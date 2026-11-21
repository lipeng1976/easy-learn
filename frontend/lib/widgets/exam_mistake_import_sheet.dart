import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/database_service.dart';
import '../services/exam_mistake_api.dart';
import '../utils/pop_route.dart';

/// 家长端「复习」页的入口按钮。
///
/// ⚠️ **可选能力**：没开通 ima / 目录不存在 / 读失败，都只是**不显示按钮**，
/// 绝不弹红条、绝不抛异常。只有家长主动点进来才允许明确的失败反馈。
/// 这条规矩由 `test/exam_mistake_import_test.dart` 单独盯着。
class ExamMistakeImportEntry extends StatefulWidget {
  const ExamMistakeImportEntry({
    super.key,
    required this.studentId,
    this.repository,
    this.onChanged,
  });

  final String studentId;

  /// 只为测试注入；线上按 `DatabaseService.cloud?.api` 构造。
  final ExamMistakeRepository? repository;

  /// 导入 / 撤销成功后刷新家长端错题本，否则页面数字会停在过去。
  final VoidCallback? onChanged;

  @override
  State<ExamMistakeImportEntry> createState() => _ExamMistakeImportEntryState();
}

class _ExamMistakeImportEntryState extends State<ExamMistakeImportEntry> {
  bool _visible = false;
  ExamMistakeLibrary? _library;

  ExamMistakeRepository get _repo =>
      widget.repository ?? _defaultRepository();

  static ExamMistakeRepository _defaultRepository() {
    final api = DatabaseService.cloud?.api;
    return api == null
        ? const UnavailableExamMistakeRepository()
        : HttpExamMistakeRepository(api);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ExamMistakeImportEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 家长切孩子时不能沿用上一个孩子的可见状态。
    if (oldWidget.studentId != widget.studentId) _load();
  }

  Future<void> _load() async {
    try {
      final library = await _repo.listFiles(studentId: widget.studentId);
      if (!mounted) return;
      setState(() {
        _library = library;
        _visible = library.connected;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _visible = false);
    }
  }

  Future<void> _open() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => ExamMistakeImportSheet(
        repository: _repo,
        studentId: widget.studentId,
        initial: _library,
      ),
    );
    if (!mounted) return;
    if (changed == true) widget.onChanged?.call();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        key: const Key('exam_mistake_import_entry'),
        onPressed: _open,
        icon: const Icon(Icons.upload_file_outlined, size: 17),
        label: const Text('从 ima 导入试卷错题'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primaryDark,
          side: const BorderSide(color: AppColors.primary),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

/// 列出 `教学资料/试卷错题/` 下的 MD，逐份导入 / 撤销。
///
/// 返回 `true` 表示确实改动过错题本，调用方据此刷新页面。
class ExamMistakeImportSheet extends StatefulWidget {
  const ExamMistakeImportSheet({
    super.key,
    required this.repository,
    required this.studentId,
    this.initial,
  });

  final ExamMistakeRepository repository;
  final String studentId;
  final ExamMistakeLibrary? initial;

  @override
  State<ExamMistakeImportSheet> createState() => _ExamMistakeImportSheetState();
}

class _ExamMistakeImportSheetState extends State<ExamMistakeImportSheet> {
  late ExamMistakeLibrary _library;
  bool _loading = false;
  bool _busy = false;
  bool _changed = false;
  String _tip = '';
  bool _tipIsError = false;

  @override
  void initState() {
    super.initState();
    _library = widget.initial ?? ExamMistakeLibrary.empty;
    if (widget.initial == null) _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final library = await widget.repository.listFiles(studentId: widget.studentId);
      if (!mounted) return;
      setState(() => _library = library);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tip = '列表没读到：$e';
        _tipIsError = true;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => popRoute(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => popRoute(context, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _import(ExamMistakeFile file) async {
    final confirmed = await _confirm(
      file.importedCount > 0 ? '重新导入这份试卷？' : '导入这份试卷？',
      file.importedCount > 0
          ? '「${file.fileName}」之前导入的 ${file.importedCount} 条错题会被这份 MD 替换。'
              '其它来源（作业、打卡、手工录入）的错题不受影响。'
          : '「${file.fileName}」里的错题会加入错题本，之后能直接组卷重做。',
    );
    if (!confirmed || !mounted || _busy) return;
    setState(() {
      _busy = true;
      _tip = '';
    });
    try {
      final result = await widget.repository.importFile(
        studentId: widget.studentId,
        mediaId: file.mediaId,
      );
      if (!mounted) return;
      _changed = true;
      setState(() {
        _tip = '已导入 ${result.imported} 条错题'
            '${result.removed > 0 ? '（替换了旧的 ${result.removed} 条）' : ''}';
        _tipIsError = false;
      });
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tip = '导入没成功：$e';
        _tipIsError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(ExamMistakeFile file) async {
    final confirmed = await _confirm(
      '撤销这批错题？',
      '「${file.fileName}」导入的 ${file.importedCount} 条错题会从错题本删掉。'
      'ima 里的原文件不受影响，以后还能重新导入。',
    );
    if (!confirmed || !mounted || _busy) return;
    setState(() {
      _busy = true;
      _tip = '';
    });
    try {
      final removed = await widget.repository.revoke(
        studentId: widget.studentId,
        mediaId: file.mediaId,
      );
      if (!mounted) return;
      _changed = true;
      setState(() {
        _tip = '已撤销 $removed 条错题';
        _tipIsError = false;
      });
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tip = '撤销没成功：$e';
        _tipIsError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final files = _library.files;
    return AlertDialog(
      title: const Text('从 ima 导入试卷错题'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '把考试卷的错题 MD 放进 ima 的「${_library.folderPath}」。'
                '导入后能直接组卷重做、举一反三。',
                style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
              const SizedBox(height: 10),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(10),
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (files.isEmpty)
                Text(
                  _library.reason == 'folder_missing'
                      ? '还没在 ima 里建「${_library.folderPath}」文件夹。'
                      : '这个文件夹里还没有 MD 文件。',
                  style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
                )
              else
                ...files.map(
                  (file) => Container(
                    key: Key('exam_file_${file.mediaId}'),
                    margin: const EdgeInsets.only(bottom: 6),
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.border),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ListTile(
                          dense: true,
                          title: Text(file.fileName, style: const TextStyle(fontSize: 13)),
                          subtitle: Text(
                            file.importedCount > 0
                                ? '已导入 ${file.importedCount} 条'
                                : '未导入',
                            style: TextStyle(
                              fontSize: 11,
                              color: file.importedCount > 0
                                  ? AppColors.success
                                  : AppColors.textMuted,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                          child: Row(
                            children: [
                              TextButton(
                                key: Key('exam_import_${file.mediaId}'),
                                onPressed: _busy ? null : () => _import(file),
                                child: Text(
                                  file.importedCount > 0 ? '重新导入' : '导入',
                                ),
                              ),
                              if (file.importedCount > 0)
                                TextButton(
                                  key: Key('exam_revoke_${file.mediaId}'),
                                  onPressed: _busy ? null : () => _revoke(file),
                                  child: const Text(
                                    '撤销',
                                    style: TextStyle(color: AppColors.danger),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_tip.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _tip,
                  style: TextStyle(
                    fontSize: 12,
                    color: _tipIsError ? AppColors.danger : AppColors.success,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => popRoute(context, _changed),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
