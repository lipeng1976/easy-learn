-- ═══════════════════════════════════════════════════════════════════════════
-- 伴学 APP —— 种子初始化 SQL
--
-- 只含**非敏感字典数据**：学科、年级规范词、状态词、难度档位。
-- 不含：账号、口令、手机号、姓名、学生数据、任何密钥、任何绝对路径。
-- 幂等：ON CONFLICT DO NOTHING，重复执行不产生重复行。
-- 执行：紧跟 001_schema.sql，由 scripts/init-db.mjs 包在同一事务里。
--
-- ⚠️ 首次登录账号**不在版本库里创建**。由运维在部署后用内部脚本生成，
--    口令只存在于该次运行的输入中。任何「开箱即用的演示账号」都不要写进这里。
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- 1. 学科（十科，与原工程 src/subjects.js 的 SUBJECTS 逐字一致）
--    「其他」也是合法值，别顺手删掉：客户端与服务端都在用。
-- ───────────────────────────────────────────────────────────────────────────
INSERT INTO app_dict (dict_type, code, label, sort_order) VALUES
  ('subject', '语文', '语文', 1),
  ('subject', '数学', '数学', 2),
  ('subject', '英语', '英语', 3),
  ('subject', '物理', '物理', 4),
  ('subject', '化学', '化学', 5),
  ('subject', '生物', '生物', 6),
  ('subject', '历史', '历史', 7),
  ('subject', '地理', '地理', 8),
  ('subject', '政治', '政治', 9),
  ('subject', '其他', '其他', 10)
ON CONFLICT (dict_type, code) DO NOTHING;

-- ───────────────────────────────────────────────────────────────────────────
-- 2. 年级规范词
--    只有这一套词。档案页、错题归档、教材导入弹窗三处必须引用同一份常量；
--    历史行里的「七/八/九年级」「7年级」等别名由客户端归一，不在这里 UPDATE。
-- ───────────────────────────────────────────────────────────────────────────
INSERT INTO app_dict (dict_type, code, label, sort_order) VALUES
  ('grade', '一年级', '一年级', 1),
  ('grade', '二年级', '二年级', 2),
  ('grade', '三年级', '三年级', 3),
  ('grade', '四年级', '四年级', 4),
  ('grade', '五年级', '五年级', 5),
  ('grade', '六年级', '六年级', 6),
  ('grade', '初一',   '初一',   7),
  ('grade', '初二',   '初二',   8),
  ('grade', '初三',   '初三',   9),
  ('grade', '高一',   '高一',   10),
  ('grade', '高二',   '高二',   11),
  ('grade', '高三',   '高三',   12)
ON CONFLICT (dict_type, code) DO NOTHING;

-- ───────────────────────────────────────────────────────────────────────────
-- 3. 状态词
--    ⚠️ 这些词以字符串形式同时活在 DB 列值、RLS 可见集合计算、路由校验、
--       以及客户端 Dart 枚举里。写错一个字母不报错，只是「永远匹配不到行」。
--       服务端统一从 backend/shared/vocab.js 取词，不在这里之外写字面量。
-- ───────────────────────────────────────────────────────────────────────────
INSERT INTO app_dict (dict_type, code, label, sort_order) VALUES
  ('status', 'relationship.pending',  '结伴·待回应',   1),
  ('status', 'relationship.active',   '结伴·已生效',   2),
  ('status', 'relationship.rejected', '结伴·已拒绝',   3),
  ('status', 'relationship.removed',  '结伴·已解除',   4),
  ('status', 'plan.pending',          '计划·待确认',   5),
  ('status', 'plan.active',           '计划·进行中',   6),
  ('status', 'plan.rejected',         '计划·已拒绝',   7),
  ('status', 'plan.completed',        '计划·已完成',   8),
  ('status', 'plan.expired',          '计划·已到期',   9),
  ('status', 'quiz.pending',          '打卡·待作答',   10),
  ('status', 'quiz.done',             '打卡·已交卷',   11),
  ('status', 'paper.draft',           '试卷·草稿',     12),
  ('status', 'mistake.pending',       '错题·待复习',   13),
  ('status', 'mistake.reviewing',     '错题·复习中',   14),
  ('status', 'mistake.verifying',     '错题·验证中',   15),
  ('status', 'mistake.mastered',      '错题·已掌握',   16)
ON CONFLICT (dict_type, code) DO NOTHING;

-- ───────────────────────────────────────────────────────────────────────────
-- 4. 难度档位（与 subject_scope.difficulty 的 CHECK 约束一致）
-- ───────────────────────────────────────────────────────────────────────────
INSERT INTO app_dict (dict_type, code, label, sort_order) VALUES
  ('difficulty', '基础', '基础', 1),
  ('difficulty', '提高', '提高', 2),
  ('difficulty', '挑战', '挑战', 3)
ON CONFLICT (dict_type, code) DO NOTHING;
