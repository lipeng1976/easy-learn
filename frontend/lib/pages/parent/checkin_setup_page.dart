import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../models/checkin_models.dart';
import '../../models/subject_scope.dart';
import '../../repositories/checkin_repository.dart';
import '../../services/data_api_client.dart';
import '../../services/database_service.dart';
import '../../services/homework_item_normalizer.dart';

/// 家长发起打卡时的范围设置。
///
/// ## 为什么是一个独立页面，而不是打卡页上的一段表单
///
/// 要选四组东西（学科 / 知识点 / 数量 / 难度），知识点还可能十几条。
/// 塞进打卡页的空态卡里，那张卡会长到把「今天做没做」这个最重要的信息
/// 挤到屏幕外。而且学生端根本不需要这些 —— 学生只有「出 5 道题」。
///
/// ## 这一页只负责「收集范围」
///
/// 它**不**调模型、不落库：选完 `Get.back(result: ...)` 把范围交回打卡页，
/// 由那边统一的 `start()` 发起。分两处发起的话，「出题失败怎么提示」
/// 要写两遍，而两边一定会长得不一样。
///
/// 返回 [CheckinSetup]；用户直接返回时是 null（什么都不做）。
class CheckinSetupPage extends StatefulWidget {
  const CheckinSetupPage({super.key, this.studentId, this.repository});

  /// 这份打卡挂在谁名下（家长端 = 孩子）。空值服务端会 400，所以在入口就传好。
  final String? studentId;

  /// 只为测试注入；线上走 [DatabaseService.checkin]。
  final CheckinRepository? repository;

  @override
  State<CheckinSetupPage> createState() => _CheckinSetupPageState();
}

class _CheckinSetupPageState extends State<CheckinSetupPage> {
  /// 与服务端 `MAX_SEED_POINTS` / 网关 `MAX_CHECKIN_ITEMS` 同一个数。
  /// 界面先拦住，别等用户选完了再由服务端 400 —— 那时他已经忘了选过哪些。
  static const int maxPoints = 6;

  /// 题量档位。不给 1 和 10 的自由输入：一分钟能做完的量就那么几档，
  /// 输个 9 出来的题要么敷衍、要么做不完。
  static const List<int> countChoices = [3, 5, 8];

  static const Map<String, String> difficultyHints = {
    '基础': '一步就能出答案，适合每天巩固。',
    '提高': '需要两步，或先做一次转换（去括号、通分）。',
    '挑战': '两个概念一起用，或要绕过常见的直觉错误。',
  };

  late final CheckinRepository _repo;
  final TextEditingController _custom = TextEditingController();

  /// 已选知识点，**顺序即优先级**（所以用 List 不用 Set）。
  final List<String> _selected = [];

  String _subject = '数学';
  int _count = 5;
  String _difficulty = '基础';

  List<CheckinSeed> _seeds = const [];
  bool _loadingSeeds = true;
  String? _seedsError;

  /// 切科目会连发几次请求；只有最后一次的结果能落地，否则「切到语文、
  /// 数学的候选后到」会把语文候选覆盖掉。
  int _seedGeneration = 0;

  /// 内联提示（「最多选 6 个」这类）。不用 SnackBar：
  /// 它是一次性的，而这里说的是一个**持续存在的状态**。
  String? _tip;

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? DatabaseService.checkin;
    _loadSeeds();
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  Future<void> _loadSeeds() async {
    setState(() {
      _loadingSeeds = true;
      _seedsError = null;
    });
    final generation = ++_seedGeneration;
    final subject = _subject;
    try {
      // 带上科目：家长切到「语文」时，候选里不能再出现数学的知识点
      // （勾上之后出的语文题会夹着「整式化简」，界面上完全看不出来）。
      final seeds = await _repo.loadSeeds(studentId: widget.studentId, subject: subject);
      if (!mounted || generation != _seedGeneration) return;
      setState(() {
        _seeds = seeds;
        _loadingSeeds = false;
      });
    } on DataApiException catch (e) {
      if (!mounted || generation != _seedGeneration) return;
      setState(() {
        _seedsError = e.userMessage;
        _loadingSeeds = false;
      });
    }
  }

  /// 换科目：已勾的知识点必须清掉。
  ///
  /// 不清的话，家长勾了「整式化简」再切「语文」，那一条会作为语文范围被
  /// 送去出题 —— 服务端只保证「题在指定范围内」，不会替你判断这条是不
  /// 是别的科的知识点。
  void _pickSubject(String subject) {
    if (subject == _subject) return;
    setState(() {
      _subject = subject;
      _selected.clear();
      _tip = null;
    });
    _loadSeeds();
  }

  /// 勾 / 取消一个知识点。
  void _toggle(String point) {
    setState(() {
      if (_selected.remove(point)) {
        _tip = null;
        return;
      }
      if (_selected.length >= maxPoints) {
        _tip = '最多选 $maxPoints 个知识点。想换的话先取消一个。';
        return;
      }
      _selected.add(point);
      _tip = null;
    });
  }

