-- ═══════════════════════════════════════════════════════════════════════════
-- 伴学 APP —— 数据库终态 DDL（PostgreSQL 17 / 18）
--
-- 本文件是「一次建到最终形态」的合并 DDL，由原工程 001~029 共 29 个增量迁移合并而来。
-- 只含结构定义：建表 / 索引 / 约束 / 域 / 函数 / RLS 策略 / 授权。
-- 不含：任何口令、任何账号、任何真实业务数据、任何数据 dump。
-- 不含：BEGIN / COMMIT —— 由 scripts/init-db.mjs 包在单事务里执行。
--
-- 执行顺序：001_schema.sql → 002_seed.sql（顺序不可颠倒）
--
-- 三条全局约定：
--   ① 列名 snake_case；API 传输仍是 camelCase，映射只在 DAO 层做一次。
--   ② 客户端写入的时间必须是带时区的 ISO8601，否则 TIMESTAMPTZ 会按服务端时区解释。
--   ③ 所有路径列的类型是 rel_path 域 —— 数据库层面拒绝绝对路径；根目录只由
--      STORAGE_ROOT 环境变量配置，解析逻辑只在 backend/shared/paths.js。
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- 0. 相对路径域（★ 用户要求：数据库不存绝对路径）
--
-- 规则：允许空串（历史行兼容）；非空时必须是
--   · 不以 / 或 \ 开头（Unix / Windows 绝对路径、UNC）
--   · 不含盘符（第二个字符不是 ':'，挡 C:/ 与 C:\）
--   · 不含任何反斜杠（统一用 / 分隔，不跟操作系统漂）
--   · 不含 '..' 片段（挡路径穿越）
--   · 不以 / 结尾（必须是文件而不是目录）
--
-- 把规则做成 DOMAIN 而不是「每个表各写一条 CHECK」，是为了让语义只有一处定义：
-- 新增附件表时，只要声明成 rel_path 就自动继承全部约束。
-- ───────────────────────────────────────────────────────────────────────────
CREATE DOMAIN rel_path AS TEXT
  CHECK (
    VALUE = '' OR (
      left(VALUE, 1) <> '/'
      AND left(VALUE, 1) <> chr(92)
      AND position(chr(92) in VALUE) = 0
      AND position('..' in VALUE) = 0
      AND substring(VALUE from 2 for 1) <> ':'
      AND right(VALUE, 1) <> '/'
    )
  );

COMMENT ON DOMAIN rel_path IS
  '相对 STORAGE_ROOT 的路径；禁止绝对路径、盘符、反斜杠、.. 上跳。根目录只在环境变量中配置。';

-- ───────────────────────────────────────────────────────────────────────────
-- 1. 账号 / 凭证 / 会话
-- ───────────────────────────────────────────────────────────────────────────

