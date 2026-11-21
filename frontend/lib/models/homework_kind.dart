/// 作业的类型与工作量估读。
///
/// 识别出来的一串文字里，其实已经包含了「这是件什么事」：
/// 「背诵《静夜思》」和「练习册P12-P14」都是作业，但**完成的样子完全不同** ——
/// 背诵没法拍照提交，口算20题也不该和一篇作文按同样的工作量算。
/// 这个信息本来就在文字里，丢掉它就得让学生逐条自己填一遍。
///
/// **只从标题推导，不落库**，理由两条：
/// 1. 学生随时会改标题。落库的副本会和标题对不上，而界面上显示的是哪一份
///    没人说得清 —— 这类「两个真相」的 bug 事后极难查。
/// 2. 这个字段出现之前的老作业立刻也能用上，不需要写迁移回填。
enum HomeworkKind {
  dictation('默写'),
  recitation('背诵'),
  reading('朗读'),
  oral('口算'),
  correction('订正'),
  preview('预习'),
  written('书面'),

  /// 字帖、练字、描红、抄写这类「照着写一遍」的作业。
  ///
  /// 声明放在最后**只是阅读顺序**，不是判定优先级 ——
  /// 优先级由 [_patterns] 的键序决定，而它在第一（理由见那里）。
  copywork('抄写');

  const HomeworkKind(this.label);

  /// 界面上给这一条打的标签。
  final String label;

  /// 判定顺序**就是优先级**，所以刻意用有序的 Map 而不是若干 if。
  ///
  /// 两个「两种都命中」的例子，顺序就是为它们定的：
  /// - 「背诵并默写」→ 取更靠前的「默写」：背下来还得落到纸上，
  ///   那才是老师第二天真正要检查的东西。
  /// - 「英语单词抄写」→ 取更靠前的「抄写」，而不是被「单词」拉去「默写」：
  ///   照着写和听人念着默出来是两回事。这两类在「要不要批改」上结论相同
  ///   （都不判对错），所以这里判错只影响那张类型标签 —— 但标签是学生
  ///   判断「系统有没有看懂我的作业」的依据，错了就会让他去关一个
  ///   本来就已经关着的开关。
  ///
  /// 顺序写在数据里，改动时必须连着注释一起看，别把它当成一张无关紧要的表。
  static const Map<HomeworkKind, String> _patterns = {
    HomeworkKind.copywork: '字帖|练字|描红|临摹|抄写',
    HomeworkKind.dictation: '默写|听写|单词',
    HomeworkKind.recitation: '背诵|背默|背课文|熟背',
    HomeworkKind.reading: '朗读|诵读|读课文|听读|熟读|阅读',
    HomeworkKind.oral: '口算|听算|速算|口头',
    HomeworkKind.correction: '订正|更正|改错|纠错',
    HomeworkKind.preview: '预习|复习',
  };

  /// 从标题文字判类型。判不出来就是「书面」—— 大多数作业本来就是书面的，
  /// 而给一个默认的错标签，比不给标签更误导。
  static HomeworkKind of(String title) {
    final text = title.trim();
    if (text.isEmpty) return HomeworkKind.written;
    for (final entry in _patterns.entries) {
      if (RegExp(entry.value).hasMatch(text)) return entry.key;
    }
    return HomeworkKind.written;
  }

  /// 这类作业的**默认**耗时（分钟）。
  ///
  /// 是给学生的起点，不是测算结果，所以取的都是整数 ——
  /// 30 和 32 对学生没有区别，但 32 会让他以为系统真的算过，
  /// 于是不再按自己的情况改。
  int get defaultMinutes => switch (this) {
    HomeworkKind.dictation => 15,
    HomeworkKind.recitation => 10,
    HomeworkKind.reading => 10,
    HomeworkKind.oral => 15,
    HomeworkKind.correction => 15,
    HomeworkKind.preview => 15,
    HomeworkKind.written => 30,
    HomeworkKind.copywork => 15,
  };

