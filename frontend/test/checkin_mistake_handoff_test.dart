import 'package:easy_learn_app/models/checkin_models.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// 计划 → 复习的交接。
///
/// 2026-11-12 划定的边界：
/// - **复习**只从错题本出发（错题 + 由错题引出的举一反三，题型不受限，
///   可以打印出来做完再回传批改）；
/// - **计划**只从教材 / 家长指定的知识点出发，只出选择、判断，
///   做错的题**必须进错题本**，成为复习的原料。
///
/// 这条链断在哪一环，界面上都看不出来：孩子做错了、成绩也存了，
/// 只是复习队列里永远不多出那道题。所以这里盯的是「服务端说的数字
/// 有没有被客户端如实带出来」。
void main() {
  test('交卷结果如实带出「几道错题进了错题本」', () {
    final parsed = CheckinSubmitResult.fromJson(const {
      'quizId': 'ck_1',
      'score': 3,
      'total': 5,
      'items': <Object>[],
      'mistakes': {'added': 2, 'failed': false},
    });

    expect(parsed.mistakesAdded, 2);
    expect(parsed.mistakesFailed, isFalse);
  });

  test('归档失败要单独标出来（成绩已保存，别让人以为复习里会有）', () {
    final parsed = CheckinSubmitResult.fromJson(const {
      'quizId': 'ck_1',
      'score': 3,
      'total': 5,
      'items': <Object>[],
      'mistakes': {'added': 0, 'failed': true},
    });

    expect(parsed.mistakesAdded, 0);
    expect(parsed.mistakesFailed, isTrue);
  });

  test('老服务端没有 mistakes 字段：按 0 处理，不报错也不提示', () {
    final parsed = CheckinSubmitResult.fromJson(const {
      'quizId': 'ck_1',
      'score': 5,
      'total': 5,
      'items': <Object>[],
    });

    expect(parsed.mistakesAdded, 0);
    expect(parsed.mistakesFailed, isFalse);
  });

  test('打卡来的错题有自己的来源标签，不冒充作业批改', () {
    // 冒充 `homework` 会让「这份作业产生了哪些错题」里多出几道
    // 根本不在作业里的题，而作业详情页不会报错，只是列得莫名其妙。
    expect(MistakeSource.checkin.label, '每日打卡');
    expect(mistakeSourceOf('checkin'), MistakeSource.checkin);
    expect(mistakeSourceOf('nope'), MistakeSource.manual);
  });
}
