# 登录方式与「忘记密码」的预留设计

> 本期**没有**短信网关，所以短信相关的功能一律不可用。这份文档说明预留
> 做在了哪里、为什么这么做、以及接入短信服务时要改什么。

## 0. 一句话概括

**结构先立全，能力留一个开关。** 数据模型、接口路由、界面入口三处都已就位，
唯一的开关是 `SmsGateway.isConfigured`；接入时补一个 `SmsGateway` 实现
并把它接到 `defaultSmsGateway()` 上，业务代码一行不改。

三条硬性约束贯穿全文：

| 约束 | 为什么 |
| --- | --- |
| **不伪造成功** | 「假装发了一条短信」比「按钮灰着」糟糕得多：用户会一直等一条永远不来的短信，接入后也没人分得清哪段代码是真的 |
| **验证码不进客户端** | 校验一旦能在本地成立，「改密码」就等于没有鉴权 |
| **可用性只有一个真值来源** | 两处判断迟早对不上，而错法通常是「按钮能点、点了没反应」 |

---

## 1. 数据模型

### 1.1 `LoginMethod`（新增）

**位置**：`lib/models/login_method.dart`

| 值 | `code` | 依赖短信网关 |
| --- | --- | --- |
| 手机号 + 密码 | `phone` | 否 |
| 微信授权 | `wechat` | 否 |
| 手机号 + 验证码 | `sms_code` | 是 |

**约束**

- 持久化与传输只用 `code`，**不能用枚举下标**。枚举顺序是内部实现，
  将来在中间插入一个方式会让所有历史记录的 index 全部错位。
- `tryParse` 认不出来时返回 `null`，**不默认成 `phone`**。
  默认了会把「读到一条脏数据」表现成「用户上次用的是密码登录」。
- 枚举里**不写 `available` 字段**。写了就等于有了第二个可用性来源。
  可用性只由 `requiresSmsGateway` + 网关推导。

**已落地的使用点**：`AuthController._saveLastLogin` 把 `method.code` 写进
`easy_learn_last_login_v1`；登录页在存在记录时显示「上次使用：xxx」。

### 1.2 `UserModel` 的新增派生

**位置**：`lib/models/user_model.dart`

| 成员 | 含义 |
| --- | --- |
| `hasPassword` | 账号设置**过**密码。微信建号是 `false` |
| `hasPhone` | 绑了手机号。没有它就没有收码的地方 |
| `canUse(LoginMethod)` | 账号这侧是否具备条件（**不代表功能已开通**） |
| `passwordUpdatedAt` | 密码最后一次设置 / 修改的时间 |
| `maskPhone(String)` | `138****0001`，让用户确认收码号码，又不全量暴露 PII |

**约束**

- `hasPassword` 只向上传**布尔结论**，不传 `password` 本身。
  `UserModel` 会飘到界面层，那里放一份明文口令，迟早有人顺手打印出来。
- `canUse` 返回 `true` **不等于能用**：短信是否开通由网关说了算，
  两者都成立才成立。`AuthController.isLoginMethodAvailable` 把两者合起来判。
- `passwordUpdatedAt` 本期**只写不判**。写它是为了让改密功能上线时
  不用再走一次迁移；判它（改密后使旧登录态失效）留给后续。

### 1.3 数据库 v23

**位置**：`lib/services/database_service.dart`

- `_initDatabase(version: 23)`
- `_onCreate`：`app_user` 增加 `passwordUpdatedAt TEXT`
- `_onUpgrade`：`if (oldVersion < 23)` 分支

> ⚠️ **三处必须同步改**。「`_onCreate` 漏列」的后果是老库升级没事、
> **全新安装直接炸**，这个项目已经栽过一次。`test/auth_schema_migration_test.dart`
> 两条路都测了。

**约束**

- 只加一列，**刻意不建客户端验证码表**。验证码的存在与校验都在服务端；
  客户端建一张表等于给「本地把码比出来」开了一条捷径。
- 老库回填时只给 `password IS NOT NULL AND password <> ''` 的行写时间。
  给没有密码的账号（微信建号）回填，会让界面把它显示成「已设置密码」。

### 1.4 短信验证码的若干值对象

**位置**：`lib/services/sms_gateway.dart`

- `SmsPurpose`（`sms_login` / `reset_password`）
- `SmsSendStatus`（`sent` / `unavailable` / `rejected`）+ `SmsSendResult`
- `SmsFailureKind`（`unavailable` / `invalidCode` / `rateLimited`）+ `SmsException`
- `SmsVerification`（`phone` / `token` / `purpose` / `expiresAt`）

**约束**

- **用途必须区分**。一次「登录」用的码不该能通过「重置密码」的校验，
  否则拿到登录码的人就等于拿到了改密权 —— 那是权限提升，不是体验问题。
- `SmsSendResult` **没有 `code` 字段**，`SmsVerification` 里也没有验证码。
  带回来一次，就会有人拿它做本地校验。
