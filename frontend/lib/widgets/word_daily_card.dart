import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/parent_controller.dart';
import '../models/word_checkin.dart';
import '../services/database_service.dart';
import '../utils/word_selector.dart';

/// 家长端计划页的单词打卡卡：今日完成 / 正确率 / 连续天数 / 错词。
///
/// 云上只是**摘要**（服务端不复算判分），离线期间看不到当天结果 —— 恢复网络
/// 后自动补上，卡片不会因此弹红条。切孩子 / 晚到的 boundStudents 都靠
/// `ever` 重拉，快速切换用 generation 丢掉迟到响应（阅读记录同款坑）。
class WordDailyCard extends StatefulWidget {
  const WordDailyCard({super.key, this.isParent = true});

  final bool isParent;

  @override
  State<WordDailyCard> createState() => _WordDailyCardState();
}

class _WordDailyCardState extends State<WordDailyCard> {
  List<WordDailyResult> _results = const <WordDailyResult>[];
  int _generation = 0;
  Worker? _worker;
  bool _loading = false;

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

  String? _studentId() {
    if (!Get.isRegistered<ParentController>()) return null;
    final id = Get.find<ParentController>().selectedStudentId.value;
    return id.isEmpty ? null : id;
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final studentId = _studentId();
    if (studentId == null) return; // 晚到时 ever 会再拉一次
    if (mounted) setState(() => _loading = true);
    try {
      final rows = await DatabaseService.word.listDaily(
        studentId: studentId,
        limit: 30,
      );
      if (generation != _generation || !mounted) return;
      setState(() => _results = rows);
    } catch (_) {
      if (generation == _generation && mounted) {
        setState(() => _results = const <WordDailyResult>[]);
      }
    } finally {
      if (generation == _generation && mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final today = WordSelector.dateKeyOf(DateTime.now());
    final todayResult = _results.where((r) => r.day == today).toList();
    final one = todayResult.isEmpty ? null : todayResult.first;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.translate_outlined, size: 20),
                const SizedBox(width: 8),
                const Text(
                  '英语单词打卡',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                if (_loading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (one == null)
              const Text('今天还没有单词打卡记录', style: TextStyle(fontSize: 13))
            else ...[
              Text(
                '今天完成 ${one.total} 题 · 答对 ${one.correct} 题 · '
                '正确率 ${(one.accuracy * 100).round()}% · 连续 ${one.streak} 天',
                style: const TextStyle(fontSize: 13),
              ),
              if (one.wrongWords.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '错词：${one.wrongWords.join('、')}',
                    style: TextStyle(fontSize: 12, color: Colors.red.shade700),
                  ),
                ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => Get.toNamed('/word-daily-logs'),
                  child: const Text('历史记录'),
                ),
                if (widget.isParent)
                  OutlinedButton(
                    onPressed: () async {
                      await Get.toNamed('/word-scope');
                      await _load();
                    },
                    child: const Text('配置词表'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
