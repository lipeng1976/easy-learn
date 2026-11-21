import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';

import '../../constants/app_colors.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/review_controller.dart';
import '../../models/review_model.dart';
import '../../services/ai_data_source.dart';

/// 错题录入 / 编辑页。
///
/// 新增与编辑复用同一页：两者的字段完全相同，差别只在有没有初始值。
/// 拆成两页的后果是「录错了想改，字段却对不上」——比如新增页允许不选知识点，
/// 编辑页却卡着必填，用户只能删了重录。
///
/// 科目用「选择 + 可输入」而不是纯下拉：历史错题常常来自目前一道错题都没有的科目，
/// 纯下拉会逼用户先随便选一个再回头改。
class MistakeEditPage extends StatefulWidget {
  const MistakeEditPage({super.key, this.mistakeId});

  /// 为空表示新增。
  final String? mistakeId;

  @override
  State<MistakeEditPage> createState() => _MistakeEditPageState();
}

class _MistakeEditPageState extends State<MistakeEditPage> {
  final ReviewController controller = Get.find<ReviewController>();

  final TextEditingController _subject = TextEditingController();
  final TextEditingController _knowledgePoint = TextEditingController();
  final TextEditingController _title = TextEditingController();
  final TextEditingController _body = TextEditingController();
  final TextEditingController _answerKey = TextEditingController();
  final TextEditingController _answer = TextEditingController();
  final TextEditingController _reason = TextEditingController();
  final TextEditingController _source = TextEditingController();

  final ImagePicker _picker = ImagePicker();

  /// 待上传的原题照片（新增时）。编辑页只展示已有照片数量，
  /// 不在这里做增删 —— 删除走错题详情的图片区，避免两个入口两套逻辑。
  final List<XFile> _photos = <XFile>[];
  bool _picking = false;

  /// 正在识别题目。
  bool _scanning = false;

  /// 已经送到存储里的照片键，与 [_photos] 按位置对应。
  ///
  /// 识别过一次后由 `scanMistakePhotos` 带回，保存时回传给控制器复用 ——
  /// 不存这一份，同一批照片就要在「识别」和「保存」各上传一遍。
  /// 照片增删之后这个列表就作废了（位置对不上），清空即回到「保存时再传」。
  List<String> _storageKeys = const [];

  static const List<String> _presetSubjects = ['语文', '数学', '英语', '科学'];
  static const List<String> _presetKnowledge = [
    '分数计算',
    '分数比较',
    '应用题',
    '阅读理解',
    '字词辨析',
    '时态',
    '单位换算',
  ];

  bool get isEditing => (widget.mistakeId ?? '').isNotEmpty;
  bool _saving = false;

