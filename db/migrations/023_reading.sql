-- 英文阅读：一本书 → 一次长期任务 → 一篇一次打卡
--
-- ## 为什么任务挂在「书」上，而不是挂在「天」上
--
-- 这里**没有** `reading_daily` 之类「某天该读第几篇」的表，这是刻意的。
--
-- 产品语义是：家长布置一本书，任务就一直挂在那儿，孩子哪天读了哪天算一次
-- 打卡，没读就顺延到明天，直到整本书读完。如果按天生成待办行，就要额外
-- 处理「昨天没做怎么办」——要么堆出一串过期任务（孩子一打开看到十条欠账），
-- 要么每天跑一次结转（离线设备必然漏结）。而只要不按天建行，这个需求
-- **自然成立**：任务没结束，它明天还在。
--
-- 「今天做了没有」是**查出来的**（`reading_log` 里有没有今天的行），
-- 不是**存出来的**。存出来的那一天会出现「日志写进去了、任务表没更新」
-- 这种两处不一致，且没有任一方报错。
--
-- ## 一张表一本书，还是每课一行
--
-- 每课一行（`reading_lesson`）。一篇 1.5k–3.7k 字符，96 课合起来约 350KB ——
-- 这不值得做懒加载或对象存储。存成行之后「下一课是哪课」「一共几课」
-- 都是普通 SQL，客户端不必先下载整本书才能显示进度。

