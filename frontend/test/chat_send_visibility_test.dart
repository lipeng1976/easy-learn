import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/chat_controller.dart';
import 'package:easy_learn_app/models/chat_message_model.dart';
import 'package:easy_learn_app/models/relationship_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/shared/chat_page.dart';
import 'package:easy_learn_app/repositories/relationship_repository.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/http_relationship_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 真机反馈：「**伴学消息那，现在发送消息那发不出去**」。
///
/// ## 两层原因，这个文件各钉一半
///
/// **① 服务端根本没有聊天端点。** `chat_message` 表 / 索引 / RLS 一直都在，
/// 唯独没有路由 —— 客户端的 `HttpRelationshipRepository` 只能抛
/// `not_implemented`。已在 `src/routes/chat.js` 补上（判据在服务端的
/// `test/chat.test.js`，含三条越权反面）。
///
/// **② 客户端把异常吞了。** 旧 `ChatPage._send` 既不 catch、也不看结果，
/// 异常冒到 `Obx` 之外被框架吃掉，表现是**点发送毫无反应**；
/// 而且 `clear()` 照跑 —— 用户看到输入框空了，以为自己发出去了。
/// **这一条才是「发不出去」的真实体感来源**，也是本文件的主体。
///
/// 这个文件里最值钱的两条：
///   · 「失败时**输入框内容要留着**」—— 只断言"弹了提示"不够，
///     一个「弹提示 + 照样清空」的实现也能过（而用户得重打一遍字）；
///   · 「发送成功要**采纳服务端返回的那一行**」—— 与作业/照片同一条纪律（R2）。
class _StubRepo implements RelationshipRepository {
  _StubRepo({this.sendError});

  /// 非 null 时 `sendChatMessage` 抛它 —— 用来复现「服务端拒绝/网络失败」。
  final Object? sendError;

  /// 记录调用次数，用来区分「真的发了」与「界面看着像发了」。
  int sendCalls = 0;
  int queryCalls = 0;
  String? lastContent;

  @override
  Future<List<RelationshipModel>> queryRelationships(String userId) async =>
      [
        RelationshipModel(
          id: 'rel-1',
          studentId: 'stu-1',
          parentId: 'par-1',
          senderId: 'par-1',
          studentName: '林小宇',
          parentName: '王老师',
          status: RelationshipStatus.active,
        ),
      ];

  @override
  Future<List<ChatMessageModel>> queryChatMessages({
    required String relationshipId,
    required String requesterId,
  }) async {
    queryCalls++;
    // 这个文件的用例都从"空会话"开始 —— 要断言的是「发出去的那条」，
    // 有一堆历史消息反而会让 findsOneWidget 之类的断言含义变模糊。
    //
    // ⚠️ 用 `<ChatMessageModel>[]` 而不是 `const []`：仓储的真实实现
    // （本地 `.toList()` / 云端 `items.map(...).toList()`）给的都是**可增**列表，
    // 桩返回不可增列表就和生产不同形了 —— 而 `ChatController` 会把它
    // 直接当成 `messages` 的底层存储，一次 `add` 就能把这个差异炸出来。
    return <ChatMessageModel>[];
  }

  @override
  Future<ChatMessageModel> sendChatMessage({
    required String relationshipId,
    required String senderId,
    required String content,
  }) async {
    sendCalls++;
    lastContent = content;
    final err = sendError;
    if (err != null) throw err;
    // 服务端返回**它自己那行**（id / createdAt 由它定）。
    return ChatMessageModel(
      id: 'srv-msg-1',
      relationshipId: relationshipId,
      senderId: senderId,
      receiverId: 'par-1',
      content: content,
      createdAt: DateTime(2026, 9, 22, 21, 30),
      isRead: false,
    );
  }

  @override
  Future<RelationshipModel> createRelationshipInvitation({
    required String senderId,
    required String targetPhone,
  }) => throw UnimplementedError('本组用例不涉及邀请');

  @override
  Future<void> updateRelationshipStatus({
    required String id,
    required RelationshipStatus status,
  }) => throw UnimplementedError('本组用例不涉及改关系状态');

