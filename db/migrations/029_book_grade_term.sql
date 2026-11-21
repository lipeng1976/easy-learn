-- 教材 / 词表按「年级 + 学期」区分（11-12 定）。
--
-- ## 为什么这两张表要年级学期，阅读表不要
--
-- 教材（subject_book）和词表（word_book）是**跟着教学大纲走**的资源：
-- 七上数学 ≠ 七下数学，孩子升年级就得换书。库里存下年级学期，才能
--   ① 配置页比对「这本书是不是当前年级的」并预警；
--   ② 以后复习/出题按年级筛选。
-- 阅读（reading_book）是**跟着孩子走**的资源：《三国演义》不分年级，
--   什么年级都能读、能重读 —— 给了年级反而限制「跨年级重读」，所以不加。
--
-- 错题本（review_mistake）不拆表，但每条已经带年级学期快照（011），
-- 它是累积档案，按年级拆开会毁掉「复习原料」的语义。
--
-- ## 给书加年级学期，不是给「范围」加
--
-- 年级学期是**书本身的属性**（一本七上数学就是七上的），不是 subject_scope
-- 的属性。所以列加在 subject_book / word_book 上，不加在 scope 表。
-- subject_scope.book_id 指向某本书，书的年级就是这份范围的年级；
-- 游标 start_unit_no 是 per-book 的，换书自然从 1 开始。
--
-- ## 默认空串，不回填老数据
--
-- 已有书 grade/term 留空 = 「未标注年级」（导入功能早于年级标注存在）。
-- 配置页遇到空串不报错，只不显示匹配状态；导入功能上线后新导入的会填。

ALTER TABLE subject_book
  ADD COLUMN IF NOT EXISTS grade TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS term  TEXT NOT NULL DEFAULT '';

ALTER TABLE word_book
  ADD COLUMN IF NOT EXISTS grade TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS term  TEXT NOT NULL DEFAULT '';

-- 配置页比对 / 列表按（学生, 科目, 年级, 学期）筛时用。
CREATE INDEX IF NOT EXISTS ix_subject_book_student_subject_grade
  ON subject_book (student_id, subject, grade, term);

CREATE INDEX IF NOT EXISTS ix_word_book_student_grade
  ON word_book (student_id, grade, term);
