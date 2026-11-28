import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../models/point_model.dart';
import '../utils/date_utils.dart' as date_utils;

/// 积分相关的小组件。学生端和家长端共用一份 ——
/// 两边各写一套的话，「+5 是绿色还是红色」这种约定迟早会分岔。

/// 动作对应的图标。
///
/// 账本里存的是字符串 code，认不出来就回一个中性图标：老记录里的陌生动作
/// 要能照常显示，不能让整个明细页崩掉。
IconData pointActionIcon(String code) {
  switch (pointActionFromCode(code)) {
    case PointAction.homeworkGraded:
    case PointAction.homeworkNoGrading:
      return Icons.assignment_turned_in_outlined;
    case PointAction.homeworkAllCorrect:
      return Icons.verified_outlined;
    case PointAction.workoutCheckin:
      return Icons.directions_run;
    case PointAction.planCheckin:
      return Icons.event_available_outlined;
    case PointAction.checkinCompleted:
      return Icons.checklist_rtl;
    case PointAction.checkinAllCorrect:
      return Icons.workspace_premium_outlined;
    case PointAction.reviewRound:
      return Icons.menu_book_outlined;
    case PointAction.mistakeGraduated:
      return Icons.school_outlined;
    case PointAction.parentReward:
      return Icons.card_giftcard;
    case PointAction.wishRedeem:
      return Icons.redeem;
    case PointAction.behaviorDeduction:
      return Icons.report_problem_outlined;
    case null:
      return Icons.stars_outlined;
  }
}

/// 余额卡片。
class PointBalanceCard extends StatelessWidget {
  const PointBalanceCard({
    super.key,
    required this.account,
    this.title = '我的积分',
    this.subtitle,
    this.onOpenLedger,
    this.compact = false,
  });

  final PointAccount account;
  final String title;
  final String? subtitle;
  final VoidCallback? onOpenLedger;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? 14 : 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF4D7CFE), Color(0xFF36CFC9)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.stars, color: Colors.white, size: 18),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (onOpenLedger != null)
                TextButton(
                  onPressed: onOpenLedger,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Row(
                    children: [
                      Text('明细', style: TextStyle(color: Colors.white)),
                      Icon(Icons.chevron_right, color: Colors.white, size: 18),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '${account.balance}',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: compact ? 28 : 34,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 4),
              const Text('分', style: TextStyle(color: Colors.white70)),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              _Stat(label: '累计获得', value: account.totalEarned),
              const SizedBox(width: 18),
              _Stat(label: '累计兑换', value: account.totalSpent),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          '$label ',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        Text(
          '$value',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// 一条流水。
class PointLedgerTile extends StatelessWidget {
  const PointLedgerTile({super.key, required this.entry});

  final PointLedgerEntry entry;

  @override
  Widget build(BuildContext context) {
    // 被撤销的原记录连同它的冲正记录都会留在账上。两条都变灰 ——
    // 孩子看到「我确实做过，后来撤销了」才是完整的交代。
    final voided = entry.isReversed || entry.isReversal;
    final positive = entry.points > 0;
    final color = voided
        ? AppColors.textMuted
        : (positive ? AppColors.success : AppColors.danger);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            pointActionIcon(entry.action),
            size: 20,
            color: voided ? AppColors.textMuted : AppColors.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.reason.isEmpty
                            ? pointActionLabel(entry.action)
                            : entry.reason,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          decoration: voided ? TextDecoration.lineThrough : null,
                          color: voided ? AppColors.textMuted : AppColors.text,
                        ),
                      ),
                    ),
                    if (entry.isReversed) ...[
                      const SizedBox(width: 6),
                      const _Tag(text: '已撤销'),
                    ],
                    if (entry.isReversal) ...[
                      const SizedBox(width: 6),
                      const _Tag(text: '冲正'),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  date_utils.DateUtilsX.formatDateTime(entry.createdAt),
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '${positive ? '+' : ''}${entry.points}',
            style: TextStyle(
              color: color,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.textMuted.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.textMuted,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 空状态。
class PointEmptyHint extends StatelessWidget {
  const PointEmptyHint({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 28),
      alignment: Alignment.center,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
      ),
    );
  }
}
