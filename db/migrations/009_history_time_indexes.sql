-- 历史数据的时间窗查询：补三处复合索引
--
-- ## 为什么这条迁移是「判据的一部分」而不是顺手做的优化
--
-- 起因见 `doc/historical-data-plan.md`：日历只有本周，查历史无从下手。查下去发现
-- 真正的窟窿是**查询没有时间窗能力** —— `listHomework` 是
-- `order by due_at desc limit 50`，作业存够 200 条之后历史在**接口层面**就取不到，
-- 而界面看起来完全正常（显示 50 条，只是那 50 条全是最近的）。
--
-- 修法是在三个列表端点上加**可选**的 `from` / `to`。参数一加上去，SQL 形状就从
-- 「按 student_id 取前 N 条」变成「按 student_id 取某个时间区间内的全部」——
-- 后者没有 `limit` 兜底（只有防爆的上限），所以它会**真的去扫一个区间**。
-- 没有 `(student_id, <时间列>)` 的复合索引时，PG 只能：
--   ① seq scan 整表再在内存里筛 → 数据量一上来就慢；
--   ② 或者**用上已有的 `(student_id, status)` 这类索引**再回表过滤 ——
--      这在「只看某一个学生」时看起来还行，一旦家长有两个孩子、
--      或者某个学生数据多一点，计划就会翻脸。
--
-- ⚠️ 更要紧的是**它不是性能问题，是判据问题**：计划 §3.2 的 P1 前提写着
--    「永久保留的前提是查询必须有时间窗能力，不能靠 limit 兜」。如果时间窗查询
--    在某一天悄悄变慢到超时，客户端那侧的表现是**那段列表空掉**（本项目对读失败
--    的一贯处置是静默降级），于是回到「历史取不到」——只是这次连 limit 都不背锅了。
--    所以建索引这一步要和端点改动一起落，别拆开。
--
-- ## 补哪三个
--
--   · `homework(student_id, due_at)` —— 作业按**到期日**筛。
--     已有的 `idx_homework_student_status` 是 `(student_id, status)`，没有 due_at 可用。
--   · `review_mistake(student_id, last_wrong_at)` —— 错题按**最后一次做错**的时刻筛。
--     已有的 `idx_review_mistake_student` 是 `(student_id, state)`。
--   · `study_plan(student_id, start_at)` —— 计划按**起始时刻**筛（「那阵子在学什么」）。
--     已有的 `idx_study_plan_student` 是 `(student_id, status)`。
--
-- ⚠️ `study_plan` 这一列**不是 `created_at`** —— 我第一版就是按「别的表都有 created_at」
--    的惯性写的，而这个表**根本没有 created_at**（它的时间列只有 `start_at` / `end_at`，
--    见 001 的建表语句）。后果是迁移直接失败：
--
--       迁移 009_history_time_indexes.sql 失败：column "created_at" does not exist
--
--    这个错**之所以能被发现，是因为迁移是把每个文件包在一个事务里执行的**
--    （见 `src/migrate.js`）：失败即整个文件回滚，而且报错带文件名。
--    如果它是「逐条执行、失败就跳过」，这里会留下一个**索引没建**的库，
--    而所有测试照绿 —— 正是本项目最恨的那类静默失败。
--    记下来：**加索引前先读建表语句，别按套路猜列名。**
--
-- 说明：`workout_record` 与 `study_plan_checkin` **不需要动** ——
-- 它们已经有 `(student_id, start_at DESC)` 与 `(student_id, date)`，
-- 正是时间窗查询要的形状（`DESC` 不影响范围扫描，PG 两个方向都能走）。
-- 补索引这件事容易「顺手多补几个」，而每个多余的索引都要在每次写入时维护，
-- 所以这里只补真正缺的三个。
--
-- ## 为什么用 `IF NOT EXISTS`
--
-- `runMigrations` 用 `schema_migrations` 表保证只执行一次（见 `src/migrate.js`），
-- 正常路径下这里不会重跑。但手工在云上排障时经常会直接贴这段 SQL 试试，
-- 加上 `if not exists` 让那种操作是无害的（同 005/007/008 的处置）。
--
-- ⚠️ `due_at` 允许为 NULL（DDL 里没有 not null），NULL 在 B-tree 里排在最后，
--    不参与范围扫描 —— 这正是我们要的：没有到期日的作业不属于任何一天，
--    日历上不该打点（客户端 `_isSameDay` 对 null 也是不匹配）。

create index if not exists idx_homework_student_due_at
  on homework(student_id, due_at);

create index if not exists idx_review_mistake_student_last_wrong
  on review_mistake(student_id, last_wrong_at);

-- ⚠️ 列名是 `start_at` **不是 `created_at`**（这个表没有 created_at）。
create index if not exists idx_study_plan_student_start_at
  on study_plan(student_id, start_at);
