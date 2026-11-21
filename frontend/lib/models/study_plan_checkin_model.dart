/// 学习计划每日打卡记录（一条 = 某学生在某天完成了某个学习计划）
class StudyPlanCheckin {
  final String id;
  final String planId;
  final String studentId;

  /// 打卡日期，格式 yyyy-MM-dd
  final String date;
  final DateTime createdAt;

  const StudyPlanCheckin({
    required this.id,
    required this.planId,
    required this.studentId,
    required this.date,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'planId': planId,
    'studentId': studentId,
    'date': date,
    'createdAt': createdAt.toIso8601String(),
  };

  factory StudyPlanCheckin.fromMap(Map<String, dynamic> map) {
    return StudyPlanCheckin(
      id: map['id'] as String,
      planId: map['planId'] as String,
      studentId: (map['studentId'] as String?) ?? '',
      date: map['date'] as String,
      createdAt: DateTime.parse(map['createdAt'] as String),
    );
  }
}

/// 日期统一格式化为 yyyy-MM-dd
String studyPlanDateKey(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// 把服务端返回的任意形态日期字段，归一为纯 `yyyy-MM-dd`。
///
/// ## 为什么需要它（一个只在走 HTTP 时才复现的静默 bug）
///
/// 服务端 `rowToApi` 会把 PG 的 `DATE` 列（node-postgres 把它解析成 `Date`
/// 对象）序列化成 `YYYY-MM-DDTHH:MM:SS.000Z` —— 在服务器非 UTC 时区下甚至会
/// 变成**前一天**。而客户端本地生成、比较、做近 7 天打点用的都是
/// `studyPlanDateKey`（纯 `yyyy-MM-dd`）。若把服务端返回的 ISO 串原样当字符串
/// 比较，永远不会相等：
///
/// **打卡其实已经存进库，刷新从服务端读回却「认不出」，于是界面又变回
/// 「今天有 N 个学习计划待打卡」** —— 这正是「点完已打卡、刷新又待打卡」
/// 周而复始的根因。本地 SQLite 路径不走 `rowToApi`，所以不受影响。
///
/// 处理策略：能解析就按**本地日期部分**取年月日（规避 UTC 偏移导致的差一天），
/// 兜底再截前 10 位。
String studyPlanDateKeyFromRaw(dynamic raw) {
  if (raw == null) return '';
  final s = raw is String ? raw : raw.toString();
  final dt = DateTime.tryParse(s);
  if (dt != null) {
    // 先转到本地时区再取日期，规避 UTC 偏移造成的「差一天」。
    return studyPlanDateKey(dt.toLocal());
  }
  // 兜底：ISO 串形如 `2026-10-27T...`，截前 10 位。
  return s.length >= 10 ? s.substring(0, 10) : s;
}
