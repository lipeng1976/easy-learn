-- 行为扣分（2026-11-28）。
--
-- ## 为什么要单独一张表，不塞进 point_rule
--
-- point_rule 的键是「孩子 + 动作」，值只有一个 points。它适合描述
-- 「所有作业提交都值 5 分」这种**系统动作**，但描述不了家长自定义的行为：
-- 「迟到」和「旷课」各有自己的名字、分值和开关，自定义行为还会继续增加。
-- 把它们伪装成 action 字符串会让账本里的行为名没法展示、没法改名，
-- 而且改名就等于改数据。所以行为独立成表，账本只记行为 id（ref_id）。
--
-- ## 账本仍然只有一张
--
-- 扣分就是一笔负数流水：action = behaviorDeduction，ref_type = behavior，
-- ref_id = 行为 id，reason = 行为名（+家长备注）。余额与积分记录的口径
-- 完全不变，不需要「另一套扣分账本」。
--
-- ## 多家庭隔离
--
-- 归属列是 student_id，沿用 010 之后的全库口径 app_csv_setting()：
-- 空 visible_students 必须是空集合，不能因为 current_setting 缺失而
-- 变成「谁都能看」（string_to_array(NULL) 的旧坑）。

CREATE TABLE IF NOT EXISTS point_behavior (
  student_id  TEXT NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  id          TEXT NOT NULL,
  name        TEXT NOT NULL DEFAULT '',
  -- 存正数：扣分的方向由账本里的负数表达，别在两处各存一个符号。
  points      INTEGER NOT NULL DEFAULT 0 CHECK (points >= 0),
  enabled     BOOLEAN NOT NULL DEFAULT TRUE,
  -- 内置行为也落表，家长可以改分值/关掉，但不能删（删了历史记录就没名字了）。
  builtin     BOOLEAN NOT NULL DEFAULT FALSE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (student_id, id)
);

CREATE INDEX IF NOT EXISTS ix_point_behavior_student
  ON point_behavior (student_id, enabled);

ALTER TABLE point_behavior ENABLE ROW LEVEL SECURITY;
ALTER TABLE point_behavior FORCE ROW LEVEL SECURITY;

CREATE POLICY point_behavior_own ON point_behavior
  USING (student_id = ANY(app_csv_setting('app.visible_students')))
  WITH CHECK (student_id = ANY(app_csv_setting('app.visible_students')));
