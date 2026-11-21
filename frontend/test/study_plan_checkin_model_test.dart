import 'package:easy_learn_app/models/study_plan_checkin_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// 学习计划打卡「刷新后又变回待打卡」的根因测试。
///
/// 服务端 `rowToApi` 会把 PG 的 `DATE` 列（node-postgres 解析成 `Date` 对象）
/// 序列化成 `YYYY-MM-DDTHH:MM:SS.000Z`，在服务器非 UTC 时区下甚至会变成前一天。
/// 客户端本地比较、打点都用纯 `yyyy-MM-dd`。旧代码 `textOf(row['date'])` 原样取，
/// 永远对不上 → 打卡已存库、刷新却认不出。这里钉死归一函数的行为，并证伪旧写法。
void main() {
  group('studyPlanDateKeyFromRaw 归一服务端日期', () {
    test('服务器 +8 时区：DATE 当地 0 点被 pg 解析后 toISOString 成前一天 16:00Z → 归一成当天', () {
      // 真实序列化结果（非假设）：本地 +8 的 `2026-10-27` → `2026-10-26T16:00:00.000Z`。
      expect(studyPlanDateKeyFromRaw('2026-10-26T16:00:00.000Z'), '2026-10-27');
    });
    test('服务器 UTC', () {
      expect(studyPlanDateKeyFromRaw('2026-10-27T00:00:00.000Z'), '2026-10-27');
    });
    test('带显式时区偏移 +08:00', () {
      expect(studyPlanDateKeyFromRaw('2026-10-27T08:00:00.000+08:00'), '2026-10-27');
    });
    test('本来就是纯日期', () {
      expect(studyPlanDateKeyFromRaw('2026-10-27'), '2026-10-27');
    });
    test('null → 空串', () {
      expect(studyPlanDateKeyFromRaw(null), '');
    });
  });

  test('证伪：旧写法（直接 textOf）让 ISO 串与本地 key 对不上', () {
    // 真实 +8 服务器的序列化结果：DATE 的当天被搬成前一天 16:00Z。
    const raw = '2026-10-26T16:00:00.000Z';
    final key = studyPlanDateKey(DateTime(2026, 10, 27));
    // 旧：`date = textOf(raw)` 原样等于 ISO 串，与本地 key 不等 → 打卡读回认不出。
    expect(raw == key, isFalse);
    // 新：归一成纯日期后能对上 → 刷新后界面保持「已打卡」。
    expect(studyPlanDateKeyFromRaw(raw) == key, isTrue);
  });
}
