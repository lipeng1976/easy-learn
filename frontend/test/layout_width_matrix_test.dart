import 'package:easy_learn_app/controllers/parent_controller.dart';
import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/models/point_model.dart';
import 'package:easy_learn_app/pages/parent/widgets/child_selector.dart';
import 'package:easy_learn_app/pages/parent/widgets/parent_app_bar.dart';
import 'package:easy_learn_app/widgets/day_calendar.dart';
import 'package:easy_learn_app/widgets/grading_source_chip.dart';
import 'package:easy_learn_app/widgets/homework_status.dart';
import 'package:easy_learn_app/widgets/needs_grading_switch.dart';
import 'package:easy_learn_app/widgets/point_widgets.dart';
import 'package:easy_learn_app/widgets/status_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 屏幕宽度矩阵：同一批组件在**手机 / 平板 / 宽屏**上都不许溢出，
/// 而且内容必须**真的画出来**。
///
/// ── 为什么需要这个文件 ──────────────────────────────────────────────────
///
/// 起因是一个此前没被回答过的问题：「平板和手机上都能适配吗？不同宽度的
/// 屏幕，排版会不会有影响」—— 虫子随后明确了他问的是**伴学苹果版**
/// （iPad + iPhone），所以下面每一档都按**真机**排，而不是按「宽 / 窄」。
///
/// ⚠️ 这个文件测的是 **Flutter 布局层**，而布局层是 iOS 与 Android
/// **共用同一份代码**的（`lib/` 里 `Platform.is…` 出现 **0 次**），
/// 所以这些断言对两个平台**同时**成立 —— 苹果版不会因为是苹果就换一套布局。
/// 真正分平台的配置在 `Info.plist` / `AndroidManifest.xml` 里
/// （方向、iPad 分屏、安全区、明文 HTTP 策略），那些测不到，边界见文末。
///
/// 这个仓库里**没有任何一条测试在盯宽度**，而这不等于「宽度没问题」——
/// `flutter_test` 的默认视口是 **800×600**，宽 800 比任何手机都宽。
/// 全仓 62 个测试文件里只有 2 个改过视口（`parent_app_bar_test` /
/// `parent_answer_photos_test`），也就是说：**其余 60 个文件无论在什么
/// 设备上跑，量的都是同一个 800dp 宽的窗口**。
///
/// 代价已经付过一次：`parent_app_bar_test.dart` 的注释写着，家长端顶栏
/// 在**真机上**溢出 51px（`RenderFlex overflowed by 51 pixels`），
/// 用户看到的是黄黑斜纹加一行看不懂的英文。那个 bug 能在 800dp 下
/// 安稳地活过全部测试。
///
/// ⚠️ 所以这个文件盯的是**宽度**这一个变量，不是「渲染不报错」。
/// 每个宽度的断言都必须能区分「排得好」和「东西没画出来」——
/// 把内容压成 0 宽度同样不会溢出，那是另一种坏法（同
/// `parent_app_bar_test.dart` 里「不溢出」与「名字没被省略」两条必须并存）。
///
/// ── 怎么跑 ─────────────────────────────────────────────────────────────
///
///     flutter test test/layout_width_matrix_test.dart
///
/// ⚠️ 这个文件是**静态核对**写出来的（本协作窗口跑不了 Dart，子进程被拦），
/// 每个构造签名都逐个对过源码。首次真跑若有 `Undefined name`、
/// 参数不匹配这类编译错，是本文件的锅，不是被测代码的。
///
/// ── 还没覆盖的（三条，都不是「忘了」，是「在这里做不出判据」）─────────────
///
/// **一、整页。** 这里只测组件。整页要多一份数据库 + 控制器装配，现成的
/// 样板是 `parent_answer_photos_test.dart` 里的 `openReviewTab` —— 它已经
/// 能渲染真实页面，只是视口写死成 1000×3200。把它的视口参数化后接进来
/// 是下一步。
///
/// **二、安全区（刘海 / 灵动岛 / Home Indicator / 手势条）。**
/// `tester.view.padding` 默认是 **0** —— 也就是说**全仓测试都跑在「没有一滴
/// 安全区」的假设下**，而 iPhone X 之后的机器全都没有 Home 键。
/// 但这一条**在组件级做不出来**：消费安全区的是页面骨架（`Scaffold` +
/// 底栏 + 弹层外壳），而它们要么是私有 widget（`_HomeworkSubmitSheet`、
/// `_ReviewExportSheet`），要么需要控制器实例才能构造 —— 硬写只会得到一个
/// 「怎么改都绿」的测试，那比不写更糟（同 `parent_app_bar_test.dart` 的教训：
/// 没有反面的绿等于没测）。
/// 目前的依据只有**静态核对**：11 处 `SafeArea` / 10 个文件，底部栏与弹层
/// 一律 `SafeArea(top: false)`，底部导航用的是 Flutter 内置的
/// `BottomNavigationBar`（它自己会消费底部 inset）。**剩下的交给真机走查。**
///
/// **三、iOS 平台层。** 方向矩阵、iPad 分屏能不能用、App 图标、签名与
/// 「到底构建过没有」—— 这些在 `ios/Runner/Info.plist` 与
/// `ios/Runner.xcodeproj/project.pbxproj` 里，不在 Dart 测试的范围里。
/// 见 `doc/open-items.md` 的 B23。
void main() {
  Get.testMode = true;

  _parentAppBarMatrix();
  _childSelectorMatrix();
  _pointCardMatrix();
  _statusChipMatrix();
  _weekStripMatrix();
  _textScaleMatrix();
}

