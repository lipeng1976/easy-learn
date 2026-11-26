import pg from 'pg';

import { UserRoles } from '../../shared/token.js';
import { dbUnavailable, internal } from '../../shared/errors.js';
import { RELATIONSHIP_ACTIVE } from './vocab.js';

/**
 * 连接池与「请求上下文」。
 *
 * ## 这个文件里最关键的一件事：身份只能活在事务里
 *
 * RLS 的 policy 靠 `current_setting('app.visible_students')` 判断可见性。
 * 而**连接池会复用连接** —— 如果用会话级的 `SET`，下一个请求会继承
 * 上一个人的身份，症状是「A 偶尔能看到 B 的数据」，且**单请求测试永远串不出来**。
 *
 * 所以这里只有一条路：每个请求开一个事务，用 `SET LOCAL`（= `set_config(..., true)`）
 * 设置身份，事务一结束自动失效。SET 与业务查询必须在同一个 transaction 里。
 *
 * 用 `set_config()` 而不是拼 `SET LOCAL xxx = '...'`：后者要把用户 id 拼进 SQL，
 * 而 visible_students 是个列表 —— 拼接就是注入口子。
 *
 * ## 三条连接，三个身份
 *
 * - **应用连接**用 `app_rls` 角色（非 superuser、非表 owner）→ RLS 生效
 * - **运维连接**用 postgres 超级用户 → 刻意绕过 RLS（迁移、对账、后台统计）
 * - **鉴权连接**用 `app_auth` 角色（S2）→ 只碰 `app_user` / `user_session` 两张表。
 *   它存在的理由是**注册和登录发生在还没有身份的时刻**，而 app_rls 的 policy
 *   全部依赖 `current_setting('app.user_id')` —— 没有身份就读不到任何行，
 *   连「这个手机号注册过没有」都答不出来。
 *   它确实绕过了 RLS（BYPASSRLS），但**越权面被权限收口锁死在两张账号表上**：
 *   业务表一行权限都没有，写错就 `permission denied`，而不是静默读到全部数据。
 *   这条不变式由 `assertAuthRoleScoped()` 断言，**不做人工检查**。
 *
 * ⚠️ 拿超级用户当应用账号连库，整套 RLS 会**静默失效**：不报错、不警告，
 * 查询照常返回全部行。所以启动时跑一次 `assertRlsEnforced()`，宁可起不来也不要裸奔。
 */

/**
 * pg 默认把 `numeric` 返回成**字符串**（为了不丢精度），于是
 * `estimated_minutes` 会以 `"30.00"` 的形式到客户端，而客户端要的是数字
 * （`as double` 会直接抛类型错误）。
 *
 * 在这里统一转成 number：这个应用里的 numeric 只有「课时长」和「通过率」两类，
 * 都不涉及金额，double 的精度绰绰有余。真出现金额字段时再单独处理那个列，
 * 不要因为一个字段把所有 numeric 恢复成字符串。
 */
pg.types.setTypeParser(pg.types.builtins.NUMERIC, (v) => (v === null ? null : Number(v)));

/**
 * `PGSSLMODE` → pg 的 `ssl` 选项。
 *
 * ## 为什么需要它
 *
 * 云上的托管 PostgreSQL（RDS 之类）常常**只接受 TLS 连接**。少了这一项，
 * 数据服务连不上库，而报错是驱动给的 `no pg_hba.conf entry for host ...,
 * no encryption` —— 看起来像白名单没放行，于是会去查安全组，查半天。
 *
 * ## 为什么只实现两个取值
 *
 * libpq 的 `PGSSLMODE` 有六个取值，其中 `allow` / `prefer` 的语义是
 * 「先试加密、不行就退回明文」—— 那需要一个**可用的降级路径**，而
 * 「悄悄退回明文」恰恰是运维最不希望发生的事（以为在加密，其实没有）。
 * `verify-ca` / `verify-full` 要挂 CA 证书文件，本服务没有实现。
 *
 * 所以：
 *   · `disable`（默认，保持原有行为，本机开发不受影响）
 *   · `require`     加密，**不校验证书链** —— 这就是 libpq `require` 的语义，
 *                   也是云厂商用自签 CA 时的常见形态
 *   · 其余取值**直接抛错**，而不是按 `require` 处理。
 *
 * 最后一条是关键：把 `verify-full` 当成 `require` 放过，会得到一个
 * 「配置里写着要校验、实际一次都没校验」的状态，从外部完全看不出来。
 * 这正是本项目反复踩的那类失败，所以宁可让冷启动炸掉。
 */
