import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:easy_learn_app/models/wish_model.dart';

/// 心愿列表展示顺序的判据。
///
/// 口径：申请兑现时间越新越靠前；没申请过的按期望日期近的在前；最后 id 稳定。
/// 三处必须一致：模型比较器、家长端页面、学生端页面。服务端 `wish.js` 的
/// ORDER BY 在 data.test.js 里有对应判据。
WishModel wish({
  required String id,
  DateTime? requestedAt,
  DateTime? expectedDate,
  bool isArchived = false,
}) =>
    WishModel(
      id: id,
      title: '心愿$id',
      description: '',
      isPublic: true,
      parentConfirmed: false,
      studentConfirmed: false,
      isArchived: isArchived,
      studentId: 'stu_1',
      expectedDate: expectedDate,
      redeemRequestedAt: requestedAt,
    );

void main() {
  test('比较器：申请时间降序，没申请的按期望日期降序，最后 id 稳定', () {
    final rows = [
      wish(id: 'a', expectedDate: DateTime(2026, 12, 1)),
      wish(id: 'b', requestedAt: DateTime(2026, 11, 20, 10)),
      wish(id: 'c', requestedAt: DateTime(2026, 11, 22, 9)),
      wish(id: 'd', expectedDate: DateTime(2026, 12, 10)),
      wish(id: 'e', requestedAt: DateTime(2026, 11, 22, 9)),
    ];
    sortWishesByRequestTimeDesc(rows);
    expect(rows.map((w) => w.id).toList(), ['c', 'e', 'b', 'd', 'a'],
        reason: 'c/e 同申请时间按 id 升序；b 次之；没申请的 d 期望日期更近在前');
  });

  test('比较器：只有期望日期时也按近的在前，全空按 id', () {
    final rows = [
      wish(id: 'a'),
      wish(id: 'b', expectedDate: DateTime(2026, 12, 1)),
      wish(id: 'c', expectedDate: DateTime(2026, 11, 1)),
    ];
    sortWishesByRequestTimeDesc(rows);
    expect(rows.map((w) => w.id).toList(), ['b', 'c', 'a']);
  });

  test('源码契约：模型比较器 + 家长端 + 学生端三处调用同一排序', () {
    final model =
        File('lib/models/wish_model.dart').readAsStringSync();
    final parent =
        File('lib/pages/parent/tabs/wishes_parent_tab.dart').readAsStringSync();
    final student =
        File('lib/pages/student/tabs/wish_tab.dart').readAsStringSync();

    expect(model.contains('compareByRequestTimeDesc'), isTrue,
        reason: '比较器只许在模型里定义一次');
    expect(parent.contains('sortWishesByRequestTimeDesc('), isTrue,
        reason: '家长端多孩子拼接会打乱服务端顺序，必须在页面排序');
    expect(student.contains('sortWishesByRequestTimeDesc('), isTrue,
        reason: '学生端 insert(0) 后不重拉，也会跟服务端顺序不一致');
  });
}
