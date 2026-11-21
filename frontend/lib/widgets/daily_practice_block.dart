import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../constants/app_colors.dart';
import '../constants/subject_colors.dart';
import '../controllers/checkin_controller.dart';
import '../controllers/checkin_entry_state.dart';
import '../controllers/drill_controller.dart';
import '../controllers/word_drill_controller.dart';
import '../models/checkin_models.dart';
import '../services/database_service.dart';
import '../utils/checkin_label.dart';

/// 学生端计划页的「今日打卡」**一个大方块**，里面逐个列出今天的几件小练。
///
/// ## 为什么合成一块，而不是三张并列卡
///
/// 这三件（每日概念打卡 / 今日概念训练 / 英语单词打卡）是同一类东西：
/// **每次只花几分钟、做完就没了、一天一轮**。原来各占一张卡，每张都带
/// 一句说明和一个大按钮，孩子要读三遍才知道「今天有哪几件小事」；
/// 而且「刚出的那份题」藏在打卡页里，得先点进去才看得见。
/// 现在一张卡列出所有训练项，**一行一件事**，右侧就是状态；刚出的题
/// 直接挂在「每日概念打卡」下面，点一下就能做。
///
/// ## 英文阅读不在这里
///
/// 阅读是**一本书的长期任务**（没读就顺延，一直挂到整本读完），
/// 和「今天做完就没了」的小练不是同一个时间尺度。混进来会让
/// 「今天还剩几件事」这个数字一半按天算、一半按书算。
///
/// ## 本地模式下只剩两行
///
/// 概念打卡的题目快照必须存在服务端（爸妈是两个账号，本地库各存一份永远
/// 对不上），所以本地模式**不画那一行** —— 一个点了才说「需要联网」的
/// 入口，比没有入口更糟。概念训练与单词打卡全在本机，照常可用。
class DailyPracticeBlock extends StatefulWidget {
  const DailyPracticeBlock({
    super.key,
    this.entry,
    this.drillController,
    this.wordController,
    this.isCloud,
  });

  /// 以下三个只为测试注入；线上各自从 Get 容器取（没有就建一个）。
  final CheckinEntryState? entry;
  final DrillController? drillController;
  final WordDrillController? wordController;

  /// 只为测试注入 —— 假库里 `DatabaseService.isCloud` 恒 false，
  /// 「概念打卡那一行在不在」就没法验了。线上不传，走真实模式。
  final bool? isCloud;

  @override
  State<DailyPracticeBlock> createState() => _DailyPracticeBlockState();
}

class _DailyPracticeBlockState extends State<DailyPracticeBlock> {
  late final CheckinEntryState entry;
  late final DrillController drill;
  late final WordDrillController word;

  /// 刚出的题最多逐条列几份。再多就折成「还有 N 份 ›」——
  /// 一次性列出十几份会把下面「学习计划」整区推到屏幕外，
  /// 而这孩子真正要做的往往就是最上面那一两份。
  static const int _maxQuizRows = 3;

  @override
  void initState() {
    super.initState();
    entry = widget.entry ??
        (Get.isRegistered<CheckinEntryState>()
            ? Get.find<CheckinEntryState>()
            : Get.put(CheckinEntryState()));
    drill = widget.drillController ??
        (Get.isRegistered<DrillController>()
            ? Get.find<DrillController>()
            : Get.put(DrillController()));
    word = widget.wordController ??
        (Get.isRegistered<WordDrillController>()
            ? Get.find<WordDrillController>()
            : Get.put(WordDrillController()));

    // 各自拉一次初始值。放 initState 而不是 build：build 会被 Obx 反复
    // 重建，每次重建都读一遍盘/发一次请求。三者对「已经在做/已经在答」
    // 都有守卫，重复调用安全。
    entry.load();
    drill.loadToday();
    word.loadToday();
  }

