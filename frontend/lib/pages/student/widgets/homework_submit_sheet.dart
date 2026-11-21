import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';

import '../../../constants/app_colors.dart';
import '../../../constants/attachment_limits.dart';
import '../../../controllers/student_controller.dart';
import '../../../models/homework_image_model.dart';
import '../../../models/homework_model.dart';
import '../../../models/homework_photo_draft.dart';
import '../../../services/image_storage_service.dart';
import '../../../services/lost_photo_recovery.dart';
import '../../../utils/attachment_summary.dart';
import '../../../widgets/attachment_player.dart';
import '../../../widgets/homework_image_viewer.dart';
import '../../../widgets/needs_grading_switch.dart';

/// 学生提交作业面板。
///
/// 设计要点：
/// - 「拍照/选图」和「提交」是同一次动作。旧实现把它拆成两个按钮，
///   结果「上传了图片」被当成「已提交」，而提交按钮又完全不看图片。
/// - 允许无照片提交：背诵、朗读这类作业本来就没有书面材料。
/// - 提交前可以预览、逐张删除，避免把拍糊的照片交上去。
Future<void> openHomeworkSubmitSheet({
  required BuildContext context,
  required StudentController controller,
  required HomeworkItem homework,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) =>
        _HomeworkSubmitSheet(controller: controller, homework: homework),
  );
}

/// 单次提交的照片张数上限。
///
/// ⚠️ **数字不在这里** —— 它来自 [AttachmentLimits] 那张唯一的表。原先这里
/// 硬编码 6，而口径早就改成了 9：这类「同一件事的第二处副本」不会报错，
/// 只会表现为「界面上明明可以选 9 张，选第 7 张时被静默丢掉」。
///
/// 从 `const` 降级为 `final` 只是语法需要（常量映射取值不是编译期常量），
/// 值仍然是启动时就定死的。
final int kMaxPhotosPerSubmission = AttachmentLimits.maxCountOf(
  AttachmentKind.image,
);

class _HomeworkSubmitSheet extends StatefulWidget {
  const _HomeworkSubmitSheet({
    required this.controller,
    required this.homework,
  });

  final StudentController controller;
  final HomeworkItem homework;

  @override
  State<_HomeworkSubmitSheet> createState() => _HomeworkSubmitSheetState();
}

class _HomeworkSubmitSheetState extends State<_HomeworkSubmitSheet> {
  final List<HomeworkPhotoDraft> _picked = [];
  bool _submitting = false;

  /// 这次要不要批改。初值取作业上存的那份（录入时定的），
  /// 学生在这里可以改 —— 这是最后一次确认的机会，而他自己最清楚
  /// 今天交上来的到底是不是「要对错的东西」。
  ///
  /// `late` 而非在 `initState` 里赋值：初值来自 [_homework]，
  /// 而它在面板打开后才从 controller 取到最新的一份。
  late bool _needsGrading = _homework.needsGrading;

  HomeworkItem get _homework =>
      widget.controller.homeworkById(widget.homework.id) ?? widget.homework;

  /// 按**当前开关状态**算口径，而不是按作业上存的那份 ——
  /// 学生刚把开关关掉，上面的标签还写着「提交后 AI 批改」就自相矛盾了。
  HomeworkGradingMode get _mode => HomeworkGradingMode.of(
    needsGrading: _needsGrading,
    aiEnabled: _homework.aiEnabled,
  );

  bool get _isResubmission => _homework.status == HomeworkStatus.needFix;

  /// 补充提交：作业已完成（有结果），学生要追加漏交的附件。
  /// 与 needFix 的重交不是一回事 —— 这里必须明说「会重新批改、
  /// 旧结果被覆盖」，因为旧结果里有他已经看过的分数。
  bool get _isSupplement => _homework.status == HomeworkStatus.finished;

  @override
  void initState() {
    super.initState();
    _recoverLostPhotos();
  }

