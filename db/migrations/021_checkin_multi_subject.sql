-- 一天多份打卡：唯一键从 (student_id, quiz_date) 放宽到 (student_id, quiz_date, subject)
--
-- ## 为什么要放宽
--
-- 家长可能分科目给不同的打卡要求：上午一份数学、晚上一份英语。
-- 原来的「一天一份」会把第二份静默覆盖掉第一份 —— 而且第一份已经做完的
-- 成绩会一起作废，家长端看起来就像「孩子做过的东西丢了」。
--
-- 科目就是天然的「一天内区分多份」的键：出题设置页本来就在选学科，
-- 学生自发起固定走「数学」。重复发起**同一科目**仍然走覆盖（删旧行插新行、
-- id 换新，见 routes/checkin.js 的 upsertQuiz），语义与一天一份时一致。
--
-- ## 为什么不按「发起次数」允许任意多份
--
-- 「今天的打卡」必须是一个能答完的概念 —— 入口卡要能显示「已完成 2/2」。
-- 按科目封顶（每科目一份）让两边都有明确的口径：科目相同 = 同一份打卡，
-- 重新出题 = 作废该科目那份。

ALTER TABLE checkin_quiz DROP CONSTRAINT uq_checkin_quiz;
ALTER TABLE checkin_quiz
  ADD CONSTRAINT uq_checkin_quiz UNIQUE (student_id, quiz_date, subject);
