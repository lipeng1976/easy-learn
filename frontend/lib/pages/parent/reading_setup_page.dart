import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/reading_controller.dart';
import '../../models/reading_models.dart';

/// 家长的阅读任务页：从 ima 导入书 → 布置 → 看进度。
///
/// ## 一页放三块，不拆成三个页面
///
/// 「导入一本新书 → 立刻布置 → 孩子那边出现」是一条连续动作。拆成
/// 「书库页 / 布置页 / 任务页」之后，家长每走一步都要返回一次，
/// 而且导入成功后他不会知道下一步该去哪个页面。三块竖着排，
/// 从上到下就是他要走的顺序。
///
/// ## 「导入」与「布置」是两件事
///
/// 导入 = 把 md 切成一课一课存进库（慢，一次几秒）。
/// 布置 = 给这个孩子开一份任务（快）。
/// 合成一个按钮的话，家长想重读一本书时会被迫重新导入，而导入是幂等的 ——
/// 他看到的只是「转了几秒什么也没发生」。
class ReadingSetupPage extends StatefulWidget {
  const ReadingSetupPage({super.key});

  @override
  State<ReadingSetupPage> createState() => _ReadingSetupPageState();
}

class _ReadingSetupPageState extends State<ReadingSetupPage> {
  late final ReadingController controller;

  @override
  void initState() {
    super.initState();
    controller = Get.isRegistered<ReadingController>()
        ? Get.find<ReadingController>()
        : Get.put(ReadingController());
    controller.load();
    controller.loadLibrary();
  }

