-- 学科范围：家长为每个科目配一次「练什么」，出题时直接用它
--
-- ## 为什么按 (student_id, subject) 建联合主键
--
-- 一个孩子一科一行；同一份配置要被**父母双方**看到（父亲配好、母亲那边也显示已配），
-- 所以必须落服务端 —— 客户端 `app_setting` 是裸 key、没有 student_id 列，
-- 多孩家庭切孩子必然串（哥哥的数学范围变成弟弟的）。
--
-- ## 为什么 points 是 jsonb 而不是单独一张表
--
-- 这里存的是「范围条目」：数学是知识点、语文是字词/古诗、历史是时间点+事件。
-- 四科的形状不同，但都是**一屏内可编辑的有序短清单**（≤6 条，顺序即优先级，
-- 与 `MAX_CHECKIN_ITEMS` 同一个数）。拆成四张表只会让「列表 / 保存 / 校验」各写四遍。
--
-- 条目由家长**手填**或从错题本同科知识点里挑，服务端不解释其内容 ——
-- 它只是出题时原样带给模型（`/data/checkin/generate` 的 `knowledgePoints`）。
--
-- ## 为什么这里没有「启用」列
--
-- 「这科要不要练」= 有没有这一行。删掉一行就是关掉，省掉「有配置但 disabled」
-- 与「没配置」两种状态在下游各写一遍分支。
--
-- ## 表没迁移时不报错
--
-- 与 `025_word_checkin.sql` 同一口径：只读端点按「未配置」降级（页面照常渲染、
-- 只是每科都显示未配），写端点响亮失败（家长正等着结果）。
--
-- ⚠️ 科目白名单以客户端 `HomeworkItemNormalizer.subjectNames` 为准，
-- 服务端 `routes/subject.js` 里那份必须逐字一致（两处都有判据盯）。

CREATE TABLE IF NOT EXISTS subject_scope (
  student_id  TEXT NOT NULL,
  subject     TEXT NOT NULL,
  -- 3 / 5 / 8：与 `checkin_setup_page.countChoices` 同一档位。
  -- 不给自由输入 —— 输个 9 出来的题要么敷衍、要么做不完。
  daily_count INTEGER NOT NULL DEFAULT 5,
  -- 基础 / 提高 / 挑战：与 `kCheckinDifficulties` 同一口径。
  difficulty  TEXT NOT NULL DEFAULT '基础',
  -- ["有理数加减", "整式化简"]；顺序即优先级，最多 6 条（网关 MAX_CHECKIN_ITEMS）。
  points      JSONB NOT NULL DEFAULT '[]'::jsonb,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (student_id, subject),
  CONSTRAINT ck_subject_scope_count CHECK (daily_count IN (3, 5, 8)),
  CONSTRAINT ck_subject_scope_difficulty
    CHECK (difficulty IN ('基础', '提高', '挑战')),
  CONSTRAINT ck_subject_scope_points CHECK (jsonb_typeof(points) = 'array')
);

-- ===== RLS：与 023_reading / 025_word_checkin 完全同一口径 =====
-- 可见集合 = 自己 + 家长可见的 active 孩子。
ALTER TABLE subject_scope ENABLE ROW LEVEL SECURITY;
ALTER TABLE subject_scope FORCE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON subject_scope USING (
  student_id = ANY(app_csv_setting('app.visible_students'))
);
