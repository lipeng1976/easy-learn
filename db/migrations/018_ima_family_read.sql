-- ima：让学生端「只读」所属家庭的同步状态
--
-- ## 来路（与 008_relationship_peer_name.sql 同源）
--
-- ima 凭证挂在「拥有者用户」上（通常是家长），RLS 原本只有 owner 自己能碰
-- （见 017 的 `ima_credential_own` / `ima_student_kb_own`）。于是：
--   · 家长能读到自己家庭的 ima 状态与 KB 列表；
--   · 学生读不到 —— 因为学生的 `app.user_id` 不是 owner，永远返回空。
--
-- 但「学生端状态展示」需要学生知道「我家 ima 同步开没开」。
-- 这与 008 是同一个问题：孩子要通过结伴把数据共享给家长，自然也该
-- 看得到家庭级的同步开关状态。
--
-- ## 为什么是 FOR SELECT，且只放行「家庭对端」
--
--   · 只给 SELECT：学生**绝不可写** ima 凭证（写 = 改写/清空家长的 apikey）。
--     `WITH CHECK` 不写，于是 INSERT/UPDATE/DELETE 仍只有 owner 自己能过。
--   · 方向限定为「我是这个 owner 的 active 学生」：子查询 `relationship`
--     以**当前角色**执行（RLS 会套用 relationship 自己的 policy），所以学生
--     只能顺着「自己的关系行」找到家长，跨家庭不可能成立。
--
-- ⚠️ 行级 RLS 没法只暴露 `status` 一列：学生能 SELECT 到的行，其
--   `clientid_enc` / `apikey_enc` 在 SQL 层面也可读。**但本服务没有任何端点
--   会把这两个密文字段返回给客户端**（`getImaStatus` 只回 `status` 与 `kbs`），
--   且它们是用服务端密钥 AES-GCM 加密的，学生即便拿到密文也无法还原。
--   这与 008 接受「学生可读家长整行 app_user」是同一档的取舍。

-- ===== ima_credential：学生只读所属家长的状态 =====
CREATE POLICY ima_credential_family_read ON ima_credential
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM relationship r
      WHERE r.student_id = current_setting('app.user_id', true)
        AND r.parent_id  = ima_credential.owner_user_id
        AND r.status     = 'active'
    )
  );

-- ===== ima_student_kb：学生只读所属家庭的 KB 列表 =====
-- KB 映射（kb_id / kb_name）本就不是秘密，放开只读更安全——学生端要展示
-- 「同步到了哪个知识库」。同样只给 SELECT。
CREATE POLICY ima_student_kb_family_read ON ima_student_kb
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM relationship r
      WHERE r.student_id = current_setting('app.user_id', true)
        AND r.parent_id  = ima_student_kb.owner_user_id
        AND r.status     = 'active'
    )
  );
