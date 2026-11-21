/**
 * 跨端**状态词**的单一来源。
 *
 * ## 为什么值得单独一个文件
 *
 * 这些词以字符串形式同时活在四个地方：DB 列的值、RLS 可见集合的计算
 * （`db.js: resolveVisibleStudents`）、路由的校验与 SQL（`notify.js` /
 * `relationship.js` / `study_plan.js`）、以及**客户端的 Dart 枚举**。
 * 它们之间必须逐字相同 —— 而字符串字面量一旦散落，写错一个字母：
 *
 *   - **不报错**。`where status = 'active'` 与 `where status = 'accepted'`
 *     在 PG 里都是合法 SQL，只是其中一个**永远匹配不到行**。
 *   - **症状长在别处**。可见集合算成空 → 家长看不到自己的孩子。
 *     看起来像「结伴没成功」，而关系在库里好好的。
 *
 * 这个 bug 真实发生过：客户端那份映射少了一个词，后果是家长端永远显示
 * 「尚未与任何学生结伴」，而 `/data/homework` 那条路完全是好的
 * （它不经过那个枚举）—— 两个功能各说各话，根因在一个字符串上。
 * 见 `lib/services/http_relationship_repository.dart` 的历史注释。
 *
 * 所以：**服务端每一个状态比较都从这里取词**，不再写字面量。
 * RLS 那个字面量尤其要紧 —— 它是「要不要隐藏数据」的开关。
 *
 * ## 与客户端词表的现状
 *
 * | 概念 | 服务端（本文件） | 客户端（Dart 枚举） | 是否一致 |
 * |---|---|---|---|
 * | 结伴关系 | `pending / active / rejected / removed` | `RelationshipStatus.pending / active / rejected / removed` | ✅ 词一致 |
 * | 学习计划 | `pending / active / rejected / completed / expired` | `StudyPlanStatus.pendingStudentConfirm / active / rejected / withdrawn / completed` | ⚠️ 仍不同 |
 *
 * 结伴关系这一行是 **2026-09-20 统一的**：服务端原用 `accepted`，
 * 与客户端的 `active` 是两个词，靠客户端仓库层做双向翻译活着
 * （迁移 `007_status_vocab_active.sql` 做数据侧的一半）。
 *
 * ⚠️ `removed` 这一格 **2026-09-26 才对齐**：在那之前客户端有、服务端没有，
 * 当时写下的判断是「服务端没有『删好友』这个动作，所以不算少一个词，是少一件事」——
 * 那句话在**解除功能落地前**是对的。现在服务端也有了 `removed`
 * （`routes/relationship.js: revoke`，家长单方解除），词表逐字对齐。
 * 留在这里是提醒：**「对面没有这个词」有时只是「这件事还没做」**，
 * 而这两者在下一次读这段注释的人眼里长得一模一样。
 *
 * ⚠️ 学习计划那一行**仍然不同，且不是命名风格问题**：
 *   - 服务端 `pending`（待确认）↔ 客户端 `pendingStudentConfirm`：同一个语义，
 *     两个词。**这一处仍靠客户端翻译**，合并它要动客户端的落库值。
 *   - 服务端 `expired`（到期自动失效）与客户端 `withdrawn`（家长撤回）
 *     在对面**都没有对应值**。它们是两个不同的动作，谁把它结束的这件事
 *     只在各自那一侧记着 —— 硬凑成一个词就会把这条信息丢掉。
 * 所以学习计划这层映射（`http_study_plan_repository.dart`）**不是权宜之计，
 * 是当前就该存在的东西**；要消掉它得先在两侧都加词，而不是改词。
 */

/**
 * 结伴关系的状态机：`pending` → `active` / `rejected`，`active` → `removed`。
 *
 * ## `removed` 是**软删**：那一行留在库里，只改状态
 *
 * 不是「DELETE 掉这一行」，有两个都躲不掉的理由：
 *
 *   ① `uq_relation UNIQUE (student_id, parent_id)` —— 删了再结伴当然也能插进去，
 *      但**不删就必然撞约束**。既然重新结伴这条产品路径一定存在
 *      （家长解除后又想连上），那就得让同一格能「复活」，而这要求那一行还在。
 *   ② 留痕。**「谁在什么时候断的」这件事只在这里记着** ——
 *      而现在表上**没有 `removed_at` 列**，所以时间只剩 `created_at`（会被复活时重置）。
 *      真要审计得补一列，见 `doc/open-items.md` 的 B22。
 *
 * ⚠️ 它**不是** `rejected` 的别名：`rejected` = 「邀请被拒了」，`removed` = 「原本成立的关系被断开」。
 * 两者都会让 `invite` 放行（见 `routes/relationship.js`），但来源完全不同。
 */
