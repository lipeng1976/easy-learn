import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../constants/app_colors.dart';
import '../controllers/data_status_controller.dart';
import '../services/data_staleness_log.dart';

/// 数据层「不新鲜 / 没保存」的横幅（迁移计划 §7 方案 B 的可见性那一半）。
///
/// ## 为什么必须存在
///
/// 方案 B 让断网时仍然读得到数据（来自缓存），消掉了纯在线方案那个致命表现
/// （断网 = 空列表 = 「我昨天的作业全没了」）。但它同时制造了一个更隐蔽的
/// 误解：**用户看到的是一份和实时数据长得一模一样的旧数据**。
///
/// 界面上没有任何东西能把「今早同步的」与「此刻的」区分开 —— 而这正是最难
/// 挽回的一类错：家长看到一个「已完成」而孩子其实刚改成「未交」，
/// 他会基于这个数字做判断，并且**不会再回来核对**。
///
/// ## 两种事件，语气不同
///
/// - [DataStalenessKind.staleRead]：**看到了旧数据**。信息性的，
///   用中性蓝 —— 「显示的是一份完整的、只是稍旧的数据」不是故障。
/// - [DataStalenessKind.writeDropped]：**这次修改没保存**。警示性的，
///   用红色。它比前者严重：用户以为自己做了一件事，而它没有发生。
///
/// 刻意**不做成只有一个文案的通用提示**：这两件事需要的动作完全不同
/// （一个是「将就着看」或「等会儿再刷」，另一个是「立刻重新提交」），
/// 合成一句就得写成「数据可能不是最新的」，而那句话两种情况下都不够用。
class OfflineDataBanner extends StatelessWidget {
  const OfflineDataBanner({super.key, required this.status});

  final DataStatusController status;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final event = status.latest.value;
      // ⚠️ **这里刻意没有任何动画**，这是踩出来的，不是省事。
      //
      // 原先用 `AnimatedSize`：高度从 0 动画长到 60。它在真浏览器走查里
      // 表现为「事件到了、控制器收到了、`Obx` 也用非空事件重建过，界面上
      // 却什么都没有」—— 因为**动画没跑起来时高度就永远停在 0**。
      // 复现条件（widget 测试里钉着）：`TickerMode(enabled: false)`，
      // 此时刚测到的横幅高度正好是 `0.0`。
      //
      // 为什么这一次不能忍：横幅要提示的是「你看到的可能是旧数据」——
      // 一份**安全提示**。它消失的时候不报错、不崩、日志里那条事件还在，
      // 而用户会把旧数据当实时数据用。**可见性一旦挂在动画上，就等于
      // 把「提示还在不在」交给帧调度去决定。**
      //
      // 要动画的地方很多（转场、加载态），但「有没有提示」不属于它们。
      if (event == null) return const SizedBox.shrink();
      return _Chrome(
        event: event,
        totalCount: status.totalCount.value,
        onDismiss: status.dismiss,
      );
    });
  }
}

class _Chrome extends StatelessWidget {
  const _Chrome({
    required this.event,
    required this.totalCount,
    required this.onDismiss,
  });

  final DataStaleness event;
  final int totalCount;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final dropped = event.kind == DataStalenessKind.writeDropped;
    final accent = dropped ? AppColors.danger : AppColors.primary;
    final icon = dropped ? Icons.cloud_off_outlined : Icons.history_outlined;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.38)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: accent),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dropped ? '这次修改没有保存' : '正在显示上次同步的内容',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: dropped ? AppColors.danger : AppColors.primaryDark,
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
                if (dropped) ...[
                  const SizedBox(height: 4),
                  // 给出下一步动作。没有它的话，用户看到「没保存」
                  // 之后能做的只有反复点同一个按钮 —— 而断网时那必然失败。
                  const Text(
                    '请检查网络后重新提交；恢复连接前不会在本地留副本。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // 只显示「最近一次」会让人以为是偶发；连续 12 次和偶尔 1 次
          // 需要的反应完全不同，所以把次数也摆出来。
          if (totalCount > 1)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Text(
                '已 $totalCount 次',
                style: TextStyle(fontSize: 11, color: accent),
              ),
            ),
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 16),
            color: AppColors.textMuted,
            visualDensity: VisualDensity.compact,
            tooltip: '知道了',
          ),
        ],
      ),
    );
  }
}
