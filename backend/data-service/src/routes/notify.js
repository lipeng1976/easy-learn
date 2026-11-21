import { newId, rowToApi, rowsToApi } from '../mapper.js';
import { buildInsert } from '../insert.js';
import { UserRoles } from '../../../shared/token.js';
import { RELATIONSHIP_ACTIVE } from '../vocab.js';

/**
 * 通知的产生 —— **服务端在事件发生时生成，客户端只读**（陷阱⑦的服务端落点）。
 *
 * ## 为什么这件事必须在这里做
 *
 * 本地实现是「哪台设备显示、就由哪台设备生成」（`NotificationController.addNotification`
 * 把通知写进本机的库）。单机演示下它工作得很好 —— 因为两个角色**共用同一个库**。
 * 换成两台手机之后，学生手机写进去的那条通知，在家长手机上**根本不存在**：
 * `targetUserId` 填得再准也换不来一行记录。
 *
 * 所以生成位置从「客户端」搬到「服务端」不是优化，是**功能能不能成立**的区别。
 * 客户端从此只调 `GET /data/notifications` 与标记已读。
 *
 * ## 权限：不靠新角色，靠「应用声明收件人」
 *
 * 服务端是在**请求方的身份**下写这行通知的（没有另开特权连接），
 * 所以它必须通过 `app_notification` 的 INSERT policy。那条 policy 认三件事
 * （见 `sql/005_notification.sql`）：自己 / 广播 / **本次事务里声明过的收件人**。
 *
 * 声明动作就是下面这个 [allowTargets] —— 而它声明的值**只可能来自服务端**
 * （`counterpartIds` 查关系表得出，或调用点显式给出的 studentId）。
 * 客户端能影响的只有「发什么」，影响不到「发给谁」。
 *
 * ⚠️ 这条 policy 的必然代价：**同一台设备上的恶意客户端可以给自己的结伴对象
 * 刷通知**。它与「能给对方发聊天消息」是同一级别的问题（同一家庭内部的骚扰），
 * 与「一个班互相看得见」差得很远。真正的对策是限流，不是把 policy 收死 ——
 * 收死的代价是「通知由服务端生成」这件事根本做不出来。
 *
 * ## 为什么这两个函数都**不用** `RETURNING`（2026-09-18 实测）
 *
 * 在 RLS 下，`INSERT ... RETURNING` 要求**新行本身能被读策略看见**：
 * `RETURNING` 返回的每一行都要过一遍 SELECT policy。而通知的读策略是
 * `target_user_id = 自己` 或 `广播`（`sql/005_notification.sql`），于是：
 *
 *   · 写给**自己**或**广播** → 新行可读 → 带 `RETURNING` 也通过；
 *   · 写给**别人**（学生写给家长、家长写给孩子 —— 也就是全部有意义的用法）
 *     → 新行读不出来 → **整条 INSERT 被拒**，报
 *
 *         new row violates row-level security policy for table "app_notification"
 *
 * 这条报错**指向的是 INSERT 策略**，而 INSERT 策略其实完全放行
 * （收件人已经由 `app.notify_targets` 声明过）—— 于是排查会被带到一个
 * 无论怎么改都不对的地方。本机实测的四格矩阵（同一事务、同一份声明、
 * 唯一变量是语句形态；`test/data.test.js` 里有对应的回归用例）：
 *
 *     字面量 / 参数化  ×  无 RETURNING  → 通过
 *     字面量 / 参数化  ×  带 RETURNING  → 42501（`returning id` 也一样）
 *     带 RETURNING，但收件人是自己      → 通过
 *
 * 所以这里**写完之后不读回来**：需要的字段服务端本来就知道
 * （id 自己生成，时间戳取事务的 `now()`），没有理由为了拿它们
 * 给每一行加一道读权限要求。代价是返回值由 JS 组装，
 * **因此它必须与库里那一行逐字段一致**（见 `noticeRow`）。
 *
 * 将来若真需要读回，正确做法是放宽**读**策略并想清楚「谁能看见写给别人的通知」，
 * 而不是把 `RETURNING` 加回来 —— 加回来只会让同一个错误以同样的误导性文案再出现一次。
 */

