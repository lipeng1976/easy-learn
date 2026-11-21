import 'package:easy_learn_app/services/auth_service.dart';
import 'package:easy_learn_app/services/cloud_runtime.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// **装配点只有一处**：`DatabaseService.useCloudRuntime()`。
///
/// ## 它为什么值得单独立一个文件
///
/// 这条不变量没有任何一条别的用例在守，而它一旦破了**不会报错**：
/// 数据那半边读到了运行时 → 请求走服务端；认证那半边没读到 → 登录留在本地。
/// 于是「用一个本地账号登进首页（登录页一切正常），然后每个列表都是空的」，
/// 因为读云端时手里没有 token。首页写着「今天暂无作业」，控制台干干净净。
///
/// 这不是假想的：这份代码里真的曾经有第二个可变全局 `currentCloudRuntime`，
/// 而 `useCloudRuntime()` 只改了其中一个，一次浏览器走查才撞出来。
/// 那份全局已经删掉，这个文件就是防止它以别的形式回来。
void main() {
  /// 一个**不会真的发请求**的运行时：地址指向一个必然连不上的端口。
  ///
  /// 这里只验「装配有没有生效」，不验任何一次调用 —— 用例不应该依赖网络，
  /// 也不该依赖外部有个服务在跑（那会让一次本地失败看起来像代码坏了）。
  CloudRuntime makeRuntime() => CloudRuntime(
        config: const DataConfig(baseUrl: 'http://127.0.0.1:1'),
      );

  tearDown(() {
    // 全局状态必须清掉：留着它会影响同一个文件里后面的用例，
    // 而那种失败表现为「单独跑能过、一起跑就挂」，很难指向真正的原因。
    DatabaseService.useCloudRuntime(null);
  });

  test('装配云端运行时之后，认证也必须一起切过去', () {
    final runtime = makeRuntime();
    addTearDown(runtime.dispose);

    DatabaseService.useCloudRuntime(runtime);

    expect(DatabaseService.isCloud, isTrue);
    expect(DatabaseService.cloud, same(runtime));

    // ⚠️ 这一条就是那个 bug 本身。登录走哪条路由 `AuthService` 自己决定，
    // 而它读的是**门面**里的那一份 —— 两处各存一份时，这里会是 false，
    // 而 `DatabaseService.isCloud` 是 true，于是「数据上云、登录还在本地」。
    expect(
      AuthService().isCloud,
      isTrue,
      reason: '数据走了服务端，登录却还在本地比较口令 —— 半上云',
    );
  });

  test('控制用例：没装配时认证也在本地（不然上一条可能永远为真）', () {
    expect(DatabaseService.isCloud, isFalse);
    expect(DatabaseService.cloud, isNull);
    expect(AuthService().isCloud, isFalse);
  });

  test('默认构造**不带**读缓存（纯在线是本轮之前的全部行为）', () {
    final runtime = makeRuntime();
    addTearDown(runtime.dispose);

    // 这条不变量挡的是「顺手把 createReadCache() 塞进默认构造」。
    // 那样做的后果不是崩溃，而是**所有既有用例与本地模式一起悄悄带上了缓存**：
    // 失败会表现为「某些读结果不再随服务端变化」，而排查方向会指向业务代码。
    // 缓存只在 fromEnvironment() 那条路上装配，也就是只在真的配了数据服务时。
    expect(runtime.readCache, isNull);
    expect(runtime.api.cache, isNull,
        reason: '没装配就没有缓存 —— 每次读都打网络，与上云之前一字不差');
  });

  test('退回本地要能真的退回去', () {
    final runtime = makeRuntime();
    DatabaseService.useCloudRuntime(runtime);
    expect(AuthService().isCloud, isTrue);

    DatabaseService.useCloudRuntime(null);
    expect(DatabaseService.isCloud, isFalse);
    expect(AuthService().isCloud, isFalse);
    runtime.dispose();
  });
}
