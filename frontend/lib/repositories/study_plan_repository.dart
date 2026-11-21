import '../models/study_plan_checkin_model.dart';
import '../models/study_plan_model.dart';

/// 学习计划与每日打卡的数据访问契约（L2）。
///
/// ## ⚠️ 这个接口里**藏了一条业务规则**，它是第 1 步要剥出去的对象
///
/// [queryStudyPlans] 的 `userRole == 'student'` 分支是 `db.query('study_plan')`
/// 全表返回，而家长分支才按 `userRole` 过滤。也就是说
/// 「**学生能看到全部计划（含家长发来待确认的）、家长只看自己发出的**」
/// 这条可见性规则，**当前写在数据访问方法内部**。
///
/// 这是「规则与数据访问缠在一起」最典型的一处（`architecture-refactor-plan.md`
/// §2「缺的是」）。后果有两个：
/// 1. 换实现的人会以为 Student 分支那个全表查询是笔误，顺手「修」成过滤——
///    于是学生看不到家长发来的计划了；
/// 2. 上云后它就是**跨学生越权**：老师家孩子能看到全班同学的计划。
///
/// 处置：第 1 步把这条规则提到 L1（或服务端），接口只留「取计划」。
/// 在剥离之前，**服务端实现必须把等价规则实现一遍，且按 token 判定**，
/// 不要照抄「`student` 就返回全表」。
abstract class StudyPlanRepository {
  /// 取计划。可见性规则见类注释（**当前由本方法承担，是待剥离项**）。
  Future<List<StudyPlanModel>> queryStudyPlans(String userRole);

  /// 新建计划。
  ///
  /// [userRole] 写进 `study_plan.userRole` 列：家长发起的计划记 `parent`
  /// （学生端据此渲染成「待确认」），学生自建记 `student`。
  /// 与 `WishRepository.insertWish` 同形——都是把身份当数据存，
  /// 上云后都应换成服务端写入的 `creatorId`。
  Future<void> insertStudyPlan(StudyPlanModel plan, String userRole);

  /// 改计划状态（确认 / 拒绝 / 完成）。
  ///
  /// **本方法不做状态机校验**，只把 `status` 列写下去。调用方是否校验、
  /// 校验到什么程度由控制器决定。上云时要把这件事**明确归到一层**，
  /// 不要出现「两边都以为对方在拦」。
  ///
  /// [rejectReason] 只在传入时写入；传空串会被规范化成 `null`
  /// （「没有拒绝理由」在库里是 NULL，不是空字符串——查询端按 NULL 判断）。
  Future<void> updateStudyPlanStatus(
    String id,
    StudyPlanStatus status, {
    String? rejectReason,
  });

  /// 取全部打卡记录，**无任何过滤**。
  ///
  /// 客户端拿到后按 `studentId` 内存过滤（`_belongsToBound`）。
  /// 上云后必须把过滤下推到服务端，否则每个客户端都拉走全库打卡记录。
  Future<List<StudyPlanCheckin>> queryStudyPlanCheckins();

  /// 打卡（同一天同一计划**重复调用只应留下一条**）。
  ///
  /// ## 幂等性是结构性的，别在重写时弄丢
  ///
  /// 保证来自建表时的 `UNIQUE(planId, date)` 加
  /// `ConflictAlgorithm.replace`，**不是**调用方先查后插。
  /// 这跟 `PointRepository.insertPointLedger` 是同一族（陷阱①）：
  /// 正确性押在数据库约束上，代码只负责把它用起来。
  ///
  /// 上云后若丢掉这个唯一语义，症状是**打卡数翻倍**——客户端重试、
  /// 用户双击都会各插一条，而且不报错。服务端必须保留
  /// 「(planId, date) 唯一」并实现为原子 upsert。
  ///
  /// 另一个必须对齐的细节：`INSERT OR REPLACE` 会**换掉整行（含 id）**，
  /// 而 Web 实现是原地替换。两种写法对读端不可区分（读端只按 planId+date 认），
  /// 所以两边都合法——但服务端实现要选一种并写进契约，别引入第三种行为。
  Future<void> insertStudyPlanCheckin(StudyPlanCheckin checkin);

  /// 取消打卡。按**自然键**（计划 + 日期）删，不是按 id。
  Future<void> deleteStudyPlanCheckin(String planId, String date);
}
