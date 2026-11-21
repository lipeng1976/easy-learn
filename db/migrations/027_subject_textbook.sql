-- 学科教材：ima 里的一本教材 → 章节目录 + 每节考点 → 出题时当范围
--
-- ## 为什么不在出题时实时读 ima
--
-- ima 是**可选能力**（不是每个学生都开通），它会 401 / 403 / 超时，也会
-- 因为家长删了文件而消失。出题是主链路：主链路依赖一个可能不存在的服务，
-- 症状就是「今天忽然一科都出不了题」，而且没有错误提示可解释。
-- 所以口径是：**导入时读一次 ima，落库；之后只读 PG**，断网也能出题。
--
-- ## 为什么单独两张表，不并进 word_book / word_entry
--
-- 词表一行是「单词 / 音标 / 释义」，教材一行是「章 / 考点清单」，形状不同。
-- 合并的结果是两边各长一堆永远为 NULL 的列，而且 word 那条链路（025）
-- 已经跑通判分与打卡，动它没有收益、只有回归风险。
--
-- ## 为什么只存「考点清单」不存正文
--
-- 出题要的是「考什么」，不是「教材怎么写」。把正文喂给模型有三个坏处：
-- 抄原题、prompt 几 MB、范围失控（模型自己扩大范围）。一节十几个考点词
-- 已经足够定位，而正文留在 ima 的 PDF 里当引用源。
--
-- ## start_unit_no 既是起点也是游标
--
-- 家长说的是「从第 3 章开始，每天 1 节」，系统说的是「今天该考第 7 章」。
-- 两者是同一个数：每次成功出题后 `start_unit_no += units_per_day`。
-- 不多开一个 `current_unit_no` —— 两个数一出现，就会有「改了起点但游标没动」
-- 这类只在一处生效的 bug。
--
-- ## 表没迁移时不报错
--
-- 与 025 / 026 同一口径：只读端点按「没有教材」降级（配置页少一块），
-- 写端点响亮失败（家长正等着结果）。

CREATE TABLE IF NOT EXISTS subject_book (
  id              TEXT PRIMARY KEY,
  student_id      TEXT NOT NULL,
  subject         TEXT NOT NULL,
  title           TEXT NOT NULL,
  -- 书从哪来：目前只有 ima。留这个列是为了以后能从「拍照导入」等别的来源进。
  source          TEXT NOT NULL DEFAULT 'ima',
  -- ima 文件 id：重复导入同一本书时靠它去重（家长会多点几下）。
  source_media_id TEXT NOT NULL DEFAULT '',
  source_path     TEXT NOT NULL DEFAULT '',
  unit_count      INTEGER NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_subject_book_unit_count CHECK (unit_count >= 0)
);

-- 一个学生同一本书只有一行。用部分索引是因为 `source_media_id` 允许为空
-- （将来的非 ima 来源），空值之间不该互相冲突。
CREATE UNIQUE INDEX IF NOT EXISTS ux_subject_book_media
  ON subject_book (student_id, source_media_id)
  WHERE source_media_id <> '';

CREATE TABLE IF NOT EXISTS subject_unit (
  id         TEXT PRIMARY KEY,
  book_id    TEXT NOT NULL REFERENCES subject_book(id) ON DELETE CASCADE,
  student_id TEXT NOT NULL,
  -- 文档顺序（1 起），**不是**从标题里解析出来的章号：
  -- 「第 1 章」「Unit 1」「一、」写法各不相同，解析必然出岔子。
  unit_no    INTEGER NOT NULL,
  title      TEXT NOT NULL,
  -- 该节考点，用「、」分隔的一行短文本（几十字）。出题时直接当知识点用。
  summary    TEXT NOT NULL DEFAULT '',
  -- 原书页码提示（`p23`），给「回到原书」用；不参与出题。
  page_hint  TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS ix_subject_unit_book
  ON subject_unit (book_id, unit_no);

-- ===== subject_scope 扩三列 =====
--
-- 三列都有默认值，所以 026 已有的行不需要回填：`book_id` 为空 = 还没选教材，
-- 出题继续走「手填范围 / 错题本聚合」那条老路。
ALTER TABLE subject_scope ADD COLUMN IF NOT EXISTS book_id TEXT;
ALTER TABLE subject_scope ADD COLUMN IF NOT EXISTS start_unit_no INTEGER NOT NULL DEFAULT 1;
ALTER TABLE subject_scope ADD COLUMN IF NOT EXISTS units_per_day INTEGER NOT NULL DEFAULT 1;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'ck_subject_scope_start_unit'
  ) THEN
    ALTER TABLE subject_scope
      ADD CONSTRAINT ck_subject_scope_start_unit CHECK (start_unit_no >= 1);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'ck_subject_scope_units_per_day'
  ) THEN
    -- 1~3：一天最多三节。再多就不是「每天练一组」，是一套卷子。
    ALTER TABLE subject_scope
      ADD CONSTRAINT ck_subject_scope_units_per_day CHECK (units_per_day IN (1, 2, 3));
  END IF;
END $$;

-- ===== RLS：与 023 / 025 / 026 完全同一口径 =====
-- 可见集合 = 自己 + 家长可见的 active 孩子。
ALTER TABLE subject_book ENABLE ROW LEVEL SECURITY;
ALTER TABLE subject_book FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS own_rows ON subject_book;
CREATE POLICY own_rows ON subject_book USING (
  student_id = ANY(app_csv_setting('app.visible_students'))
);

ALTER TABLE subject_unit ENABLE ROW LEVEL SECURITY;
ALTER TABLE subject_unit FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS own_rows ON subject_unit;
CREATE POLICY own_rows ON subject_unit USING (
  student_id = ANY(app_csv_setting('app.visible_students'))
);