  /// 手输一个候选里没有的知识点。
  ///
  /// 这是家长「提前练」的入口：错题本只能反映已经错过什么，
  /// 而家长可能知道下周要考哪一章。允许加，但不假装它有历史数据。
  void _addCustom() {
    final point = _custom.text.trim();
    if (point.isEmpty) return;
    if (_selected.contains(point)) {
      _custom.clear();
      return;
    }
    if (_selected.length >= maxPoints) {
      setState(() => _tip = '最多选 $maxPoints 个知识点。想换的话先取消一个。');
      return;
    }
    setState(() {
      _selected.add(point);
      _custom.clear();
      _tip = null;
    });
  }

  void _submit() {
    Get.back(
      result: CheckinSetup(
        subject: _subject,
        count: _count,
        knowledgePoints: List.unmodifiable(_selected),
        difficulty: _difficulty,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置今天的打卡')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _section(
            title: '学科',
            subtitle: '$kCheckinQuestionTypesLabel，孩子做错当场就知道对错。',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                // 科目清单唯一来源见 HomeworkItemNormalizer：那边与
                // HomeworkTextParser 的正则同一集合。这里另写一份的话，
                // 识别得出的科目会在选择器里找不到。
                for (final subject in HomeworkItemNormalizer.subjectNames)
                  ChoiceChip(
                    label: Text(subject),
                    selected: _subject == subject,
                    onSelected: (_) => _pickSubject(subject),
                  ),
              ],
            ),
          ),
          _section(
            title: '知识点',
            trailing: '已选 ${_selected.length}/$maxPoints',
            subtitle: '按你勾的顺序出题，越靠前越先考。'
                '一个都不勾，就按错题本里错得最多的几个自动挑。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_selected.isNotEmpty) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final point in _selected)
                        InputChip(
                          label: Text(point),
                          onDeleted: () => _toggle(point),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                _seedList(),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _custom,
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: '没有想要的？输入一个知识点',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _addCustom(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(onPressed: _addCustom, child: const Text('添加')),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  '输入的知识点如果还没有错题记录，孩子可能是第一次练它 —— '
                  '题目会按你选的难度出。',
                  style: TextStyle(fontSize: 12, color: AppColors.textMuted, height: 1.4),
                ),
              ],
            ),
          ),
          _section(
            title: '题量',
            subtitle: '一分钟能做完的量。',
            child: Wrap(
              spacing: 8,
              children: [
                for (final count in countChoices)
                  ChoiceChip(
                    label: Text('$count 题'),
                    selected: _count == count,
                    onSelected: (_) => setState(() => _count = count),
                  ),
              ],
            ),
          ),
          _section(
            title: '难度',
            subtitle: difficultyHints[_difficulty],
            child: Wrap(
              spacing: 8,
              children: [
                for (final level in kCheckinDifficulties)
                  ChoiceChip(
                    label: Text(level),
                    selected: _difficulty == level,
                    onSelected: (_) => setState(() => _difficulty = level),
                  ),
              ],
            ),
          ),
          if (_tip != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _tip!,
                style: const TextStyle(color: AppColors.warning, fontSize: 13),
              ),
            ),
          const SizedBox(height: 4),
          FilledButton(
            onPressed: _submit,
            child: const Text('出题'),
          ),
          const SizedBox(height: 8),
          const Text(
            '出题要几秒，这段时间别退出。出好之后孩子打开打卡就能直接做。',
            style: TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }

  /// 候选列表。三种状态各自渲染，**不要**把「还在加载」落进 isEmpty 分支 ——
  /// 那会让加载中的一瞬显示「你还没有错题」，然后跳成十几条。
  Widget _seedList() {
    if (_loadingSeeds) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 10),
            Text('正在读错题知识点…', style: TextStyle(color: AppColors.textMuted)),
          ],
        ),
      );
    }
    if (_seedsError != null) {
      return Row(
        children: [
          Expanded(
            child: Text(
              _seedsError!,
              style: const TextStyle(color: AppColors.danger, fontSize: 13),
            ),
          ),
          TextButton(onPressed: _loadSeeds, child: const Text('重试')),
        ],
      );
    }
    if (_seeds.isEmpty) {
      return const Text(
        '错题本还没有知识点记录。可以直接在下面输入要练什么。',
        style: TextStyle(color: AppColors.textMuted, fontSize: 13, height: 1.4),
      );
    }
    return Column(
      children: [
        for (final seed in _seeds)
          CheckboxListTile(
            value: _selected.contains(seed.knowledge),
            onChanged: (_) => _toggle(seed.knowledge),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(seed.knowledge, style: const TextStyle(fontSize: 14)),
            subtitle: Text(
              seed.wrongCount > 0 ? '错过 ${seed.wrongCount} 次' : '还没有错题记录',
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
      ],
    );
  }

  Widget _section({
    required String title,
    required Widget child,
    String? subtitle,
    String? trailing,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                const Spacer(),
                if (trailing != null)
                  Text(
                    trailing,
                    style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 12, color: AppColors.textMuted, height: 1.4),
              ),
            ],
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}
