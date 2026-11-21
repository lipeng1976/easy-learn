import 'package:flutter/material.dart';

import '../../../constants/app_colors.dart';
import '../../../models/review_model.dart';

/// 复习模块的**状态徽章与配色**集中在这里。
///
/// 抽出来的直接原因很具体：`PaperStatus` 的配色原先在复习页资料卡片和资料详情页
/// 各 switch 了一遍，`ReviewState` 在待复习卡、进行中卡、已掌握卡里各写了一次。
/// 改一个「已批改」的颜色要改三处，漏掉哪一处就会出现同一种状态两个颜色 ——
/// 这种不一致在界面上看起来像 bug，查起来却要翻遍全项目。
///
/// 更关键的是「渠道」：学生做对的这件事，究竟是**AI 按参考答案判定**的，
/// 还是**自己点了个「我写对了」**，两者的可信度完全不同。家长端要能一眼看出来，
/// 就不能靠各页面自己在文案里拼字符串，必须有统一的视觉标识。

/// 卷状态配色。
Color paperStatusColor(PaperStatus status) => switch (status) {
  PaperStatus.draft => AppColors.textMuted,
  PaperStatus.printed => AppColors.primary,
  PaperStatus.submitted => AppColors.accent,
  PaperStatus.graded => AppColors.success,
  PaperStatus.closed => AppColors.textMuted,
};

/// 错题状态配色。
Color mistakeStateColor(ReviewState state) => switch (state) {
  ReviewState.pending => AppColors.warning,
  ReviewState.reviewing => AppColors.primary,
  ReviewState.verifying => AppColors.accent,
  ReviewState.mastered => AppColors.success,
};

/// 作答渠道配色。
///
/// 「自评」刻意用中性灰而不是绿色：它不构成可信的掌握证据，
/// 给绿色会让人误以为和 AI 判定等价。
Color attemptChannelColor(AttemptChannel channel) => switch (channel) {
  AttemptChannel.paper => AppColors.success,
  AttemptChannel.paperSelf => AppColors.textMuted,
  AttemptChannel.practice => AppColors.primary,
};

/// 作答渠道图标。
IconData attemptChannelIcon(AttemptChannel channel) => switch (channel) {
  AttemptChannel.paper => Icons.fact_check_outlined,
  AttemptChannel.paperSelf => Icons.person_outline,
  AttemptChannel.practice => Icons.auto_awesome,
};

/// 渠道是否属于「有证据」的判定。
///
/// 自评不算 —— 这个判断被时间线、报告、家长端三处用到，
/// 写成一个函数好过在三处各写一遍 `channel != AttemptChannel.paperSelf`。
bool isEvidenceChannel(AttemptChannel channel) =>
    channel != AttemptChannel.paperSelf;

/// 学习表现配色：及格线以下给警示色，避免「60% 也一片绿」。
Color performanceColor(double rate) {
  if (rate >= 0.8) return AppColors.success;
  if (rate >= 0.5) return AppColors.warning;
  return AppColors.danger;
}

/// 小圆角标签（原 `_Tag`）。
class ReviewTag extends StatelessWidget {
  const ReviewTag({
    super.key,
    required this.text,
    this.color = AppColors.textMuted,
    this.icon,
  });

  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// 资料状态徽章。
class PaperStatusBadge extends StatelessWidget {
  const PaperStatusBadge({super.key, required this.status});

  final PaperStatus status;

  @override
  Widget build(BuildContext context) =>
      ReviewTag(text: status.label, color: paperStatusColor(status));
}

/// 错题状态徽章。
class MistakeStateBadge extends StatelessWidget {
  const MistakeStateBadge({super.key, required this.state});

  final ReviewState state;

  @override
  Widget build(BuildContext context) =>
      ReviewTag(text: state.label, color: mistakeStateColor(state));
}

/// 作答渠道徽章——「这个对是判出来的还是自己说的」的唯一视觉答案。
class ReviewChannelBadge extends StatelessWidget {
  const ReviewChannelBadge({
    super.key,
    required this.channel,
    this.compact = false,
  });

  final AttemptChannel channel;

  /// 紧凑模式只显示短标签（列表里用）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final text = compact ? _shortLabel(channel) : channel.label;
    return ReviewTag(
      text: text,
      color: attemptChannelColor(channel),
      icon: attemptChannelIcon(channel),
    );
  }

  static String _shortLabel(AttemptChannel channel) => switch (channel) {
    AttemptChannel.paper => 'AI 判定',
    AttemptChannel.paperSelf => '自评',
    AttemptChannel.practice => '举一反三',
  };
}

/// 结果徽章：通过 / 未通过。
class AttemptResultBadge extends StatelessWidget {
  const AttemptResultBadge({super.key, required this.correct});

  final bool correct;

  @override
  Widget build(BuildContext context) => ReviewTag(
    text: correct ? '通过' : '未通过',
    color: correct ? AppColors.success : AppColors.danger,
    icon: correct ? Icons.check_circle_outline : Icons.cancel_outlined,
  );
}
