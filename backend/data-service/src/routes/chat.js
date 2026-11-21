import { badRequest, forbidden, notFound } from '../../../shared/errors.js';
import { newId, rowToApi, rowsToApi } from '../mapper.js';
import { RELATIONSHIP_ACTIVE } from '../vocab.js';

/**
 * 聊天消息（结伴双方的一对一对话）。
 *
 * ## 它补的是什么
 *
 * 服务端一开始就有 `chat_message` 表、索引和 RLS policy，**唯独没有路由** ——
 * 客户端的 `HttpRelationshipRepository` 只能抛 `not_implemented`。
 * 于是云端模式下「伴学消息」这一页：读回来是异常、发出去也是异常，
 * 而 `chat_page.dart` 当时又没接异常 → **点发送毫无反应**，
 * 用户看到的就是「消息发不出去」。
 *
 * ## 越权面在哪，怎么收
 *
 * 一次对话的可见范围是「**我参与的那条关系**」，不是「所有涉及我的消息」。
 * 两件事必须同时成立，缺一都是越权：
 *
 *   ① **关系成员**：`relationship_id` 指向的那条关系里，`student_id` 或
 *      `parent_id` 必须是我。`ctx.userId` 来自 token（`sub`），
 *      **不是客户端自报的** —— 拿 body 里的 senderId 当身份就是送越权。
 *   ② **关系成立**：状态必须是 `active`。`pending` 的邀请里对方还没有
 *      任何可见性（`resolveVisibleStudents` 只算 active），
 *      此时允许发消息等于「输入手机号就能给任意人发消息」——
 *      那正是 `invite` 那套 `pending` 流程要挡住的东西。
 *
 * ③ 再加一层**收信人由关系反推**：客户端只说「发给哪段关系」，
 *    不指定 `receiverId`。否则发送方可以伪造一个收信人，
 *    把消息塞进一段与自己无关的对话里。
 *
 * RLS 在 `chat_message` 上是按 `sender_id = 我 or receiver_id = 我` 过滤的，
 * **它挡不住 ① 和 ②** —— 一条我参与过、但关系已 `rejected` 的对话，
 * 按 RLS 我照样读得到。所以校验必须写在路由里（这一条与作业照片同源：
 * 别把「能不能看」全押在 RLS 上，RLS 管的是行的可见性，不是业务状态）。
 */

/** 一次最多取回的条数 —— 会话没有分页接口，先给一个不会把首屏拖垮的上限。 */
const MAX_MESSAGES = 500;

/** 单条消息长度上限。与客户端输入框的实际长度对齐即可，防的是刷爆。 */
const MAX_CONTENT_LENGTH = 2000;

/**
 * 取一段对话的消息（`queryChatMessages`）。
 *
 * `relationshipId` 必填：不填就等于「把我参与的所有消息混成一锅」，
 * 而客户端是按会话展示的，混着取回来它还得自己分组 —— 那是把
 * 一个明确的过滤条件散到所有调用方。
 */
export async function listChatMessages(client, ctx, query) {
  const relationshipId = String(query?.relationshipId ?? '').trim();
  if (relationshipId === '') throw badRequest('缺少 relationshipId');

  await requireActiveMembership(client, ctx, relationshipId);

  const r = await client.query(
    // 排序**必须是 created_at, id 两段**：同一毫秒内连发两条时，
    // 只按 created_at 排会让它们的相对顺序由 PG 的实现细节决定 ——
    // 表现为「消息偶尔顺序颠倒」，不报错、也不可复现。
    // `id` 是服务端生成的、单调递增的，用作稳定的 tiebreaker。
    `select * from chat_message
      where relationship_id = $1
      order by created_at, id
      limit $2`,
    [relationshipId, MAX_MESSAGES],
  );
  return { items: rowsToApi(r.rows) };
}

/**
 * 发一条消息（`sendChatMessage`）。
 *
 * 收信人**由关系反推**（见文件头 ③）：关系里我是学生，收信人就是家长；
 * 反之亦然。客户端压根没有指定收信人的机会。
 */
export async function sendChatMessage(client, ctx, body) {
  const relationshipId = String(body?.relationshipId ?? '').trim();
  if (relationshipId === '') throw badRequest('缺少 relationshipId');

  const content = String(body?.content ?? '').trim();
  if (content === '') throw badRequest('消息内容不能为空');
  if (content.length > MAX_CONTENT_LENGTH) {
    throw badRequest(`消息太长（上限 ${MAX_CONTENT_LENGTH} 字）`);
  }

  const relationship = await requireActiveMembership(client, ctx, relationshipId);

  // 我是学生 → 发给家长；我是家长 → 发给学生。
  // 两条都不是的话，`requireActiveMembership` 已经把我挡在外面了。
  const receiverId = relationship.student_id === ctx.userId
    ? relationship.parent_id
    : relationship.student_id;

  const r = await client.query(
    `insert into chat_message (
       id, relationship_id, sender_id, receiver_id, content, created_at, is_read
     ) values ($1, $2, $3, $4, $5, now(), false)
     returning *`,
    [newId(), relationshipId, ctx.userId, receiverId, content],
  );

  // 返回**存下来的那一行**，调用方据此采纳（迁移规则 R2）。
  // 客户端不传 id / createdAt：`insert` 的 allowed keys 里也没有它们，
  // 传了会 400（与照片同一条纪律：认不出的字段要当场报错）。
  return { message: rowToApi(r.rows[0]) };
}

/**
 * 我必须是这段关系的成员，且关系处于 `active`。
 *
 * 查 `relationship` 而不是 `chat_message`：前者是权限的事实来源。
 * 也刻意不在这里 join 别人的消息 —— 读消息由 RLS 兜底，
 * 这里只回答「你能不能进这段对话」。
 *
 * 三种失败（关系不存在 / 我不是成员 / 关系未生效）合并成同一个
 * `forbidden`：对调用方是同一件事「这段对话我进不去」，
 * 而分开报错会把「这条 relationship_id 存不存在」泄露给非成员
 * （枚举面），与 `readHomeworkImageBytes` 的 404 口径一致。
 */
async function requireActiveMembership(client, ctx, relationshipId) {
  const r = await client.query(
    `select id, student_id, parent_id, status
       from relationship
      where id = $1
        and (student_id = $2 or parent_id = $2)`,
    [relationshipId, ctx.userId],
  );

  const row = r.rows[0];
  if (!row) throw notFound('找不到这段对话（或你不在其中）');
  if (row.status !== RELATIONSHIP_ACTIVE) {
    // 关系还没生效（或已被拒绝）：此时对方对我没有任何可见性，
    // 不能靠「先建关系再发消息」绕过结伴确认这件事。
    throw forbidden('结伴关系尚未生效，无法发送消息');
  }
  return row;
}
