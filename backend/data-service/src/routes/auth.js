import { ApiError, ErrorCodes, badRequest, unauthorized } from '../../../shared/errors.js';
import { UserRoles, issueSessionToken } from '../../../shared/token.js';
import { newId, rowToApi, rowsToApi } from '../mapper.js';
import {
  PASSWORD_MAX_LENGTH,
  PASSWORD_MIN_LENGTH,
  hashPassword,
  needsRehash,
  verifyPassword,
} from '../password.js';
import {
  DEFAULT_SESSION_TTL_SECONDS,
  createSession,
  revokeAllForUser,
  revokeSession,
} from '../session.js';

/**
 * 账号与会话端点（S2）。
 *
 * ## 两组 handler，两种连接
 *
 * - `register` / `login` 是**公开**的（`public: true`）：此刻还没有身份，
 *   所以走 `app_auth` 连接 —— RLS 在这里没有可用的身份，查不到任何行。
 * - `logout` / `changePassword` / `me` / `sessions` 是**受保护**的：走应用连接
 *   `app_rls`，于是 `app_user` / `user_session` 的 policy 顺便替我们做了一件事：
 *   **只能改自己那一行**。「改别人密码」这条越权路径不是被 `if` 拦住的，
 *   而是根本不成立 —— 这比在代码里写一个 if 可靠得多。
 *
 * ## 三个容易写错的地方
 *
 * ① **绝不能把 `password_hash` 返回给客户端。** 所有查询都只用下面这份显式列清单，
 *    不是 `select *`。另有一层 `toApiUser` 兜底，测试也会断言响应里没有它 ——
 *    这种事「这次记得删」是不行的，因为它不报错、也不影响功能。
 *
 * ② **「账号不存在」与「密码错误」必须回同一句话、同一个码。**
 *    分开说等于白送一个账号枚举接口（输入手机号即可探测谁在用这个 App）。
 *
 * ③ **改密之后必须吊销全部会话，并立刻给当前设备发一个新 token。**
 *    只改哈希不吊销 = 用户以为处理了「有人知道我密码」，而那人手里的 token
 *    还有 12 小时；吊销了却不补发 = 用户改完密码自己被踢，体验事故。
 *    两件事必须一起做，所以它们写在同一个函数里。
 */

/** 手机号是账号的唯一标识，所以它的**形状**属于服务端校验，不是产品策略。 */
const PHONE_PATTERN = /^1\d{10}$/;

/**
 * 允许自助注册的角色。
 *
 * `teacher` **不在里面**：老师角色是班级功能的完整前置依赖（迁移计划 §10.5），
 * 与建班、审批、权限一道落地。现在开放注册一个还没有任何意义的老师账号，
 * 只会让「这个账号能干什么」变成一句没人答得上来的问题。
 */
export const REGISTERABLE_ROLES = [UserRoles.student, UserRoles.parent];

/**
 * 返回给客户端的用户列。**这份清单是安全边界，不是便利函数。**
 * 添加列之前问一句：客户端真的需要它，还是「顺便带上」？
 *
 * `password_hash` 出现在这里是有意的，但它**只在这一层内部流转**：
 * 下面 `toApiUser` 会把它摘掉，测试也会断言响应体里没有它。
 * 它必须被读出来，因为登录要校验口令；它必须被摘掉，因为客户端永远不该拿到它。
 *
 * 凭证列走 LEFT JOIN 而不是放进 app_user：分表的理由见 sql/004_credential.sql。
 * **LEFT** 不是随手写的 —— 应用连接读不到别人的凭证行（policy 只放自己），
 * 用 INNER JOIN 的话家长看孩子资料会整行查不到，而那不是「看不到密码」，
 * 是「这个人不存在」。少一个字符，语义从「缺一列」变成「缺一行」。
 */
const USER_COLUMNS = `u.id, u.name, u.phone, u.role, u.avatar, u.wechat_open_id,
                      u.gender, u.grade, u.hobbies, u.bio,
                      c.password_hash, c.password_updated_at`;

/** 兜底：万一有人写了 `select *`，这一层把哈希摘掉。 */
function toApiUser(row) {
  const out = rowToApi(row);
  delete out.passwordHash;
  return out;
}