CREATE TABLE IF NOT EXISTS reading_book (
  id              TEXT PRIMARY KEY,
  -- 归属学生。家长导入时填孩子 id，学生自己导入时是自己。
  -- RLS 与 checkin_quiz 同一套口径（visible_students），家长能看、学生只看自己。
  student_id      TEXT NOT NULL,
  owner_user_id   TEXT NOT NULL DEFAULT '',
  title           TEXT NOT NULL,
  author          TEXT NOT NULL DEFAULT '',
  intro           TEXT NOT NULL DEFAULT '',
  -- ima / manual。v1 只有 ima，但把来源写下来：哪天接入别的书源，
  -- 老数据不用迁移就能区分。
  source          TEXT NOT NULL DEFAULT 'ima',
  -- ima 侧的条目 id。同一本书重复导入靠它去重 —— 见下面的唯一索引。
  source_media_id TEXT NOT NULL DEFAULT '',
  -- 导入时的知识库路径（`教学资料/English/xxx.md`），排查「这本书哪来的」用。
  source_path     TEXT NOT NULL DEFAULT '',
  lesson_count    INTEGER NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 同一学生、同一本 ima 文件只导一次。
--
-- 用**部分唯一索引**而不是普通唯一键：`source_media_id` 默认为空串，
-- 手动录入的书（`source='manual'`）没有 media id，普通唯一键会让第二本
-- 手动书直接插不进去 —— 而报错是「duplicate key」，跟书本身毫无关系。
CREATE UNIQUE INDEX IF NOT EXISTS uq_reading_book_source
  ON reading_book(student_id, source_media_id)
  WHERE source_media_id <> '';

CREATE INDEX IF NOT EXISTS idx_reading_book_student
  ON reading_book(student_id, created_at DESC);

CREATE TABLE IF NOT EXISTS reading_lesson (
  id          TEXT PRIMARY KEY,
  book_id     TEXT NOT NULL REFERENCES reading_book(id) ON DELETE CASCADE,
  -- 冗余 student_id 是给 RLS 用的：不冗余就得在策略里写子查询关联
  -- reading_book —— 子查询本身也受 RLS 约束，正确但慢，而且一旦哪天
  -- 有人给 reading_book 换了策略，这里会静默变成「看不到任何课」。
  student_id  TEXT NOT NULL,
  lesson_no   INTEGER NOT NULL,
  title       TEXT NOT NULL DEFAULT '',
  title_zh    TEXT NOT NULL DEFAULT '',
  -- 英文正文（段落用空行分隔，保留原书换行）。
  body        TEXT NOT NULL DEFAULT '',
  -- [{word, phonetic, meaning}]。空数组不是 null：客户端少一次判空。
  vocabulary  JSONB NOT NULL DEFAULT '[]'::jsonb,
  translation TEXT NOT NULL DEFAULT '',
  char_count  INTEGER NOT NULL DEFAULT 0,
  CONSTRAINT uq_reading_lesson UNIQUE (book_id, lesson_no)
);

CREATE INDEX IF NOT EXISTS idx_reading_lesson_book
  ON reading_lesson(book_id, lesson_no);

CREATE TABLE IF NOT EXISTS reading_task (
  id            TEXT PRIMARY KEY,
  student_id    TEXT NOT NULL,
  book_id       TEXT NOT NULL REFERENCES reading_book(id) ON DELETE CASCADE,
  owner_user_id TEXT NOT NULL DEFAULT '',
  -- 每天建议读几篇。v1 固定 1，但存下来：卡片要显示「今日 0/1 篇」，
  -- 而「1」如果写死在客户端，改起来就要发版。
  daily_target  INTEGER NOT NULL DEFAULT 1,
  -- 布置那一刻的总篇数快照。**不复用 book.lesson_count**：书将来可以增补
  -- 课（比如换一版 MD 重新导入），而「这次任务要求读多少」必须锁定，
  -- 否则孩子读到 90/96 时书变成 120 课，任务突然又要多读 24 篇。
  total_lessons INTEGER NOT NULL DEFAULT 0,
  -- active（进行中）/ done（读完）/ cancelled（家长取消）
  status        TEXT NOT NULL DEFAULT 'active',
  started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at  TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 一本书同时只能有一个进行中的任务。
--
-- 不加这条的话，家长手抖点两下「布置」就有两个 active 任务指向同一本书：
-- 学生端出现两张一模一样的卡，读一篇算谁的进度？两边各自涨，谁也读不完。
-- 部分索引让它卡在数据库层 —— 客户端漏判、并发双击都撞不穿。
CREATE UNIQUE INDEX IF NOT EXISTS uq_reading_task_active_book
  ON reading_task(book_id)
  WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_reading_task_student
  ON reading_task(student_id, status, created_at DESC);

CREATE TABLE IF NOT EXISTS reading_log (
  id         TEXT PRIMARY KEY,
  task_id    TEXT NOT NULL REFERENCES reading_task(id) ON DELETE CASCADE,
  student_id TEXT NOT NULL,
  book_id    TEXT NOT NULL,
  lesson_no  INTEGER NOT NULL,
  -- 客户端给的**本地日**（yyyy-MM-dd）。
  --
  -- 与 `study_plan_checkin` / `checkin_quiz.quiz_date` 同一条规矩（R4）：
  -- 服务端按 UTC 算日期，晚上 8 点后打卡会被记到明天，而孩子看到的是
  -- 「今天明明读了」。所以日期由客户端给，服务端只校验格式。
  day        DATE NOT NULL,
  read_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- 一篇只算一次。重复点击、断网重试、双端同时提交都不会把进度刷高。
  CONSTRAINT uq_reading_log_lesson UNIQUE (task_id, lesson_no)
);

CREATE INDEX IF NOT EXISTS idx_reading_log_task_day
  ON reading_log(task_id, day);

CREATE INDEX IF NOT EXISTS idx_reading_log_student
  ON reading_log(student_id, read_at DESC);

-- ===== RLS：与 checkin_quiz 同一套口径 =====
-- 可见集合 = 自己 + 家长可见的 active 孩子。家长能建书、布置任务、看进度；
-- 学生只能碰自己的。四张表都冗余了 `student_id`，策略因此完全一致，
-- 不必为「哪张表要连哪张表」记例外。
ALTER TABLE reading_book ENABLE ROW LEVEL SECURITY;
ALTER TABLE reading_book FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON reading_book USING (
  student_id = ANY(app_csv_setting('app.visible_students'))
);

ALTER TABLE reading_lesson ENABLE ROW LEVEL SECURITY;
ALTER TABLE reading_lesson FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON reading_lesson USING (
  student_id = ANY(app_csv_setting('app.visible_students'))
);

ALTER TABLE reading_task ENABLE ROW LEVEL SECURITY;
ALTER TABLE reading_task FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON reading_task USING (
  student_id = ANY(app_csv_setting('app.visible_students'))
);

ALTER TABLE reading_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE reading_log FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON reading_log USING (
  student_id = ANY(app_csv_setting('app.visible_students'))
);
