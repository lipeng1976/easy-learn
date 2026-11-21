import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easy_learn_app/constants/grades.dart';
import 'package:easy_learn_app/models/textbook.dart';
import 'package:easy_learn_app/models/word_checkin.dart';
import 'package:easy_learn_app/widgets/grade_term_mismatch.dart';

void main() {
  group('教材/词表年级学期模型（fromJson 只透传，归一是展示/比对层的事）', () {
    test('TextbookBook.fromJson 读 grade/term', () {
      final book = TextbookBook.fromJson(<String, dynamic>{
        'id': 'tb_1',
        'title': '七上数学',
        'subject': '数学',
        'unitCount': 20,
        'sourceMediaId': 'm1',
        'grade': '七',
        'term': '上',
      });
      expect(book.grade, '七');
      expect(book.term, '上');
    });

    test('TextbookBook.fromJson 缺字段时 grade/term 为空串', () {
      final book =
          TextbookBook.fromJson(<String, dynamic>{'id': 'tb_2', 'title': 'x'});
      expect(book.grade, '');
      expect(book.term, '');
    });

    test('WordImportedBook.fromJson 读 grade/term', () {
      final book = WordImportedBook.fromJson(<String, dynamic>{
        'id': 'wb_1',
        'title': '七上词表',
        'wordCount': 200,
        'grade': '七',
        'term': '上',
      });
      expect(book.grade, '七');
      expect(book.term, '上');
    });
  });

  group('年级口径：初一 与 七年级 是同一个年级（11-13）', () {
    test('kGradeOptions 只有一套初中叫法（盯住再次漂移）', () {
      expect(kGradeOptions.length, 12);
      expect(kGradeOptions.contains('初一'), isTrue);
      expect(kGradeOptions.contains('初二'), isTrue);
      expect(kGradeOptions.contains('初三'), isTrue);
      expect(kGradeOptions.contains('七年级'), isFalse,
          reason: '别名只能进 kGradeAliases，不能进选项');
      expect(kGradeOptions.contains('八年级'), isFalse);
      expect(kGradeOptions.contains('九年级'), isFalse);
      expect(kGradeOptions.first, '一年级');
      expect(kGradeOptions.last, '高三');
    });

    test('canonicalGrade 把别名归一到规范值', () {
      expect(canonicalGrade('七年级'), '初一');
      expect(canonicalGrade('7年级'), '初一');
      expect(canonicalGrade('八年级'), '初二');
      expect(canonicalGrade('8年级'), '初二');
      expect(canonicalGrade('九年级'), '初三');
      expect(canonicalGrade('9年级'), '初三');
    });

    test('canonicalGrade 幂等 / 去空格 / 不认得的宽松放过', () {
      expect(canonicalGrade('初一'), '初一');
      expect(canonicalGrade(' 七年级 '), '初一');
      expect(canonicalGrade('高一'), '高一');
      expect(canonicalGrade('七年级上'), '七年级上',
          reason: '年级+学期粘一起的不猜，那是两个字段');
      expect(canonicalGrade(''), '');
    });

    test('🔴 用户报的 bug：书选「七年级 上」、档案是「初一 上」→ 不误报', () {
      expect(
        gradeTermMismatch(
          bookGrade: '七年级',
          bookTerm: '上',
          profileGrade: '初一',
          profileTerm: '上',
        ),
        isFalse,
      );
    });

    test('反面对照：别名归一后真差一个年级，仍要报', () {
      expect(
        gradeTermMismatch(
          bookGrade: '八年级',
          bookTerm: '上',
          profileGrade: '初一',
          profileTerm: '上',
        ),
        isTrue,
      );
    });

    test('反面对照：别名归一后学期不同，仍要报', () {
      expect(
        gradeTermMismatch(
          bookGrade: '七年级',
          bookTerm: '上',
          profileGrade: '初一',
          profileTerm: '下',
        ),
        isTrue,
      );
    });

    test('gradeTermLabel 归一后拼，横幅两边不会写出两种叫法', () {
      expect(gradeTermLabel('七年级', '上'), '初一上学期');
      expect(gradeTermLabel('初一', '下'), '初一下学期');
      expect(gradeTermLabel('七年级', ''), '初一');
      expect(gradeTermLabel('', ''), '');
    });

    test('pickerInitialGrade 预填命中「初一」，不退到「一年级」', () {
      expect(pickerInitialGrade('初一'), '初一');
      expect(pickerInitialGrade('七年级'), '初一');
      expect(pickerInitialGrade('高二'), '高二');
      expect(pickerInitialGrade('未填写'), '一年级');
      expect(pickerInitialGrade(''), '一年级');
    });

    test('profileInitialGrade：老档案别名归一，认不出的显示「未填写」', () {
      expect(profileInitialGrade('七年级'), '初一');
      expect(profileInitialGrade('初一'), '初一');
      expect(profileInitialGrade(''), kGradeUnset);
      expect(profileInitialGrade(kGradeUnset), kGradeUnset);
      expect(profileInitialGrade('七年级上'), kGradeUnset,
          reason: '不在选项里的值交给下拉 initialValue 会抛断言');
    });
  });

  group('gradeTermMismatch 比对', () {
    test('书与档案同年级学期 → 不报警', () {
      expect(
        gradeTermMismatch(
          bookGrade: '初一',
          bookTerm: '上',
          profileGrade: '初一',
          profileTerm: '上',
        ),
        isFalse,
      );
    });

    test('书年级与档案不同 → 报警', () {
      expect(
        gradeTermMismatch(
          bookGrade: '初二',
          bookTerm: '上',
          profileGrade: '初一',
          profileTerm: '上',
        ),
        isTrue,
      );
    });

    test('学期不同（同年级）→ 报警', () {
      expect(
        gradeTermMismatch(
          bookGrade: '初一',
          bookTerm: '上',
          profileGrade: '初一',
          profileTerm: '下',
        ),
        isTrue,
      );
    });

    test('书没标年级（老数据）→ 不当不匹配', () {
      expect(
        gradeTermMismatch(
          bookGrade: '',
          bookTerm: '',
          profileGrade: '初一',
          profileTerm: '上',
        ),
        isFalse,
      );
    });

    test('档案没设年级 → 不当不匹配', () {
      expect(
        gradeTermMismatch(
          bookGrade: '初一',
          bookTerm: '上',
          profileGrade: '',
          profileTerm: '',
        ),
        isFalse,
      );
    });

    test('档案写「未填写」占位 → 不当不匹配', () {
      expect(
        gradeTermMismatch(
          bookGrade: '初一',
          bookTerm: '上',
          profileGrade: kGradeUnset,
          profileTerm: '上',
        ),
        isFalse,
      );
    });
  });

  group('GradeTermMismatchNotice 横幅', () {
    Future<void> pump(WidgetTester tester, GradeTermMismatchNotice notice) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(children: [notice]),
          ),
        ),
      );
    }

    testWidgets('真不匹配时显示，且两边都用规范词', (tester) async {
      await pump(
        tester,
        const GradeTermMismatchNotice(
          bookGrade: '八年级',
          bookTerm: '上',
          profileGrade: '初一',
          profileTerm: '上',
        ),
      );
      expect(find.textContaining('这本是「初二上学期」'), findsOneWidget);
      expect(find.textContaining('当前年级是「初一上学期」'), findsOneWidget);
    });

    testWidgets('🔴 书=七年级 / 档案=初一：同一个年级，不弹横幅', (tester) async {
      await pump(
        tester,
        const GradeTermMismatchNotice(
          bookGrade: '七年级',
          bookTerm: '上',
          profileGrade: '初一',
          profileTerm: '上',
        ),
      );
      expect(find.textContaining('这本是'), findsNothing);
    });

    testWidgets('同年级时不显示（SizedBox.shrink）', (tester) async {
      await pump(
        tester,
        const GradeTermMismatchNotice(
          bookGrade: '初一',
          bookTerm: '上',
          profileGrade: '初一',
          profileTerm: '上',
        ),
      );
      expect(find.textContaining('这本是'), findsNothing);
    });

    testWidgets('书没标年级时不显示', (tester) async {
      await pump(
        tester,
        const GradeTermMismatchNotice(
          bookGrade: '',
          bookTerm: '',
          profileGrade: '初一',
          profileTerm: '上',
        ),
      );
      expect(find.textContaining('这本是'), findsNothing);
    });
  });

  group('导入弹窗 pickGradeTerm', () {
    /// 真把弹窗打开、读预填值、点「确定」，返回落库要用的值。
    Future<(String grade, String term)?> openAndConfirm(
      WidgetTester tester, {
      required String initialGrade,
      required String initialTerm,
      required String expectedInitialGrade,
    }) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                ctx = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      final future = pickGradeTerm(
        ctx,
        initialGrade: initialGrade,
        initialTerm: initialTerm,
      );
      await tester.pumpAndSettle();
      final gradeDropdown = tester.widget<DropdownButtonFormField<String>>(
        find
            .byWidgetPredicate((w) => w is DropdownButtonFormField<String>)
            .first,
      );
      expect(gradeDropdown.initialValue, expectedInitialGrade,
          reason: '预填错了家长就会存下错误年级');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      return future;
    }

    testWidgets('档案「初一」→ 预填初一、确定后落库「初一」', (tester) async {
      final picked = await openAndConfirm(
        tester,
        initialGrade: '初一',
        initialTerm: '上',
        expectedInitialGrade: '初一',
      );
      expect(picked?.$1, '初一');
      expect(picked?.$2, '上');
    });

    testWidgets('老数据「七年级」→ 预填归一成初一、落库也归一', (tester) async {
      final picked = await openAndConfirm(
        tester,
        initialGrade: '七年级',
        initialTerm: '下',
        expectedInitialGrade: '初一',
      );
      expect(picked?.$1, '初一');
      expect(picked?.$2, '下');
    });

    testWidgets('档案「未填写」→ 退到第一个选项，不崩', (tester) async {
      final picked = await openAndConfirm(
        tester,
        initialGrade: '未填写',
        initialTerm: '未填写',
        expectedInitialGrade: '一年级',
      );
      expect(picked?.$1, '一年级');
      expect(picked?.$2, '上');
    });
  });
}
