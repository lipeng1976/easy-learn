import 'dart:convert';

import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/http_review_repository.dart';
import 'package:easy_learn_app/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 建卷后**必须采纳服务端生成的 id**（R2）。
///
/// ## 这条判据对应的真实故障（2026-10-23）
///
/// 症状：刚生成「数学错题重做卷 · 10月23日」，点进去说「这份资料还没有题目」，
/// 过一会儿再点又好了；导出/打印同样时好时坏。服务日志里躺着一条
/// `GET /data/review/paper-items?paperId=rp_1792715241521589_9` —— 客户端拿
/// **自己造的占位 id** 去查题，而服务端把题目存在自己生成的 UUID 下。
///
/// 根因：`createPaper` 用 `crypto.randomUUID()` 生成卷 id 并返回 `{paper, items}`，
/// 而客户端把返回值扔了、继续用占位 id。等列表刷新换成服务端 id 才恢复正常 ——
/// 于是表现为「有延迟」。
///
/// 所以判据盯的是：**返回值里的 id 与请求里的 id 不同时，仓库给回的必须是
/// 服务端那份**。负对照：响应没带 paper/items 时必须**硬失败**，
/// 不许静默退回占位 id（那样症状会和这个 bug 一模一样）。
void main() {
  const config = DataConfig(
    baseUrl: 'http://127.0.0.1:8788',
    requestTimeout: Duration(seconds: 5),
  );

  DataApiClient clientWith(
    Future<http.Response> Function(http.Request request) handler,
  ) =>
      DataApiClient(
        config: config,
        session: _MemorySession(),
        httpClient: MockClient(handler),
      );

  ReviewPaper paper(String id) => ReviewPaper(
    id: id,
    studentId: 'stu_001',
    title: '数学错题重做卷 · 10月23日',
    subject: '数学',
    knowledgePoints: const ['分数比较'],
    itemCount: 1,
    createdAt: DateTime(2026, 10, 23, 8, 30),
  );

  ReviewPaperItem item(String id, String paperId) => ReviewPaperItem(
    id: id,
    paperId: paperId,
    mistakeId: 'rm_1',
    questionTitle: '分数比较题',
    questionBody: '比较 \$3/4\$ 与 \$2/3\$',
  );

  Map<String, Object?> rowFor(String id, {String? paperId}) => {
    'id': id,
    'paperId': ?paperId,
    'studentId': 'stu_001',
    'title': '数学错题重做卷 · 10月23日',
    'subject': '数学',
    'knowledgePoints': ['分数比较'],
    'status': 'draft',
    'itemCount': 1,
    'createdAt': '2026-10-23T00:30:00.000Z',
    if (paperId != null) 'mistakeId': 'rm_1',
    if (paperId != null) 'questionTitle': '分数比较题',
    if (paperId != null) 'questionBody': '比较 3/4 与 2/3',
    if (paperId != null) 'sortOrder': 0,
  };

  test('服务端重新生成 id 时，返回的是服务端那份（卷 + 题目）', () async {
    late Map<String, dynamic> sentBody;
    final api = clientWith((request) async {
      sentBody = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'ok': true,
          'data': {
            // 服务端生成的 UUID —— 与请求里的 `rp_...` 不同。
            'paper': rowFor('srv-paper-uuid'),
            'items': [rowFor('srv-item-uuid', paperId: 'srv-paper-uuid')],
          },
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    final saved = await HttpReviewRepository(api)
        .insertReviewPaperWithItems(paper('rp_local_1'), [
          item('rp_local_1_i0', 'rp_local_1'),
        ]);

    expect(
      (sentBody['items'] as List).single['mistakeId'],
      'rm_1',
      reason: '请求里必须带上题目与错题的对应关系',
    );
    expect(
      saved.paper.id,
      'srv-paper-uuid',
      reason: '没有采纳服务端生成的卷 id —— 接着用占位 id 查题目会查不到',
    );
    expect(saved.items.single.id, 'srv-item-uuid');
    expect(saved.items.single.paperId, 'srv-paper-uuid');
    // 题目与错题的对应关系必须还在：回传批改靠它。
    expect(saved.items.single.mistakeId, 'rm_1');
  });

  test('响应没带 paper/items 时硬失败，不静默退回占位 id', () async {
    final api = clientWith((request) async {
      return http.Response(
        jsonEncode({'ok': true, 'data': <String, Object?>{}}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    expect(
      () => HttpReviewRepository(api)
          .insertReviewPaperWithItems(paper('rp_local_2'), const []),
      throwsA(isA<StateError>()),
      reason: '静默沿用占位 id 会让「刚生成的资料没有题目」再次复发',
    );
  });
}

/// 最小会话替身：数据服务在 `AI_REQUIRE_AUTH=false` 时也可无 token 访问，
/// 这里只需要一个「有 user」的会话让客户端不抱怨。
class _MemorySession extends SessionStore {
  @override
  Future<void> initialize() async {}

  @override
  String? get token => 'test-token';

  @override
  Map<String, dynamic>? get user => const {'id': 'stu_001', 'role': 'student'};

  @override
  Future<void> save({
    required String token,
    required Map<String, dynamic> user,
  }) async {}

  @override
  Future<void> clear() async {}
}
