-- 英语单词打卡：教材词表 → 每天一组本地选择题 → 成绩摘要
--
-- ## 为什么词表要落 PG，而不是每次去 ima 读
--
-- ima 是**可选能力**：不是每个家庭都有账号。词表只在家长点「导入」时碰一次 ima，
-- 之后全落在这四张表里，客户端再缓存进本地 sqflite。于是「ima 后来断了 / 没开通 /
-- 凭证失效」只影响「能不能导入新书」，打卡、发音、错词复习全部照常 —— 且不会报错
-- （11-07 定的硬规矩）。反过来，如果每次出题都读 ima，没账号的家庭连页面都打不开。
--
-- ## 为什么范围（word_scope）单独一张表，且 student_id 是主键
--
-- 客户端的 `app_setting(key, value)` 是**裸 key、没有 student_id 列**，多孩家庭切孩子
-- 必然串（哥哥的当前书变成弟弟的）。范围与每日题量因此放服务端、一学生一行，
-- 本地只做只读缓存。这也是「家长配一次、学生每天零操作」的落点。
--
-- ## 为什么服务端不存逐题作答
--
-- 题目在客户端由同一份词表按日期种子确定性生成，服务端没有题目快照，
-- 也不承担防作弊。`word_daily_result` 只是给家长看的**摘要**（最后同步为准）。
-- 详见 `doc/word-checkin-design.md` §7.3。

CREATE TABLE IF NOT EXISTS word_book (
  id              TEXT PRIMARY KEY,
  student_id      TEXT NOT NULL,
  owner_user_id   TEXT NOT NULL DEFAULT '',
  title           TEXT NOT NULL,
  -- ima / manual。v1 只有 ima，写下来让老数据以后能区分来源。
  source          TEXT NOT NULL DEFAULT 'ima',
  source_media_id TEXT NOT NULL DEFAULT '',
  source_path     TEXT NOT NULL DEFAULT '',
  unit_count      INTEGER NOT NULL DEFAULT 0,
  word_count      INTEGER NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 同一学生、同一份 ima MD 只导一次；重复导入是「覆盖更新」，不是再建一本书。
-- ⚠️ 覆盖时**必须保留 book.id**：`word_scope.book_id` 指着它，删掉重建会让
-- 家长设好的范围静默指向一本不存在的书。
CREATE UNIQUE INDEX IF NOT EXISTS uq_word_book_source
  ON word_book(student_id, source_media_id)
  WHERE source_media_id <> '';

CREATE INDEX IF NOT EXISTS idx_word_book_student
  ON word_book(student_id, created_at DESC);

CREATE TABLE IF NOT EXISTS word_entry (
  id               TEXT PRIMARY KEY,
  book_id          TEXT NOT NULL REFERENCES word_book(id) ON DELETE CASCADE,
  -- 冗余 student_id 给 RLS 用：不冗余就得在策略里子查询 word_book，
  -- 而子查询本身也受 RLS 约束，一旦上游策略改了这里会静默变空。
  student_id       TEXT NOT NULL,
  unit             TEXT NOT NULL,
  -- 单元顺序 = MD 里 `##` 的出现顺序，**不按标题文本排序**。
  unit_order       INTEGER NOT NULL DEFAULT 1,
  word             TEXT NOT NULL,
  phonetic         TEXT NOT NULL DEFAULT '',
  meaning          TEXT NOT NULL DEFAULT '',
  -- 只取首义，出题时的唯一答案口径（`word_import.js:primaryMeaning`）。
  primary_meaning  TEXT NOT NULL DEFAULT '',
  normalized_word  TEXT NOT NULL DEFAULT '',
  sort_no          INTEGER NOT NULL DEFAULT 0,
  CONSTRAINT uq_word_entry UNIQUE (book_id, unit, normalized_word)
);

CREATE INDEX IF NOT EXISTS idx_word_entry_student_unit
  ON word_entry(student_id, book_id, unit_order, sort_no);

CREATE TABLE IF NOT EXISTS word_daily_result (
  student_id  TEXT NOT NULL,
  -- 客户端给的**本地日**（R4：服务端按 UTC 算日期，晚上 8 点后会错一天）。
  day         DATE NOT NULL,
  total       INTEGER NOT NULL DEFAULT 0,
  correct     INTEGER NOT NULL DEFAULT 0,
  streak      INTEGER NOT NULL DEFAULT 0,
  -- [{word, count}] Top5，仅供家长端展示；错词权重真值在客户端 word_answer。
  wrong_words JSONB NOT NULL DEFAULT '[]'::jsonb,
  synced_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (student_id, day)
);

CREATE TABLE IF NOT EXISTS word_scope (
  student_id     TEXT PRIMARY KEY,
  book_id        TEXT NOT NULL DEFAULT '',
  -- current=仅当前单元 / learned=第 1→当前单元 / selected=家长多选 / all=整本
  unit_mode      TEXT NOT NULL DEFAULT 'learned',
  current_unit   TEXT NOT NULL DEFAULT '',
  selected_units JSONB NOT NULL DEFAULT '[]'::jsonb,
  daily_count    INTEGER NOT NULL DEFAULT 10,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_word_scope_mode
    CHECK (unit_mode IN ('current', 'learned', 'selected', 'all')),
  CONSTRAINT ck_word_scope_count CHECK (daily_count BETWEEN 1 AND 50)
);

-- ===== RLS：与 023_reading / 019_checkin_quiz 完全同一口径 =====
-- 可见集合 = 自己 + 家长可见的 active 孩子。四表都冗余 student_id，
-- 策略因此一模一样，不必为「哪张表要连哪张表」记例外。
ALTER TABLE word_book ENABLE ROW LEVEL SECURITY;
ALTER TABLE word_book FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON word_book USING (
  student_id = ANY(app_csv_setting('app.visible_students'))
);

ALTER TABLE word_entry ENABLE ROW LEVEL SECURITY;
ALTER TABLE word_entry FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON word_entry USING (
  student_id = ANY(app_csv_setting('app.visible_students'))
);

ALTER TABLE word_daily_result ENABLE ROW LEVEL SECURITY;
ALTER TABLE word_daily_result FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON word_daily_result USING (
  student_id = ANY(app_csv_setting('app.visible_students'))
);

ALTER TABLE word_scope ENABLE ROW LEVEL SECURITY;
ALTER TABLE word_scope FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON word_scope USING (
  student_id = ANY(app_csv_setting('app.visible_students'))
);
