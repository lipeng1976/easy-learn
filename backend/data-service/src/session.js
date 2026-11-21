import { randomUUID } from 'node:crypto';

import { tokenExpired, tokenInvalid } from '../../shared/errors.js';

/**
 * 会话：让 token 变成**可以被作废的**凭证。
 *
 * ## S1 的 token 缺什么
 *
 * S1 的 token 是自包含的（验签即可，不用查库），代价是**服务端无法作废它**。
 * 于是三件事做不到：退出登录、改密后把别的设备踢下线、丢了手机立刻失效。
 * 三者根因相同，所以 S2 只加一样东西就够：一张会话表 + 载荷里一个 `sid`。
 *
 * ## 为什么「可吊销」必须真的查库
 *
 * 常见做法是签一个短期 token + 一个长期 refresh token，只在刷新时查库。
 * 那是**另一个取舍**（换来更少的库查询，代价是 access token 过期前依然作废不了），
 * 不是「可吊销」。这里选择每个请求查一次会话 —— 一次主键命中，
 * 换来的是「登出就是登出」这件事真的成立。
 *
 * ## 时序上唯一容易错的一处
 *
 * `expires_at`（库）与 token 的 `exp`（载荷）**必须由同一个时刻算出来**。
 * 两处各算一次的话，会出现「token 还没过期但会话已过期」（客户端按 token_expired
 * 去续签，续回来还是过期）或者反过来的窗口。所以这里由调用方传入 now，
 * 算一次，两边都用它。
 */

/** 一个学习日。比它更长没有意义，比它更短会让每天早上的第一件事变成登录。 */
export const DEFAULT_SESSION_TTL_SECONDS = 12 * 3600;

/** 会话 id 带前缀：日志里一眼能分清它是会话 id 还是用户 id。 */
function newSessionId() {
  return `sess_${randomUUID()}`;
}

/**
 * 新建一个会话。
 *
 * @param {import('pg').PoolClient} client **必须**是鉴权连接（app_auth），
 *   因为登录发生在还没有身份的时刻，RLS 下读不到任何行。
 */
export async function createSession(client, {
  userId,
  ttlSeconds = DEFAULT_SESSION_TTL_SECONDS,
  clientLabel = '',
  now = Date.now(),
}) {
  const id = newSessionId();
  const expiresAt = new Date(now + ttlSeconds * 1000);
  await client.query(
    `insert into user_session (id, user_id, issued_at, expires_at, client)
     values ($1, $2, $3, $4, $5)`,
    [id, userId, new Date(now), expiresAt, String(clientLabel).slice(0, 200)],
  );
  return { id, expiresAt: expiresAt.getTime() };
}

/**
 * 这个会话现在还有效吗。**每次带 token 的请求都会走这里。**
 *
 * 三种失败分别给不同的话，是因为客户端的动作不同：
 * - 不存在 / 已吊销 → `token_invalid` → **重新登录**（续签没有意义，服务端把它删了）；
 * - 已过期 → `token_expired` → 可以走续签流程。
 * 把这两种合成一个码，客户端就会对「已登出的 token」反复续签。
 */
export async function assertSessionActive(client, sessionId, { now = Date.now() } = {}) {
  const sid = String(sessionId ?? '').trim();
  if (sid === '') {
    // 没有 sid 的 token 一律不认。刻意**不留**「老 token 免查库」的兼容分支：
    // 那个分支等于「自己签一个不带 sid 的 token 就能绕过吊销」，把刚加的表一次作废。
    throw tokenInvalid('会话凭证缺少会话标识，请重新登录');
  }

  const r = await client.query(
    `select id, user_id, expires_at, revoked_at, revoke_reason
       from user_session where id = $1`,
    [sid],
  );
  if (r.rowCount === 0) {
    throw tokenInvalid('会话不存在或已被清理，请重新登录');
  }

  const row = r.rows[0];
  if (row.revoked_at !== null) {
    // 把吊销原因带出来：用户看到「你已退出登录」与「密码已修改，请重新登录」
    // 的感受完全不同，后者需要他去别处确认一下是不是自己干的。
    const why = String(row.revoke_reason ?? '');
    throw tokenInvalid(why === ''
      ? '该会话已失效，请重新登录'
      : `该会话已失效（${why}），请重新登录`);
  }
  if (new Date(row.expires_at).getTime() <= now) {
    throw tokenExpired();
  }

  return { sessionId: row.id, userId: row.user_id, expiresAt: new Date(row.expires_at).getTime() };
}

/** 吊销一个会话（登出）。幂等：已经吊销过的不再改 `revoked_at`（保留第一次的时间）。 */
export async function revokeSession(client, { sessionId, reason = '', now = Date.now() }) {
  const r = await client.query(
    `update user_session
        set revoked_at = $2, revoke_reason = $3
      where id = $1 and revoked_at is null
      returning id`,
    [sessionId, new Date(now), String(reason).slice(0, 200)],
  );
  return r.rowCount > 0;
}

/**
 * 把这个用户的**所有**活着的会话一次吊销，返回吊销条数。
 *
 * 用在改密之后。这是「改密」这个动作真正的价值所在 ——
 * 只改库里那一行哈希、把在线的旧设备留着，等于没改：
 * 用户以为自己在处理「有人知道了我的密码」，而那个人手里的 token 还有 12 小时。
 *
 * ⚠️ 调用方要**紧接着签一个新会话**给当前设备，否则用户改完密码自己也被踢了。
 * 那不是安全问题，是纯粹的体验事故，而它一定会被当成 bug 报上来。
 */
export async function revokeAllForUser(client, { userId, reason = '', now = Date.now() }) {
  const r = await client.query(
    `update user_session
        set revoked_at = $2, revoke_reason = $3
      where user_id = $1 and revoked_at is null
      returning id`,
    [userId, new Date(now), String(reason).slice(0, 200)],
  );
  return r.rowCount;
}

/**
 * 清掉早已过期的会话行。
 *
 * 不在这里自动跑：它是一次全表扫描，放在请求路径上迟早变成慢查询。
 * 留给部署侧的定时任务（每天一次足够），所以这里只提供入口。
 */
export async function purgeExpiredSessions(client, { before = Date.now() } = {}) {
  const r = await client.query('delete from user_session where expires_at <= $1', [new Date(before)]);
  return r.rowCount;
}
