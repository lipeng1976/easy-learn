-- 登录留痕（2026-11-26）。
--
-- ## 记什么
--
-- 每次**成功**登录写一行：账号（手机号）、时间、来源 IP、UA 摘要、登录方式。
-- 失败不记 —— 「每次登录」的口径由用户定为「真的进来了」；失败留痕是
-- 另一个需求（防撞库），会引入「账号乱填」的脏数据，别混进来。
--
-- ## 为什么单独建表，不给 user_session 加列
--
-- user_session 是**会话**：会被吊销、过期，语义是「现在还活着的登录」。
-- 登录日志是**历史事实**：登出、改密、过期都不该抹掉「某时某 IP 登过」。
-- 两者生命周期不同，塞一张表会让「删旧会话」顺手删掉审计线索。
--
-- ## 权限与 RLS
--
-- 写入方是 app_auth（登录时还没有身份，走鉴权连接），它是 BYPASSRLS，
-- 所以只需要显式 GRANT INSERT。
-- 读取方是 app_rls：沿用全库 RLS 约定，policy 限定 `user_id = app.user_id`
-- —— 用户能查自己的登录历史，家长看不到孩子的（那是账号安全信息）。
-- 要看全表用 easylearn_admin（BYPASSRLS），不要在应用角色上开口子。

CREATE TABLE IF NOT EXISTS login_log (
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  -- 登录时用的账号原文（手机号）。不加密：app_user.phone 本身就是明文，
  -- 单独把这一列藏起来只会让日志没法按账号排查。
  account    TEXT NOT NULL DEFAULT '',
  logged_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- 转发头优先（X-Forwarded-For / X-Real-IP），没有才用 socket 地址。
  -- FRP 是纯 tcp 转发，公网进来的请求在本机看到的是 127.0.0.1 —— 这是
  -- 部署事实，不是代码 bug；要真实公网 IP 得改 FRP 或上 https 网关。
  ip         TEXT NOT NULL DEFAULT '',
  -- UA 摘要（复用 user_session.client 的口径，最多 200 字符）。
  client     TEXT NOT NULL DEFAULT '',
  -- password / register（注册成功即自动登录）。
  method     TEXT NOT NULL DEFAULT 'password'
);

CREATE INDEX IF NOT EXISTS ix_login_log_user_time ON login_log (user_id, logged_at DESC);
CREATE INDEX IF NOT EXISTS ix_login_log_account_time ON login_log (account, logged_at DESC);

ALTER TABLE login_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE login_log FORCE ROW LEVEL SECURITY;

CREATE POLICY login_log_own ON login_log
  USING (user_id = current_setting('app.user_id', true))
  WITH CHECK (user_id = current_setting('app.user_id', true));

-- app_auth 只在登录成功时 INSERT；不给 SELECT/UPDATE/DELETE，
-- 避免「还没身份的连接」能读到任何账号的登录历史。
GRANT INSERT ON login_log TO app_auth;
