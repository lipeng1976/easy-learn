/// 服务端 JSON → 客户端模型的取值工具。
///
/// ## 为什么需要这一层（而不是直接 `row['x'] as String`）
///
/// 两条链路给出的**行长得不一样**，而且差别不是「写法不同」这么轻：
///
/// | | 本地（SQLite） | 服务端（PostgreSQL / JSON） |
/// |---|---|---|
/// | 布尔 | `1` / `0` | `true` / `false` |
/// | 时间 | `2026-09-19T20:00:00.000`（**无时区，本地时间**） | `2026-09-19T12:00:00.000Z`（UTC） |
/// | 数值列 | 可能是 `int` 也可能是 `double` | NUMERIC 经 JSON 出来是**字符串** |
/// | 缺列 | 老库的行可能真的没有这一列 | 服务端按契约总会给 |
///
/// 前两条都踩过：
/// - `aiEnabled: (row['aiEnabled'] as num?)?.toInt() == 1` 在本地是对的，
///   而服务端给的是 `true` —— `as num?` 得到 `null`，`null == 1` 是 `false`，
///   于是**一份开着 AI 的作业在云端被读成「关了 AI」**，不报错。
/// - 时间若不 `.toLocal()`，全部显示会差一个时区（东八区差 8 小时）。
///   线上表现是「今天的作业显示成昨天晚上」。
///
/// 所以这一层的职责只有一个：**把服务端的行翻译成本地那套形状**，
/// 之后模型自己的 `fromMap` 就是唯一入口 —— 不需要给每个模型写两遍解析。
library;

/// 布尔：`true` / `1` / `'1'` / `'true'` 都算真。
bool boolOf(Object? value, {bool fallback = false}) {
  if (value == null) return fallback;
  if (value is bool) return value;
  if (value is num) return value.toInt() != 0;
  final text = value.toString().trim().toLowerCase();
  if (text.isEmpty) return fallback;
  return text == '1' || text == 'true' || text == 'yes';
}

/// 布尔 → 本地那套 `1 / 0`。
///
/// 用在**上行**方向：`HomeworkPatch` 等本地结构用 `1/0` 表达布尔，
/// 服务端的 `toBool` 两种都认，但原样转发能让「同一份请求在两条链路里长得一样」，
/// 排查时少一个变量。
int intFromBool(bool value) => value ? 1 : 0;

/// 整数：数字、数字字符串（NUMERIC 列经 JSON 会变字符串）、布尔都能接。
int intOf(Object? value, {int fallback = 0}) {
  if (value == null) return fallback;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is bool) return value ? 1 : 0;
  return int.tryParse(value.toString().trim()) ?? fallback;
}

int? intOrNull(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString().trim());
}

double doubleOf(Object? value, {double fallback = 0}) {
  if (value == null) return fallback;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString().trim()) ?? fallback;
}

String textOf(Object? value, {String fallback = ''}) {
  if (value == null) return fallback;
  if (value is String) return value;
  return value.toString();
}

/// 解析时间，**并转到本地时区**。
///
/// 服务端一律给带 `Z` 的 UTC；本地库里存的是不带时区的本地时间。
/// 不转的话，界面上的每个时间都会差一个时区。
DateTime? timeOf(Object? value) {
  if (value is DateTime) return value.toLocal();
  if (value is! String || value.trim().isEmpty) return null;
  final parsed = DateTime.tryParse(value.trim());
  return parsed?.toLocal();
}

DateTime timeOr(Object? value, DateTime fallback) => timeOf(value) ?? fallback;

/// 把服务端时间归一成「本地时间的无时区字符串」—— 与本地库里那一列**逐字同形**。
///
/// 它的用途是喂给模型自己的 `fromMap`（那些 `fromMap` 是按本地行的形状写的，
/// 见 `HomeworkImageModel.fromMap` 里的 `createdAt`）。这样子模型层不需要知道
/// 世界上还有第二个时间格式。
String? localTimeText(Object? value) {
  final parsed = timeOf(value);
  return parsed?.toIso8601String();
}

/// 上行时间：转成 UTC ISO8601（带 `Z`）。
///
/// 服务端的 `toTs` 能解析带 `Z` 的字符串。**不要**用 `toIso8601String()` 直接发本地
/// 时间 —— 那会丢掉时区，服务端按 UTC 解读，于是「今晚 8 点交」变成「今天中午」。
String? utcTimeText(DateTime? value) => value?.toUtc().toIso8601String();

/// 把 JSON 列表转成一组 Map。
List<Map<String, dynamic>> mapList(Object? raw) {
  if (raw is! List) return const [];
  return raw.whereType<Map>().map(Map<String, dynamic>.from).toList();
}

/// 服务端「写成功但没有返回体」时的统一处理：不靠返回值，靠不抛异常。
void ignoreResult(Map<String, dynamic> _) {}
