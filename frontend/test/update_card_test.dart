import 'package:easy_learn_app/controllers/update_controller.dart';
import 'package:easy_learn_app/services/app_update_service.dart';
import 'package:easy_learn_app/widgets/update_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 判据：个人页的更新卡片**始终在菜单里**，但按钮只在新版存在时可点。
///
/// 这两条必须分开盯：只断「有更新时按钮亮」会漏掉「没更新时卡片整张消失」
/// 这个迁移前的老毛病；只断「卡片在」又抓不到灰按钮没生效。
class _TestUpdateController extends UpdateController {
  _TestUpdateController({required this.withUpdate});

  final bool withUpdate;

  @override
  Future<UpdateCheckResult> check({bool showSpinner = true}) async {
    final latest = withUpdate
        ? const UpdateInfo(
            versionCode: 9999,
            versionName: '9.9.9',
            changelog: '测试更新',
            fileName: 'update.apk',
            size: 1024,
            sha256: 'abc',
            publishedAt: '2026-11-26T00:00:00+08:00',
          )
        : null;
    info.value = latest;
    return UpdateCheckResult(available: withUpdate, latest: latest);
  }
}

UpdateController _install({required bool withUpdate}) =>
    Get.put<UpdateController>(_TestUpdateController(withUpdate: withUpdate));

Widget _harness() => const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: UpdateCard())),
    );

FilledButton _button(WidgetTester tester) => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '检查更新'),
    );

void main() {
  tearDown(() => Get.reset());

  testWidgets('没有新版本：卡片仍在，按钮灰着', (tester) async {
    _install(withUpdate: false);
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.text('版本更新'), findsOneWidget, reason: '入口必须始终能在菜单里看到');
    expect(find.byWidgetPredicate((w) => w is FilledButton), findsOneWidget);
    expect(_button(tester).onPressed, isNull, reason: '没新版时按钮必须灰');
    expect(find.textContaining('当前已是最新版本'), findsOneWidget);
  });

  testWidgets('有新版本：卡片在，按钮可点', (tester) async {
    _install(withUpdate: true);
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.text('版本更新'), findsOneWidget);
    expect(_button(tester).onPressed, isNotNull, reason: '有新版时按钮必须可点');
    expect(find.textContaining('发现新版本 9.9.9'), findsOneWidget);
  });

  testWidgets('检查从有更新回退到无更新：按钮跟着变灰（不留旧状态）', (tester) async {
    final controller = _install(withUpdate: true);
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();
    expect(_button(tester).onPressed, isNotNull);

    controller.info.value = null;
    await tester.pumpAndSettle();

    expect(find.text('版本更新'), findsOneWidget);
    expect(_button(tester).onPressed, isNull, reason: '服务端撤包后按钮不能继续亮着');
  });
}