  /// 这类作业**要不要 AI 判对错**。判据只有一条：**答案在不在照片里**。
  ///
  /// - 口算、书面、订正：题目和答案在同一张纸上，模型照着题面就能判。
  /// - 默写、听写、抄写、字帖：纸上只有学生写的东西，**题干根本没被拍进来**
  ///   （词表是家长念的，范字在另一本书上）。模型只能猜他写的是什么、
  ///   猜得对不对 —— 这已经不是「判得准不准」，而是**没有可判的东西**。
  ///   这类作业的对错当场就由念词表的人核对完了，交上来的照片是
  ///   「我做过了」的凭证，不是一道待判的题。
  /// - 朗读、背诵、预习：产出是一段过程，不是一张纸。
  ///
  /// 硬把关不掉批改的作业送进批改，模型只能对着一张没有答案的照片编一份评语，
  /// 而那比不批改更坏：它看起来像结论。
  ///
  /// 这是**默认值**，不是判决：学生可以在录入时或提交前自己改
  /// （见 `NeedsGradingSwitch`），改了就落库。这里只负责给出
  /// 「最可能对的那一个」，让大多数情况下他不用做选择。
  ///
  /// 这里刻意写全八个分支而不是 `_ => true`：新增类型时编译器会提醒
  /// 回来想一遍「这类要不要批」，而不是安静地继承一个默认值。
  bool get needsGrading => switch (this) {
    HomeworkKind.dictation => false,
    HomeworkKind.recitation => false,
    HomeworkKind.reading => false,
    HomeworkKind.oral => true,
    HomeworkKind.correction => true,
    HomeworkKind.preview => false,
    HomeworkKind.written => true,
    HomeworkKind.copywork => false,
  };
}

/// 一条作业的页码跨度：`P12-P14` / `第12至14页`。
final RegExp _pageRange = RegExp(
  r'[Pp]\s*(\d{1,3})\s*[-–—~～至到]\s*[Pp]?\s*(\d{1,3})',
);

/// 单页：`P12` / `第12页`。
final RegExp _pageSingle = RegExp(r'[Pp]\s*(\d{1,3})|第\s*(\d{1,3})\s*页');

/// 题量：`口算20题` / `20道题`。
///
/// 前面带「第」的不算 —— 「做第12题」是一道题，按 12 题估会得出
/// 一个凭空翻十倍的时间。
final RegExp _questionCount = RegExp(r'(?<!第)(\d{1,3})\s*(?:道)?\s*题');

int _clampMinutes(int minutes) {
  final clamped = minutes.clamp(5, 120);
  // 取 5 的整数倍：这是个可改的输入框，47 这样的数看着像精确计算结果。
  return (clamped / 5).round() * 5;
}

/// 估一条作业大概要多久。**给的是默认值，不是测算结果。**
///
/// 优先用模型给的（它看得见「一张卷子两面」这种量，规则怎么数都数不出来）。
/// 模型没给就按类型 + 正文里的数量词推：
/// 页数每题按 8 分钟，口算每题按 0.5 分钟、其他题按 2 分钟，
/// 两样都没有就退回该类型的默认值。
///
/// 一律夹在 5–120 分钟并取 5 的倍数 —— 这个数会进「预计耗时」输入框，
/// 由学生最终确认；它只要量级对就够了，装作精确反而会被弃用。
int estimateHomeworkMinutes(String title, {int? suggested}) {
  if (suggested != null && suggested > 0) return _clampMinutes(suggested);

  final kind = HomeworkKind.of(title);
  var minutes = kind.defaultMinutes;

  final range = _pageRange.firstMatch(title);
  if (range != null) {
    final from = int.parse(range.group(1)!);
    final to = int.parse(range.group(2)!);
    final pages = (to - from).abs() + 1;
    if (pages > 0) minutes = pages * 8;
  } else if (_pageSingle.hasMatch(title)) {
    minutes = 8;
  } else {
    final questions = _questionCount.firstMatch(title);
    if (questions != null) {
      final count = int.parse(questions.group(1)!);
      if (count > 0) {
        minutes = (count * (kind == HomeworkKind.oral ? 0.5 : 2)).round();
      }
    }
  }
  return _clampMinutes(minutes);
}
