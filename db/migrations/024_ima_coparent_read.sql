-- ima：按学生配置后，放行「同一学生的其他 active 家长」只读状态
--
-- ## 来路（2026-11-08，`doc/ima-integration-design.md` §2）
--
-- 归属规则改为「配置主体 = 学生」：一切读取走
--   `studentId → ima_student_kb → 配置人 owner_user_id → ima_credential`。
-- 但 017 的 `*_own` 策略只让配置人本人读那两张表，018 只放行了
-- 「学生 → 家长」这一个方向。于是父母共管时出现：
--
--   · 父亲配好孩子 A 的 ima；母亲选中同一个 A，`getImaStatus` 读不到
--     父亲那行凭证、也读不到 A 的 KB 映射 → 状态恒「未开启」；
--   · 母亲若再去点「连接」，会建出第二个库并覆盖映射归属（§2.3）。
--
-- 本文件只补**共管家长之间的只读**，不新增表、不改数据、不放开任何写权限。
-- `relationship` 的 `own_rows` 策略（002）允许家长读 `parent_id = 自己` 的行，
-- 所以下面两个 EXISTS 都能以请求者身份成立，不需要绕过 RLS。
--
-- ⚠️ 只给 SELECT：写（改密文 / 改状态 / 改映射）仍然只有 017 的 `*_own`
-- 放行。母亲看得到「已配置 + 库名」，但改不动父亲填的密钥 —— 断开发生时
-- 服务端会给一句明确提示（见 `routes/ima.js:disconnectIma`），而不是静默失败。
--
-- ⚠️ 与 018 同一档取舍：行级 RLS 没法只暴露 `status` 一列，被放行的
-- 凭证行里 `clientid_enc` / `apikey_enc` 在 SQL 层也可读。但它们是
-- `IMA_CREDENTIAL_SECRET` 加密的 AES-GCM 密文，且**没有任何端点把这两列
-- 返回给客户端**（`getImaStatus` 只回 status / kbs / ownerUserId / studentId）。

-- ===== 1/2 共同孩子的 KB 映射：另一位 active 家长可读 =====
-- 只依赖 relationship（不引用 ima_credential），避免 policy 之间循环。
DROP POLICY IF EXISTS ima_student_kb_coparent_read ON ima_student_kb;
CREATE POLICY ima_student_kb_coparent_read ON ima_student_kb
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM relationship r
      WHERE r.student_id = ima_student_kb.student_id
        AND r.parent_id  = current_setting('app.user_id', true)
        AND r.status     = 'active'
    )
  );

-- ===== 2/2 配置人的凭证状态：共同孩子的另一位 active 家长可读 =====
-- 子查询里的 ima_student_kb 会套用上一条策略（以当前用户身份），
-- 因此只有「我确实也是这个孩子的 active 家长」时才拿得到 owner_user_id。
-- 一个 owner 只有一行凭证，越界到别人家的 key 在关系层面就不成立。
DROP POLICY IF EXISTS ima_credential_coparent_read ON ima_credential;
CREATE POLICY ima_credential_coparent_read ON ima_credential
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM ima_student_kb k
      WHERE k.owner_user_id = ima_credential.owner_user_id
        AND EXISTS (
          SELECT 1 FROM relationship r
          WHERE r.student_id = k.student_id
            AND r.parent_id  = current_setting('app.user_id', true)
            AND r.status     = 'active'
        )
    )
  );