- 失败原因是**枚举而不是一句文案**（同 `OcrFailureKind` 的做法）：
  「没接入」去找运维、「码错了」让用户重输、「太频繁」让他等 ——
  三种处置互不相干，合成一句「操作失败，请重试」会让用户永远在错的方向上重试。

---

## 2. 接口路由

### 2.1 客户端端口 `SmsGateway`

**位置**：`lib/services/sms_gateway.dart`

```dart
abstract class SmsGateway {
  bool get isConfigured;                 // ← 唯一能力开关
  Future<SmsSendResult> sendVerificationCode({required String phone, required SmsPurpose purpose});
  Future<SmsVerification> verifyCode({required String phone, required String code, required SmsPurpose purpose});
}
```

**约束**

- **`isConfigured` 是唯一真值来源。** 界面不要判断 `kReleaseMode`、
  不要判断有没有配 URL、不要靠 `try/catch` 推断。
- 端口里**没有 verify 的本地实现**。`verifyCode` 一定是把码发给服务端，
  客户端不比对。`UnconfiguredSmsGateway` 对此的处理是**抛
  `SmsFailureKind.unavailable`，而不是返回一个能过的凭证**。
- `UnconfiguredSmsGateway` 被限制到最小：不发网络请求、不落库、
  不产生随机数、不返回验证码。它唯一做的事就是如实报告「没接」。
- 默认实现只挂在**一个函数**上：`defaultSmsGateway()`。
  各处直接写 `const UnconfiguredSmsGateway()` 的话，将来换实现要全局搜替换，
  漏掉的那一处会静默退化成「永远没接」。

### 2.2 `AuthService` 的三个预留用例

**位置**：`lib/services/auth_service.dart`

| 用例 | 行为 |
| --- | --- |
| `sendSmsCode` | 返回三态结果。号码格式不对 → `rejected`；未接入 → `unavailable`。**不抛假异常**（异常里塞不下 `retryAfterSeconds`） |
| `verifySmsCode` | 本地能判的（号码格式、空验证码）抛 `AuthException`；远程失败抛 `SmsException` 并带原因枚举 |
| `loginBySmsCode` | **不需要 `role`**：手机号在 `app_user` 上 UNIQUE，身份由账号决定 |
| `resetPasswordBySmsCode` | 走**和注册同一套**密码强度正则；成功后回读一次库再返回 |

**约束**

- 三个用例的第一行都是 `_requireSmsEnabled()`。**没接入时它们必须失败**，
  哪怕有人手工构造了一个 `SmsVerification`。理由不是防攻击（本地库本来就在
  用户手里），而是**防接错线**：将来有人把某个演示入口直接连到
  `resetPasswordBySmsCode` 上，没有这道闸就会「看起来能用」。
- 失败路径**不允许有任何副作用**。`resetPasswordBySmsCode` 在未接入时
  必须抛异常且一个字节都不改密码 —— 改了却报失败，用户会以为没改，
  然后发现旧密码登不上。这条有测试。
- 返回值**必须回读**，不能拿旧的 map 拼一个新 `UserModel`：
  拼出来的对象永远是成功的样子。
- `sendSmsCode` **不校验号码是否已注册**。校验了这个接口就变成了
  「查这个手机号在不在库里」的查询器；要拦注册状态，交给服务端在审计维度做。

### 2.3 新增的数据口 `AuthDataSource.updatePassword`

**位置**：`lib/services/auth_data_source.dart` + `DatabaseService` 的实现

**约束**

- **`updatedAt` 由调用方传入**，实现里不取 `DateTime.now()` ——
  测试要用注入时钟，实现里偷偷取一次就没法断言了。
- 用 `db.update`（只动两列），**不要用 `saveUser`**（replace 整行会清掉
  没传的列，顺手抹掉 `hobbies` 之类的资料）。
- 用户不存在时**抛异常**，不静默成功。静默成功会制造
  「改密成功但下次还是登不上」这类最难查的问题。

> ⚠️ `AuthDataSource` 的实现方用的是 `implements`，**新增方法必须显式实现**，
> 继承不到默认实现。目前有 3 个实现：`DatabaseService`、
> `test/auth_service_test.dart`、`test/registration_test.dart`
> （以及 `test/auth_provision_test.dart` 里的那个）。

### 2.4 服务端预留路由（网关）

**位置**：`serverless/ai-gateway/src/router.js`、`src/errors.js`

```
POST /auth/sms/send      ┐
POST /auth/sms/verify    ├─ 均为 501 + not_implemented + retryable:false
POST /auth/sms/reset     ┘
```

**三个决定各自的理由**

- `auth: false` —— 验证码要发给**还没有登录的人**。挂鉴权会把唯一需要它的
  那批用户全挡在外面，而且报 401，看起来像「凭证过期」。
