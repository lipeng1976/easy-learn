-- 每日概念打卡：一天一份题 + 一次作答结果
--
-- ## 为什么分两张表
--
-- 题目是**发起方**（家长发起的，或学生自己点开始）产出的快照，作答是
-- **学生**后来提交的结果。两者时间上分开、权限上也可能分开（家长看结果、
-- 学生答题），塞进一行会让「今天出了题但还没做」和「做完了」靠一堆可空列区分，
-- 那正是后来最容易写出 `where submitted_at is not null` 漏一半的地方。
--
-- ## 为什么题目快照里带答案
--
-- 判分在 App 本地做（选择/判断是有限答案集），服务端**复算**一遍入库 ——
-- 这样即使客户端算错或被抓包改分数，库里那一行仍然是按题目答案算出来的。
-- 答案要下发给客户端是刻意的取舍，理由见 ai-gateway
-- `handlers.checkinGenerate`：本轮不是考试，弱网下等一次判分的体验更糟。
--
-- ## 日期由客户端给
--
-- 与 `study_plan_checkin` 同一条规矩（R4）：服务端按 UTC 算日期，晚上 8 点后
-- 打卡会记到明天。所以这里只校验格式与范围，不自己生成。

CREATE TABLE IF NOT EXISTS checkin_quiz (
  id            TEXT PRIMARY KEY,
  -- 谁做这份打卡。家长发起时这里是孩子，学生自练时是自己。
  student_id    TEXT NOT NULL,
  -- 发起人。家长发起时是家长 id，学生自练时留空。
  owner_user_id TEXT NOT NULL DEFAULT '',
  quiz_date     DATE NOT NULL,
  subject       TEXT NOT NULL DEFAULT '',
  -- 题目快照：[{type, stem, options, answer, knowledge, analysis}]。
  -- 存快照而不是引用题库：题目由模型现场生成，没有可引用的稳定 id；
  -- 而且历史打卡必须能复现当时考的是什么。
  questions     JSONB NOT NULL,
  -- pending（已出题待答）/ done（已提交）
  status        TEXT NOT NULL DEFAULT 'pending',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- 一天一份。重复发起走 upsert（覆盖题目、结果作废重来），
  -- 不是新增一行 —— 否则「今天的打卡」会有好几份，谁也不知道该看哪份。
  CONSTRAINT uq_checkin_quiz UNIQUE (student_id, quiz_date)
);

CREATE INDEX IF NOT EXISTS idx_checkin_quiz_student_date
  ON checkin_quiz(student_id, quiz_date DESC);

CREATE TABLE IF NOT EXISTS checkin_result (
  quiz_id      TEXT PRIMARY KEY REFERENCES checkin_quiz(id) ON DELETE CASCADE,
  student_id   TEXT NOT NULL DEFAULT '',
  -- 原始作答：[{index, picked}]。保留原始而不是只留分数：
  -- 学生复盘时要看的是「我在第 3 题选了 B」，只留分数就永远答不出来。
  answers      JSONB NOT NULL,
  score        INTEGER NOT NULL DEFAULT 0,
  total        INTEGER NOT NULL DEFAULT 0,
  submitted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_checkin_result_student
  ON checkin_result(student_id, submitted_at DESC);

-- ===== RLS：与 focus_session 同一套口径 =====
-- 可见集合 = 自己 + 家长可见的 active 孩子。家长能看到孩子的打卡、也能替他发起；
-- 学生只能碰自己的。不需要额外的家族策略（与 ima 不同：那边是「孩子的环境里
-- 没有家长的凭证」，而这里归属列就是学生本人）。
ALTER TABLE checkin_quiz ENABLE ROW LEVEL SECURITY;
ALTER TABLE checkin_quiz FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON checkin_quiz USING (
  student_id = ANY(app_csv_setting('app.visible_students'))
);

ALTER TABLE checkin_result ENABLE ROW LEVEL SECURITY;
ALTER TABLE checkin_result FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON checkin_result USING (
  student_id = ANY(app_csv_setting('app.visible_students'))
);