// ── 视口矩阵 ──────────────────────────────────────────────────────────────

/// **宽度是主角，但「形状」（宽高比）同样是主角。**
///
/// 844×390 的横屏和 390×844 的竖屏，宽度差了 2.2 倍，而坏的方式完全不同：
/// 竖屏是「一行放不下」，横屏是「一列放不下」。所以档位不能只按宽度排。
///
/// 下限 320 是 iOS 与 Android **都**真实存在的最窄宽度（iPhone SE 竖屏、
/// iPad 侧边分屏 Slide Over 恰好也是 320）；上限 1600 是 Web 宽屏。
///
/// ⚠️ **每一档都必须对应一台真机或一个真实系统场景**。`label` 不是注释，
/// 它是失败信息的一部分（见 [_expectNoOverflow]）：红的时候要能直接说出
/// 「哪一台手机上坏了」。写成「平板」这种笼统名字，等于把这条信息丢掉。
/// 2026-09-26 补苹果版档位时，顺手把 `640×360` / `800×1280` 这类
/// 「谁都不是」的尺寸换成了真机型号名。
class _Viewport {
  const _Viewport(this.label, this.size);

  final String label;
  final Size size;
}

// ── 具名常量（**引用一律用名字，不许用索引**）───────────────────────────────
//
// 第 6 组（字号）原来写的是 `_viewports[1]` / `_viewports[2]`。
// 那是这个文件里最脆弱的一处：往列表中间插一档，那两条用例就**悄悄**跑到
// 别的设备上去了 —— 不报错、不变红，Dart 也没法检查「你想指的是哪一个」。
// 补苹果版档位正要动这个列表，所以先把名字固化下来。
const _vpSePortrait = _Viewport('iPhone SE 竖屏 320×568', Size(320, 568));
const _vpAndroidSmall = _Viewport('小屏安卓 360×640', Size(360, 640));
const _vpPhone14 = _Viewport('iPhone 14 竖屏 390×844', Size(390, 844));
const _vpAndroidLarge = _Viewport('大屏安卓 412×915', Size(412, 915));
const _vpFoldable = _Viewport('折叠屏展开 600×960', Size(600, 960));
const _vpAndroidTabletPortrait = _Viewport('安卓平板竖屏 800×1280', Size(800, 1280));
const _vpAndroidTabletLandscape = _Viewport(
  '安卓平板横屏 1280×800',
  Size(1280, 800),
);
const _vpAndroidLandscape = _Viewport('小屏安卓横屏 640×360', Size(640, 360));
const _vpWeb = _Viewport('Web 宽屏 1600×900', Size(1600, 900));