- `quota: false` —— 不调模型，不该占学生的 AI 额度。短信自己的频控是
  另一套维度（按手机号 + 时间桶），上线时在 handler 里做，不要借 AI 的这套。
- **501 而不是 404** —— 看到 404 人会去查「是不是部署漏了这段代码」，
  看到 `internal` 会当成线上故障；`not_implemented` 才能让人立刻明白
  「这是计划内的空缺」，不去翻故障日志。
- `retryable: false` —— 让它可重试等于让客户端对着一个永远不会成功的请求
  退避重试，把「功能没上线」表现成「偶发失败」。

**部署归属未决**：网关目前只服务 AI（名字叫 `ai-gateway`）。短信端点是
落在同一个函数里，还是另开一个函数，属于部署决策，本期只钉契约不定部署。

---

## 3. 界面入口

| 入口 | 位置 | 未接入时的表现 |
| --- | --- | --- |
| 「忘记密码」（登录页） | `lib/pages/auth/login_page.dart` | 进入 `/forgot-password`，页顶横幅说明原因 |
| 「验证码登录（未开通）」（登录页底部） | 同上 | 进入 `/sms-login`，同样带横幅 |
| 「修改密码 / 设置密码」（个人信息页 → 账号与安全） | `lib/pages/shared/profile_page.dart` | 进入 `/forgot-password` 并带上当前手机号 |
| 验证码页 | `lib/pages/auth/sms_code_page.dart` | 发送按钮与提交按钮 `onPressed == null` |

**路由**：`lib/app.dart` → `/sms-login`（`SmsPurpose.login`）、
`/forgot-password`（`SmsPurpose.resetPassword`）。

**约束**

- 两个页面**不挂 `AuthGuard`**。有两个原因：它们是「进不去的时候要去的地方」，
  挂上就会形成「没登录 → 跳登录页 → 点忘记密码 → 被弹回登录页」的死循环；
  而且个人信息页里「修改密码」也要能进同一个页面，那是已登录状态。
  两条路必须都能走。
- **未接入时不禁用入口，只禁用动作。** 把入口藏起来或灰掉的结果是
  接入那天没人记得它存在，也没人验收得了入口文案。页面上的横幅负责说清楚
  「为什么现在不能点」以及「接入后会自动启用」。
- 横幅文案必须把**「功能没做好」和「服务没接入」分开**：
  用户看到「服务尚未接入」不会反复重试，看到「发送失败」才会一直点。
- 倒计时长度**以服务端给的 `retryAfterSeconds` 为准**，客户端不写死 60。
  两边对不上时用户会看到「按钮亮了但发不出去」。
- 验证码登录**不显示身份选择器**：手机号唯一确定账号，
  让用户再选一次只会多出一种失败（账号是家长、手滑选了学生，然后被拒）。

### 已修掉的一处假成功

`login_page.dart` 里「找回密码」原先弹的是
`Get.snackbar('提示', '短信找回密码已模拟完成')`。

那是**假成功**：用户以为密码被找回了，实际上什么都没发生、一条短信也没发。
现在改成进真正的预留页。这类「为了演示好看而报成功」的代码是本期最要防的东西。

---

## 4. 接入短信网关的启用清单

按顺序做完，业务代码一行不用改：

1. 实现 `SmsGateway`（新文件，例如 `lib/services/aliyun_sms_gateway.dart`）：
   - `isConfigured` 返回真实探测结果（配置齐了 + 模板过审）
   - `sendVerificationCode` 调服务端 `/auth/sms/send`
   - `verifyCode` 调 `/auth/sms/verify`，把服务端的错误码映射到 `SmsFailureKind`
2. 改 `defaultSmsGateway()` 一处，返回新实现。
3. 服务端：把 `/auth/sms/*` 的三个 stub handler 换成真实实现
   （签名、频控、验证码只存哈希、按 purpose 分桶、一次性消费）。
4. 跑 `flutter test` 与网关 `node --test`：
   `test/auth_provision_test.dart` 的「无缝启用」一组已经证明了
   **注入一个 `isConfigured == true` 的网关后整条链路能通** ——
   如果接入后这组测试挂了，说明业务代码被改动过，回去看看改了什么。
5. 真机验收：登录页的「验证码登录（未开通）」应自动变成「验证码登录」，
   两个页面的横幅应消失，按钮可点。

## 5. 本期刻意不做的事

| 不做 | 原因 |
| --- | --- |
| 客户端验证码表 | 会给「本地校验」开捷径 |
| 客户端校验验证码 | 校验必须由服务端完成，客户端只做**形制校验**（用途、过期、非空） |
| 通过短信「设置」密码（微信建号绑手机） | 需要先有绑定手机号的流程，本期没有；入口对没有手机号的账号是禁用的 |
| 登录页内嵌验证码表单 | 会得到两份「发送 + 倒计时 + 错误提示」，将来必然分别漂移 |
