-- 伴学 APP 数据服务 —— 通知的写入边界（S3）
--
-- ## 这个文件解决的是一个「S2 之前看不出来、S3 一写就撞墙」的问题
--
-- 迁移计划 §3.4① 定死了：**通知必须由服务端在事件发生时生成，客户端只读**。
-- 于是服务端要在「学生提交作业」这个请求里，替**家长**生成一条通知。
--
-- 而 002 给 app_notification 的 policy 是 `FOR ALL` + USING(target_user_id = 自己 OR '')，
-- 且 `FOR ALL` 策略下 USING 会**同时充当 WITH CHECK**（PG 的行为：省略 WITH CHECK 时
-- 用 USING 表达式判断新行）。所以服务端以学生的身份插一行 target_user_id = 家长 的通知，
-- 会当场收到：
--
--     new row violates row-level security policy for table "app_notification"
--
-- 这条报错本身是好消息（fail-closed 生效了）。坏消息是它把「通知由服务端产生」
-- 这件事变成了「要么放开 RLS，要么单开一条特权连接」二选一 —— 而这两个选项
-- 都会把一条本来收得很紧的边界变松。
--
-- ## 选择第三条路：不放开 RLS，也不开特权连接，而是让**应用声明收件人**
--
-- 通知不是凭空产生的：它总是某个事件的副产物，而事件的受众是**服务端自己算出来的**
-- （见 `src/routes/notify.js` 的 `counterpartIds` / `parentIdsOf`）。既然服务端
-- 本来就必须算出「这条通知要写给谁」才能插入那些行，policy 就没有必要再推一遍：
--
--     你只能通知「自己」「所有人（广播）」「**本次事务里声明过的**收件人」。
--
-- 这不是为了绕开 RLS 而放松它 —— 声明集合仍然只能由服务端从关系数据推导，
-- 客户端影响不到它（客户端能影响的只有"发什么"，不是"发给谁"）。
-- 与 `app.visible_students` 是同一个模式，只是方向相反：
--   · `app.visible_students` —— 声明「我能读谁」；
--   · `app.notify_targets`   —— 声明「我能写给谁」。
--
-- 代价要说清楚：**同一台设备上的恶意客户端可以给自己的结伴对象刷通知**。
-- 这条已经存在（他能给对方发聊天消息，`chat_message` 的 policy 同样允许），
-- 而它是「同一家庭内部的骚扰」，不是越权读数据 —— 与「一个班互相看得见」不同级别。
-- 真正的对策是限流，不是把 policy 收死（收死的代价是功能做不出来）。
--
-- ⚠️ 换掉的另一件事：**不再给 app_notification 开放 UPDATE**。
--   `markNotificationRead` 今后只写 `app_notification_read`（那才是「谁看过了」的正确位置），
--   行上的 `is_read` 列退化为历史字段。留着 UPDATE 权限会让两条写法并存，
--   而症状是「学生点掉广播，家长那端的未读数一起消失」——这正是要修掉的那个缺陷。
--
-- ⚠️ 文件修订记录：本文件**还没有在任何真实环境应用过**（只有一次性本机测试库跑过，
--   而那个库每轮都重建），所以改动是**直接改这里**，而不是再补一条 007 迁移。
--   一旦它上过一个需要保留数据的环境，就必须改成追加新迁移。
--
-- 执行方式：由 src/migrate.js 在事务内按文件名顺序执行，本文件**不要自带 BEGIN/COMMIT**。

-- ===== 1/2 app_notification：按命令拆开 =====

DROP POLICY own_rows ON app_notification;

-- 读：发给自己的，或广播。
--
-- 广播（target_user_id = ''）是**刻意共享**的一行 —— 它的已读状态因此不能放在行上，
-- 见 001_schema.sql 末尾的 app_notification_read。
CREATE POLICY notification_read ON app_notification FOR SELECT USING (
  target_user_id = current_setting('app.user_id', true)
  OR target_user_id = ''
);

