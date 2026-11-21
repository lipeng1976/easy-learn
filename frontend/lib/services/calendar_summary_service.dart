import '../models/homework_model.dart';
import '../models/study_plan_checkin_model.dart';
import '../models/workout_model.dart';
import '../services/data_api_client.dart';
import '../widgets/day_calendar.dart';

/// 日历月摘要的取数与缓存。
///
/// ## 它解决什么
///
/// 日历弹层要能「一眼看出这个月有没有数据」。按天逐次请求不行，有两个后果：
/// **翻月时打不了点**（不知道哪天有数据，只能让人一格一格点）+
/// **连点几天就是连发几次请求**。所以拆成「按月摘要 + 按天明细」
/// （见 `doc/historical-data-plan.md` §2.2）。
///
/// ## 缓存键是 `(学生, 月)`
///
/// 同一个孩子来回翻月不重发。**缓存必须按学生分开**：家长有两个孩子，
/// 切孩子之后如果命中上一个孩子的摘要，日历上的点会指错人 ——
/// 而「点错了」比「没有点」更坏，因为它看起来是有效信息。
///
/// ## 三条刻意的设计
///
/// ① **摘要失败不抛给界面**：返回空 Map + 记录失败原因。
///    摘要是**加速手段，不是数据通路**（与首屏聚合同一处置）：
///    没有它日历照常可用、日期照常可选，只是没有小圆点。
///    抛出去会让「日历打不开」——那等于因为一个装饰性功能坏掉了核心功能。
///
/// ② **失败不写进缓存**。写进去的话，「那一次断网」会被记成一整个月的
///    「没有数据」，而用户翻回来还是空的、且不会重试 ——
///    这就是本项目最恨的那类静默失败。
///
/// ③ **本地模式返回空**。本地库里当然有数据，但按天/按月聚合是服务端的能力；
///    本地模式下日历不打点，而不是「本地也实现一遍聚合」——
///    那会让同一件事有两份实现，而它们一定会漂（本项目最贵的 bug 类型）。
///    这一条与 §2.4「本地模式降级为离线演示」的定位一致。
class CalendarSummaryService {
  CalendarSummaryService({required this.api, this.forceEmpty = false});

  /// 传输层。为 null 表示本地模式（不打点）。
  final DataApiClient? api;

  /// 测试用：强制走「没有摘要」那条路，不必构造一个假 api。
  final bool forceEmpty;

  /// 缓存：`'<studentId>|<yyyy-MM>'` → 那个月的打点。
  ///
  /// 只增不减（一个月的数据不会变历史）。十年 = 120 个月 × 孩子数，
  /// 每个最多 31 个小对象 —— 这个量级不需要淘汰策略，
  /// 加一个 LRU 只是引入一处新的错法。
  final Map<String, Map<String, DayMarks>> _cache = {};

  /// 正在飞的请求，按同一个键去重。
  ///
  /// ⚠️ **少了这一层会重复发请求**：翻月快一点就会连发两次同一月的摘要
  /// （`_cache` 只在**回来之后**才有值）。这与首屏预取那个「并发读把聚合
  /// 当成拉过了」是同一类问题，处置也一样：**并发读等同一个 Future**。
  final Map<String, Future<Map<String, DayMarks>>> _inflight = {};

  /// 上一次失败的原因（界面上不显示，排障用）。
  String? lastError;

  /// 取某个月的打点。**同一个键在缓存里有就直接返回，不打网络。**
  ///
  /// [students] 传 `null` 表示「不按学生筛」（服务端会用 token 推出的全部可见学生）——
  /// 学生端就是这一种。家长端传当前选中的孩子 id，
  /// 这样切孩子之后缓存键跟着变、不会串。
  Future<Map<String, DayMarks>> summaryFor(DateTime month, {String? studentId}) async {
    final key = '${studentId ?? ''}|${DayUtil.monthKey(month)}';
    final cached = _cache[key];
    if (cached != null) return cached;

    final api = this.api;
    if (api == null || forceEmpty) return const {};

    final pending = _inflight[key];
    if (pending != null) return pending;

    final request = _fetch(api, month, studentId, key);
    _inflight[key] = request;
    try {
      return await request;
    } finally {
      // 无论成功失败都要摘掉：失败的那些**没有写进 `_cache`**，
      // 所以下一次翻回来会重试 —— 这正是我们要的。
      _inflight.remove(key);
    }
  }

