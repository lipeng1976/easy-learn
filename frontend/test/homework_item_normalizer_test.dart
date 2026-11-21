import 'package:easy_learn_app/models/homework_kind.dart';
import 'package:easy_learn_app/services/homework_item_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

/// 作业项归一化的测试。
///
/// 这一层管的是「一条 = 一件事」这个前提。它错了，症状会出现在很远的地方：
/// 清单里少一条看起来像学生自己漏抄了，多一条看起来像老师多留了作业 ——
/// 两种都不会有人怀疑到解析头上。所以边界要在这里钉死。
void main() {
  group('科目名收敛', () {
    test('去掉「作业」「练习」这类修饰，同一门课归成一个', () {
      expect(HomeworkItemNormalizer.canonicalSubject('数学作业'), '数学');
      expect(HomeworkItemNormalizer.canonicalSubject('语文 练习'), '语文');
      expect(HomeworkItemNormalizer.canonicalSubject('英语课'), '英语');
    });

    test('英文名映射到中文科目', () {
      expect(HomeworkItemNormalizer.canonicalSubject('Math'), '数学');
      expect(HomeworkItemNormalizer.canonicalSubject('ENGLISH'), '英语');
    });

    test('科目名后面的括号是范围，不是科目的一部分', () {
      expect(HomeworkItemNormalizer.canonicalSubject('英语（Unit 2）'), '英语');
    });

    test('认不出的科目名原样保留，不倒进「其他」', () {
      // 收敛是为了合并同义写法，不是为了消灭没见过的科目 ——
      // 名丢掉了就找不回来，而多一个选项最多是没人选。
      expect(HomeworkItemNormalizer.canonicalSubject('科学'), '科学');
    });

    test('整体性标签落到单条上等于没定下来', () {
      expect(HomeworkItemNormalizer.canonicalSubject('多科目'), '待确认');
      expect(HomeworkItemNormalizer.canonicalSubject('未知'), '待确认');
      expect(HomeworkItemNormalizer.canonicalSubject('   '), '待确认');
    });
  });

  group('正文里的科目前缀', () {
    test('subject 填了「待确认」但正文写着「数学：」时，用正文救回来', () {
      final items = HomeworkItemNormalizer.normalizeTask({
        'subject': '待确认',
        'text': '数学：练习册P12',
      });
      expect(items, hasLength(1));
      expect(items.first['subject'], '数学');
      expect(items.first['text'], '练习册P12');
    });

    test('前缀不是一个已知科目时不动它', () {
      // 「要求：朗读课文」里的「要求」不是科目，认成科目只会多出一门假课。
      final items = HomeworkItemNormalizer.normalizeTask({
        'subject': '语文',
        'text': '要求：朗读课文三遍',
      });
      expect(items, hasLength(1));
      expect(items.first['subject'], '语文');
      expect(items.first['text'], '要求：朗读课文三遍');
    });
  });

  group('一条拆成多条', () {
    test('一行里塞了两件事时按序号拆开', () {
      final items = HomeworkItemNormalizer.normalizeTask({
        'subject': '数学',
        'text': '1. 练习册P12 2. 口算20题',
      });
      expect(items, hasLength(2));
      expect(items[0]['text'], '练习册P12');
      expect(items[1]['text'], '口算20题');
    });

    test('全角序号与圆圈序号都认', () {
      final items = HomeworkItemNormalizer.normalizeTask({
        'subject': '语文',
        'text': '①背诵《静夜思》 ②默写生字',
      });
      expect(items.map((e) => e['text']), ['背诵《静夜思》', '默写生字']);
    });

    test('「做1、2、3题」是一件事，不许拆', () {
      // 那串序号是内容的一部分。拆开就会凭空多出两条待办，
      // 而学生看到「2」和「3」只会以为是系统坏了。
      final items = HomeworkItemNormalizer.normalizeTask({
        'subject': '数学',
        'text': '做1、2、3题',
      });
      expect(items, hasLength(1));
      expect(items.first['text'], '做1、2、3题');
    });

    test('只出现一个序号时不拆 —— 那更可能是正文里的点', () {
      final items = HomeworkItemNormalizer.normalizeTask({
        'subject': '语文',
        'text': '朗读课文第2段，注意停顿。',
      });
      expect(items, hasLength(1));
    });

    test('序号前的标题不会被丢掉，但「今天的作业：」这种不算一条', () {
      final items = HomeworkItemNormalizer.normalizeTask({
        'subject': '语文',
        'text': '今天的作业：1. 抄写生字 2. 背诵课文',
      });
      expect(items.map((e) => e['text']), ['抄写生字', '背诵课文']);
    });

    test('空的、只剩序号的都不会变成一条作业', () {
      final items = HomeworkItemNormalizer.normalizeTask({
        'subject': '数学',
        'text': '1.  2. ',
      });
      expect(items, isEmpty);
    });

    test('拆完为空时退回原文，宁可让看见也不能让丢', () {
      final items = HomeworkItemNormalizer.normalizeTask({
        'subject': '数学',
        'text': '数学',
      });
      expect(items, hasLength(1));
      expect(items.first['text'], '数学');
    });

    test('uncertain 会跟着拆出来的每一条走', () {
      final items = HomeworkItemNormalizer.normalizeTask({
        'subject': '语文',
        'text': '1. 背诵《静在恩（？）》 2. 默写生字',
        'uncertain': true,
      });
      expect(items.every((e) => e['uncertain'] == true), isTrue);
    });
  });

  group('题号连写', () {
    test('点分题号串读成列举：`1.2.37` 是第 1、2、3、7 题', () {
      // 口径来自用户 2026-09-29 的确认：原图写的就是 `1.2.37`
      // （列投影复核过 —— 只有两个点，`3` 和 `7` 之间没有），
      // 而它的意思就是第 1、2、3、7 题。
      //
      // 这件事**不能交给模型**：同一张照片实测 25 次，模型自己改写这串时
      // 有 6 次把 `7` 丢了（写成 `1、2、3题`），而丢掉的那一题
      // 没有任何机制能发现。
      expect(HomeworkItemNormalizer.expandSerialRuns('1.2.37'), '1、2、3、7');
      expect(
        HomeworkItemNormalizer.expandSerialRuns('学法P27 1.2.37'),
        '学法P27 1、2、3、7',
      );
      expect(HomeworkItemNormalizer.expandSerialRuns('1.2.3'), '1、2、3');
    });

    test('含 0 的两位段不拆 —— 题号里没有第 0 题', () {
      // 拆开就会凭空造出一个「第 0 题」。
      expect(HomeworkItemNormalizer.expandSerialRuns('1.2.10'), '1、2、10');
      expect(HomeworkItemNormalizer.expandSerialRuns('1.2.20'), '1、2、20');
    });

    test('两段以下的点分数字不碰 —— 那更像小数', () {
      expect(HomeworkItemNormalizer.expandSerialRuns('3.14'), '3.14');
      expect(HomeworkItemNormalizer.expandSerialRuns('3.14159'), '3.14159');
      expect(HomeworkItemNormalizer.expandSerialRuns('1.5小时'), '1.5小时');
    });

    test('本来就是列举形态的顿号串不动', () {
      expect(
        HomeworkItemNormalizer.expandSerialRuns('学法P28、P29'),
        '学法P28、P29',
      );
    });

    test('解读出来的列举不会被当列表切碎 —— 原来会切成 `、7`', () {
      // `_listMarkers` 只看得见「数字 + 顿号」，会把这条**内容本身**
      // 当成三个列表序号。
      final items = HomeworkItemNormalizer.normalizeTask({
        'subject': '地理',
        'text': '学法P27 1、2、3、7',
      });
      expect(items, hasLength(1));
      expect(items.first['text'], '学法P27 1、2、3、7');
    });

    test('展开结果再归一化一次不变 —— 幂等', () {
      // 少这条，将来任何人把同一批条目归一化两次（读库再存、
      // 编辑后重存）都会把一条作业变成乱码，而且不会报错。
      final once = HomeworkItemNormalizer.normalizeAll([
        {'subject': '地理', 'text': '学法P27 1.2.37'},
      ]);
      expect(once, hasLength(1));
      expect(once.first['text'], '学法P27 1、2、3、7');

      final twice = HomeworkItemNormalizer.normalizeAll(once);
      expect(twice, hasLength(once.length));
      expect(twice.first['text'], once.first['text']);
    });

    test('普通列表照拆 —— 短路条件不能被放宽', () {
      final items = HomeworkItemNormalizer.normalizeTask({
        'subject': '数学',
        'text': '1. 练习册P12 2. 口算20题',
      });
      expect(items, hasLength(2));
    });

    test('尾巴前面真站着序号时，那串不是题号连写', () {
      // 短路的前提是「尾巴前面没有别的序号」。这条守住那个前提：
      // 放宽了就会把真列表整行吞下、不再拆分。
      final items = HomeworkItemNormalizer.normalizeTask({
        'subject': '数学',
        'text': '1. 做P12 1、2、3',
      });
      expect(items.length, greaterThan(1));
    });
  });

  group('去重', () {
    Map<String, dynamic> task(String subject, String text) => {
      'subject': subject,
      'text': text,
    };

    test('只有空白和标点不同时算同一条', () {
      // 同一页拍了两遍时，学生会看到同一项作业出现两次，
      // 于是以为老师布置了两遍。
      final merged = <Map<String, dynamic>>[];
      HomeworkItemNormalizer.mergeInto(merged, task('数学', '练习册 P12'));
      HomeworkItemNormalizer.mergeInto(merged, task('数学', '练习册P12'));
      expect(merged, hasLength(1));
    });

    test('科目不同就不算重复', () {
      final merged = <Map<String, dynamic>>[];
      HomeworkItemNormalizer.mergeInto(merged, task('语文', '朗读课文'));
      HomeworkItemNormalizer.mergeInto(merged, task('英语', '朗读课文'));
      expect(merged, hasLength(2));
    });

    test('重复时「没把握」标记要保住 —— 宁可多提醒一次', () {
      final merged = <Map<String, dynamic>>[];
      HomeworkItemNormalizer.mergeInto(merged, task('语文', '背诵《静在恩》'));
      HomeworkItemNormalizer.mergeInto(merged, {
        'subject': '语文',
        'text': '背诵《静在恩》',
        'uncertain': true,
      });
      expect(merged, hasLength(1));
      expect(merged.first['uncertain'], isTrue);
    });

    test('normalizeAll 会顺带拆开一层套多条', () {
      final items = HomeworkItemNormalizer.normalizeAll([
        task('数学', '练习册P12'),
        task('数学', '1. 口算20题 2. 预习第3课'),
      ]);
      expect(items.map((e) => e['text']), [
        '练习册P12',
        '口算20题',
        '预习第3课',
      ]);
    });
  });

  group('下拉框选项', () {
    test('清单外的科目被并进来，避免 initialValue 断言失败', () {
      final options = HomeworkItemNormalizer.subjectOptionsFor(['科学']);
      expect(options, contains('科学'));
      expect(options, contains('待确认'));
    });

    test('同一门课的多种写法只占一个选项', () {
      final options = HomeworkItemNormalizer.subjectOptionsFor([
        '数学',
        '数学作业',
      ]);
      expect(options.where((s) => s == '数学'), hasLength(1));
    });
  });

  group('作业类型', () {
    test('按优先级判定：「背诵并默写」算默写', () {
      // 背下来还得落到纸上，那才是老师第二天要查的东西。
      expect(HomeworkKind.of('背诵并默写《静夜思》'), HomeworkKind.dictation);
    });

    test('常见关键词各自命中', () {
      expect(HomeworkKind.of('背诵课文第3段'), HomeworkKind.recitation);
      expect(HomeworkKind.of('朗读课文三遍'), HomeworkKind.reading);
      expect(HomeworkKind.of('口算20题'), HomeworkKind.oral);
      expect(HomeworkKind.of('订正试卷错题'), HomeworkKind.correction);
      expect(HomeworkKind.of('预习第5课'), HomeworkKind.preview);
    });

    test('判不出来时是「书面」—— 大多数作业本来就是书面的', () {
      expect(HomeworkKind.of('完成练习册P12'), HomeworkKind.written);
      expect(HomeworkKind.of(''), HomeworkKind.written);
    });
  });

  group('耗时估读', () {
    test('页数跨度按页算', () {
      // 3 页 × 8 分钟。
      expect(estimateHomeworkMinutes('完成练习册P12-P14'), 25);
    });

    test('口算每题半分钟，其他题每题两分钟', () {
      expect(estimateHomeworkMinutes('口算20题'), 10);
      expect(estimateHomeworkMinutes('完成20道题'), 40);
    });

    test('「做第12题」是一道题，不许按 12 题估', () {
      // 前面带「第」的不算题量。按 12 题算会得出凭空翻十倍的时间。
      final minutes = estimateHomeworkMinutes('做第12题');
      expect(minutes, lessThanOrEqualTo(30));
    });

    test('模型给了就以模型为准', () {
      expect(estimateHomeworkMinutes('口算20题', suggested: 45), 45);
    });

    test('一律夹在 5-120 且取 5 的倍数', () {
      // 47 这样的数看着像精确测算结果，学生会不敢改它。
      expect(estimateHomeworkMinutes('口算1题'), 5);
      expect(estimateHomeworkMinutes('完成练习册P1-P100'), 120);
      expect(estimateHomeworkMinutes('完成练习册P1-P3') % 5, 0);
    });
  });

  group('模型给的耗时建议', () {
    // 这个字段一路从网关传到这里，中途丢过一次：归一化重建条目时
    // 只带了 subject/text/uncertain。丢了的后果不是报错，而是界面安静地
    // 显示规则兜底的整数 —— 模型看出来的「一张卷子两面」就这么没了，
    // 且没有任何地方看得出来。
    test('一条还是一条时原样透传', () {
      final out = HomeworkItemNormalizer.normalizeTask({
        'subject': '数学',
        'text': '完成练习册P12-P14',
        'estimatedMinutes': 25,
      });
      expect(out, hasLength(1));
      expect(out.first['estimatedMinutes'], 25);
    });

    test('拆成多条时不透传 —— 那是整块文字的量，照抄会给每条各算一遍', () {
      final out = HomeworkItemNormalizer.normalizeTask({
        'subject': '数学',
        'text': '1.练习册P12 2.口算20题',
        'estimatedMinutes': 30,
      });
      expect(out, hasLength(2));
      // 30 分钟是这两件事合起来的时间。给每条都塞 30，总时长就变成 60。
      for (final item in out) {
        expect(item.containsKey('estimatedMinutes'), isFalse);
      }
    });

    test('范围外整条丢掉，不夹到边界', () {
      // 夹到 120 会显得像模型真的估过 120 分钟。
      for (final bad in [0, 4, 999, -30]) {
        final out = HomeworkItemNormalizer.normalizeTask({
          'subject': '语文',
          'text': '抄写生字',
          'estimatedMinutes': bad,
        });
        expect(out.first.containsKey('estimatedMinutes'), isFalse, reason: '坏值 $bad');
      }
    });

    test('类型不对当没给', () {
      for (final bad in ['20', true, null, <int>[20]]) {
        final out = HomeworkItemNormalizer.normalizeTask({
          'subject': '语文',
          'text': '抄写生字',
          'estimatedMinutes': bad,
        });
        expect(out.first.containsKey('estimatedMinutes'), isFalse, reason: '坏值 $bad');
      }
    });

    test('小数四舍五入后仍在范围内就收下', () {
      final out = HomeworkItemNormalizer.normalizeTask({
        'subject': '英语',
        'text': '默写单词',
        'estimatedMinutes': 12.4,
      });
      expect(out.first['estimatedMinutes'], 12);
    });
  });
}
