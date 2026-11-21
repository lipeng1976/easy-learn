-- 伴学 APP 数据服务 —— 复习组的两条结构性补课（S3）
--
-- 本文件不新增表，只补两条**本地实现靠约定维持、而约定在网络边界上不成立**的不变式。
--
-- 执行方式：由 src/migrate.js 在事务内按文件名顺序执行，本文件**不要自带 BEGIN/COMMIT**。

-- ===== 1/1 周期报告：同一周期只能有一份 =====
--
-- ## 本地是怎么做的
--
-- `review_controller.generateReport` 构造报告时把 id 拼成 `sum_{studentId}_{scopeKey}`
-- （`review_service.dart:145`），写入用 `ConflictAlgorithm.replace` ——
-- 于是「同一周期重复生成只保留最新一份」这件事**成立，但只因为 id 的拼法**。
--
-- ## 为什么上云后不能继续靠它
--
-- 三件事变了：
--   ① **id 不再由客户端给**（R2）。服务端一旦改用 uuid，「同周覆盖」当场失效，
--      同一周会攒出十几份内容各异的报告，而每一份看起来都对；
--   ② 客户端可能**不只有 Flutter 一个**（小程序端要重写），拼 id 的约定要抄两遍；
--   ③ 「重复生成」是**正常操作**（用户多看两眼就多生成一次），
--      所以这不是异常路径，是每次都会走的主路径。
--
-- 补一条唯一约束之后，覆盖写入交给 `ON CONFLICT (student_id, scope, scope_key)
-- DO UPDATE`（见 routes/review.js 的 upsertSummary），id 的拼法就只是**可读性**问题。
--
-- ⚠️ 为什么把 `scope` 也放进键：本地 id 里**只有 scopeKey**，靠「不同 scope 的
-- scopeKey 形制不同」（ISO 周 vs 月）来保证不撞。那是一个隐式假设，
-- 而它一旦被打破（例如将来加一个「按科目」的口径，键也是日期），
-- 症状是两份不同口径的报告互相覆盖 —— 用户看到的是「这周的报告变成了上个月的数」。
-- 显式写进键里，就不会有这个失效模式。
CREATE UNIQUE INDEX uq_review_summary_period
  ON review_summary(student_id, scope, scope_key);

-- 顺带把「按周期取一份」的读法变成索引扫描（`storedReport` 那条路径每个页面都会走）。
CREATE INDEX idx_review_summary_period
  ON review_summary(student_id, scope, generated_at DESC);
