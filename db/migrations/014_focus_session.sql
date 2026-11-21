-- 伴学 APP 数据服务 —— 专注计时流水
--
-- 客户端的「专注计时」原来只写 `homework.actual_seconds`（一份作业一个总数）。
-- 那个数回答不了两个后来才被问到的问题：
--   ① 学习计划（阅读、背诵）花了多久 —— 计划是**按天重复**的，
--      一个总数没法说清「今天读了多少」；
--   ② 「今天临时想读 20 分钟」这种不属于任何作业/计划的时间记在哪。
--
-- 所以这里记**流水**：一次会话一行。作业那份总数仍然是它的镜像
-- （`homework.actual_seconds` = 该作业所有流水的和），两条路径各答一个问题。
--
-- 执行方式：由 src/migrate.js 在事务内按文件名顺序执行，本文件**不要自带 BEGIN/COMMIT**。

CREATE TABLE IF NOT EXISTS focus_session (
  id          TEXT PRIMARY KEY,
  student_id  TEXT NOT NULL DEFAULT '',
  kind        TEXT NOT NULL DEFAULT 'free',
  source_id   TEXT NOT NULL DEFAULT '',
  title       TEXT NOT NULL DEFAULT '',
  date        TEXT NOT NULL DEFAULT '',
  seconds     INTEGER NOT NULL DEFAULT 0,
  started_at  TIMESTAMPTZ DEFAULT now(),
  updated_at  TIMESTAMPTZ DEFAULT now()
);

-- 「今天读了多少」「这个计划本周投入多少」都从这里读：
-- 按 (学生, 日期) 取一段，按 (学生, 目标) 汇总。
CREATE INDEX IF NOT EXISTS idx_focus_session_student_date
  ON focus_session(student_id, date);
CREATE INDEX IF NOT EXISTS idx_focus_session_student_target
  ON focus_session(student_id, kind, source_id, date);

-- ⚠️ 新表最容易犯的错是「建了表忘了开 RLS」：policy 建得好好的、不报任何错，
--    但因为没启用，这张表对所有人完全开放（别的学生能看到你的专注记录）。
--    排查方式：查 pg_class 的 relrowsecurity / relforcerowsecurity，
--    而不是查 pg_policies —— 「有 policy」不等于「RLS 生效」。
ALTER TABLE focus_session ENABLE ROW LEVEL SECURITY;
ALTER TABLE focus_session FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON focus_session USING (
  student_id = ANY(app_csv_setting('app.visible_students'))
);
