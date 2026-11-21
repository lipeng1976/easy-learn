import 'package:easy_learn_app/models/knowledge_tip.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/services/knowledge_tip_service.dart';
import 'package:easy_learn_app/services/knowledge_tip_store.dart';
import 'package:easy_learn_app/services/simulated_ai_data_source.dart';
import 'package:flutter_test/flutter_test.dart';

/// 全局唯一的进程内缓存：判据要能看到「写了什么、什么时候没写」。
class _Store implements KnowledgeTipStore {
  final List<KnowledgeTip> rows = <KnowledgeTip>[];
  int writes = 0;
  Object? error;

  @override
  Future<List<KnowledgeTip>> queryKnowledgeTips({
    required String studentId,
    required String subject,
  }) async {
    final e = error;
    if (e != null) throw e;
    return rows
        .where((row) => row.studentId == studentId && row.subject == subject)
        .toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  }

  @override
  Future<void> replaceKnowledgeTips({
    required String studentId,
    required String subject,
    required List<KnowledgeTip> tips,
  }) async {
    final e = error;
    if (e != null) throw e;
    writes += 1;
    rows.removeWhere(
      (row) => row.studentId == studentId && row.subject == subject,
    );
    rows.addAll(tips);
  }
}

class _Ai extends SimulatedAiDataSource {
  _Ai(this.drafts);

  List<MistakeTipDraft> drafts;
  int calls = 0;
  Object? error;

  @override
  Future<List<MistakeTipDraft>> summarizeMistakeTips({
    required String subject,
    required List<MistakeTipSeed> items,
  }) async {
    calls += 1;
    final e = error;
    if (e != null) throw e;
    return drafts;
  }
}

class _Clock {
  DateTime value = DateTime(2026, 10, 19, 9, 0, 0);

  DateTime call() => value;

  void advance(Duration d) => value = value.add(d);
}

ReviewMistake _mistake({
  required String id,
  required String point,
  int wrongCount = 1,
  String subject = '数学',
  String reason = '',
  DateTime? masteredAt,
}) => ReviewMistake(
  id: id,
  subject: subject,
  title: '作业 · $point',
  originalAnswer: '',
  wrongReason: reason,
  createdAt: DateTime(2026, 10, 1),
  state: ReviewState.pending,
  studentId: 'stu_1',
  knowledgePoint: point,
  wrongCount: wrongCount,
  lastWrongAt: DateTime(2026, 10, 10),
  masteredAt: masteredAt,
);

