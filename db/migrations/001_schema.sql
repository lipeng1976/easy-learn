-- 伴学 APP 数据服务 —— PostgreSQL 初始 schema
--
-- 来源：客户端 SQLite（lib/services/database_service.dart 的 _onCreate，DB version 23）
-- 目标：PostgreSQL 17
--
-- 本文件只做「结构搬运」，不改业务语义。三条全局映射规则：
--   ① 列名 camelCase → snake_case（库内下划线，API 传输仍是 camelCase，映射在 DAO 层做一次）
--   ② 类型：INTEGER 存布尔 → BOOLEAN；TEXT 存时间 → TIMESTAMPTZ；REAL → NUMERIC
--   ③ 空值语义：TEXT NOT NULL DEFAULT '' 一律保留（客户端代码依赖空串，不是 NULL）
--
-- ⚠️ 三处刻意「不映射」的列，改了就属于行为变化：
--   · workout_plan.start_time / end_time 存的是 '17:30' 这种展示串，不是时刻。
--     改成 TIME 读回来会变成 '17:30:00'，前端显示会变。
--   · weekdays / custom_weekdays / knowledge_points / hobbies / weak_points 是 JSON 数组，
--     第一阶段保留 TEXT（客户端解析逻辑稳定，改 JSONB 只为了「能在库里查询」，该需求不存在）。
--   · app_user.avatar 存的是 emoji 或 'student'/'parent'，不是图片 URL。将来接自定义头像
--     要加 avatar_url 列，不要塞进这一列。
--
-- ⚠️ 时间戳的隐藏依赖（见 §R3）：客户端 121 处 toIso8601String() 全库 0 处 toUtc()，
--   即现有库里的时间字符串是「不带时区后缀的本地时间」。搬进 TIMESTAMPTZ 后，
--   客户端写入必须改成带时区的 ISO8601（toUtc().toIso8601String()），否则 PG 会
--   按服务端时区解释，产生静默偏移。DDL 这里是对的，问题在写入端。
--
-- 执行方式：由 src/migrate.js 在事务内按文件名顺序执行，本文件**不要自带 BEGIN/COMMIT**。

-- ===== 1/22 账号 =====
-- ⚠️ 2026-09-18（S2）：`password_hash` 与 `password_updated_at` 两列**已经搬走**，
--   见 sql/004_credential.sql —— 口令哈希与用户资料的可见范围不同，
--   放在同一行里会让「家长看孩子资料」顺带授权「家长读孩子密码」。
--   下面这两行是本文件的历史形态，实际执行到 004 之后就不存在了。
-- password_hash: 原列名 password 存的是明文，上云前必修（§3.4③）。
--   迁移时不搬明文 —— 存量演示账号本来就是 abc123，直接重设。
--   phone / wechat_open_id 允许多个 NULL（PG 的 UNIQUE 不比较 NULL，与 SQLite 一致）。
--   ⚠️ 若哪天把手机号改成写 ''，第二个微信用户就注册不进来。
CREATE TABLE app_user (
  id                  TEXT PRIMARY KEY,
  name                TEXT NOT NULL,
  phone               TEXT,
  role                TEXT NOT NULL,
  avatar              TEXT NOT NULL,
  password_hash       TEXT,
  wechat_open_id      TEXT,
  gender              TEXT DEFAULT '',
  grade               TEXT DEFAULT '',
  hobbies             TEXT DEFAULT '',
  bio                 TEXT DEFAULT '',
  password_updated_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX uq_user_phone  ON app_user(phone);
CREATE UNIQUE INDEX uq_user_wechat ON app_user(wechat_open_id);

-- ===== 2/22 作业 =====
-- grading_source 是「本地兜底」的降级溯源，不能丢：它记录这次判定是云上模型给的还是本地规则给的。
-- user_role 列保留但**不再作为授权依据**（R1：身份只由 token 给）。上云后它就是一条历史记录。
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
  grading_source    TEXT NOT NULL DEFAULT ''
);

-- ===== 3/22 运动计划 =====
-- start_date / end_date 存的是完整时间戳（不是纯日期），按 TIMESTAMPTZ 搬。
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

-- ===== 4/22 运动记录 =====
-- start_at / end_at 是**业务时间**（学生实际做的时刻，客户端给），不是记录时间。
-- 所以它们不由服务端 now() 覆盖，只校验范围（R3）。
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

-- ===== 5/22 错题池 =====
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
  last_reviewed_at      TIMESTAMPTZ
);

-- ===== 6/22 复习试卷 =====
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
  file_path        TEXT NOT NULL DEFAULT '',
  note             TEXT NOT NULL DEFAULT ''
);

