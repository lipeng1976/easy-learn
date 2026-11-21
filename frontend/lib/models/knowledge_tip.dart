/// 一条知识点提示的**出处**。
///
/// 这两个值在界面上长得一样，但在数据层必须分开：
/// [rule] 是客户端按错题频次拼出来的**事实陈述**（「这个知识点你错过 3 次」），
/// 它没有经过模型，不能当成「知识点讲解」；
/// [model] 才是模型归纳出来的一句话要点。
///
/// 把两者混成一个值，会让「离线时看到了什么」这件事无法事后解释 ——
/// 而这正是本项目里最贵的一类 bug：看起来正常、语义已经错了。
enum KnowledgeTipSource { model, rule }

/// 送到模型去的**一个知识点**（已在客户端按知识点聚合过）。
///
/// 刻意不直接把 `ReviewMistake` 传下去：模型只需要「错了哪个知识点、错了几次、
/// 最近一次错在哪」，不需要题目原文、照片、学生答案。少传一份就少一份
/// 上行成本，也少一份把学生隐私送出去的路径。
class MistakeTipSeed {
  const MistakeTipSeed({
    required this.knowledgePoint,
    this.wrongCount = 1,
    this.wrongReason = '',
  });

  final String knowledgePoint;
  final int wrongCount;
  final String wrongReason;
}

/// AI 返回的一条提示（还没有学生、科目、时间这些归属信息）。
class MistakeTipDraft {
  const MistakeTipDraft({
    required this.knowledgePoint,
    required this.text,
    this.source = KnowledgeTipSource.model,
  });

  final String knowledgePoint;
  final String text;
  final KnowledgeTipSource source;
}

/// 落库的一条知识点提示。
///
/// ## 为什么带 [signature]
///
/// 提示是按「当前错题库」生成的一次快照。错题毕业、新增错题之后，
/// 旧提示就可能指向一个已经不存在的知识点。把生成时的输入指纹跟着每一行
/// 存下来，读缓存时一比就知道该不该重新生成 —— 比「按时间过期」准，
/// 也比「不判断、直接用」诚实。
class KnowledgeTip {
  const KnowledgeTip({
    required this.id,
    required this.studentId,
    required this.subject,
    required this.knowledgePoint,
    required this.text,
    required this.source,
    this.sortOrder = 0,
    required this.generatedAt,
    this.signature = '',
  });

  final String id;
  final String studentId;
  final String subject;
  final String knowledgePoint;
  final String text;
  final KnowledgeTipSource source;
  final int sortOrder;
  final DateTime generatedAt;
  final String signature;

  Map<String, dynamic> toMap() => {
    'id': id,
    'studentId': studentId,
    'subject': subject,
    'knowledgePoint': knowledgePoint,
    'text': text,
    'source': source.name,
    'sortOrder': sortOrder,
    'generatedAt': generatedAt.toIso8601String(),
    'signature': signature,
  };

  static KnowledgeTip fromMap(Map<String, dynamic> row) {
    return KnowledgeTip(
      id: (row['id'] as String?) ?? '',
      studentId: (row['studentId'] as String?) ?? '',
      subject: (row['subject'] as String?) ?? '',
      knowledgePoint: (row['knowledgePoint'] as String?) ?? '',
      text: (row['text'] as String?) ?? '',
      // 认不出来时按 [rule] 处理：宁可把模型结果标低，也不要让一段
      // 没人核实过的文字冒充「模型归纳」。
      source: (row['source'] as String?) == KnowledgeTipSource.model.name
          ? KnowledgeTipSource.model
          : KnowledgeTipSource.rule,
      sortOrder: (row['sortOrder'] as num?)?.toInt() ?? 0,
      generatedAt:
          DateTime.tryParse((row['generatedAt'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      signature: (row['signature'] as String?) ?? '',
    );
  }

  KnowledgeTip copyWith({int? sortOrder}) => KnowledgeTip(
    id: id,
    studentId: studentId,
    subject: subject,
    knowledgePoint: knowledgePoint,
    text: text,
    source: source,
    sortOrder: sortOrder ?? this.sortOrder,
    generatedAt: generatedAt,
    signature: signature,
  );
}
