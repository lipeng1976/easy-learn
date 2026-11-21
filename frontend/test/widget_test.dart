// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:easy_learn_app/app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App loads login page', (WidgetTester tester) async {
    await tester.pumpWidget(const EasyLearnApp());
    expect(find.text('伴学APP'), findsOneWidget);
    expect(find.text('注册新账号'), findsOneWidget);
  });

  testWidgets('Login page opens registration page', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const EasyLearnApp());
    await tester.tap(find.text('注册新账号'));
    await tester.pumpAndSettle();

    expect(find.text('创建伴学账号'), findsOneWidget);
    expect(find.text('注册并登录'), findsOneWidget);
  });
}