  Future<void> _import(ReadingAvailableBook book) async {
    final result = await controller.importBook(book: book);
    if (!mounted) return;
    if (result == null) {
      // 要有反馈，但不变成页面顶部的红色横幅 —— 可选功能失败不是整页故障。
      Get.snackbar('没能导入', controller.availableHint.value ?? '请稍后重试');
      return;
    }

    // 导入成功后**再问一次知识库**（不等它、不挡弹窗）。
    //
    // 为什么不是就地更新一条就够：家长常常是「先导一本试试，再往回传第二本」，
    // 而 `available` 只在进页面时读过一次。不重拉的话，第二本要退出页面
    // 再进来才会出现 —— 他的判断会是「这个功能只能导第一本」。
    unawaited(controller.loadLibrary());

    final skipped = result.skipped;
    if (skipped.isNotEmpty) {
      // 解析不出正文的课**如实说**。静默忽略的话，家长会以为 96 课都在，
      // 而孩子读到某处会突然没有内容 —— 那时没人想得起是导入时的事。
      Get.snackbar(
        '导入完成，但有 ${skipped.length} 课没读出来',
        '第 ${skipped.take(8).join('、')}${skipped.length > 8 ? ' 等' : ''} 课没有正文，'
        '其余 ${result.book.lessonCount} 课正常。',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 5),
      );
      return;
    }
    Get.snackbar(
      result.imported ? '导入成功' : '这本书已经在书库里了',
      '《${result.book.title}》共 ${result.book.lessonCount} 篇。',
      snackPosition: SnackPosition.BOTTOM,
    );
  }

  Future<void> _createTask(ReadingBook book) async {
    final result = await controller.createTask(book: book);
    if (!mounted || result == null) return;
    Get.snackbar(
      result.created ? '布置好了' : '这本书已经在读了',
      result.created
          ? '《${book.title}》共 ${result.task.totalLessons} 篇，孩子每次读一篇打卡。'
          : '进度 ${result.task.doneLessons}/${result.task.totalLessons} 篇，接着读就行。',
      snackPosition: SnackPosition.BOTTOM,
    );
  }

  Future<void> _cancel(ReadingTask task) async {
    final ok = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('取消这份阅读任务？'),
        content: Text(
          '《${task.bookTitle}》的进度会停止，已读的 ${task.doneLessons} 篇不会丢。'
          '之后可以重新布置同一本书，进度接着算。',
        ),
        actions: [
          TextButton(onPressed: () => Get.back(result: false), child: const Text('再想想')),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: const Text('取消任务', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final done = await controller.cancelTask(task);
    if (!mounted) return;
    Get.snackbar(
      done ? '已取消' : '取消失败',
      done ? '孩子那边不会再显示这份任务。' : (controller.error.value ?? '请稍后重试'),
      snackPosition: SnackPosition.BOTTOM,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('英文阅读')),
      body: Obx(() {
        final error = controller.error.value;
        return RefreshIndicator(
          onRefresh: () async {
            await controller.load();
            await controller.loadLibrary();
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              if (error != null && error.isNotEmpty) ...[
                _ErrorBanner(
                  key: const Key('library_error_banner'),
                  message: error,
                ),
                const SizedBox(height: 12),
              ],
              _SectionTitle(
                title: '进行中的任务',
                subtitle: '一本书一份任务，读到最后一篇自动结束。',
              ),
              const SizedBox(height: 8),
              ..._buildTasks(),
              const SizedBox(height: 20),
              _SectionTitle(
                title: '我的书库',
                subtitle: '已经导入 App 的书。选一本布置给孩子。',
              ),
              const SizedBox(height: 8),
              ..._buildBooks(),
              // 没开通 ima 时整块不出现 —— 功能可以没有，但不能报错。
              // `null`（还没问到 / 这次没读到）时保留区块和刷新按钮，
              // 让家长能重试；只有明确的 connected:false 才隐藏。
              if (controller.imaBooksAvailable.value != false) ...[
                const SizedBox(height: 20),
                _SectionTitle(
                  title: '从 ima 导入',
                  // 副标题要说清「新增的书怎么才会出现」—— 否则家长传完第二本，
                  // 回到这一页发现还是只有旧的几本，会以为导入功能坏了。
                  subtitle: '读取「教学资料/English」目录下的 md 书。新放进去的书，点右侧刷新。',
                  action: _RefreshButton(
                    busy: controller.loadingLibrary.value,
                    onPressed: () => controller.loadLibrary(),
                  ),
                ),
                const SizedBox(height: 8),
                ..._buildAvailable(),
              ],
            ],
          ),
        );
      }),
    );
  }

  List<Widget> _buildTasks() {
    final active = controller.tasks.where((task) => task.isActive).toList();
    if (active.isEmpty) {
      return [
        const _EmptyHint(
          icon: Icons.task_alt_outlined,
          text: '现在没有进行中的阅读任务。导入一本书，再从书库里布置。',
        ),
      ];
    }
    return [
      for (final task in active) ...[
        _ActiveTaskTile(task: task, onCancel: () => _cancel(task), onOpen: () {
          Get.toNamed('/reading', arguments: task.id);
        }),
        const SizedBox(height: 10),
      ],
    ];
  }

  List<Widget> _buildBooks() {
    if (controller.loadingLibrary.value && controller.books.isEmpty) {
      return [const _LoadingHint(text: '正在读取书库…')];
    }
    if (controller.books.isEmpty) {
      return [
        _EmptyHint(
          icon: Icons.library_books_outlined,
          // 没开通 ima 时下面根本没有那个区块，别把家长指过去。
          text: controller.imaBooksAvailable.value == false
              ? '还没有导入任何书。'
              : '还没有导入任何书。下面的「从 ima 导入」里选一本。',
        ),
      ];
    }
    return [
      for (final book in controller.books) ...[
        _BookTile(book: book, busy: controller.busy.value, onDeploy: () => _createTask(book)),
        const SizedBox(height: 10),
      ],
    ];
  }

  List<Widget> _buildAvailable() {
    if (controller.loadingLibrary.value && controller.available.isEmpty) {
      return [const _LoadingHint(text: '正在读取 ima 知识库…')];
    }
    if (controller.available.isEmpty) {
      return [
        // 空有两种原因：知识库里确实没 md，或者还没连 ima。前者要告诉家长
        // 「目录里没书」，后者要告诉家长「去连一下」—— 混成一句
        // 「暂无书籍」的话，没连 ima 的人会一直去翻自己的目录。
        _EmptyHint(
          icon: Icons.cloud_off_outlined,
          text: controller.availableHint.value ?? '没有读到可导入的书。',
          action: ('去设置 ima 知识库', () => Get.toNamed('/ima-settings')),
        ),
      ];
    }
    final unimported = controller.available.where((b) => !b.imported).length;
    return [
      for (final book in controller.available) ...[
        _AvailableTile(
          book: book,
          busy: controller.importing.value,
          onImport: () => _import(book),
        ),
        const SizedBox(height: 10),
      ],
      // 全部导完时整块会只剩几行灰字「已导入」，看着像功能没了。
      // 明说一次「怎么加新书」，比让家长自己猜要省事得多。
      if (unimported == 0)
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: Text(
            '目录里的书都导进来了。想加新书：把 md 放进 ima 的「教学资料/English」，'
            '再点右上角刷新。',
            style: TextStyle(fontSize: 12, color: AppColors.textMuted, height: 1.6),
          ),
        ),
    ];
  }
}

