import { forbidden } from '../../../shared/errors.js';
import { requireVisibleStudent } from '../auth.js';
import { newId, rowToApi, rowsToApi } from '../mapper.js';
import { buildInsert, SQL_NOW } from '../insert.js';
import { requireText, toText } from '../coerce.js';
import { notifyBoundPartners, NotificationTypes } from './notify.js';

/**
 * 通知与每日点评（`NotificationRepository` 的服务端落点）。
 *
 * ## 这个文件里**没有** `insertNotification` —— 这是刻意的
 *
 * 本地实现的通知是「哪台设备显示、就由哪台设备生成」：`NotificationController`
 * 把通知写进**本机**的库。单机演示下它成立，因为两个角色共用同一个库；
 * 两台手机之后，学生手机写的那条通知在家长手机上**根本不存在**。
 *
 * 所以通知的产生位置上云后必须整体搬到服务端（陷阱⑦），而客户端的
 * `insertNotification` 随之**退化成服务端内部调用** ——
 * 见 `notify.js`（事件发生时由业务处理函数调用），客户端侧不再有这条路。
 *
 * 于是这里不注册 `POST /data/notifications`：**接口不存在**比
 * 「接口存在但返回 403」更适合表达「这件事不是客户端能做的」。
 * 客户端少一条路可走，就等于少一个将来被误用的口子。
 *
 * ## 已读状态为什么从 JOIN 来，而不是读行上的 `is_read`
 *
 * 广播通知（`target_user_id = ''`）是**所有角色共用的同一行**。只要已读状态
 * 放在行上，就必然出现「学生点掉一条广播，家长那端的未读数也一起消失」——
 * 这个缺陷在单机演示里已经存在，只是不容易被注意到。多设备下它变成常态。
 *
 * 正解是 `app_notification_read(notification_id, user_id)` 关联表（第 23 张，
 * 客户端 SQLite 里没有）。行上的 `is_read` 退化成历史字段：
 * **读的时候不再看它，写的时候也不碰它**（`sql/005_notification.sql` 已经
 * 收掉了 `app_notification` 的 UPDATE 权限，想碰也碰不到）。
 */

/**
 * 取当前用户可见的通知（本人专属 + 广播），按时间倒序。
 *
 * ## 两处必须改掉的地方（都在这里改掉了）
 *
 * 1. 本地实现**先取全表再在内存里过滤**（`_queryAllNotifications` 没有 where）。
 *    上云后那就是「每个客户端拉走全库通知，含别人的专属通知」——
 *    既浪费带宽也是越权。这里把它下推成 SQL 条件。
 * 2. 本地实现的 `userId` 为空时**返回全部**（为了兼容「登录前」场景）。
 *    服务端不保留这个分支：**没有身份就不该拿到任何人的通知**。
 *    这一条由 RLS 兜住（`current_setting('app.user_id', true)` 取不到值时
 *    表达式为 NULL → 一行都不返回，fail-closed）。
 *
 * ⚠️ 客户端签名里的 `userId` 参数**留在线上但一概不读**（与 `wish.js` 同样的处置）：
 * 收件人只能是 token 里的那个人，否则改个包就能读别人的通知 —— 而症状
 * 极其隐蔽（别人的红点自己消失了，且不报任何错）。
 */
export async function queryNotifications(client, ctx) {
  // 显式写出条件而不是只靠 policy：policy 是**安全边界**，不是可读性的声明。
  // 两者重合时重复一次没有代价（且能让 idx_notification_target 用上），
  // 将来 policy 被改动时会立刻表现成查询结果变化，而不是**静默多返回几行**。
  const r = await client.query(
    `select n.id, n.title, n.body, n.created_at, n.target_user_id, n.type, n.related_biz_id,
            (r.user_id is not null) as read_by_me
       from app_notification n
       left join app_notification_read r
              on r.notification_id = n.id
             and r.user_id = $1
      where n.target_user_id = $1 or n.target_user_id = ''
      order by n.created_at desc, n.id`,
    [ctx.userId],
  );

  return {
    items: r.rows.map((row) => {
      const item = rowToApi(row);
      // `isRead` 的含义改成「**我**读过了」。行上的 is_read 不再参与 ——
      // 保留列名是为了让客户端（S4 前）不改一行就能拿到正确的语义。
      item.isRead = item.readByMe === true;
      delete item.readByMe;
      return item;
    }),
  };
}

