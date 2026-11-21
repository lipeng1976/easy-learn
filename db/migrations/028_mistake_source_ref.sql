-- 错题来源引用：让「每日打卡做错的题」能被认出来、且重复交卷不重复入库
--
-- ## 为什么需要一列，而不是把 quizId 塞进 homework_id
--
-- `homework_id` 的语义是「这道题来自哪份作业」，下游的作业详情、重算错题
-- （`deleteReviewMistakesByHomeworkId`）都按它匹配。把打卡 id 塞进去，
-- 作业页会去 homework 表里查一个不存在的行 —— 不报错，只是永远查不到，
-- 而那正是最难查的一类失败。
--
-- ## 为什么不能只靠 id 前缀
--
-- 曾经想用 `rm_ck_<quizId>_<index>` 这种 id 直接删旧行，但 PostgreSQL 的
-- `LIKE` 里 `_` 是通配符，而 quizId 本身就带下划线（`ck_xxx`）——
-- 同一个 `LIKE` 模式会命中别的卷，删错数据且不报错。
--
-- ## 幂等
--
-- 同一份打卡重复交卷时，先按 `(student_id, source_ref)` 删掉上一次由这份卷
-- 产出的错题，再按这次的真实错题重写。没有这一列就只能靠 id 约定，
-- 而 id 约定在「题目变少 / 顺序变化」时清理不干净。
--
-- 老数据：默认空串，表示「不是打卡来的」，行为完全不变。

ALTER TABLE review_mistake
  ADD COLUMN IF NOT EXISTS source_ref TEXT NOT NULL DEFAULT '';

-- 交卷时的删除只看这张卷，走 (student_id, source_ref) 即可。
CREATE INDEX IF NOT EXISTS idx_review_mistake_source_ref
  ON review_mistake(student_id, source_ref);