export function sslOption(raw = process.env.PGSSLMODE) {
  const mode = String(raw ?? '').trim().toLowerCase();
  if (mode === '' || mode === 'disable') return undefined;
  if (mode === 'require') return { rejectUnauthorized: false };
  throw new Error(
    `PGSSLMODE=${mode} 本服务不支持（只实现 disable / require）：`
      + 'allow 与 prefer 要求「加密失败就退回明文」，verify-ca 与 verify-full 要求挂 CA 证书 ——'
      + '两件事本服务都没做。**故意不把它当成 require 悄悄放过**：'
      + '那会得到一个「配置写着要校验、实际没校验」的状态。',
  );
}

/** 应用侧连接池。生产环境请在它前面放 PgBouncer / RDS Proxy（见迁移计划 §4）。 */
export function createPool(options = {}) {
  const config = options.connectionString
    ? { connectionString: options.connectionString }
    : {
        host: options.host ?? process.env.PGHOST ?? '127.0.0.1',
        port: Number(options.port ?? process.env.PGPORT ?? 5432),
        user: options.user ?? process.env.PGUSER ?? 'app_rls',
        password: options.password ?? process.env.PGPASSWORD ?? undefined,
        database: options.database ?? process.env.PGDATABASE ?? 'easy_learn',
      };

  const ssl = options.ssl ?? sslOption();

  const pool = new pg.Pool({
    ...config,
    ...(ssl ? { ssl } : {}),
    // Serverless 下每个实例都是自己的池，实例数 × max 会一起打向数据库。
    // 默认给 5，生产靠 PgBouncer 收敛。这个数字要在 S1 就定下来，
    // 别等并发上来才发现连接数打满 —— 那时排查方向会被「接口变慢」带偏。
    max: Number(options.max ?? process.env.PG_POOL_MAX ?? 5),
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
  });

  /**
   * **一条空闲连接出问题，不能让整个进程退出。**
   *
   * pg-pool 把客户端上的错误转成池对象上的 `error` 事件，而 Node 对没有监听者的
   * `error` 事件的处理方式是**抛出去**。于是「一条空闲连接被回收」会升级成
   * 「数据服务进程消失」——现场只剩 `throw er; // Unhandled 'error' event`
   * 加一句 `Connection terminated unexpectedly`，而后面的表现全都变了样：
   * 走查里「服务端收不到请求」看起来像客户端的问题
   * （2026-09-20 本机演示栈两次走到一半断掉，都是这个形状）。
   *
   * 触发原因可以有很多（数据库重启、网络中断、中间设备回收空闲连接、云上的
   * idle timeout），这里要做的**不是猜原因**，而是把它降级成一条日志：
   * 池会丢掉坏连接，下一个请求自动重建。请求失败是诚实的（500），
   * 进程消失则会把后面所有判断一起带偏。
   */
  pool.on('error', (err) => {
    console.error(`[db] 空闲连接出错（已丢弃，下一个请求会重建连接）：${err.message}`);
  });

  return pool;
}

/**
 * 哪些「借不到连接」是**瞬时**的，值得等一等。
 *
 * 分这两类不是为了精致，是因为处置相反：
 * 瞬时 → 等一下就好了，报错等于把一次抖动推给用户；
 * 永久（口令错、库不存在、主机名写错）→ 等一下**永远不会**好，
 * 重试只会把一次配置错误表现成「服务很慢」，还白占一个请求的时间。
 *
 * 右边那些**消息**而不是错误码的条目，全部来自实测 —— 它们在 pg 里
 * 没有可用的 code，只以文案区分（2026-09-20 本机演示栈上真实打印出来的）：
 *   · `the database system is in recovery mode` —— PG 后端崩过之后在做恢复
 *   · `Connection terminated due to connection timeout` —— 连上之前就断了
 *   · `could not open file "base/…": Permission denied` —— 崩溃恢复期间
 *     重新打开关系文件撞上文件锁（Windows 上常见于杀软实时扫描）
 * 前两条是**教科书级的瞬时**：`57P03 cannot_connect_now` 的文档原话就是
 * 「数据库正在启动」，标准做法就是等一下再来。
 */
