import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';

import '../../constants/app_colors.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/review_controller.dart';
import '../../models/review_model.dart';
import '../../services/image_storage_service.dart';
import 'review_summary_page.dart';

/// 回传批改页：**逐题标记对错 →（可选）录入卷面答案 →（可选）拍照留档 → 提交批改**。
///
/// 判定口径写在这里，是因为它决定了「这道题算不算过」：
/// - 填了答案 → 由 AI 按快照的参考答案判定，证据渠道记为「纸质卷 · AI 判定」；
/// - 没填答案 → 按学生自评处理，渠道记为「纸质卷 · 自评」。
///
/// 两者都会写入 `review_attempt`，**毕业判定只看证据、不看走了哪条路**。
/// 之所以保留「不填答案也能过」，是因为线下卷子上早已写满了过程，
/// 强迫学生把每一步再敲一遍，只会让人放弃回传这一步 —— 闭环就断在这里。
class ReviewCheckPage extends StatefulWidget {
  const ReviewCheckPage({super.key, required this.paperId});

  final String paperId;

  @override
  State<ReviewCheckPage> createState() => _ReviewCheckPageState();
}

class _ReviewCheckPageState extends State<ReviewCheckPage> {
  final ReviewController controller = Get.find<ReviewController>();
  final ImageStorageService _images = createImageStorage();

  final Map<String, PaperItemResult> _results = {};
  final Map<String, String> _photos = {};
  final Map<String, TextEditingController> _answers = {};