/**
 * 事件类型（写进 `app_notification.type`）。
 *
 * ⚠️ **这份清单必须与 `lib/models/notification_model.dart` 的 `NotificationType`
 * 逐字对齐** —— `NotificationType.parse` 是按 `value.name` 匹配的，匹配不上就
 * **静默回落到 `system`**：不报错，只是图标变成铃铛。
 * 这种「错了但看不出来」的偏差是最难发现的一类，所以宁可在枚举里少几个值，
 * 也不要写一个客户端认不出的字符串。
 *
 * 客户端侧 `type` 只参与图标与标签（全库唯一的消费者是
 * `database_service.dart:4006` 的 `NotificationType.parse`），没有任何分支逻辑
 * 依赖它 —— 所以**用错了不会影响功能，只会影响观感**，也正因如此它很容易
 * 一直错下去。改动这里时请同时改客户端。
 *
 * 注意**没有** `checkin` / `workout` 这类「事件名」：枚举的键是**展示域**
 * （作业 / 运动 / 复习 / 计划 / 心愿 / 点评 / 系统），不是事件本身。
 * 「打卡完成」属于计划这个展示域，所以用 `studyPlan` 而不是自造 `checkin`。
 */
export const NotificationTypes = {
  homework: 'homework',
  workout: 'workout',
  review: 'review',
  studyPlan: 'studyPlan',
  wish: 'wish',
  dailyComment: 'dailyComment',
  /**
   * 结伴关系本身的通知（目前只有一种：家长解除结伴）。
   *
   * ⚠️ 加一个类型要**同时**改客户端 `lib/models/notification_model.dart`
   * 的 `NotificationType` —— 而漏改的症状是静默的：`parse()` 认不出的词
   * 退回 `system`，于是那条通知照样显示、照样能点，只是**图标与业务标签是错的**。
   * 没有测试盯着这层（`parse` 有个 default 分支，永远不会红）。
   */
  relationship: 'relationship',
  system: 'system',
};

/**
 * 找出「该收到这条通知的人」= 与当前用户结伴的另一方。
 *
 * 学生发起 → 他的家长；家长发起 → 他的孩子。
 * 两端都只取关系**已成立**的行（`vocab.js` 的 `active`）—— pending 的关系还没成立，
 * 给一个还没确认的人推送「你家孩子提交了作业」是错的（那甚至不是他家孩子）。
 */
async function counterpartIds(client, ctx) {
  if (ctx.role === UserRoles.student) {
    const r = await client.query(
      `select parent_id as uid from relationship
        where student_id = $1 and status = $2`,
      [ctx.userId, RELATIONSHIP_ACTIVE],
    );
    return r.rows.map((x) => x.uid);
  }
  if (ctx.role === UserRoles.parent) {
    const r = await client.query(
      `select student_id as uid from relationship
        where parent_id = $1 and status = $2`,
      [ctx.userId, RELATIONSHIP_ACTIVE],
    );
    return r.rows.map((x) => x.uid);
  }
  // 老师角色还没有（见迁移计划 §10.5）：它将来要通知的是「本班学生的家长」，
  // 而 `classroom_member` 那张表还没建。留空而不是猜。
  return [];
}

/**
 * 指定学生的全部家长（关系已成立的，`vocab.js` 的 `active`）。
 *
 * ## 为什么需要它：默认的「按关系推导」在多孩子家庭里是错的
 *
 * `notifyBoundPartners` 不指定收件人时，收件人是**与该用户结伴的所有人**。
 * 家长有两个孩子时，「家长给老大布置了学习计划」按默认推导会**同时通知老二**；
 * 点评同理。而这两件事都是有明确对象的（`studentId` 就在请求体里），
 * 所以调用方必须显式指定，不能省。
 *
 * 反方向（学生交作业 / 打卡 → 通知家长）用这个函数同样比默认推导准确：
 * 默认推导依赖「发起者是谁」，而这里依赖「这件事是关于谁的」——
 * 后者在请求里是已知的，前者要靠调用点自己保证。
 *
 * 子查询同样受 RLS 约束（`relationship` 有自己的 policy），
 * 所以这个函数并不会因为「直接查表」而打开什么口子。
 */
export async function parentIdsOf(client, studentId) {
  const r = await client.query(
    `select parent_id as uid from relationship
      where student_id = $1 and status = $2`,
    [studentId, RELATIONSHIP_ACTIVE],
  );
  return r.rows.map((x) => x.uid);
}

/**
 * 声明「本次事务里允许写通知的收件人」。
 *
 * `app_notification` 的 INSERT policy 只认这个集合（见 `sql/005_notification.sql`）：
 * 判断逻辑因此只有一层，与「应用算 `visible_students`、RLS 认它」完全同构。
 *
 * ## 唯一的硬约束：值只能来自数据库推导，不能来自请求体
 *
 * 把请求体里的字段塞进来，等于让客户端自己声明「我能给谁发通知」——
 * 而 policy 已经没有第二道防线了（这正是简化换来的东西，所以这条约定必须守住）。
 * 本文件里两个 `notice.to` 的取值来源只有两处，都是服务端算的：
 *   · `counterpartIds()` —— 查 `relationship`；
 *   · 调用点显式给出的 `studentId`（而它已经过 `requireVisibleStudent` 校验）。
 *
 * ⚠️ `set_config(..., true)` 的第三个参数是 `is_local`，只对本事务有效 ——
 * 而整个请求就在一个事务里（`withRequestContext`），所以不需要清理。
 * **不要**把它设成 `false`：那会让这个能力泄漏到同一条连接的下一个请求上，
 * 而症状是「某个用户的请求忽然能给陌生人发通知」。
 */
