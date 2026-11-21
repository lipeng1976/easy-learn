import 'package:easy_learn_app/models/reading_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 阅读模型。
///
/// 这里压的是**渲染前就会炸掉整张卡**的那几个值。它们有一个共同点：
/// 出错时不会抛异常、也不会让接口失败，只会让界面安静地消失或显示 0：
///
///   · `progress` 返回 NaN → `LinearProgressIndicator(value: NaN)` 抛断言，
///     整张入口卡连同页面一起变红；
///   · `totalLessons == 0` 时算除法 → 同上；
///   · `nextLessonNo` 用 0 表示「没有下一篇」→ 判空写错就变成「读第 0 篇」；
///   · 正文按单个 `\n` 断段 → 原书折行的地方变成好几个短段，
///     一篇文章看起来像诗。
void main() {
  group('ReadingTask', () {
    ReadingTask task({
      int done = 0,
      int total = 0,
      int? next,
      String status = 'active',
      bool finished = false,
      List<int> read = const [],
    }) =>
        ReadingTask(
          id: 'rt_1',
          bookId: 'rb_1',
          bookTitle: '感动世界的文字',
          status: status,
          doneLessons: done,
          totalLessons: total,
          nextLessonNo: next,
          finished: finished,
          readLessonNos: read,
        );

    test('进度：总篇数为 0 时返回 0，不是 NaN', () {
      final progress = task().progress;
      expect(progress.isNaN, isFalse);
      expect(progress, 0);
    });

    test('进度：夹在 0~1 之间（历史数据多出一篇也不会画出 1.02 的条）', () {
      expect(task(done: 3, total: 96).progress, closeTo(3 / 96, 1e-9));
      expect(task(done: 97, total: 96).progress, 1.0);
    });

    test('fromJson：缺字段时给安全默认值，不抛', () {
      final parsed = ReadingTask.fromJson(const {});
      expect(parsed.id, '');
      expect(parsed.totalLessons, 0);
      expect(parsed.nextLessonNo, isNull);
      expect(parsed.readLessonNos, isEmpty);
      expect(parsed.isActive, isTrue);
    });

    test('fromJson：nextLessonNo 为 null 时保持 null（不能用 0 顶替）', () {
      final parsed = ReadingTask.fromJson(const {
        'id': 'rt_1',
        'totalLessons': 96,
        'doneLessons': 96,
        'nextLessonNo': null,
        'finished': true,
      });
      expect(parsed.nextLessonNo, isNull);
      expect(parsed.finished, isTrue);
    });

    test('fromJson：readLessonNos 里的脏值被丢掉，不会把字符串当地址用', () {
      final parsed = ReadingTask.fromJson(const {
        'readLessonNos': [1, '2', 3.0, null, 4],
      });
      expect(parsed.readLessonNos, [1, 3, 4]);
    });

    test('「读完了」与「没有下一篇」是两件事', () {
      // 被家长取消的任务：没有下一篇，但**不是读完**。混成一个判断，
      // 家长会看到一张被自己撤掉的卡写着「已读完」。
      final cancelled = task(done: 3, total: 96, next: null, status: 'cancelled');
      expect(cancelled.isCancelled, isTrue);
      expect(cancelled.nextLessonNo, isNull);
      expect(cancelled.finished, isFalse);
      expect(cancelled.isActive, isFalse);
    });

    test('hasRead：按课号判断，不看数量', () {
      final t = task(done: 2, total: 96, read: [1, 2]);
      expect(t.hasRead(1), isTrue);
      expect(t.hasRead(3), isFalse);
    });
  });

  group('ReadingLesson', () {
    test('正文按空行分段，不按单换行', () {
      // 原书里一句话被折行（单个 \n）；那是同一段，不该拆成两段。
      const lesson = ReadingLesson(
        lessonNo: 1,
        title: 'Poor or Rich',
        body: '第一段第一句。\n第一段第二句。\n\n第二段。',
      );
      expect(lesson.paragraphs, ['第一段第一句。\n第一段第二句。', '第二段。']);
    });

    test('空正文不产生空段落', () {
      const lesson = ReadingLesson(lessonNo: 1, title: 'x', body: '\n\n  \n');
      expect(lesson.paragraphs, isEmpty);
    });

    test('fromJson：vocabulary 里的脏元素被跳过', () {
      final lesson = ReadingLesson.fromJson(const {
        'lessonNo': 2,
        'title': 'Three Fish Brothers',
        'vocabulary': [
          {'word': 'young', 'phonetic': '[jʌŋ]', 'meaning': 'adj 年轻的'},
          'not-a-map',
          null,
        ],
      });
      expect(lesson.vocabulary.length, 1);
      expect(lesson.vocabulary.first.word, 'young');
    });
  });

  group('ReadingAvailableBook', () {
    test('imported 由 importedBookId 决定，空串也算没导入', () {
      expect(
        ReadingAvailableBook.fromJson(const {'mediaId': 'm', 'importedBookId': null}).imported,
        isFalse,
      );
      expect(
        ReadingAvailableBook.fromJson(const {'mediaId': 'm', 'importedBookId': ''}).imported,
        isFalse,
      );
      expect(
        ReadingAvailableBook.fromJson(const {'mediaId': 'm', 'importedBookId': 'rb_1'}).imported,
        isTrue,
      );
    });
  });
}
