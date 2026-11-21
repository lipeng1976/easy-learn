-- 结伴双方互见：让 `app_user` 的读策略放行「我的结伴对端」
--
-- ## 现象的来路
--
-- `listRelationships` 返回的关系行里只有 id（`student_id` / `parent_id`），
-- 没有名字 —— 客户端要显示「对方是谁」，只能拿这个 id 再回 `app_user` 取。
-- 而 `user_read`（004 建的）只放行两件事：
--
--     id = 我自己   OR   id = ANY(可见学生)
--
-- 于是：
--   · **家长**读得到孩子的名字 —— 因为孩子在 `visible_students` 里（= 已结伴的学生）；
--   · **学生**读不到家长的名字 —— 因为学生的 `visible_students` 就是 `[自己]`
--     （见 `src/db.js` 的 `resolveVisibleStudents`）。
--
-- 症状是这一串同时成立：关系建成了、`status` 是 `active`、库里两边账号都在，
-- 而**界面上对方那一栏是空的**，且不报任何错误（客户端把取不到的名字映射成空串）。
-- 这类「数据在、显示没有」比缺数据更难查，因为每个环节分开看都是对的。
--
-- ## 为什么在策略层修，而不是在端点里补一次查询
--
-- 「谁看得见谁」在这个项目里是**数据库机制**（`doc/cloud-migration-plan.md` 的 R7：
-- 不按角色写判断，而是先算出可见集合，让忘写 where 的后果从「越权」降级为「查不到」）。
-- 在 `listRelationships` 里补一次绕过 RLS 的读（比如借 `app_auth` 连接取名字），
-- 等于把这条规则从一处挪到 N 处，而且**不会报错**：
-- 将来再多一个端点要显示对方名字，就得记得再补一次，漏了就是又一片空白。
--
-- ## 影响面（算过）
--
--   · **家长侧：无变化。** 家长的对端是学生，本来就在 `visible_students` 里，
--     新加的 EXISTS 对他不产生任何新增可见行。
--   · **学生侧：新增「自己的结伴家长」这一行。**
--   也就是说这条放开只让「学生看到自己的家长」成为可能 —— 方向是合理的，
--   他们本来就通过结伴把作业数据共享了。
--
-- ⚠️ RLS 是**行级**的：`app_user` 一行可见 = `name` / `phone` / `role` / `avatar` 全都可见，
--    没法只放行 name 一列。这正是这里只认「已结伴」这一种关系、
--    而不是顺手写成更宽的「同班/同校」的原因。真要只暴露名字，那是视图或列级权限的活。
--
-- ⚠️ 子查询引用 `relationship` 时**会应用它自己的 RLS**（policy 内的查询以当前角色执行）。
--    这对我们是好事：判定「谁是结伴对端」这件事本身也受隔离约束。
--    无递归风险 —— `relationship` 的策略只读 `current_setting`，不回头查 `app_user`。
--    取不到就是 false，表现为「名字仍为空」，fail-safe，不会放开不该放的。
--
-- ⚠️ `status = 'active'` 是**写死的字面量**（SQL 迁移文件没法 import 常量）：
--    它与 `src/vocab.js` 的 `RELATIONSHIP_STATUS.active` 是**同一件事的两半**
--    （同 007 的处置）。改词要两个文件一起改，否则这里会静默失效 —— 只认旧词，
--    表现为「名字又空了」。
--
-- 幂等：DROP IF EXISTS + CREATE，手工重跑无副作用（正常路径下由
-- `schema_migrations` 保证只执行一次，见 `src/migrate.js`）。

DROP POLICY IF EXISTS user_read ON app_user;

CREATE POLICY user_read ON app_user FOR SELECT USING (
  id = current_setting('app.user_id', true)
  OR id = ANY(string_to_array(current_setting('app.visible_students', true), ','))
  OR EXISTS (
    SELECT 1 FROM relationship r
     WHERE r.status = 'active'
       AND (
         (r.student_id = current_setting('app.user_id', true) AND r.parent_id = app_user.id)
         OR (r.parent_id = current_setting('app.user_id', true) AND r.student_id = app_user.id)
       )
  )
);