  /// 面板一打开，先试着取回「上次拍照途中被系统回收」的照片。
  ///
  /// 恢复点为什么放在这里：学生被中断后重新打开的一定是同一份作业的提交面板
  /// ——他的目标就是把这份作业交上去。所以不需要把「当时在交哪份作业」持久化
  /// 下来再自动导航过去：那要多一套状态和一个突兀的自动跳转，而学生自己的
  /// 行为路径本来就回到了正确位置。
  ///
  /// 拿到之后必须**明确告诉他**，不能悄悄塞进列表：列表上突然多出几张照片
  /// 而没说明来历，比照片丢了更让人困惑。
  Future<void> _recoverLostPhotos() async {
    final files = await LostPhotoRecovery.instance.takeLostPhotos();
    if (files.isEmpty || !mounted) return;

    final drafts = <HomeworkPhotoDraft>[];
    for (final file in files) {
      // 单张读失败不该让整批都丢掉 —— 能救回几张是几张。
      try {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) continue;
        drafts.add(HomeworkPhotoDraft.photo(fileName: file.name, bytes: bytes));
      } catch (error) {
        debugPrint('读回丢失照片失败，跳过这一张：$error');
      }
    }
    if (drafts.isEmpty || !mounted) return;

    setState(() {
      // 找回的是**照片**，所以按照片名额算 —— 不能用 `_picked.length`：
      // 那里面可能已经有学生选好的音频/视频。
      final room = kMaxPhotosPerSubmission - _countOf(AttachmentKind.image);
      if (room <= 0) return;
      _picked.addAll(drafts.take(room));
    });
    Get.snackbar('已找回照片', '上次拍摄的照片还在，已经放进待提交列表');
  }

  /// 之前已入库的照片。只用于显示「已提交 N 张」与缩略图网格，
  /// 因此直接拿已落库的记录即可，不需要把字节读进内存。
  List<HomeworkImageModel> get _existing =>
      widget.controller.imagesOfHomework(_homework.id);

  /// 本次已选的附件，按类型统计。
  ///
  /// ⚠️ 三类**各自计数**，所以这个文件里任何地方都不能再拿
  /// `_picked.length` 当「照片张数」用 —— 那会把一段录音算成一张照片，
  /// 表现为「只选了 3 张照片却说已经满了」。这种 bug 不报错，
  /// 只让上限提前生效。
  Map<AttachmentKind, int> get _pickedCounts {
    final out = <AttachmentKind, int>{};
    for (final draft in _picked) {
      final kind = draft.kind;
      if (kind == null) continue;
      out[kind] = (out[kind] ?? 0) + 1;
    }
    return out;
  }

  int _countOf(AttachmentKind kind) => _pickedCounts[kind] ?? 0;

  /// 「本次提交的附件」那行标题：**按类型分别说**，不混成一个总数。
  ///
  /// 混着说的后果是「本次提交的附件（4）」让人以为照片有 4 张 ——
  /// 而三类各有各的上限，学生需要一眼看出**每一项**还剩几个名额。
  String get _pickedSummaryTitle {
    final parts = <String>[];
    for (final kind in AttachmentKind.values) {
      final n = _countOf(kind);
      if (n > 0) parts.add('$n ${kind.unit}${kind.label}');
    }
    if (parts.isEmpty) return '本次提交的附件';
    return '本次提交的附件（${parts.join('、')}）';
  }

  /// 「添加音频 2/3」—— 把**已用几个**写在按钮上。
  ///
  /// 不写的话，学生要等到点下去之后才知道名额满了，而那一次操作已经白做。
  String _mediaButtonLabel(AttachmentKind kind) {
    final used = _countOf(kind);
    if (used == 0) return '添加${kind.label}';
    return '添加${kind.label} $used/${AttachmentLimits.maxCountOf(kind)}';
  }

  /// 选音频 / 视频。
  ///
  /// 走系统文件选择器而不是相机：它们本来就不是「拍」出来的 ——
  /// 朗读录音在录音机里、讲解视频在相册里。逼学生在这个面板里重录一遍，
  /// 结果就是他放弃交这个附件。
  Future<void> _pickMedia(AttachmentKind kind) async {
    if (_submitting) return;
    final limit = AttachmentLimits.maxCountOf(kind);
    if (_countOf(kind) >= limit) {
      Get.snackbar('提示', '单次最多 $limit 个${kind.label}');
      return;
    }
    try {
      // ⚠️ `file_picker` 13.x 是**静态方法** `pickFile`，没有
      //    `FilePicker.platform`；`PlatformFile` 也不再带 `bytes` 字段，
      //    要 `readAsBytes()`。旧版写法（`.platform.pickFiles(withData: true)`）
      //    在 13.x 上直接编不过 —— 2026-10-03 的 analyze 就是这么暴露的。
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: AttachmentLimits.extensionsOf(kind),
      );
      if (file == null) return;

      final maxBytes = AttachmentLimits.maxBytesOf(kind);
      // 先按系统报的体积挡一道，**再**读进内存：一个 2GB 的视频不该先被
      // 读进 RAM 才被告知太大。拿不到长度时跳过这道预检，读完再判 ——
      // 预检失败不能让「能不能传」这件事变得不确定。
      final declared = file.lengthSync();
      if (declared != null && declared > maxBytes) {
        Get.snackbar(
          '文件太大',
          _tooLargeText(file.name, declared, kind, maxBytes),
        );
        return;
      }

      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return;
      if (bytes.length > maxBytes) {
        Get.snackbar(
          '文件太大',
          _tooLargeText(file.name, bytes.length, kind, maxBytes),
        );
        return;
      }

      // 类型推不出来就不收，并**说清是哪一步不行**。悄悄丢掉会让
      // 「选了却没出现」变成一个查不出的问题。
      final mime = _mimeOfPickedFile(file, kind);
      if (mime == null) {
        Get.snackbar('无法识别', '认不出 ${file.name} 的格式，请换一个文件试试。');
        return;
      }

      setState(() {
        _picked.add(
          HomeworkPhotoDraft(
            fileName: file.name,
            bytes: bytes,
            mimeTypeOverride: mime,
          ),
        );
      });
    } catch (error) {
      Get.snackbar('选择失败', '无法读取文件：$error');
    }
  }

  /// 定一个附件的 MIME：按文件名后缀推，且必须与 [kind] **一致**。
  ///
  /// 后缀 → MIME 只有 `AttachmentLimits` 那一处规则，这里不另写一份。
  /// `PlatformFile.extension` 不带点，而 `mimeOfFileName` 要带点。
  ///
  /// 推出来与 [kind] 不一致时返回 **null**（宁可拒绝）：服务端按 MIME
  /// 归类，它会落进**另一个**配额 —— 而界面上算的是这一个。两边口径
  /// 不同时，症状是「明明没超，提交却被拒」。
  String? _mimeOfPickedFile(PlatformFile file, AttachmentKind kind) {
    final ext = file.extension;
    final byExt = (ext == null || ext.isEmpty)
        ? null
        : AttachmentLimits.mimeOfFileName('x.$ext');
    final candidate = byExt ?? AttachmentLimits.mimeOfFileName(file.name);
    if (candidate == null) return null;
    return AttachmentKind.ofMime(candidate) == kind ? candidate : null;
  }

  /// 「太大了」那句话。预检与实测两处共用 —— 分开写就会有一处先漂，
  /// 而它们说的是同一件事，用户不该看到两种说法。
  String _tooLargeText(
    String name,
    int size,
    AttachmentKind kind,
    int maxBytes,
  ) =>
      '$name 有 ${AttachmentLimits.humanSize(size)}，'
      '${kind.label}最多 ${AttachmentLimits.humanSize(maxBytes)}，请压缩后再上传。';

  Future<void> _pick(ImageSource source) async {
    if (_submitting) return;
    final picker = ImagePicker();
    try {
      final List<XFile> files;
      if (source == ImageSource.gallery) {
        files = await picker.pickMultiImage(imageQuality: 85, maxWidth: 2048);
      } else {
        // 相机一次只能拍一张，且必须只调用一次 pickImage：
        // 调用两次会让相机弹两次，第二次取消时强解包会直接崩掉。
        final shot = await picker.pickImage(
          source: source,
          imageQuality: 85,
          maxWidth: 2048,
        );
        files = shot == null ? const <XFile>[] : <XFile>[shot];
      }
      if (files.isEmpty) return;

      final drafts = <HomeworkPhotoDraft>[];
      for (final file in files) {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) continue;
        drafts.add(HomeworkPhotoDraft.photo(fileName: file.name, bytes: bytes));
      }
      if (drafts.isEmpty) return;

      setState(() {
        // 按照片**自己**的名额算，并且溢出时只挤掉图片。
        //
        // ⚠️ 原来这里是 `_picked.clear()` —— 只有照片的时候无害，现在它
        // 会把学生已经选好的录音、视频一起丢掉，而它们与照片名额无关。
        // 这种「删了不相干的东西」不会报错，只会让人以为文件没选上。
        final pickedImages = _countOf(AttachmentKind.image);
        final room = kMaxPhotosPerSubmission - pickedImages;
        if (room <= 0) {
          _picked.removeWhere((draft) => draft.kind == AttachmentKind.image);
          _picked.addAll(drafts.take(kMaxPhotosPerSubmission));
        } else {
          _picked.addAll(drafts.take(room));
        }
      });

      if (drafts.length > kMaxPhotosPerSubmission) {
        Get.snackbar(
          '提示',
          '单次最多提交 $kMaxPhotosPerSubmission 张照片，已保留前 $kMaxPhotosPerSubmission 张',
        );
      }
    } catch (error) {
      Get.snackbar('选择失败', '无法读取图片：$error');
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);

    // 先抓住面板自己的 route 和 navigator。两件事都在 `await` 之前做：
    // 一是回来之后 context 可能已经失效；二是**面板可能已经被学生自己关掉**，
    // 那时 `canPop()` 仍然是 true，直接 pop 会把学生页弹出去。
    final sheetRoute = ModalRoute.of(context);
    final navigator = Navigator.of(context);

    final result = await widget.controller.submitHomework(
      homeworkId: _homework.id,
      photos: _picked,
      // 显式带上学生这次的选择：只在界面上改而不落库的话，
      // 他下次进来会看到系统把「不用批」又改回了「要批」。
      needsGrading: _needsGrading,
    );

    final webFailed = LocalImageStorageService.lastWebPersistFailed;
    if (!mounted) return;
    setState(() => _submitting = false);

    if (!result.ok) {
      // 失败**不关面板**：照片还在里面，关掉等于让他重拍一遍。
      Get.snackbar('提交失败', result.message);
      return;
    }

    // 成功才关面板。这里原来写的是 `if (Get.isBottomSheetOpen ?? false) Get.back();`
    // —— 但这个面板是 **Flutter 原生 `showModalBottomSheet`** 开的，不是
    // `Get.bottomSheet`，`Get.isBottomSheetOpen` 恒为 false，所以那行**从来没执行过**。
    // 现象是：学生点了「确认提交」、看到「提交成功」，面板却还敞着，他以为没交上，
    // 于是再点一次 —— 而第二次会把同一批照片**重复入库**。
    // 教训：用哪个导航栈开的 route，就用哪个关；别问一个不负责这件事的中间层。
    if (sheetRoute != null && sheetRoute.isCurrent) navigator.pop();

    if (webFailed) {
      // 不能假装成功：浏览器存储写不进去，照片刷新后会消失
      Get.snackbar(
        '已提交，但照片未能保存',
        '当前浏览器存储空间不足，照片本次可以查看，刷新页面后会丢失。'
            '建议减少照片数量或在桌面端使用。',
        duration: const Duration(seconds: 6),
      );
      return;
    }
    Get.snackbar('提交成功', result.message);
  }

  @override
  Widget build(BuildContext context) {
    final homework = _homework;
    final existing = _existing;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _isResubmission
                          ? '更正后重新提交'
                          : _isSupplement
                          ? '补充提交'
                          : '提交作业',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    // 这个面板由 `showModalBottomSheet` 打开，就按它所在的
                    // 导航栈关 —— 和 `_submit` 里的道理一样，别混两套导航。
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    tooltip: '关闭',
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      homework.title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      // 原先这里还跟着「· 截止：9月28日 22:56」。
                      // 删掉的理由：那个时间取的是打开作业页那一刻，
                      // 不是学生定过的期限 —— 见 `doc/open-items.md` B26。
                      '科目：${homework.subject.isEmpty ? '未填写' : homework.subject}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _MiniTag(
                          label: switch (_mode) {
                            HomeworkGradingMode.auto => '提交后 AI 批改',
                            HomeworkGradingMode.notRequired => '无需批改',
                            HomeworkGradingMode.unavailable => 'AI 批改未开启',
                          },
                          color: _mode.willGrade
                              ? AppColors.primary
                              : AppColors.textMuted,
                        ),
                        if (existing.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          _MiniTag(
                            label: '已提交 ${attachmentSummary(existing)}',
                            color: AppColors.success,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (_isResubmission) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 18,
                        color: AppColors.warning,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '这是第二次提交，之前提交的照片会保留，方便家长对比改正前后。',
                          style: TextStyle(fontSize: 12, color: AppColors.text),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (_isSupplement) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 18,
                        color: AppColors.primary,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '这次是补充提交：之前提交的附件会保留，'
                              '提交后会对全部附件重新批改，旧的分数和错题会被新结果替换。',
                          style: TextStyle(fontSize: 12, color: AppColors.text),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              // 批改口径放在照片之前：它会影响学生拍几张 ——
              // 不需要批改的作业拍一张留档就够了，而要批的卷子得页页拍全。
              const SizedBox(height: 8),
              NeedsGradingSwitch(
                value: _needsGrading,
                onChanged: (value) => setState(() => _needsGrading = value),
                note: switch ((_needsGrading, homework.aiEnabled)) {
                  (false, _) => '只留档，不给对错结论；家长仍能看到你提交的附件',
                  (true, false) => '当前未开启 AI 批改，这次实际上不会批改',
                  (true, true) => null,
                },
              ),
              const SizedBox(height: 8),
              if (existing.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  '已提交的照片（${existing.length} 张）',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                HomeworkImageGrid(
                  images: widget.controller.imagesOfHomework(homework.id),
                  thumbnailSize: 78,
                ),
              ],
              const SizedBox(height: 16),
              Text(
                _pickedSummaryTitle,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              if (_picked.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: AppColors.border,
                      style: BorderStyle.solid,
                    ),
                  ),
                  child: const Column(
                    children: [
                      Icon(
                        Icons.attach_file,
                        size: 28,
                        color: AppColors.textMuted,
                      ),
                      SizedBox(height: 6),
                      Text(
                        '还没有选择附件（照片、音频、视频都可以）',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                )
              else
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (var i = 0; i < _picked.length; i++)
                      _DraftThumbnail(
                        draft: _picked[i],
                        onRemove: _submitting
                            ? null
                            : () => setState(() => _picked.removeAt(i)),
                        onPreview: () => _previewDrafts(i),
                      ),
                  ],
                ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _submitting
                          ? null
                          : () => _pick(ImageSource.camera),
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('拍照'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _submitting
                          ? null
                          : () => _pick(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('相册多选'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 音频与视频单独一行：它们走**另一条上传通道**（对象存储直传），
              // 与照片不是同一件事；混在一行里会让人以为点「相册多选」
              // 也能选到视频。
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _submitting
                          ? null
                          : () => _pickMedia(AttachmentKind.audio),
                      icon: const Icon(Icons.mic_none_outlined),
                      label: Text(_mediaButtonLabel(AttachmentKind.audio)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _submitting
                          ? null
                          : () => _pickMedia(AttachmentKind.video),
                      icon: const Icon(Icons.videocam_outlined),
                      label: Text(_mediaButtonLabel(AttachmentKind.video)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                // 这里要顺手告诉学生「这个开关存在」：他多半是照着
                // 老师布置的原话录进来的，不会自己想到去关掉批改。
                switch (_mode) {
                  HomeworkGradingMode.auto =>
                    '朗读、背诵、默写、抄写这类作业交照片就算完成，'
                        '可以把上面的批改开关关掉。',
                  HomeworkGradingMode.notRequired =>
                    '这次只留档、不判对错；朗读、背诵这类不传照片也可以提交。',
                  HomeworkGradingMode.unavailable => '当前未开启 AI 批改，本次提交只作记录。',
                },
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _submitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    backgroundColor: _isResubmission
                        ? AppColors.warning
                        : AppColors.primary,
                    foregroundColor: Colors.white,
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          // 按**这次的开关**说，不是按作业上存的那份：
                          // 学生刚关掉批改，按钮还写着「开始 AI 批改」
                          // 会让他以为自己点错了。
                          _mode.willGrade ? '提交并开始 AI 批改' : '确认提交',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _previewDrafts(int index) {
    final draft = _picked[index];
    final kind = draft.kind;
    // 类型推不出来 = 它压根进不了 [_picked]（见 `_pickMedia`）。这里是
    // 一道防御性收口，而不是一个正常会走到分支。
    if (kind == null) return;
    // 尚未入库的附件没法走 HomeworkImageGrid（它按 HomeworkImageModel
    // 读字节），所以直接交给播放器：图片放大、音频出声、视频出画面 ——
    // 与已提交附件的观感是同一套。
    //
    // ⚠️ 原来这里对**任何**字节都调 `Image.memory`。加上音视频之后，
    //    那个写法会在点开一段录音时抛解码异常 —— 不是「显示不出来」，
    //    而是整块面板炸掉。
    //
    // ⚠️ 草稿还没有服务端 id ⇒ 签不出直读地址，只能走「字节」那条。
    //    音频/视频在原生平台上会先把字节落盘成 `file:` 再播，所以同样
    //    不经 just_audio 的本地明文代理（那条路在 targetSdk >= 28 上
    //    打不开，见 `attachment_player.dart` 的 `_AudioBody`）。
    unawaited(
      openAttachmentPlayer(
        context: context,
        title: draft.fileName,
        kind: kind,
        bytes: draft.bytes,
        mimeType: draft.mimeType,
      ),
    );
  }
}

/// 已入库照片的草稿态视图不再需要额外的中间类型，
/// 直接复用 [HomeworkImageGrid]。
class _DraftThumbnail extends StatelessWidget {
  const _DraftThumbnail({
    required this.draft,
    required this.onPreview,
    this.onRemove,
  });

  final HomeworkPhotoDraft draft;
  final VoidCallback onPreview;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        GestureDetector(
          onTap: onPreview,
          child: Container(
            width: 78,
            height: 78,
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: _draftThumbContent(draft),
          ),
        ),
        Positioned(
          right: -6,
          top: -6,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: const BoxDecoration(
                color: AppColors.danger,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}

/// 一个待提交附件的缩略图内容。
///
/// ⚠️ **只有图片**能交给 `Image.memory`。把一段音频/视频的字节喂进去不会
/// 「显示不出来」，而是**抛异常** —— 解码器拿到的东西根本不是图。
/// 之前这里只有照片，所以那行是对的；加上音视频之后它就成了一个
/// 「选了音频就白屏」的坑，而白屏不会告诉你原因。
Widget _draftThumbContent(HomeworkPhotoDraft draft) {
  final kind = draft.kind;
  if (kind == AttachmentKind.image) {
    return Image.memory(draft.bytes, fit: BoxFit.cover);
  }
  return Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(
        kind == AttachmentKind.video ? Icons.videocam : Icons.audiotrack,
        size: 26,
        color: AppColors.primary,
      ),
      const SizedBox(height: 2),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          AttachmentLimits.humanSize(draft.bytes.length),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, color: AppColors.textMuted),
        ),
      ),
    ],
  );
}

class _MiniTag extends StatelessWidget {
  const _MiniTag({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// 这个文件里原有一个 `_formatDateTime`，只服务于面板标题上的
// 「· 截止：9月28日 22:56」。那半句删掉后它就没有引用了，一并删除 ——
// 留一个没人调的时间格式化函数，只会让人以为界面上还有地方在显示时间。