-- ===== 7/22 卷内单题快照 =====
-- 这是**快照**：纸卷一旦印出去，学生手上的纸和库里的题就分叉了。
-- 迁移时必须整体搬，不能照错题池重新生成。
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
  photo_path      TEXT NOT NULL DEFAULT '',
  comment         TEXT NOT NULL DEFAULT '',
  checked_at      TIMESTAMPTZ
);

-- ===== 8/22 判定影子比对 =====
-- 一行 = 一次比对，不是一次作答（举一反三交 3 题就有 3 行）。
-- 这样「一致率」的分母才等于模型真正判定过的题数。
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

-- ===== 9/22 作答证据 =====
-- 毕业判定的唯一依据。不要往这里塞观测数据（那是 judgement_ab 的事）。
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

-- ===== 10/22 AI 练习题 =====
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
  checked_at        TIMESTAMPTZ
);

-- ===== 11/22 讲解留痕 =====
-- 讲解不构成毕业（看懂 ≠ 会做），只进过程时间线，不改掌握率。
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

-- ===== 12/22 周期报告 =====
-- 通过率的分母是「期内作答次数」；scope_key 是周期键（ISO 周年），落库按 scope_key 覆盖。
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

-- ===== 13/22 心愿 =====
-- 兑换的三个时间戳合起来构成状态机：requested → redeemed / rejected。
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

-- ===== 14/22 学习计划 =====
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

-- ===== 15/22 打卡 =====
-- ⚠️ date 是「**学生所在时区的今天**」（客户端用本地年月日算，如 2026-09-18）。
-- 它是唯一约束的一部分，服务端若按 UTC 算会错一天 —— 晚上 8 点后打卡记到明天（R4）。
-- 所以服务端只校验范围，不自己生成这个值。
CREATE TABLE study_plan_checkin (
  id         TEXT PRIMARY KEY,
  plan_id    TEXT NOT NULL,
  student_id TEXT NOT NULL DEFAULT '',
  date       DATE NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT uq_checkin UNIQUE (plan_id, date)
);

-- ===== 16/22 结伴关系 =====
-- sender_id 是发起方（学生或家长），status 是状态机（pending → active / rejected）。
-- 词的唯一来源是 src/vocab.js —— 服务端不在这里、也不在任何别处写字面量。
-- 上云后这张表是 RLS 计算 visible_students 的**两个来源之一**。
CREATE TABLE relationship (
  id         TEXT PRIMARY KEY,
  student_id TEXT NOT NULL,
  parent_id  TEXT NOT NULL,
  sender_id  TEXT NOT NULL,
  status     TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_relation UNIQUE (student_id, parent_id)
);

-- ===== 17/22 聊天 =====
CREATE TABLE chat_message (
  id              TEXT PRIMARY KEY,
  relationship_id TEXT NOT NULL,
  sender_id       TEXT NOT NULL,
  receiver_id     TEXT NOT NULL,
  content         TEXT NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  is_read         BOOLEAN NOT NULL DEFAULT FALSE
);

-- ===== 18/22 作业图片 =====
-- storage_key 存**相对存储根目录的路径**：`YYYYMMDD/<studentId>/<uuid>.<ext>`，
-- 例如 `20260920/36e392cd-…/f3a1c2d4.jpg`。根目录由 `IMAGE_ROOT_DIR` 配置
-- （见 `src/imagestore.js`）。键一律用 `/` 分隔，不跟服务端操作系统漂。
--
-- ⚠️ **历史值仍是设备本地标识**（原生端绝对路径 / Web 端 localStorage 键）——
-- 那是 2026-09-20 之前写下的行。它们不是坏数据：字节只在当初那台设备上，
-- 服务端永远拿不到。所以客户端**必须先分辨两种形态**
-- （`lib/services/image_key.dart`），判错的症状是「照片位置一片空白、无报错」：
--   · 认不出旧标识 → 该回退本地读的照片永远看不到；
--   · 把旧标识当服务端键 → 请求必然 404。
--
-- 库里依然**不存字节**（字节在文件系统或对象存储里）。读的入口是
-- `GET /data/homework/images/file?id=`：按 id 查行 → RLS 过滤可见性 →
-- 从存储取字节。**客户端不传路径**，所以「路径穿越」在这里不是一个
-- 「记得校验」的问题，而是一个「没有入口」的问题。
CREATE TABLE homework_image (
  id          TEXT PRIMARY KEY,
  student_id  TEXT NOT NULL,
  homework_id TEXT,
  storage_key TEXT NOT NULL,
  file_name   TEXT NOT NULL,
  file_size   INTEGER NOT NULL,
  mime_type   TEXT NOT NULL,
  ocr_status  TEXT NOT NULL,
  ocr_text    TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  batch_id    TEXT NOT NULL DEFAULT '',
  sort_order  INTEGER NOT NULL DEFAULT 0
);