  /// 已经存成功过。
  ///
  /// 只用 `_saving` 不够：它在保存结束时就被重置了，而 `Get.back()` 万一
  /// 没把页面关掉（实测过一次「一道题变成 4 条」，就是同一个表单被连点），
  /// 用户会以为没存上、再点一次，于是又多一条。存成功后就再也点不动。
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    final existing = isEditing ? controller.mistakeById(widget.mistakeId!) : null;
    if (existing != null) {
      _subject.text = existing.subject;
      _knowledgePoint.text = existing.knowledgePoint;
      _title.text = existing.title;
      _body.text = existing.questionBody;
      _answerKey.text = existing.answerKey;
      _answer.text = existing.originalAnswer;
      _reason.text = existing.wrongReason;
      _source.text = existing.sourceHomeworkTitle;
    }
  }

  @override
  void dispose() {
    _subject.dispose();
    _knowledgePoint.dispose();
    _title.dispose();
    _body.dispose();
    _answerKey.dispose();
    _answer.dispose();
    _reason.dispose();
    _source.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || _saved) return;
    setState(() => _saving = true);

    // 照片先读成字节。读不出来就中止：宁可让用户重选一张，
    // 也不要把一条「有题没图」的记录存进去。
    final photos = <MistakeIntakePhoto>[];
    try {
      for (final file in _photos) {
        photos.add(
          MistakeIntakePhoto(
            fileName: file.name,
            bytes: await file.readAsBytes(),
            mimeType: file.mimeType ?? 'image/jpeg',
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      Get.snackbar('照片读取失败', '$e');
      return;
    }

    final user = Get.isRegistered<AuthController>()
        ? Get.find<AuthController>().currentUser.value
        : null;
    final result = isEditing
        ? await controller.updateMistake(
            mistakeId: widget.mistakeId!,
            subject: _subject.text,
            title: _title.text,
            questionBody: _body.text,
            answerKey: _answerKey.text,
            sourceHomeworkTitle: _source.text,
            grade: user?.grade,
            term: user?.term,
            knowledgePoint: _knowledgePoint.text,
            originalAnswer: _answer.text,
            wrongReason: _reason.text,
          )
        : await controller.addMistakeManually(
            subject: _subject.text,
            title: _title.text,
            questionBody: _body.text,
            answerKey: _answerKey.text,
            knowledgePoint: _knowledgePoint.text,
            originalAnswer: _answer.text,
            wrongReason: _reason.text,
            sourceType: photos.isEmpty
                ? MistakeSource.manual
                : MistakeSource.scan,
            grade: user?.grade ?? '',
            term: user?.term ?? '',
            photos: photos,
            // 识别过一次的照片已经在存储里：把键带过去，避免保存时再传一遍。
            preparedStorageKeys: _storageKeys,
          );
    if (!mounted) return;
    setState(() {
      _saving = false;
      // 成功就锁死，哪怕页面没被关掉也点不出第二条。
      if (result.ok) _saved = true;
    });
    Get.snackbar(result.ok ? '已保存' : '未能保存', result.message);
    if (result.ok) Get.back<void>();
  }

  Future<void> _pickPhoto(ImageSource source) async {
    if (_picking || _photos.length >= ReviewController.maxIntakePhotos) return;
    setState(() => _picking = true);
    try {
      final List<XFile> picked;
      if (source == ImageSource.camera) {
        final one = await _picker.pickImage(
          source: ImageSource.camera,
          imageQuality: 85,
          maxWidth: 2000,
        );
        picked = one == null ? <XFile>[] : <XFile>[one];
      } else {
        picked = await _picker.pickMultiImage(
          imageQuality: 85,
          maxWidth: 2000,
        );
      }
      if (picked.isNotEmpty) {
        setState(() {
          _photos.addAll(
            picked.take(ReviewController.maxIntakePhotos - _photos.length),
          );
          // 位置全变了（多了一张），旧的存储键对不上任何一行。
          _storageKeys = const [];
        });
      }
    } catch (e) {
      Get.snackbar('没能打开相机/相册', '$e');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 让 AI 把照片里的题目提取出来，填进表单。
  ///
  /// 只填、不存：学生看到题干之后仍然能改，保存由他自己点。这样
  /// 「识别错了」最多让他多改几个字，而不会把一道错题干送进错题库。
  Future<void> _recognize() async {
    if (_scanning || _photos.isEmpty) return;
    setState(() => _scanning = true);

    final photos = <MistakeIntakePhoto>[];
    try {
      for (final file in _photos) {
        photos.add(
          MistakeIntakePhoto(
            fileName: file.name,
            bytes: await file.readAsBytes(),
            mimeType: file.mimeType ?? 'image/jpeg',
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _scanning = false);
      Get.snackbar('照片读取失败', '$e');
      return;
    }

    final scan = await controller.scanMistakePhotos(photos: photos);
    if (!mounted) return;
    setState(() {
      _scanning = false;
      // 上传失败时 `storageKeys` 是空的 —— 别把已经对上的键清掉。
      if (scan.storageKeys.isNotEmpty) _storageKeys = scan.storageKeys;
    });

    if (!scan.ok) {
      Get.snackbar('没能识别', scan.failure);
      return;
    }

    final candidates = scan.extraction.candidates;
    if (candidates.isEmpty) {
      Get.snackbar(
        '没识别到题目',
        scan.extraction.uncertain.isNotEmpty
            ? scan.extraction.uncertain
            : '照片里没有看清的题目，可以重拍或直接手写题干',
      );
      return;
    }

    if (candidates.length == 1) {
      await _applyCandidate(candidates.first);
      return;
    }
    await _chooseCandidate(candidates);
  }

  /// 一张照片里有多道题：让学生挑一道先录。
  ///
  /// 刻意不给「全部录进来」：批量录入要逐条确认知识点、答案与错因，
  /// 一屏塞不下。硬做出来只会让学生跳过确认，把模型的猜测当成事实存下去。
  Future<void> _chooseCandidate(List<ExtractedMistake> candidates) async {
    final picked = await showModalBottomSheet<ExtractedMistake>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.72,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  '照片里有 ${candidates.length} 道题，先录哪一道？',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final candidate = candidates[index];
                    return ListTile(
                      title: Text(
                        candidate.questionBody,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5, height: 1.45),
                      ),
                      subtitle: candidate.knowledgePoint.isEmpty
                          ? null
                          : Text(candidate.knowledgePoint),
                      // 把握低的标黄：不拦着选，但要让他知道这条得自己核。
                      trailing: candidate.needsReview
                          ? const Icon(
                              Icons.error_outline,
                              size: 18,
                              color: AppColors.warning,
                            )
                          : null,
                      onTap: () => Navigator.of(context).pop(candidate),
                    );
                  },
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 10, 16, 14),
                child: Text(
                  '整页批量录入还在做，目前一次录一道。',
                  style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) await _applyCandidate(picked);
  }

  /// 把一条提取结果填进表单。
  Future<void> _applyCandidate(ExtractedMistake candidate) async {
    // 已经手抄了题干就不要默默覆盖：他可能正是为了避开识别错误才抄的。
    if (_body.text.trim().isNotEmpty) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('用识别结果替换题干？'),
          content: const Text('题目原文里已经有内容，替换后会覆盖掉。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('保留我写的'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('用识别结果'),
            ),
          ],
        ),
      );
      if (replace != true) return;
    }

    setState(() {
      _body.text = candidate.questionBody;
      // 答案与知识点只在识别出来时才填：拿空串覆盖会把学生自己填的清掉。
      if (candidate.answerKey.isNotEmpty) _answerKey.text = candidate.answerKey;
      if (candidate.knowledgePoint.isNotEmpty) {
        _knowledgePoint.text = candidate.knowledgePoint;
      }
    });

    final notes = <String>[];
    if (candidate.uncertain.isNotEmpty) notes.add(candidate.uncertain);
    if (candidate.needsReview) notes.add('识别把握不高，请对照原图核对一遍');
    if (notes.isNotEmpty) Get.snackbar('已填入，请核对', notes.join('；'));
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这道错题？'),
        content: const Text('这道题的作答记录、讲解与举一反三题目会一起删除，且无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final result = await controller.removeMistake(widget.mistakeId!);
    if (!mounted) return;
    Get.snackbar(result.ok ? '已删除' : '未能删除', result.message);
    if (result.ok) Get.back<void>();
  }

  @override
  Widget build(BuildContext context) {
    final user = Get.isRegistered<AuthController>()
        ? Get.find<AuthController>().currentUser.value
        : null;
    final subjects = <String>{
      ..._presetSubjects,
      ...controller.knownSubjects,
      if (_subject.text.trim().isNotEmpty) _subject.text.trim(),
    }.toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? '编辑错题' : '手工录入错题'),
        actions: [
          if (isEditing)
            IconButton(
              tooltip: '删除',
              onPressed: _saving ? null : _delete,
              icon: const Icon(Icons.delete_outline, color: AppColors.danger),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          const _FormHint(),
          const SizedBox(height: 14),
          _ArchiveHint(
            grade: user?.grade ?? '',
            term: user?.term ?? '',
          ),
          const SizedBox(height: 16),
          if (!isEditing) ...[
            _label('原题照片（可选）'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _picking ? null : () => _pickPhoto(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_outlined, size: 18),
                    label: const Text('拍照'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _picking ? null : () => _pickPhoto(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    label: const Text('从相册选'),
                  ),
                ),
              ],
            ),
            if (_photos.isNotEmpty) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 84,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _photos.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) => _PhotoThumb(
                    file: _photos[index],
                    onRemove: () => setState(() {
                      _photos.removeAt(index);
                      // 少了一张，后面的位置全变了 —— 旧键不能再按位置对应。
                      _storageKeys = const [];
                    }),
                  ),
                ),
              ),
            ],
            if (_photos.isNotEmpty) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: (_scanning || _saving) ? null : _recognize,
                  icon: _scanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome_outlined, size: 18),
                  label: Text(_scanning ? '正在识别题目…' : '识别题目（自动填题干）'),
                ),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              '最多 ${ReviewController.maxIntakePhotos} 张。拍照录入的题，'
              '讲解时会连同原图一起发给 AI —— 题干识别不准时它还能看图。',
              style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
          ],
          _label('科目', required: true),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: subjects.map((subject) {
              final selected = _subject.text.trim() == subject;
              return ChoiceChip(
                label: Text(subject),
                selected: selected,
                selectedColor: AppColors.primary,
                labelStyle: TextStyle(
                  color: selected ? Colors.white : AppColors.text,
                  fontWeight: FontWeight.w600,
                ),
                onSelected: (_) {
                  setState(() {
                    // 再点一次取消，避免「选错了却换不掉」
                    _subject.text = selected ? '' : subject;
                  });
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          _field(
            controller: _subject,
            hint: '也可以直接输入其他科目',
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          _label('知识点'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _presetKnowledge.map((point) {
              final selected = _knowledgePoint.text.trim() == point;
              return ChoiceChip(
                label: Text(point),
                selected: selected,
                selectedColor: AppColors.primary,
                labelStyle: TextStyle(
                  fontSize: 12.5,
                  color: selected ? Colors.white : AppColors.text,
                  fontWeight: FontWeight.w600,
                ),
                onSelected: (_) => setState(() {
                  _knowledgePoint.text = selected ? '' : point;
                }),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          _field(
            controller: _knowledgePoint,
            hint: '如「分数比较」。组卷、讲解、举一反三都按它组织',
          ),
          const SizedBox(height: 16),
          _label('题目原文', required: true),
          const SizedBox(height: 8),
          _field(
            controller: _body,
            hint: '把题目完整抄下来。数学式可用 LaTeX，如 \$\\frac{1}{2}x+3=5\$',
            maxLines: 6,
          ),
          const SizedBox(height: 16),
          _label('短标题（可选）'),
          const SizedBox(height: 8),
          _field(
            controller: _title,
            hint: '列表里显示的标题。留空会自动取题干第一行',
          ),
          const SizedBox(height: 16),
          _label('正确答案（可选）'),
          const SizedBox(height: 8),
          _field(
            controller: _answerKey,
            hint: '不确定就留空。编一个答案会把做对的判成错的',
          ),
          const SizedBox(height: 16),
          _label('来源名称（可选）'),
          const SizedBox(height: 8),
          _field(
            controller: _source,
            hint: '如「十月月考」「课本 P42」。拍照录入会自动记为「拍照录入」',
          ),
          const SizedBox(height: 16),
          _label('上次的答案'),
          const SizedBox(height: 8),
          _field(controller: _answer, hint: '写错的那个答案，留痕用'),
          const SizedBox(height: 16),
          _label('错因'),
          const SizedBox(height: 8),
          _field(
            controller: _reason,
            hint: '当时为什么做错。这条会印在重做卷上，帮你对着错处重做',
            maxLines: 3,
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: (_saving || _saved) ? null : _save,
              icon: const Icon(Icons.save_outlined),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              label: Text(_saving ? '正在保存…' : (isEditing ? '保存修改' : '加入错题库')),
            ),
          ),
          if (isEditing) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _saving ? null : _delete,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.danger,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                child: const Text('删除这道错题'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _label(String text, {bool required = false}) => Row(
    children: [
      Text(
        text,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
      if (required)
        const Text(' *', style: TextStyle(color: AppColors.danger, fontSize: 14)),
    ],
  );

  Widget _field({
    required TextEditingController controller,
    required String hint,
    int maxLines = 1,
    ValueChanged<String>? onChanged,
  }) => TextField(
    controller: controller,
    maxLines: maxLines,
    onChanged: onChanged,
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 13, color: AppColors.textMuted),
      isDense: true,
      filled: true,
      fillColor: AppColors.card,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
    ),
  );
}

class _FormHint extends StatelessWidget {
  const _FormHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: AppColors.primary),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '手工录入的错题和作业批改出来的错题一样，会一起参与组卷、'
              '讲解和举一反三。知识点填得越准，AI 出的变式题越对路。',
              style: TextStyle(fontSize: 12.5, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// 归档信息：这道题会记到哪个年级/学期。
///
/// 刻意只展示、不在这里改：年级学期是**学生档案**的一部分，散落在录入页里
/// 改会让同一个人在不同页面填出不同答案。要改就去个人信息页。
class _ArchiveHint extends StatelessWidget {
  const _ArchiveHint({required this.grade, required this.term});

  final String grade;
  final String term;

  @override
  Widget build(BuildContext context) {
    final hasGrade = grade.trim().isNotEmpty;
    final termLabel = switch (term) {
      '上' => '上学期',
      '下' => '下学期',
      _ => '',
    };
    final text = hasGrade
        ? '归档：$grade${termLabel.isEmpty ? '（未填学期）' : termLabel}'
        : '还没设置年级：这道题会记为「未归档」，仍可在「全部」里看到';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          hasGrade ? Icons.folder_outlined : Icons.info_outline,
          size: 15,
          color: hasGrade ? AppColors.textMuted : AppColors.warning,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: hasGrade ? AppColors.textMuted : AppColors.warning,
            ),
          ),
        ),
      ],
    );
  }
}

class _PhotoThumb extends StatelessWidget {
  const _PhotoThumb({required this.file, required this.onRemove});

  final XFile file;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: 76,
            height: 76,
            child: FutureBuilder<Uint8List>(
              future: file.readAsBytes(),
              builder: (context, snapshot) {
                if (snapshot.hasData) {
                  return Image.memory(snapshot.data!, fit: BoxFit.cover);
                }
                return const ColoredBox(
                  color: AppColors.card,
                  child: Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: IconButton(
            tooltip: '移除这张照片',
            onPressed: onRemove,
            icon: const Icon(Icons.cancel, size: 19, color: AppColors.danger),
          ),
        ),
      ],
    );
  }
}

/// 供列表页判断某道题是否还在卷上、能不能删。
bool canRemoveMistake(ReviewMistake mistake) =>
    mistake.state != ReviewState.reviewing &&
    mistake.state != ReviewState.verifying;
