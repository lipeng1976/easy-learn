import { badRequest, forbidden } from '../../../shared/errors.js';
import { UserRoles } from '../../../shared/token.js';
import { newId, rowToApi, rowsToApi } from '../mapper.js';
import {
  RELATIONSHIP_APPROVAL_STATUSES,
  RELATIONSHIP_REVIVABLE_STATUSES,
  RELATIONSHIP_STATUS,
} from '../vocab.js';
import { NotificationTypes, notifyUser } from './notify.js';

/**
 * 结伴关系（S2）。
 *
 * ## 它修掉的是什么
 *
 * 客户端现状：`createRelationshipInvitation` 内部走 `findUserByPhone`，
 * 而那个查询打的是**本机 SQLite** —— 于是「家长在自己手机上邀请孩子」
 * 必然抛「手机号对应的用户不存在」（`doc/open-items.md` §C1）。
 * 单机演示时看不出问题，只因为两个角色共用同一个库。
 *
 * 上云后「邀请」终于可以成立：手机号是全局唯一的，对方在哪台设备上都一样。
 *
 * ## 越权面在哪
 *
 * 与其它端点不同，这里有一个**打破隔离的读**：邀请方手里只有手机号，
 * 要把它变成一个 user_id，而 `app_user` 的 policy 让「无关账号」读不到 ——
 * 这是对的，正因为如此才需要绕过它。
 *
 * 三件事让它不至于失控：
 *   ① 必须**已登录**才能调（`/data/*` 全是受保护路由）；
 *   ② 只用手机号做**等值**查找，没有列表 / 模糊 / 批量接口；
 *   ③ 返回给客户端的信息**只有「存不存在」**，拿不到对方的资料。
 *
 * ⚠️ ③ 也意味着它仍然是一个（弱）账号枚举面：输入手机号能判断出谁在用这个 App。
 * 这是产品决定的 —— 家长邀请孩子本来就只能靠手机号。要压住它靠的是限流与审计，
 * 那是 S3 的事（迁移计划 §4.1）；在这里假装不存在才是问题。
 *
 * 注意**不能**用「回一句『邀请已发出』但实际不建关系」来掩盖：
 * 那样家长会等一个永远不会到来的确认，问题只是从枚举面变成了功能故障。
 */

/** 与 auth 路由同一套手机号形状约束（它是账号标识符，不是昵称）。 */
const PHONE_PATTERN = /^1\d{10}$/;

const RELATIONSHIP_COLUMNS = 'id, student_id, parent_id, sender_id, status, created_at';

/**
 * 同一份列清单加上表别名前缀。
 *
 * JOIN 之后 `id` / `status` / `created_at` 在 `relationship` 与 `app_user` 里同名，
 * 不加前缀 PostgreSQL 直接报 `42702 column reference "id" is ambiguous`。
 *
 * 用生成而不是手抄第二份：手抄的那份会在以后加列时被漏掉，
 * 而漏掉的症状是「这个字段在某些接口里莫名其妙是 undefined」，不报错。
 */
function aliasColumns(alias) {
  return RELATIONSHIP_COLUMNS.split(',')
    .map((c) => `${alias}.${c.trim()}`)
    .join(', ');
}

/**
 * 我参与的全部关系（含 pending）。
 *
 * 查询里 `or parent_id = $2` 那半句不能省：家长**待确认**的邀请里
 * 孩子还不在 `visible_students` 里（那是关系成立、`vocab.js` 的 `active` 才算的），
 * 只按可见集合查会让家长看不到自己刚发出的邀请。
 *
 * 副作用是 `studentId` 筛选对家长不完全生效（家长永远看得到自己的全部关系行）。
 * 这不是越权 —— `parent_id = 我` 那半句限定了范围，漏掉的只是「再筛一个孩子」。
 * 反过来说，若为了让它生效而把条件写严，代价是家长看不到待确认的邀请。
 * 两害相权，取看得全。
 */
