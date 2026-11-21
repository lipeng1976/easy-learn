import 'dart:io';

import 'package:easy_learn_app/models/review_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// 错题来源的「读得回来、写得回去」。
///
/// 为什么值得单独盯：`ima_exam` 曾经被静默当成「手工录入」——因为它不在
/// Dart 枚举里，`mistakeSourceOf` 一路兜底到 `manual`。界面照样画得出，
/// 只是那 4 条试卷错题的来源永远显示错，色块里也算不出「试卷导入 N」。
///
/// 更隐蔽的一半是**上行**：编辑一道试卷错题会走 `overwrite`，如果发的是
/// `imaExam`，服务端那行的 `source_type` 就变了下划线之外的写法，
/// 而导入/撤销的幂等都是按 `'ima_exam'` 匹配的 —— 重新导入会多出一套题。
void main() {
  group('解析（读）', () {
    test('服务端下划线写法 ima_exam 认得出', () {
      expect(mistakeSourceOf('ima_exam'), MistakeSource.imaExam);
    });

    test('本地 sqflite 存的枚举名 imaExam 也认得出', () {
      // 同一条错题在本机读本地库、在云版读服务端，不能得出两种来源。
      expect(mistakeSourceOf('imaExam'), MistakeSource.imaExam);
    });

    test('其余来源两种写法都还对', () {
      expect(mistakeSourceOf('checkin'), MistakeSource.checkin);
      expect(mistakeSourceOf('homework'), MistakeSource.homework);
      expect(mistakeSourceOf('scan'), MistakeSource.scan);
      expect(mistakeSourceOf('teacher'), MistakeSource.teacher);
      expect(mistakeSourceOf('manual'), MistakeSource.manual);
    });

    test('没见过的值仍按 homeworkId 兜底，不变成 imaExam', () {
      expect(mistakeSourceOf('nope'), MistakeSource.manual);
      expect(
        mistakeSourceOf('nope', homeworkId: 'hw_1'),
        MistakeSource.homework,
      );
      expect(mistakeSourceOf(null), MistakeSource.manual);
      expect(
        mistakeSourceOf(null, homeworkId: 'hw_1'),
        MistakeSource.homework,
      );
      expect(mistakeSourceOf('   '), MistakeSource.manual);
    });
  });

  group('写回（上行 / 落库）', () {
    test('imaExam 上行必须写成 ima_exam', () {
      expect(mistakeSourceWire(MistakeSource.imaExam), 'ima_exam');
    });

    test('其余来源的 wire 名与枚举名一致（不悄悄改历史值）', () {
      for (final source in MistakeSource.values) {
        if (source == MistakeSource.imaExam) continue;
        expect(mistakeSourceWire(source), source.name);
      }
    });

    test('每个来源都能 wire → 解析 往返回来', () {
      for (final source in MistakeSource.values) {
        expect(mistakeSourceOf(mistakeSourceWire(source)), source);
      }
    });
  });

  group('文案', () {
    test('试卷导入不叫「手工录入」', () {
      expect(MistakeSource.imaExam.label, '试卷导入');
      expect(MistakeSource.imaExam.label, isNot(MistakeSource.manual.label));
    });
  });

  group('上行单点（源码）', () {
    test('错题上行用 wire 名，没有残留 sourceType.name', () {
      // 这条测的是「有没有人把上行改回 name」。纯函数测不到它，
      // 而它一改坏就是上面说的那种静默重复入库。
      final source = File(
        'lib/services/http_review_repository.dart',
      ).readAsStringSync();

      expect(
        source,
        contains("'sourceType': mistakeSourceWire(m.sourceType)"),
      );
      expect(source, isNot(contains("'sourceType': m.sourceType.name")));
    });
  });
}