-- ===== 19/22 通知 =====
-- ⚠️ 上云后**不再由客户端写入**：通知必须由服务端在事件发生时生成，
-- 客户端只读（陷阱⑦）。is_read 这一列保留但会被 app_notification_read 取代 ——
-- 因为它无法表达「广播行里谁已读」（学生点掉一条广播，家长的未读数会一起消失）。
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

-- ===== 20/22 每日点评 =====
CREATE TABLE daily_comment (
  id         TEXT PRIMARY KEY,
  rating     TEXT NOT NULL,
  content    TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  student_id TEXT NOT NULL DEFAULT ''
);

-- ===== 21/22 积分规则 =====
-- 没配的行 = 用出厂默认值，所以家长没进过设置页也能正常计分（不需要预生成一堆行）。
-- 原表只声明了 UNIQUE(studentId, action) 而没有主键；这里提升为主键 ——
-- 两列本来就都是 NOT NULL，语义等价，但 PG 里无主键表会挡住逻辑复制与部分运维工具。
CREATE TABLE point_rule (
  student_id TEXT NOT NULL,
  action     TEXT NOT NULL,
  points     INTEGER NOT NULL DEFAULT 0,
  enabled    BOOLEAN NOT NULL DEFAULT TRUE,
  updated_at TIMESTAMPTZ,
  PRIMARY KEY (student_id, action)
);

-- ===== 22/22 积分账本 =====
-- 余额永远由这张表求和得来，不另存字段。
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

-- 防重的最后一道闸：同一个动作只能有一条「还活着」的发分记录。
--
-- ⚠️ 这条部分唯一索引有个实现级陷阱（已实测，见 §R5）：
--   `INSERT ... ON CONFLICT (idempotency_key) DO NOTHING` **会报 42P10**，
--   因为部分索引不能被「无 WHERE 的冲突推断」匹配到。
--   正确写法必须把索引谓词原样带上：
--
--     INSERT INTO point_ledger (...) VALUES (...)
--     ON CONFLICT (idempotency_key) WHERE idempotency_key <> '' AND reversed_at IS NULL
--     DO NOTHING
--     RETURNING id;
--
--   命中冲突时 rowCount = 0 → 服务端回查原记录并**返回原结果**（不是报 409）。
--   网络超时后的重试走的就是这条路。
CREATE UNIQUE INDEX idx_point_ledger_active_key
  ON point_ledger(idempotency_key)
  WHERE idempotency_key <> '' AND reversed_at IS NULL;

CREATE INDEX idx_point_ledger_student ON point_ledger(student_id, created_at);

-- ===== 索引补课 =====
-- 现有 SQLite 全库 JOIN 数 = 0，查询都是「单表 + Dart 侧拼装」。
-- 服务端要开始做关系鉴权与按学生过滤，这几个条件会在**每个请求**上跑一遍。
CREATE INDEX idx_homework_student_status    ON homework(student_id, status);
CREATE INDEX idx_review_mistake_student     ON review_mistake(student_id, state);
CREATE INDEX idx_relationship_parent        ON relationship(parent_id, status);
CREATE INDEX idx_relationship_student       ON relationship(student_id, status);
CREATE INDEX idx_notification_target        ON app_notification(target_user_id, created_at DESC);
CREATE INDEX idx_review_paper_student       ON review_paper(student_id, status);
CREATE INDEX idx_review_attempt_student     ON review_attempt(student_id, created_at DESC);
CREATE INDEX idx_wish_student               ON wish(student_id);
CREATE INDEX idx_study_plan_student         ON study_plan(student_id, status);
CREATE INDEX idx_study_plan_checkin_student ON study_plan_checkin(student_id, date);
CREATE INDEX idx_workout_record_student     ON workout_record(student_id, start_at DESC);
CREATE INDEX idx_homework_image_homework    ON homework_image(homework_id);
CREATE INDEX idx_chat_message_relationship  ON chat_message(relationship_id, created_at);
CREATE INDEX idx_daily_comment_student      ON daily_comment(student_id, created_at DESC);

-- ===== 第 23 张：通知已读（上云新增，客户端 SQLite 里没有）=====
-- 解决「广播行全角色共用一行 is_read」的缺陷：已读状态按 (通知, 用户) 拆开存。
-- 这一张属于 §3.4① 的重新设计，S1 先把表建好，S3 才会有人写它。
CREATE TABLE app_notification_read (
  notification_id TEXT NOT NULL REFERENCES app_notification(id) ON DELETE CASCADE,
  user_id         TEXT NOT NULL,
  read_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (notification_id, user_id)
);
