import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../constants/subject_colors.dart';
import '../../controllers/parent_controller.dart';
import '../../models/subject_scope.dart';
import '../../models/textbook.dart';
import '../../models/user_profile_model.dart';
import '../../repositories/user_repository.dart';
import '../../services/database_service.dart';
import '../../services/subject_api.dart';
import '../../services/textbook_api.dart';
import '../../utils/pop_route.dart';
import '../../widgets/grade_term_mismatch.dart';

/// 家长端「学科范围」配置：**配一次，出题时不用再选**。
///
/// 与 `checkin_setup_page` 的区别不是外观，而是**生命周期**：那一页是
/// 「这一次出什么」，返回就没了；这一页写进 `subject_scope`，孩子下次
/// 出题还在用。所以这里没有「确定」这种一次性措辞，只有「保存」。
///
/// 英语有**两本资料**：词表在 `/word-scope`（`word_scope`），教材在这页
/// （`subject_scope`，语法 / 时态 / 句型）。两套各管各的，避免同一件事两个入口。
/// 11-13 前英语不进这页；现在要出教材题，就得能选一本英语教材骨架。
class SubjectScopePage extends StatefulWidget {
  const SubjectScopePage({
    super.key,
    this.subject,
    this.studentId,
    this.repository,
    this.textbookRepository,
    this.userRepository,
  });

  /// 哪一科。由路由参数传（`Get.arguments`）；空值按「数学」兜底并提示。
  final String? subject;

  /// 只为测试注入；线上取 `ParentController.selectedStudentId`。
  final String? studentId;

  /// 只为测试注入；线上走 [DatabaseService.subject]。
  final SubjectScopeRepository? repository;

  /// 只为测试注入；线上走 [DatabaseService.textbook]。
  final TextbookRepository? textbookRepository;

  /// 只为测试注入；线上走 [DatabaseService.instance]（它实现了 [UserRepository]）。
  /// 拿学生档案的年级 / 学期跟选中的书比对，读不到也不影响主流程。
  final UserRepository? userRepository;

  @override
  State<SubjectScopePage> createState() => _SubjectScopePageState();
}

class _SubjectScopePageState extends State<SubjectScopePage> {
  /// 与服务端 `MAX_POINTS` / 网关 `MAX_CHECKIN_ITEMS` 同一个数。
  static const int maxPoints = 6;

  late final SubjectScopeRepository _repo;
  late final TextbookRepository _textbook;
  late final UserRepository _profileRepo;
  final TextEditingController _custom = TextEditingController();

  late String _subject;
  SubjectScope _scope = const SubjectScope(studentId: '', subject: '');
  List<String> _seeds = const <String>[];

  /// 这一科的教材（已导入 + ima 里可导入的）。恒非空对象，读不到就是空。
  TextbookLibrary _library = TextbookLibrary.empty;
  List<TextbookUnit> _units = const <TextbookUnit>[];
  bool _bookBusy = false;

  /// 当前学生的档案（拿年级 / 学期跟选中的书比对，年级对不上就预警）。
  /// 读不到就当 null（不报错，只是不显示匹配状态）。
  UserProfileModel? _profile;

  bool _loading = true;
  bool _saving = false;
  String? _tip;
  /// `_tip` 默认是错误色（红）。删除成功是唯一的好消息，别用红字吓人。
  bool _tipIsSuccess = false;
  int _generation = 0;

