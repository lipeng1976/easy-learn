-- 伴学 APP 数据服务 —— S2 账号与会话
--
-- 本文件回答一个问题：**S1 的 token 为什么不够用。**
--
-- S1 的 token 是「签名 + 明文载荷」的无状态自包含凭证，验签就完事。
-- 它能挡住「改学号冒充别人」，但挡不住三件事：
--   ① **退出登录** —— 没有服务端状态，签出去的 token 在过期前一直有效；
--   ② **改密后旧设备还在线** —— 用户改了密码，另一台设备照样能用老 token 读数据；
--   ③ **踢设备** —— 手机丢了，除了等 12 小时过期没有别的办法。
-- 三个症状的根都是同一件事：**服务端无法作废一个凭证**。
--
-- 所以 S2 加一张会话表，token 载荷里多一个 `sid`：
--   token 依然自包含（验签不用查库、便宜），但**验签之后必须再查一次会话是否还活着**。
--   代价是每个请求多一次主键查询 —— 这是「可吊销」唯一诚实的价格，
--   写成「加了张表但不用查」就等于没加。
--
-- 执行方式：由 src/migrate.js 在事务内按文件名顺序执行，本文件**不要自带 BEGIN/COMMIT**。

-- ===== 1/2 会话表 =====
--
-- 只存**会话本身**，不存 token 的字节 —— 存了它也无非是把「谁持有凭证」
-- 复制成两份，泄露面反而变大。吊销靠 `revoked_at`，客户端手里那个 token 变成废纸。
--
-- `revoke_reason` 不是给人看的备注：它区分「用户主动登出」与「改密导致的全量下线」。
-- 客户端提示文案不同（前者正常，后者要说「密码已修改，请重新登录」），
-- 且排查「我怎么被登出了」时，这一列就是答案。
--
-- `client` 由调用方传入（S2 由客户端 UA 摘要），本期只写不读 ——
-- 它存在的理由是：「列出登录设备」这个功能迟早要有，而这一列必须在
-- **第一次发 token 的时候**就开始写。等要用了才加，历史会话全是空的。
CREATE TABLE user_session (
  id            TEXT PRIMARY KEY,
  user_id       TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  issued_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at    TIMESTAMPTZ NOT NULL,
  revoked_at    TIMESTAMPTZ,
  revoke_reason TEXT NOT NULL DEFAULT '',
  client        TEXT NOT NULL DEFAULT ''
);

-- 部分索引：查「这个用户还有几个活着的会话」是最常见的查询
-- （登出、改密全量下线、/auth/sessions 列表），而历史会话会一直堆着。
CREATE INDEX idx_user_session_alive ON user_session(user_id) WHERE revoked_at IS NULL;

-- ===== 2/2 应用侧 RLS =====
--
-- 形状与前 22 张表**保持一致**（`某归属列 = ANY(visible_students)` 的同族）：
-- 会话的归属列就是 user_id，而「看自己」用 `app.user_id` 表达。
--
-- 注意这里**没有** `OR user_id = ANY(visible_students)`：
-- 家长不该看到孩子的登录会话 —— 那是账号安全信息，不是业务数据。
-- 一个家长能「登出孩子的所有设备」听起来方便，实则是一次没说出口的越权。
ALTER TABLE user_session ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_session FORCE ROW LEVEL SECURITY;

CREATE POLICY session_own ON user_session
  USING (user_id = current_setting('app.user_id', true))
  WITH CHECK (user_id = current_setting('app.user_id', true));

-- ===== 鉴权角色 app_auth =====
--
-- ## 为什么必须再开一个角色
--
-- 注册和登录发生在**还没有身份**的时刻，而 app_rls 的 policy 全部依赖
-- `current_setting('app.user_id')`。没有身份 → 读不到任何 app_user 行 →
-- 连「这个手机号注册过没有」都答不出来。业务表能靠「先有身份」活着，
-- 账号表不能，这是它结构上的特殊性。
--
-- ## 为什么不干脆让 app_rls 也 BYPASSRLS
--
-- 那样整个隔离层一次性作废（§10.2 的 R7 就是为这件事定的）。
-- 这里给的是**一个能力被严格限制的角色**：
--   · `BYPASSRLS` —— 只在 app_user / user_session 上有意义；
--   · **只 GRANT 这两张表** —— 业务表一行权限都没有。
--
-- 两条合起来的效果是：**越权面 = 账号表本身**。哪怕将来有人在 auth 路由里
-- 写错一句 SQL 去查作业，得到的是一句 `permission denied for table homework`
-- —— 当场炸，而不是静默读到全部数据。
--
-- 这个不变式由 `assertAuthRoleScoped()` 在启动时断言（services/src/db.js）：
-- 它会去 information_schema 里逐张业务表确认 app_auth 无权限。
-- **不做人工检查** —— 这类「静默失效」的问题，人眼看不出来。
--
-- ⚠️ 另一个顺序陷阱：`ALTER DEFAULT PRIVILEGES`（002 文件里那一句）只作用于
-- app_rls，所以本文件新建的 user_session 对 app_auth 不会自动获得权限 ——
-- 这正是我们要的，下面的 GRANT 是显式的、可审计的。
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'app_auth') THEN
    -- 生产环境请在云控制台创建并设强口令；这里的口令只为本机开发可复现。
    CREATE ROLE app_auth LOGIN PASSWORD 'app_auth_local_dev' BYPASSRLS;
  END IF;
END
$$;

GRANT USAGE ON SCHEMA public TO app_auth;
-- 白名单只有这几张表。**加表要先想清楚为什么**，不要顺手补一句 ALL TABLES。
-- （凭证表在 sql/004_credential.sql 里建，它的 GRANT 也在那边。）
GRANT SELECT, INSERT, UPDATE ON app_user, user_session TO app_auth;

-- 上面那句 CREATE ROLE 在「角色已存在」时会被整个跳过（DO 块的 IF）。
-- 而 BYPASSRLS 是 app_auth 的**结构必需品**：登录要读 app_user，
-- 而那张表的 policy 依赖 `current_setting('app.user_id')` —— 没有身份时一行都读不到。
-- 所以这里显式补一次，让「本地某次中断留下的残缺角色」不会表现成
-- 「注册时手机号永远查不到，于是每次都是 23505 冲突」这种极难联想的症状。
ALTER ROLE app_auth BYPASSRLS;

-- app_rls 读自己的会话（/auth/sessions 列登录设备）：
-- user_session 是本文件新建的，002 的 ALTER DEFAULT PRIVILEGES 会给它补上
-- 与其它表一样的四件套，所以这里**不需要再 GRANT 一次**。
-- 下面这句是把这件事写成断言，而不是写成注释 —— 迁移时就能发现默认权限没生效。
DO $$
BEGIN
  IF NOT has_table_privilege('app_rls', 'user_session', 'SELECT') THEN
    RAISE EXCEPTION 'app_rls 读不到 user_session：ALTER DEFAULT PRIVILEGES 没生效，/auth/sessions 会全线 403';
  END IF;
END
$$;
