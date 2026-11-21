import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/parent_controller.dart';
import '../parent/widgets/child_selector.dart';

class DailyCommentPage extends StatefulWidget {
  const DailyCommentPage({super.key});

  @override
  State<DailyCommentPage> createState() => _DailyCommentPageState();
}

class _DailyCommentPageState extends State<DailyCommentPage> {
  final ParentController controller = Get.find<ParentController>();
  final _ratingController = TextEditingController(text: '非常优秀');
  final _contentController = TextEditingController(
    text: '今天专注度不错，作业完成质量也稳定，继续保持。',
  );

  /// 正在发布 —— 防连点。
  ///
  /// 存一条点评要一次网络往返。这期间按钮仍可点的话，家长手快会发出
  /// **两条一模一样的点评**（服务端每次都生成新 id，不会去重），
  /// 学生端就会连看到两遍。
  bool _publishing = false;

  @override
  void dispose() {
    _ratingController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('每日点评')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Obx(() {
              if (controller.boundStudents.length > 1) {
                return ChildSelectorCard(
                  students: controller.boundStudents.toList(),
                  selectedId: controller.selectedStudentId.value,
                  onSelect: (id) => controller.selectedStudentId.value = id,
                );
              }
              final childName = controller.boundStudents.isEmpty
                  ? ''
                  : controller.boundStudents
                            .firstWhereOrNull(
                              (child) =>
                                  child.id ==
                                  controller.selectedStudentId.value,
                            )
                            ?.name ??
                        '';
              if (childName.isEmpty) return const SizedBox.shrink();
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.face_retouching_natural,
                      size: 18,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '点评对象：$childName',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
              );
            }),
            const Text(
              '快捷评级',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: ['非常优秀', '很好', '一般', '待改进']
                  .map(
                    (value) => ChoiceChip(
                      label: Text(value),
                      selected: _ratingController.text == value,
                      onSelected: (_) {
                        setState(() => _ratingController.text = value);
                      },
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _contentController,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: '点评内容',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                // 必须 await：存不上就**不许**说「已保存」并关页 ——
                // 那正是「今天的点评，学生端看到的还是几天前那条」的成因。
                onPressed: _publishing
                    ? null
                    : () async {
                        final rating = _ratingController.text.trim();
                        final content = _contentController.text.trim();
                        if (rating.isEmpty || content.isEmpty) {
                          Get.snackbar('提示', '评级和点评内容都不能为空');
                          return;
                        }
                        setState(() => _publishing = true);
                        // 先把 Navigator 取出来：等完网络再 `Navigator.of(context)`
                        // 会踩 use_build_context_synchronously（页面可能已经不在）。
                        final navigator = Navigator.of(context);
                        final ok = await controller.publishDailyComment(
                          rating,
                          content,
                        );
                        if (!mounted) return;
                        setState(() => _publishing = false);
                        if (!ok) {
                          // 不 pop：留着这一页和已经写好的文字，
                          // 家长改个网络再点一次就行，不用重写一遍。
                          Get.snackbar(
                            '点评没保存上',
                            '这条点评没有存进服务端（学生端看不到）。检查网络后重试。',
                          );
                          return;
                        }
                        Get.snackbar('点评', '已保存，学生端可以查看');
                        navigator.pop();
                      },
                child: Text(_publishing ? '保存中…' : '发布点评'),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              '最近点评',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Obx(() {
                if (controller.visibleDailyComments.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Center(child: Text('暂无点评记录')),
                  );
                }

                return ListView.separated(
                  itemCount: controller.visibleDailyComments.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final item = controller.visibleDailyComments[index];
                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.rating,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(item.content),
                          const SizedBox(height: 8),
                          Text(
                            '日期：${item.createdAt.toLocal().toString().substring(0, 16)}',
                            style: const TextStyle(color: AppColors.textMuted),
                          ),
                        ],
                      ),
                    );
                  },
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}
