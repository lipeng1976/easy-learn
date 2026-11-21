import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../models/homework_model.dart';

/// 作业状态对应的展示色。
///
/// 学生端卡片、家长端列表、家长端详情页共用同一个映射，
/// 避免同一个「待更正」在学生端是红色、在家长端是橙色的认知错位。
Color homeworkStatusColor(HomeworkStatus status) => switch (status) {
  HomeworkStatus.pending => AppColors.warning,
  HomeworkStatus.checking => AppColors.accent,
  HomeworkStatus.needFix => AppColors.danger,
  HomeworkStatus.finished => AppColors.success,
};

class HomeworkStatusChip extends StatelessWidget {
  const HomeworkStatusChip({super.key, required this.status, this.dense = false});

  final HomeworkStatus status;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = homeworkStatusColor(status);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 7 : 9,
        vertical: dense ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: dense ? 11 : 12,
        ),
      ),
    );
  }
}
