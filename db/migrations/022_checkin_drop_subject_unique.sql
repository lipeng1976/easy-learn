-- 取消「一天一科目最多一份」的限制（2026-10-27 用户要求）。
--
-- 之前（021）把唯一键放宽到 (student_id, quiz_date, subject)，
-- 目的是「分科目出多份」。但用户进一步明确：家长想出几套就出几套，
-- 同科目也可以再出一组，每份独立、互不覆盖，不需要「覆盖」语义。
--
-- 所以这里直接把 uq_checkin_quiz 整个去掉。唯一性只保留主键 id
-- （见 019_checkin_quiz.sql），避免同一行被插入两次；
-- 同 (student_id, quiz_date) 下出现多份（同科目或不同科目）都是允许的。
--
-- 服务端落库逻辑同步改成「纯插入」：routes/checkin.js 的 insertCheckinQuiz
-- 不再删旧行，每次 start() 都是一份全新的卷（id 由服务端生成）。

ALTER TABLE checkin_quiz DROP CONSTRAINT IF EXISTS uq_checkin_quiz;