void main() {
  group('按知识点聚合', () {
    test('只算当前科目、只算没毕业的，错题次数累加', () {
      final seeds = KnowledgeTipService.seedsFrom([
        _mistake(id: 'a', point: '分式化简', wrongCount: 2),
        _mistake(id: 'b', point: '分式化简', wrongCount: 1),
        _mistake(id: 'c', point: '勾股定理'),
        // 这三个都不该出现：
        _mistake(id: 'd', point: '古诗默写', subject: '语文', wrongCount: 9),
        _mistake(id: 'e', point: '已掌握的知识点', masteredAt: DateTime(2026, 10, 12)),
        _mistake(id: 'f', point: '  '),
      ], '数学');

      expect(seeds.map((seed) => seed.knowledgePoint), ['分式化简', '勾股定理']);
      expect(seeds.first.wrongCount, 3);
    });

    test('错得多的排前面；最多 12 个', () {
      final pool = [
        for (var i = 0; i < 15; i++)
          _mistake(id: 'm$i', point: '知识点$i', wrongCount: i + 1),
      ];
      final seeds = KnowledgeTipService.seedsFrom(pool, '数学');
      expect(seeds, hasLength(12));
      expect(seeds.first.knowledgePoint, '知识点14');
    });

    test('错题池变了，指纹就变 —— 否则会一直显示上一批提示', () {
      final before = KnowledgeTipService.signatureFor('数学', [
        const MistakeTipSeed(knowledgePoint: '分式化简', wrongCount: 1),
      ]);
      final after = KnowledgeTipService.signatureFor('数学', [
        const MistakeTipSeed(knowledgePoint: '分式化简', wrongCount: 2),
      ]);
      expect(before, isNot(after));
    });
  });

  group('载入与缓存', () {
    late _Clock clock;
    late _Store store;
    late _Ai ai;
    late KnowledgeTipService service;

    setUp(() {
      clock = _Clock();
      store = _Store();
      ai = _Ai(const [
        MistakeTipDraft(
          knowledgePoint: '分式化简',
          text: '分式加减先通分，分母不变。',
        ),
      ]);
      service = KnowledgeTipService(ai: ai, store: store, clock: clock.call);
    });

    tearDown(() => service.dispose());

    test('第一次：用模型提示，并写进缓存', () async {
      await service.load(
        studentId: 'stu_1',
        subject: '数学',
        pool: [_mistake(id: 'a', point: '分式化简')],
      );

      expect(service.tips.value.single.text, '分式加减先通分，分母不变。');
      expect(service.tips.value.single.source, KnowledgeTipSource.model);
      expect(store.writes, 1);
      expect(store.rows.single.subject, '数学');
      expect(store.rows.single.studentId, 'stu_1');
    });

    test('同一份错题池再进页面：不发第二次请求', () async {
      final pool = [_mistake(id: 'a', point: '分式化简')];
      await service.load(studentId: 'stu_1', subject: '数学', pool: pool);
      await service.load(studentId: 'stu_1', subject: '数学', pool: pool);

      expect(ai.calls, 1, reason: '缓存命中还发请求，等于每次开计时页都花一次钱');
      expect(service.tips.value.single.text, '分式加减先通分，分母不变。');
    });

    test('错题池变了：重新生成，旧提示被整体替换', () async {
      await service.load(
        studentId: 'stu_1',
        subject: '数学',
        pool: [_mistake(id: 'a', point: '分式化简')],
      );

      ai.drafts = const [
        MistakeTipDraft(
          knowledgePoint: '一元二次方程',
          text: '先算判别式。',
        ),
      ];
      await service.load(
        studentId: 'stu_1',
        subject: '数学',
        pool: [
          _mistake(id: 'a', point: '分式化简'),
          _mistake(id: 'b', point: '一元二次方程'),
        ],
      );

      expect(ai.calls, 2);
      expect(service.tips.value.single.knowledgePoint, '一元二次方程');
      expect(
        store.rows.where((row) => row.knowledgePoint == '分式化简'),
        isEmpty,
        reason: '旧提示必须删掉，否则「换一条」还会转到已经不在池里的知识点',
      );
    });

    test('模型失败：退回规则提示，而且不写缓存', () async {
      ai.error = Exception('断网了');
      await service.load(
        studentId: 'stu_1',
        subject: '数学',
        pool: [_mistake(id: 'a', point: '分式化简', wrongCount: 2)],
      );

      final tip = service.tips.value.single;
      expect(tip.source, KnowledgeTipSource.rule);
      expect(tip.text, contains('分式化简'));
      expect(tip.text, contains('2 次'), reason: '规则提示写的是真实的错题次数');
      expect(
        store.writes,
        0,
        reason: '把降级结果按当前指纹写进缓存 = 一次断网换来三天不再重试',
      );
    });

    test('降级产物（rule）不写缓存，并且冷却期内不反复请求', () async {
      ai.drafts = const [
        MistakeTipDraft(
          knowledgePoint: '分式化简',
          text: '先用一句话说出它的定义。',
          source: KnowledgeTipSource.rule,
        ),
      ];
      final pool = [_mistake(id: 'a', point: '分式化简')];

      await service.load(studentId: 'stu_1', subject: '数学', pool: pool);
      expect(store.writes, 0);

      await service.load(studentId: 'stu_1', subject: '数学', pool: pool);
      expect(ai.calls, 1, reason: '刚失败过就再等 30 秒，对正在做题的人是打扰');

      clock.advance(const Duration(minutes: 6));
      await service.load(studentId: 'stu_1', subject: '数学', pool: pool);
      expect(ai.calls, 2, reason: '冷却结束要允许重试');
    });

    test('这个科目没有错题：不给提示，也不请求模型', () async {
      await service.load(
        studentId: 'stu_1',
        subject: '数学',
        pool: [_mistake(id: 'a', point: '古诗默写', subject: '语文')],
      );

      expect(service.tips.value, isEmpty);
      expect(service.seedCount.value, 0);
      expect(ai.calls, 0);
    });

    test('缓存读坏了也不影响显示', () async {
      store.error = Exception('no such table: knowledge_tip');
      await service.load(
        studentId: 'stu_1',
        subject: '数学',
        pool: [_mistake(id: 'a', point: '分式化简')],
      );

      expect(service.tips.value, isNotEmpty, reason: '老库缺表时提示区不该是空的');
      expect(service.tips.value.single.source, KnowledgeTipSource.model);
    });
  });
}