/**
 * 标记已读（`markNotificationRead`）。
 *
 * ## 必须补上「这条通知是发给你的」这一步
 *
 * `app_notification_read` 的 policy 只校验 `user_id = 当前用户`
 * （见 `sql/002_rls.sql:137`）—— 它管得住**「这行已读记录是谁的」**，
 * 但**管不住 `notification_id` 指的那条通知你能不能看见**。
 * 少了下面这次校验，改个包就能拿任意 id 插一行已读记录。
 *
 * 它不会泄露内容（读不到就是读不到），但它会往库里塞垃圾行，
 * 而且给「猜 id」提供了一个可观测的信号（命中与否通过返回码区分）。
 * 一次 `select` 就能收掉，不值得省。
 *
 * 幂等：靠主键 `(notification_id, user_id)` + `do nothing`。
 * 用 `do nothing` 而不是 `do update set read_at = now()`，是因为
 * `read_at` 的语义是**第一次读到它的时刻** —— 重复点击不该把它推后。
 */
export async function markNotificationRead(client, ctx, body) {
  const id = requireText(body.id, 'id');

  const visible = await client.query(
    `select id from app_notification
      where id = $1 and (target_user_id = $2 or target_user_id = '')`,
    [id, ctx.userId],
  );
  if (visible.rowCount === 0) throw forbidden('找不到这条通知（或它不属于你）');

  const ins = await client.query(
    `insert into app_notification_read (notification_id, user_id, read_at)
     values ($1, $2, now())
     on conflict (notification_id, user_id) do nothing
     returning notification_id, user_id, read_at`,
    [id, ctx.userId],
  );

  // 冲突命中时 `returning` 是空的。回查一次，让「首次标记」与「重复标记」
  // 返回同一个形状 —— 否则客户端会看到一次「成功但结果为空」。
  const row = ins.rows[0] ?? (await client.query(
    `select notification_id, user_id, read_at from app_notification_read
      where notification_id = $1 and user_id = $2`,
    [id, ctx.userId],
  )).rows[0];

  return { marked: true, read: rowToApi(row) };
}

/**
 * 把**当前用户看得见的**未读通知一次全标已读。
 *
 * ## 为什么不是让客户端循环调上一条
 *
 * 一条通知一次 HTTP。家长攒了几十条未读，点一下就是几十个串行往返；
 * 中途失败还会留下「一半已读、一半没读」的状态，而界面只会显示「失败」。
 *
 * ## 可见范围必须在 SQL 里再写一遍
 *
 * 不能只靠 RLS：`select` 出来的行**确实**已经是可见的，但这里连 `select`
 * 都带着 `target_user_id = 我 or 广播` 的显式条件 —— 理由与上一条相同，
 * 让「批量」这条路和「单条」那条路的判据逐字一致。将来读策略放宽时，
 * 这两处会一起被看见，而不是只有一条安静地越权。
 *
 * `not exists` 只为拿准 `marked`（已经在已读表里的不该计入）。真正的
 * 防重仍由主键 `(notification_id, user_id)` + `do nothing` 兜住。
 */
export async function markAllNotificationsRead(client, ctx) {
  const r = await client.query(
    `insert into app_notification_read (notification_id, user_id, read_at)
     select n.id, $1, now()
       from app_notification n
      where (n.target_user_id = $1 or n.target_user_id = '')
        and not exists (
          select 1 from app_notification_read r
           where r.notification_id = n.id and r.user_id = $1
        )
     on conflict (notification_id, user_id) do nothing`,
    [ctx.userId],
  );
  // 不用 RETURNING：这里是「批量插入自己的已读行」，读策略虽然放行，
  // 但已经踩过一次 RETURNING 在 RLS 下的坑（见 notify.js 文件头，
  // 那次是写给别人的通知）。`rowCount` 同样准确，且只依赖 INSERT 权限。
  return { marked: r.rowCount ?? 0 };
}

