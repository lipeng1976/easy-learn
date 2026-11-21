-- 伴学 APP 数据服务 —— 错题的「原卷面题号」
--
-- 批改时模型看得到卷面上的题号（它自己在 formatIssues 里就写「第 4 题」），
-- 但契约里一直没有字段放它，于是客户端只能拿到知识点。
-- 家长拿着一条错题要翻到作业本上的那一题时，知识点是找不到的。
--
-- ⚠️ 这一列只用于**展示**：不参与判分、不参与组卷排序。
--    重做卷的题号永远是那张卷子自己的 1..N。
--
-- ⚠️ **不回填**：老错题不知道题号，拿知识点去猜只会猜错，
--    而这一列的全部价值就是准确。
--
-- 执行方式：由 src/migrate.js 在事务内按文件名顺序执行，本文件**不要自带 BEGIN/COMMIT**。

ALTER TABLE review_mistake
  ADD COLUMN IF NOT EXISTS question_no TEXT NOT NULL DEFAULT '';

-- 学生那次**写出来的解题过程**（批改时 OCR 抄下来的原文）。
--
-- 为什么值得单独存：讲解要说清「他卡在哪一步」，只有最终答案是错的
-- 只能泛泛而谈。而这个过程只在批改那一刻看得到 —— 之后照片可能删了。
--
-- ⚠️ 空串是常态：选择题、填空题本来就没有过程。
--    也**不回填**：老错的题没记过过程，编不出来。
ALTER TABLE review_mistake
  ADD COLUMN IF NOT EXISTS student_process TEXT NOT NULL DEFAULT '';
