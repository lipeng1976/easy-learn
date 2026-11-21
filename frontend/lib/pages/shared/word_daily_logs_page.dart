import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/parent_controller.dart';
import '../../models/word_checkin.dart';
import '../../services/database_service.dart';

/// 单词打卡历史：一天一行，倒序。两端共用 —— 家长看当前伴学的孩子，
/// 学生看自己。切孩子时重新拉，快速切换用 generation 丢掉迟到响应。
class WordDailyLogsPage extends StatefulWidget {
  const WordDailyLogsPage({super.key});

  @override
  State<WordDailyLogsPage> createState() => _WordDailyLogsPageState();
}

class _WordDailyLogsPageState extends State<WordDailyLogsPage> {
  List<WordDailyResult> _results = const <WordDailyResult>[];
  bool _loading = true;
  int _generation = 0;
  Worker? _worker;

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

  String _studentId() {
    if (Get.isRegistered<ParentController>()) {
      final id = Get.find<ParentController>().selectedStudentId.value;
      if (id.isNotEmpty) return id;
    }
    // 学生端：直接用自己的 id（AuthController）。
    if (Get.isRegistered<AuthController>()) {
      return Get.find<AuthController>().currentUser.value?.id ?? '';
    }
    return '';
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final studentId = _studentId();
    if (studentId.isEmpty) return;
    if (mounted) setState(() => _loading = true);
    try {
      final rows = await DatabaseService.word.listDaily(
        studentId: studentId,
        limit: 200,
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
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('单词打卡记录'),
          actions: [
            IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _results.isEmpty
                ? const Center(child: Text('还没有单词打卡记录'))
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final one = _results[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          leading: const Icon(Icons.calendar_today_outlined),
                          title: Text(one.day),
                          subtitle: Text(
                            '答对 ${one.correct}/${one.total} · '
                            '正确率 ${(one.accuracy * 100).round()}% · 连续 ${one.streak} 天'
                            '${one.wrongWords.isEmpty ? '' : '\n错词：${one.wrongWords.join('、')}'}',
                          ),
                          isThreeLine: one.wrongWords.isNotEmpty,
                        ),
                      );
                    },
                  ),
      );
}
