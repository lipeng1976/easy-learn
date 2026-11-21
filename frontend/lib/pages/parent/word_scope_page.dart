import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/parent_controller.dart';
import '../../models/word_checkin.dart';
import '../../models/user_profile_model.dart';
import '../../services/database_service.dart';
import '../../services/word_api.dart';
import '../../widgets/grade_term_mismatch.dart';

/// 家长端「配置词表」：选当前书 / 单元模式 / 当前单元 / 每日题量 + 从 ima 导入。
///
/// 照抄英文阅读范式：家长点一次书，学生端不给任何选择。
/// **一个学生一个范围**（`word_scope.student_id` 主键），学生 id 一律取
/// `ParentController.selectedStudentId`，与 ima 按学生配置口径一致 ——
/// 不用 `CheckinController.targetStudentId()`（它取 boundStudents.first，
/// 多孩家庭会拿 A 的词表给 B 打卡）。
///
/// 没有 ima 时：导入区整块隐藏，已导入的书照常能切，全程不弹红条。
class WordScopePage extends StatefulWidget {
  const WordScopePage({super.key});

  @override
  State<WordScopePage> createState() => _WordScopePageState();
}

class _WordScopePageState extends State<WordScopePage> {
  WordScope _scope = const WordScope(studentId: '');
  WordBookList _books = const WordBookList(connected: false);
  bool _loading = true;
  bool _saving = false;
  String? _hint;
  int _generation = 0;
  Worker? _worker;

  /// 当前学生档案（年级 / 学期），用来跟选中的词表比对。
  UserProfileModel? _profile;

