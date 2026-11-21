-- 变式题的题型与选项。
--
-- ## 为什么现在才加
--
-- 最初的举一反三只有一种形态：文字作答 + 拍照识别 + 模型判定。那时
-- `ai_practice_question` 里只有题干和答案，够用。
--
-- 加题型是为了让**答案集合封闭**的题不必经过模型：
--   · choice —— 四个选项，答案是一个字母；
--   · judge  —— 正确 / 错误。
-- 这两种题的判定是确定的。让模型去判，同一个答案两次可能得到不同结论，
-- 学生无法理解，而错题本里会多出一堆假错题。
--
-- ## 默认值的方向
--
-- `question_type` 默认 `solution`：加这一列之前的题**全都是**解答题，
-- 按它走与以前完全一致。反过来默认成 `choice` 会让历史题变成
-- 「没有选项的选择题」—— 学生点不了任何东西，且没有任何报错。
--
-- `options_json` 默认 `'[]'`：非选择题就是没有选项。
ALTER TABLE ai_practice_question
  ADD COLUMN IF NOT EXISTS question_type TEXT NOT NULL DEFAULT 'solution';

ALTER TABLE ai_practice_question
  ADD COLUMN IF NOT EXISTS options_json TEXT NOT NULL DEFAULT '[]';