/// 标题右侧的刷新按钮。
///
/// 单独抽出来只为一件事：**请求进行中要有可见的反馈**。点一下毫无变化，
/// 家长会连点三次，而每次都在真打三个 ima 请求。
class _RefreshButton extends StatelessWidget {
  const _RefreshButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '刷新知识库',
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh, size: 20),
    );
  }
}

/// 进行中的任务：进度 + 「查看」+「取消」。
class _ActiveTaskTile extends StatelessWidget {
  const _ActiveTaskTile({required this.task, required this.onCancel, required this.onOpen});

  final ReadingTask task;
  final VoidCallback onCancel;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '《${task.bookTitle}》',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ),
              Text(
                '${task.doneLessons}/${task.totalLessons} 篇',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.success,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: task.progress,
              minHeight: 6,
              backgroundColor: AppColors.border,
              valueColor: const AlwaysStoppedAnimation(AppColors.success),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                task.nextLessonNo == null ? '没有下一篇' : '下一篇：第 ${task.nextLessonNo} 篇',
                style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
              const Spacer(),
              TextButton(
                onPressed: onCancel,
                child: const Text('取消', style: TextStyle(color: AppColors.danger)),
              ),
              const SizedBox(width: 4),
              FilledButton.tonal(onPressed: onOpen, child: const Text('查看')),
            ],
          ),
        ],
      ),
    );
  }
}

/// 书库里的一本：标题 + 篇数 + 「布置 / 继续」。
class _BookTile extends StatelessWidget {
  const _BookTile({required this.book, required this.busy, required this.onDeploy});

  final ReadingBook book;
  final bool busy;
  final VoidCallback onDeploy;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  book.title,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
                const SizedBox(height: 3),
                Text(
                  '${book.lessonCount} 篇'
                  '${book.hasActiveTask ? ' · 正在读' : ''}',
                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // 已经在读的书，按钮只是「去看看」—— 不能再布置一份
          // （服务端会返回同一份任务，但界面不该让人以为能开第二份）。
          FilledButton.tonal(
            onPressed: busy ? null : onDeploy,
            child: Text(book.hasActiveTask ? '继续读' : '布置'),
          ),
        ],
      ),
    );
  }
}

/// ima 里可导入的一本。
class _AvailableTile extends StatelessWidget {
  const _AvailableTile({required this.book, required this.busy, required this.onImport});

  final ReadingAvailableBook book;
  final bool busy;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  book.title,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
                const SizedBox(height: 3),
                Text(
                  book.imported ? '已导入 · ${book.importedLessonCount} 篇' : '未导入',
                  style: TextStyle(
                    fontSize: 12,
                    color: book.imported ? AppColors.success : AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (book.imported)
            const Text('已导入', style: TextStyle(fontSize: 12, color: AppColors.textMuted))
          else
            FilledButton.tonal(
              onPressed: busy ? null : onImport,
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('导入'),
            ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.subtitle, this.action});

  final String title;
  final String subtitle;

  /// 标题右侧的动作（目前只有「从 ima 导入」用：一个刷新按钮）。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ),
            ?action,
          ],
        ),
        const SizedBox(height: 2),
        Text(subtitle, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppColors.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13, color: AppColors.textMuted, height: 1.5),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: 8),
            TextButton(onPressed: action!.$2, child: Text(action!.$1)),
          ],
        ],
      ),
    );
  }
}

class _LoadingHint extends StatelessWidget {
  const _LoadingHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(text, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: AppColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12, height: 1.5, color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}
