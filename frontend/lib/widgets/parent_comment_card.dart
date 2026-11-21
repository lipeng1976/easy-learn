import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../models/daily_comment_model.dart';
import '../utils/date_utils.dart';

/// 学生端首页的「家长点评」卡片。
///
/// ## 为什么标题右边必须写日期（2026-10-27）
///
/// 用户报：「今天的点评，任意一天看到的都变成了几天前那条点评的信息」。
/// 卡片原先只有「家长点评」四个字 + 评分 + 内容，**从不标日期** ——
/// 于是任何一天打开，看到的都是"最近那条"，读书的人自然当成今天的。
/// 旧点评本身不该藏（那是信息），错的是让它**冒充**今天的。
///
/// 现在：今天写的显示「今天 19:43」，隔天的显示「2026-10-26 21:33」。
/// 判据在 `test/parent_comment_card_test.dart`：同一条旧点评渲染出来，
/// 必须带完整日期，且**不能**出现「今天」二字。
class ParentCommentCard extends StatelessWidget {
  const ParentCommentCard({
    super.key,
    required this.comment,
    required this.now,
  });

  final DailyCommentModel comment;

  /// 「今天」的参照时刻。**由调用方给**，不在 build 里读 `DateTime.now()`：
  /// 否则测试只能靠真实时钟，跨零点时会随机红。
  final DateTime now;

  /// 标题右边那行时间：今天的写「今天 19:43」，其余写「2026-10-26 21:33」。
  ///
  /// 只按**本地日**判：`createdAt` 到这里已经是本地时间
  /// （`data_row_values.timeOf` 里做的 `toLocal()`），这里别再减时区。
  static String stampFor(DateTime createdAt, DateTime now) {
    final hhmm = '${createdAt.hour.toString().padLeft(2, '0')}:'
        '${createdAt.minute.toString().padLeft(2, '0')}';
    final sameDay = createdAt.year == now.year &&
        createdAt.month == now.month &&
        createdAt.day == now.day;
    if (sameDay) return '今天 $hhmm';
    return '${DateUtilsX.formatDate(createdAt)} $hhmm';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '家长点评',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text(
                stampFor(comment.createdAt, now),
                style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            comment.rating,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(comment.content),
        ],
      ),
    );
  }
}
