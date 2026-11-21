-- 伴学 APP 数据服务 —— 错题闭环 P1：主动录入与学期归档
--
-- 本迁移只做三件事：
--   ① 学生档案补 `term`（上/下）；
--   ② `review_mistake` 补题干、答案、来源、年级学期快照、图片计数；
--   ③ 新增 `review_mistake_image` 并**立刻启用 RLS**。
--
-- ⚠️ 历史数据**不回填** question_body / grade / term：
--    · `title` 是「作业标题 · 知识点」，不是题目原文。拿它冒充题干，
--      讲解会继续拿一句标签当题讲——那正是这次要修的病根；
--    · 年级学期无从推断，猜一个比空着更糟（历史错题会被归到错误的学期）。
--    空值在 UI 里如实显示为「未归档」，由默认筛选兜住。
--
-- 执行方式：由 src/migrate.js 在事务内按文件名顺序执行，本文件**不要自带 BEGIN/COMMIT**。

-- ===== 1/4 学生档案：学期 =====
ALTER TABLE app_user ADD COLUMN IF NOT EXISTS term TEXT NOT NULL DEFAULT '';

-- ===== 2/4 错题：题干 / 答案 / 来源 / 学期快照 =====
ALTER TABLE review_mistake ADD COLUMN IF NOT EXISTS question_body TEXT NOT NULL DEFAULT '';
ALTER TABLE review_mistake ADD COLUMN IF NOT EXISTS answer_key    TEXT NOT NULL DEFAULT '';
ALTER TABLE review_mistake ADD COLUMN IF NOT EXISTS source_type   TEXT NOT NULL DEFAULT 'manual';
ALTER TABLE review_mistake ADD COLUMN IF NOT EXISTS grade         TEXT NOT NULL DEFAULT '';
ALTER TABLE review_mistake ADD COLUMN IF NOT EXISTS term          TEXT NOT NULL DEFAULT '';
ALTER TABLE review_mistake ADD COLUMN IF NOT EXISTS image_count   INTEGER NOT NULL DEFAULT 0;

-- 老数据：有来源作业的确实是批改产出的。
-- 没有 homework_id 的保持 manual —— 不能默认成 homework，
-- 那会让家长以为一条随手记的题是系统批出来的。
UPDATE review_mistake
   SET source_type = 'homework'
 WHERE homework_id <> '' AND source_type = 'manual';

-- 学期筛选的默认查询是「当前年级+学期」，补一条索引。
CREATE INDEX IF NOT EXISTS idx_review_mistake_term
  ON review_mistake(student_id, grade, term, created_at DESC);

-- ===== 3/4 错题图片 =====
--
-- 与 homework_image **分表**：作业图片跟着作业走（重新批改会覆盖），
-- 错题图片必须独立于作业存在——作业删了，错题还在。
CREATE TABLE IF NOT EXISTS review_mistake_image (
  id          TEXT PRIMARY KEY,
  student_id  TEXT NOT NULL DEFAULT '',
  mistake_id  TEXT NOT NULL,
  storage_key TEXT NOT NULL DEFAULT '',
  mime_type   TEXT NOT NULL DEFAULT '',
  file_size   BIGINT NOT NULL DEFAULT 0,
  sort_order  INTEGER NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_review_mistake_image_mistake
  ON review_mistake_image(mistake_id, sort_order);

-- ===== 4/4 RLS =====
--
-- ⚠️ 新表最容易犯的错是「建了表忘了开 RLS」：policy 建得好好的、不报任何错，
--    但因为没启用，这张表对所有人完全开放（别的学生能看到你的错题照片）。
--    排查方式：查 pg_class 的 relrowsecurity / relforcerowsecurity，
--    而不是查 pg_policies —— 「有 policy」不等于「RLS 生效」。
ALTER TABLE review_mistake_image ENABLE ROW LEVEL SECURITY;
ALTER TABLE review_mistake_image FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON review_mistake_image USING (
  student_id = ANY(app_csv_setting('app.visible_students'))
);