/**
 * 按某个唯一列取一行用户（含凭证列，走 LEFT JOIN）。
 *
 * 公开路径（登录）用 `app_auth` 连接 —— 它带 BYPASSRLS，join 得到哈希；
 * 应用路径（改密 / me）用 `app_rls` 连接 —— 凭证表的 policy 只放自己那一行，
 * 所以 `appUserId` 传别人的 id 时拿到的是 `passwordHash: null`，而不是别人的哈希。
 * **同一个函数、两种连接，安全性由数据库决定**，不由调用方记得传对参数决定。
 */
async function selectUserBy(client, column, value) {
  const r = await client.query(
    `select ${USER_COLUMNS}
       from app_user u
       left join app_user_credential c on c.user_id = u.id
      where ${column} = $1`,
    [value],
  );
  return r.rows[0];
}

/**
 * 下面两个包装函数是**唯一的调用入口**，列名是硬编码的、不来自请求 ——
 * 所以那句模板拼接没有注入面。加一个新的查找维度时也要走这里，
 * 而不是在调用点拼 `where ${body.xxx}`。
 */
export function selectUserByPhone(client, phone) {
  return selectUserBy(client, 'u.phone', phone);
}

export function selectUserById(client, id) {
  return selectUserBy(client, 'u.id', id);
}

/** 每次失败都用同一个句子，见上面 ②。 */
function loginFailed() {
  return unauthorized('手机号、密码或身份不正确');
}

/**
 * 手机号已被占用。
 *
 * 码用 `bad_request`（客户端据此判定「不可重试、要用户改输入」，这是对的），
 * 但 HTTP 状态给 409 —— 它确实是冲突，而不是请求格式不对。
 * 单独放 `details.reason` 而不是新造一个错误码：**错误码是客户端协议**，
 * 加一个码要同步客户端，而这里客户端的行为与其它 bad_request 完全一样。
 */
function phoneTaken() {
  return new ApiError(ErrorCodes.badRequest, '该手机号已注册，请直接登录', {
    status: 409,
    details: { reason: 'phone_taken' },
  });
}

function normalizePhone(raw) {
  const phone = String(raw ?? '').trim();
  if (!PHONE_PATTERN.test(phone)) throw badRequest('请输入有效的11位手机号');
  return phone;
}

function requirePassword(raw) {
  const password = String(raw ?? '');
  if (password.length < PASSWORD_MIN_LENGTH || password.length > PASSWORD_MAX_LENGTH) {
    throw badRequest(`密码长度需为 ${PASSWORD_MIN_LENGTH}-${PASSWORD_MAX_LENGTH} 位`);
  }
  return password;
}

function requireRegisterableRole(raw) {
  const role = String(raw ?? '').trim();
  if (!REGISTERABLE_ROLES.includes(role)) {
    throw badRequest('请选择学生或家长身份');
  }
  return role;
}

/**
 * 一次「假校验」，用来抹平「账号不存在」的时间差。
 *
 * 不这么做的话，「没这个手机号」会比「密码错了」快好几毫秒（少一次 scrypt），
 * 于是接口又变回一个可探测的账号枚举器 —— 只不过从读响应变成了读时钟。
 * 哈希只算一次并缓存：它是常量，每次重算只是白白拖慢失败的登录。
 */
let dummyHashPromise = null;
function dummyHash() {
  dummyHashPromise ??= hashPassword('placeholder-that-never-matches');
  return dummyHashPromise;
}

/**
 * 建会话 + 签 token。三处用到（注册 / 登录 / 改密），所以只写一遍 ——
 * 「token 的 exp 与会话的 expires_at 必须由同一时刻算出」这条约束
 * 只有在只有一处实现时才守得住。
 */
async function startSession(ctx, { userId, role, now }) {
  const { id, expiresAt } = await createSession(ctx.client, {
    userId,
    ttlSeconds: DEFAULT_SESSION_TTL_SECONDS,
    clientLabel: ctx.clientLabel,
    now,
  });
  const token = issueSessionToken({
    secret: ctx.sessionSecret,
    subject: userId,
    role,
    sessionId: id,
    ttlSeconds: DEFAULT_SESSION_TTL_SECONDS,
    now,
  });
  return { token, sessionId: id, expiresAt };
}

// ===== 公开端点（走 app_auth 连接）=====

/**
 * 注册。**成功后直接返回 token**（等于自动登录一次）。
 *
 * 不做「注册 → 提示去登录 → 再输一次密码」：那是两个步骤里插了一个
 * 纯属多余的失败点，而此刻服务端手里正拿着刚验证过的明文口令。
 */
