-- 伴学 APP 数据服务 —— 隔离层（RLS）
--
-- 对应迁移计划 §10.2 的规则 R7：**隔离必须是数据库机制，不是约定**。
--
-- 为什么不能靠「应用层记得写 where」：
--   一个家庭时漏写 = 看到自家另一台设备的数据，无所谓；
--   一个班 40 个学生 + 40 个家长时，一次漏写 = 一整个班的数据泄露。
--
-- 本文件做对的核心设计：**不按角色写 policy，而是先算出「这个请求能看哪些学生」**。
--   好处是 policy 形状与「集合怎么算出来的」无关 ——
--   将来老师角色接入，只需多一个 visible_students 的来源（班级成员表），
--   policy 一行都不用改；若当初按角色写，那时要改 23 张表。
--
-- ⚠️⚠️ 实测（2026-09-18，本机 PG 17.10）：
--   **superuser 永远绕过 RLS，连 `FORCE ROW LEVEL SECURITY` 也拦不住。**
--   用一个未设 visible_students 的 superuser 查一张启用了 RLS 的表，看到的是**全部 2 行**，
--   不报错、不警告。也就是说：如果应用拿主账号连库，整套 RLS 会**静默失效**。
--   → 所以这里必须建一个非 superuser、非表 owner 的应用角色 app_rls，应用只用它连。
--   → 系统级查询（对账脚本、迁移工具、后台统计）另用 postgres 账号，那是刻意绕过。
--
-- 执行方式：由 src/migrate.js 在事务内按文件名顺序执行，本文件**不要自带 BEGIN/COMMIT**。

-- ===== 应用角色 =====
-- 生产环境请在云控制台创建并设强口令；这里的口令只为本机开发可复现。
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'app_rls') THEN
    CREATE ROLE app_rls LOGIN PASSWORD 'app_rls_local_dev';
  END IF;
END
$$;

GRANT USAGE ON SCHEMA public TO app_rls;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_rls;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rls;

-- ===== 可见集合的计算口径（由服务端的鉴权中间件在每个请求里设置）=====
--
--   app.user_id         当前登录用户（来自 token 的 sub，**不是客户端自报的**）
--   app.visible_students  这个请求能看到的学生 id 列表（逗号分隔）
--
-- 两个变量都只在**事务内**用 SET LOCAL 设置 —— 连接池复用连接时，
-- 会话级的 SET 会让下一个请求继承上一个人的身份（R7 的坑）。
--
-- 未设置时：current_setting(..., true) 返回 NULL → string_to_array(NULL) 为 NULL
--          → `x = ANY(NULL)` 为 NULL（不是 true）→ **fail-closed**。
-- 这是刻意的：宁可查不到数据，也不要漏出数据。忘写 where 的后果从「越权事故」
-- 降级为「查不到数据」——安全漏洞变成了可见的 bug。
--
-- ⚠️ 但上面这条推理**只覆盖了「不设」和「整体为空串」两种情形**（2026-09-24 在真 RDS 上
--    实测补全）。第三种情形是**列表里含空元素**：
--
--        string_to_array('',   ',')  =  {}          ← 空数组，0 行 ✓
--        string_to_array(NULL, ',')  =  NULL        ← ANY(NULL) 为 NULL ✓
--        string_to_array(',,', ',')  =  {'','',''}  ← 含空串元素 ✗ 会匹配 student_id = ''
--
--    而 `student_id` 在 15 张业务表上是 `TEXT NOT NULL DEFAULT ''` —— 于是
--    「某处漏传 student_id 静默写入无主行」+「某次下发的集合含空元素」这条链
--    会让那行对所有人可见。两个条件都罕见，且**都不报错**。
--
--    → 已由 `010_rls_empty_collection_safe.sql` 修掉：本文件下面那些
--      `string_to_array(current_setting(...))` 在库里已经被统一替换成
--      `app_csv_setting('...')`（一个带 `array_remove(..., '')` 的 STABLE 函数）。
--      **改这里不会生效**（本文件已应用过），要改就再补一条新迁移。

-- ===== 逐表启用 RLS 与 policy =====
-- 形状统一为「某个归属列 = ANY(visible_students)」，只是列名不同。

-- 归属列 = student_id 的表
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'homework', 'workout_plan', 'workout_record',
    'review_mistake', 'review_paper',
    'judgement_ab', 'review_attempt', 'ai_practice_question',
    'explain_record', 'review_summary',
    'wish', 'study_plan', 'study_plan_checkin',
    'daily_comment', 'point_rule', 'point_ledger',
    'homework_image'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format($f$
      CREATE POLICY own_rows ON %I USING (
        student_id = ANY(
          string_to_array(current_setting('app.visible_students', true), ',')
        )
      )$f$, t);
  END LOOP;
END
$$;

-- review_paper_item 的归属列是 paper_id 而不是 student_id —— 它自己不带学生字段。
-- 所以它的可见性要**顺着父卷**判断，不能用上面那批的形状。
--
-- ⚠️ 这里必须自己写 ENABLE/FORCE —— 它不在上面的循环里。
--   漏掉的后果是**静默的**：policy 建得好好的、不报任何错，但因为没启用 RLS，
--   这张表对所有人完全开放（卷内每道题的题干、答案、学生作答都能被别的学生读到）。
--   排查方式：查 pg_class 的 relrowsecurity / relforcerowsecurity，
--   而不是查 pg_policies —— 「有 policy」不等于「RLS 生效」。
ALTER TABLE review_paper_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE review_paper_item FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON review_paper_item USING (
  paper_id IN (
    SELECT p.id FROM review_paper p
    WHERE p.student_id = ANY(
      string_to_array(current_setting('app.visible_students', true), ',')
    )
  )
);

-- 账号：能看到「自己」+「可见学生」。
-- 注意 student_id 与 app_user.id 是**同一套 id**（演示数据里就是 stu_001），
-- 所以 visible_students 里的值可以直接拿来比对 app_user.id。
ALTER TABLE app_user ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_user FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON app_user USING (
  id = current_setting('app.user_id', true)
  OR id = ANY(string_to_array(current_setting('app.visible_students', true), ','))
);

-- 关系链：学生端看自己相关的，家长端看自己相关的。
-- 这里不能用 student_id 单列判 —— 家长需要看到「我是 parent_id」的那些行。
ALTER TABLE relationship ENABLE ROW LEVEL SECURITY;
ALTER TABLE relationship FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON relationship USING (
  student_id = ANY(string_to_array(current_setting('app.visible_students', true), ','))
  OR parent_id = current_setting('app.user_id', true)
);

-- 聊天：只看自己参与的消息（不按学生聚合 —— 家长之间的对话不该被孩子看到）。
ALTER TABLE chat_message ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat_message FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON chat_message USING (
  sender_id = current_setting('app.user_id', true)
  OR receiver_id = current_setting('app.user_id', true)
);

-- 通知：发给自己的，或广播（target_user_id = ''）。
ALTER TABLE app_notification ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_notification FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON app_notification USING (
  target_user_id = current_setting('app.user_id', true)
  OR target_user_id = ''
);

-- 通知已读：只看自己的已读记录（含写入 —— FOR ALL 策略下 USING 同时充当 WITH CHECK）。
ALTER TABLE app_notification_read ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_notification_read FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON app_notification_read USING (
  user_id = current_setting('app.user_id', true)
);
