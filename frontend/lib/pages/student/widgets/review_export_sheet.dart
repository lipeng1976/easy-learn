import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../constants/app_colors.dart';
import '../../../controllers/review_controller.dart';
import '../../../services/review_exporter.dart';
import '../../../utils/pop_route.dart';

/// 打开「取走这份卷子」面板：打印 / 下载 / 转发。
///
/// 为什么要有这个面板，而不是在页面上并排放三个按钮：
/// 三个动作**互斥**（学生每次只会选一种），并排放会在底部栏挤掉「回传批改」
/// 这个真正的主动作 —— 而回传才是闭环往前走的那一步。
///
/// 面板里带「含参考答案」开关：以前它被拆成两个按钮（导出试卷 / 试卷 + 答案），
/// 等于用按钮数量表达一个布尔值。收进面板后，三种去向都能带答案或不带。
Future<void> openReviewExportSheet({
  required BuildContext context,
  required ReviewController controller,
  required String paperId,
}) async {
  final choice = await showModalBottomSheet<_ExportChoice>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => const _ReviewExportSheet(),
  );
  if (choice == null) return;

  final result = await controller.exportPaper(
    paperId,
    target: choice.target,
    includeAnswerPage: choice.withAnswers,
  );

  // 标题按**这次的动作**说，不统一叫「已导出」：
  // 「已导出」这句正是之前的问题 —— 三种去向都这么说，而学生手里其实什么都没有。
  final title = switch (choice.target) {
    ExportTarget.print => result.ok ? '已交给打印' : '未打印',
    ExportTarget.download => result.ok ? '已保存' : '未保存',
    ExportTarget.share =>
      result.ok ? (result.copiedToClipboard ? '已复制' : '已发送') : '未发送',
  };
  Get.snackbar(title, result.message, duration: const Duration(seconds: 5));
}

class _ExportChoice {
  const _ExportChoice({required this.target, required this.withAnswers});

  final ExportTarget target;
  final bool withAnswers;
}

class _ReviewExportSheet extends StatefulWidget {
  const _ReviewExportSheet();

  @override
  State<_ReviewExportSheet> createState() => _ReviewExportSheetState();
}

class _ReviewExportSheetState extends State<_ReviewExportSheet> {
  /// 默认带答案：订正场景下家长多半要对着答案看。
  /// 想让孩子先独立做时，把这个开关关掉即可。
  bool _withAnswers = true;

  void _choose(ExportTarget target) {
    Navigator.pop(context, _ExportChoice(target: target, withAnswers: _withAnswers));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        // 必须可滚动：底部面板的高度上限由屏高决定，而这里有三条去向 + 开关 +
        // 说明。小屏（或横屏）上放不下时，被裁掉的正好是最下面那条「转发到微信」
        // —— 那等于这个改动白做。
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '取走这份卷子',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    onPressed: () => popRoute(context),
                    icon: const Icon(Icons.close),
                    tooltip: '关闭',
                  ),
                ],
              ),
              const SizedBox(height: 4),
              _AnswerToggle(
                value: _withAnswers,
                onChanged: (value) => setState(() => _withAnswers = value),
              ),
              const SizedBox(height: 12),
              _ExportOption(
                icon: Icons.print_outlined,
                title: '打印 / 另存 PDF',
                subtitle: '用系统打印服务选打印机；没有打印机时可以在里面另存为 PDF',
                onTap: () => _choose(ExportTarget.print),
              ),
              _ExportOption(
                icon: Icons.download_outlined,
                title: '保存 PDF 文件',
                subtitle: '弹系统「另存为」，存到哪个文件夹由你选',
                onTap: () => _choose(ExportTarget.download),
              ),
              _ExportOption(
                icon: Icons.share_outlined,
                title: '转发到微信',
                subtitle: '调起系统分享面板，把 PDF 直接发给老师或家长',
                onTap: () => _choose(ExportTarget.share),
              ),
              const SizedBox(height: 4),
              const Text(
                '三种方式拿到的都是同一份 PDF：可以直接打印，也可以在手机上打开看。',
                style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AnswerToggle extends StatelessWidget {
  const _AnswerToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '附带参考答案',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 2),
                Text(
                  '关掉它就只印题目，适合让孩子先独立完成',
                  style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _ExportOption extends StatelessWidget {
  const _ExportOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 20, color: AppColors.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textMuted,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: AppColors.textMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
