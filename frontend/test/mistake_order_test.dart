import 'dart:io';

import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/db_test_helper.dart';

/// 错题列表的顺序。
///
/// ## 为什么这条要单独盯
///
/// `queryReviewMistakes` 原先**没有任何 `order by`**，返回的是数据库物理顺序。
/// 物理顺序在「删过几行、插过几批」之后与时间基本无关，而界面上看不出来 ——
/// 用户只会觉得「提交完作业的错题找不到了」。要找到它，只能靠翻。
///
/// 现在改成在 Dart 里排序（[ReviewMistake.byNewestFirst]），三种数据源
/// （服务端 / sqlite / Web 内存表）共用同一个比较函数。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Directory? tempDir;

  setUp(() async {
    tempDir = await setUpTestDatabase();
  });

  tearDown(() async {
    final dir = tempDir;
    if (dir != null) await tearDownTestDatabase(dir);
  });

  ReviewMistake make(
    String id,
    DateTime createdAt, {
    String homeworkId = 'hw_order',
  }) => ReviewMistake(
    id: id,
    subject: '数学',
    title: '第 $id 题',
    originalAnswer: '1',
    wrongReason: '算错了',
    createdAt: createdAt,
    state: ReviewState.pending,
    studentId: 'stu_001',
    homeworkId: homeworkId,
  );

  /// 只挑本用例造的行：`setUpTestDatabase` 会灌演示数据（里面也有错题），
  /// 拿全表长度当判据会得到一条与排序无关的红。
  List<String> idsOf(List<ReviewMistake> rows, String prefix) => rows
      .map((row) => row.id)
      .where((id) => id.startsWith(prefix))
      .toList();

  test('列表按时间倒序：最新提交的那次作业排在最前', () async {
    await DatabaseService.instance.insertReviewMistakes([
      make('ord_mid', DateTime(2026, 10, 19, 9)),
      make('ord_old', DateTime(2026, 10, 18, 9)),
      make('ord_new', DateTime(2026, 10, 20, 9)),
    ]);

    final rows = await DatabaseService.instance.queryReviewMistakes();

    expect(
      idsOf(rows, 'ord_'),
      ['ord_new', 'ord_mid', 'ord_old'],
      reason: '错题本没有按时间排，用户找不到刚提交那次的错题',
    );
  });

  test('同一时刻入库的错题有确定顺序（不会每次查询都换一个样）', () async {
    // 一次批改写进来的错题 `createdAt` 完全相同，这是真实情况而不是构造。
    final sameMoment = DateTime(2026, 10, 20, 9, 30);
    await DatabaseService.instance.insertReviewMistakes([
      make('tie_a', sameMoment),
      make('tie_c', sameMoment),
      make('tie_b', sameMoment),
    ]);

    final first = await DatabaseService.instance.queryReviewMistakes();
    final second = await DatabaseService.instance.queryReviewMistakes();

    expect(idsOf(first, 'tie_'), ['tie_c', 'tie_b', 'tie_a'], reason: '同时刻用 id 倒序兜底');
    expect(
      idsOf(second, 'tie_'),
      idsOf(first, 'tie_'),
      reason: '两次查询顺序不同 = 列表会自己动',
    );
  });

  test('按作业查错题：只出这份作业的，且最新在前', () async {
    await DatabaseService.instance.insertReviewMistakes([
      make('hw_a_old', DateTime(2026, 10, 18, 9), homeworkId: 'hw_a'),
      make('hw_a_new', DateTime(2026, 10, 20, 9), homeworkId: 'hw_a'),
      make('hw_b_only', DateTime(2026, 10, 19, 9), homeworkId: 'hw_b'),
    ]);

    final rows = await DatabaseService.instance
        .queryReviewMistakesByHomeworkId('hw_a');

    expect(idsOf(rows, 'hw_a_'), ['hw_a_new', 'hw_a_old']);
    expect(
      idsOf(rows, 'hw_b_'),
      isEmpty,
      reason: '别的作业的错题混进来了 —— 学生会看到不属于这次作业的题',
    );
  });

  test('排序比较函数本身：先比时间，再比 id', () {
    final a = make('m_a', DateTime(2026, 10, 20, 9));
    final b = make('m_b', DateTime(2026, 10, 20, 9));
    final older = make('m_c', DateTime(2026, 10, 19, 9));

    expect(ReviewMistake.byNewestFirst(a, older), lessThan(0));
    expect(ReviewMistake.byNewestFirst(older, a), greaterThan(0));
    expect(ReviewMistake.byNewestFirst(b, a), lessThan(0), reason: '同时刻 id 大者在前');
    expect(ReviewMistake.byNewestFirst(a, a), 0);
  });
}
