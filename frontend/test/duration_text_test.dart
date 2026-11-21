import 'package:easy_learn_app/utils/duration_text.dart';
import 'package:flutter_test/flutter_test.dart';

/// 时间文本是**同一份数据在三个地方的说法**（计时页 / 作业卡片 / 家长端）。
/// 各页面自己拼字符串的话，同一段用时会在两处显示成不同的量，
/// 而孩子和家长一对就会以为计时出错了。
void main() {
  group('formatClock', () {
    test('始终带小时位，位数不随数值跳变', () {
      expect(formatClock(0), '00:00:00');
      expect(formatClock(9), '00:00:09');
      expect(formatClock(65), '00:01:05');
      expect(formatClock(3599), '00:59:59');
      expect(formatClock(3600), '01:00:00');
      expect(formatClock(3661), '01:01:01');
      expect(formatClock(36000), '10:00:00');
    });

    test('负数按 0 处理 —— 显示 -00:00:03 只会像计时器坏了', () {
      expect(formatClock(-1), '00:00:00');
      expect(formatClock(-3600), '00:00:00');
    });
  });

  group('formatStudyTime', () {
    test('不足一分钟按秒说', () {
      expect(formatStudyTime(0), '0 秒');
      expect(formatStudyTime(1), '1 秒');
      expect(formatStudyTime(59), '59 秒');
    });

    test('分与秒：整分不带「0 秒」', () {
      expect(formatStudyTime(60), '1 分');
      expect(formatStudyTime(61), '1 分 1 秒');
      expect(formatStudyTime(754), '12 分 34 秒');
      expect(formatStudyTime(3540), '59 分');
    });

    test('一小时以上丢掉秒 —— 到这个量级，秒不影响「大概花了多久」', () {
      expect(formatStudyTime(3600), '1 小时');
      expect(formatStudyTime(3601), '1 小时');
      expect(formatStudyTime(3900), '1 小时 5 分');
      expect(formatStudyTime(86399), '23 小时 59 分');
    });

    test('负数同样按 0 处理', () {
      expect(formatStudyTime(-30), '0 秒');
    });
  });
}
