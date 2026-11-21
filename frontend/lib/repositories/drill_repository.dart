import '../models/drill_question.dart';

/// 每日概念训练的存储口。
///
/// ## 为什么只有一个本地实现
///
/// 与 `knowledge_tip` 同一路线（见 `DatabaseService` 的「本机缓存」段）：
/// 训练是孩子一个人在手机上完成的动作，记录跟着设备走即可；上云的代价
/// 是每个家庭的孩子互相读到别人的训练流水，而收益（跨设备续练）目前
/// 没有真实场景。**跨设备同步与家长端可见列入后续版本**，接口先冻结，
/// 到时「多实现一份」而不是「重写」。
abstract class DrillRepository {
  /// 该生的训练流水，新的在前。
  Future<List<DrillAnswer>> queryDrillAnswers({
    required String studentId,
    int limit = 300,
  });

  /// 一次提交的整组作答（同一天同一批题）。
  ///
  /// 批量而不是逐条：一组题要么整组记下，要么整组没记 ——
  /// 记了一半的历史会让「最近一次做错」这种判断落到一条残记录上。
  Future<void> insertDrillAnswers(List<DrillAnswer> answers);
}
