import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/student_controller.dart';
import '../../models/focus_session_model.dart';
import '../../services/focus_timer_service.dart';
import '../student/focus_timer_page.dart';

/// 打开专注计时的**唯一入口**。
///
/// 作业页和计划页都要开这一屏，而「同时只允许一段计时」这条规则
/// 只有一份才成立：两处各写一遍的话，其中一处迟早会忘了先结束上一段，
/// 表现是「数学作业记的时间跑到了语文作业上」—— 而界面上两个卡片
/// 都在正常显示各自的用时。
abstract final class FocusTimerLauncher {
  static Future<void> open(
    BuildContext context,
    StudentController controller,
    FocusTarget target,
  ) async {
    final timer = FocusTimerService.instance;

    if (timer.hasSession && !timer.isActiveFor(target.id)) {
      final current = timer.target!;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('还有一段计时没结束'),
          content: Text(
            '《${current.title}》的计时还没结束。要先结束它、再开始这一段吗？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('先不开始'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('结束并开始'),
            ),
          ],
        ),
      );
      if (proceed != true) return;

      timer.pause();
      final saved = await controller.saveFocusProgress(
        target: current,
        sessionId: timer.sessionId,
        sessionSeconds: timer.sessionSeconds,
        totalSeconds: timer.totalSeconds,
        startedAt: timer.sessionStartedAt,
      );
      if (!saved.ok) {
        // 保存不了就不清会话：那段时间还在内存里，学生回到卡片还能再存。
        // 清掉才是真的把它弄丢了。
        Get.snackbar('还没结束上一段计时', saved.message);
        return;
      }
      timer.reset();
    }

    if (!context.mounted) return;
    final message = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => FocusTimerPage(target: target, controller: controller),
      ),
    );
    if (message != null && context.mounted) {
      // 计时页保存失败时把原因带回来（它已经放人走了）。会话仍保留着，
      // 入口会显示「继续」。
      Get.snackbar('用时没能保存', message);
    }
  }
}
