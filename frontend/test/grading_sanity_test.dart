import 'package:easy_learn_app/services/ai_data_source.dart';
import 'package:easy_learn_app/utils/grading_sanity.dart';
import 'package:flutter_test/flutter_test.dart';

/// 批改结果体检的三条口径。
///
/// 这三条以前散在网络层与控制器的分支里，一条覆盖都没有；而它们的代价是
/// **错题库被清空 / 空白照片换到满分加分 / 假错题入库** —— 都不是界面问题。
///
/// ⚠️ 用例分得比较碎（一条判据一个 `test`），是刻意的：证伪时要求
/// 「改坏的恰好是那几条变红」，全塞进一个 test 就分不出是哪一条在响。
void main() {
  HomeworkCheckOutcome outcome({
    required String summary,
    List<HomeworkCheckItem> items = const [],
    int score = 100,
  }) => HomeworkCheckOutcome(score: score, summary: summary, items: items);

  const wrongItem = HomeworkCheckItem(
    question: r'计算 $\frac{3}{4}-\frac{1}{2}$ 的值。',
    knowledgePoint: '分数计算',
    originalAnswer: '-29/4',
    wrongReason: '通分时分母没有统一',
  );

  group('① 照片没批成 ≠ 全对', () {
    test('实测原话：现网视觉档对纯白页面那句「照片是空白的……无法批改」', () {
      expect(
        GradingSanity.isUnreadable(
          outcome(summary: '照片是空白的，没有可批改的内容，无法批改。'),
        ),
        isTrue,
      );
    });

    test('实测原话：vl-plus 那句「作业照片为空，按无错误处理」', () {
      // ⚠️ 这一档**一边说没内容、一边按满分处理** —— 正是最该抓的一档。
      expect(
        GradingSanity.isUnreadable(
          outcome(summary: '作业照片为空，按无错误处理。'),
        ),
        isTrue,
      );
    });

    test('score:0 的「无法批改」也算不可读 —— 判据不看分数', () {
      // `qwen3.8-max` / `flash` 对白页回的是「无法批改」+ score:0。
      // 那份结果同样一条错题都没有，落到下面照样会把作业置成「已完成」、
      // 发出「《X》全对」的加分通知。要求 score == 100 会把它全漏掉。
      expect(
        GradingSanity.isUnreadable(
          outcome(summary: '照片无法批改，请重新拍照。', score: 0),
        ),
        isTrue,
      );
    });

    test('**反面**：真的全对不能被当成不可读', () {
      // 这是本地兜底与云端都会给的那种总结。误判它 = 一个全对的孩子被判成需要重拍。
      expect(
        GradingSanity.isUnreadable(
          outcome(summary: '本次作业全部正确，书写与步骤完整，保持这个状态。'),
        ),
        isFalse,
      );
    });

    test('**反面**：报出了错题就说明它读得出来，哪怕总结里提到空白', () {
      // 安全阀：危险分支（清空错题库、发「全对」加分）本来就只挂在
      // 「一条错题都没有」上，所以只要 items 非空就不该拦。
      expect(
        GradingSanity.isUnreadable(
          outcome(summary: '照片右侧一块是空白的，其余部分批改如下。', items: [wrongItem], score: 70),
        ),
        isFalse,
      );
    });

    test('**反面**：「模糊」这类修饰词不能触发不可读', () {
      // 「有几处笔迹模糊，但整体全部正确」是真的全对。词表刻意不收
      // 「模糊 / 不清晰」这类**修饰**，只收对整张照片下的**结论**。
      expect(
        GradingSanity.isUnreadable(
          outcome(summary: '有几处笔迹模糊，但整体全部正确。'),
        ),
        isFalse,
      );
    });
  });

  group('② items 空却扣分 = 自相矛盾', () {
    test('items 空 + score 80 ⇒ 报出矛盾，且提示里点名两个数', () {
      final problem = GradingSanity.contradiction(
        outcome(summary: '共有 2 处计算错误。', score: 80),
      );
      expect(problem, isNotNull);
      // 提示会被当作 retryHint 发回服务端拼进提示词，所以两个数都要说清楚 ——
      // 「哪里错了」比「错了」有用得多。
      expect(problem, contains('100'));
      expect(problem, contains('80'));
    });

    test('items 空 + score 100 ⇒ 不矛盾', () {
      expect(
        GradingSanity.contradiction(outcome(summary: '全部正确。', score: 100)),
        isNull,
      );
    });

    test('报了错题 + score 80 ⇒ 不矛盾', () {
      expect(
        GradingSanity.contradiction(
          outcome(summary: '有 1 处错误。', items: [wrongItem], score: 80),
        ),
        isNull,
      );
    });
  });

  group('③ 模型当场反悔的条目', () {
    test('实测原话：「此条实际不构成错误，请勿计入错题库」', () {
      expect(
        GradingSanity.isRetracted(
          '符号处理错误。（复核：结果为 -1 与标准答案一致，此条实际不构成错误，请勿计入错题库）',
        ),
        isTrue,
      );
    });

    test('实测原话：「此条为误判，请以「无错题」处理」', () {
      expect(
        GradingSanity.isRetracted('经核对，学生填的 D 与标准答案一致，此条为误判。'),
        isTrue,
      );
    });

    test('实测原话：「学生算的是对的」', () {
      expect(
        GradingSanity.isRetracted('等等，让我重新算一下。哎呀，学生算的是对的！'),
        isTrue,
      );
    });

    test('实测原话（2026-10-21）：「不应判错……此条目为误报，请忽略」', () {
      // 这条来自真实照片：模型把一道**做对**的题报成错题，
      // 答案写的和学生一模一样（0.17a vs 0.17a），错因里自己承认了。
      expect(
        GradingSanity.isRetracted(
          r'此处经复核，学生答案正确（$a \times (1+30\%) \times 0.9 - a = 0.17a$），'
          '不应判错。此条目为误报，请忽略。',
        ),
        isTrue,
      );
    });

    test('换成「此条为误报，请忽略」这种说法也要拦住', () {
      // 上面那条**恰好**含「不应判错」才被拦住的 —— 换个说法就漏。
      // 这正是词表最容易失效的地方：靠碰巧命中的判据等于没有判据。
      expect(GradingSanity.isRetracted('学生写的与标准答案一致，此条为误报，请忽略。'), isTrue);
    });

    test('正常错因不能被误判成反悔', () {
      expect(GradingSanity.isRetracted('通分时分母没有统一，导致最后一步算错'), isFalse);
    });

    test('**反面**：「不是错误地通分」这种半截话不能命中', () {
      // 「不是错误」是「不构成错误」的子串方向上的近亲，但语义完全不同：
      // 这句话在**肯定**这条错题（真正的错因是看错了数）。
      // 词表只收明确的撤回语，就是为了不把真错题丢掉。
      expect(
        GradingSanity.isRetracted('这道题的错因不是错误地通分，而是把 5 看成了 3'),
        isFalse,
      );
    });

    test('withoutRetracted 滤掉反悔的、保住其余，并保持原顺序', () {
      const kept = HomeworkCheckItem(
        question: '甲乙两车同时从两地出发，相向而行，多久相遇？',
        knowledgePoint: '相遇问题',
        originalAnswer: 'x=5',
        wrongReason: '等量关系列错',
      );
      final result = GradingSanity.withoutRetracted(const [
        wrongItem,
        HomeworkCheckItem(
          question: r'计算 $-\frac{7}{4}+\frac{1}{2}$。',
          knowledgePoint: '符号',
          originalAnswer: '-29/4',
          wrongReason: '此条为误判，请以「无错题」处理',
        ),
        kept,
      ]);
      expect(result.length, 2);
      expect(result.first.knowledgePoint, '分数计算');
      expect(result.last.knowledgePoint, '相遇问题');
    });
  });

  test('不可读的文案必须与「真的全对」分得开', () {
    // 两者都会让作业落到终态，但一个要说「请重拍」、一个要说「全对」。
    // 混成一句，学生就不知道自己该不该重拍。
    expect(GradingSanity.unreadableMessage, contains('重拍'));
    expect(GradingSanity.unreadableMessage, isNot(contains('全对')));
  });

  test('反悔条数的说明要带条数 —— 否则「加了 3 道却只多 2 道」说不清', () {
    expect(GradingSanity.retractedNote(2), contains('2'));
  });
}
