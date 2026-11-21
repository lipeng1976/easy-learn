import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

/// 「本地兜底」标记。
///
/// 只在批改来源是 `local` 时出现。**云端结果不显示任何标记** ——
/// 给正常状态也挂一个徽章，等于让「有标记」变成背景噪音，
/// 学生和家长很快就会不再看它，那时标记就白做了。
///
/// 文案刻意是「离线参考结果」而不是「AI 失败」：降级不是错误，
/// 离线可用、模型故障时仍然给出结果，本来就是这套设计要保住的能力。
class LocalGradingChip extends StatelessWidget {
  const LocalGradingChip({super.key, this.showNote = false});

  /// 是否在标记下面补一句解释。
  ///
  /// 家长端要开：家长是**在没有上下文的情况下**看到这条结果的 ——
  /// 他不知道孩子这边网络怎么样、模型开没开，一个光秃秃的「离线」标签
  /// 只会让他更困惑。
  final bool showNote;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF8A5A00);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF6E5),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.warning.withValues(alpha: 0.45)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 13, color: ink),
              SizedBox(width: 4),
              Text(
                '离线参考结果',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: ink,
                ),
              ),
            ],
          ),
        ),
        if (showNote) ...[
          const SizedBox(height: 6),
          const Text(
            '本次批改由本地内置实现产出，不是模型批改结果，仅可作为参考。',
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: AppColors.textMuted,
            ),
          ),
        ],
      ],
    );
  }
}
