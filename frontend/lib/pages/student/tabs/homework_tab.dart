import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';

import '../../../constants/app_colors.dart';
import '../../../controllers/auth_controller.dart';
import '../../../controllers/student_controller.dart';
import '../../../models/focus_session_model.dart';
import '../../../models/homework_image_model.dart';
import '../../../models/homework_kind.dart';
import '../../../models/homework_model.dart';
import '../../../models/homework_photo_draft.dart';
import '../../../services/ai_data_source_factory.dart';
import '../../../services/calendar_summary_service.dart';
import '../../../services/database_service.dart';
import '../../../services/homework_item_normalizer.dart';
import '../../../services/homework_text_parser.dart';
import '../../../services/lost_photo_recovery.dart';
import '../../../services/ocr_data_source.dart';
import '../../../utils/attachment_summary.dart';
import '../../../utils/duration_text.dart';
import '../../../services/ocr_service.dart';
import '../../../widgets/day_calendar.dart';
import '../../../widgets/grading_source_chip.dart';
import '../../../widgets/homework_image_viewer.dart';
import '../../../widgets/math_text.dart';
import '../../../widgets/homework_status.dart';
import '../../../widgets/needs_grading_switch.dart';
import '../../../widgets/parent_comment_card.dart';
import '../focus_timer_launcher.dart';
import '../homework_mistakes_page.dart';
import '../widgets/focus_timer_entry.dart';
import '../widgets/homework_submit_sheet.dart';

// 注：这里没有引用 `utils/pop_route.dart` 的 `popRoute`，是**刻意**的。
// `_recognizeAndImport` 里关进度弹窗时 `context` 已经跨过 await 取不到了，
// 所以那边是在 await 之前先把 `Navigator` 取出来再 pop。别「顺手」补上。

/// 当前装配的 OCR 数据源。
///
/// 正常从学生首页进入时 [AiRuntime] 一定已注册；单独构建本 Tab 做调试时没有 ——
/// 那种情况下回落到本地实现，而不是让「拍照识别」整个抛异常。
OcrDataSource get _ocrDataSource => Get.isRegistered<AiRuntime>()
    ? Get.find<AiRuntime>().ocrDataSource
    : const SimulatedOcrDataSource();

/// 一次拍照识别最多收几张照片。
///
/// 上限存在的理由不是技术限制，是**核对成本**：识别出来的条目要一条条看
/// 有没有认错。页数越多，学生越可能直接点保存，那这一步就白做了。
const int kMaxOcrPhotos = 4;

/// 认不出来时学生能做的三件事。
///
/// 「去登录」是后加的，因为它曾经**根本不是学生的错**：
/// 未登录时请求压根没发出去，模型一次都没被调用，
/// 而界面上写的却是「光线太暗、拍歪了」——去重拍一百次也不会有变化。
/// 提示必须指向真正能做的那一步。
enum _UnrecognizedAction { manual, retry, login }

/// 学生端首页的「作业」页。
///
/// ## 为什么这个类是 `StatefulWidget`（曾经是 `StatelessWidget`）
///
/// 选中的日期原先存在 `static final Rx<DateTime> _selectedDate` 里 ——
/// 那是**跨实例共享的全局状态**。三处日历的另外两处（`workout_tab` /
/// `overview_tab`）用的都是实例字段，只有这一处是 `static`。
///
/// 后果有两类，都不报错：
///   · **测试之间会串**：一个用例改了选中日期，另一个用例看得见，
///     表现为「单独跑绿、一起跑红」这种最难查的失败；
///   · **将来做「记忆上次查看位置」时会串得更明显**（两个孩子的页面互相污染）。
///
/// 改成实例字段是「抽公共控件」的前置步骤：`WeekStrip` 的选中态由调用方持有，
/// 调用方必须是 StatefulWidget 才放得下。
class HomeworkTab extends StatefulWidget {
  const HomeworkTab({super.key});

  @override
  State<HomeworkTab> createState() => _HomeworkTabState();
}

class _HomeworkTabState extends State<HomeworkTab> {
  /// 当前选中的日期。
  ///
  /// ⚠️ **这是实例字段，不是 `static`** —— 见 [HomeworkTab] 的类注释。
  /// 原来是 `static final Rx<DateTime> _selectedDate`，那是跨实例共享的全局态。
  DateTime _selectedDate = DateTime.now();

  /// 学生控制器。在 [initState] 里取一次 —— 不放在 `build` 里当局部量，
  /// 因为摘要相关的回调（`onMonthChanged`）在 `build` 之外也要用它。
  late final StudentController controller;

  /// 摘要服务（含按月缓存）。
  ///
  /// ⚠️ **必须是实例字段、只建一次。** 写成 `get _summary => CalendarSummaryService(...)`
  /// 会让每次调用都新建一个 —— 而缓存是**实例字段**，于是缓存永远命中不了、
  /// 每次翻月都真的发一次请求，**且没有任何报错**（只是慢/费流量）。
  /// 这种「缓存看着在、其实一直失效」的形态在首屏预取那轮见过一次。
  late final CalendarSummaryService _summary;