async function allowTargets(client, targets) {
  await client.query('select set_config($1, $2, true)', [
    'app.notify_targets',
    targets.join(','),
  ]);
}

/**
 * 本次事务的时间戳。
 *
 * 为什么不让 SQL 里直接写 `now()`：见文件头「为什么这两个函数都不用 `RETURNING`」——
 * 通知插入**不能**带 `RETURNING`，于是插完拿不到数据库填的 `created_at`。
 * 而 `select now()` 在同一个事务里返回的就是 `transaction_timestamp()`，
 * 与 INSERT 里 `now()` 求的值**完全相同**，所以把它当参数传进 `created_at`，
 * 落库的值与「让数据库自己填」逐字节一致，返回给调用方的时间也是真的。
 *
 * 换成 `new Date()` 就错了：那是应用进程的时钟，多实例部署时机器之间
 * 有毫秒级差异，同一批通知会带上不同的时间（R3 要的正是「服务端说了算」）。
 */
async function txNow(client) {
  const r = await client.query('select now() as ts');
  return r.rows[0].ts;
}

/**
 * 一行通知。**返回给调用方的对象与写进库的那一行是同一个对象** ——
 * 列名由 `buildInsert` 从驼峰转成下划线，所以这里只维护一份字段清单，
 * 不存在「库里写这些、返回值里写另一些」这种会悄悄漂开的第二份。
 */
function noticeRow(id, targetUserId, notice, createdAt) {
  return {
    id,
    title: notice.title,
    body: notice.body,
    targetUserId,
    type: notice.type ?? NotificationTypes.system,
    relatedBizId: notice.relatedBizId ?? '',
    isRead: false,
    createdAt,
  };
}

/**
 * 通知「与自己结伴的人」。
 *
 * 静默处理「一个都没结伴」的情况（返回空数组）：那是**正常状态**
 * （新注册的学生还没结伴），不是错误。抛异常会让「提交作业」在
 * 未结伴的账号上失败 —— 而那是最不该失败的一步。
 *
 * @param {object} client
 * @param {object} ctx 请求上下文（要 userId 与 role）
 * @param {{title: string, body: string, type?: string, relatedBizId?: string}} notice
 * @param {string[]} [notice.to] 显式指定收件人（默认按关系推导）
 *        ⚠️ 只接受服务端算出的列表 —— 永远不要把请求体里的字段传进来。
 */
export async function notifyBoundPartners(client, ctx, notice) {
  const targets = notice.to ?? (await counterpartIds(client, ctx));
  if (targets.length === 0) return [];
  await allowTargets(client, targets);

  const ts = await txNow(client);
  const rows = [];
  for (const uid of targets) {
    const row = noticeRow(newId(), uid, notice, ts);
    const ins = buildInsert({
      table: 'app_notification',
      spec: {},
      row,
      // 不要 RETURNING —— 理由见文件头「为什么这两个函数都不用 RETURNING」。
      returning: null,
    });
    await client.query(ins.text, ins.values);
    rows.push(row);
  }
  return rowsToApi(rows);
}

/**
 * 单条通知（给「系统公告」这类不该广播给结伴对象的场景用）。
 *
 * ⚠️ **目前没有任何调用点，也没有对应端点** —— 它是为「系统公告」预留的，
 * 而那件事还没做（能产生广播的业务路径同样一条都没有，见
 * `sql/005_notification.sql` 里对哨兵值 `''` 的说明）。
 * 写在这里是为了让将来接入的人只有一个地方需要改，但**它的正确性没有被任何用例覆盖**：
 * 上面那段 `RETURNING` 的坑就是这么被踩过一遍的（`notifyBoundPartners` 有 12 处调用，
 * 一改就炸；这个函数改错了不会有任何症状）。真要开始用它，先给它补一条用例。
 */
export async function notifyUser(client, userId, notice) {
  // 与 notifyBoundPartners 同样的前置动作：先声明收件人，再插。
  // 少了它这条通知会被 policy 拒（除非 userId 恰好是自己或广播）。
  await allowTargets(client, [userId]);

  const ts = await txNow(client);
  const row = noticeRow(newId(), userId, notice, ts);

  const ins = buildInsert({
    table: 'app_notification',
    spec: {},
    row,
    // 与 notifyBoundPartners 同一条理由：不要 RETURNING。
    returning: null,
  });
  await client.query(ins.text, ins.values);
  return rowToApi(row);
}