  @override
  Future<void> revokeRelationship({required String id}) =>
      throw UnimplementedError('本组用例不涉及解除结伴');
}

/// 造一个登录态：`ChatPage` 在 `initState` 里读 `AuthController.currentUser`。
void _seedUser(String id) {
  Get.put(AuthController());
  Get.find<AuthController>().currentUser.value = UserModel(
    id: id,
    name: '林小宇',
    phone: '13800000001',
    role: 'student',
    avatar: '👦',
  );
}

/// 把仓储塞进**页面自己会拿到的那一份控制器**里。
///
/// ⚠️ 不能只在外面 `Get.put(ChatController(repository: repo))`：`ChatPage`
/// 的 `State` 里写的是 `final controller = Get.put(ChatController())`，
/// 而 **`Get.put` 默认不覆盖已存在的实例**（`permanent: false` 也一样），
/// 于是页面上那个控制器是**另建的一个**，用的是真仓储 ——
/// `repo.sendCalls` 永远是 0，用例会以「压根没调用仓库」的形式失败，
/// 而失败信息会把注意力引向"发送路径没接通"，那是**假线索**。
///
/// 正解与 `parent_wish_redeem_flow_test.dart` 同一手法：注册一个子类实例，
/// 让页面 `Get.put(ChatController())` 拿到的就是它。
ChatController _install({RelationshipRepository? repository}) {
  return Get.put<ChatController>(_TestChatController(repository: repository));
}

/// 子类化的目的只有一个：能被 `Get.put` 命中，从而顶掉页面自己会建的那个。
class _TestChatController extends ChatController {
  _TestChatController({super.repository});
}

/// 收尾：排空 GetX snackbar 的定时器。
///
/// snackbar 是**排队**的：第一条到点自动关，第二条才显示，又新建一个定时器。
/// 不管它，用例结束时会得到「A Timer is still pending」——
/// 而那句话会把注意力引向"播放动画的 ticker"，与真正的失败原因无关。
/// 另外它是全局静态的，`Get.reset()` 清不掉，会残留到下一个用例。
///
/// 不用 `pumpAndSettle`：它只推进会排帧的定时器，不管这类纯等待定时器。
Future<void> _drainSnackbars(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(seconds: 4));
  }
}