const TRANSIENT_CONNECT_CODES = new Set([
  'ECONNREFUSED', // 服务刚重启，还没开始监听
  'ECONNRESET', // 连接被对端掐断
  'ETIMEDOUT',
  'EPIPE',
  'EHOSTUNREACH',
  'ENETUNREACH',
  'EAI_AGAIN', // 临时 DNS 失败。注意与 ENOTFOUND（主机名根本不存在）不同
  '57P01', // admin_shutdown
  '57P02', // crash_shutdown
  '57P03', // cannot_connect_now（正在启动 / 正在恢复）
]);

const TRANSIENT_CONNECT_MESSAGE = /in recovery mode|starting up|shutting down|could not connect|connection terminated|connection timeout|could not open file/i;

/** 见 [TRANSIENT_CONNECT_CODES]。 */
export function isTransientConnectError(e) {
  if (TRANSIENT_CONNECT_CODES.has(e?.code)) return true;
  return TRANSIENT_CONNECT_MESSAGE.test(String(e?.message ?? ''));
}

/**
 * 借一条连接，**瞬时故障就等到等不动为止**。
 *
 * ## 为什么值得重试，而不是直接报「数据库暂时无法连接」
 *
 * 池里的空闲连接会**被别人掐断**——数据库重启、网络抖动、中间设备回收空闲连接、
 * 云上的 idle timeout，全都算。掐断的那一刻，池手上就有几条**已经死了但还没被察觉**
 * 的连接：下个请求拿到它，`connect()` 当场失败。
 *
 * 而这个失败一路上去就变成用户看到的句子。它的问题是**说得太重**：
 * 听起来是一次故障，实际通常是一次几百毫秒的抖动，再借一条就好了。
 *
 * 本机演示栈上的形状更极端，也更值得把预算给够（2026-09-20 实测）：
 * PG 的一个后端崩掉 → 其余后端被连带终止 → postmaster 进**崩溃恢复**。
 * 那几秒里每一次借连接都被拒（`in recovery mode`），而它自己会好 ——
 * 固定「重试 2 次、间隔 150ms」根本等不到恢复完，于是家长端登录被拒，
 * **一次数据库崩溃的代价被记在了登录功能头上**。
 *
 * ## 重试在这里是安全的，而且理由很具体
 *
 * 重试的是**「拿到一条连接」**，不是在途的语句。`pool.connect()` 失败意味着
 * **一句话都还没发出去**，所以不存在「重试把同一笔写做了两遍」的可能。
 * 这一点决定了它能放在 `withRequestContext` 这种会写库的路径上 ——
 * 换成「重试整个事务」就得先证明每个写都幂等，那是另一件事。
 *
 * 等待有**上界**（默认 5 秒，`PG_CONNECT_RETRY_BUDGET_MS` 可调）：
 * 抖动与短暂的恢复被吃掉，真故障照旧如实报出来，不会把「库真的没了」
 * 拖成一次看不到头的等待。
 */
async function connectWithRetry(pool, { onRetry } = {}) {
  // 环境变量在**调用时**读，不在模块加载时读：这样测试与运维都能改，
  // 而模块级常量读取会让「先 import 再设 env」静默失效。
  const budgetMs = Number(process.env.PG_CONNECT_RETRY_BUDGET_MS ?? 5000);
  const maxAttempts = Number(process.env.PG_CONNECT_RETRY_MAX ?? 8);
  const deadline = Date.now() + budgetMs;

  let delay = 100;
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await pool.connect();
    } catch (e) {
      // 永久的失败立刻抛：等下去不会变好，只会把它表现成「服务慢」。
      const worthRetrying = isTransientConnectError(e)
        && attempt < maxAttempts
        && Date.now() + delay <= deadline;
      if (!worthRetrying) throw e;
      onRetry?.(attempt, e, delay);
      await new Promise((r) => setTimeout(r, delay));
      delay = Math.min(delay * 2, 800); // 指数退避，封顶 800ms
    }
  }
}

/** 借连接失败时的同一条日志：它是**抖动被吃掉了**的唯一痕迹。 */
const warnConnectRetry = (i, e, waitMs) => console.warn(
  `[db] 借连接失败（第 ${i} 次，等 ${waitMs}ms 再试）：${e.message}`,
);

/**
 * 数据库**拒绝**了这条连接 —— 这是部署配置错了，不是抖动。
 *
 * 与 [isTransientConnectError] 是同一件事的两面：判据分开，处置才分得开。
 * 全都报成「数据库暂时无法连接」的代价很具体：运维看到「暂时」就会等它自己好，
 * 而口令配错、库名写错**永远不会**自己好；客户端还会一直带着退避重试。
 * 这与 `modelNotEnabled` 刻意不设可重试是同一条理由 ——
 * 让配置问题表现成偶发故障，会把排查方向整个带偏。
 *
 * `ENOTFOUND`（主机名不存在）在这里：它与 `EAI_AGAIN`（临时 DNS 解析失败）
 * 长得像，处置相反。
 */