/** 每日点评的可写字段。`id` / `student_id` / `created_at` 一律由服务端定。 */
const DAILY_COMMENT_SPEC = {
  // 评分是这条点评的**唯一必填项**（它是标题里出现的那个值）。
  rating: (v, f) => requireText(v, f),
  // `content` 在 DDL 里是 NOT NULL，所以缺省补空串而不是留 null ——
  // 留 null 会让插入在数据库那层失败，而报错指向的是库不是调用方。
  content: (v) => toText(v) ?? '',
};

/**
 * 新增一条每日点评（家长写给孩子的）。
 *
 * ## 归属由 `studentId` 定，而它必须在**我的可见集合**里
 *
 * 本地实现里 `DailyCommentModel.studentId` 记录「写给谁」，且
 * `ParentController` 填的是当前选中的孩子。上云后这个值来自客户端，
 * 所以必须校验它落在 `ctx.visibleStudents` 里 —— 否则家长可以给
 * 别人家的孩子写点评，而且**对方真的会看到**（`daily_comment` 的
 * policy 是 `student_id = ANY(visible_students)`，写进去就等于送出去了）。
 *
 * 顺带一提，这次的校验不依赖任何额外断言：`daily_comment` 的 INSERT
 * policy 用的是同一条 `student_id = ANY(visible_students)` 条件，
 * 所以越界的写**在数据库那层也会被拒**，这里的 400/403 只是把
 * 一次数据库报错换成一次说明清楚的业务错误。
 *
 * ## 通知也在这里生成（陷阱⑦）
 *
 * 本地实现是「写点评」+「发通知」两件事（`parent_controller.dart:589` 与 `:597`），
 * 上云后后者必须由服务端做，否则孩子在另一台设备上收不到。
 *
 * ⚠️ 收件人**显式指定**，不用默认的「按关系推导」：家长可能有多个孩子，
 * 默认推导会把「给老大的点评」同时通知给老二。
 * 收件人能被 policy 接受是因为 `studentId` 已经验过是自己结伴的孩子
 * （见 `sql/005_notification.sql` 的 `notification_insert`）。
 */
export async function insertDailyComment(client, ctx, body) {
  const studentId = requireVisibleStudent(ctx.visibleStudents, body.studentId, '该学生');
  const commentId = newId();

  const ins = buildInsert({
    table: 'daily_comment',
    spec: DAILY_COMMENT_SPEC,
    body,
    extras: [
      { column: 'id', value: commentId },
      { column: 'student_id', value: studentId },
      { column: 'created_at', value: SQL_NOW },
    ],
  });
  const r = await client.query(ins.text, ins.values);
  const item = r.rows[0];

  await notifyBoundPartners(client, ctx, {
    to: [studentId],
    title: '家长点评',
    // 与本地实现的文案一致（`parent_controller.dart:599`）：标题里带评分，
    // 因为评分是家长最想一眼看到的那个值。
    body: `家长发布了新的每日点评：${item.rating}`,
    type: NotificationTypes.dailyComment,
    relatedBizId: commentId,
  });

  return { item: rowToApi(item) };
}

/**
 * 取点评，按时间倒序。
 *
 * 本地实现的注释写的是「**无过滤**，调用方自己按 studentId 过滤成我结对的孩子」——
 * 那句话在单机单库下是成立的，上云后是「家长会读到别人家孩子的点评」。
 * 所以过滤**下推到 SQL**：`student_id = ANY(ctx.students)`。
 *
 * 家长 → 结伴的孩子；学生 → 自己（这正好也是「谁写给我的点评」）。
 *
 * 与 `queryNotifications` 一样，这里也显式写出条件 —— RLS 的
 * `own_rows` policy 用的是同一个 `visible_students` 表达式，
 * 两者一致时它只是一次多余但便宜的重复。
 */
export async function queryDailyComments(client, ctx) {
  const r = await client.query(
    `select * from daily_comment
      where student_id = any($1::text[])
      order by created_at desc, id`,
    [ctx.students],
  );
  return { items: rowsToApi(r.rows) };
}
