// 年级 / 学期的统一定义与比对。
//
// 🔴 年级只有这一份真值：[kGradeOptions]。学生档案页、错题本年级归档、
// 教材/词表导入弹窗都必须引用它。11-12 曾在这里另造一套
// 「七年级 / 八年级 / 九年级」，而档案里是「初一 / 初二 / 初三」：
// 于是家长导入选了「七年级」、档案是「初一」，同一个年级被判成不匹配，
// 弹窗预填还因为 `初一` 不在选项里悄悄退成「一年级」（11-13 修）。
//
// 「七年级」这类写法是**同一个年级的别名**，不是另一个年级：老数据、
// 家长手写、教材书名里都可能出现。新写入统一存 `初X`，读入用
// [canonicalGrade] 归一，比对与展示都只看归一后的值；历史行不做 UPDATE。

/// 可选年级（小学到高三，按升序）。**与档案页、错题归档顺序逐字一致**。
const List<String> kGradeOptions = <String>[
  '一年级',
  '二年级',
  '三年级',
  '四年级',
  '五年级',
  '六年级',
  '初一',
  '初二',
  '初三',
  '高一',
  '高二',
  '高三',
];

/// 学生档案里「没填年级」的占位值。比对时算「不知道」，不算不匹配。
const String kGradeUnset = '未填写';

/// 学期：只有上 / 下两档。
const List<String> kTermOptions = <String>['上', '下'];

/// 同一年级的别名 → 规范值。只收「明显就是同一个年级」的写法；
/// 不猜 `七上` 这种把学期粘进年级的（那是两个字段，别混成一个）。
const Map<String, String> kGradeAliases = <String, String>{
  '七年级': '初一',
  '7年级': '初一',
  '八年级': '初二',
  '8年级': '初二',
  '九年级': '初三',
  '9年级': '初三',
};

/// 把任意年级写法归一到 [kGradeOptions] 里的值。
/// 认不出来的**原样返回**（宽松：宁可当「不知道」，也不硬判成不匹配）。
String canonicalGrade(String grade) {
  final g = grade.trim();
  if (g.isEmpty) return '';
  return kGradeAliases[g] ?? g;
}

/// 导入弹窗的预填年级：归一后仍在选项里就用它，否则退到第一个。
/// 单拎成纯函数是为了能被测 —— 预填错一度让「初一」变「一年级」。
String pickerInitialGrade(String profileGrade) {
  final g = canonicalGrade(profileGrade);
  return kGradeOptions.contains(g) ? g : kGradeOptions.first;
}

/// 档案页下拉的初始年级。与 [pickerInitialGrade] 不同：**档案允许「不知道」**，
/// 所以认不出来就显示 [kGradeUnset]，而不是硬塞一个「一年级」；
/// 也避免把不在 items 里的值交给 `DropdownButtonFormField.initialValue`（会抛断言）。
String profileInitialGrade(String raw) {
  final g = canonicalGrade(raw);
  if (g.isEmpty || g == kGradeUnset) return kGradeUnset;
  return kGradeOptions.contains(g) ? g : kGradeUnset;
}

/// `上` → `上学期`，`下` → `下学期`，其余 → 空串。
String termFull(String term) {
  if (term == '上') return '上学期';
  if (term == '下') return '下学期';
  return '';
}

/// 把年级 + 学期拼成展示串：`初一` / `七年级` + `上` → `初一上学期`。
/// 先归一，横幅两边才不会因为两种叫法写出「这本是七年级，当前是初一」。
String gradeTermLabel(String grade, String term) {
  final g = canonicalGrade(grade);
  if (g.isEmpty) return '';
  final t = termFull(term.trim());
  return t.isEmpty ? g : '$g$t';
}

/// 书的年级学期与学生的当前年级学期**是否不匹配**。
///
/// 判据（刻意宽松，匹配不上就当「不知道」而不是「不匹配」）：
/// - 书没标注年级（老数据，空串 / `未填写`）→ 不知道，不算不匹配；
/// - 学生档案没设年级（空串 / `未填写`）→ 不知道，不算不匹配；
/// - **两边先归一**：`七年级` 与 `初一` 是同一个年级，不算不匹配；
/// - 其余情况任一不等即不匹配。
bool gradeTermMismatch({
  required String bookGrade,
  required String bookTerm,
  required String profileGrade,
  required String profileTerm,
}) {
  final bg = canonicalGrade(bookGrade);
  final pg = canonicalGrade(profileGrade);
  if (bg.isEmpty || pg.isEmpty) return false;
  if (bg == kGradeUnset || pg == kGradeUnset) return false;
  return bg != pg || bookTerm.trim() != profileTerm.trim();
}