  bool get _cloud => widget.isCloud ?? DatabaseService.isCloud;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题留在块里（而不是外面的分区小标题）：这张卡本身就是一区，
          // 再套一层「今日打卡」小标题会变成两层标题夹一行字。
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Row(
              children: [
                Text(
                  '今日打卡',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                ),
                Spacer(),
                Text(
                  '每天做一遍 · 每次几分钟',
                  style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          // ⚠️ 只用一个 Obx 包住三行：三个控制器各自是 Rx，拆多个 Obx 反而
          // 会让「点完回来」时某一行不刷新。
          Obx(() {
            final rows = <Widget>[];
            if (_cloud) {
              rows.addAll(_checkinRows());
            }
            rows.add(_drillRow());
            rows.add(_wordRow());
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, indent: 60, endIndent: 16),
                  rows[i],
                ],
                const SizedBox(height: 4),
              ],
            );
          }),
        ],
      ),
    );
  }

  // ===== ① 每日概念打卡（家长出的题） =====

  List<Widget> _checkinRows() {
    // ⚠️ 必须无条件订阅 `progressByStudent.value` 与 `pendingByStudent.value`：
    // 未登录 / 没结伴孩子时 `targetStudentId()` 是 null，三元短路会让 Obx
    // 一个 observable 都没追踪到，直接抛「no observable」。
    // ignore: invalid_use_of_protected_member —— RxMap.value 在 Obx 闭包里读是 GetX 标准写法。
    final progress = entry.progressByStudent.value;
    // ignore: invalid_use_of_protected_member
    final pendingQuizzes = entry.pendingByStudent.value;
    final id = CheckinController.targetStudentId();
    final day = id == null ? null : progress[id];
    final quizzes = id == null
        ? const <CheckinQuiz>[]
        : (pendingQuizzes[id] ?? const <CheckinQuiz>[]);

    final hasPending = day?.hasPending ?? false;
    final empty = day?.empty ?? true;

    final String status;
    if (hasPending) {
      status = '待完成 ${day!.pending} 份';
    } else if (empty) {
      status = '还没有题';
    } else {
      status = '已全部完成';
    }

    // 状态之外再给一句「接下来做什么」：只有份数的话，孩子知道有几份
    // 却不知道那几份是不是下面列着的这些。
    final subtitle = hasPending
        ? (quizzes.isEmpty ? '点开看看今天要做的题' : '刚出的题在下面，点一下就能做')
        : (empty ? '等家长出题，也可以自己发一组' : '今天做完了，明天再来');

    return [
      _PracticeRow(
        icon: Icons.fact_check_outlined,
        color: hasPending ? AppColors.success : AppColors.primary,
        title: '每日概念打卡',
        subtitle: subtitle,
        status: status,
        statusColor: hasPending ? AppColors.success : AppColors.textMuted,
        onTap: () => Get.toNamed('/checkin'),
      ),
      // 刚出的题：一份一行，按出题顺序（服务端就是正序：先出的先做）。
      for (final quiz in quizzes.take(_maxQuizRows))
        _QuizRow(quiz: quiz, onTap: () => Get.toNamed('/checkin')),
      if (quizzes.length > _maxQuizRows)
        Padding(
          padding: const EdgeInsets.fromLTRB(60, 0, 16, 8),
          child: InkWell(
            onTap: () => Get.toNamed('/checkin'),
            child: Text(
              '还有 ${quizzes.length - _maxQuizRows} 份 ›',
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
              ),
            ),
          ),
        ),
    ];
  }

  // ===== ② 今日概念训练（本地题库） =====

  Widget _drillRow() {
    final today = drill.today.value;
    final total = today?.questions.length ?? 0;
    final done = drill.answeredCount;

    final String status;
    final String subtitle;
    if (today == null) {
      status = '每天 6 题';
      subtitle = '把文字描述翻译成数学式子';
    } else if (drill.submitted.value) {
      status = '已完成';
      subtitle = '答对 ${drill.correctCount}/$total · 点进去看每题思路';
    } else if (done > 0) {
      status = '已答 $done/$total';
      subtitle = '接着上次的继续，今天的题不会变';
    } else {
      status = '$total 题';
      subtitle = '先把文字读懂，再选式子 —— 不会算也能选对';
    }

    return _PracticeRow(
      icon: Icons.translate,
      color: const Color(0xFF7C5CFF),
      title: '今日概念训练',
      subtitle: subtitle,
      status: status,
      statusColor: drill.submitted.value ? AppColors.success : AppColors.textMuted,
      onTap: () => Get.toNamed('/daily-drill'),
    );
  }

  // ===== ③ 英语单词打卡（教材词表 · 本机出题） =====

  Widget _wordRow() {
    final done = word.isDoneToday;
    final count = word.questions.length;

    final String status;
    final String subtitle;
    if (done) {
      status = '已完成';
      subtitle = '答对 ${word.correctCount}/$count · 连续 ${word.streak.value} 天';
    } else if (count > 0) {
      status = '$count 题';
      subtitle = '英→中 / 中→英，各一半';
    } else {
      status = '待配置';
      subtitle = word.hint.value ?? '请家长先在计划页配置教材词表';
    }

    return _PracticeRow(
      icon: done ? Icons.check_circle : Icons.abc,
      color: subjectColor('英语'),
      title: '英语单词打卡',
      subtitle: subtitle,
      status: status,
      statusColor: done ? AppColors.success : AppColors.textMuted,
      onTap: () => Get.toNamed('/word-drill'),
    );
  }
}

/// 大字方块里的一行：图标 + 标题 + 一句说明 + 右侧状态。
///
/// 没有整块的大按钮：这一区是「清单」，点行本身就是动作。三行各挂一个
/// FilledButton 的话，一块卡里会出现三个同等视觉权重的按钮 —— 孩子反而
/// 不知道先点哪个。
class _PracticeRow extends StatelessWidget {
  const _PracticeRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.statusColor,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String status;
  final Color statusColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 19, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 窄屏（360dp）下状态文字也要能让位给标题：Flexible + 省略号，
            // 宁可少两个字，不要溢出红条。
            Flexible(
              child: Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: statusColor,
                ),
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}

/// 「刚出的那份题」：**缩进一行**，视觉上从属于上面的「每日概念打卡」。
///
/// 科目色和打卡页的方块是同一套（`subjectColor`）—— 同一套题在两个页面
/// 必须是同一个颜色，否则孩子会以为那是另一份。
class _QuizRow extends StatelessWidget {
  const _QuizRow({required this.quiz, required this.onTap});

  final CheckinQuiz quiz;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subject = checkinSubjectLabel(quiz);
    final color = subjectColor(subject);
    final meta = [
      '共 ${quiz.total} 题',
      if (quiz.difficulty.isNotEmpty) quiz.difficulty,
      checkinShortDate(quiz.quizDate),
    ].join(' · ');

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(34, 0, 12, 0),
        child: Row(
          children: [
            // 一小段竖线：把这几行挂在上面那一行下面，而不是变成新的平级项。
            Container(
              width: 2,
              height: 26,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            const SizedBox(width: 10),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(
              subject,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
            ),
            Text(
              '去做',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            const Icon(Icons.chevron_right, size: 16, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}