  @override
  void initState() {
    super.initState();
    controller = Get.find<StudentController>();
    // 本地模式（`DatabaseService.cloud == null`）下 `api` 传 null，
    // `CalendarSummaryService` 会直接回空 Map —— 日历不打点，但照常可用。
    _summary = CalendarSummaryService(api: DatabaseService.cloud?.api);
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final today = DateTime.now();
      final selectedDate = _selectedDate;
      final homework = controller.homeworkList
          .where((item) => _isSameDay(item.dueAt, selectedDate))
          .toList();
      final todayHomework = controller.homeworkList
          .where((item) => _isSameDay(item.dueAt, today))
          .toList();
      final todayFinished = todayHomework
          .where((h) => h.status == HomeworkStatus.finished)
          .length;
      final todayTotal = todayHomework.length;
      final todayWrong = todayHomework.fold(0, (sum, h) => sum + h.wrongCount);
      final todayPending = todayHomework.where((h) => h.canSubmit).length;

      // 「家长点评」卡片显示**最近一条**点评，并把它的日期一起写出来。
      //
      // 2026-10-27 用户报「今天的点评，任意一天看到的都是几天前那条」：
      // 卡片原先既不标日期、也不区分是哪天的，读书的人自然把它当成
      // 「今天家长给我的点评」—— 而它其实可能是好几天前那条。
      // 修法不是藏掉旧点评（那会丢信息），而是让日期明明白白。
      final latestComment =
          controller.dailyComments.isEmpty ? null : controller.dailyComments.first;

      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 今日学习计划打卡提示（有待打卡计划时显示，点击跳转计划页）
          if (controller.todayPlans.isNotEmpty &&
              controller.todayPendingCheckinCount > 0)
            _TodayPlanCheckinBanner(controller: controller),
          if (controller.todayPlans.isNotEmpty &&
              controller.todayPendingCheckinCount > 0)
            const SizedBox(height: 16),
          // 每日学习概览卡片
          _DailySummaryCard(
            finished: todayFinished,
            total: todayTotal,
            pending: todayPending,
            wrongCount: todayWrong,
          ),
          const SizedBox(height: 16),
          if (latestComment != null)
            ParentCommentCard(comment: latestComment, now: today),
          const Text(
            '学习日历',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          WeekStrip(
            selectedDate: selectedDate,
            today: today,
            onDateSelected: (date) => setState(() => _selectedDate = date),
            onPickMonth: () => _openMonthPicker(selectedDate),
            marks: _localMarksFor(selectedDate),
          ),
          const SizedBox(height: 18),

          Text(
            _isSameDay(selectedDate, today)
                ? '今天的学习任务'
                : '${selectedDate.month}月${selectedDate.day}日的学习记录',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '作业录入',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () => _showHomeworkForm(
                          context,
                          controller,
                          selectedDate,
                        ),
                        icon: const Icon(Icons.add_task),
                        label: const Text('录入作业'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _recognizeAndImport(
                          context,
                          controller,
                          selectedDate,
                        ),
                        icon: const Icon(Icons.document_scanner_outlined),
                        label: const Text('拍照识别'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (homework.isEmpty)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                children: [
                  const Icon(
                    Icons.task_alt,
                    size: 40,
                    color: AppColors.primary,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '暂无作业',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _isSameDay(selectedDate, today) ? '今天还没有录入作业' : '这一天暂无学习记录',
                  ),
                ],
              ),
            )
          else
            ...homework.map(
              (item) => _HomeworkCard(
                item: item,
                images: controller.imagesOfHomework(item.id),
                // finished 走补充提交（canSupplement），不是重新提交。
                onSubmit: (item.canSubmit || item.canSupplement)
                    ? () => openHomeworkSubmitSheet(
                        context: context,
                        controller: controller,
                        homework: item,
                      )
                    : null,
                onDeleteImages: () =>
                    _confirmDeleteImages(context, controller, item),
                onDelete: () =>
                    _confirmDeleteHomework(context, controller, item),
                onEdit: () => _editHomework(context, controller, item),
                onStartTimer: () => _openFocusTimer(context, controller, item),
              ),
            ),
        ],
      );
    });
  }

  static bool _isSameDay(DateTime first, DateTime second) {
    return first.year == second.year &&
        first.month == second.month &&
        first.day == second.day;
  }

  Future<void> _showHomeworkForm(
    BuildContext context,
    StudentController controller,
    DateTime selectedDate, {
    List<Map<String, dynamic>>? initialTasks,
    List<HomeworkPhotoDraft> sourcePhotos = const [],
    double? confidence,
    int missedPhotoCount = 0,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _HomeworkBatchDialog(
        selectedDate: selectedDate,
        controller: controller,
        initialTasks: initialTasks,
        sourcePhotos: sourcePhotos,
        confidence: confidence,
        missedPhotoCount: missedPhotoCount,
      ),
    );
  }

  /// 拍照识别 → 按科目归类 → 预填到录入表单。
  ///
  /// 失败的处置是这段里最要紧的部分：认不出来时**必须给出下一步动作**，
  /// 而不是弹一句「识别失败」就结束 —— 学生这时候手里有照片、也有作业本，
  /// 他要的是「那我怎么录进去」。
  Future<void> _recognizeAndImport(
    BuildContext context,
    StudentController controller,
    DateTime selectedDate,
  ) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照识别'),
              subtitle: Text('一张一张拍，最多 $kMaxOcrPhotos 张'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册多选识别'),
              subtitle: const Text('一次选中整份作业的所有页'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !context.mounted) return;

    final photos = await _collectPhotos(context, source);
    if (photos.isEmpty || !context.mounted) return;

    final studentId =
        Get.find<AuthController>().currentUser.value?.id ?? 'unknown';

    Get.dialog(
      const Center(child: CircularProgressIndicator()),
      barrierDismissible: false,
    );
    // 在 await 之前把 Navigator 取出来，而不是等识别回来再拿 `context`。
    //
    // 两个理由：一是 `context` 跨 await 之后可能已经失效（页面被退掉），
    // 那时 `Navigator.of(context)` 本身就取不到了；二是**这个进度弹窗是
    // `barrierDismissible: false` 的，漏关它等于一块点不掉的遮罩永远堵在
    // 屏幕上** —— 恰恰是「页面已经退出去了」这种情况下最需要把它关掉，
    // 所以不能靠 `if (!context.mounted) return;` 把这条路提前掐掉。
    final navigator = Navigator.of(context);

    final HomeworkOcrResult result;
    try {
      // 走运行时装配的 OCR 数据源：配了网关就是视觉模型识别，
      // 没配（或探测到视觉模型未开通）就还是本地模拟，调用点形状不变。
      result = await OcrService(dataSource: _ocrDataSource).recognizeHomework(
        studentId: studentId,
        inputs: [
          for (final photo in photos)
            HomeworkOcrInput(fileName: photo.fileName, bytes: photo.bytes),
        ],
      );
    } catch (error) {
      if (Get.isDialogOpen ?? false) navigator.pop();
      if (!context.mounted) return;
      Get.snackbar('识别失败', '图片识别出错：$error');
      return;
    }

    if (Get.isDialogOpen ?? false) navigator.pop();
    if (!context.mounted) return;

    if (!result.isUsable) {
      final action = await _showUnrecognizedDialog(context, result);
      if (!context.mounted) return;
      if (action == _UnrecognizedAction.retry) {
        await _recognizeAndImport(context, controller, selectedDate);
      } else if (action == _UnrecognizedAction.manual) {
        await _showHomeworkForm(context, controller, selectedDate);
      } else if (action == _UnrecognizedAction.login) {
        Get.offAllNamed('/login');
      }
      return;
    }

    final groupCount = HomeworkTextParser.groupBySubject(result.tasks).length;
    Get.snackbar(
      '识别完成',
      '已按 $groupCount 个科目整理出 ${result.tasks.length} 项作业，请核对后保存',
    );
    await _showHomeworkForm(
      context,
      controller,
      selectedDate,
      initialTasks: result.tasks,
      sourcePhotos: photos,
      confidence: result.confidence,
      missedPhotoCount: result.sourceImageCount - result.recognizedImageCount,
    );
  }

  /// 收照片。相册一次多选；相机一次一张，拍完问一句要不要接着拍 ——
  /// 作业抄在两三页上很常见，逼学生退出去重来一遍纯属添堵。
  Future<List<HomeworkPhotoDraft>> _collectPhotos(
    BuildContext context,
    ImageSource source,
  ) async {
    final picker = ImagePicker();
    final drafts = <HomeworkPhotoDraft>[];

    // 先把上次因系统回收而丢失的照片捡回来，再开相机。
    // 顺序有讲究：放在前面，学生看到的第一批里就包含它；放在后面会变成
    // 「拍完一张之后突然又冒出一张来历不明的」。
    // 这一处比提交面板更需要它 —— 下面是**循环连拍**，学生每确认一张，
    // 我们的界面就退到后台一次，被回收的机会是提交面板的好几倍。
    final recovered = await LostPhotoRecovery.instance.takeLostPhotos();
    for (final file in recovered.take(kMaxOcrPhotos)) {
      // 单张读失败不该让整批都丢掉 —— 能救回几张是几张。
      try {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) continue;
        drafts.add(HomeworkPhotoDraft.photo(fileName: file.name, bytes: bytes));
      } catch (error) {
        debugPrint('读回丢失照片失败，跳过这一张：$error');
      }
    }
    if (drafts.isNotEmpty && context.mounted) {
      Get.snackbar('已找回照片', '上次拍摄的照片还在，已经和这次的一起识别');
    }

    try {
      if (source == ImageSource.gallery) {
        final files = await picker.pickMultiImage(
          imageQuality: 85,
          maxWidth: 2048,
        );
        for (final file in files.take(kMaxOcrPhotos)) {
          final bytes = await file.readAsBytes();
          if (bytes.isEmpty) continue;
          drafts.add(HomeworkPhotoDraft.photo(fileName: file.name, bytes: bytes));
        }
        if (files.length > kMaxOcrPhotos) {
          Get.snackbar(
            '提示',
            '一次最多识别 $kMaxOcrPhotos 张，已取前 $kMaxOcrPhotos 张',
          );
        }
        return drafts;
      }

      while (drafts.length < kMaxOcrPhotos) {
        final shot = await picker.pickImage(
          source: ImageSource.camera,
          imageQuality: 85,
          maxWidth: 2048,
        );
        if (shot == null) break;
        final bytes = await shot.readAsBytes();
        if (bytes.isEmpty) break;
        drafts.add(HomeworkPhotoDraft.photo(fileName: shot.name, bytes: bytes));

        if (drafts.length >= kMaxOcrPhotos) break;
        if (!context.mounted) break;
        if (await _askShootMore(context, drafts.length) != true) break;
      }
    } catch (error) {
      Get.snackbar('无法读取图片', '$error');
    }
    return drafts;
  }

  Future<bool?> _askShootMore(BuildContext context, int count) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('还要再拍一页吗？'),
        content: Text('已经拍了 $count 张。作业抄在多页上的话，拍完一起识别，结果会合并。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('够了，开始识别'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.photo_camera_outlined, size: 18),
            label: const Text('继续拍'),
          ),
        ],
      ),
    );
  }

  /// 认不出来时的两条路：手工录入、重拍。
  ///
  /// 这里刻意不用 snackbar：snackbar 会自己消失，而此刻学生正需要做决定。
  Future<_UnrecognizedAction?> _showUnrecognizedDialog(
    BuildContext context,
    HomeworkOcrResult result,
  ) {
    final missed = result.sourceImageCount - result.recognizedImageCount;
    final copy = _unrecognizedCopy(result, missed);
    return showDialog<_UnrecognizedAction>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(copy.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(copy.reason),
            const SizedBox(height: 8),
            Text(
              copy.advice,
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textMuted,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '手工录一遍，后面的批改、错题复习都照常走，功能不会少。',
                style: TextStyle(fontSize: 12.5, height: 1.5),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _UnrecognizedAction.manual),
            child: const Text('手工录入'),
          ),
          if (copy.offerRetry)
            ElevatedButton.icon(
              onPressed: () =>
                  Navigator.pop(dialogContext, _UnrecognizedAction.retry),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重拍一张'),
            ),
          if (copy.offerLogin)
            ElevatedButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, _UnrecognizedAction.login),
              child: const Text('去登录'),
            ),
        ],
      ),
    );
  }

  /// 按**真实成因**给出文案。
  ///
  /// 这里必须分情况，因为「没能认出内容」对用户是个歧义词：
  /// 他读到之后的第一反应是「照片拍得不好」或「模型不行」，
  /// 而这两件事可能都不是原因 —— 例如未登录时请求根本没发出去，
  /// 重拍多少次都一样（2026-09-15 的实际排查结论）。
  _UnrecognizedCopy _unrecognizedCopy(HomeworkOcrResult result, int missed) {
    final missedLine = missed > 0
        ? '${result.sourceImageCount} 张照片里有 $missed 张没能识别。'
        : '照片里的作业内容没能识别出来。';

    switch (result.failure) {
      case OcrFailureKind.noIdentity:
        return _UnrecognizedCopy(
          title: '这次没有联网识别',
          reason: missedLine,
          advice: result.failureNote ??
              '当前没有登录信息，识别请求没有发出去 —— 重拍不会有变化。'
                  '登录后重试即可用上云端识别。',
          offerRetry: false,
          offerLogin: true,
        );
      case OcrFailureKind.offline:
        return const _UnrecognizedCopy(
          title: '当前是离线识别',
          reason: '离线模式只能按图片名做演示识别，读不出照片里的内容。',
          advice: '这是正常的离线行为，不是照片的问题。可以直接手工录入，或等接上云端识别后再拍。',
          offerRetry: false,
        );
      case OcrFailureKind.rejected:
        return _UnrecognizedCopy(
          title: '识别服务没有接受这次请求',
          reason: missedLine,
          advice: result.failureNote == null
              ? '这次是服务端的问题，不是你拍得不好。稍后重试，或先手工录入。'
              : '服务端说明：${result.failureNote}',
          offerRetry: true,
        );
      case OcrFailureKind.unreachable:
        return _UnrecognizedCopy(
          title: '连不上识别服务',
          reason: missedLine,
          advice: '网络或识别服务暂时不可用，和你拍得怎么样无关。稍后重试即可，或先手工录入。',
          offerRetry: true,
        );
      case OcrFailureKind.notRecognized:
      case null:
        // 模型确实看过这张照片，只是没能读出可用的作业内容 —— 这时才该建议重拍。
        return _UnrecognizedCopy(
          title: '没能认出作业内容',
          reason: missedLine,
          advice: '常见原因：光线太暗、拍歪了、字迹潦草，或者作业格式比较少见。',
          offerRetry: true,
        );
    }
  }

  Future<void> _confirmDeleteImages(
    BuildContext context,
    StudentController controller,
    HomeworkItem item,
  ) async {
    final attachments = controller.imagesOfHomework(item.id);
    if (attachments.isEmpty) {
      Get.snackbar('提示', '该作业没有已上传的附件');
      return;
    }
    final summary = attachmentSummary(attachments);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除作业附件'),
        content: Text(
          '确定删除「${item.title}」的 $summary 吗？删除后家长端将无法查看。\n'
          '作业的提交记录会保留，不会变成「未提交」。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final result = await controller.removeHomeworkPhotos(item.id);
    Get.snackbar(result.ok ? '已删除' : '删除失败', result.message);
  }

  /// 删除**整份作业**前的确认。
  ///
  /// ## 文案按状态分级，而不是一句通用的「确定删除吗」
  ///
  /// 两种情况的后果差得远：未提交的作业只是一条录入记录（识别拍的照片
  /// 并不落库，所以它真的只有一行）；已提交/已批改的会连照片、错题本里
  /// 由它带出来的那些题、以及家长端那条记录一起消失。
  /// 合成一句「相关数据会一并删除」的话两种情况都不够用 ——
  /// 学生没法据此判断「我是不是该先跟家长说一声」。
  ///
  /// ## 为什么把「积分不追回」专门写出来
  ///
  /// 它是这个操作里**唯一不按直觉走**的一条：多数人会以为「删了作业，
  /// 加过的分也该收回」。实际不收回（`point_ledger` 是账本，撤一笔会让
  /// 余额与流水对不上）。不写明的话，学生要么以为分掉了、要么被家长问
  /// 「分怎么还在」时答不上来 —— 而这两种都只在删完之后才会被发现。
  ///
  /// ## 与「删除作业照片」是两个动作，别合并
  ///
  /// 删照片之后「已提交」这个事实还在（提交通知已经发给家长了，
  /// 悄悄撤回提交会让家长看到的状态与孩子的操作不一致）；
  /// 删作业则连那条记录一起没了。两者在确认框里说清的事完全不同。
  Future<void> _confirmDeleteHomework(
    BuildContext context,
    StudentController controller,
    HomeworkItem item,
  ) async {
    final submitted = item.hasSubmission;
    final wrongCount = item.wrongCount;

    final detail = submitted
        ? '这份作业已经提交过。它的照片、批改结果，以及它带出来的'
              '${wrongCount > 0 ? ' $wrongCount 道错题' : '错题'}都会一起删除，'
              '家长端那条记录也会消失。\n\n'
              '已经获得的积分不会收回。'
        : '这条作业还没有提交过，删除它不会影响任何已有记录。';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这份作业'),
        content: Text('「${item.title}」\n\n$detail'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final result = await controller.deleteHomework(item.id);
    // 文案用服务端/仓库给的那句（`OpResult.message`）：删不到时它会说清
    // 「找不到这份作业（或无权删除）」，比这里统一编一句「删除失败」有用。
    Get.snackbar(result.ok ? '已删除' : '删除失败', result.message);
  }

  /// 打开全屏专注计时。
  ///
  /// ## 同时只允许一份作业在计时
  ///
  /// 两段计时并行的话，「实际用时」这个数字就没有意义了 —— 学生同时做两科、
  /// 每科各记一小时，加起来两小时，而他只坐了一小时。所以第二份作业要开始时，
  /// 先把上一份**暂停并保存**，再开新的。
  ///
  /// ⚠️ 这里不能「静默丢掉上一份」：那段时间已经发生了，丢了就是少记。
  /// 也不能「自动继续累计到新作业上」：那是把两科的时间记成一科。
  /// 打开全屏专注计时（见 `FocusTimerLauncher`）。
  Future<void> _openFocusTimer(
    BuildContext context,
    StudentController controller,
    HomeworkItem item,
  ) async {
    await FocusTimerLauncher.open(context, controller, FocusTarget.homework(item));
  }

  /// 打开「修改作业」对话框。
  ///
  /// 复用 [_HomeworkBatchDialog] 而不是另写一个单条表单：科目下拉的选项来源、
  /// 「改标题就重推类型、耗时、要不要批改」这些联动规则，只能有一处实现。
  /// 复制一份出去之后必然会漂，而漂的表现是「核对识别结果时改得动、
  /// 事后编辑却改不动」这种只在一条路径上冒出来的怪毛病。
  ///
  /// ⚠️ **不传 `sourcePhotos`**：那是「识别用的原图」，只在核对识别结果的
  /// 当刻有意义。事后编辑时它既不是这次识别来的，也可能早被删了 ——
  /// 传进去只会让对话框误以为自己在核对识别结果（标题会变成「核对识别结果」）。
  Future<void> _editHomework(
    BuildContext context,
    StudentController controller,
    HomeworkItem item,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _HomeworkBatchDialog(
        selectedDate: item.dueAt,
        controller: controller,
        editTarget: item,
      ),
    );
  }

  /// 打开月历弹层，选中的日期回填到周历与列表。
  ///
  /// ## 三个刻意的行为
  ///
  /// ① **返回 null（用户取消）时不改任何东西。** 不能用
  ///    `?? selectedDate` 那种写法 —— 那会把「取消」和「选了同一天」抹平，
  ///    而现在这个区别没有实际后果；将来加上「打开弹层时预选别的月」就会有了。
  ///
  /// ② **摘要是加速手段，不是通路。** 它取不到时日历照常可用
  ///    （`CalendarSummaryService` 内部把失败吞成空 Map，见那个类的说明）——
  ///    这里不要写 `try/catch` 去兜，那会在两处表达同一个意思。
  ///
  /// ③ **翻月时先给「正在读」的提示，再填打点。**
  ///    这一整段（弹层 + 打点 + 清理）由 [MonthPickerLauncher] 管 ——
  ///    三个页面共用那一份，所以「历史怎么查」在这三页里**编译期就是同一件事**。
  ///    传进去的只有两处差异：`localMarks`（还没有摘要时先显示什么）
  ///    和 `fetchSummary`（怎么取某个月的打点）。
  Future<void> _openMonthPicker(DateTime selectedDate) async {
    final picked = await MonthPickerLauncher.open(
      context,
      selectedDate: selectedDate,
      // 本地模式（`api == null`）下 `summaryFor` 会直接回空 Map，
      // 所以这里不必判模式 —— 一条路径，两种模式。
      fetchSummary: (month) => _summary.summaryFor(month),
      localMarks: _localMarksFor(selectedDate),
    );
    if (picked == null) return;
    if (!mounted) return;
    setState(() => _selectedDate = picked);
  }

  /// 当前已有的打点（**本地算的**，零成本）。
  ///
  /// 为什么先给本地算的：`controller.homeworkList` 里已经有最近这批作业了，
  /// 按天归一下组就能打点，不必等一次网络往返。代价是它**只覆盖已加载的行**
  /// （作业默认 limit 50），所以它是「先显示点什么」而不是「这个月的真相」——
  /// 真相由服务端摘要给出，翻月时 `MonthPickerLauncher` 会把它换上去。
  ///
  /// 作业页只按 `dueAt` 打点：这一页的主题就是作业，
  /// 把运动和打卡也点上去会让「这点是什么意思」变得含糊。
  Map<String, DayMarks> _localMarksFor(DateTime month) {
    final list = controller.homeworkList;
    if (list.isEmpty) return const {};
    final key = DayUtil.monthKey(month);
    return LocalDayMarks.build(
      homework: list.where((h) => DayUtil.monthKey(h.dueAt) == key),
      workoutRecords: const [],
      checkins: const [],
    );
  }
}

