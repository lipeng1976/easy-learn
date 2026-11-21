import 'package:easy_learn_app/models/study_plan_checkin_model.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/http_study_plan_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// 黑盒验证 `HttpStudyPlanRepository.queryStudyPlanCheckins`：
/// 当服务端把 `date` 列序列化成 ISO 串时，解析出的 `StudyPlanCheckin.date`
/// 必须是纯 `yyyy-MM-dd`，否则 `StudentController.isCheckedInToday` 永远 false，
/// 表现成「点完已打卡、刷新又待打卡」。
class _FakeApi extends DataApiClient {
  _FakeApi() : super(config: const DataConfig(baseUrl: 'http://127.0.0.1:1'));

  Map<String, dynamic>? nextJson;

  @override
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, Object?>? query,
  }) async =>
      nextJson ?? <String, dynamic>{};
}

void main() {
  test('queryStudyPlanCheckins 把服务端 ISO 日期归一成纯 yyyy-MM-dd', () async {
    final api = _FakeApi();
    api.nextJson = {
      'items': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'c1',
          'planId': 'p1',
          'studentId': 'stu_001',
          // 真实 +8 服务器序列化：DATE '2026-10-27' 当地 0 点 → toISOString 前一天 16:00Z
          'date': '2026-10-26T16:00:00.000Z',
          'createdAt': '2026-10-27T08:00:00.000Z',
        },
      ],
    };
    final repo = HttpStudyPlanRepository(api);
    final checkins = await repo.queryStudyPlanCheckins();
    expect(checkins, hasLength(1));
    expect(checkins.first.date, '2026-10-27');
    // 与本地 key 同形 → isCheckedInToday 能对上。
    expect(
      checkins.first.date == studyPlanDateKey(DateTime(2026, 10, 27)),
      isTrue,
    );
  });

  test('多个打卡记录各自归一，互不影响', () async {
    final api = _FakeApi();
    api.nextJson = {
      'items': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'c1',
          'planId': 'p1',
          'studentId': 'stu_001',
          'date': '2026-10-27T00:00:00.000Z',
          'createdAt': '2026-10-27T00:00:00.000Z',
        },
        <String, dynamic>{
          'id': 'c2',
          'planId': 'p2',
          'studentId': 'stu_001',
          // DATE '2026-10-28' 当地 0 点 → 前一天 16:00Z
          'date': '2026-10-27T16:00:00.000Z',
          'createdAt': '2026-10-28T08:00:00.000Z',
        },
      ],
    };
    final repo = HttpStudyPlanRepository(api);
    final checkins = await repo.queryStudyPlanCheckins();
    expect(checkins.map((c) => c.date).toList(), ['2026-10-27', '2026-10-28']);
  });
}