export async function register(ctx, body) {
  const phone = normalizePhone(body?.phone);
  const password = requirePassword(body?.password);
  const role = requireRegisterableRole(body?.role);
  const name = String(body?.name ?? '').trim() || (role === UserRoles.student ? '新学生' : '新家长');
  const now = ctx.now();

  const id = newId();
  const passwordHash = await hashPassword(password);

  try {
    // 账号行与凭证行分两次写，但它们在**同一个事务**里（withAuthTransaction）——
    // 中间失败留下一个「有账号、没密码」的用户，而他既登不进去、也无法重新注册
    // （手机号已被自己占用）。这类半截状态是注册路径上最值钱的一次回滚。
    await ctx.client.query(
      `insert into app_user (id, name, phone, role, avatar)
       values ($1, $2, $3, $4, $5)`,
      // avatar 现在存的是 'student' / 'parent' 这种身份串，不是图片 URL。
      // 将来接自定义头像要加 avatar_url 列，不要塞进这一列（迁移计划 §3.4④）。
      [id, name, phone, role, role],
    );
    await ctx.client.query(
      `insert into app_user_credential (user_id, password_hash, password_updated_at)
       values ($1, $2, $3)`,
      [id, passwordHash, new Date(now)],
    );
  } catch (e) {
    // 唯一索引名就是并发安全的全部答案：不做「先查手机号再插入」——
    // 查与插之间永远有缝，两个同时点的注册会双双通过检查。
    if (e?.code === '23505' && e.constraint === 'uq_user_phone') throw phoneTaken();
    throw e;
  }

  // 回读而不是拿刚插进去的值拼一个对象：
  // 「存进去了什么」必须由数据库回答，拼出来的对象永远是成功的样子。
  const row = await selectUserById(ctx.client, id);
  await recordLogin(ctx, { userId: id, account: phone, method: 'register' });
  const session = await startSession(ctx, { userId: id, role, now });
  return { token: session.token, expiresAt: session.expiresAt, user: toApiUser(row) };
}

/**
 * 登录留痕。调用方必须已经验过账号密码 —— 失败不记（见 030 迁移）。
 *
 * 走 ctx.client（app_auth 连接）而不是新开连接：日志和发 token 在**同一个
 * 事务**里，要么都成功，要么都不留。分开写会留下「日志说登录成功、
 * 但会话没发出来」的幽灵记录。
 */
async function recordLogin(ctx, { userId, account, method }) {
  await ctx.client.query(
    `insert into login_log (id, user_id, account, logged_at, ip, client, method)
     values ($1, $2, $3, $4, $5, $6, $7)`,
    [
      newId(), userId, account, new Date(ctx.now()),
      String(ctx.clientIp ?? '').slice(0, 64),
      String(ctx.clientLabel ?? '').slice(0, 200),
      method,
    ],
  );
}

/**
 * 密码登录。
 *
 * `role` 可选：传了必须与账号一致（客户端登录页要求选身份，这里守住它），
 * 不传就按账号自身身份 —— 让用户在已经知道身份的情况下再选一次，
 * 只会多出一种失败：账号是家长、手滑选了学生，然后被拒，而他并没有做错什么。
 */
export async function login(ctx, body) {
  const phone = String(body?.phone ?? '').trim();
  if (!PHONE_PATTERN.test(phone)) throw loginFailed();
  const password = String(body?.password ?? '');
  const requestedRole = String(body?.role ?? '').trim();
  const now = ctx.now();

  const row = await selectUserByPhone(ctx.client, phone);

  const check = row
    ? await verifyPassword(password, row.password_hash)
    : await verifyPassword(password, await dummyHash());

  if (!row || !check.ok || (requestedRole !== '' && row.role !== requestedRole)) {
    if (check.reason === 'malformed') {
      // 数据坏了（或还是历史明文行）—— 这是服务端的问题，值得留一条线索。
      // 但**对客户端的回复必须与「密码错」一字不差**（见文件头 ②）。
      console.error(`[auth] 账号 ${row?.id} 的口令存储不是合法哈希，无法校验`);
    }
    throw loginFailed();
  }

  // 登录是唯一持有明文的时刻，顺手把旧参数的哈希升级掉。
  // 不做这件事的话，调高 scrypt 参数只对新账号生效 ——
  // 而老账号恰恰是存在最久、最可能已经泄露的那些。
  if (needsRehash(row.password_hash)) {
    await ctx.client.query(
      'update app_user_credential set password_hash = $2 where user_id = $1',
      [row.id, await hashPassword(password)],
    );
  }

  await recordLogin(ctx, { userId: row.id, account: phone, method: 'password' });
  const session = await startSession(ctx, { userId: row.id, role: row.role, now });
  return { token: session.token, expiresAt: session.expiresAt, user: toApiUser(row) };
}

