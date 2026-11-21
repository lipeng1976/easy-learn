-- 伴学 APP 数据服务 —— 口令哈希与用户资料分表（S2）
--
-- ## 这个文件解决的是一个 S1 看不出来、S2 一改就成立的问题
--
-- S1 只读业务数据，`app_user` 的 policy 是「自己 + 可见学生」，看起来没问题。
-- S2 一旦有了「改密」，同一条 policy 立刻变成两条越权路径：
--
--   ① **家长能读到孩子的 password_hash。** policy 是**行级**的，
--      `id = ANY(visible_students)` 放行了整行 —— 包括哈希那一列。
--   ② **家长能改孩子的密码。** 同一条 policy 也管 UPDATE，
--      于是「改密」这个动作对孩子那一行同样成立。
--
-- 两条都不是「有人写错了 if」，是**用错了机制**：policy 管的是「哪些行」，
-- 管不了「行里的哪一列」。而 `SELECT (id, name, ...)` 那种列级权限能管列，
-- 却有一个很难看的副作用：002 的 `GRANT … ON ALL TABLES` 已经把**表级** SELECT
-- 给了 app_rls，表级会覆盖列级，所以必须先 `REVOKE SELECT ON app_user`；
-- 而一旦表级 SELECT 被收回，任何一处 `select *` 都当场报 permission denied ——
-- 改一处、炸一片，且炸的位置与改动点毫无关系。
--
-- **所以选择分表**：口令哈希不属于「用户资料」，只是恰好和一个用户一一对应。
--   · 资料（名字 / 头像 / 年级 / 爱好）—— 给关联的人看是**功能**；
--   · 口令哈希 —— 连管理员都不该随手读到，任何一次读出都是事故。
-- 两者的可见范围本来就不一样，硬塞进一行里，policy 就只能服务其中一个。
--
-- 分表之后不需要列级权限，也不需要「改密改用特权连接」这类妥协：
-- policy 仍然是统一的 `某归属列 = app.user_id`，与其余 22 张表同形。
--
-- ⚠️ 本期没有存量数据（服务端尚未上线），所以直接 DROP 列而不是数据搬迁；
--    客户端库（SQLite）里的 `password` 列仍在原处，S6 迁移时**不搬它** ——
--    存量演示账号的口令统一重设（迁移计划 §3.4③）。
--
-- 执行方式：由 src/migrate.js 在事务内按文件名顺序执行，本文件**不要自带 BEGIN/COMMIT**。

-- ===== 1/3 凭证表 =====
--
-- `user_id` 就是主键，不为它另建 id：这张表与用户是 1:1，
-- 一个自增主键只会多一列没人会去读的东西。
--
-- `ON DELETE CASCADE`：删账号时凭证跟着走。留一条孤儿哈希没有任何意义，
-- 而它会在「这个 user_id 又被注册出来」时变成一句很难解释的登录失败。
CREATE TABLE app_user_credential (
  user_id             TEXT PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  password_hash       TEXT NOT NULL,
  password_updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE app_user_credential ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_user_credential FORCE ROW LEVEL SECURITY;

-- 只有自己能碰自己的凭证行。**没有** `OR user_id = ANY(visible_students)` ——
-- 那半句正是问题 ① 和 ② 的来源。家长对孩子的一切业务数据都有可见性，
-- 唯独这一行没有；这条边界不靠约定，靠这条 policy。
CREATE POLICY credential_own ON app_user_credential
  USING (user_id = current_setting('app.user_id', true))
  WITH CHECK (user_id = current_setting('app.user_id', true));

-- app_rls（应用连接）：读 + 改自己的凭证（改密）。
-- 002 的 ALTER DEFAULT PRIVILEGES 已经给了四件套，这里把 DELETE 收回来 ——
-- 「删掉自己的密码」不是任何功能的中间步骤，而它会让账号进入一个
-- 谁都登不进去的状态。将来真要做注销，那是一个有级联清理的**端点**，
-- 不是一次 DELETE 权限。
REVOKE DELETE ON app_user_credential FROM app_rls;

-- app_auth（鉴权连接）：登录要读哈希、注册要写哈希、登录时顺手升级参数。
-- 它本来就带 BYPASSRLS，所以这条 GRANT 的边界由 db.js 的
-- assertAuthRoleScoped() 守着（白名单在那边）。
GRANT SELECT, INSERT, UPDATE ON app_user_credential TO app_auth;

-- ===== 2/3 从 app_user 里摘掉凭证列 =====
--
-- 保留 `password_hash` 列而不去用它，是**更差**的选择：某个新查询用 `select *`
-- 就会把哈希带进响应体，而它不报错、不影响功能，直到有人看到它。
-- 结构上不存在，才是真的读不到。
ALTER TABLE app_user DROP COLUMN password_hash;
ALTER TABLE app_user DROP COLUMN password_updated_at;

-- ===== 3/3 app_user 的 policy 按命令拆开 =====
--
-- 002 建的是 `FOR ALL` 一条：`id = 自己 OR id = ANY(可见学生)`。
-- 对**读**来说这句是对的（家长看孩子资料），对**写**来说是错的（家长改孩子资料）。
-- `FOR ALL` 把两者合并，等于偷偷用「读的范围」授权了「写的范围」。
--
-- 拆开之后：
--   · 读 —— 自己 + 可见学生（保持 S1 的行为，家长看得到孩子资料）；
--   · 写 —— **只有自己**。
--
-- 这不是收紧了好用的功能：客户端现在所有资料编辑都发生在「我」身上。
-- 将来若真要「家长替孩子改头像」，那应当是一次有意的放开 ——
-- 由那句需求驱动，而不是被一条顺带写下的 policy 长期默许。
DROP POLICY own_rows ON app_user;

CREATE POLICY user_read ON app_user FOR SELECT USING (
  id = current_setting('app.user_id', true)
  OR id = ANY(string_to_array(current_setting('app.visible_students', true), ','))
);

CREATE POLICY user_write_self ON app_user FOR UPDATE
  USING (id = current_setting('app.user_id', true))
  WITH CHECK (id = current_setting('app.user_id', true));

-- 注册走 app_auth（那时还没有身份），所以应用连接不需要 INSERT 用户行。
-- 同理不需要 DELETE：删账号是服务端的一次级联清理，不是一次行删除权限。
REVOKE INSERT, DELETE ON app_user FROM app_rls;