const PERMANENT_CONNECT_CODES = new Set([
  '28P01', // invalid_password
  '28000', // invalid_authorization_specification
  '3D000', // invalid_catalog_name（库不存在）
  'ENOTFOUND',
]);

/**
 * 把「借不到连接」翻译成给用户/客户端的说法。三路，默认走保守的那一路。
 */
function connectFailure(e) {
  if (isTransientConnectError(e)) return dbUnavailable('数据库暂时无法连接', { cause: e });
  if (PERMANENT_CONNECT_CODES.has(e?.code)) {
    return internal(`数据库拒绝了连接（配置问题，重试无用）：${e.message}`, {
      retryable: false,
      cause: e,
    });
  }
  // 认不出来的失败按可重试的 503 报：宁可多给一次机会，
  // 也不要把一次本来能好的失败说成终局。
  return dbUnavailable('数据库暂时无法连接', { cause: e });
}

/**
 * 启动自检：确认应用连接**真的**受 RLS 约束。
 *
 * 这是「静默失效」类问题里最值得用代码挡住的一个 ——
 * 它不会以报错的形式出现，只会表现为「隔离根本没生效」。
 */
export async function assertRlsEnforced(pool) {
  const r = await pool.query(
    `select current_user as u, rolsuper, rolbypassrls
       from pg_roles where rolname = current_user`,
  );
  const row = r.rows[0];
  if (!row) throw new Error('无法确认当前数据库角色');
  if (row.rolsuper) {
    throw new Error(
      `应用连接用的是超级用户 ${row.u} —— 超级用户永远绕过 RLS（连 FORCE 也拦不住），`
        + '隔离会静默失效。请改用 app_rls 这类普通角色连接。',
    );
  }
  if (row.rolbypassrls) {
    throw new Error(`角色 ${row.u} 带 BYPASSRLS，隔离不会生效。`);
  }
  return row.u;
}

/**
 * 在一个事务里执行 fn，事务内带上请求身份。
 *
 * @param {object} identity
 * @param {string} identity.userId 来自 token 的 sub，**不是客户端自报的**
 * @param {string} identity.role   来自 token，见 UserRoles
 * @param {string} identity.sessionId 来自 token 的 sid（S2）：登出与改密要用它
 * @param {(client: pg.PoolClient, ctx: {
 *   userId: string, role: string, sessionId?: string, visibleStudents: string[],
 * }) => Promise<any>} fn
 */