  /// 选中的那本书（从已导入列表里按 id 找），拿它的年级学期做比对。
  TextbookBook? get _selectedBook {
    if ((_scope.bookId ?? '').isEmpty) return null;
    for (final book in _library.books) {
      if (book.id == _scope.bookId) return book;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? DatabaseService.subject;
    _textbook = widget.textbookRepository ?? DatabaseService.textbook;
    _profileRepo = widget.userRepository ?? DatabaseService.instance;
    _subject = (widget.subject ?? '').trim();
    if (_subject.isEmpty) _subject = '数学';
    _scope = SubjectScope(studentId: _studentId, subject: _subject);
    _load();
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  String get _studentId =>
      widget.studentId ??
      (Get.isRegistered<ParentController>()
          ? Get.find<ParentController>().selectedStudentId.value
          : '');

  Future<void> _load() async {
    final generation = ++_generation;
    final studentId = _studentId;
    if (studentId.isEmpty) return;
    setState(() => _loading = true);
    try {
      SubjectScope scope;
      try {
        scope = await _repo.getScope(studentId: studentId, subject: _subject);
      } catch (_) {
        scope = SubjectScope(studentId: studentId, subject: _subject);
      }
      List<String> seeds = const <String>[];
      try {
        seeds = await _repo.loadSeeds(studentId: studentId, subject: _subject);
      } catch (_) {
        // 错题本读不到 = 没有候选，手填照样能用（不弹红条）。
      }
      if (generation != _generation || !mounted) return;
      setState(() {
        _scope = scope;
        _seeds = seeds;
      });
      // 学生档案（年级 / 学期）独立拉，失败不影响主流程。
      try {
        _profile = await _profileRepo.queryUserProfile(studentId);
      } catch (_) {
        _profile = null;
      }
      await _loadLibrary(generation, bookId: scope.bookId);
    } finally {
      if (generation == _generation && mounted) setState(() => _loading = false);
    }
  }

  /// 教材库（可选）：读不到就当成「没有教材」，配置页少一块，不弹红条。
  Future<void> _loadLibrary(int generation, {String? bookId}) async {
    final studentId = _studentId;
    if (studentId.isEmpty) return;
    TextbookLibrary library = TextbookLibrary.empty;
    try {
      library = await _textbook.listBooks(studentId: studentId, subject: _subject);
    } catch (_) {
      // ima 未开通 / 027 未迁移 / 断网 —— 一律按「没教材」处理。
    }
    List<TextbookUnit> units = const <TextbookUnit>[];
    if (bookId != null && bookId.isNotEmpty) {
      try {
        units = await _textbook.listUnits(studentId: studentId, bookId: bookId);
      } catch (_) {
        // 章节读不到：下拉空着，家长能换书或取消选书（不阻塞保存）。
      }
    }
    if (generation != _generation || !mounted) return;
    setState(() {
      _library = library;
      _units = units;
    });
  }

  /// 选中一本书：起始章回到 1（换书后原章号没有意义）。
  Future<void> _selectBook(TextbookBook book) async {
    if (_bookBusy) return;
    final generation = ++_generation;
    setState(() {
      _bookBusy = true;
      _scope = _scope.copyWith(bookId: book.id, bookTitle: book.title, startUnitNo: 1);
      _tip = null;
    });
    await _loadLibrary(generation, bookId: book.id);
    if (mounted) setState(() => _bookBusy = false);
  }

  Future<void> _clearBook() async {
    if (_bookBusy) return;
    setState(() {
      _scope = _scope.copyWith(clearBook: true, startUnitNo: 1);
      _units = const <TextbookUnit>[];
      _tip = null;
    });
  }

  /// 从 ima 导入一本：列可导入的 md → 导入 → 选中它。
  Future<void> _openImportSheet() async {
    final candidates = _library.available;
    if (candidates.isEmpty) {
      setState(() {
        _tipIsSuccess = false;
        _tip = _library.reason == 'folder_missing'
            ? 'ima 里还没有「${_library.folderPath}」这个文件夹。'
            : '${_library.folderPath} 里还没有 .md 教材文件。';
      });
      return;
    }
    final picked = await showModalBottomSheet<TextbookCandidate>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 10, 18, 6),
              child: Text(
                '从 ima 导入教材',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
            for (final one in candidates)
              ListTile(
                title: Text(one.fileName),
                subtitle: Text(
                  one.imported ? '已导入 · 再导一次会覆盖章节' : '未导入',
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: () => Navigator.of(context).pop(one),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;

    // 导入前先选年级学期：默认填当前学生年级（导入大概率就是当前年级的），
    // 家长改了才变。不解析 ima 路径（命名太随意，解析必碎）。
    final pickedGradeTerm = await pickGradeTerm(
      context,
      initialGrade: _profile?.grade ?? '',
      initialTerm: _profile?.term ?? '',
    );
    if (pickedGradeTerm == null || !mounted) return;
    final (grade, term) = pickedGradeTerm;

    final generation = ++_generation;
    setState(() {
      _bookBusy = true;
      _tip = null;
    });
    try {
      final book = await _textbook.importBook(
        studentId: _studentId,
        subject: _subject,
        mediaId: picked.mediaId,
        fileName: picked.fileName,
        grade: grade,
        term: term,
      );
      if (!mounted) return;
      setState(() {
        _scope = _scope.copyWith(bookId: book.id, bookTitle: book.title, startUnitNo: 1);
      });
      await _loadLibrary(generation, bookId: book.id);
    } catch (e) {
      if (!mounted) return;
      final text = e.toString();
      setState(() {
        _tipIsSuccess = false;
        _tip = '导入没成功：${text.length > 80 ? '${text.substring(0, 80)}…' : text}';
      });
    } finally {
      if (mounted) setState(() => _bookBusy = false);
    }
  }

  /// 删除已导入的教材：ima 换了新版骨架后，旧的那本不该一直留在配置页。
  ///
  /// 两步确认（先选书、再确认），因为删掉的是**这本书的全部章节**；
  /// 一个顺手就能点到的 × 会让家长误删正在用的教材。
  Future<void> _openDeleteSheet() async {
    final books = _library.books;
    if (books.isEmpty || _bookBusy) return;
    final picked = await showModalBottomSheet<TextbookBook>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 10, 18, 6),
              child: Text(
                '删除已导入的教材',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: Text(
                '只删 App 里这份导入记录，ima 里的原文件不受影响，以后还能重新导入。',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
            ),
            for (final book in books)
              ListTile(
                title: Text(book.title),
                subtitle: Text(
                  book.id == _scope.bookId
                      ? '${book.unitCount} 节 · 当前正在使用'
                      : '${book.unitCount} 节',
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: () => popRoute(context, book),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这本教材？'),
        content: Text(
          '「${picked.title}」和它的 ${picked.unitCount} 节章节会从 App 里删掉。'
          'ima 里的原文件不受影响，以后还能重新导入。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => popRoute(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => popRoute(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _deleteBook(picked);
  }

  Future<void> _deleteBook(TextbookBook book) async {
    if (_bookBusy) return;
    final generation = ++_generation;
    setState(() {
      _bookBusy = true;
      _tip = null;
    });
    try {
      final scopeCleared = await _textbook.deleteBook(
        studentId: _studentId,
        bookId: book.id,
      );
      if (!mounted) return;
      final wasSelected = _scope.bookId == book.id;
      setState(() {
        // 服务端已经清掉指向这本书的范围；本地**必须**同步清掉，
        // 否则家长随后点「保存范围」会把一个已经不存在的 bookId 写回去。
        if (wasSelected || scopeCleared) {
          _scope = _scope.copyWith(clearBook: true, startUnitNo: 1);
          _units = const <TextbookUnit>[];
        }
        _tipIsSuccess = true;
        _tip = (wasSelected || scopeCleared)
            ? '已删除「${book.title}」；原先指向它的范围设置也已清除。'
            : '已删除「${book.title}」。';
      });
      await _loadLibrary(generation, bookId: _scope.bookId);
    } catch (e) {
      if (!mounted) return;
      final text = e.toString();
      setState(() {
        _tipIsSuccess = false;
        _tip = '删除没成功：${text.length > 80 ? '${text.substring(0, 80)}…' : text}';
      });
    } finally {
      if (mounted) setState(() => _bookBusy = false);
    }
  }

  void _patch({
    int? dailyCount,
    String? difficulty,
    List<String>? points,
  }) {
    setState(() {
      _scope = _scope.copyWith(
        dailyCount: dailyCount,
        difficulty: difficulty,
        points: points,
      );
      _tip = null;
    });
  }

  void _togglePoint(String point) {
    final next = <String>[..._scope.points];
    if (next.remove(point)) {
      _patch(points: next);
      return;
    }
    if (next.length >= maxPoints) {
      setState(() {
        _tipIsSuccess = false;
        _tip = '最多 $maxPoints 条。想换的话先删一条。';
      });
      return;
    }
    next.add(point);
    _patch(points: next);
  }

  void _addCustom() {
    final point = _custom.text.trim();
    if (point.isEmpty) return;
    if (_scope.points.contains(point)) {
      _custom.clear();
      return;
    }
    if (_scope.points.length >= maxPoints) {
      setState(() {
        _tipIsSuccess = false;
        _tip = '最多 $maxPoints 条。想换的话先删一条。';
      });
      return;
    }
    _patch(points: <String>[..._scope.points, point]);
    _custom.clear();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_studentId.isEmpty) {
      setState(() {
        _tipIsSuccess = false;
        _tip = '还没选孩子，先回到计划页切换学生。';
      });
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await _repo.putScope(
        SubjectScope(
          studentId: _studentId,
          subject: _subject,
          dailyCount: _scope.dailyCount,
          difficulty: _scope.difficulty,
          points: _scope.points,
          // 教材三件套必须一起带上：漏掉 `bookId` 就是「保存成功，但书没了」
          // —— 而界面上那一行还显示着书名（本次的 `_scope` 没被覆盖）。
          bookId: _scope.bookId,
          bookTitle: _scope.bookTitle,
          startUnitNo: _scope.startUnitNo,
          unitsPerDay: _scope.unitsPerDay,
        ),
      );
      if (!mounted) return;
      setState(() {
        _scope = saved;
        _saving = false;
      });
      Get.back(result: true);
    } catch (e) {
      if (!mounted) return;
      final text = e.toString();
      setState(() {
        _tipIsSuccess = false;
        _tip = '保存没成功：${text.length > 70 ? '${text.substring(0, 70)}…' : text}';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = subjectColor(_subject);
    return Scaffold(
      appBar: AppBar(title: Text('$_subject · 范围配置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _header(accent),
                const SizedBox(height: 16),
                _textbookSection(accent),
                const SizedBox(height: 18),
                _sectionTitle('每天几题'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: kSubjectDailyCounts
                      .map((count) => ChoiceChip(
                            label: Text('$count 题'),
                            selected: _scope.dailyCount == count,
                            onSelected: (_) => _patch(dailyCount: count),
                          ))
                      .toList(),
                ),
                const SizedBox(height: 16),
                _sectionTitle('难度'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: kSubjectDifficulties
                      .map((level) => ChoiceChip(
                            label: Text(level),
                            selected: _scope.difficulty == level,
                            onSelected: (_) => _patch(difficulty: level),
                          ))
                      .toList(),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _difficultyHint(_scope.difficulty),
                    style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ),
                const SizedBox(height: 18),
                _sectionTitle('${subjectPointLabel(_subject)}（最多 $maxPoints 条）'),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '顺序就是优先级：出题时先考前面的。错题本里出现过的列在下面，'
                    '教材上还没考到的自己加一条。',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textMuted,
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                if (_scope.points.isNotEmpty) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: _scope.points
                        .map((point) => InputChip(
                              label: Text(point),
                              onDeleted: () => _togglePoint(point),
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 10),
                ],
                TextField(
                  controller: _custom,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _addCustom(),
                  decoration: InputDecoration(
                    hintText: _customHint(_subject),
                    suffixIcon: TextButton(
                      onPressed: _addCustom,
                      child: const Text('添加'),
                    ),
                  ),
                ),
                if (_seeds.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    '错题本里出现过的',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: _seeds
                        .map((point) => FilterChip(
                              label: Text(point),
                              selected: _scope.points.contains(point),
                              onSelected: (_) => _togglePoint(point),
                            ))
                        .toList(),
                  ),
                ],
                if (_tip != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _tip!,
                      style: TextStyle(
                        fontSize: 13,
                        color: _tipIsSuccess
                            ? accent
                            : (_saving ? AppColors.textMuted : AppColors.danger),
                      ),
                    ),
                  ),
                const SizedBox(height: 22),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? '保存中…' : '保存范围'),
                ),
                const SizedBox(height: 8),
                const Text(
                  '配一次就够了：以后在计划页点科目色块直接出题，不用再选。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                ),
              ],
            ),
    );
  }

  Widget _header(Color accent) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 34,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _subject,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: accent,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '这是「每次出什么」的默认值；改完保存，出题时直接用。',
                    style: TextStyle(fontSize: 12, height: 1.5),
                  ),
                  const SizedBox(height: 2),
                  // 题型先写在这里：家长看到「每天 5 题」时最想问的就是
                  // 「出什么题」，不说清就会以为是整张卷子（有解答题）。
                  Text(
                    kCheckinQuestionTypesLabel,
                    style: TextStyle(fontSize: 12, height: 1.5, color: accent),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _sectionTitle(String text) => Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
      );

  // ===== 教材 =====
  //
  // 这一块是**可选**的：没连 ima、没导入过书、027 没迁移，都只是少一块，
  // 下面「手填范围」照常可用。反过来，选了书就以书为准（服务端
  // `generateCheckin` 里教材优先）—— 两套范围并着算会让家长看不懂在考什么。

  Widget _textbookSection(Color accent) {
    // 没连接、也没有已导入的书：整块给一句话，不给按钮
    // （一个点了才失败的按钮比没有按钮更糟）。
    if (!_library.connected && _library.books.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(
          '没有连接 ima 也不影响：用下面的手填范围一样能出题。'
          '想按课本进度出题，再在 ima 里放一本教材。',
          style: TextStyle(fontSize: 12, color: AppColors.textMuted, height: 1.5),
        ),
      );
    }

    final selected = _scope.bookId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _sectionTitle('教材'),
            const SizedBox(width: 6),
            Text(
              '可选',
              style: TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
            const Spacer(),
            if (_library.connected)
              TextButton(
                onPressed: _bookBusy ? null : _openImportSheet,
                child: Text(_bookBusy ? '处理中…' : '从 ima 导入'),
              ),
          ],
        ),
        if (_library.books.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              _library.connected
                  ? 'ima 的「${_library.folderPath}」里放一份教材骨架 md，再从这里导入。'
                  : '还没有导入过教材。',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted, height: 1.5),
            ),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final book in _library.books)
                ChoiceChip(
                  label: Text('${book.title}（${book.unitCount} 节）'),
                  selected: selected == book.id,
                  onSelected: (_) => selected == book.id ? _clearBook() : _selectBook(book),
                ),
            ],
          ),
        if (_library.books.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _bookBusy ? null : _openDeleteSheet,
              child: Text(_bookBusy ? '处理中…' : '删除已导入'),
            ),
          ),
        if (selected != null && selected.isNotEmpty) ...[
          const SizedBox(height: 10),
          GradeTermMismatchNotice(
            bookGrade: _selectedBook?.grade ?? '',
            bookTerm: _selectedBook?.term ?? '',
            profileGrade: _profile?.grade ?? '',
            profileTerm: _profile?.term ?? '',
          ),
          if (_units.isEmpty)
            Text(
              '这本书的章节没读出来（可能刚删了或网络抖动）。点书名可以取消选书。',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted, height: 1.5),
            )
          else ...[
            DropdownButtonFormField<int>(
              // 书重新导入后章节可能变少：当前值不在列表里就让下拉自己退回第一节，
              // 而不是抛「value 不在 items 里」（那是一条红屏）。
              initialValue: _units.any((u) => u.unitNo == _scope.startUnitNo)
                  ? _scope.startUnitNo
                  : _units.first.unitNo,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '从第几节开始',
                helperText: '出一次题往后走，不用天天改',
              ),
              items: [
                for (final unit in _units)
                  DropdownMenuItem<int>(
                    value: unit.unitNo,
                    child: Text(unit.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _scope = _scope.copyWith(startUnitNo: value);
                  _tip = null;
                });
              },
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text('每天几节', style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
                const SizedBox(width: 10),
                for (final perDay in const <int>[1, 2, 3]) ...[
                  ChoiceChip(
                    label: Text('$perDay 节'),
                    selected: _scope.unitsPerDay == perDay,
                    onSelected: (_) => setState(() {
                      _scope = _scope.copyWith(unitsPerDay: perDay);
                      _tip = null;
                    }),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '选了教材就按课本走：出题只用这几节的考点，下面手填的「${subjectPointLabel(_subject)}」暂时不参与。',
                style: TextStyle(fontSize: 12, color: accent, height: 1.5),
              ),
            ),
          ],
        ],
        const SizedBox(height: 6),
      ],
    );
  }

  static String _difficultyHint(String level) {
    switch (level) {
      case '提高':
        return '需要两步，或先做一次转换。';
      case '挑战':
        return '两个概念一起用，或要绕过常见的直觉错误。';
      default:
        return '一步就能出答案，适合每天巩固。';
    }
  }

  static String _customHint(String subject) {
    switch (subject) {
      case '语文':
        return '例如：《观沧海》默写、第二单元字词';
      case '历史':
        return '例如：1840 鸦片战争、商鞅变法';
      case '英语':
        return '例如：一般现在时、名词复数、Unit 3 句型（单词在词表页配）';
      default:
        return '例如：有理数加减、整式化简';
    }
  }
}
