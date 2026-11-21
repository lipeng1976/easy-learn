import 'dart:async';

import 'package:get/get.dart';

import '../controllers/parent_controller.dart';
import '../repositories/ima_repository.dart';
import '../services/database_service.dart';
import '../services/data_api_client.dart';

/// ima 知识库同步的 UI 状态机。
///
/// 三个动作都收敛到 [ImaStatus] / [error] / [busy] 三个可观测量，页面只用 `Obx`
/// 订阅它们，不自己维护「正在连接」这种易漏的本地布尔 —— 这是项目里反复踩过的
/// 「点了没反应」坑（见 `doc/open-items.md` B21）：执行了但界面不重建，往往就是
/// 某个布尔没被 `Obx` 追踪。
///
/// ## 连接失败不污染状态
///
/// `connect` 抛错时不会把 `status` 残留下半截，而是回读一次真实状态，确保界面
/// 回到「连接前的真实情况」。否则家长看到「已连接」但服务端根本没建 KB，比直接报错更糟。
class ImaController extends GetxController {
  ImaController({ImaRepository? repo}) : _repo = repo ?? DatabaseService.ima;

  final ImaRepository _repo;

  /// ⭐ 当前伴学的学生（家长端）。ima 配置按学生归属，切孩子必须跟着切；
  /// 学生端为 null，由服务端按登录人自己解析。
  String? _studentId;
  Worker? _studentWorker;

  /// 状态请求代号。快速切孩子时，上一个学生的慢响应不能覆盖当前学生。
  int _statusGeneration = 0;

  /// 当前 [studentId] 这个学生的同步状态（父母共管时两边读到同一份）。
  final status = ImaStatus.unconnected.obs;

  /// 是否在与服务端交互（拉状态 / 连接 / 断开）。
  final busy = false.obs;

  /// 主动操作（连接 / 断开）的失败说明，会显示成红字。
  final error = RxnString();

  /// 只读状态拉取失败时的**灰字**提示。
  ///
  /// 「读不到 ima 状态」等价于「没开通」：按虫子 11-07 的硬规矩，
  /// 可选功能不可用不能变成一条红色错误。单独一份状态是为了不把
  /// 连接失败的真错误也一起降级掉。
  final hint = RxnString();

  /// 表单：ima 账号 clientId（来自家长的 ima 开放平台）。
  final clientId = ''.obs;

  /// 表单：ima 账号 apiKey。
  final apiKey = ''.obs;

  /// 两个字段都非空才允许点「连接」，避免把空串发给服务端。
  bool get canConnect =>
      clientId.value.trim().isNotEmpty && apiKey.value.trim().isNotEmpty;

  @override
  void onInit() {
    super.onInit();
    // 只在 ParentController 已注册时绑定：学生端 / 纯单元测试里没有它，
    // 这时 studentId 保持 null，服务端按登录人解析，行为不变。
    if (Get.isRegistered<ParentController>()) {
      final parent = Get.find<ParentController>();
      _studentWorker = ever<String>(parent.selectedStudentId, (id) {
        bindStudent(id);
      });
      // 首次只是记下当前孩子；页面 initState 会拉一次状态，别在这里重复发请求。
      bindStudent(parent.selectedStudentId.value, reload: false);
    }
  }

  @override
  void onClose() {
    _studentWorker?.dispose();
    super.onClose();
  }

  /// 切换当前伴学的学生。
  ///
  /// ⚠️ 立刻把状态清回「未开启」：不清的话，从已配好的老大切到没配的老二，
  /// 界面会继续显示老大的「已开启 + 库名」几秒，家长会以为老二也配好了。
  /// `available` 必须保留（它是部署级开关，不是学生级的），否则切换瞬间
  /// 会闪一下「当前未开启 ima 知识库」的整块说明卡。
  void bindStudent(String? id, {bool reload = true}) {
    final next = (id == null || id.isEmpty) ? null : id;
    if (next == _studentId) return;
    _studentId = next;
    status.value = ImaStatus(
      status: 'unconnected',
      available: status.value.available,
      studentId: next,
    );
    error.value = null;
    hint.value = null;
    if (reload) unawaited(loadStatus());
  }

  /// 拉一次最新状态（进页面时、断开后、连接失败后都调）。
  ///
  /// ⚠️ 每次拉取代号 +1，**只有最后一次**能写界面：切孩子时旧请求可能晚到，
  /// 不丢弃的话，界面会从老二的状态又跳回老大的「已开启 + 库名」——
  /// 正是「切孩子状态跟着切」最隐蔽的破法。busy 也只由最后一次负责收尾。
  Future<void> loadStatus() async {
    final generation = ++_statusGeneration;
    busy.value = true;
    error.value = null;
    hint.value = null;
    try {
      final next = await _repo.getStatus(studentId: _studentId);
      if (generation != _statusGeneration) return;
      status.value = next;
    } on DataApiException catch (_) {
      if (generation != _statusGeneration) return;
      // 读不到状态 = 按「没开通」呈现：灰字，不红错，不把底层异常原文
      // （可能含 URL / 堆栈）拼到界面上。
      status.value = ImaStatus.unconnected;
      hint.value = '暂时读不到 ima 状态，其余功能照常使用。';
    } catch (_) {
      if (generation != _statusGeneration) return;
      status.value = ImaStatus.unconnected;
      hint.value = '暂时读不到 ima 状态，其余功能照常使用。';
    } finally {
      if (generation == _statusGeneration) busy.value = false;
    }
  }

  /// 连接 ima。返回是否真的连上了（active）。
  Future<bool> connect() async {
    if (!canConnect) {
      error.value = 'clientId 与 apiKey 都不能为空';
      return false;
    }
    busy.value = true;
    error.value = null;
    try {
      final result = await _repo.connect(
        clientId: clientId.value.trim(),
        apiKey: apiKey.value.trim(),
        studentId: _studentId,
      );
      status.value = result;
      return result.isActive;
    } on DataApiException catch (e) {
      error.value = e.userMessage;
      // 失败不污染状态：回读真实情况，避免界面卡在「半连接」。
      try {
        status.value = await _repo.getStatus(studentId: _studentId);
      } catch (_) {
        // 回读也失败就保留原值，error 已记录。
      }
      return false;
    } catch (e) {
      error.value = '连接失败：$e';
      return false;
    } finally {
      busy.value = false;
    }
  }

  /// 断开 ima：置 unconnected，保留 KB 映射。
  Future<void> disconnect() async {
    busy.value = true;
    error.value = null;
    try {
      await _repo.disconnect(studentId: _studentId);
      await loadStatus();
    } on DataApiException catch (e) {
      error.value = e.userMessage;
    } catch (e) {
      error.value = '断开失败：$e';
    } finally {
      busy.value = false;
    }
  }
}