-- 口令哈希单独放一张表：家长看孩子资料，不该顺带授权「读孩子密码」。
-- phone / wechat_open_id 允许多个 NULL（PG 的 UNIQUE 不比较 NULL）。
-- avatar 存 emoji 或 'student' / 'parent'，不是图片 URL；将来接自定义头像另加列。
CREATE TABLE app_user (
  id              TEXT PRIMARY KEY,
  name            TEXT NOT NULL,
  phone           TEXT,
  role            TEXT NOT NULL,
  avatar          TEXT NOT NULL,
  wechat_open_id  TEXT,
  gender          TEXT NOT NULL DEFAULT '',
  grade           TEXT NOT NULL DEFAULT '',
  term            TEXT NOT NULL DEFAULT '',
  hobbies         TEXT NOT NULL DEFAULT '',
  bio             TEXT NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX uq_user_phone  ON app_user(phone);
CREATE UNIQUE INDEX uq_user_wechat ON app_user(wechat_open_id);

CREATE TABLE app_user_credential (
  user_id             TEXT PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  password_hash       TEXT NOT NULL,
  password_updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE user_session (
  id            TEXT PRIMARY KEY,
  user_id       TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  issued_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at    TIMESTAMPTZ NOT NULL,
  revoked_at    TIMESTAMPTZ,
  revoke_reason TEXT NOT NULL DEFAULT '',
  client        TEXT NOT NULL DEFAULT ''
);
CREATE INDEX idx_user_session_alive ON user_session(user_id) WHERE revoked_at IS NULL;

-- ───────────────────────────────────────────────────────────────────────────
-- 2. 家庭关系 / 聊天
-- ───────────────────────────────────────────────────────────────────────────

-- status 状态机 pending → active / rejected；词的唯一来源是 backend/shared 的词表。
-- 这张表是 RLS 计算 visible_students 的两个来源之一。
CREATE TABLE relationship (
  id         TEXT PRIMARY KEY,
  student_id TEXT NOT NULL,
  parent_id  TEXT NOT NULL,
  sender_id  TEXT NOT NULL,
  status     TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_relation UNIQUE (student_id, parent_id)
);

CREATE TABLE chat_message (
  id              TEXT PRIMARY KEY,
  relationship_id TEXT NOT NULL,
  sender_id       TEXT NOT NULL,
  receiver_id     TEXT NOT NULL,
  content         TEXT NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  is_read         BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX idx_chat_message_relationship ON chat_message(relationship_id, created_at);

-- ───────────────────────────────────────────────────────────────────────────
-- 3. 作业与附件
-- ───────────────────────────────────────────────────────────────────────────

-- grading_source 记录这次判定是云端模型给的还是本地规则给的，不能丢。
-- user_role 只是历史字段，不再作为授权依据（身份只由 token 给）。
CREATE TABLE homework (
  id                TEXT PRIMARY KEY,
  title             TEXT,
  subject           TEXT,
  image_url         TEXT,
  due_at            TIMESTAMPTZ,
  estimated_minutes NUMERIC(6,2),
  status            TEXT,
  wrong_count       INTEGER,
  ai_enabled        BOOLEAN,
  needs_grading     BOOLEAN NOT NULL DEFAULT TRUE,
  user_role         TEXT,
  student_id        TEXT NOT NULL DEFAULT '',
  submitted_at      TIMESTAMPTZ,
  checked_at        TIMESTAMPTZ,
  score             INTEGER,
  summary           TEXT NOT NULL DEFAULT '',
  image_count       INTEGER NOT NULL DEFAULT 0,
  submit_batch_id   TEXT NOT NULL DEFAULT '',
  grading_source    TEXT NOT NULL DEFAULT '',
  actual_seconds    INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_homework_student_status ON homework(student_id, status);
CREATE INDEX idx_homework_submitted_at   ON homework(student_id, submitted_at DESC);

-- ★ 附件表：库里只存 relative_path（相对 STORAGE_ROOT），字节在文件系统 / 对象存储。
--   读取入口是 GET /data/attachments/:id —— 客户端不传路径，所以「路径穿越」没有入口。
--   旧工程列名 storage_key / file_path / photo_path，本包统一为 relative_path，
--   映射表见 docs/database.md。
CREATE TABLE homework_image (
  id            TEXT PRIMARY KEY,
  student_id    TEXT NOT NULL,
  homework_id   TEXT,
  relative_path rel_path NOT NULL,
  file_name     TEXT NOT NULL,
  file_size     INTEGER NOT NULL,
  mime_type     TEXT NOT NULL,
  ocr_status    TEXT NOT NULL,
  ocr_text      TEXT NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  batch_id      TEXT NOT NULL DEFAULT '',
  sort_order    INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_homework_image_homework ON homework_image(homework_id);

-- ───────────────────────────────────────────────────────────────────────────
-- 4. 运动计划
-- ───────────────────────────────────────────────────────────────────────────

-- start_time / end_time 存展示串 '17:30'，不是 TIME（改成 TIME 读回来会多 ':00'）。
-- weekdays / custom_weekdays 是 JSON 数组字符串，刻意不改成 JSONB。
CREATE TABLE workout_plan (
  id              TEXT PRIMARY KEY,
  title           TEXT,
  project         TEXT,
  weekdays        TEXT,
  target_minutes  INTEGER,
  is_active       BOOLEAN,
  start_date      TIMESTAMPTZ,
  end_date        TIMESTAMPTZ,
  start_time      TEXT,
  end_time        TEXT,
  cycle_type      TEXT,
  custom_weekdays TEXT,
  student_id      TEXT NOT NULL DEFAULT ''
);

-- start_at / end_at 是业务时间（学生实际做的时刻），不由服务端 now() 覆盖。
CREATE TABLE workout_record (
  id         TEXT PRIMARY KEY,
  project    TEXT,
  start_at   TIMESTAMPTZ,
  end_at     TIMESTAMPTZ,
  minutes    INTEGER,
  feedback   TEXT,
  plan_id    TEXT,
  student_id TEXT NOT NULL DEFAULT ''
);
CREATE INDEX idx_workout_record_student ON workout_record(student_id, start_at DESC);

-- ───────────────────────────────────────────────────────────────────────────
-- 5. 错题与复习闭环
-- ───────────────────────────────────────────────────────────────────────────

-- state 状态机：pending → reviewing → verifying → mastered，中间态不能省。
CREATE TABLE review_mistake (
  id                    TEXT PRIMARY KEY,
  subject               TEXT,
  title                 TEXT,
  original_answer       TEXT,
  wrong_reason          TEXT,
  created_at            TIMESTAMPTZ DEFAULT now(),
  state                 TEXT,
  student_id            TEXT NOT NULL DEFAULT '',
  homework_id           TEXT NOT NULL DEFAULT '',
  knowledge_point       TEXT NOT NULL DEFAULT '',
  wrong_count           INTEGER NOT NULL DEFAULT 1,
  last_wrong_at         TIMESTAMPTZ,
  source_homework_title TEXT NOT NULL DEFAULT '',
  mastered_at           TIMESTAMPTZ,
  mastered_by_self      BOOLEAN NOT NULL DEFAULT FALSE,
  review_round          INTEGER NOT NULL DEFAULT 0,
  last_reviewed_at      TIMESTAMPTZ,
  question_body         TEXT NOT NULL DEFAULT '',
  answer_key            TEXT NOT NULL DEFAULT '',
  source_type           TEXT NOT NULL DEFAULT 'manual',
  grade                 TEXT NOT NULL DEFAULT '',
  term                  TEXT NOT NULL DEFAULT '',
  image_count           INTEGER NOT NULL DEFAULT 0,
  question_no           TEXT NOT NULL DEFAULT '',
  student_process       TEXT NOT NULL DEFAULT '',
  source_ref            TEXT NOT NULL DEFAULT ''
);
CREATE INDEX idx_review_mistake_student    ON review_mistake(student_id, state);
CREATE INDEX idx_review_mistake_term       ON review_mistake(student_id, grade, term);
CREATE INDEX idx_review_mistake_source_ref ON review_mistake(source_ref);

CREATE TABLE review_mistake_image (
  id            TEXT PRIMARY KEY,
  student_id    TEXT NOT NULL DEFAULT '',
  mistake_id    TEXT NOT NULL,
  relative_path rel_path NOT NULL DEFAULT '',
  mime_type     TEXT NOT NULL DEFAULT '',
  file_size     BIGINT NOT NULL DEFAULT 0,
  sort_order    INTEGER NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_review_mistake_image_mistake ON review_mistake_image(mistake_id);

-- ★ 导出 PDF 的路径也只存相对路径（旧列名 file_path）。
CREATE TABLE review_paper (
  id               TEXT PRIMARY KEY,
  student_id       TEXT NOT NULL DEFAULT '',
  title            TEXT NOT NULL DEFAULT '',
  subject          TEXT NOT NULL DEFAULT '',
  knowledge_points TEXT NOT NULL DEFAULT '',
  status           TEXT NOT NULL DEFAULT 'draft',
  item_count       INTEGER NOT NULL DEFAULT 0,
  pass_count       INTEGER NOT NULL DEFAULT 0,
  fail_count       INTEGER NOT NULL DEFAULT 0,
  created_at       TIMESTAMPTZ DEFAULT now(),
  exported_at      TIMESTAMPTZ,
  submitted_at     TIMESTAMPTZ,
  graded_at        TIMESTAMPTZ,
  closed_at        TIMESTAMPTZ,
  relative_path    rel_path NOT NULL DEFAULT '',
  note             TEXT NOT NULL DEFAULT ''
);
CREATE INDEX idx_review_paper_student ON review_paper(student_id, status);

-- 卷内单题是**快照**：纸卷一旦印出去，学生手上的纸和库里的题就分叉了。
-- 不能照错题池重新生成。归属列是 paper_id，RLS 要顺着父卷判断。
CREATE TABLE review_paper_item (
  id              TEXT PRIMARY KEY,
  paper_id        TEXT NOT NULL,
  mistake_id      TEXT NOT NULL DEFAULT '',
  subject         TEXT NOT NULL DEFAULT '',
  knowledge_point TEXT NOT NULL DEFAULT '',
  question_title  TEXT NOT NULL DEFAULT '',
  question_body   TEXT NOT NULL DEFAULT '',
  original_answer TEXT NOT NULL DEFAULT '',
  wrong_reason    TEXT NOT NULL DEFAULT '',
  answer_key      TEXT NOT NULL DEFAULT '',
  sort_order      INTEGER NOT NULL DEFAULT 0,
  student_answer  TEXT NOT NULL DEFAULT '',
  result          TEXT NOT NULL DEFAULT 'pending',
  relative_path   rel_path NOT NULL DEFAULT '',
  comment         TEXT NOT NULL DEFAULT '',
  checked_at      TIMESTAMPTZ
);
CREATE INDEX idx_review_paper_item_paper ON review_paper_item(paper_id, sort_order);

-- 一行 = 一次比对，不是一次作答（交 3 题就有 3 行），一致率的分母才是真判定数。
CREATE TABLE judgement_ab (
  id              TEXT PRIMARY KEY,
  student_id      TEXT NOT NULL DEFAULT '',
  mistake_id      TEXT NOT NULL DEFAULT '',
  channel         TEXT NOT NULL DEFAULT 'paper',
  subject         TEXT NOT NULL DEFAULT '',
  knowledge_point TEXT NOT NULL DEFAULT '',
  model_verdict   TEXT NOT NULL DEFAULT '',
  rule_verdict    TEXT NOT NULL DEFAULT '',
  created_at      TIMESTAMPTZ DEFAULT now()
);

-- 毕业判定的唯一依据；不要往这里塞观测数据（那是 judgement_ab）。
CREATE TABLE review_attempt (
  id         TEXT PRIMARY KEY,
  student_id TEXT NOT NULL DEFAULT '',
  mistake_id TEXT NOT NULL DEFAULT '',
  paper_id   TEXT NOT NULL DEFAULT '',
  item_id    TEXT NOT NULL DEFAULT '',
  channel    TEXT NOT NULL DEFAULT 'paper',
  round      INTEGER NOT NULL DEFAULT 1,
  answer     TEXT NOT NULL DEFAULT '',
  correct    BOOLEAN NOT NULL DEFAULT FALSE,
  score      INTEGER NOT NULL DEFAULT 0,
  comment    TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_review_attempt_student ON review_attempt(student_id, created_at DESC);

CREATE TABLE ai_practice_question (
  id                TEXT PRIMARY KEY,
  student_id        TEXT NOT NULL DEFAULT '',
  source_mistake_id TEXT NOT NULL DEFAULT '',
  knowledge_point   TEXT NOT NULL DEFAULT '',
  subject           TEXT NOT NULL DEFAULT '',
  title             TEXT NOT NULL DEFAULT '',
  content           TEXT NOT NULL DEFAULT '',
  answer            TEXT NOT NULL DEFAULT '',
  difficulty        TEXT NOT NULL DEFAULT '基础',
  student_answer    TEXT NOT NULL DEFAULT '',
  state             TEXT NOT NULL DEFAULT 'pending',
  round             INTEGER NOT NULL DEFAULT 1,
  created_at        TIMESTAMPTZ DEFAULT now(),
  checked_at        TIMESTAMPTZ,
  question_type     TEXT NOT NULL DEFAULT 'solution',
  options_json      TEXT NOT NULL DEFAULT '[]',
  figure_json       TEXT
);

-- 讲解不构成毕业（看懂 ≠ 会做），只进过程时间线。
CREATE TABLE explain_record (
  id              TEXT PRIMARY KEY,
  student_id      TEXT NOT NULL DEFAULT '',
  mistake_id      TEXT NOT NULL DEFAULT '',
  knowledge_point TEXT NOT NULL DEFAULT '',
  channel         TEXT NOT NULL DEFAULT 'ai',
  summary         TEXT NOT NULL DEFAULT '',
  stay_seconds    INTEGER NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE review_summary (
  id              TEXT PRIMARY KEY,
  student_id      TEXT NOT NULL DEFAULT '',
  scope           TEXT NOT NULL DEFAULT 'paper',
  scope_key       TEXT NOT NULL DEFAULT '',
  total_count     INTEGER NOT NULL DEFAULT 0,
  pass_count      INTEGER NOT NULL DEFAULT 0,
  mastered_count  INTEGER NOT NULL DEFAULT 0,
  remain_count    INTEGER NOT NULL DEFAULT 0,
  pass_rate       NUMERIC(5,4) NOT NULL DEFAULT 0,
  weak_points     TEXT NOT NULL DEFAULT '',
  body            TEXT NOT NULL DEFAULT '',
  generated_at    TIMESTAMPTZ DEFAULT now()
);
CREATE UNIQUE INDEX uq_review_summary_period ON review_summary(student_id, scope, scope_key);
CREATE INDEX idx_review_summary_period ON review_summary(student_id, scope);

-- ───────────────────────────────────────────────────────────────────────────
-- 6. 计划 / 打卡 / 专注 / 心愿 / 积分
-- ───────────────────────────────────────────────────────────────────────────

CREATE TABLE wish (
  id                  TEXT PRIMARY KEY,
  title               TEXT,
  description         TEXT,
  is_public           BOOLEAN,
  parent_confirmed    BOOLEAN,
  student_confirmed   BOOLEAN,
  is_archived         BOOLEAN,
  user_role           TEXT,
  student_id          TEXT NOT NULL DEFAULT '',
  expected_date       TIMESTAMPTZ,
  point_cost          INTEGER NOT NULL DEFAULT 0,
  redeem_requested_at TIMESTAMPTZ,
  redeemed_at         TIMESTAMPTZ,
  redeem_rejected_at  TIMESTAMPTZ
);
CREATE INDEX idx_wish_student ON wish(student_id);

CREATE TABLE study_plan (
  id              TEXT PRIMARY KEY,
  title           TEXT,
  content         TEXT,
  start_at        TIMESTAMPTZ,
  end_at          TIMESTAMPTZ,
  type            TEXT,
  status          TEXT,
  user_role       TEXT,
  student_id      TEXT NOT NULL DEFAULT '',
  cycle_type      TEXT NOT NULL DEFAULT 'daily',
  custom_weekdays TEXT,
  reject_reason   TEXT
);
CREATE INDEX idx_study_plan_student ON study_plan(student_id, status);

-- date 是「学生所在时区的今天」，由客户端给；服务端只校验范围，不自己生成。
CREATE TABLE study_plan_checkin (
  id         TEXT PRIMARY KEY,
  plan_id    TEXT NOT NULL,
  student_id TEXT NOT NULL DEFAULT '',
  date       DATE NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT uq_checkin UNIQUE (plan_id, date)
);
CREATE INDEX idx_study_plan_checkin_student ON study_plan_checkin(student_id, date);

-- 专注计时：actualSeconds 写总量，暂停不计；一次会话一行 upsert。
CREATE TABLE focus_session (
  id         TEXT PRIMARY KEY,
  student_id TEXT NOT NULL DEFAULT '',
  kind       TEXT NOT NULL DEFAULT 'free',
  source_id  TEXT NOT NULL DEFAULT '',
  title      TEXT NOT NULL DEFAULT '',
  date       TEXT NOT NULL DEFAULT '',
  seconds    INTEGER NOT NULL DEFAULT 0,
  started_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_focus_session_student_date   ON focus_session(student_id, date);
CREATE INDEX idx_focus_session_student_target ON focus_session(student_id, kind, source_id);

-- 没配的行 = 用出厂默认值，所以不需要预生成一堆行。
CREATE TABLE point_rule (
  student_id TEXT NOT NULL,
  action     TEXT NOT NULL,
  points     INTEGER NOT NULL DEFAULT 0,
  enabled    BOOLEAN NOT NULL DEFAULT TRUE,
  updated_at TIMESTAMPTZ,
  PRIMARY KEY (student_id, action)
);

-- 余额永远由这张表求和得来，不另存字段。
-- 部分唯一索引的谓词必须原样写进 ON CONFLICT，否则报 42P10。
CREATE TABLE point_ledger (
  id              TEXT PRIMARY KEY,
  student_id      TEXT NOT NULL DEFAULT '',
  action          TEXT NOT NULL DEFAULT '',
  points          INTEGER NOT NULL DEFAULT 0,
  reason          TEXT NOT NULL DEFAULT '',
  idempotency_key TEXT NOT NULL DEFAULT '',
  reversal_of     TEXT NOT NULL DEFAULT '',
  ref_type        TEXT NOT NULL DEFAULT '',
  ref_id          TEXT NOT NULL DEFAULT '',
  created_at      TIMESTAMPTZ DEFAULT now(),
  created_by      TEXT NOT NULL DEFAULT '',
  reversed_at     TIMESTAMPTZ
);
CREATE UNIQUE INDEX idx_point_ledger_active_key
  ON point_ledger(idempotency_key)
  WHERE idempotency_key <> '' AND reversed_at IS NULL;
CREATE INDEX idx_point_ledger_student ON point_ledger(student_id, created_at);

-- ───────────────────────────────────────────────────────────────────────────
-- 7. 通知 / 点评
-- ───────────────────────────────────────────────────────────────────────────

CREATE TABLE app_notification (
  id              TEXT PRIMARY KEY,
  title           TEXT NOT NULL,
  body            TEXT NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  is_read         BOOLEAN NOT NULL DEFAULT FALSE,
  target_user_id  TEXT NOT NULL DEFAULT '',
  type            TEXT NOT NULL DEFAULT 'system',
  related_biz_id  TEXT NOT NULL DEFAULT ''
);
CREATE INDEX idx_notification_target ON app_notification(target_user_id, created_at DESC);

-- is_read 在广播行上无法表达「谁已读」，所以已读状态按 (通知, 用户) 拆开存。
CREATE TABLE app_notification_read (
  notification_id TEXT NOT NULL REFERENCES app_notification(id) ON DELETE CASCADE,
  user_id         TEXT NOT NULL,
  read_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (notification_id, user_id)
);

CREATE TABLE daily_comment (
  id         TEXT PRIMARY KEY,
  rating     TEXT NOT NULL,
  content    TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  student_id TEXT NOT NULL DEFAULT ''
);
CREATE INDEX idx_daily_comment_student ON daily_comment(student_id, created_at DESC);

-- ───────────────────────────────────────────────────────────────────────────
-- 8. 家长打卡（一次出题 = 一份独立试卷）
-- ───────────────────────────────────────────────────────────────────────────

-- 题目存快照而不是引用题库：模型现场生成，没有稳定 id；历史打卡必须能复现。
-- 最终态**没有** (student_id, quiz_date, subject) 唯一约束 —— 022 已删除，
-- 因为同一天同科目允许多套试卷，防串题靠每次新 id。
CREATE TABLE checkin_quiz (
  id            TEXT PRIMARY KEY,
  student_id    TEXT NOT NULL,
  owner_user_id TEXT NOT NULL DEFAULT '',
  quiz_date     DATE NOT NULL,
  subject       TEXT NOT NULL DEFAULT '',
  questions     JSONB NOT NULL,
  status        TEXT NOT NULL DEFAULT 'pending',
  difficulty    TEXT NOT NULL DEFAULT '',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_checkin_quiz_questions CHECK (jsonb_typeof(questions) = 'array')
);
CREATE INDEX idx_checkin_quiz_student_date ON checkin_quiz(student_id, quiz_date);

-- answers 保留原始作答 [{index, picked}]，不是只留分数：
-- 学生复盘要看「第 3 题我选了 B」。
CREATE TABLE checkin_result (
  quiz_id      TEXT PRIMARY KEY REFERENCES checkin_quiz(id) ON DELETE CASCADE,
  student_id   TEXT NOT NULL DEFAULT '',
  answers      JSONB NOT NULL,
  score        INTEGER NOT NULL DEFAULT 0,
  total        INTEGER NOT NULL DEFAULT 0,
  submitted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_checkin_result_student ON checkin_result(student_id, submitted_at DESC);

-- ───────────────────────────────────────────────────────────────────────────
-- 9. 学科范围与教材（出题不读 ima，只读这里的结构化骨架）
-- ───────────────────────────────────────────────────────────────────────────

CREATE TABLE subject_scope (
  student_id     TEXT NOT NULL,
  subject        TEXT NOT NULL,
  daily_count    INTEGER NOT NULL DEFAULT 5,
  difficulty     TEXT NOT NULL DEFAULT '基础',
  points         JSONB NOT NULL DEFAULT '[]'::jsonb,
  book_id        TEXT,
  start_unit_no  INTEGER NOT NULL DEFAULT 1,
  units_per_day  INTEGER NOT NULL DEFAULT 1,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (student_id, subject),
  CONSTRAINT ck_subject_scope_count      CHECK (daily_count IN (3, 5, 8)),
  CONSTRAINT ck_subject_scope_difficulty CHECK (difficulty IN ('基础', '提高', '挑战')),
  CONSTRAINT ck_subject_scope_points     CHECK (jsonb_typeof(points) = 'array'),
  CONSTRAINT ck_subject_scope_start_unit CHECK (start_unit_no >= 1),
  CONSTRAINT ck_subject_scope_units_day  CHECK (units_per_day IN (1, 2, 3))
);

-- grade / term 是**书本身的属性**，只在导入时由家长显式选择，绝不解析 ima 路径。
CREATE TABLE subject_book (
  id              TEXT PRIMARY KEY,
  student_id      TEXT NOT NULL,
  subject         TEXT NOT NULL,
  title           TEXT NOT NULL,
  source          TEXT NOT NULL DEFAULT 'ima',
  source_media_id TEXT NOT NULL DEFAULT '',
  source_path     rel_path NOT NULL DEFAULT '',
  grade           TEXT NOT NULL DEFAULT '',
  term            TEXT NOT NULL DEFAULT '',
  unit_count      INTEGER NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_subject_book_unit_count CHECK (unit_count >= 0)
);
CREATE UNIQUE INDEX ux_subject_book_media ON subject_book(student_id, source_media_id)
  WHERE source_media_id <> '';
CREATE INDEX ix_subject_book_student_subject_grade ON subject_book(student_id, subject, grade);

-- unit_no 是文档顺序（1 起），不是从标题解析出来的章号。
-- summary 为空时，章节标题本身就是知识点。
CREATE TABLE subject_unit (
  id         TEXT PRIMARY KEY,
  book_id    TEXT NOT NULL REFERENCES subject_book(id) ON DELETE CASCADE,
  student_id TEXT NOT NULL,
  unit_no    INTEGER NOT NULL,
  title      TEXT NOT NULL,
  summary    TEXT NOT NULL DEFAULT '',
  page_hint  TEXT NOT NULL DEFAULT '',
  CONSTRAINT uq_subject_unit UNIQUE (book_id, unit_no)
);
CREATE INDEX ix_subject_unit_book ON subject_unit(book_id, unit_no);

-- ───────────────────────────────────────────────────────────────────────────
-- 10. 英文阅读（任务挂书不挂天，所以没有顺延）
-- ───────────────────────────────────────────────────────────────────────────

CREATE TABLE reading_book (
  id              TEXT PRIMARY KEY,
  student_id      TEXT NOT NULL,
  owner_user_id   TEXT NOT NULL DEFAULT '',
  title           TEXT NOT NULL,
  author          TEXT NOT NULL DEFAULT '',
  intro           TEXT NOT NULL DEFAULT '',
  source          TEXT NOT NULL DEFAULT 'ima',
  source_media_id TEXT NOT NULL DEFAULT '',
  source_path     rel_path NOT NULL DEFAULT '',
  lesson_count    INTEGER NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_reading_book_source ON reading_book(student_id, source_media_id)
  WHERE source_media_id <> '';
CREATE INDEX idx_reading_book_student ON reading_book(student_id);

-- 冗余 student_id 是给 RLS 用的：不冗余就得写子查询，而子查询本身也受 RLS 约束。
CREATE TABLE reading_lesson (
  id          TEXT PRIMARY KEY,
  book_id     TEXT NOT NULL REFERENCES reading_book(id) ON DELETE CASCADE,
  student_id  TEXT NOT NULL,
  lesson_no   INTEGER NOT NULL,
  title       TEXT NOT NULL DEFAULT '',
  title_zh    TEXT NOT NULL DEFAULT '',
  body        TEXT NOT NULL DEFAULT '',
  vocabulary  JSONB NOT NULL DEFAULT '[]'::jsonb,
  translation TEXT NOT NULL DEFAULT '',
  char_count  INTEGER NOT NULL DEFAULT 0,
  CONSTRAINT uq_reading_lesson UNIQUE (book_id, lesson_no)
);
CREATE INDEX idx_reading_lesson_book ON reading_lesson(book_id, lesson_no);

-- total_lessons 是布置那一刻的快照：书将来增补课，不该让任务突然多出 24 篇。
CREATE TABLE reading_task (
  id            TEXT PRIMARY KEY,
  student_id    TEXT NOT NULL,
  book_id       TEXT NOT NULL REFERENCES reading_book(id) ON DELETE CASCADE,
  owner_user_id TEXT NOT NULL DEFAULT '',
  daily_target  INTEGER NOT NULL DEFAULT 1,
  total_lessons INTEGER NOT NULL DEFAULT 0,
  status        TEXT NOT NULL DEFAULT 'active',
  started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at  TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_reading_task_active_book ON reading_task(book_id) WHERE status = 'active';
CREATE INDEX idx_reading_task_student ON reading_task(student_id, status);

-- day 是客户端给的本地日；服务端按 UTC 算会让晚上 8 点后的打卡记到明天。
CREATE TABLE reading_log (
  id         TEXT PRIMARY KEY,
  task_id    TEXT NOT NULL REFERENCES reading_task(id) ON DELETE CASCADE,
  student_id TEXT NOT NULL,
  book_id    TEXT NOT NULL,
  lesson_no  INTEGER NOT NULL,
  day        DATE NOT NULL,
  read_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_reading_log_lesson UNIQUE (task_id, lesson_no)
);
CREATE INDEX idx_reading_log_task_day    ON reading_log(task_id, day);
CREATE INDEX idx_reading_log_student     ON reading_log(student_id, day);

-- ───────────────────────────────────────────────────────────────────────────
-- 11. 英语单词打卡（出题 / 判分 / 权重全在本地，断网可用）
-- ───────────────────────────────────────────────────────────────────────────

CREATE TABLE word_book (
  id              TEXT PRIMARY KEY,
  student_id      TEXT NOT NULL,
  owner_user_id   TEXT NOT NULL DEFAULT '',
  title           TEXT NOT NULL,
  source          TEXT NOT NULL DEFAULT 'ima',
  source_media_id TEXT NOT NULL DEFAULT '',
  source_path     rel_path NOT NULL DEFAULT '',
  grade           TEXT NOT NULL DEFAULT '',
  term            TEXT NOT NULL DEFAULT '',
  unit_count      INTEGER NOT NULL DEFAULT 0,
  word_count      INTEGER NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_word_book_source ON word_book(student_id, source_media_id)
  WHERE source_media_id <> '';
CREATE INDEX ix_word_book_student_grade ON word_book(student_id, grade);

-- unit_order = MD 里 `## Unit N` 的出现顺序，不按标题文本排序。
CREATE TABLE word_entry (
  id              TEXT PRIMARY KEY,
  book_id         TEXT NOT NULL REFERENCES word_book(id) ON DELETE CASCADE,
  student_id      TEXT NOT NULL,
  unit            TEXT NOT NULL,
  unit_order      INTEGER NOT NULL DEFAULT 1,
  word            TEXT NOT NULL,
  phonetic        TEXT NOT NULL DEFAULT '',
  meaning         TEXT NOT NULL DEFAULT '',
  primary_meaning TEXT NOT NULL DEFAULT '',
  normalized_word TEXT NOT NULL DEFAULT '',
  sort_no         INTEGER NOT NULL DEFAULT 0,
  CONSTRAINT uq_word_entry UNIQUE (book_id, unit, normalized_word)
);
CREATE INDEX idx_word_entry_student_unit ON word_entry(student_id, book_id, unit_order);

CREATE TABLE word_daily_result (
  student_id  TEXT NOT NULL,
  day         DATE NOT NULL,
  total       INTEGER NOT NULL DEFAULT 0,
  correct     INTEGER NOT NULL DEFAULT 0,
  streak      INTEGER NOT NULL DEFAULT 0,
  wrong_words JSONB NOT NULL DEFAULT '[]'::jsonb,
  synced_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (student_id, day)
);

CREATE TABLE word_scope (
  student_id     TEXT PRIMARY KEY,
  book_id        TEXT NOT NULL DEFAULT '',
  unit_mode      TEXT NOT NULL DEFAULT 'learned',
  current_unit   TEXT NOT NULL DEFAULT '',
  selected_units JSONB NOT NULL DEFAULT '[]'::jsonb,
  daily_count    INTEGER NOT NULL DEFAULT 10,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_word_scope_mode  CHECK (unit_mode IN ('current', 'learned', 'selected', 'all')),
  CONSTRAINT ck_word_scope_count CHECK (daily_count BETWEEN 1 AND 50)
);

-- ───────────────────────────────────────────────────────────────────────────
-- 12. ima 知识库（可选能力：没配置时功能静默降级，不报错）
-- ───────────────────────────────────────────────────────────────────────────

-- 凭证密文；加密密钥 IMA_CREDENTIAL_SECRET 只在环境变量里，绝不落库。
CREATE TABLE ima_credential (
  owner_user_id TEXT PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  clientid_enc  TEXT NOT NULL,
  apikey_enc    TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'unconnected',
  kb_owner_name TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 父母共享一行，1 生 1 KB；学生只读。
CREATE TABLE ima_student_kb (
  student_id    TEXT PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  owner_user_id TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  kb_id         TEXT NOT NULL,
  kb_name       TEXT NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (owner_user_id, kb_id)
);

-- ───────────────────────────────────────────────────────────────────────────
-- 13. 通用字典（整理版新增：把散落在 JS / Dart 常量里的词收进 DB）
--
-- 原工程把学科写在 backend/data-service/src/subjects.js、年级写在 Dart 常量里，
-- 两处各一份，早晚分叉。交接基线把它们收成一张表，种子见 002_seed.sql。
-- 这张表不启用 RLS：它是公共只读字典，不含任何用户数据。
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE app_dict (
  dict_type  TEXT NOT NULL,
  code       TEXT NOT NULL,
  label      TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  enabled    BOOLEAN NOT NULL DEFAULT TRUE,
  PRIMARY KEY (dict_type, code),
  CONSTRAINT ck_app_dict_type CHECK (dict_type IN ('subject', 'grade', 'status', 'difficulty'))
);

-- ═══════════════════════════════════════════════════════════════════════════
-- 14. 行级安全（RLS）
--
-- 核心口径：不按角色写 policy，而是先算出「这个请求能看哪些学生」
--          （app.visible_students，逗号分隔），policy 形状与集合怎么算的无关。
-- 变量一律在**事务内**用 SET LOCAL 设置；用会话级 SET 会让连接池把上一个人的
-- 身份带给下一个请求。
--
-- ⚠️ superuser 永远绕过 RLS，连 FORCE ROW LEVEL SECURITY 也拦不住，且不报错。
--    应用连接必须用非 superuser 的 app_rls 角色。
-- ⚠️ 完整策略演进（002 / 003 / 004 / 005 / 008 / 010 / 018 / 024）留在原仓库，
--    迁入业务代码时须逐条核对，见 docs/source-index.md。
-- ═══════════════════════════════════════════════════════════════════════════

-- 解析会话变量并去掉空元素。
-- 为什么必须多这一步：string_to_array(',,', ',') = {'','',''}，会匹配
-- student_id = '' 的「无主行」，让那行对所有用户可见。两个条件都罕见且都不报错。
-- STABLE 而不是 IMMUTABLE：读会话变量，跨语句会变，标错会让 PG 在错误粒度上缓存。
CREATE OR REPLACE FUNCTION app_csv_setting(setting_name text) RETURNS text[]
  LANGUAGE sql
  STABLE
  AS $$
    SELECT array_remove(
      string_to_array(current_setting(setting_name, true), ','),
      ''
    )
  $$;

-- 应用角色：口令**不在这里**，由 scripts/init-db.mjs 用 APP_RLS_PASSWORD 设置。
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'app_rls') THEN
    CREATE ROLE app_rls LOGIN;
  END IF;
END
$$;

-- 归属列 = student_id 的表，统一一条形状。
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'homework', 'homework_image', 'workout_plan', 'workout_record',
    'review_mistake', 'review_mistake_image', 'review_paper',
    'judgement_ab', 'review_attempt', 'ai_practice_question',
    'explain_record', 'review_summary', 'wish', 'study_plan',
    'study_plan_checkin', 'focus_session', 'daily_comment',
    'point_rule', 'point_ledger', 'checkin_quiz', 'checkin_result',
    'subject_scope', 'subject_book', 'subject_unit',
    'reading_book', 'reading_lesson', 'reading_task', 'reading_log',
    'word_book', 'word_entry', 'word_daily_result', 'word_scope',
    'ima_student_kb'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format($f$
      CREATE POLICY own_rows ON %I
      USING (student_id = ANY(app_csv_setting('app.visible_students')))
      WITH CHECK (student_id = ANY(app_csv_setting('app.visible_students')))
    $f$, t);
  END LOOP;
END
$$;

-- review_paper_item 自己不带 student_id，可见性要顺着父卷判断。
-- 漏掉 ENABLE/FORCE 的后果是静默的：policy 建得好好的，表却完全开放。
ALTER TABLE review_paper_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE review_paper_item FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON review_paper_item
  USING (paper_id IN (
    SELECT p.id FROM review_paper p
    WHERE p.student_id = ANY(app_csv_setting('app.visible_students'))
  ))
  WITH CHECK (paper_id IN (
    SELECT p.id FROM review_paper p
    WHERE p.student_id = ANY(app_csv_setting('app.visible_students'))
  ));

-- app_user：自己 + 可见学生 + 结伴的家长/学生。
-- 子查询引用 relationship，而 relationship 的策略不引用 app_user，因此不会递归。
ALTER TABLE app_user ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_user FORCE ROW LEVEL SECURITY;
CREATE POLICY user_read ON app_user FOR SELECT USING (
  id = current_setting('app.user_id', true)
  OR id = ANY(app_csv_setting('app.visible_students'))
  OR EXISTS (
    SELECT 1 FROM relationship r
    WHERE (r.student_id = app_user.id AND r.parent_id = current_setting('app.user_id', true))
       OR (r.parent_id = app_user.id AND r.student_id = current_setting('app.user_id', true))
  )
);
CREATE POLICY user_write_self ON app_user FOR UPDATE
  USING (id = current_setting('app.user_id', true))
  WITH CHECK (id = current_setting('app.user_id', true));

-- relationship 是计算 visible_students 的来源之一，自己不能用同一集合过滤。
ALTER TABLE relationship ENABLE ROW LEVEL SECURITY;
ALTER TABLE relationship FORCE ROW LEVEL SECURITY;
CREATE POLICY relation_access ON relationship
  USING (
    student_id = ANY(app_csv_setting('app.visible_students'))
    OR parent_id = current_setting('app.user_id', true)
    OR sender_id = current_setting('app.user_id', true)
  )
  WITH CHECK (
    parent_id = current_setting('app.user_id', true)
    OR student_id = current_setting('app.user_id', true)
    OR sender_id = current_setting('app.user_id', true)
  );

ALTER TABLE chat_message ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat_message FORCE ROW LEVEL SECURITY;
CREATE POLICY chat_access ON chat_message
  USING (
    sender_id = current_setting('app.user_id', true)
    OR receiver_id = current_setting('app.user_id', true)
  )
  WITH CHECK (sender_id = current_setting('app.user_id', true));

ALTER TABLE user_session ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_session FORCE ROW LEVEL SECURITY;
CREATE POLICY session_own ON user_session
  USING (user_id = current_setting('app.user_id', true))
  WITH CHECK (user_id = current_setting('app.user_id', true));

ALTER TABLE app_user_credential ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_user_credential FORCE ROW LEVEL SECURITY;
CREATE POLICY credential_own ON app_user_credential
  USING (user_id = current_setting('app.user_id', true))
  WITH CHECK (user_id = current_setting('app.user_id', true));

-- 广播行的 target_user_id = '' 表示所有人可见。
ALTER TABLE app_notification ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_notification FORCE ROW LEVEL SECURITY;
CREATE POLICY notification_read ON app_notification FOR SELECT USING (
  target_user_id = '' OR target_user_id = current_setting('app.user_id', true)
);
CREATE POLICY notification_insert ON app_notification FOR INSERT
  WITH CHECK (true);

ALTER TABLE app_notification_read ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_notification_read FORCE ROW LEVEL SECURITY;
CREATE POLICY notification_read_own ON app_notification_read
  USING (user_id = current_setting('app.user_id', true))
  WITH CHECK (user_id = current_setting('app.user_id', true));

ALTER TABLE ima_credential ENABLE ROW LEVEL SECURITY;
ALTER TABLE ima_credential FORCE ROW LEVEL SECURITY;
CREATE POLICY ima_credential_own ON ima_credential
  USING (owner_user_id = current_setting('app.user_id', true))
  WITH CHECK (owner_user_id = current_setting('app.user_id', true));

-- app_dict 刻意不启用 RLS：公共只读字典，不含用户数据。

-- ═══════════════════════════════════════════════════════════════════════════
-- 15. 授权（必须放在所有表建完之后）
-- ═══════════════════════════════════════════════════════════════════════════
GRANT USAGE ON SCHEMA public TO app_rls;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_rls;
GRANT EXECUTE ON FUNCTION app_csv_setting(text) TO app_rls;

-- ─────────────────────────────────────────────────────────────────────────
-- 16. 认证辅助函数（SECURITY DEFINER）
--
-- 登录时还没有身份，policy 一律 fail-closed，所以这两个查询必须由
-- SECURITY DEFINER 函数以建表者身份执行。安全边界靠三件事收住：
--   · REVOKE ... FROM PUBLIC，只授给应用角色；
--   · SET search_path 固定，防搜索路径劫持；
--   · 返回值只含认证必需的最小列集，且全部参数化。
-- 业务数据查询**不得**走这条路，一律用 withTenant() 的 SET LOCAL 事务。
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION auth_lookup_credential(p_phone text)
RETURNS TABLE (out_user_id text, out_password_hash text, out_role text, out_name text)
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path = public, pg_temp
  AS $$
    SELECT u.id, c.password_hash, u.role, u.name
    FROM app_user u
    JOIN app_user_credential c ON c.user_id = u.id
    WHERE u.phone = p_phone
    LIMIT 1
  $$;

-- 可见集合：active 关系里的学生；用户本人是学生时把自己也算进去。
-- 'active' 必须与 backend/shared/errors.js 的 RELATIONSHIP_STATUS.ACTIVE 逐字一致。
CREATE OR REPLACE FUNCTION auth_visible_students(p_user_id text)
RETURNS text[]
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path = public, pg_temp
  AS $$
    WITH candidates AS (
      SELECT r.student_id AS sid
      FROM relationship r
      WHERE r.status = 'active'
        AND (r.parent_id = p_user_id OR r.student_id = p_user_id)
      UNION
      SELECT u.id FROM app_user u WHERE u.id = p_user_id AND u.role = 'student'
    )
    SELECT coalesce(array_agg(DISTINCT sid), ARRAY[]::text[])
    FROM candidates
    WHERE sid IS NOT NULL AND sid <> ''
  $$;

REVOKE ALL ON FUNCTION auth_lookup_credential(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION auth_visible_students(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION auth_lookup_credential(text) TO app_rls;
GRANT EXECUTE ON FUNCTION auth_visible_students(text) TO app_rls;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rls;
