-- 伴学 APP 数据服务 —— ima 集成（多家庭·多学生独立知识库 + 可选同步）
--
-- 设计见 doc/ima-integration-design.md。要点：
--   · ima 同步默认关闭（status 默认 'unconnected'），无 ima 账号也能完整体验；
--   · 凭证挂在「拥有者用户」（家庭代表，通常是家长）上，每个学生一个独立 KB；
--   · 凭证可逆加密存储（src/crypto.js），读取时还原明文去调 ima OpenAPI。
--
-- 执行方式：由 src/migrate.js 在事务内按文件名顺序执行，本文件不要自带 BEGIN/COMMIT。

-- ===== 1/2 ima 凭证表（owner 级）=====
-- owner_user_id 即持有 ima 账号的用户（家庭代表，通常家长）。
-- status 默认 'unconnected' = 默认关闭、不联网、不阻断主流程。
CREATE TABLE IF NOT EXISTS ima_credential (
  owner_user_id   TEXT PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  clientid_enc    TEXT NOT NULL,
  apikey_enc      TEXT NOT NULL,
  status          TEXT NOT NULL DEFAULT 'unconnected',
  kb_owner_name   TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE ima_credential ENABLE ROW LEVEL SECURITY;
ALTER TABLE ima_credential FORCE ROW LEVEL SECURITY;

-- 只有自己能碰自己的凭证行。没有任何「OR 可见学生」半句：
-- ima 凭证是家庭资产，孩子不该读到家长的 ima apikey。
CREATE POLICY ima_credential_own ON ima_credential
  USING (owner_user_id = current_setting('app.user_id', true))
  WITH CHECK (owner_user_id = current_setting('app.user_id', true));

-- ===== 2/2 学生→KB 映射表 =====
-- 每个学生一个独立 KB（库名带学号），挂在 owner 的 ima 账号下。
-- student_id 即 app_user.id（学生账号），owner_user_id 是持有 ima 凭证的用户。
CREATE TABLE IF NOT EXISTS ima_student_kb (
  student_id      TEXT PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  owner_user_id   TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  kb_id           TEXT NOT NULL,
  kb_name         TEXT NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (owner_user_id, kb_id)
);

ALTER TABLE ima_student_kb ENABLE ROW LEVEL SECURITY;
ALTER TABLE ima_student_kb FORCE ROW LEVEL SECURITY;

CREATE POLICY ima_student_kb_own ON ima_student_kb
  USING (owner_user_id = current_setting('app.user_id', true))
  WITH CHECK (owner_user_id = current_setting('app.user_id', true));