// ── 以下五档是 2026-09-26 补的「苹果版真实尺寸」──────────────────────────
//
// 起因：虫子纠正说问的是**伴学苹果版**（iPad + iPhone），而上面那批档位里
// 横屏只有 `640×360`、平板只有 `800×1280` —— 苹果阵营一台真机都对不上。
//
// 苹果版和 Android 在适配上的关键差别**不在「屏大屏小」**，而在于：
//   · iPhone 允许横屏（`Info.plist` 给了 LandscapeLeft/Right），而横屏时
//     可用**高度**只剩 320~430dp，是纵向溢出最容易破的地方；
//   · iPad 没有锁全屏（`Info.plist` 里**没有** `UIRequiresFullScreen`）
//     ⇒ Split View / Slide Over 都能用，**Slide Over 只有 320dp 宽**。
//     也就是说 iPad 上会真的出现「手机宽度」的渲染，而且这个宽度是
//     用户拖动分屏条**动态**产生的 —— 不是开头选好的。
const _vpSeLandscape = _Viewport('iPhone SE 横屏 568×320', Size(568, 320));
const _vpPhone14Landscape = _Viewport('iPhone 14 横屏 844×390', Size(844, 390));
const _vpPhoneMaxLandscape = _Viewport(
  'iPhone 15 Pro Max 横屏 932×430',
  Size(932, 430),
);
const _vpPadProPortrait = _Viewport(
  'iPad Pro 13" 竖屏 1024×1366',
  Size(1024, 1366),
);
const _vpPadSlideOver = _Viewport('iPad 侧边分屏 320×1366', Size(320, 1366));

/// 全部档位（14 档）。
///
/// 数量是**有意**的：这个文件的全部价值在于「只有某一档坏」这个信息，
/// 档位少了就等于没测。而每一条都只是一个 widget 测试，代价可以忽略。
const _viewports = <_Viewport>[
  // 竖屏 · 从最窄到折叠屏
  _vpSePortrait,
  _vpAndroidSmall,
  _vpPhone14,
  _vpAndroidLarge,
  _vpFoldable,
  // 横屏 · 高度被压到 320~430，纵向最容易破
  _vpAndroidLandscape,
  _vpSeLandscape,
  _vpPhone14Landscape,
  _vpPhoneMaxLandscape,
  // 平板 · 安卓与苹果各一台（形状不同：800×1280 偏瘦、1024×1366 更方）
  _vpAndroidTabletPortrait,
  _vpAndroidTabletLandscape,
  _vpPadProPortrait,
  // iPad 分屏 · 苹果版**独有**的最窄场景，320 与 iPhone SE 同宽但高一倍
  _vpPadSlideOver,
  // 超宽 · Web
  _vpWeb,
];

// ── 渲染脚手架 ────────────────────────────────────────────────────────────

/// 把视口切成 [viewport]，并把 [child] 放进一个带 16dp 内边距的页面里。
///
/// `devicePixelRatio` 设成 1，这样 `physicalSize` 的数值**就是 dp**，
/// 上面矩阵里的数字可以直接和设计稿对齐（同 `parent_app_bar_test.dart`）。
///
/// 刻意保持**最朴素**的形态：`GetMaterialApp` 直接包 `Scaffold`，不额外插
/// `MediaQuery`、不包 `Builder`。第 2~5 组全走这里，多一层插桩就多一处
/// 「所有组一起红」的机会 —— 而红的时候还分不清是组件的问题还是脚手架的问题。
///
/// 字号那一组需要改 `textScaler`，它单独用 [_pumpWithTextScale]，
/// 失败被隔离在那一组里。
Future<void> _pumpInBody(
  WidgetTester tester,
  _Viewport viewport,
  Widget child,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = viewport.size;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    GetMaterialApp(
      home: Scaffold(
        // 真实的卡片都长在页面的内边距里，撑满「屏幕宽 − 32」。
        // 不加这一层，组件能多拿 32dp，会放过一些本该暴露的溢出。
        body: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    ),
  );
  await tester.pump();
}