export async function listRelationships(client, ctx) {
  const r = await client.query(
    // 两个名字是**顺带 join 出来的**，不是客户端再查一次 ——
    // 客户端手里只有 id，它要显示「对方是谁」就必须回头读 `app_user`，
    // 而那一次读受 RLS 约束（`sql/008_relationship_peer_name.sql` 专门放开了
    // 「结伴对端」这一种），修在服务端这边只有一处。
    //
    // ⚠️ 必须是 **LEFT JOIN**：`pending` 的邀请里对方还不在我的可见集合里
    // （`resolveVisibleStudents` 只算 `active` 的），INNER JOIN 会把
    // 「刚发出、等对方确认」的邀请整行从列表里删掉 —— 而列表最该显示的就是它。
    // 取不到名字时回 null，`rowToApi` 原样带出去，客户端映射成空串。
    `select ${aliasColumns('r')},
            stu.name as student_name,
            par.name as parent_name
       from relationship r
       left join app_user stu on stu.id = r.student_id
       left join app_user par on par.id = r.parent_id
      where r.student_id = any($1::text[]) or r.parent_id = $2
      order by r.created_at desc, r.id`,
    [ctx.students, ctx.userId],
  );
  return { items: rowsToApi(r.rows) };
}

/**
 * 发出结伴邀请（状态 `pending`，等对方确认）。
 *
 * 为什么不是「插入即结伴」：结伴意味着家长能看到孩子的全部作业、错题与对话。
 * 一个不设防的「输入手机号即可查看」是这套系统里权限最大的一条路径，
 * 必须由被查看的一方点头 —— 所以中间那个 `pending` 不能省。
 */
export async function invite(client, ctx, body) {
  const targetPhone = String(body?.targetPhone ?? '').trim();
  if (!PHONE_PATTERN.test(targetPhone)) throw badRequest('请输入有效的11位手机号');

  const peer = await ctx.lookupUserByPhone(targetPhone);
  if (!peer) throw badRequest('该手机号尚未注册，请让对方先注册账号');
  if (peer.id === ctx.userId) throw badRequest('不能和自己结伴');

  const iAmStudent = ctx.role === UserRoles.student;
  const iAmParent = ctx.role === UserRoles.parent;
  if (!iAmStudent && !iAmParent) {
    // 目前只有两种角色能结伴。老师将来也不走这条路（他走班级）。
    throw forbidden('当前身份不支持结伴');
  }
  const peerRole = String(peer.role);
  const complementary = (iAmStudent && peerRole === UserRoles.parent)
    || (iAmParent && peerRole === UserRoles.student);
  if (!complementary) {
    throw badRequest(iAmStudent
      ? '只能邀请家长账号结伴'
      : '只能邀请学生账号结伴');
  }

  const studentId = iAmStudent ? ctx.userId : String(peer.id);
  const parentId = iAmStudent ? String(peer.id) : ctx.userId;

  // `on conflict ... do update` 而不是「先查再插」：
  // 查与插之间的那道缝里，对方可能刚好也发起了邀请（两个方向同时点），
  // 于是两边都「查到没有」、都去插 —— 其中一个撞唯一约束。
  // 让数据库在一次语句里回答「这一格现在能不能被占」，是并发安全的全部答案。
  //
  // `where` 子句是这次改动的全部要害：**只有已结束的关系行可以被复活**
  //（`removed` 解除 / `rejected` 被拒）。`pending` 与 `active` 落在条件外，
  // 于是 `do update` 不执行、`returning` 一行都不返回 —— 下面用 `rowCount`
  // 把它翻译成人话的错误。
  //
  // ⚠️ 改这个条件等于改「重新结伴」这条产品路径能不能走通，
  // 而它的失败方式很具体：家长解除后想再连上，会收到**「你们已经结伴」** ——
  // 一句与事实完全相反的话（那正是 `uq_relation` 约束没被处理时的症状）。
  //
  // ⚠️ `created_at = now()` 会**覆盖最初的建立时间**。这是有意的
  //（列表按它排序，「刚发出的邀请」该排在最前），但代价是「第一次是什么时候结伴的」
  // 从此查不到 —— 表上现在没有第二列记时间。要审计得加 `removed_at`，见 open-items B22。
  const r = await client.query(
    `insert into relationship (id, student_id, parent_id, sender_id, status)
     values ($1, $2, $3, $4, $5)
     on conflict (student_id, parent_id) do update
       set sender_id = excluded.sender_id,
           status = excluded.status,
           created_at = now()
       where relationship.status = any($6::text[])
     returning ${RELATIONSHIP_COLUMNS}`,
    [
      newId(), studentId, parentId, ctx.userId, RELATIONSHIP_STATUS.pending,
      RELATIONSHIP_REVIVABLE_STATUSES,
    ],
  );

  if (r.rowCount === 0) {
    // 走到这里只有一种情况：那一格上有一条 `pending` 或 `active` 的关系。
    // 对调用方是同一句话（他不需要知道对方是还没回应还是已经结伴）。
    //
    // ⚠️ **不要再套一层 `catch` 去接 `23505`**（这版之前就是这么写的）。
    //   `on conflict` 已经把 `uq_relation` 这条冲突接管了，能漏到 catch 的
    //   只剩**别的**约束冲突（比如 id 主键），而那时回「你们已经结伴」
    //   是一句与故障无关的话 —— 它会把「id 生成坏了」伪装成「重复邀请」。
    throw badRequest('你们已经结伴，或已有待确认的邀请');
  }
  return { relationship: rowToApi(r.rows[0]) };
}