  Future<Map<String, DayMarks>> _fetch(
    DataApiClient api,
    DateTime month,
    String? studentId,
    String key,
  ) async {
    try {
      final query = <String, Object?>{
        'month': DayUtil.monthKey(month),
        // ⚠️ 服务端**不猜时区**（猜错就是静默偏一整天，见 R3），
        // 所以偏移必须由客户端说清楚。东八区是 480。
        //
        // 注意符号：Dart 的 `timeZoneOffset` 是「本地时间 − UTC」，
        // 东八区 = +8h = 480 分钟，与服务端 `+ interval '480 minutes'` 一致。
        'tzOffsetMinutes': '${month.timeZoneOffset.inMinutes}',
      };
      // 不传 = 服务端用 token 推出的**全部**可见学生（学生端就是这一种）。
      // ⚠️ 这个参数**不能**扩大范围 —— 服务端会用 `requireVisibleStudent`
      // 挡住越界的 id（404），见 `routes/calendar.js`。
      if (studentId != null) query['studentId'] = studentId;

      final data = await api.getJson('/data/calendar/summary', query: query);

      final days = data['days'];
      if (days is! List) {
        // 形状不对**不抛**（见类注释 ①），但要留痕 ——
        // 「响应里没有 days」与「这个月真的没数据」在界面上长得一样，
        // 而处置完全相反（前者要查接口，后者什么都不用做）。
        lastError = '响应里没有 days 数组';
        return const {};
      }

      final marks = <String, DayMarks>{};
      for (final row in days) {
        if (row is! Map) continue;
        final date = row['date'];
        if (date is! String || date.isEmpty) continue;
        marks[date] = DayMarks.fromJson(Map<String, dynamic>.from(row));
      }

      // **只有成功才写缓存**（见类注释 ②）。
      _cache[key] = marks;
      lastError = null;
      return marks;
    } on DataApiException catch (e) {
      lastError = e.message;
      return const {};
    } catch (e) {
      lastError = '$e';
      return const {};
    }
  }

  /// 清掉某个学生的缓存（换孩子 / 重新登录后调用）。
  ///
  /// 不做「全清」的公开方法：缓存是按学生分键的，
  /// 而「全清」在界面上没有对应的动作 —— 多一个入口就多一次漂的机会。
  void invalidate(String studentId) {
    _cache.removeWhere((k, _) => k.startsWith('$studentId|'));
  }

  /// 测试用：当前缓存了几个键。
  int get cacheSize => _cache.length;
}

/// 从**已加载的数据**里就地算出打点 —— 本地模式与「服务端摘要还没回来」时的兜底。
///
/// ## 为什么需要这一条
///
/// 摘要端点要一次额外往返。但**首屏那批数据里其实已经有作业和运动了**
/// （`controller.homeworkList` / `visibleWorkoutRecords`）。
/// 用它们算打点是零成本的：数据在手，只是需要按天归一下组。
///
/// 这带来两个好处：
///   · **本地模式也有打点**（不再依赖服务端）；
///   · **云端模式下摘要是纯增强** —— 它只在「首屏数据覆盖不到的月份」
///     （也就是用户翻到更早的月份）才必须。
///
/// ⚠️ 但两者**不能混用同一份打点**：本地算出来的只覆盖「已加载的那些行」
/// （作业默认 limit 50，所以只有最近的部分），而服务端摘要覆盖整月。
/// 直接合并会让用户以为「这个月只有这么几天有数据」。
/// 所以调用方要清楚自己给的是哪一种：日历上「有服务端摘要」时用它，
/// 否则退回本地算的（并接受它只覆盖已加载范围）。
class LocalDayMarks {
  const LocalDayMarks._();

  /// 从作业 + 运动记录 + 打卡算出打点。
  ///
  /// 三个来源的「那一天」语义**不同**，与 `doc/historical-data-plan.md` §2.3
  /// 那张表逐条对应：
  ///   · 作业按 `dueAt`（**到期日**）；
  ///   · 运动按 `start`（**实际发生的时刻**）；
  ///   · 打卡按 `date`，而它**本身就是本地日字符串**（没有时刻）——
  ///     直接拿 `yyyy-MM-dd` 当键，不做时区换算。
  static Map<String, DayMarks> build({
    required Iterable<HomeworkItem> homework,
    required Iterable<WorkoutRecord> workoutRecords,
    required Iterable<StudyPlanCheckin> checkins,
  }) {
    // 计数用可变累加器，最后再一次性固化成 DayMarks。
    //
    // ⚠️ 第一版是「取出旧值 → 造一个新 DayMarks 塞回去」，而 `DayMarks`
    // 是**不可变**的（字段全 final）—— 那么写出来的仍然是新对象，能跑。
    // 但它的写法容易让人以为「改一改就行」，而真正的问题是**它把
    // 『同一天两处都要加』这件事写成了三段各自为政的代码**。
    // 用 `_Tally` 累加器就没有这个问题：三个来源各自 `+= 1`，
    // 顺序无关、重复调用也安全。
    final tally = <String, _Tally>{};
    _Tally of(String key) => tally.putIfAbsent(key, () => _Tally());

    for (final h in homework) {
      of(DayUtil.dayKey(h.dueAt)).homework += 1;
    }
    for (final r in workoutRecords) {
      of(DayUtil.dayKey(r.start)).workout += 1;
    }
    for (final c in checkins) {
      // `date` 已是 `yyyy-MM-dd` —— **不要** `DateTime.parse(...).toLocal()`：
      // 那会把它当成 UTC 午夜再转到本地，东八区下变成前一天。
      final raw = c.date.trim();
      if (raw.isEmpty) continue;
      of(raw).checkin += 1;
    }

    return {
      for (final entry in tally.entries)
        entry.key: DayMarks(
          homework: entry.value.homework,
          workout: entry.value.workout,
          checkin: entry.value.checkin,
        ),
    };
  }
}

/// 可变累加器。只在 [LocalDayMarks.build] 内部用。
class _Tally {
  int homework = 0;
  int workout = 0;
  int checkin = 0;
}
