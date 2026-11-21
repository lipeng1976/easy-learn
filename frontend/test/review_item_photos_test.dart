import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/pages/student/widgets/review_item_photos.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 卷内原题照片的渲染判据。
///
/// ## 这条判据对应的真实故障（2026-10-23）
///
/// 用户：*「生成出来的界面（快照）没有题干的图案了」*。
/// 导出 PDF 那条路一直印原题照片（`ReviewController._mistakeImageBytes`），
/// 屏幕上从来没有渲染过 —— 同一份卷子出现了「纸上有图、App 里没图」两个版本。
///
/// 所以判据盯三件事：
/// ① 没有来源错题（`mistakeId` 为空）时**不发请求、不占位**；
/// ② 取图失败时**说出话来**，不许缩成 0 高度（那会被读成「这题本来没图」）；
/// ③ 列表复用 State 时换了题必须**重新取**（否则第二道题显示第一题的图，
///    图不会报错，只会张冠李戴）。
void main() {
  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  testWidgets('没有来源错题时不取图，也不显示「原题照片」', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        ReviewItemPhotos(
          mistakeId: '',
          loader: (id) async {
            calls++;
            return const <ReviewMistakeImage>[];
          },
        ),
      ),
    );
    await tester.pump();

    expect(calls, 0, reason: '空 mistakeId 还发请求，等于每次滚动都白打一次网关');
    expect(find.textContaining('原题照片'), findsNothing);
  });

  testWidgets('取图失败时显示「读不到」，而不是缩成空白', (tester) async {
    await tester.pumpWidget(
      host(
        ReviewItemPhotos(
          mistakeId: 'rm_1',
          loader: (id) async => throw StateError('网关不通'),
        ),
      ),
    );
    await tester.pump(); // 第一帧：FutureBuilder waiting
    await tester.pump(); // 第二帧：Future 完成（错误）

    expect(
      find.textContaining('原题照片暂时读不到'),
      findsOneWidget,
      reason: '静默消失会让用户以为这道题本来就没有图',
    );
  });

  testWidgets('换了一道题必须重新取图，不沿用上一题的 future', (tester) async {
    final asked = <String>[];
    Future<List<ReviewMistakeImage>> loader(String id) async {
      asked.add(id);
      return const <ReviewMistakeImage>[];
    }

    await tester.pumpWidget(
      host(ReviewItemPhotos(mistakeId: 'rm_a', loader: loader)),
    );
    await tester.pump();
    expect(asked, ['rm_a']);

    // 同一个 State（key 不变）换成另一道题 —— 列表复用时的真实情形。
    await tester.pumpWidget(
      host(
        ReviewItemPhotos(
          key: const ValueKey<String>('card'),
          mistakeId: 'rm_b',
          loader: loader,
        ),
      ),
    );
    await tester.pump();
    // 上面这条是新建 State，下面这条才是复用：同 key 同类型，只换 mistakeId。
    await tester.pumpWidget(
      host(
        ReviewItemPhotos(
          key: const ValueKey<String>('card'),
          mistakeId: 'rm_c',
          loader: loader,
        ),
      ),
    );
    await tester.pump();

    expect(
      asked,
      ['rm_a', 'rm_b', 'rm_c'],
      reason: '复用的 State 不重新取，第二道题会显示第一道题的照片',
    );
  });
}