/**
 * 接受 / 拒绝邀请。
 *
 * 状态机约束写进 SQL（`and status = $3`）而不是先读后判：
 * 「已确认的关系被改成拒绝」在单请求下不会发生，在两个人同时点的时候会。
 * 让数据库来回答「这一行还是不是 pending」，比在应用层读一次再写一次可靠。
 */
export async function updateStatus(client, ctx, body) {
  const id = String(body?.id ?? '').trim();
  if (id === '') throw badRequest('缺少关系 id');

  const status = String(body?.status ?? '').trim();
  if (!RELATIONSHIP_APPROVAL_STATUSES.includes(status)) {
    throw badRequest(
      `status 只能是 ${RELATIONSHIP_APPROVAL_STATUSES.join(' 或 ')}`
      + `（${RELATIONSHIP_STATUS.pending} 是发起时的初始状态，不能改回去）`,
    );
  }

  const r = await client.query(
    `update relationship
        set status = $2
      where id = $1 and status = $3
      returning ${RELATIONSHIP_COLUMNS}`,
    [id, status, RELATIONSHIP_STATUS.pending],
  );

  if (r.rowCount === 0) {
    // 三种可能：id 不存在、不是我参与的关系（RLS 挡掉了）、已经不是 pending。
    // 对调用方是同一件事：这个邀请我现在处理不了。
    throw forbidden('找不到待处理的邀请（或无权操作）');
  }
  return { relationship: rowToApi(r.rows[0]) };
}

/**
 * 解除结伴（**家长单方，立即生效**）—— `POST /data/relationship/revoke`。
 *
 * 2026-09-26 新增。此前这条路是不通的：客户端有 `RelationshipStatus.removed`
 * 和「已解除」的文案，但**没有任何东西会产生那个状态** ——
 * 服务端没有这个动作（词表里连 `removed` 都没有），于是家长一旦结伴就再也解不开。
 *
 * ## 为什么是独立端点，而不是 `updateStatus` 的一个取值
 *
 * 见 `vocab.js: RELATIONSHIP_APPROVAL_STATUSES` 的表格。三样都不同：
 * 前置状态（`active` vs `pending`）、权限（仅家长 vs 被邀请的那一方）、
 * 语义（撤销一段已成立的关系 vs 回应一个邀请）。
 * 合进一个端点的话，`updateStatus` 里那句 `and status = $3` 会变成
 * 「靠传入的 status 反推前置状态」的隐式矩阵 —— 9 格里只有 2 格合法。
 *
 * ## 只有家长能做 —— 产品决定（2026-09-26 与用户确认）
 *
 * 角色取自 **`ctx.role`（token 里解出来的）**，不看请求体。
 * 学生端没有入口，而它**不需要有**：学生对「谁在看我」没有控制权，
 * 他的可见集合恒为「自己」，解除对他的一切功能都没有影响 ——
 * 只是不再有人能看到他的数据。
 *
 * ## 解除之后会发生什么（三件事，**一件都不报错**）
 *
 * ① **可见集合立刻变空** —— `resolveVisibleStudents` 只算 `active`
 *    （`db.js`）。家长端所有学生数据的读从此返回 0 行。
 *    ⚠️ 表现为**「尚未与任何学生结伴」**，不是一个错误提示 ——
 *    这是本系统里最典型的那类静默失败：功能是对的，但长得像 bug。
 * ② **聊天双向关闭** —— `chat.js: requireActiveMembership` 要求 `active`，
 *    读写都 403。**历史消息一条没删**，重新结伴后照样能读到。
 * ③ **学生数据一行都不动** —— 作业 / 打卡 / 错题 / 照片的归属是 `student_id`，
 *    与关系无关。所以**重新结伴 = 完整恢复可见**，含解除期间孩子自己产生的数据。
 *    这是确认过的产品决定（`vocab.js: RELATIONSHIP_STATUS.removed` 有完整说明），
 *    **不是遗漏**；要改成「只看到重新结伴之后的」得给可见集合加时间下界，
 *    代价见 `doc/open-items.md` B22。
 *
 * 上面 ① 与 ③ 合起来有一个不太直觉的推论，值得写在代码里：
 * **解除并不能收回已经看过的数据**。它只影响「此刻能不能看」，
 * 不改写孩子那侧的任何一行。所以家长在结伴期内看过的内容，他记住了就是记住了。
 */