  /// 选中的词表（从已导入列表里按 id 找），拿它的年级学期做比对。
  WordImportedBook? get _selectedBook {
    if (_scope.bookId.isEmpty) return null;
    for (final book in _books.imported) {
      if (book.id == _scope.bookId) return book;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    if (Get.isRegistered<ParentController>()) {
      _worker = ever<String>(
        Get.find<ParentController>().selectedStudentId,
        (_) => _load(),
      );
    }
    _load();
  }

  @override
  void dispose() {
    _worker?.dispose();
    super.dispose();
  }

  String get _studentId => Get.isRegistered<ParentController>()
      ? Get.find<ParentController>().selectedStudentId.value
      : '';

  Future<void> _load() async {
    final generation = ++_generation;
    final studentId = _studentId;
    if (studentId.isEmpty) return; // 晚到时 ever 会再拉
    if (mounted) setState(() => _loading = true);
    try {
      final scope = await DatabaseService.word.getScope(studentId);
      WordBookList books;
      try {
        books = await DatabaseService.word.listBooks(studentId);
      } catch (_) {
        books = const WordBookList(connected: false, reason: 'ima_read_error');
      }
      if (generation != _generation || !mounted) return;
      // 学生档案（年级 / 学期）独立拉，失败不影响主流程。
      try {
        _profile = await DatabaseService.instance.queryUserProfile(studentId);
      } catch (_) {
        _profile = null;
      }
      setState(() {
        _scope = scope;
        _books = books;
        _hint = scope.hasBook ? null : '还没有选当前词表，请先导入一本教材词表。';
      });
    } catch (_) {
      if (generation == _generation && mounted) {
        setState(() => _hint = '暂时读不到词表配置，稍后再试；已有词表照常可以打卡。');
      }
    } finally {
      if (generation == _generation && mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_scope.hasBook) {
      setState(() => _hint = '请先选一本当前词表');
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await DatabaseService.word.putScope(_scope);
      if (!mounted) return;
      setState(() {
        _scope = saved;
        // 文案照实说：题不落盘，所以「今天还没作答」时改完范围，下次进
        // 答题页就是新范围；已经选过答案 / 已交卷的那组才保持不变。
        // 旧文案写「明天开始生效」，但实现从来没锁过「今天的题」——
        // 家长第二天发现「昨天说次日生效、其实昨天就变了」，比不提示更糟。
        _hint = '已保存。今天还没作答的话，回到学生端就是新范围；今天已答过的不变。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _hint = '保存没成功：${_shortError(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _import(WordAvailableBook book) async {
    // 导入前先选年级学期：默认当前学生年级，家长改了才变。
    final picked = await pickGradeTerm(
      context,
      initialGrade: _profile?.grade ?? '',
      initialTerm: _profile?.term ?? '',
    );
    if (picked == null) return;
    final (grade, term) = picked;
    setState(() => _saving = true);
    try {
      final res = await DatabaseService.word.importBook(
        studentId: _studentId,
        mediaId: book.mediaId,
        fileName: book.fileName,
        grade: grade,
        term: term,
      );
      if (res['imported'] == true) {
        await _load();
        if (mounted) {
          setState(() => _hint = '已导入 ${res['wordCount'] ?? 0} 个单词，记得选它为当前词表。');
        }
      } else if (mounted) {
        setState(() => _hint = '这份词表没能导入，请检查文件内容后重试。');
      }
    } catch (e) {
      if (mounted) setState(() => _hint = '导入没成功：${_shortError(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String _shortError(Object e) {
    final text = e.toString();
    return text.length > 60 ? '${text.substring(0, 60)}…' : text;
  }

  void _patch({
    String? bookId,
    String? unitMode,
    String? currentUnit,
    List<String>? selectedUnits,
    int? dailyCount,
  }) {
    setState(() {
      _scope = WordScope(
        studentId: _scope.studentId,
        bookId: bookId ?? _scope.bookId,
        bookTitle: _scope.bookTitle,
        unitMode: unitMode ?? _scope.unitMode,
        currentUnit: currentUnit ?? _scope.currentUnit,
        selectedUnits: selectedUnits ?? _scope.selectedUnits,
        units: _scope.units,
        dailyCount: dailyCount ?? _scope.dailyCount,
        configured: _scope.configured,
      );
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('英语单词 · 配置词表')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_hint != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _hint!,
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                      ),
                    ),
                  const Text('当前教材词表', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: _books.imported.any((b) => b.id == _scope.bookId)
                        ? _scope.bookId
                        : null,
                    hint: const Text('还没有导入词表'),
                    items: _books.imported
                        .map((b) => DropdownMenuItem<String>(
                              value: b.id,
                              child: Text('${b.title}（${b.wordCount} 词）'),
                            ))
                        .toList(),
                    onChanged: (id) {
                      if (id == null) return;
                      // 换书后当前单元要跟着新书走，否则服务端会 400。
                      _patch(bookId: id, currentUnit: '');
                      _loadUnitsFor(id);
                    },
                  ),
                  const SizedBox(height: 12),
                  GradeTermMismatchNotice(
                    bookGrade: _selectedBook?.grade ?? '',
                    bookTerm: _selectedBook?.term ?? '',
                    profileGrade: _profile?.grade ?? '',
                    profileTerm: _profile?.term ?? '',
                  ),
                  const SizedBox(height: 16),
                  const Text('单元范围', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: const <MapEntry<String, String>>[
                      MapEntry('current', '仅当前单元'),
                      MapEntry('learned', '已学区间'),
                      MapEntry('selected', '指定单元'),
                      MapEntry('all', '整本'),
                    ].map((entry) {
                      return ChoiceChip(
                        label: Text(entry.value),
                        selected: _scope.unitMode == entry.key,
                        onSelected: (_) => _patch(unitMode: entry.key),
                      );
                    }).toList(),
                  ),
                  if (_scope.units.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text('当前学到哪一单元'),
                    DropdownButton<String>(
                      isExpanded: true,
                      value: _scope.units.contains(_scope.currentUnit)
                          ? _scope.currentUnit
                          : null,
                      hint: const Text('请选择'),
                      items: _scope.units
                          .map((unit) => DropdownMenuItem<String>(
                                value: unit,
                                child: Text(unit),
                              ))
                          .toList(),
                      onChanged: (unit) => _patch(currentUnit: unit),
                    ),
                  ],
                  if (_scope.unitMode == 'selected' && _scope.units.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const Text('勾选要练的单元'),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: _scope.units.map((unit) {
                        final selected = _scope.selectedUnits.contains(unit);
                        return FilterChip(
                          label: Text(unit),
                          selected: selected,
                          onSelected: (_) {
                            final next = [..._scope.selectedUnits];
                            if (selected) {
                              next.remove(unit);
                            } else {
                              next.add(unit);
                            }
                            _patch(selectedUnits: next);
                          },
                        );
                      }).toList(),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Text('每天几题', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: const <int>[5, 10, 15].map((count) {
                      return ChoiceChip(
                        label: Text('$count 题'),
                        selected: _scope.dailyCount == count,
                        onSelected: (_) => _patch(dailyCount: count),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? '处理中…' : '保存范围'),
                  ),
                  // 没开通 ima 时整块隐藏：功能可以缺，不可错（11-07 硬规矩）。
                  if (_books.connected && _books.available.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    const Text('从 ima 导入新词表', style: TextStyle(fontWeight: FontWeight.w700)),
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: Text(
                        '目录：${_books.folderPath}',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                      ),
                    ),
                    ..._books.available.map(
                      (book) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.article_outlined),
                        title: Text(book.title),
                        subtitle: Text(
                          book.importedBookId != null
                              ? '已导入 ${book.importedWordCount} 词 · 重新导入会覆盖更新'
                              : book.fileName,
                        ),
                        trailing: TextButton(
                          onPressed: _saving ? null : () => _import(book),
                          child: Text(book.importedBookId != null ? '更新' : '导入'),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
      );

  /// 换书后把单元列表切成新书的（服务端下发，客户端不自己拼口径）。
  Future<void> _loadUnitsFor(String bookId) async {
    try {
      final entries = await DatabaseService.word.listEntries(
        studentId: _studentId,
        bookId: bookId,
      );
      final units = <String>[];
      for (final e in entries) {
        if (!units.contains(e.unit)) units.add(e.unit);
      }
      if (!mounted) return;
      setState(() {
        _scope = WordScope(
          studentId: _scope.studentId,
          bookId: bookId,
          bookTitle: _books.imported
              .firstWhere(
                (b) => b.id == bookId,
                orElse: () => const WordImportedBook(id: '', title: ''),
              )
              .title,
          unitMode: _scope.unitMode,
          currentUnit: units.isEmpty ? '' : units.first,
          selectedUnits: const <String>[],
          units: units,
          dailyCount: _scope.dailyCount,
          configured: _scope.configured,
        );
      });
    } catch (_) {
      // 读不到单元就先留空，保存时服务端会给出明确提示。
    }
  }
}