void main() {
  setUp(() {
    Get.testMode = true;
  });

  tearDown(() {
    Get.reset();
  });

  group('读失败之后，仍然要发得出去（真机那条反馈的**真凶**）', () {
    // 这一组是整个文件最值钱的。
    //
    // 真机现象是「发送消息发不出去」，但根因不在发送，而在**上一次读取失败**：
    // 旧 `loadConversation` 的 catch 分支写的是 `messages.value = const []`，
    // 而 `RxList.value = 某列表` 是**把这个列表当成底层存储**（不复制）。
    // `const []` 不可增 → 之后发送成功时那句 `messages.add(...)` 抛
    // `Unsupported operation: Cannot add to an unmodifiable list`。
    //
    // 为什么这个 bug 特别难查：
    //   ① 「读过一次且失败了」是它的**前提**，网络抖一下就够了；
    //   ② 抛点在**发送成功之后**，消息其实已经落到服务端了 ——
    //      界面说「没发出去」、输入框还留着字，用户会重发一遍，对方收到两条；
    //   ③ 单纯看发送路径的代码完全正常，`sendChatMessage` 一行错都没有。
    //
    // ⚠️ 这一组刻意**打控制器**而不是走界面。原因是：失败态下整个 body 被
    // `_buildFailure` 换掉了，输入框**根本不在树上**，`enterText` 会以
    // 「Bad state: No element」失败 —— 那说明的是"界面上没有输入框"，
    // 不是"发不出去"。真机上可达这条路径的入口是 `selectConversation`
    // （点另一个联系人换会话），所以判据打在控制器上才是准的。
    test('读消息失败之后直接发送：不许炸在 `add` 上', () async {
      _seedUser('stu-1');
      final repo = _ReadFailThenOkRepo();
      final controller = _install(repository: repo);

      await controller.load('stu-1');
      expect(controller.failure.value, isNotNull, reason: '前置：读失败过');

      // 这里**不再读一次**：真机上用户遇到这种错往往就是直接再发一条。
      // 若先让读成功一次，`messages` 会被重新赋成可增列表、`const []` 被覆盖，
      // 用例就变绿了 —— 但它验的已经不是真机那条路径（我第一版就踩了这步）。
      await controller.send('rel-1', '带伞了');

      expect(
        controller.messages.single.content,
        '带伞了',
        reason: '读失败过一次之后，发送成功却没能把消息放进列表 '
            '—— 十有八九是 catch 里那句 `const []` 把底层存储变成了不可增列表',
      );
    });

    test('切会话读失败之后发送：同样不许炸（真机上这是点另一个联系人）', () async {
      // `selectConversation` 是界面上真实存在的入口。它失败时走的就是
      // `loadConversation` 的 catch —— 与上一条同路径、不同入口。
      // 两条都钉住，避免以后只修一条。
      _seedUser('stu-1');
      final repo = _ReadFailThenOkRepo()..readShouldFail = false;
      final controller = _install(repository: repo);

      await controller.load('stu-1'); // 先正常读一次
      repo.readShouldFail = true; // 紧接着切会话时读失败
      await controller.selectConversation('rel-1');
      expect(controller.failure.value, isNotNull, reason: '前置：切会话时读失败过');

      await controller.send('rel-1', '带伞了');
      expect(controller.messages.single.content, '带伞了');
    });

    test('反面：读成功之后发送当然也要进列表（保证上两条不是恒绿）', () async {
      _seedUser('stu-1');
      final repo = _ReadFailThenOkRepo()..readShouldFail = false;
      final controller = _install(repository: repo);

      await controller.load('stu-1');
      expect(controller.failure.value, isNull, reason: '前置：这一次读是成功的');

      await controller.send('rel-1', '带伞了');
      expect(controller.messages.single.content, '带伞了');
    });
  });

  group('发送失败必须看得见（真机那条反馈的主体）', () {
    testWidgets('失败时：弹提示 + **输入框内容保留**', (tester) async {
      _seedUser('stu-1');
      final repo = _StubRepo(
        sendError: DataApiException(
          code: 'not_implemented',
          message: '服务端尚未实现聊天发送端点',
        ),
      );
      final controller = _install(repository: repo);

      await tester.pumpWidget(const GetMaterialApp(home: ChatPage()));
      await tester.pumpAndSettle();
      // 前置：页面用的确实是注入的那一份。少了这句，页面若自己重建一个
      // 控制器（用真仓储），下面所有断言都打在另一个对象上 ——
      // 失败信息会指向"发送路径没接通"，而那是**假线索**。
      expect(
        identical(Get.find<ChatController>(), controller),
        isTrue,
        reason: '页面用了另一个控制器 —— 注入的假仓储没被使用，下面全是假结论',
      );

      await tester.enterText(find.byType(TextField), '这条应该发不出去');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();

      expect(repo.sendCalls, 1, reason: '压根没调用仓库 —— 那这条用例没测到发送路径');
      // ① 要说出来。
      expect(find.text('消息没发出去'), findsOneWidget, reason: '失败却一声不吭');
      // ② **要留着内容**。只断言 ① 的话，「弹提示 + 照样清空」也过 ——
      //    而用户得把刚打的字重打一遍，这才是"发不出去"最烦人的部分。
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(
        field.controller?.text,
        '这条应该发不出去',
        reason: '发送失败却清空了输入框 —— 用户以为发出去了，字也没了',
      );

      await _drainSnackbars(tester);
    });

    testWidgets('成功时：调用仓库 + 清空输入框 + 消息进列表', (tester) async {
      _seedUser('stu-1');
      final repo = _StubRepo();
      final controller = _install(repository: repo);

      await tester.pumpWidget(const GetMaterialApp(home: ChatPage()));
      await tester.pumpAndSettle();
      expect(
        identical(Get.find<ChatController>(), controller),
        isTrue,
        reason: '页面用了另一个控制器 —— 注入的假仓储没被使用，下面全是假结论',
      );

      await tester.enterText(find.byType(TextField), '妈妈我今天考了 95');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();

      expect(repo.sendCalls, 1, reason: '压根没调用仓库 —— 那这条用例没测到发送路径');
      expect(repo.lastContent, '妈妈我今天考了 95', reason: '上行内容被改了');

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.text, '', reason: '发成功了还留着旧文字');

      // 采纳的是**服务端返回的那一行**（R2）：id 是 srv-msg-1 而不是本地造的。
      expect(controller.messages.length, 1);
      expect(
        controller.messages.first.id,
        'srv-msg-1',
        reason: '内存里那份的 id 不是服务端给的 —— 后续按 id 的操作会全部落空',
      );
      expect(find.text('妈妈我今天考了 95'), findsOneWidget, reason: '发出去了但界面没回显');
    });

    testWidgets('空白内容：不调用仓库、不弹提示（点一下等于没点）', (tester) async {
      _seedUser('stu-1');
      final repo = _StubRepo();
      _install(repository: repo);

      await tester.pumpWidget(const GetMaterialApp(home: ChatPage()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '    ');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();

      expect(repo.sendCalls, 0, reason: '空白内容也发了 —— 服务端会 400');
      expect(find.text('消息没发出去'), findsNothing, reason: '点空输入框不该弹错误提示');
    });
  });

  group('加载失败不能伪装成「你还没结伴」', () {
    testWidgets('读失败 → 显示失败态与原因，而不是「暂无已组队成员」', (tester) async {
      _seedUser('stu-1');
      final controller = _install(repository: _FailingRepo());
      await tester.pumpWidget(const GetMaterialApp(home: ChatPage()));
      await tester.pumpAndSettle();

      expect(controller.failure.value, isNotNull, reason: '读失败没被记下来');
      expect(
        find.textContaining('暂无已组队成员'),
        findsNothing,
        reason: '把「读失败」显示成「你还没结伴」—— 用户会去重新邀请一个早已存在的关系',
      );
      expect(find.text('消息没能加载'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget, reason: '没有重试入口，用户只能退出去再进来');
    });

    testWidgets('真没结伴 → 仍然是「暂无已组队成员」', (tester) async {
      _seedUser('stu-1');
      final controller = _install(repository: _NoRelationRepo());
      await tester.pumpWidget(const GetMaterialApp(home: ChatPage()));
      await tester.pumpAndSettle();

      // 反面：这一条保证上一条不是因为「失败态恒显示」而通过。
      expect(controller.failure.value, isNull);
      expect(find.textContaining('暂无已组队成员'), findsOneWidget);
      expect(find.text('消息没能加载'), findsNothing);
    });
  });

  group('云端仓库：请求形状与返回行采纳', () {
    test('读消息：上行只带 relationshipId（身份来自票，不在参数里）', () async {
      final api = _RecordingApi()
        ..itemsResponse = [
          {
            'id': 'srv-1',
            'relationshipId': 'rel-1',
            'senderId': 'par-1',
            'receiverId': 'stu-1',
            'content': '今天带伞了吗',
            'createdAt': '2026-09-22T13:30:00.000Z',
            'isRead': true,
          },
        ];
      final repo = HttpRelationshipRepository(api);

      // `requesterId` 传一个**明显不同**的值：服务端只认票，
      // 客户端这边传什么都不该出现在请求里。
      final list = await repo.queryChatMessages(
        relationshipId: 'rel-1',
        requesterId: 'whoever-the-client-claims',
      );

      expect(api.lastPath, '/data/chat/messages');
      expect(api.lastQuery, {'relationshipId': 'rel-1'});
      expect(list.length, 1);
      expect(list.first.content, '今天带伞了吗');
      // 服务端给 `true`，本地那套是 `1/0` —— 映射错了会静默变成"未读"。
      expect(list.first.isRead, isTrue, reason: 'isRead 的布尔没归一化');
      // UTC → 本地。不转的话同一句话在两端差一个时区。
      expect(
        list.first.createdAt.toUtc(),
        DateTime.utc(2026, 9, 22, 13, 30),
        reason: 'createdAt 没解析对（时区或格式）',
      );
    });

    test('发消息：上行只有 relationshipId + content，且采纳服务端返回的行', () async {
      final api = _RecordingApi()
        ..messageResponse = {
          'id': 'srv-msg-9',
          'relationshipId': 'rel-1',
          'senderId': 'stu-1',
          'receiverId': 'par-1',
          'content': '带伞了',
          'createdAt': '2026-09-22T13:31:00.000Z',
          'isRead': false,
        };
      final repo = HttpRelationshipRepository(api);

      final msg = await repo.sendChatMessage(
        relationshipId: 'rel-1',
        senderId: 'stu-1',
        content: '带伞了',
      );

      expect(api.lastPath, '/data/chat/messages');
      expect(api.lastMethod, 'POST');
      // 上行**不能**带 receiverId —— 收信人由服务端按关系反推。
      expect(
        api.lastBody,
        {'relationshipId': 'rel-1', 'content': '带伞了'},
        reason: '上行带了多余字段（尤其 receiverId），服务端会 400 或采信它',
      );
      expect(msg.id, 'srv-msg-9', reason: '没采纳服务端返回的行');
      expect(msg.receiverId, 'par-1');
    });
  });
}

/// 记录最后一次请求，用来断言上行形状。
class _RecordingApi extends DataApiClient {
  _RecordingApi() : super(config: const DataConfig(baseUrl: 'http://127.0.0.1:1'));

  List<Map<String, dynamic>> itemsResponse = const [];
  Map<String, dynamic> messageResponse = const {};

  String? lastPath;
  String? lastMethod;
  Map<String, Object?>? lastQuery;
  Object? lastBody;

  @override
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, Object?>? query,
  }) async {
    lastPath = path;
    lastMethod = 'GET';
    lastQuery = query;
    return {'items': itemsResponse};
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path, {
    Object? body,
    String? authToken,
    Duration? timeout,
  }) async {
    lastPath = path;
    lastMethod = 'POST';
    lastBody = body;
    return {'message': messageResponse};
  }
}

