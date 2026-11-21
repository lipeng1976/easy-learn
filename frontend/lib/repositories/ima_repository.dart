/// ima 知识库同步的客户端契约（L2 数据访问层）。
///
/// 服务端端点见 `serverless/data-service/src/routes/ima.js`：
///   · `GET  /data/ima/status`     → **当前伴学学生**的同步状态与他的 KB
///   · `POST /data/ima/connect`    → 提交 clientId + apiKey，只给当前学生建 KB
///   · `POST /data/ima/disconnect` → 置 unconnected，保留 KB 映射
///
/// ⭐ 归属口径（2026-11-08 定稿，见 `doc/ima-integration-design.md` §2）：
/// **配置主体是学生**。三个端点都带 `studentId`（家长端是
/// `ParentController.selectedStudentId`），父母共管同一个孩子时读到同一行
/// 配置、同一个 KB；切孩子状态跟着切；学生端只读自己那份。
///
/// ## 这是「可选同步」——没有 ima 的家庭不该看到任何错误
///
/// 虫子 11-07 定的硬规矩：不是所有人都有 ima，没有的话功能可以不出现，
/// 但不能出错。未连接（`unconnected`）或整个服务没开通（`available:false`）时，
/// 核心功能（错题复习 / 打卡 / 阅读）**完全不受影响**——ima 只是把错题 /
/// 打卡档案额外推到家长自己的 ima 知识库，方便用 ima 做检索与二次学习。
/// 凭证由**配置人家长**持有（服务端加密），客户端永远只见状态与库名；
/// 学生端只能**只读**状态。
///
/// 所以：状态读失败按「未开通」处理（不弹红错）；`available:false` 时
/// 设置页 / 个人信息页 / 阅读导入入口整体隐藏。只有用户**主动点「连接」**
/// 才允许回明确错误。
///
/// ## 错误语义
///
/// `connect` / `getStatus` 抛出的都是 [DataApiException]（见 `data_api_client.dart`）：
/// 它的 `userMessage` 已经是一句能直接展示给家长的中文说明，UI 不必再翻译。
/// 常见码：`ima_auth_failed`（密钥错）、`server_config_missing`（服务端没配密钥）
/// 、`unavailable`（本地模式，无云端）。

library;

/// 单个学生知识库的状态快照。
class ImaStudentKb {
  const ImaStudentKb({
    required this.studentId,
    required this.kbId,
    required this.kbName,
  });

  factory ImaStudentKb.fromJson(Map<String, dynamic> json) => ImaStudentKb(
        studentId: json['studentId'] as String? ?? '',
        kbId: json['kbId'] as String? ?? '',
        kbName: json['kbName'] as String? ?? '',
      );

  final String studentId;
  final String kbId;
  final String kbName;
}

/// 家庭级 ima 同步状态。
class ImaStatus {
  const ImaStatus({
    required this.status,
    this.kbs = const [],
    this.ownerUserId,
    this.available,
    this.studentId,
    this.studentName,
  });

  /// status 取值：`unconnected` | `active` | `expired`。
  final String status;

  /// 服务端是否开通了 ima 能力。
  ///
  /// `null` = 老服务端 / 还没读到（按可用处理，免得一次升级就让已开通
  /// 家庭的功能凭空消失）；`false` = 整个部署没配 `IMA_CREDENTIAL_SECRET`，
  /// 这时所有 ima UI 应当整体隐藏。`fromJson` 缺该字段时保持 null。
  final bool? available;

  /// 「这个界面还要不要出现 ima」。
  bool get isFeatureEnabled => available != false;

  /// 该家庭下每个学生的知识库映射（仅 `active` 时有意义）。
  final List<ImaStudentKb> kbs;

  /// 凭证配置人（家长）。父母共管时，两位家长看到的都是同一个 id。
  final String? ownerUserId;

  /// 这份状态说的是**哪个学生**。切孩子时必须跟着变；
  /// null = 老服务端 / 还没拿到当前学生。
  final String? studentId;

  /// 该学生姓名（服务端回，仅用于 UI 标明「正在配谁」）。
  final String? studentName;

  factory ImaStatus.fromJson(Map<String, dynamic> json) => ImaStatus(
        status: json['status'] as String? ?? 'unconnected',
        kbs: [
          for (final e in (json['kbs'] as List? ?? const []))
            if (e is Map) ImaStudentKb.fromJson(Map<String, dynamic>.from(e)),
        ],
        ownerUserId: json['ownerUserId'] as String?,
        available: json['available'] as bool?,
        studentId: json['studentId'] as String?,
        studentName: json['studentName'] as String?,
      );

  bool get isActive => status == 'active';
  bool get isExpired => status == 'expired';

  /// 是否已连接（active 才算，expired 不算「在用」）。
  bool get isConnected => status == 'active';

  @override
  String toString() =>
      'ImaStatus($status, kbs=${kbs.length}${studentId == null ? '' : ', student=$studentId'}${ownerUserId == null ? '' : ', owner=$ownerUserId'})';

  static const ImaStatus unconnected = ImaStatus(status: 'unconnected');
}

/// 徽标文案的唯一来源（状态 → 一句话）。
///
/// `status == null` 有**两种**含义，必须分开：
///   · [failed] = true → 「状态未知」（读过了，没读到）
///   · [failed] = false → 「加载中…」（还在读）
///
/// 混成一句就会出现「加载完了还写着加载中」——那不是文案问题，是界面在撒谎。
/// 单独提成纯函数是为了能直接写判据，而不必去 pump 一个要真库的页面
/// （见 `test/ima_repository_test.dart`）。
String imaStatusLabel(ImaStatus? status, {required bool failed}) {
  if (status == null) return failed ? '状态未知' : '加载中…';
  if (status.isActive) return '已开启';
  if (status.isExpired) return '已失效';
  return '未开启';
}

abstract class ImaRepository {
  /// 读取 [studentId] 这个学生的同步状态。
  ///
  /// 传 null = 不指定（学生端由服务端按登录人自己解析；老服务端也兼容）。
  Future<ImaStatus> getStatus({String? studentId});

  /// 连接 ima：给 [studentId] 这**一个**学生建独立 KB。
  ///
  /// 仅家长可调用；已有配置时服务端直接复用，不会建第二个库。
  Future<ImaStatus> connect({
    required String clientId,
    required String apiKey,
    String? studentId,
  });

  /// 断开：置 unconnected，保留 KB 映射（重新连接可复用，不重建库）。
  Future<void> disconnect({String? studentId});
}
