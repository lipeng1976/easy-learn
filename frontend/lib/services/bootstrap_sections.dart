/// 首屏聚合端点（`GET /data/bootstrap`）的**段 ↔ 端点**对照表。
///
/// ## 这张表为什么必须单独一层，而且必须只有一份
///
/// 聚合端点省往返的手法不是「让控制器少读几次」，而是**客户端在第一次读落空时
/// 拉一次聚合，把它按段写进读缓存**；于是首页那十几次读各自命中自己那一份，
/// 一次网络都不用打。控制器、仓库、界面**一行都不用改**。
///
/// 这个手法有一个非常具体的失效方式：**缓存键必须取得一模一样**。
/// 读缓存按 `身份 | GET 路径?查询串` 存（见 `DataApiClient._cacheKey`），
/// 所以「聚合写进去的键」与「仓库读的时候算出来的键」只要差一个字符，
/// 那次读就会落空 —— 而这个失败**不报错**，只是退化成打一次网络。
/// 18 次变回 18 次，界面完全正常，没有人会注意到。
///
/// 所以：
///   · 每个 [BootstrapSection] 的 `path` / `query` 必须与仓库里那次调用的字面量
///     **逐字相同**（`test/bootstrap_prefetch_test.dart` 用「记录型 http 客户端」
///     驱动真实仓库，把实际发出的路径与这张表对照 —— 那是唯一能挡住它的东西）；
///   · 表只有这一份，实现与测试都读它。抄第二份就等于把「会不会漂」这件事
///     重新交回给运气。
library;

/// 段的作用域。与 `serverless/data-service/src/routes/bootstrap.js` 的 `scope` 一一对应。
enum BootstrapScope {
  /// 一次，覆盖本次身份可见的全部学生。键里**没有** `studentId`。
  broad,

  /// 每个可见学生各一段，服务端放在 `byStudent[<学生 id>]` 下。
  /// 对应客户端**按孩子循环**的两处（家长端的照片与公开心愿）。
  perStudent,

  /// 一次，只针对「当前看着的那个孩子」（服务端给 `actingStudentId`）。
  /// 积分账本与分值属于选中的孩子，不属于全部孩子。
  narrow,
}

/// 一段：它在响应里的名字，以及「客户端会用什么路径去读它」。
class BootstrapSection {
  const BootstrapSection({
    required this.name,
    required this.path,
    this.query,
    this.scope = BootstrapScope.broad,
  });

  /// 服务端响应里 `sections` 下的键名（见 `bootstrap.js` 的 `SECTIONS`）。
  final String name;

  /// 客户端读它的路径。
  final String path;

  /// 客户端读它时带的**固定**查询参数。`studentId` 不写在这里 ——
  /// 学生维度的两档作用域由 [scope] 决定，是另一回事。
  final Map<String, Object?>? query;

  final BootstrapScope scope;
}

/// 聚合端点路径。**只此一处** —— 传输层与测试都引用它。
const String kBootstrapPath = '/data/bootstrap';

/// 全部段。顺序与服务端 `SECTIONS` 一致，便于两边对照着读。
///
/// ⚠️ 加段 / 改路径时**必须**同时跑 `test/bootstrap_prefetch_test.dart`：
/// 它会因为「某个仓库实际打出的路径不在表里」而失败 —— 这是刻意的，
/// 因为那种情况下聚合会**悄悄地不再省那一次往返**。
const List<BootstrapSection> kBootstrapSections = <BootstrapSection>[
  // ===== 宽表 =====
  BootstrapSection(name: 'relationship', path: '/data/relationship'),
  BootstrapSection(name: 'homework', path: '/data/homework'),
  BootstrapSection(name: 'notifications', path: '/data/notifications'),
  BootstrapSection(name: 'workoutPlans', path: '/data/workouts/plans'),
  BootstrapSection(name: 'workoutRecords', path: '/data/workouts/records'),
  BootstrapSection(name: 'reviewMistakes', path: '/data/review/mistakes'),
  BootstrapSection(name: 'reviewPapers', path: '/data/review/papers'),
  BootstrapSection(name: 'reviewAttempts', path: '/data/review/attempts'),
  BootstrapSection(name: 'reviewPractice', path: '/data/review/practice'),
  BootstrapSection(name: 'reviewSummaries', path: '/data/review/summaries'),
  BootstrapSection(name: 'reviewExplains', path: '/data/review/explains'),
  BootstrapSection(name: 'studyPlans', path: '/data/study-plans'),
  BootstrapSection(name: 'studyPlanCheckins', path: '/data/study-plans/checkins'),
  BootstrapSection(name: 'dailyComments', path: '/data/daily-comments'),
  BootstrapSection(
    name: 'wishesCreated',
    path: '/data/wishes',
    query: <String, Object?>{'scope': 'created'},
  ),
  BootstrapSection(
    name: 'wishesUnfulfilled',
    path: '/data/wishes',
    query: <String, Object?>{'scope': 'unfulfilled'},
  ),

  // ===== 按学生分桶 =====
  BootstrapSection(
    name: 'homeworkImages',
    path: '/data/homework/images',
    scope: BootstrapScope.perStudent,
  ),
  BootstrapSection(
    name: 'wishesPublic',
    path: '/data/wishes',
    query: <String, Object?>{'scope': 'public'},
    scope: BootstrapScope.perStudent,
  ),

  // ===== 当前看着的那个孩子 =====
  BootstrapSection(
    name: 'pointLedger',
    path: '/data/points/ledger',
    scope: BootstrapScope.narrow,
  ),
  BootstrapSection(
    name: 'pointRules',
    path: '/data/points/rules',
    scope: BootstrapScope.narrow,
  ),
];

/// 在 [path] + [query] 上加一个 `studentId`。学生维度的两档作用域都用它。
///
/// 空 id 返回 null —— 调用方据此**跳过**这一段，而不是写一个
/// `?studentId=` 的键。服务端与客户端都会把空串参数丢掉，所以那个键
/// 永远不会被读到，写它只会白占一条缓存容量。
Map<String, Object?>? withStudentId(Map<String, Object?>? query, String studentId) {
  if (studentId.isEmpty) return null;
  return <String, Object?>{...?query, 'studentId': studentId};
}