  List<ReviewPaperItem> _items = const [];
  bool _loading = true;
  bool _submitting = false;
  bool _showKey = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final editor in _answers.values) {
      editor.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final items = await controller.openPaper(widget.paperId);
    for (final item in items) {
      _answers[item.id] = TextEditingController(text: item.studentAnswer);
      if (item.result != PaperItemResult.pending) _results[item.id] = item.result;
      if (item.photoPath.isNotEmpty) _photos[item.id] = item.photoPath;
    }
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  /// 拍一道题的作答过程留档。
  ///
  /// 这里**刻意不做丢失照片恢复**（对比 LostPhotoRecovery 在提交面板里的用法）：
  /// 能恢复回来的只是一张 XFile，而「它属于哪一道题」这个信息在进程被回收时
  /// 已经丢了（`item.id` 是内存里的对象，没落盘）。硬猜一个题号挂上去，
  /// 等于把证据放错位置 —— 学生重拍一张的代价是几秒钟，挂错题的代价是
  /// 家长看到一份不属于这道题的「作答证据」。
  Future<void> _pickPhoto(ReviewPaperItem item) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(sheetContext, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(sheetContext, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    try {
      // 相机一次只能拍一张：pickImage 只调一次。
      // 调两次会让相机弹两次，第二次取消时强解包会直接崩。
      final file = await ImagePicker().pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 2048,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final studentId = Get.isRegistered<AuthController>()
          ? (Get.find<AuthController>().currentUser.value?.id ?? 'unknown')
          : 'unknown';
      final saved = await _images.saveHomeworkImage(
        studentId: studentId,
        fileName: file.name,
        bytes: bytes,
        homeworkId: widget.paperId,
      );
      if (!mounted) return;
      setState(() => _photos[item.id] = saved.storageKey);
      Get.snackbar('已留档', '这张照片会作为这道题的作答过程证据');
    } catch (error) {
      Get.snackbar('拍照失败', '$error');
    }
  }

  Future<void> _submit() async {
    final unmarked = _items
        .where((item) => !_results.containsKey(item.id))
        .length;
    if (unmarked > 0) {
      Get.snackbar('还有 $unmarked 道题没有标记', '请把每一道题都标为「做对了」或「做错了」');
      return;
    }

    setState(() => _submitting = true);
    final result = await controller.submitPaper(
      paperId: widget.paperId,
      results: Map<String, PaperItemResult>.of(_results),
      answers: {
        for (final entry in _answers.entries) entry.key: entry.value.text,
      },
      photoPaths: Map<String, String>.of(_photos),
    );
    if (!mounted) return;
    setState(() => _submitting = false);

    if (!result.op.ok) {
      Get.snackbar('未能提交', result.op.message);
      return;
    }

    await _showGradingDialog(result);
    if (!mounted) return;
    Get.off(() => ReviewSummaryPage(paperId: widget.paperId));
  }

  Future<void> _showGradingDialog(PaperGradingResult result) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(result.graduatedCount > 0 ? '有错题毕业了' : '批改完成'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _tally('通过', result.passCount, AppColors.success),
                _tally('未通过', result.failCount, AppColors.danger),
                _tally('已毕业', result.graduatedCount, AppColors.primary),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              result.summary?.body ?? result.op.message,
              style: const TextStyle(fontSize: 13, height: 1.6),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('看报告'),
          ),
        ],
      ),
    );
  }

  Widget _tally(String label, int value, Color color) {
    return Expanded(
      child: Column(
        children: [
          Text(
            '$value',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('回传批改')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_items.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('回传批改')),
        body: const Center(
          child: Text(
            '这份资料没有题目',
            style: TextStyle(color: AppColors.textMuted),
          ),
        ),
      );
    }

    final marked = _items.where((item) => _results.containsKey(item.id)).length;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('回传批改'),
        actions: [
          if (_items.any((item) => item.answerKey.isNotEmpty))
            TextButton.icon(
              onPressed: () => setState(() => _showKey = !_showKey),
              icon: Icon(
                _showKey ? Icons.visibility_off : Icons.visibility,
                size: 16,
              ),
              label: Text(
                _showKey ? '收起答案' : '对照答案',
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          _guide(marked),
          const SizedBox(height: 12),
          ..._items.map(
            (item) => _CheckCard(
              item: item,
              showKey: _showKey,
              result: _results[item.id],
              photoPath: _photos[item.id],
              editor: _answers[item.id]!,
              readImage: _images.readImage,
              onMark: (value) => setState(() => _results[item.id] = value),
              onClear: () => setState(() => _results.remove(item.id)),
              onPhoto: () => _pickPhoto(item),
              onRemovePhoto: () => setState(() => _photos.remove(item.id)),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          decoration: const BoxDecoration(
            color: AppColors.card,
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: _items.isEmpty ? 0 : marked / _items.length,
                        minHeight: 7,
                        backgroundColor: AppColors.border,
                        valueColor: AlwaysStoppedAnimation(
                          marked == _items.length
                              ? AppColors.success
                              : AppColors.primary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '已标记 $marked/${_items.length}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _submitting ? null : _submit,
                  icon: const Icon(Icons.fact_check_outlined),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  label: Text(_submitting ? '正在批改…' : '提交批改'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _guide(int marked) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.info_outline,
                size: 17,
                color: AppColors.primary,
              ),
              const SizedBox(width: 7),
              Text(
                '对照纸上的作答，逐题标记',
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '填了答案的题由 AI 判定对错；没填答案的题按你的标记记录。'
            '两者都会留痕，反复错的题需要连续两轮通过才移出错题库。',
            style: TextStyle(fontSize: 12, height: 1.6, color: AppColors.text),
          ),
          if (marked > 0) ...[
            const SizedBox(height: 6),
            Text(
              '已经标记 $marked 道',
              style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

class _CheckCard extends StatelessWidget {
  const _CheckCard({
    required this.item,
    required this.showKey,
    required this.result,
    required this.photoPath,
    required this.editor,
    required this.readImage,
    required this.onMark,
    required this.onClear,
    required this.onPhoto,
    required this.onRemovePhoto,
  });

  final ReviewPaperItem item;
  final bool showKey;
  final PaperItemResult? result;
  final String? photoPath;
  final TextEditingController editor;
  final Uint8List? Function(String storageKey) readImage;
  final ValueChanged<PaperItemResult> onMark;
  final VoidCallback onClear;
  final VoidCallback onPhoto;
  final VoidCallback onRemovePhoto;

  @override
  Widget build(BuildContext context) {
    final borderColor = switch (result) {
      PaperItemResult.correct => AppColors.success,
      PaperItemResult.wrong => AppColors.danger,
      _ => AppColors.border,
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 22,
                height: 22,
                margin: const EdgeInsets.only(right: 8, top: 1),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Center(
                  child: Text(
                    '${item.sortOrder + 1}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  item.questionTitle,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          if (item.knowledgePoint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 30),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  item.knowledgePoint,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accent,
                  ),
                ),
              ),
            ),
          if (item.questionBody.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              item.questionBody,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: AppColors.text,
              ),
            ),
          ],
          if (showKey && item.answerKey.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '参考答案：${item.answerKey}',
                style: const TextStyle(fontSize: 12.5, height: 1.5),
              ),
            ),
          ],
          const SizedBox(height: 10),
          TextField(
            controller: editor,
            maxLines: 2,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              labelText: '卷面答案（选填）',
              helperText: '填了由 AI 判定对错；不填则按下面的标记记录',
              helperStyle: TextStyle(fontSize: 11, color: AppColors.textMuted),
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _MarkButton(
                  label: '做对了',
                  icon: Icons.check,
                  color: AppColors.success,
                  selected: result == PaperItemResult.correct,
                  onTap: () => onMark(PaperItemResult.correct),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MarkButton(
                  label: '做错了',
                  icon: Icons.close,
                  color: AppColors.danger,
                  selected: result == PaperItemResult.wrong,
                  onTap: () => onMark(PaperItemResult.wrong),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (photoPath != null && photoPath!.isNotEmpty)
            Row(
              children: [
                _Thumbnail(bytes: _safeRead(photoPath!), storageKey: photoPath!),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    '已保留作答照片',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ),
                TextButton.icon(
                  onPressed: onRemovePhoto,
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('移除', style: TextStyle(fontSize: 12)),
                ),
              ],
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onPhoto,
                icon: const Icon(Icons.add_a_photo_outlined, size: 16),
                label: const Text('拍照留档', style: TextStyle(fontSize: 12.5)),
              ),
            ),
          if (result == PaperItemResult.correct)
            TextButton(
              onPressed: onClear,
              child: const Text('清除标记', style: TextStyle(fontSize: 11.5)),
            ),
        ],
      ),
    );
  }

  Uint8List? _safeRead(String storageKey) {
    try {
      return readImage(storageKey);
    } catch (_) {
      return null;
    }
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.bytes, required this.storageKey});

  final Uint8List? bytes;
  final String storageKey;

  @override
  Widget build(BuildContext context) {
    if (bytes == null) {
      return Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          Icons.image_outlined,
          size: 20,
          color: AppColors.textMuted,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.memory(
        bytes!,
        width: 52,
        height: 52,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stack) => Container(
          width: 52,
          height: 52,
          color: AppColors.background,
          child: const Icon(
            Icons.broken_image_outlined,
            size: 20,
            color: AppColors.textMuted,
          ),
        ),
      ),
    );
  }
}

class _MarkButton extends StatelessWidget {
  const _MarkButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.12) : AppColors.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? color : AppColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: selected ? color : AppColors.textMuted,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: selected ? color : AppColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
