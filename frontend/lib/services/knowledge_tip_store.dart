import '../models/knowledge_tip.dart';

/// 知识点提示的存储口。
///
/// 抽出来只有两个理由，但都值：
/// 1. 它**只在本机**（见 `KnowledgeTipService` 的说明），不该和云同步接口混在一起；
/// 2. 判据要能在没有数据库的环境里跑 —— 提示的取舍规则（缓存新鲜度、
///    错题池变了要不要重算）与 SQLite 无关，掺进去只会让测试慢且脆。
abstract class KnowledgeTipStore {
  Future<List<KnowledgeTip>> queryKnowledgeTips({
    required String studentId,
    required String subject,
  });

  Future<void> replaceKnowledgeTips({
    required String studentId,
    required String subject,
    required List<KnowledgeTip> tips,
  });
}