/// 读关系就抛 —— 复现「云端端点不可用」。
class _FailingRepo extends _StubRepo {
  @override
  Future<List<RelationshipModel>> queryRelationships(String userId) async {
    throw DataApiException(
      code: 'not_implemented',
      message: '服务端尚未实现聊天读取端点',
    );
  }
}

/// 关系列表恒空 —— 复现「真的还没结伴」。
class _NoRelationRepo extends _StubRepo {
  @override
  Future<List<RelationshipModel>> queryRelationships(String userId) async =>
      const [];
}

/// 读**消息**第一次失败、之后成功；发送始终成功。
///
/// 这个桩存在的唯一理由，是复现真机那条时序：
/// 「**先读过一次会话、且失败了**，之后用户又发了一条消息」。
/// 少了这一半，`loadConversation` 的 catch 分支就永远不会被执行到，
/// 而真凶恰好就藏在那两行里（`messages.value = const []`）。
///
/// ⚠️ 失败的必须是 `queryChatMessages`（**读消息**），不是 `queryRelationships`：
/// 只让后者失败的话，`load` 会在调 `loadConversation` **之前**就抛出去，
/// catch 分支压根进不去 —— 用例会全绿，但它什么都没验到。
class _ReadFailThenOkRepo extends _StubRepo {
  bool readShouldFail = true;

  @override
  Future<List<ChatMessageModel>> queryChatMessages({
    required String relationshipId,
    required String requesterId,
  }) async {
    if (readShouldFail) {
      throw DataApiException(
        code: 'network',
        message: '网络不太稳定，消息没读完',
      );
    }
    return super.queryChatMessages(
      relationshipId: relationshipId,
      requesterId: requesterId,
    );
  }
}