/// 与 [_pumpInBody] 相同，但把系统字号放大到 [textScale]。
///
/// ⚠️ 单独一支，不合并进 `_pumpInBody`：这里要动 `MediaQuery`，而
/// `MediaQuery` 的注入方式**与 Flutter 版本有关**，属于「可能因版本而变的
/// 一行」。让只有 3 条用例依赖它，出问题时其余组照常给结论。
///
/// 构造 `MediaQueryData` 有两条必须避开的写法：
///
///   1. **不能**写 `MediaQueryData(textScaler: …)` —— 那个无参构造会把
///      `size` 变成 `Size.zero`，整棵子树被压成 0×0：测试全绿，什么都没测到；
///   2. **不能**写 `MediaQuery.of(context).copyWith(…)` 套在 `home` 里 ——
///      新版 `WidgetsApp` 不再自己插入 `MediaQuery`，`home` 那个位置
///      拿不拿得到要按版本赌。
///
/// 所以走 `MediaQueryData.fromView(tester.view)`：它直接**从视口算**
/// size / padding / devicePixelRatio，与视口设置同源，不依赖任何上层继承。
Future<void> _pumpWithTextScale(
  WidgetTester tester,
  _Viewport viewport,
  Widget child, {
  required double textScale,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = viewport.size;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(
        tester.view,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: GetMaterialApp(
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 顶栏要挂在 `Scaffold.appBar` 上，**不能**塞进 body —— 它拿到的宽度
/// 要减去 leading / actions，塞进 body 测不出真问题。
Future<void> _pumpAsAppBar(
  WidgetTester tester,
  _Viewport viewport,
  PreferredSizeWidget appBar,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = viewport.size;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    GetMaterialApp(home: Scaffold(appBar: appBar, body: const SizedBox())),
  );
  await tester.pump();
}

/// 断言「没溢出」，并把**哪一档坏了**写进失败信息。
///
/// 不加这个的话，矩阵里九条一起跑，红的时候只有一句
/// `A RenderFlex overflowed...`，还得自己去数第几档 —— 而矩阵测试的
/// 全部价值就在「只有某一档坏」这个信息上。
///
/// ⚠️ `takeException()` 会**取走**异常（取一次就没了），所以每个测试里
/// 只在渲染完成后调用一次。若一次 pump 产生了多个异常，剩下的仍会被
/// 框架在测试结束时当作未处理异常报出来 —— 失败窗口不会漏。
void _expectNoOverflow(WidgetTester tester, _Viewport viewport, String what) {
  expect(
    tester.takeException(),
    isNull,
    reason:
        '${viewport.label}：$what 溢出。宽度是这一组里唯一变化的量，'
        '只有一档红就意味着「那一档的可用空间不够」',
  );
}

// ── 第 1 组：家长端顶栏 ───────────────────────────────────────────────────

/// 顶栏是**已知会溢出**的地方（真机报回来过 51px），也是唯一有现成测试的
/// 地方 —— 但那个测试只跑手机宽度（360~412），**从没跑过平板**。
/// 平板正是它注释里那句「封一个上限，免得在平板/横屏上被拉成一整条」
/// 想解决的问题，所以这里把平板补上。
void _parentAppBarMatrix() {
  List<ParentChild> children({required bool single}) => single
      ? const [ParentChild(id: 'stu_0', name: '林小宇')]
      : const [
          ParentChild(id: 'stu_0', name: '林小宇'),
          ParentChild(id: 'stu_1', name: '林小桐'),
          ParentChild(id: 'stu_2', name: '李雨霏'),
        ];

  group('家长端顶栏：全宽度都不溢出', () {
    for (final viewport in _viewports) {
      testWidgets('${viewport.label} · 单孩子', (tester) async {
        final list = children(single: true);
        await _pumpAsAppBar(
          tester,
          viewport,
          ParentAppBar(
            students: list,
            selectedId: list.first.id,
            onSelect: (_) {},
            unreadCount: 0,
          ),
        );
        _expectNoOverflow(tester, viewport, '顶栏（单孩子）');
        // 反面：单孩子时标题是固定的「家长端」，它必须在。
        expect(find.text('家长端'), findsOneWidget);
      });

      testWidgets('${viewport.label} · 多孩子（下拉）', (tester) async {
        final list = children(single: false);
        await _pumpAsAppBar(
          tester,
          viewport,
          ParentAppBar(
            students: list,
            selectedId: list.last.id,
            onSelect: (_) {},
            unreadCount: 3,
          ),
        );
        _expectNoOverflow(tester, viewport, '顶栏（多孩子 + 未读红点）');
        // 反面：名字没被省略。把标题压成 0 宽度也能不溢出，那是另一种坏法。
        // 选中的是「李雨霏」—— 下拉当前值必须看得见。
        expect(
          find.text('李雨霏'),
          findsOneWidget,
          reason: '顶栏溢出的代价通常就是名字被省略，这一条是它的反面',
        );
      });
    }
  });
}

// ── 第 2 组：孩子选择器（下拉 + 卡片） ────────────────────────────────────

/// 提到顶层而不是写在 `_childSelectorMatrix()` 里：这两个列表要出现在
/// `const` 构造里，而**局部** const 变量被 const 表达式引用虽然合法，
/// 却要求声明顺序严格在前 —— 顶层常量没有这个隐式约束，
/// 也省得下一个人在里面加一行时突然收到一句看不懂的报错。
const _selectorChildren = <ParentChild>[
  ParentChild(id: 'stu_0', name: '林小宇'),
  ParentChild(id: 'stu_1', name: '林小桐'),
];

void _childSelectorMatrix() {
  group('孩子选择器：全宽度都不溢出', () {
    for (final viewport in _viewports) {
      testWidgets('${viewport.label} · 下拉', (tester) async {
        await _pumpInBody(
          tester,
          viewport,
          const ChildSelectorDropdown(
            students: _selectorChildren,
            selectedId: 'stu_0',
            onSelect: _noop,
          ),
        );
        _expectNoOverflow(tester, viewport, '孩子下拉');
        expect(find.text('林小宇'), findsOneWidget);
      });

      testWidgets('${viewport.label} · 卡片', (tester) async {
        await _pumpInBody(
          tester,
          viewport,
          const ChildSelectorCard(
            students: _selectorChildren,
            selectedId: 'stu_0',
            onSelect: _noop,
          ),
        );
        _expectNoOverflow(tester, viewport, '孩子选择卡片');
        // 卡片用 Wrap 排 chip，两个名字都该在。
        expect(find.text('林小宇'), findsOneWidget);
        expect(find.text('林小桐'), findsOneWidget);
      });
    }
  });
}

void _noop(String _) {}

// ── 第 3 组：积分余额卡 ───────────────────────────────────────────────────

void _pointCardMatrix() {
  const account = PointAccount(
    balance: 128,
    totalEarned: 260,
    totalSpent: 132,
    entryCount: 17,
  );

  group('积分余额卡：全宽度都不溢出', () {
    for (final viewport in _viewports) {
      for (final compact in [false, true]) {
        testWidgets('${viewport.label} · compact=$compact', (tester) async {
          await _pumpInBody(
            tester,
            viewport,
            PointBalanceCard(
              account: account,
              subtitle: '本周 +25，已兑换 2 次',
              onOpenLedger: () {},
              compact: compact,
            ),
          );
          _expectNoOverflow(tester, viewport, '积分卡（compact=$compact）');
          expect(find.text('我的积分'), findsOneWidget);
        });
      }
    }
  });
}

// ── 第 4 组：状态类小组件 ─────────────────────────────────────────────────

void _statusChipMatrix() {
  group('状态类小组件：全宽度都不溢出', () {
    for (final viewport in _viewports) {
      testWidgets('${viewport.label} · 状态标签', (tester) async {
        // ⚠️ 这一整个 `Column` **不能**加 `const`：`NeedsGradingSwitch.onChanged`
        // 是必填的 `ValueChanged<bool>`（非空类型），只能给闭包，而闭包不是
        // 常量表达式。`note` 用了一句偏长的文案 —— 那是有意的：这一组要压的
        // 就是「文字最长时会不会把行撑破」，用一句短的等于没测。
        await _pumpInBody(
          tester,
          viewport,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const StatusChip(label: '待更正', color: Colors.red),
              const SizedBox(height: 8),
              const HomeworkStatusChip(status: HomeworkStatus.needFix),
              const SizedBox(height: 8),
              const LocalGradingChip(),
              const SizedBox(height: 8),
              const LocalGradingChip(showNote: true),
              const SizedBox(height: 8),
              NeedsGradingSwitch(
                value: false,
                onChanged: (_) {},
                note: '关闭后只检查书写是否规范，不再判断这道题的对错',
              ),
            ],
          ),
        );
        _expectNoOverflow(tester, viewport, '状态标签组合');
        // 反面：两个「待更正」分别来自 StatusChip 与 HomeworkStatusChip
        // 的枚举 label，都要在。
        expect(find.text('待更正'), findsWidgets);
        expect(find.text('离线参考结果'), findsWidgets);
      });
    }
  });
}

// ── 第 5 组：周历（7 列网格）★ ────────────────────────────────────────────

/// 这是全项目**唯一**一个七等分的横向网格（`Row` + 7×`Expanded` +
/// 右侧一个图标按钮），网格类布局正是宽度变化最直接的受力点：
/// 每一格从 393 宽屏上的约 47dp，到 320 窄屏上只剩约 36dp，
/// 而格子里要塞下「星期 + 两位数日期 + 一行脚注」。
///
/// 日期用**代码算**而不是写死：`2026-09-26` 是星期六，那一周是 21~27，
/// 但这属于「本该由测试自己算」的东西 —— 手写一遍等于给未来的自己
/// 埋一个「哪天改了锚点就假红」的坑（同 `WeekStrip` 注释里
/// 「测试与走查要能钉住今天是哪天，否则断言会随运行日期漂移」）。
void _weekStripMatrix() {
  // 固定日期，不取 `DateTime.now()`。
  final today = DateTime(2026, 9, 26);
  final monday = today.subtract(Duration(days: today.weekday - 1));
  final sunday = monday.add(const Duration(days: 6));

  group('周历（七列网格）：全宽度都不溢出', () {
    for (final viewport in _viewports) {
      testWidgets('${viewport.label} · 带月历入口', (tester) async {
        await _pumpInBody(
          tester,
          viewport,
          WeekStrip(
            selectedDate: today,
            today: today,
            onDateSelected: (_) {},
            onPickMonth: () {},
          ),
        );
        _expectNoOverflow(tester, viewport, '周历（含右侧月历图标）');

        // 反面一：七个星期标签一个都不能少（被挤掉就是真 bug）。
        for (final label in ['一', '二', '三', '四', '五', '六', '日']) {
          expect(
            find.text(label),
            findsOneWidget,
            reason: '星期「$label」那一格在 ${viewport.label} 下不见了',
          );
        }
        // 反面二：首尾两个日期数字都在（验证 7 格都真的排进去了）。
        expect(find.text('${monday.day}'), findsOneWidget);
        expect(find.text('${sunday.day}'), findsOneWidget);
      });

      testWidgets('${viewport.label} · 无月历入口', (tester) async {
        await _pumpInBody(
          tester,
          viewport,
          WeekStrip(
            selectedDate: today,
            today: today,
            onDateSelected: (_) {},
          ),
        );
        _expectNoOverflow(tester, viewport, '周历（无图标）');
        expect(find.text('一'), findsOneWidget);
        expect(find.text('日'), findsOneWidget);
      });
    }
  });
}

// ── 第 6 组：系统字号放大 ─────────────────────────────────────────────────

/// 这一组盯的是**另一个变量**：用户在系统设置里把字号调大。
///
/// 它和宽度是同一类风险 —— 「可用空间不够」—— 但来源不同：宽度是横向的，
/// 字号是纵向（也是横向的）双向的。全仓**没有任何一处**处理过
/// `textScaler`，也就是这一条从没被任何测试碰过。
///
/// ⚠️ **这一组若红，是发现，不是回归**。红说明某个固定高度 / 单行容器
/// 装不下放大后的文字。修法通常是给容器留余量，而不是把 `textScaler`
/// 按下去（那样只会让需要大字号的用户看不到）。
void _textScaleMatrix() {
  // 1.3 ≈ 系统「大」，1.5 ≈ 「很大」，2.0 是可访问性档位。
  const scales = <double>[1.3, 1.5, 2.0];
  final today = DateTime(2026, 9, 26);

  group('系统字号放大：组件不溢出（红 = 真实缺口）', () {
    for (final scale in scales) {
      // ⚠️ 按**名字**取，不按索引 —— 原来这里是 `_viewports[1]` /
      // `_viewports[2]`，一旦往列表中间插档位，这两条就会静默改测别的设备。
      for (final viewport in [_vpAndroidSmall, _vpPhone14]) {
        testWidgets('${viewport.label} · 字号 ×$scale', (tester) async {
          await _pumpWithTextScale(
            tester,
            viewport,
            WeekStrip(
              selectedDate: today,
              today: today,
              onDateSelected: (_) {},
              onPickMonth: () {},
            ),
            textScale: scale,
          );
          _expectNoOverflow(tester, viewport, '周历（字号 ×$scale）');
          expect(find.text('一'), findsOneWidget);
        });
      }
    }
  });
}