export async function revoke(client, ctx, body) {
  if (ctx.role !== UserRoles.parent) {
    // 「这件事不归你做」→ 403；不是「参数写错了」→ 400。
    //
    // ⚠️ 这一道**与下面 SQL 里的 `parent_id = 我` 是两道独立保护**：
    // 删掉这一道，学生来调**仍然是 403**（`parent_id` 那条件让 UPDATE 影响 0 行，
    // 走下面那条「找不到可解除的结伴关系」）。
    //
    // 那为什么还留着？**因为它决定的是错误文案**：少了它，学生看到的是一句
    // 「找不到可解除的结伴关系（或无权操作）」—— 对学生完全没有信息量，
    // 他会以为是自己点错了、或者 App 坏了。留着它，那句话才是
    // 「只有家长可以解除结伴」，他立刻知道该找谁。
    //
    // 这条区别被测到了：`test/auth.test.js` 里那条断言**同时钉住 403 与文案**。
    // 2026-09-26 的证伪发现了这件事 —— 只断言状态码时，删掉这一道测试**全绿**，
    // 因为另一道把结果兜住了。
    throw forbidden('只有家长可以解除结伴');
  }

  const id = String(body?.id ?? '').trim();
  if (id === '') throw badRequest('缺少关系 id');

  const r = await client.query(
    // 三个条件缺一不可：
    //   · `id` —— 指定哪一条；
    //   · `parent_id = 我` —— **RLS 已经挡过一层，这里再显式写一遍**。
    //     两道不是冗余：RLS 管的是「这一行我看不看得见」，而 `relationship` 的
    //     policy 是 `student_id = ANY(可见) OR parent_id = 我` —— **学生那一半也放行**，
    //     家长 A 能看见「自己孩子与家长 B」的那一行。少了这个条件，
    //     A 就能解除 B 与孩子的关系。
    //   · `status = active` —— 状态机约束写进 SQL 而不是先读后判：
    //     两个人同时点「解除」时，先读后判会让第二次也成功（并发下都读到 active）。
    `update relationship
        set status = $2
      where id = $1 and parent_id = $3 and status = $4
      returning ${RELATIONSHIP_COLUMNS}`,
    [id, RELATIONSHIP_STATUS.removed, ctx.userId, RELATIONSHIP_STATUS.active],
  );

  if (r.rowCount === 0) {
    // 四种可能：id 不存在 / 不是我的关系 / 本来就不是 active（pending、
    // rejected、已 removed）/ 重复点击。**对调用方是同一件事，也不细分** ——
    // 细分等于回答「这条关系存不存在」，那是个没必要的枚举面。
    throw forbidden('找不到可解除的结伴关系（或无权操作）');
  }

  const row = rowToApi(r.rows[0]);

  // 通知被解除的那一方。
  //
  // ⚠️ **必须显式给 `studentId`**（不能省成默认推导）：`counterpartIds`
  //    与 `parentIdsOf` 都只认 `active`，而这一行刚刚变成 `removed` ——
  //    默认推导此刻返回空数组，通知会**静默不发**（这正是它最容易错的地方：
  //    不报错、只是对方什么都不知道）。
  //
  // 收件人的来源是**数据库推导**（上面 `returning student_id`），
  // 符合 `notify.js` 那条「`app.notify_targets` 的值只能来自数据库、不能来自请求体」的约定。
  //
  // ⚠️ 不能在这里用 `requireVisibleStudent(ctx, ...)` 去校验学生 id ——
  //    那时候关系已经不在可见集合里了，那个校验会 403，通知永远发不出去。
  //
  // 这个调用也是 `notifyUser` 的**第一个真实调用点**。那个函数的注释写着
  // 「真要开始用它，先给它补一条用例」—— `test/auth.test.js` 里那条解除闭环
  // 就是补上的用例（断言学生真收到这一行）。
  await notifyUser(client, row.studentId, {
    type: NotificationTypes.relationship,
    title: '结伴已解除',
    body: '家长已解除与你的结伴。你的作业、打卡与错题不会被删除，'
      + '若重新结伴，对方仍能看到全部历史。',
  });

  return { relationship: row };
}