// ===== 受保护端点（走应用连接 app_rls，policy 保证只能碰自己）=====

/**
 * 登出：吊销**当前这一个**会话。
 *
 * 只吊销自己，不吊销该用户的所有会话 —— 「我在平板上退出」不该把手机也踢下线。
 * 要全部下线是「改密」的语义，两者刻意分开。
 *
 * 幂等：重复调用返回 `revoked: false` 而不是报错。客户端重试或用户手快连点
 * 两次时，正确的答案是「这个会话确实已经不活跃了」，而不是一个错误。
 */
export async function logout(client, ctx, body) {
  const reason = String(body?.reason ?? '').trim() || '用户退出登录';
  const revoked = await revokeSession(client, {
    sessionId: ctx.sessionId,
    reason,
    now: ctx.now(),
  });
  return { revoked, sessionId: ctx.sessionId };
}

/**
 * 改密。见文件头 ③：**吊销全部会话 + 补发一个新 token**，两件事一起做。
 *
 * 越权面为零的原因不在本函数里：`app_user` 的 policy 是 `id = app.user_id`，
 * 所以下面那句 `select … where id = $1` 无论如何都只能取到调用者自己那一行。
 * 这不是「相信 ctx.userId 来自 token」—— 是数据库再确认了一次。
 */
export async function changePassword(client, ctx, body) {
  const currentPassword = String(body?.currentPassword ?? '');
  const newPassword = requirePassword(body?.newPassword);
  if (currentPassword === '') throw badRequest('请输入当前密码');
  if (currentPassword === newPassword) throw badRequest('新密码不能与当前密码相同');

  const row = await selectUserById(client, ctx.userId);
  if (!row) {
    // 会话有效但账号没了（被删号？）。这是账号生命周期的问题，不是权限问题。
    throw unauthorized('账号不存在或已被停用，请重新注册');
  }

  const check = await verifyPassword(currentPassword, row.password_hash);
  if (!check.ok) throw unauthorized('当前密码不正确');

  const now = ctx.now();
  // 两个字段分处两张表，但同在**一个事务**里 —— 哈希换了而时间戳没换，
  // 会让 `passwordUpdatedAt` 这个「凭证是什么时候设的」失去意义。
  await client.query(
    `update app_user_credential
        set password_hash = $2, password_updated_at = $3
      where user_id = $1`,
    [ctx.userId, await hashPassword(newPassword), new Date(now)],
  );

  // 先全量下线，再给当前设备补一个新的 —— 顺序不能反，
  // 否则新会话会被紧随其后的全量吊销一起干掉。
  const revokedSessions = await revokeAllForUser(client, {
    userId: ctx.userId,
    reason: '密码已修改',
    now,
  });
  // 受保护路径的 ctx 里没有 `client`（它是 handler 的第一个参数），
  // 而 `startSession` 要用它写会话行 —— 所以在这个调用点把两半合起来。
  const session = await startSession(
    { client, sessionSecret: ctx.sessionSecret, clientLabel: ctx.clientLabel },
    { userId: ctx.userId, role: row.role, now },
  );

  const updated = await selectUserById(client, ctx.userId);
  return {
    token: session.token,
    expiresAt: session.expiresAt,
    revokedSessions,
    user: toApiUser(updated),
  };
}

/** 当前身份。客户端启动时用它确认「手里这个 token 还能用」。 */
export async function me(client, ctx) {
  const row = await selectUserById(client, ctx.userId);
  return {
    user: toApiUser(row ?? null),
    session: { id: ctx.sessionId, role: ctx.role },
  };
}

/**
 * 列出自己的活跃会话（登录设备）。
 *
 * 这张表能查得到，是因为 `user_session` 的 policy 也是 `user_id = app.user_id` ——
 * 家长看不到孩子的登录会话。那不是业务数据，是账号安全信息，
 * 让家长能「登出孩子的所有设备」听起来方便，实则是一次没说出口的越权。
 */
export async function listSessions(client, ctx) {
  const r = await client.query(
    `select id, issued_at, expires_at, client
       from user_session
      where user_id = $1 and revoked_at is null
      order by issued_at desc
      limit 50`,
    [ctx.userId],
  );
  return {
    items: rowsToApi(r.rows).map((x) => ({ ...x, current: x.id === ctx.sessionId })),
  };
}
