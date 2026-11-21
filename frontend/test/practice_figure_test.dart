import 'dart:convert';

import 'package:easy_learn_app/models/practice_figure.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/pages/student/widgets/practice_figure_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 图形 DSL 的解析与渲染。
//
// `lShape` **不是编的**：它是 2026-10-23 用真实照片跑网关时
// `qwen3.5-omni-plus` 自己输出的结果，原样抄下来当夹具。
// 手写的漂亮 JSON 能通过任何校验，用真数据才有意义。

const Map<String, dynamic> lShape = {
  'type': 'plane',
  'points': [
    {'name': 'A', 'x': 0, 'y': 3},
    {'name': 'B', 'x': 2, 'y': 3},
    {'name': 'C', 'x': 2, 'y': 1},
    {'name': 'D', 'x': 4, 'y': 1},
    {'name': 'E', 'x': 4, 'y': 0},
    {'name': 'F', 'x': 0, 'y': 0},
  ],
  'polygons': [
    ['A', 'B', 'C', 'D', 'E', 'F'],
  ],
  'segments': <List<String>>[],
  'dashed': <List<String>>[],
  'dims': [
    {
      'from': {'x': 0, 'y': 3},
      'to': {'x': 2, 'y': 3},
      'text': 'd',
    },
    {
      'from': {'x': 0, 'y': 0},
      'to': {'x': 0, 'y': 3},
      'text': 'a',
    },
    {
      'from': {'x': 0, 'y': 0},
      'to': {'x': 4, 'y': 0},
      'text': 'b',
    },
    {
      'from': {'x': 4, 'y': 0},
      'to': {'x': 4, 'y': 1},
      'text': 'c',
    },
  ],
  'labels': [
    {'text': '50°', 'x': 3, 'y': 2.5},
  ],
  'marks': <Map<String, dynamic>>[],
};

void main() {
  group('PracticeFigure.parse', () {
    test('真实模型输出能解析，点、边、标注一个不少', () {
      final figure = PracticeFigure.parse(lShape);
      expect(figure, isNotNull);
      expect(figure!.points.length, 6);
      expect(figure.polygons.single.length, 6);
      expect(figure.dims.length, 4);
      expect(figure.labels.single.text, '50°');
      expect(figure.isCoord, isFalse);
    });

    test('type 的别名认得出（polygon → plane）', () {
      final figure = PracticeFigure.parse({...lShape, 'type': 'polygon'});
      expect(figure?.type, 'plane');
    });

    test('引用了不存在的点 ⇒ 整张图返回 null，不是跳过那一条', () {
      final broken = {
        ...lShape,
        'polygons': [
          ['A', 'B', 'C', 'D', 'E', 'F'],
          ['A', 'B', 'Z'],
        ],
      };
      expect(PracticeFigure.parse(broken), isNull);
    });

    test('尺寸标注端点缺失 ⇒ null', () {
      final broken = {
        ...lShape,
        'dims': [
          {
            'from': {'x': 0, 'y': 0},
            'to': {'y': 3},
            'text': 'a',
          },
        ],
      };
      expect(PracticeFigure.parse(broken), isNull);
    });

    test('像素级坐标（越界）⇒ null，不夹紧', () {
      final broken = {
        ...lShape,
        'points': [
          {'name': 'A', 'x': 0, 'y': 3000},
          {'name': 'B', 'x': 2000, 'y': 3000},
          {'name': 'C', 'x': 2000, 'y': 0},
        ],
      };
      expect(PracticeFigure.parse(broken), isNull);
    });

    test('未知类型 / 空值 / 非 Map 一律 null，不抛异常', () {
      expect(PracticeFigure.parse({'type': 'svg', 'points': []}), isNull);
      expect(PracticeFigure.parse(null), isNull);
      expect(PracticeFigure.parse('{}'), isNull);
      expect(PracticeFigure.parse({}), isNull);
    });

    test('只有点没有边 ⇒ null（画出来是一堆孤立的点）', () {
      expect(
        PracticeFigure.parse({
          'type': 'plane',
          'points': lShape['points'],
          'polygons': <List<String>>[],
          'segments': <List<String>>[],
        }),
        isNull,
      );
    });
  });

  group('落地往返', () {
    test('figure 写进 figureJson 后读回来还是同一张图', () {
      final figure = PracticeFigure.parse(lShape);
      final question = AiPracticeQuestion(
        id: 'pq_1',
        sourceMistakeId: 'm_1',
        subject: '数学',
        title: '用不同方法表示下图的面积',
        content: '如图，一个 L 形图形……',
        answer: 'S = ad + (b-d)c',
        createdAt: DateTime(2026, 10, 23),
        figure: figure,
      );

      final row = question.toMap();
      expect(row['figureJson'], isA<String>());

      final restored = AiPracticeQuestion.fromMap(row);
      expect(restored.figure, isNotNull);
      expect(restored.figure!.points.length, 6);
      expect(restored.figure!.dims.length, 4);
    });

    test('没有图的题 figureJson 是 null，能直接数出「多少道题带图」', () {
      final question = AiPracticeQuestion(
        id: 'pq_2',
        sourceMistakeId: 'm_1',
        subject: '数学',
        title: '计算',
        content: '1 + 1 = ?',
        answer: '2',
        createdAt: DateTime(2026, 10, 23),
      );
      expect(question.toMap()['figureJson'], isNull);
      expect(AiPracticeQuestion.fromMap(question.toMap()).figure, isNull);
    });

    test('坏掉的 figureJson 读回来是 null，不抛异常（不能白屏）', () {
      final row = {
        'id': 'pq_3',
        'sourceMistakeId': 'm_1',
        'subject': '数学',
        'title': 't',
        'content': 'c',
        'answer': 'a',
        'figureJson': '{ 这不是 JSON',
      };
      final restored = AiPracticeQuestion.fromMap(row);
      expect(restored.figure, isNull);
      expect(restored.content, 'c', reason: '图坏了不该影响这道题的其它字段');
    });

    test('figureJson 往返走的是与接口相同的字段名', () {
      final figure = PracticeFigure.parse(lShape)!;
      final json = jsonDecode(jsonEncode(AiPracticeQuestion.figureToJson(figure)));
      // 再解一次：如果存的时候换了字段名，这一步会返回 null。
      expect(PracticeFigure.parse(json), isNotNull);
    });
  });

  group('PracticeFigureView', () {
    testWidgets('有图时能画出来，不抛异常', (tester) async {
      final figure = PracticeFigure.parse(lShape)!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: PracticeFigureView(figure: figure),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CustomPaint), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('坐标系类型也能画（多了两条轴）', (tester) async {
      final figure = PracticeFigure.parse({
        'type': 'coord',
        'points': [
          {'name': 'A', 'x': -2, 'y': -1},
          {'name': 'B', 'x': 2, 'y': 3},
        ],
        'segments': [
          ['A', 'B'],
        ],
      });
      expect(figure, isNotNull);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 320, child: PracticeFigureView(figure: figure!)),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