export const RELATIONSHIP_STATUS = Object.freeze({
  /** 邀请已发出，另一方尚未回应。 */
  pending: 'pending',
  /**
   * 关系成立。
   *
   * **这一个词同时是 RLS 的准入条件** —— `resolveVisibleStudents()` 用它决定
   * 「这个家长能看哪些学生」，而 RLS 的 policy 只认算出来的那个集合。
   * 改错它的后果不是报错，是家长看不到自己的孩子（见文件头）。
   */
  active: 'active',
  rejected: 'rejected',
  /**
   * 关系被解除（家长单方，见 `routes/relationship.js: revoke`）。
   *
   * **它同时也是「家长此刻看不到任何数据」的开关** —— 家长端所有学生数据的读
   * 都经过 `resolveVisibleStudents`，而这个函数只算 `active`。所以解除的后果
   * 不是报错，是**取回来的列表静默变空**（家长端显示「尚未与任何学生结伴」）。
   *
   * ⚠️ 反过来也成立，而且更值得知道：**重新结伴后，可见性完整恢复** ——
   * 包括解除期间孩子自己产生的打卡 / 作业 / 错题。因为数据按 `student_id` 存，
   * 行上没有「属于哪一段结伴期」的标记。这是 2026-09-26 核对过的**产品决定**，
   * 不是遗漏；要改得给可见集合加时间下界，代价见 B22。
   */
  removed: 'removed',
});

/** 关系成立时的值。给「只关心成立与否」的地方用（可见集合、通知收件人）。 */
export const RELATIONSHIP_ACTIVE = RELATIONSHIP_STATUS.active;

/**
 * 「接受 / 拒绝」这两个动作的合法取值（`updateStatus` 的入参白名单）。
 *
 * **不含 `pending`**：`pending` 是发起时的初始状态，不是一个可以「改过去」的目标。
 * 让它在白名单里会多出一个语义可疑的动作（把已确认的关系退回待确认）。
 *
 * **也不含 `removed`**：解除**故意不走这个端点**，它有自己的
 * `POST /data/relationship/revoke`。两者差的不是取值，是**前置状态与权限**：
 *
 *   | | `updateStatus`（接受/拒绝） | `revoke`（解除） |
 *   |---|---|---|
 *   | 前置状态 | `pending` | `active` |
 *   | 谁能做 | 被邀请的那一方 | **只有家长**（产品决定，2026-09-26） |
 *   | 语义 | 回应一个邀请 | 撤销一段已成立的关系 |
 *
 * 把它们合进一个端点的话，`updateStatus` 里那句 `and status = $3` 会变成
 * 「按传入的 status 反推前置状态」——一个 3×3 的隐式矩阵，而这里面
 * 只有 2 格是合法的。**读代码的人得自己在脑子里枚举**，这比多一个端点贵得多。
 */
export const RELATIONSHIP_APPROVAL_STATUSES = Object.freeze([
  RELATIONSHIP_STATUS.active,
  RELATIONSHIP_STATUS.rejected,
]);

/**
 * 哪些状态下，**同一对（学生，家长）可以重新结伴**（`invite` 的 `on conflict ... where`）。
 *
 * 两个值各代表一种「已经结束的关系」：
 *   · `removed` —— 家长解除过（2026-09-26 新增的 `revoke`）；
 *   · `rejected` —— 上次的邀请被拒了。
 *
 * ⚠️ 加上 `rejected` 是**顺手修掉的一个现存缺陷**，不是解除功能的一部分：
 * 在那之前「被拒绝」是这条关系的终点 —— `invite` 撞 `uq_relation`、
 * 回一句「你们已经结伴」，而事实是**再也没人能邀请这一对**（换个手机号也不行，
 * 唯一约束盯的是 `student_id + parent_id`，不是手机号）。
 * 客户端本地实现当时只放行 `removed`，所以两台手机的云上行为与本地也不同。
 * 产品上「上次拒了，这次同意了」是最正常不过的事，把它永久锁死没有依据。
 *
 * 放在 vocab.js 而不是路由里：它与 `RELATIONSHIP_APPROVAL_STATUSES` 是同一类东西
 * （状态词的**集合**），且改错的症状是静默的 —— 重新结伴失败，报的却是一句
 * 与事实相反的话。
 */
export const RELATIONSHIP_REVIVABLE_STATUSES = Object.freeze([
  RELATIONSHIP_STATUS.removed,
  RELATIONSHIP_STATUS.rejected,
]);

/**
 * 学习计划的状态值域（`updatePlanStatus` 的入参白名单）。
 *
 * 服务端**只拦拼写错误，不判流转是否合法** —— `pending → completed` 这种跳步
 * 在这里是允许的。流转规则归客户端 L1：它和「拒绝理由要不要清」绑在一起，
 * 属于产品判断，两边各判一次就会出现两个真相（理由见 `routes/study_plan.js`）。
 */
export const STUDY_PLAN_STATUSES = Object.freeze([
  'pending',
  'active',
  'rejected',
  'completed',
  'expired',
]);