class _DailySummaryCard extends StatelessWidget {
  final int finished;
  final int total;
  final int pending;
  final int wrongCount;

  const _DailySummaryCard({
    required this.finished,
    required this.total,
    required this.pending,
    required this.wrongCount,
  });

  @override
  Widget build(BuildContext context) {
    final rate = total > 0 ? finished / total : 0.0;
    final allDone = total > 0 && finished == total;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: allDone
              ? [AppColors.success, AppColors.success.withValues(alpha: 0.8)]
              : [AppColors.primary, AppColors.primary.withValues(alpha: 0.8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.today, size: 20, color: Colors.white),
              const SizedBox(width: 8),
              const Text(
                '今日学习概览',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const Spacer(),
              if (total > 0)
                Text(
                  '${(rate * 100).toInt()}%',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (total == 0)
            const Text(
              '今天暂无作业，轻松一下～',
              style: TextStyle(color: Colors.white, fontSize: 14),
            )
          else ...[
            // 进度条
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                height: 8,
                child: LinearProgressIndicator(
                  value: rate,
                  backgroundColor: Colors.white.withValues(alpha: 0.3),
                  valueColor: const AlwaysStoppedAnimation(Colors.white),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _SummaryItem(
                  icon: Icons.check_circle_outline,
                  label: '已完成',
                  count: finished,
                ),
                _SummaryItem(
                  icon: Icons.pending_actions,
                  label: '待完成',
                  count: pending,
                ),
                _SummaryItem(
                  icon: Icons.error_outline,
                  label: '错题',
                  count: wrongCount,
                ),
                _SummaryItem(icon: Icons.assignment, label: '合计', count: total),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;

  const _SummaryItem({
    required this.icon,
    required this.label,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, size: 20, color: Colors.white.withValues(alpha: 0.9)),
          const SizedBox(height: 4),
          Text(
            '$count',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeworkDraft {
  final TextEditingController titleController;
  final TextEditingController estimatedController;
  String subject;

  /// 模型说这一条里有认不准的字。
  ///
  /// 一旦学生动手改过内容就置为 false —— 这一条已经被人看过并确认了，
  /// 再挂着「请核对」只会让真正没核对过的那几条被淹没。
  bool uncertain;

  /// 学生有没有自己动过「预计耗时」。
  ///
  /// 没动过时改标题会跟着重算（「口算20题」改成「口算10题」，时间就该变）；
  /// 一旦他手填过就不再覆盖 —— 系统猜的数不该盖掉学生自己知道的事，
  /// 否则每改一个字都要重新填一遍时间。
  bool estimateTouched = false;

  /// 这一条要不要批改。
  ///
  /// 落库的（DB v21）。两类作业没有可判的东西，交上来就算完成：
  /// 朗读、背诵、预习的产出是一段过程，默写、抄写、字帖的题干
  /// （词表、范字）根本没被拍进照片。硬走一遍批改只会得到一份
  /// 对着没答案的照片编出来的评语 —— 而它看起来像结论。
  bool needsGrading;

  /// 学生有没有自己动过「需要批改」这个开关。
  ///
  /// 与耗时同一个道理：没动过时改标题会跟着重推 ——
  /// 标题从「朗读课文」改成「完成练习册」，口径就该从「不必批」翻成「要批」；
  /// 一旦他自己点过，说明他知道这条的实际要求，不再覆盖。
  bool gradingTouched = false;

  _HomeworkDraft({
    this.subject = HomeworkItemNormalizer.unknownSubject,
    String title = '',
    this.uncertain = false,
    int? estimatedMinutes,
    bool? needsGrading,
  }) : titleController = TextEditingController(text: title),
       estimatedController = TextEditingController(
         text: '${estimatedMinutes ?? estimateHomeworkMinutes(title)}',
       ),
       // 默认按标题推。识别出的「朗读课文」不该预勾成要批改 ——
       // 预勾错了学生很难发现，因为他不会去读一个自己没动过的开关。
       needsGrading = needsGrading ?? HomeworkKind.of(title).needsGrading;

  /// 标题变了就重推默认值（仅当学生还没手动改过）。
  ///
  /// 重算时**不带模型原来的建议**：那个数是模型对着旧文字给的，
  /// 标题一改它就过期了，继续沿用等于拿一个不相关的数冒充依据。
  void onTitleChanged() {
    final title = titleController.text;
    if (!gradingTouched) {
      needsGrading = HomeworkKind.of(title).needsGrading;
    }
    if (estimateTouched) return;
    estimatedController.text = '${estimateHomeworkMinutes(title)}';
  }

  void dispose() {
    titleController.dispose();
    estimatedController.dispose();
  }
}

class _HomeworkBatchDialog extends StatefulWidget {
  final DateTime selectedDate;
  final StudentController controller;

  /// 识别出来的条目，用于预填。手工录入时为空。
  final List<Map<String, dynamic>>? initialTasks;

  /// 识别用的原图。有值时对话框顶部会摆出缩略图 —— 核对识别结果唯一可靠的
  /// 办法是对着原图看，而学生手上那张纸很快就不在手边了。
  final List<HomeworkPhotoDraft> sourcePhotos;

  /// 识别把握（0-1）。手工录入时为 null，不显示这一行。
  final double? confidence;

  /// 有几张照片没认出来。
  final int missedPhotoCount;

  /// 要**编辑**的那一份作业（null = 新建 / 手工录入 / 核对识别结果）。
  ///
  /// 有值时对话框进入「编辑单个作业」形状：改这一份的科目、内容与批改开关，
  /// 保存走 `updateHomeworkFields`（掩码局部更新）而不是新增。
  ///
  /// ⚠️ **三个形状共用一个对话框是有意的**（见 [_editHomework]）：字段与
  /// 联动规则只写一遍。区分靠两处：本字段决定「新增还是改」，
  /// `sourcePhotos` 决定「顶部摆不摆识别原图、标题叫什么」。
  final HomeworkItem? editTarget;

  const _HomeworkBatchDialog({
    required this.selectedDate,
    required this.controller,
    this.initialTasks,
    this.sourcePhotos = const [],
    this.confidence,
    this.missedPhotoCount = 0,
    this.editTarget,
  });

  @override
  State<_HomeworkBatchDialog> createState() => _HomeworkBatchDialogState();
}

class _HomeworkBatchDialogState extends State<_HomeworkBatchDialog> {
  late final List<_HomeworkDraft> drafts = _initDrafts();

  /// 保存中。**必须把按钮按住**，理由不是防连点，而是这个动作比看起来慢：
  /// 每一条作业都要等服务端把 id 发回来才落进列表（见
  /// `StudentController.addHomeworks`），而列表里一旦出现 id 还没定下来的
  /// 作业，用户点进去提交就会把照片挂到服务端不认的键上。
  bool _saving = false;

  /// 下拉框里能选的科目：规范清单 ∪ 这一批里实际出现的。
  ///
  /// 取并集不是为了灵活，是为了**不崩**：`DropdownButtonFormField` 要求
  /// `initialValue` 必须在 `items` 里，而识别出的科目是自由字符串
  /// （模型可能给「科学」这种清单外的名字）。只给固定清单的话，
  /// 遇到清单外的科目会直接断言失败；release 下不崩，但输入框显示为空，
  /// 学生既看不到识别出的科目、也选不回它。
  List<String> get _subjectOptions => HomeworkItemNormalizer.subjectOptionsFor([
    for (final draft in drafts) draft.subject,
  ]);

  List<_HomeworkDraft> _initDrafts() {
    // 编辑：从**库里那一行**起手（不是从识别结果）。
    final target = widget.editTarget;
    if (target != null) {
      return <_HomeworkDraft>[
        _HomeworkDraft(
          subject: target.subject,
          title: target.title,
          // ⚠️ 必须显式把 needsGrading 传进去：`_HomeworkDraft` 的默认值是
          // **按标题重推**的，不传就等于把学生当初定过的开关静默翻掉 ——
          // 他只是打开来改个错字，一保存却顺手改了批改口径，而界面上
          // 那个开关本来显示的是对的。这类「改 A 顺手改了 B」最难被发现。
          needsGrading: target.needsGrading,
          estimatedMinutes: target.estimatedMinutes.round(),
        ),
      ];
    }
    final tasks = widget.initialTasks;
    if (tasks == null || tasks.isEmpty) {
      return <_HomeworkDraft>[_HomeworkDraft()];
    }
    return tasks
        .map(
          (task) => _HomeworkDraft(
            subject:
                task['subject'] as String? ??
                HomeworkItemNormalizer.unknownSubject,
            title: task['text'] as String? ?? '',
            uncertain: taskIsUncertain(task),
            estimatedMinutes: _suggestedMinutes(task),
          ),
        )
        .toList();
  }

  /// 模型给的耗时建议。
  ///
  /// 取值域由网关 schema 约束（5–120 的整数），这里仍要挡一道：
  /// schema 是服务端的事，客户端不能假设它一定生效（老网关、被改过的部署
  /// 都会绕过）。挡法很轻 —— 不合理就当没给，让标题推导去兜。
  int? _suggestedMinutes(Map<String, dynamic> task) {
    final raw = task['estimatedMinutes'];
    if (raw is! num) return null;
    final value = raw.round();
    return value >= 5 && value <= 120 ? value : null;
  }

  @override
  void dispose() {
    for (final draft in drafts) {
      draft.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fromRecognition = widget.sourcePhotos.isNotEmpty;
    final isEditing = widget.editTarget != null;
    return AlertDialog(
      title: Row(
        children: [
          Expanded(
            child: Text(
              isEditing
                  ? '修改作业'
                  : (fromRecognition ? '核对识别结果' : '批量录入作业'),
            ),
          ),
          // 编辑时那个「N 项」没有意义（恒为 1 项），而且标题本来就长，
          // 挤在标题栏里会被截断 —— 不如不显示。
          if (!isEditing)
            Text(
              '${drafts.length} 项',
              style: const TextStyle(fontSize: 14, color: AppColors.textMuted),
            ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (fromRecognition) ...[
                _SourcePhotoStrip(photos: widget.sourcePhotos),
                const SizedBox(height: 12),
                _RecognitionNotice(
                  confidence: widget.confidence ?? 0,
                  missedPhotoCount: widget.missedPhotoCount,
                  uncertainCount: drafts.where((d) => d.uncertain).length,
                ),
              ] else
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 18,
                        color: AppColors.primary,
                      ),
                      SizedBox(width: 8),
                      Expanded(child: Text('同一科目可以添加多项，例如语文：背诵、作文。')),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              ..._groupedCards(),
              // 编辑单份时不给「继续添加一项」：那是**新增**语义，与「改这一份」
              // 冲突，而且一旦点了，编辑分支只会读 `drafts.first` ——
              // 多出来的条目会被**静默丢掉**（打好了字、保存了、没落库）。
              if (!isEditing)
                OutlinedButton.icon(
                  onPressed: () => setState(() => drafts.add(_HomeworkDraft())),
                  icon: const Icon(Icons.add),
                  label: const Text('继续添加一项'),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        ElevatedButton.icon(
          onPressed: _saving ? null : _saveAll,
          icon: const Icon(Icons.check),
          label: Text(
            _saving ? '正在保存…' : (isEditing ? '保存修改' : '确认保存全部'),
          ),
        ),
      ],
    );
  }

  /// 科目出现的顺序：按首次出现排，「待确认」压到最后。
  ///
  /// 不按字典序排：识别结果里「语文」在最前，界面上就该「语文」在最前 ——
  /// 学生核对时视线是跟着照片从上往下走的，顺序变了就要来回找。
  List<String> _subjectsInOrder() {
    final order = <String>[];
    for (final draft in drafts) {
      if (!order.contains(draft.subject)) order.add(draft.subject);
    }
    final unknown = HomeworkItemNormalizer.unknownSubject;
    final sorted = order.where((subject) => subject != unknown).toList();
    if (order.contains(unknown)) sorted.add(unknown);
    return sorted;
  }

  /// 按科目分组渲染。
  ///
  /// 为什么不平铺一列：识别出来的十来条平铺下来，学生看不出「语文几项、
  /// 数学几项」，也就没法判断是不是漏了哪一科 —— 而「按科目归类」
  /// 正是他要在这一步确认的事。
  List<Widget> _groupedCards() {
    final widgets = <Widget>[];
    for (final subject in _subjectsInOrder()) {
      final indexes = [
        for (var i = 0; i < drafts.length; i++)
          if (drafts[i].subject == subject) i,
      ];
      widgets.add(_GroupHeader(subject: subject, count: indexes.length));
      for (var local = 0; local < indexes.length; local++) {
        widgets.add(_buildDraftCard(indexes[local], local + 1));
      }
    }
    return widgets;
  }

  Widget _buildDraftCard(int index, int localIndex) {
    final draft = drafts[index];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                '第 $localIndex 项',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              // 类型标签：把「理解」的结果摆出来给学生看。
              // 内容为空时不显示 —— 那时推导出的是默认的「书面」，
              // 一个没有依据的标签摆出来会被当成识别结论。
              if (draft.titleController.text.trim().isNotEmpty)
                _KindChip(kind: HomeworkKind.of(draft.titleController.text)),
              const Spacer(),
              if (drafts.length > 1)
                IconButton(
                  onPressed: () => setState(() {
                    draft.dispose();
                    drafts.removeAt(index);
                  }),
                  icon: const Icon(
                    Icons.delete_outline,
                    color: AppColors.danger,
                  ),
                  tooltip: '删除这一项',
                ),
            ],
          ),
          DropdownButtonFormField<String>(
            initialValue: draft.subject,
            decoration: const InputDecoration(
              labelText: '科目',
              border: OutlineInputBorder(),
            ),
            items: _subjectOptions
                .map(
                  (subject) =>
                      DropdownMenuItem(value: subject, child: Text(subject)),
                )
                .toList(),
            onChanged: (value) => setState(
              () => draft.subject =
                  value ?? HomeworkItemNormalizer.unknownSubject,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: draft.titleController,
            maxLines: 2,
            onChanged: (value) {
              // 一改内容就重算默认耗时（学生手填过时不覆盖）——
              // 类型和题量都藏在标题里，「口算20题」改成「口算10题」
              // 时间还停在 15 分钟，这个数就没人会信了。
              draft.onTitleChanged();
              // 改过内容就撤掉「请核对」：学生已经看过这一条了，
              // 让它继续挂着只会稀释剩下那几条真正需要核对的提示。
              setState(() => draft.uncertain = false);
            },
            decoration: InputDecoration(
              labelText: '作业内容',
              hintText: '例如：背诵课文第3段、完成作文一篇',
              border: const OutlineInputBorder(),
              // 把「可疑」标在**具体这一条**上，而不是只说整页把握多少。
              // 一份清单有六条，一句「把握 90%」没法告诉学生该看哪一条；
              // 而实测里最典型的错误（把「静夜思」看成「静在恩」）恰恰是
              // 藏在某一条中间的两个字。
              suffixIcon: draft.uncertain
                  ? const Tooltip(
                      message: '这几个字模型没把握，请对着上面的原图看一眼',
                      child: Icon(
                        Icons.help_outline,
                        color: AppColors.warning,
                        size: 20,
                      ),
                    )
                  : null,
            ),
          ),
          // ⚠️ 编辑模式**不显示「预计耗时」**：服务端的可更新字段表
          // （`routes/homework.js` 的 `PATCH_SPEC`）里没有 `estimatedMinutes`，
          // 改了也发不出去 —— 而「界面上能改、保存后没生效」正是最该避免的
          // 那类静默失败。宁可先不给这个框，也不给一个假的。
          // （服务端放行它与放行标题是同一件事，但会牵出「分钟能不能是小数」
          // 这条口径：`toInt` 拒小数，而录入路径存的本来就是 `double`。）
          if (widget.editTarget == null) ...[
            const SizedBox(height: 10),
            TextField(
              controller: draft.estimatedController,
              keyboardType: TextInputType.number,
              // 手填过就不再被标题改动覆盖：系统给的是起点，
              // 学生自己知道的事优先级更高。
              onChanged: (value) => draft.estimateTouched = true,
              decoration: const InputDecoration(
                labelText: '预计耗时（分钟）',
                border: OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: 4),
          // 口径紧挨着耗时放，因为这两项是同一类东西：
          // 都是「系统按标题推的默认值，学生可以改」。
          NeedsGradingSwitch(
            value: draft.needsGrading,
            onChanged: (value) => setState(() {
              draft.needsGrading = value;
              // 记下「他自己定过」，之后再改标题就不覆盖了。
              draft.gradingTouched = true;
            }),
            note: draft.gradingTouched
                ? null
                : '默认按作业内容判断：${HomeworkKind.of(draft.titleController.text).label}类'
                      '${draft.needsGrading ? '需要批改' : '交照片就算完成，不判对错'}',
          ),
        ],
      ),
    );
  }

  Future<void> _saveAll() async {
    if (_saving) return;
    // 编辑单份：走掩码局部更新，不走新增。
    final target = widget.editTarget;
    if (target != null) {
      await _saveEdit(target);
      return;
    }
    final validDrafts = drafts
        .where((draft) => draft.titleController.text.trim().isNotEmpty)
        .toList();
    if (validDrafts.isEmpty) {
      Get.snackbar('无法保存', '请至少填写一项作业内容');
      return;
    }
    // 关面板要等到**落库回来之后**。
    //
    // 之前是不 await 就 `Navigator.pop`：列表上立刻就有了这批作业，
    // 而它们的 id 还是本地拼的，要等往返回来才被换成服务端那一行。
    // 用户在这段窗口里点进去提交，照片就会挂到服务端不认的键上 ——
    // 和「照片看不到」是同一个成因，只是窗口更窄、更难查。
    setState(() => _saving = true);
    await widget.controller.addHomeworks(
      validDrafts
          .map(
            (draft) => {
              'title': draft.titleController.text.trim(),
              'subject': draft.subject,
              'dueAt': widget.selectedDate,
              'estimatedMinutes':
                  double.tryParse(draft.estimatedController.text) ?? 30,
              // 显式带上，不靠 addHomeworks 那边按标题重推一道 ——
              // 学生**改过**的开关一旦在这里丢掉，就等于「他点了，但系统没听」。
              'needsGrading': draft.needsGrading,
            },
          )
          .toList(),
    );
    if (!mounted) return;
    Navigator.pop(context);
    Get.snackbar('保存成功', '已保存 ${validDrafts.length} 项作业');
  }

  /// 保存「修改作业」的结果。
  ///
  /// 与 [_saveAll] 分开，是因为两者的形状本来就不同：新增要**逐条落库并
  /// 等服务端把 id 发回来**（见 `StudentController.addHomeworks` 的说明），
  /// 编辑只打**一次掩码更新**（只带真正改过的字段）。
  Future<void> _saveEdit(HomeworkItem target) async {
    final draft = drafts.first;
    final title = draft.titleController.text.trim();
    if (title.isEmpty) {
      Get.snackbar('无法保存', '作业内容不能为空');
      return;
    }

    setState(() => _saving = true);
    final result = await widget.controller.updateHomeworkFields(
      homeworkId: target.id,
      title: title,
      subject: draft.subject,
      needsGrading: draft.needsGrading,
    );
    if (!mounted) return;
    setState(() => _saving = false);

    if (!result.ok) {
      // ⚠️ **失败时不关弹窗**。关掉就等于把学生刚改的那几个字连同弹窗一起
      // 丢掉 —— 而他明明看到了一次「保存」的动作，会以为已经改好了。
      // 「提示里说了失败、手上的东西却没了」比静默失败更让人绕不出来。
      Get.snackbar('保存失败', result.message);
      return;
    }
    Navigator.pop(context);
    Get.snackbar('已保存', result.message);
  }
}

/// 作业类型标签：「背诵」「口算」「书面」……
///
/// 存在的意义是把「系统看懂了这是件什么事」显示出来 ——
/// 顺带解释了「预计耗时」为什么是 10 分钟而不是默认的 30：
/// 一个没有理由的数字会被当成乱填，学生第一反应是去改它而不是信它。
///
/// 一视同仁地给所有类型都上标签（包括「书面」）：只给特殊类型上标签时，
/// 「没有标签」就同时意味着「书面」和「没认出来」，这两种情况的处置完全不同。
class _KindChip extends StatelessWidget {
  const _KindChip({required this.kind});

  final HomeworkKind kind;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        kind.label,
        style: const TextStyle(
          fontSize: 12,
          color: AppColors.textMuted,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 科目分组的小标题：「语文 · 2 项」。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.subject, required this.count});

  final String subject;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 8),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            subject,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 6),
          Text(
            '$count 项',
            style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// 识别用的原图缩略图。
///
/// 不是装饰：识别结果是否可靠，唯一的判断办法是对着原图看 ——
/// 「数学：资料第 8-9 页」认成「第 8-3 页」时，只有照片能发现。
class _SourcePhotoStrip extends StatelessWidget {
  const _SourcePhotoStrip({required this.photos});

  final List<HomeworkPhotoDraft> photos;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '识别用的原图（${photos.length} 张，点开可放大对照）',
          style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 64,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: photos.length,
            separatorBuilder: (context, index) => const SizedBox(width: 8),
            itemBuilder: (context, index) => GestureDetector(
              onTap: () => _preview(context, index),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  photos[index].bytes,
                  width: 64,
                  height: 64,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _preview(BuildContext context, int index) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black87,
        child: InteractiveViewer(
          child: Image.memory(photos[index].bytes, fit: BoxFit.contain),
        ),
      ),
    );
  }
}

/// 识别把握与漏认提醒。
///
/// 强调「认错比认不出更麻烦」是刻意的：学生很容易直接点「确认保存全部」，
/// 而认错的那一条会变成一项他真的照着做的作业。
class _RecognitionNotice extends StatelessWidget {
  const _RecognitionNotice({
    required this.confidence,
    required this.missedPhotoCount,
    this.uncertainCount = 0,
  });

  final double confidence;
  final int missedPhotoCount;

  /// 有几条被模型标了「有认不准的字」。见 `HomeworkOcrResult.uncertainCount`。
  final int uncertainCount;

  @override
  Widget build(BuildContext context) {
    // 整体把握偏低 —— 值得比「逐条对一下」更重的提醒，但**不构成丢弃的理由**。
    //
    // 2026-09-29 的实测给的教训：一张手抄清单照片上，模型四门课的科目全认对、
    // 结构违约 0 条，把握却稳定在 0.6~0.7。原来这条线同时兼任「丢不丢」的判据，
    // 于是这种照片整份被丢，学生看到的是「没能认出作业内容、建议重拍」——
    // 而重拍一百次结果一样（连拍 10 次，10 次都在 0.8 以下）。
    // 所以这里只负责「提醒多重」，「进不进表单」由 `isUsable` 单独回答。
    final lowConfidence = confidence < kOcrConfidenceFloor;

    final headline = [
      '识别把握 ${(confidence * 100).round()}%',
      if (lowConfidence) '这次偏低',
      if (missedPhotoCount > 0) '有 $missedPhotoCount 张照片没认出内容',
    ].join(' · ');

    // 有认不准的条目时，正文换成指名道姓的那一句。
    //
    // 原来只有一句泛泛的「对着原图核对一下每条内容」—— 实测下来这句不够：
    // 一份六条的清单里有两三个字认错，学生扫一遍根本发现不了，
    // 而模型自报的把握**照样在 0.9**（字迹从工整到潦草，它只从 0.98 掉到 0.9），
    // 所以「把握 90%」这个数字本身给不出任何提示。能给出提示的只有
    // 「哪几条要核对」，这就是 uncertain 标记存在的理由。
    // 三档，按「学生下一步要做什么」分：
    // · 有指名道姓的存疑条目 → 说清是哪几条（最具体，优先）
    // · 整体把握低 → 说清「内容认出来了，但要你逐条核」，
    //   ⚠️ 必须点明「已经认出来了」，否则学生会以为又失败了、去重拍
    // · 其余 → 泛泛提醒一句
    //
    // ⚠️ 措辞只说「把握低」，**不说**「可能认错了」：把握低不等于认错，
    // 说成认错会让本来正确的清单被学生整份重录一遍。
    final body = uncertainCount > 0
        ? '有 $uncertainCount 项模型说它没把握（已用 ⓘ 标出），逐字对着原图看一遍 —— '
              '认错比认不出更麻烦：认错的那些读起来是通顺的，不看原图发现不了。'
        : lowConfidence
        ? '内容已经认出来了，可以直接改。只是这次照片的字迹或光线不算好，'
              '模型的把握不高 —— 保存前请逐条对着上面的原图核一遍；'
              '科目认错了也能在每一条上直接改。'
        : '对着上面的原图核对一下每条内容；认错比认不出更麻烦。';

    // 把握低或有条目存疑时**加深底色并加描边**，让它在表单顶部一眼可见 ——
    // 原来只有「有存疑条目」会触发正文变化，整体把握低时这里长得很普通，
    // 于是「把握 66%」这行数字没人会停下来读。
    final emphasis = lowConfidence || uncertainCount > 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: emphasis ? 0.16 : 0.1),
        borderRadius: BorderRadius.circular(12),
        border: emphasis
            ? Border.all(color: AppColors.warning.withValues(alpha: 0.45))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.fact_check_outlined,
                size: 18,
                color: AppColors.warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  headline,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.warning,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: const TextStyle(
              fontSize: 11.5,
              color: AppColors.text,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeworkCard extends StatelessWidget {
  final HomeworkItem item;
  final List<HomeworkImageModel> images;

  /// 为空表示当前状态不允许提交（批改中）。已完成的作业非空 ——
  /// 走的是补充提交（`HomeworkItem.canSupplement`）。
  final VoidCallback? onSubmit;
  final VoidCallback onDeleteImages;

  /// 删除整份作业（含照片与它带出来的错题）。见 [_confirmDeleteHomework]。
  final VoidCallback onDelete;

  /// 改这份作业的科目 / 内容 / 要不要批改（见 [_editHomework]）。
  ///
  /// 存在的理由是识别会认错字：`练字一张` 被读成 `练习一张`，同一张图 25 次
  /// 里错 19 次，而「练习一张」读起来更顺，核对时人都会滑过去。核对表单里
  /// 能改，但点过「确认保存全部」之后，之前就只剩「删了重录」一条路。
  final VoidCallback onEdit;

  /// 打开全屏专注计时（见 `_openFocusTimer`）。
  final VoidCallback onStartTimer;

  const _HomeworkCard({
    required this.item,
    required this.images,
    required this.onSubmit,
    required this.onDeleteImages,
    required this.onDelete,
    required this.onEdit,
    required this.onStartTimer,
  });

  @override
  Widget build(BuildContext context) {
    final isResubmit = item.status == HomeworkStatus.needFix;
    // 补充提交：已完成（有结果）的作业追加附件。按钮要和首交/重交
    // 区分得开 —— 学生得知道自己点的不是「从头再来」。
    final isSupplement = item.status == HomeworkStatus.finished;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  item.title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              HomeworkStatusChip(status: item.status),
              // 删除入口收进溢出菜单，**刻意不摆成第二颗红色图标**：
              // 底部那颗红的已经是「删除照片」（删错了还能重拍），
              // 两个红图标并排时点错一次没掉的是**整份作业**（连它带出的错题）。
              _buildOverflowMenu(item),
            ],
          ),
          const SizedBox(height: 10),
          _InfoLine(
            icon: Icons.menu_book_outlined,
            text: item.subject.isEmpty ? '未填写科目' : item.subject,
          ),
          // 这里原来有一行「截止 9月28日 22:56」（超时时标红）。
          // 删掉的理由不是「太挤」，是那个时间**不是任何人定的** ——
          // 它取的是打开作业页那一刻，标红则进一步把它说成「你迟到了」。
          // 列表本来就按天过滤，学生不需要再被告知一遍这是哪一天。
          // 见 `doc/open-items.md` B26。
          _InfoLine(
            icon: Icons.hourglass_bottom,
            text: '预计 ${item.estimatedMinutes.toInt()} 分钟',
          ),
          // 实际用时只在**计过时**之后出现。始终显示一行「实际用时 0 秒」
          // 会让没计时的作业看起来像「计时坏了」，而它只是还没开始。
          if (item.hasActualTime)
            _InfoLine(
              icon: Icons.timer_outlined,
              text: '实际用时 ${formatStudyTime(item.actualSeconds)}',
            ),
          const SizedBox(height: 10),
          FocusTimerEntry(
            targetId: item.id,
            hasRecordedTime: item.hasActualTime,
            onTap: onStartTimer,
          ),
          if (item.hasSubmission) ...[
            const SizedBox(height: 10),
            _SubmissionBanner(
              item: item,
              attachmentText: attachmentSummary(images),
            ),
          ],
          if (images.isNotEmpty) ...[
            const SizedBox(height: 10),
            HomeworkImageGrid(images: images, thumbnailSize: 74),
          ],
          if (item.hasResult) ...[
            const SizedBox(height: 10),
            _AiResultBox(item: item),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              if (onSubmit != null)
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: onSubmit,
                    icon: Icon(
                      isResubmit
                          ? Icons.refresh
                          : isSupplement
                          ? Icons.add_photo_alternate_outlined
                          : Icons.upload_file_outlined,
                    ),
                    label: Text(
                      isResubmit
                          ? '更正后重新提交'
                          : isSupplement
                          ? '补充提交'
                          : '提交作业',
                    ),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size.fromHeight(42),
                      backgroundColor: isResubmit
                          ? AppColors.warning
                          : AppColors.primary,
                      foregroundColor: Colors.white,
                    ),
                  ),
                )
              else if (item.status == HomeworkStatus.checking)
                const Expanded(
                  child: Row(
                    children: [
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 10),
                      Text(
                        'AI 正在批改…',
                        style: TextStyle(color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
              // 没有 else：pending/needFix 走 canSubmit 的按钮、finished 走
              // canSupplement 的「补充提交」，checking 走上面的转圈 ——
              // 四个状态全覆盖。原 else 那块写着「已完成，无需再提交」，
              // 在补交放开后它既是死代码又撒谎（已完成恰恰可以再提交）。
              if (images.isNotEmpty) ...[
                const SizedBox(width: 8),
                IconButton(
                  onPressed: onDeleteImages,
                  icon: const Icon(Icons.delete_outline),
                  color: AppColors.danger,
                  tooltip: '删除作业附件',
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 卡片右上角的溢出菜单（当前只有「删除这份作业」一项）。
  ///
  /// 用一个菜单、而不是再加一颗图标：删除是低频且**不可逆**的动作，
  /// 摆成显式按钮之后它与「删除照片」在视觉上就等价了，
  /// 而两者的代价差一个量级（照片还能重拍，作业连错题一起没）。
  Widget _buildOverflowMenu(HomeworkItem item) {
    // 「批改中」不给删除动作。那次批改回来时会按作业 id 写回结果，
    // 而作业已经不在了 —— 服务端回 403，又被写路径的 `_safePersist` 吞掉，
    // 于是界面显示「已批改」而库里什么都没有（静默失败那一族）。
    final busy = item.status == HomeworkStatus.checking;
    return PopupMenuButton<String>(
      tooltip: '更多操作',
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_vert, size: 20),
      onSelected: (value) {
        if (value == 'edit') onEdit();
        if (value == 'delete') onDelete();
      },
      itemBuilder: (menuContext) => [
        // 编辑**不跟随 `busy`**：批改回来时是按作业 id 写结果的，而编辑改的是
        // 标题/科目，行还在、id 没变。与删除的风险不是一类（删除会让那次写回
        // 找不到行），所以没必要把它一起灰掉。
        const PopupMenuItem<String>(
          value: 'edit',
          child: Text('修改科目或内容'),
        ),
        PopupMenuItem<String>(
          value: 'delete',
          enabled: !busy,
          // 灰掉的项必须说明原因，否则看起来像「这个功能坏了」。
          height: busy ? 62 : 48,
          child: busy
              ? const Text(
                  '正在批改，等批改结束再删',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                )
              : const Text('删除这份作业'),
        ),
      ],
    );
  }
}

/// 提交状态横幅：家长端最关心的「交了没有、什么时候交的、交了什么」。
class _SubmissionBanner extends StatelessWidget {
  const _SubmissionBanner({required this.item, required this.attachmentText});

  final HomeworkItem item;

  /// 附件摘要（「2 张照片 · 1 个视频」），空串表示没有附件。
  final String attachmentText;
  @override
  Widget build(BuildContext context) {
    // 不会批改的作业要说一句「为什么」。否则学生交完只看得到一个「已完成」，
    // 过两天翻回来会以为系统漏批了 —— 而他没有任何线索能自己判断出来。
    final mode = item.gradingMode;
    final gradingNote = switch (mode) {
      HomeworkGradingMode.auto => null,
      HomeworkGradingMode.notRequired =>
        '这类作业交上来就算完成，不需要批改',
      HomeworkGradingMode.unavailable => '当前未开启 AI 批改，本次只记录提交',
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.check_circle,
                size: 18,
                color: AppColors.success,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  attachmentText.isEmpty
                      ? '已于 ${_formatDateTime(item.submittedAt!)} 提交（未上传附件）'
                      : '已于 ${_formatDateTime(item.submittedAt!)} 提交 · $attachmentText',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.success,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (gradingNote != null) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.info_outline,
                    size: 13,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      gradingNote,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AiResultBox extends StatelessWidget {
  const _AiResultBox({required this.item});

  final HomeworkItem item;

  @override
  Widget build(BuildContext context) {
    final hasMistakes = item.wrongCount > 0;
    final accent = hasMistakes ? AppColors.danger : AppColors.success;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, size: 16, color: AppColors.primary),
              const SizedBox(width: 6),
              if (item.score != null)
                Text(
                  'AI 得分 ${item.score}',
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              const Spacer(),
              if (hasMistakes)
                // 可点：直接进「这次作业的错题」。
                // 原来这里是纯文字 —— 学生看到「错了 3 道」却没有下一步动作，
                // 只能自己绕到复习页去翻历次作业的错题。
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => Get.to(
                      () => HomeworkMistakesPage(
                        homeworkId: item.id,
                        homeworkTitle: item.title,
                      ),
                    ),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(8, 3, 4, 3),
                      decoration: BoxDecoration(
                        color: AppColors.danger.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '错题 ${item.wrongCount} 道',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppColors.danger,
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right,
                            size: 15,
                            color: AppColors.danger,
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else
                const Text(
                  '全部正确',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.success,
                  ),
                ),
            ],
          ),
          if (item.summary.isNotEmpty) ...[
            const SizedBox(height: 6),
            // 学生自己也可能在一个月后才回来看这条结果，
            // 那时「这次是模板」和「这次是模型」在他眼里没有区别。
            if (item.gradedLocally) ...[
              const LocalGradingChip(),
              const SizedBox(height: 6),
            ],
            // 批改总结是模型写的，里面会带 `$...$` 的算式
            // （「第二空列式错误：当 $x>20$ 时…」）。
            MathText(
              item.summary,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.text,
                height: 1.55,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  // `valueColor` 参数已删（2026-09-28）：它唯一的用途是给「截止 …」那行标红，
  // 而那行不再显示。留着它会让人以为还有地方在标红。
  const _InfoLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppColors.textMuted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${local.month}月${local.day}日 ${two(local.hour)}:${two(local.minute)}';
}

/// 首页（作业页）顶部的今日学习计划打卡提示条，点击跳转计划页
class _TodayPlanCheckinBanner extends StatelessWidget {
  const _TodayPlanCheckinBanner({required this.controller});

  final StudentController controller;

  @override
  Widget build(BuildContext context) {
    final pending = controller.todayPendingCheckinCount;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => controller.currentTabIndex.value = 3,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.warning.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
          ),
          child: Row(
            children: [
              const Icon(Icons.fact_check, color: AppColors.warning),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '今天有 $pending 个学习计划待打卡，去完成',
                  style: const TextStyle(
                    color: AppColors.warning,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.warning),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「没认出来」这一个弹窗的三段文案 + 该给哪几个按钮。
///
/// 抽成一个值对象，是为了让「说什么」和「能做什么」挨着写：
/// 未登录时不该出现「重拍一张」（重拍解决不了），
/// 而照片糊了时不该出现「去登录」（登录解决不了）。
/// 两者分开写就很容易对不上 —— 那正是原来那句误导提示的成因。
class _UnrecognizedCopy {
  const _UnrecognizedCopy({
    required this.title,
    required this.reason,
    required this.advice,
    required this.offerRetry,
    this.offerLogin = false,
  });

  final String title;
  final String reason;
  final String advice;

  /// 是否给「重拍一张」。照片/内容的问题才给。
  final bool offerRetry;

  /// 是否给「去登录」。只有「身份缺失」这一种成因才给。
  final bool offerLogin;
}

