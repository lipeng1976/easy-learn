import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../constants/app_colors.dart';
import '../controllers/ai_status_controller.dart';

/// AI 降级提示条。
///
/// 只说一句「本次是离线结果」，不提供「重试」按钮：降级的判定已经内置了
/// 一次重试（见 `RemoteAiDataSource._invoke`），用户再点一次重试大概率
/// 还是同一结果，却会再花一次模型调用的钱。真要重试，重新触发那个动作即可。
///
/// 也刻意**不做成红色警报**。降级不是错误：离线可用、模型故障时仍然给出
/// 结果，本来就是这套设计要保住的能力。它需要的是「别被误会成 AI 输出」，
/// 不是「出事了」。
class AiDegradedBanner extends StatelessWidget {
  const AiDegradedBanner({super.key, required this.status});

  final AiStatusController status;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final event = status.latest.value;
      // 与 `OfflineDataBanner` 同一条教训：**可见性不挂在动画上**。
      // 那里用的 `AnimatedSize` 在动画没跑起来时高度停在 0，横幅会
      // 「在树里但看不见」—— 不报错、日志里还有记录，只有用户被蒙在鼓里。
      // 这条横幅要说的同样是「你手里的结果不是当次的」，属于同一类提示。
      if (event == null) return const SizedBox.shrink();
      return Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF6E5),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.warning.withValues(alpha: 0.45)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.cloud_off_outlined,
                        size: 18,
                        color: Color(0xFF8A5A00),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '本次为离线参考结果',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF8A5A00),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            event.reason,
                            style: const TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 只显示「最近一次」会让人以为偶发；连降 5 次和偶尔 1 次
                    // 需要的反应完全不同，所以把次数也摆出来。
                    if (status.totalCount.value > 1)
                      Padding(
                        padding: const EdgeInsets.only(left: 8, top: 2),
                        child: Text(
                          '已 ${status.totalCount.value} 次',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF8A5A00),
                          ),
                        ),
                      ),
                    IconButton(
                      onPressed: status.dismiss,
                      icon: const Icon(Icons.close, size: 16),
                      color: AppColors.textMuted,
                      visualDensity: VisualDensity.compact,
                      tooltip: '知道了',
                    ),
                  ],
                ),
      );
    });
  }
}