-- 写：自己 / 广播 / **本次事务里声明的收件人**。
--
-- ## 收件人集合由应用声明，policy 只做一次「数组包含」判断
--
-- 服务端在写通知之前，会把它算好的收件人写进事务设置
-- （`set_config('app.notify_targets', …, true)`，见 `src/routes/notify.js`），
-- policy 于是退化成一句 `target_user_id = ANY(...)`。
--
-- ## 为什么要这样，而不是在 policy 里查 relationship
--
-- 这里的第一版实现是**直接从数据里推**：「通知的受众恰好是与资源结伴的人」，
-- 所以 policy 里嵌两段 `select … from relationship where …` 子查询就够了。
--
-- ⚠️ **如实说明这条证据链的缺口**（2026-09-18 补）：第一版当时确实被拒了，
-- 报的是 `new row violates row-level security policy`。但后来同一个报错又出现了一次，
-- 而那次的原因**完全不在 policy 上** —— 是 `INSERT … RETURNING` 要求新行能被
-- **读**策略看见（见 `routes/notify.js` 文件头）。两次报错文案逐字相同，
-- 所以**「第一版策略本身跑不通」这件事并没有被干净地验证过**：当时那次失败
-- 里面可能就混着 `RETURNING` 这一份，只是它还没被识别出来。
--
-- 因此这一版保留下来，理由**不是**「第一版实测失败」，而是下面这条工程判断
-- （它独立成立，不依赖那次测量）：
--
--   policy 内部再嵌一层 RLS 子查询之后，「哪一层的表达式在哪个设置下求值」
--   就不再可靠地可推理了 —— 而这是安全边界，不可推理就是不可接受。
--   第二版的判断逻辑只有一层，与 `app.visible_students` 完全同构
--   （同样是「应用算集合、RLS 认集合」），于是排查时的提问方式也一致了。
--
-- 若将来有人想回去做「policy 自己查关系」的版本，请把上面那段当成前置条件：
-- 先有一条**不带 RETURNING** 的对照实测，再谈哪一版更好。
--
-- ⚠️ 由此带来的一条**必须遵守的约定**：`app.notify_targets` 的值只能由服务端
-- 从数据库关系推导出来。永远不要把请求体里的字段塞进它 —— 那等于让客户端
-- 自己声明「我能给谁发通知」。`notify.js` 的 `to` 参数因此只接受服务端代码
-- 算出的列表（见那里的注释）。
CREATE POLICY notification_insert ON app_notification FOR INSERT WITH CHECK (
  -- 自己
  target_user_id = current_setting('app.user_id', true)
  -- 广播（''）：001_schema.sql 定下的哨兵值，读端与写端都依赖它。
  -- 目前没有业务路径产生广播，保留是为了不改动既有的读写约定。
  OR target_user_id = ''
  -- 本次事务声明的收件人。没声明任何收件人时这一项恒为假（fail-closed）。
  OR target_user_id = ANY(
       string_to_array(coalesce(current_setting('app.notify_targets', true), ''), ',')
     )
);

-- ===== 2/2 app_notification_read：确认它按预期收口 =====
--
-- 002 已经建了 policy（`USING (user_id = app.user_id)`）。这里不重建，
-- 只用断言把「RLS 真的启用了」钉住 —— 与 003_session.sql 同一个理由：
-- **「有 policy」不等于「RLS 生效」**，漏了 ENABLE 的话 policy 建得好好的、
-- 不报任何错，但那张表对所有人完全开放。
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'app_notification_read'
      AND c.relrowsecurity
      AND c.relforcerowsecurity
  ) THEN
    RAISE EXCEPTION 'app_notification_read 的 RLS 没有启用（或没有 FORCE）—— 已读状态会对所有人开放';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'app_notification'
      AND c.relrowsecurity
      AND c.relforcerowsecurity
  ) THEN
    RAISE EXCEPTION 'app_notification 的 RLS 没有启用（或没有 FORCE）—— 通知会对所有人开放';
  END IF;
END
$$;