export async function withRequestContext(pool, identity, fn) {
  const { userId, role, sessionId } = identity;
  let client;
  try {
    client = await connectWithRetry(pool, { onRetry: warnConnectRetry });
  } catch (e) {
    throw connectFailure(e);
  }

  try {
    await client.query('begin');

    // 第一步：先把「我是谁」放进事务。此时 visible_students 还是空的。
    await client.query('select set_config($1, $2, true)', ['app.user_id', userId ?? null]);
    await client.query('select set_config($1, $2, true)', ['app.visible_students', '']);

    // 第二步：算出「我能看哪些学生」，再写进事务。
    //
    // 这里有个先有鸡还是先有蛋的问题：算集合本身要查 relationship 表，
    // 而那是一次受 RLS 约束的查询。解法是 relationship 的 policy 除了
    // `student_id = ANY(visible_students)`，还放行 `parent_id = app.user_id` ——
    // 所以「未设集合、已设 user_id」的这一刻，家长恰好能读到自己的关系行。
    const visibleStudents = await resolveVisibleStudents(client, userId, role);
    await client.query('select set_config($1, $2, true)', [
      'app.visible_students',
      visibleStudents.join(','),
    ]);

    // ctx 必须带上 userId / role，而不只是 visibleStudents ——
    // 「谁在写」本身就是业务数据（如 point_ledger.created_by）。
    // 漏掉的症状不是查询出错，而是写入时撞上 NOT NULL：
    // `null value in column "created_by" violates not-null constraint`。
    // 那条约束在这里帮了忙 —— 它把「身份没传下来」当场暴露，
    // 而不是静默写进一条没有创建者的记录、等到对账时才发现。
    const out = await fn(client, { userId, role, sessionId, visibleStudents });
    await client.query('commit');
    return out;
  } catch (e) {
    // 回滚失败不该盖掉原始错误 —— 原始错误才是排查的入口。
    await client.query('rollback').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

/**
 * 「这个请求能看哪些学生」。
 *
 * 三个来源，本期只实现前两个：
 *   ① 学生本人（student_id 与 app_user.id 是**同一套 id**）
 *   ② 家长 `active` 状态的孩子（关系已成立才算，词见 `vocab.js`）
 *   ③ 老师自己班上的学生 —— **本期不实现**（没有建班角色，见迁移计划 §10.5）
 *
 * ③ 的位置留在这里是有意的：老师接入时只加一个分支，
 * 而 RLS 的 policy **一行都不用改**，因为它只认「集合」不认「角色」。
 *
 * ## 下面那个状态词是「要不要隐藏数据」的开关
 *
 * `status = $2` 直接决定家长能不能看见自己的孩子。它最危险的性质是
 * **写错不报错**：词写错（或库里的词没跟着迁移）只会让这个查询返回 0 行，
 * 于是 RLS 收到一个空集合，家长端显示「尚未与任何学生结伴」——
 * 看起来像结伴失败，实际是可见集合算空了。
 * 所以它从 `vocab.js` 取而不是就地写字面量；数据侧的另一半在
 * `sql/007_status_vocab_active.sql`。
 */
export async function resolveVisibleStudents(client, userId, role) {
  if (role === UserRoles.student) return [userId];
  if (role === UserRoles.parent) {
    const r = await client.query(
      `select student_id from relationship
        where parent_id = $1 and status = $2
        order by student_id`,
      [userId, RELATIONSHIP_ACTIVE],
    );
    return r.rows.map((x) => x.student_id);
  }
  if (role === UserRoles.teacher) {
    // 预留：将来这里查 classroom_member（owner 是自己班的）。
    return [];
  }
  return [];
}

/**
 * `app_auth` 被允许触碰的表。**这是一份白名单，加表要先想清楚为什么。**
 *
 * 加一张表的代价不是「多一行 GRANT」，而是「那张表从此不受 RLS 保护」。
 * 而它不会表现为任何症状 —— 除非有人去读全量数据，否则一切如常。
 * 所以 `assertAuthRoleScoped()` 会在启动时逐张业务表断言 app_auth 无权限，
 * 让「顺手补一句 GRANT ALL TABLES」这件事当场变成启动失败。
 */
export const AUTH_ROLE_TABLES = ['app_user', 'app_user_credential', 'user_session', 'login_log'];

/**
 * 借一条鉴权连接执行一段逻辑，**不开事务**。
 *
 * 给「只查一次」的路径用：会话校验（每个带 token 的请求都走）。
 * 那里开事务要多两个网络往返（begin / commit），而它做的事只是
 * 「这个 sid 还活着吗」—— 一次主键查询，没有需要原子性的第二句话。
 */
export async function withAuthConnection(pool, fn) {
  let client;
  try {
    client = await connectWithRetry(pool, { onRetry: warnConnectRetry });
  } catch (e) {
    throw connectFailure(e);
  }
  try {
    return await fn(client);
  } finally {
    client.release();
  }
}

/**
 * 用**鉴权连接**在事务里执行一段逻辑（注册 / 登录 / 改密）。
 *
 * 与 `withRequestContext` 的关键区别：**不设置任何身份**。
 * 这不是遗漏 —— 调用它的场景本来就没有身份（还没登录），
 * 而 app_auth 的 BYPASSRLS 让「无身份」也能正常读写那两张账号表。
 *
 * 用事务而不是裸连接：注册要**同时**写 `app_user` 和 `user_session`，
 * 中间失败留下一个「账号建好了但没有会话」的状态 —— 用户看到的是
 * 「注册成功了，然后请登录」，而他刚刚才注册过。
 */
export async function withAuthTransaction(pool, fn) {
  return withAuthConnection(pool, async (client) => {
    try {
      await client.query('begin');
      const out = await fn(client);
      await client.query('commit');
      return out;
    } catch (e) {
      await client.query('rollback').catch(() => {});
      throw e;
    }
  });
}

/**
 * 启动自检：确认鉴权连接的**越权面真的被收口了**。
 *
 * 这是与 `assertRlsEnforced()` 同一族的第二道闸 —— 它们防的是同一类问题：
 * **安全机制静默失效**。区别只是失效方式不同：
 *   · app_rls 用超级用户连 → RLS 不生效（该挡的挡不住）；
 *   · app_auth 被多授权 → 一片表不受隔离（该关的没关）。
 *
 * 两者都不会报错、不会有症状，只会在某天变成一次数据泄露。
 * 所以两处都用**断言**，而不是「记得检查一下」。
 *
 * 实现上用 `pg_class` 而不是 `information_schema.tables` 取表清单：
 * **后者只列当前角色有权限的表**，而这正是我们要审查的对象 ——
 * 用它做审查会得出「一张业务表都没有，完美」的荒谬结论。
 */
export async function assertAuthRoleScoped(pool) {
  const who = await pool.query(
    `select current_user as u, rolsuper, rolbypassrls
       from pg_roles where rolname = current_user`,
  );
  const role = who.rows[0];
  if (!role) throw new Error('无法确认鉴权连接的角色');
  if (role.rolsuper) {
    throw new Error(
      `鉴权连接用的是超级用户 ${role.u} —— 它不只绕过 RLS，还能读改任何表，`
        + '「只碰两张表」的收口完全不存在。请改用 app_auth 这类受限角色。',
    );
  }

  const r = await pool.query(
    `select c.relname,
            has_table_privilege(current_user, c.oid, 'SELECT') as can_select,
            has_table_privilege(current_user, c.oid, 'INSERT') as can_insert,
            has_table_privilege(current_user, c.oid, 'UPDATE') as can_update,
            has_table_privilege(current_user, c.oid, 'DELETE') as can_delete
       from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r'
      order by c.relname`,
  );

  const allowed = new Set([...AUTH_ROLE_TABLES, 'schema_migrations']);
  const leaked = r.rows
    .filter((x) => !allowed.has(x.relname))
    .filter((x) => x.can_select || x.can_insert || x.can_update || x.can_delete)
    .map((x) => x.relname);

  if (leaked.length > 0) {
    throw new Error(
      `鉴权角色 ${role.u} 多出了这些表的权限：${leaked.join('、')}。`
        + '它带 BYPASSRLS，多一张表就多一片不受隔离的数据（症状：无）。'
        + '请从 sql/003_session.sql 的 GRANT 里移除它们，或改用应用连接 app_rls。',
    );
  }

  const have = new Set(r.rows.map((x) => x.relname));
  const missing = AUTH_ROLE_TABLES.filter((t) => !have.has(t));
  if (missing.length > 0) {
    throw new Error(
      `鉴权角色 ${role.u} 缺少这些表：${missing.join('、')} —— 注册与登录会全线失败。`,
    );
  }

  // login_log 虽然进了白名单，但它带 BYPASSRLS：**只准 INSERT**。
  // 一旦有人给 app_auth 补了 SELECT/UPDATE/DELETE，未登录的连接就能
  // 读改所有账号的登录历史，而功能测试全绿、没有任何症状。
  const logPriv = r.rows.find((x) => x.relname === 'login_log');
  if (logPriv && (logPriv.can_select || logPriv.can_update || logPriv.can_delete)) {
    throw new Error(
      `鉴权角色 ${role.u} 对 login_log 多出了 SELECT/UPDATE/DELETE 权限 —— `
        + '它带 BYPASSRLS，能读到所有人的登录历史。030 迁移只该 GRANT INSERT。',
    );
  }

  return role.u;
}

/** 把连接池的异常翻译成有语义的 ApiError，别让它变成一句「内部错误」。 */
export function translateDbError(e) {
  // 23505 = 唯一约束冲突。部分唯一索引命中时也是这个码，
  // 幂等写入要据此回查原记录（见 routes/points.js）。
  if (e?.code === '23505') return e;
  // 42P10 = ON CONFLICT 的推断没匹配到唯一索引。
  // 这个错误的成因很隐蔽（部分索引必须把 WHERE 谓词带上），单独给一条可读信息。
  if (e?.code === '42P10') {
    return internal(
      `ON CONFLICT 未匹配到唯一索引：${e.message}。`
        + '对部分唯一索引，冲突目标必须带上原样谓词，例如 '
        + "ON CONFLICT (idempotency_key) WHERE idempotency_key <> '' AND reversed_at IS NULL",
    );
  }
  if (['ECONNREFUSED', 'ETIMEDOUT', 'ENOTFOUND', '57P01', '57P03'].includes(e?.code)) {
    return dbUnavailable('数据库暂时不可用，请稍后重试', { cause: e });
  }
  return e;
}
