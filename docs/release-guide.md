# 发布指导手册（伴学 APP）

> 面向「把这个应用发出去」这件事，三块内容：
> **① 客户端怎么构建、怎么签名、怎么装到用户手机上**；
> **② 服务端（数据服务 + 数据库）怎么部署到云上**；
> **③ AI 大模型怎么配置、怎么验收**。
>
> 与其它文档的关系（避免重复，也避免读到过期结论）：
>
> | 文档 | 它管什么 | 现在还有效吗 |
> |---|---|---|
> | **本文** | 发布与部署的**全流程 + 每步的验收判据** | 2026-09-22 重新跑过一遍命令 |
> | `android-deploy-guide.md` | 安卓安装的三条路径、未知来源授权、厂商账号怎么开、AI 排障 | **部分过期**（它开头已标注）；§1.2 / §1.3 / §2 / §4 仍有效 |
> | `serverless/ai-gateway/README.md` | 网关**全部**环境变量、模型选型实测、已知限制 | 有效，是网关细节的权威 |
> | `cloud-migration-plan.md` | 数据服务的设计与阶段进度（S1–S6）、R1–R6 规则 | 有效，是「为什么这么设计」的权威 |
> | `open-items.md` | 还没做的、受环境阻塞的 | 有效 |

---

## 0 先看这一页

### 0.1 要发布的其实是**三样东西**，可以分开发

```
┌──────────────────────────────┐
│  客户端（APK / AAB / Web）     │   用户装在手机上 / 浏览器打开
│  两个服务地址是**编译期常量**   │   ← 所以它必须**最后**构建
└───────────┬──────────────────┘
            │  HTTPS
     ┌──────┴───────┐
     ▼              ▼
┌─────────────┐  ┌──────────────┐
│ 数据服务     │  │ AI 网关       │
│ 账号/作业/   │  │ 持有方舟 Key  │
│ 错题/积分    │  │ 配额与审计     │
└──────┬──────┘  └──────┬───────┘
       │                │
       ▼                ▼
┌─────────────┐  ┌──────────────┐
│ PostgreSQL  │  │ 火山方舟      │
│ 26 表 + RLS  │  │（大模型）     │
└─────────────┘  └──────────────┘
```

**推荐顺序：数据库 → 数据服务 → AI 网关 → 客户端。**
理由只有一个但很硬：客户端的两个地址（`DATA_API_BASE_URL`、`AI_BASE_URL`）是**编译期常量**
（`String.fromEnvironment`），服务端地址定下来之前构建出来的包，事后**没法在手机上改**。

### 0.2 先决定「发的是哪一种形态」

这一步不能跳。**同一份代码有三种发布形态，数据落在三个互不相通的地方** ——
用错形态最典型的现象是「我之前注册的账号说没有注册」（看起来像数据丢了，其实是这次的
客户端在翻另一份库）。判手上产物属于哪种：`node tools/build-mode.mjs`。

| 形态 | 构建时带什么 | 数据在哪 | 适合 |
|---|---|---|---|
| **纯本地** | 什么都不带 | 手机上（SQLite）/ 浏览器 localStorage | 离线演示、给别人看看样子 |
| **云端（内网/自用）** | 两个地址指向本机或内网 | 服务端 PG | 内部试用、真机联调 |
| **云端（对外发布）** | 两个地址指向云上的域名 | 服务端 PG | **正式发布走这条** |

⚠️ 演示/自用包要显式带 `--dart-define=SEED_DEMO_DATA=true` 才有演示数据；
**对外发布的包不要带**（真实用户不该看到「别人的孩子」，默认关是有意的）。

### 0.3 上线前的四道自检 —— 都是命令，都能失败

发布这件事最容易坏在一处：**配漏了某项，而症状要到线上才出现**。所以下面四条都是
「说出来能跑、跑出来能红」的判据，**发布前逐条跑**：

| 命令 | 查什么 | 在哪跑 |
|---|---|---|
| `node tools/app-identity.mjs --release` | 应用身份 7 处是否一致 + 发布签名是否已配 | 仓库根 |
| `node tools/make-app-icon.mjs --check` | 图标文件名/尺寸/留白是否符合各平台规则 | 仓库根 |
| `node tools/build-mode.mjs site --expect cloud --host <数据服务域名>` | 手上这份 Web 产物**是**不是云模式 | 仓库根 |
| `cd serverless/data-service && node scripts/check-config.mjs --env-file .env.prod --production` | 服务端配置有没有「配错会静默出错」的组合 | data-service |

这四条各自都**可以失败**（改歪一个值就红），所以它们的绿是有信息的。
反面实验与本轮实测见 §4。

> ⚠️ 第三条命令有**两个必须照抄**的参数，漏了它会把一份**正确的云端产物判成「本地模式」**（假红）：
> - **产物目录 `site`** —— 不传时它默认读 `build/web`，那是**另一份**产物（本机上那份是 09-21 指向
>   `127.0.0.1` 的），判的根本不是你要发的东西；
> - **`--host <数据服务域名>`** —— 函数计算给的域名**不带端口**，而它的正向判据是
>   「产物里有没有 `http(s)://主机:端口`」。不带端口的域名它**故意**不当判据（否则会与 dart2js
>   自带的框架域名撞成恒真），只当警告 ⇒ 必须用 `--host` 显式兜底。
>   `tools/build-cloud-web.mjs` 的第 ⑥ 道闸门本来就是这么调的（见该文件第 289 行）。
>
> 实测（2026-09-30）：裸跑 → `✗ 期望 cloud 模式，实际是 local 模式`（EXIT=1）；
> 加上这两个参数 → `模式：云端`（EXIT=0）。**同一份产物、同一个时刻，只有参数不同。**

### 0.4 本文的口径：哪些跑过、哪些没跑过

写清楚了才好判断可信度。**按「没真跑过的验证不说通过」的规矩：**

**跑过（本机，2026-09-22）**

- 客户端全链路：真 PostgreSQL + 真数据服务 + 真网关 + **真浏览器**走查（不是 mock）；
- 身份判据（含 `--release`）、图标判据、配置自检 CLI 的**正反两面**；
- **迁移到全新空库**：全部迁移按序应用、再跑幂等、角色与 RLS 属性正确；
  （当时是 8 个；`009_history_time_indexes.sql` 是 09-23 补的，现为 9 个）
- **release APK 的真实验签**：`apksigner verify --print-certs` 读到我们自己的 keystore，
  `aapt2 dump badging` 读到 `package: name='cn.easylearn.app'`、`application-label:'伴学'`、
  且**自适应图标已进包**（`application-icon-*` 全指向 `res/BW.xml`，它是 `mipmap-anydpi-v26` 那份）。

**没跑过（没有条件，别把它们当成已验证）**

- **真云上的部署**（没有云账号）；
- **真 TLS 连库**（本机没有强制加密的 PG）——`PGSSLMODE` **只验到配置层**（§2.6）；
- **照片对象存储的真凭证验证**（后端代码已实现，见 §2.7）。⚠️ 本地那三层判据只证明了
  「与官方算例逐字节一致」——是**纸上的一致**；桶的 ACL、RAM 权限、区域、内网域名可达性、
  时钟偏差，一个都验不到，而它们失败时给的都是一样的 403；
- iOS 构建与提审（没有 macOS）；
- 应用商店提审本身。

---

## 1 客户端：构建、签名、装机

### 1.1 应用身份：一个语义散落在 7 处

「应用叫什么、它的身份是什么」在真实工程里**必然**散落在七八个文件里，
而**没有任何编译器或构建会把它们串起来**：改五处漏第六处，构建照样成功，
症状是「某个平台上的名字还是旧的」，往往要等到上架被拒、或者用户装不上覆盖包时才发现。

所以这里把它做成**可证伪的判据**：`app-identity.json` 是**声明**，`tools/app-identity.mjs` 逐处核对。

```bash
node tools/app-identity.mjs            # 核对身份一致性
node tools/app-identity.mjs --release  # 额外要求发布签名已配置（上架前跑这条）
```

| # | 位置 | 字段 | 当前值 |
|---|---|---|---|
| 1 | `android/app/build.gradle.kts` | `namespace` / `applicationId` | `cn.easylearn.app` |
| 2 | `android/app/src/main/kotlin/cn/easylearn/app/MainActivity.kt` | 目录结构 + `package` | `cn.easylearn.app` |
| 3 | `android/app/src/main/AndroidManifest.xml` | `android:label` | `伴学` |
| 4 | `ios/Runner.xcodeproj/project.pbxproj` | `PRODUCT_BUNDLE_IDENTIFIER`（6 处） | `cn.easylearn.app`（+ `.RunnerTests`） |
| 5 | `ios/Runner/Info.plist` | `CFBundleDisplayName` / `CFBundleName` | `伴学` |
| 6 | `web/manifest.json` | `name` / `short_name` | `伴学` |
| 7 | `web/index.html` | `<title>` / `apple-mobile-web-app-title` | `伴学` |

判据还会**拒收 Flutter 模板的占位值**（`com.example`、`easy_learn_app`、`A new Flutter project.`）
—— 占位值残留 = 某处没改到。

⚠️ **`applicationId` 上架后不能改。** 它不是一个字符串，是**应用身份**：
改了商店不认、装了旧版的手机装不上升级包（必须卸载，数据一起没）。
所以这件事要在**有真实用户之前**定死。

> 桌面端（`linux` / `macos` / `windows` 目录）**刻意不在判据里** —— 它们是 Flutter 模板残留，
> 不是发布目标。判据会把它打印成一条说明而不是问题，免得有人以为「漏了」。
> 真要出桌面版，先把那三个目录里的名字一起改掉再加进判据。

### 1.2 发布签名：生成一次，备份一辈子

**当前状态：已配置并真验过。** `android/key.properties` + `android/app/release-keystore.p12`
（两者都**不入库**，`.gitignore` 已拦）。

生成（**只需做一次**；已有 `key.properties` 就跳过，别重新生成）：

```bash
cd D:/workbuddy-project/projects/easy_learn_db
keytool -genkeypair -v \
  -keystore android/app/release-keystore.p12 \
  -storetype PKCS12 -keyalg RSA -keysize 2048 -validity 10000 \
  -alias banxue \
  -dname "CN=BanXue, OU=EasyLearn, O=EasyLearn, L=Changsha, ST=Hunan, C=CN"
```

然后写 `android/key.properties`：

```properties
storePassword=<口令>
keyPassword=<口令>
keyAlias=banxue
storeFile=release-keystore.p12
```

⚠️ **`storeFile` 是相对 `android/app/` 的**（Gradle 的 `file()` 在那个模块里求值）。
写绝对路径换台机器就指向别人家去了，而**这种错不会报错，只会签错**。

**行为约定（已实现，可读代码确认）**：`android/app/build.gradle.kts` 里
有 `key.properties` 就用真 release 签名；**没有就回退 debug 签名，但只要这次构建的任务名里带
`Release`，就在日志里大声警告**。回退是为了没配密钥的机器还能 `flutter run --release`，
警告是为了让「打了个假 release 包」**不可能安静发生**。

**怎么算做完了**：`node tools/app-identity.mjs --release` 退出码 0。
它会核对 keystore 文件确实存在（按 `storeFile` 相对 `android/app/` 解析）。

**发布后的验证（直接查真包，不查代码）**：

```bash
BT=/c/dev/android-sdk/build-tools/36.0.0
"$BT/apksigner.bat" verify --print-certs build/app/outputs/flutter-apk/app-release.apk
# 期望：Signer #1 certificate DN: CN=BanXue, OU=EasyLearn, ...
#       （是本项目的 keystore；出现 CN=Android Debug 说明回退到了 debug 签名）

"$BT/aapt2.exe" dump badging build/app/outputs/flutter-apk/app-release.apk | grep -E "^package|application-label"
# 期望：package: name='cn.easylearn.app' versionCode='1' versionName='1.0.0'
#       application-label:'伴学'
```

> ### 🔴 keystore 与口令必须离线备份（这条没有替代方案）
>
> 上架之后，**换了签名商店会拒收更新，丢了签名就再也无法更新那个应用**。
> 备份到密码管理器 / 保险柜，**不要**指望 git（`.gitignore` 刻意拦住了它，
> 而密钥一旦进过历史，删文件是没用的 —— 只能改 key 或重写历史）。
> 要备份的是两样：`release-keystore.p12` 文件 **和** `key.properties` 里的两个口令。

### 1.3 构建产物

**两个服务地址必须在构建时给定**（编译期常量，运行时改不了）：

| 编译期开关 | 填什么 | 不填会怎样 |
|---|---|---|
| `DATA_API_BASE_URL` | 数据服务的公网地址 | 退回**纯本地模式**（数据只在这台设备上） |
| `AI_BASE_URL` | AI 网关的公网地址 | AI 功能走**本地模拟实现**（不报错，只是「好像没用上 AI」） |
| `SEED_DEMO_DATA` | **发布包不要带** | 带了 = 真实用户看到「林小宇 / 王老师」这些别人的孩子 |
| `AI_DISABLED` | 紧急止血用，正常不带 | 置 `true` 后客户端完全不发 AI 请求 |

**本机/内网联调时的两个地址与端口**（`dev-stack` 起的就是这两个）：

| 服务 | 端口 | 常量 |
|---|---|---|
| 数据服务 | **8788** | `DATA_API_BASE_URL` |
| AI 网关 | **8787** | `AI_BASE_URL` |

**两个端口是反直觉的**（数据服务在前、网关在后），抄错的症状是「连到了网关的 8787 上，
报一堆 404」。可在 `dev-stack.mjs` 的 `DATA_PORT` / `AI_PORT` 处核对。

> ⚠️ **`http://` 的地址只在 debug 变体里能用。**
> Android 9（API 28）起系统默认**禁止明文 HTTP**，而且 **`localhost` / `127.0.0.1` 不在豁免之列**
> —— 上面那张表的「云端（内网/自用）」如果指向 `http://192.168.x.x:8788`，
> 不开例外就是**连不上**，而症状**不是**「缺权限」，是「所有请求静静失败 / AI 好像没用上」，
> 极易被误判成服务端没起来。
>
> 本项目的处理：`android/app/src/debug/AndroidManifest.xml` 给 **debug 变体**开了
> `android:usesCleartextTraffic="true"`；`main` 变体**只放开回环地址**（见下一段）——
> 业务流量仍然必须走 HTTPS（明文既是用户数据裸奔，也是商店拒审项）。
>
> ⭐ **2026-10-03：`main` 变体加了一条 `networkSecurityConfig`，只放行
> `127.0.0.1` / `localhost`**（`android/app/src/main/res/xml/network_security_config.xml`，
> 顶部有长注释解释了为什么用它而**不是** `usesCleartextTraffic="true"`）。
>
> 🔴 **但同一天下午的真机反馈证明「加这一条」不够：所有音频仍然报
> `(0)source error`，而照片、视频都正常。真正的修法在客户端，不在清单。**
> 这条 `networkSecurityConfig` 从此**只是兜底 —— 没有任何代码路径依赖它**。
>
> ### 音频必须绕开 `just_audio` 的本地明文代理（2026-10-03 真机定位）
>
> 「照片视频都好、**只有音频**播不出」是一句**机制签名**：照片走 `Image.memory`、
> 视频走 `VideoPlayerController.networkUrl`，两者都不过代理；音频是唯一过的。
>
> `just_audio` 有**两条**路会经它自己的本地 HTTP 代理
> （`http://127.0.0.1:<port>`，再让 ExoPlayer 去请求它）：
>
> | 路 | 触发条件 | 能不能关 |
> |---|---|---|
> | `UriAudioSource`（`setUrl`） | `_useProxyForRequestHeaders` 为真 **且** 带请求头 | ✅ 构造时传 `false` |
> | `StreamAudioSource`（内存字节） | **无条件**（`just_audio.dart:3314`） | ❌ 关不掉 |
>
> 而回环明文在 `targetSdk >= 28` 上被禁（本工程 36）⇒ ExoPlayer 只报一句笼统的
> `(0)source error`，真正的 `CLEARTEXT communication to 127.0.0.1 not permitted`
> 被吞在 cause 里，**看起来像音频文件坏了**。这也是为什么单看错误码会查错方向。
>
> 修法（三轮。**前两轮都在真机上失败过，所以第 3 条才是重点**）：
> ✅ **2026-10-03 真机确认：1+2+3 全部到齐后可以播放。** 单独 1+2 无效 —— 
> 「关掉代理开关」和「优先直读」都不是这条 bug 的解，**「不许放弃 + 把失败原因显示出来」才是**。
>
> 1. `AudioPlayer(useProxyForRequestHeaders: false)` —— 请求头改由 ExoPlayer 直发
>    （与视频那条已跑通的 `networkUrl(httpHeaders:)` 同机制）；
> 2. 音频**与视频一样优先走直读**（`sign-read` 签出的 OSS 地址，`setUrl`）；
> 3. ⚠️ **「优先直读」必须配一条运行期退路。** 只有 1+2 的版本装到真机上，
>    症状**一字不差**：直读签得到、但 `setUrl` 打不开 —— 而字节那条路当时
>    只在「压根没签出直读」时才走 ⇒ **整条链死在那里**，报错还是
>    `(0) source error`。现在 `_AudioBody` / `_VideoBody` 都改成**依次尝试**：
>    直读 → 字节落盘成 `file:` 再 `setFilePath`（`file://` 不过代理）→
>    内存（只有 Web，just_audio 编 data URL）；每次失败**换一个干净的播放器**，
>    失败原因逐条累积并**显示在播放器下面那一行**（`_source`）。
>
> ⚠️ `(0) source error` 可以**逐字解码**：`PlayerException.toString()` 就是
> `($code) $message`（`just_audio.dart:1839`），而 `code` 在安卓上映射的是
> `ExoPlaybackException.type` ⇒ **`0` = `TYPE_SOURCE`**，意思是「**数据源根本没打开**」，
> **不是**解码错误（那会是 `4003`）。所以「音频文件坏了 / 格式不支持」可以直接排除 ——
> 实测把库里的音频字节取回来验过：`ID3` 头、2,816,702 B 与行里记的大小一致。
>
> ⚠️ 反过来，**别指望改 `networkSecurityConfig` 修这条**：`<domain-config>` 里
> 写 IP 字面量能不能放行，社区证据是分裂的（StackOverflow 50962232 的实测是
> 「只有 `<base-config>` 才行」，而 AndroidVideoCache 那批案例又说 `<domain>127.0.0.1</domain>` 有效）。
> **它已经进过包、已经验过在包里，音频照样全哑** —— 客户端绕开代理才是
> 不依赖这个不确定性的修法。
>
> 判据（`flutter analyze` / `flutter test` **都测不到**这条 —— 删掉它一个都不红）：
> 由 `test/attachment_audio_no_local_proxy_test.dart` 的 **6 条**盯住构造与接线形态
> （播放器构造点、不许裸构造、必须有落盘那支、viewer 的直读条件含 `audio`、
> **退路接线 `loadBytes`**、**界面上那行 `_source`**）；真机判据仍是「每条音频能出声」。
> 真机上还有一个**唯一的**信息来源：播放器下面那行小字写的是「直读」还是
> 「本地文件」—— 「视频能播」证明不了直读可用（那个视频只有 1.1 MB，走字节那条也成功）。
> 判据（2026-10-03 实测，带反面）：
> ```bash
> BT=$ANDROID_HOME/build-tools/36.0.0
> "$BT/aapt2" dump xmltree --file AndroidManifest.xml <apk> | grep -i networkSecurityConfig
> "$BT/aapt2" dump resources <apk> | grep -i network_security
> # 新包   → ...:networkSecurityConfig(0x01010527)=@0x7f0e0001
> #          resource 0x7f0e0001 xml/network_security_config
> # 10-01 旧包 → 两条都空（反面）
> ```
> ⚠️ 别用「包里有没有 `network_security_config.xml` 这个路径」当判据：AAPT2 会把 release
> 包的资源路径改名（实测它叫 `res/8G.xml`），两个包都会说「没有」，**判据是瞎的**。
>
> **核对「这次改动的字面量进没进包」用 `tools/apk-contains.mjs`**（Dart 侧改动用它，
> 资源/manifest 改动用上面的 `aapt2`）：
> ```bash
> node tools/apk-contains.mjs build/app/outputs/flutter-apk/app-release.apk --from build/_apk-needles.txt
> ```
> 自带 zip 读取（不依赖 `unzip`）、**UTF-8 与 UTF-16LE 两种编码都试**
> （Dart AOT 里中文是 UTF-16LE、ASCII 才是 UTF-8）、**自动补一条随机反面对照**。
> ⚠️ 别在命令行直接传 `/data/...` 或中文：**Git Bash 会改写参数**（`/data/…` 变成
> `C:/Users/…/PortableGit/…/data/…`），判据会静默变瞎 —— 一律用 `--from <文件>`。
> ⚠️ **命名参数**（如 `useProxyForRequestHeaders`）在 AOT 里被消除，搜不到是**假阴性**；
> 要核的东西请挑**函数名**或**字面量**。
>
> 两侧核对方式（2026-09-22 实测）：
> ```bash
> BT=$ANDROID_HOME/build-tools/36.0.0
> "$BT/aapt2" dump xmltree --file AndroidManifest.xml \
>   build/app/outputs/flutter-apk/app-debug.apk   | grep -i cleartext
> # → android:usesCleartextTraffic(0x010104ec)=true
> "$BT/aapt2" dump xmltree --file AndroidManifest.xml \
>   build/app/outputs/flutter-apk/app-release.apk | grep -i cleartext
> # → 空
> ```

**APK（自用 / 内部分发）**

推荐直接用脚本（地址从 `.env.prod` 的 `CLIENT_*_BASE_URL` 读，不手抄）：

```bash
node tools/build-cloud-apk.mjs
```

它做三件事再构建：① 拒绝把 `127.0.0.1` / 内网地址烧进包；② 构建前探活两个
`/health`；③ 子进程管道自检（见下面「构建时的机器状态」）。

手工构建等价于：

```bash
flutter build apk --release --no-tree-shake-icons \
  --dart-define=DATA_API_BASE_URL=https://<数据服务域名> \
  --dart-define=AI_BASE_URL=https://<网关域名>
# 产物：build/app/outputs/flutter-apk/app-release.apk（约 57 MB，含 arm64 / armv7 / x86_64）
```

⚠️ **构建时的机器状态会伪装成「Flutter 坏了」**：若 Flutter 一启动就报
`CreateFile failed 231 (所有的管道范例都在使用中)`，那不是项目的问题 ——
但也**不是「重启机器」**。下面这段说明本身曾经把人带进歧路，2026-10-03 重写。

**受控实验（每个 stdio 形态各 20 次，完整记录见 `doc/open-items.md` 的 B15）**：

| 起点 | 结果 |
|---|---|
| `stdio: 'ignore'`（不用管道） | **20/20 成功** |
| `stdio: 'inherit'`（不用管道） | **20/20 成功** |
| `stdio: 'pipe' ×3` | **0/20，全部 `EBUSY`** |
| 自建命名管道（`CreateNamedPipeW`） | **5/5 成功** |
| 匿名管道 —— bash 的 `$( )`、**Python 的 `subprocess`** | **正常** |

⇒ 进程创建没问题、管道**创建**也没问题，坏的只有「**带命名管道起子进程**」这一件事。
**「实例被某进程挤枯竭 → 重启」那条旧结论已被证伪**：自建管道能成，且当时机器上
并没有 ACE / 反作弊类程序，231 照样 100% 复现。它的状态会在**数百秒到数小时**的
尺度上自己翻转，**触发条件没测到** —— 所以「`ignore` / `inherit` 能过、`pipe` 过不去」
这一对就足够定位，**别再花时间去找那个「占句柄的元凶」**。

✅ **处置 = 在 WorkBuddy（工作台）之外的普通终端里构建。** 双击
`tools/build-apk-outside-workbuddy.cmd`：它先打管道探针（不过就不往下走）、再构建、
最后打印产物指纹。工作台里起的子进程一律挂在 `sandbox-cli.exe` 下面，
所以在工作台内怎么调都绕不开（`dangerouslyDisableSandbox` 只解策略限制、不解这一层）。

**验证产物连的是哪份库**（构建期定的，运行时看不出来）：

```bash
node tools/build-mode.mjs --expect cloud --host <你的域名>
# ⚠️ 必须带 --host：默认判据只认「带端口」的地址，
#    而函数计算的域名没有端口，只靠默认判据会**误判成本地模式**。
```

**AAB（上架 Google Play 用；国内商店多数收 APK）**

```bash
flutter build appbundle --release --no-tree-shake-icons \
  --dart-define=DATA_API_BASE_URL=https://<数据服务域名> \
  --dart-define=AI_BASE_URL=https://<网关域名>
# 产物：build/app/outputs/bundle/release/app-release.aab
```

**为什么 `--no-tree-shake-icons` 不能省**：项目里有动态构造的 `IconData`，
tree-shaking 会把它判成「没用到」删掉，症状是**部分图标变成方框**。

**版本号**：在 `pubspec.yaml` 的 `version:`（当前 `1.0.0+1`）。
`+` 前面是 `versionName`（用户看到的），后面是 `versionCode`（商店用它判新旧）。
**每次上架 versionCode 必须比上一版大**，否则商店拒收。

### 1.4 图标

由 `tools/make-app-icon.mjs` 生成（纯 Node + 内置 `zlib`，**不依赖 ImageMagick / PIL / 联网**）：

```bash
node tools/make-app-icon.mjs          # 重新生成全部
node tools/make-app-icon.mjs --check  # 只核对文件在不在、尺寸对不对
```

它一次写 17 个文件，因为**各平台的规则不同、漏一个的症状是安静的**：

| 目标 | 文件 | 规则（不是偏好） |
|---|---|---|
| Android 传统图标 | `mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png` | 48 / 72 / 96 / 144 / 192 |
| Android 自适应图标前景 | `mipmap-*/ic_launcher_foreground.png` | 108dp 画布，**内容只占中间 44%**（安全区 66%） |
| Android 自适应图标背景 | `values/colors.xml` + `mipmap-anydpi-v26/ic_launcher.xml` | 纯色（带渐变的图做视差会露边） |
| Web / PWA | `web/icons/Icon-{192,512}.png`、`Icon-maskable-{192,512}.png` | maskable 也必须留白 |
| 浏览器标签页 | `web/favicon.png` | 32×32 |

改配色只改脚本顶部的常量后重跑。换成美术稿时，无论走 `flutter_launcher_icons`
还是自己写缩放，**都要 `--check` 通过**。

> 换图标后想确认它真的进了包：`aapt2 dump badging` 里 `application-icon-*`
> 指向的那个 `res/XX.xml` 就是自适应图标；`aapt2 dump xmltree --file <那个 xml>` 能看到
> 它引用的背景色与前景图。**只看代码是看不出「有没有真进包」的。**

### 1.5 装到手机上验收

三条安装路径（USB / 手机浏览器 / 传文件）与「未知来源」按应用授权的操作步骤见
`android-deploy-guide.md` §1.2–1.3，**那部分仍然有效**。这里只补一条**实测有效的绕法**，
以及装完必须验的五条：

**`adb install` 用不了时，别去修驱动。** `adb devices` 打印出 `List of devices attached`
后面**什么都没有、退出码还是 0、也不报错** —— 这不是「线没插好」，是**手机的 USB 调试没开**。
在系统里确认比在 adb 里确认可靠：**没有 `ADB Interface` 设备节点**就是没开；有些机型
（实测华为 `VID_12D1`）的 MTP 节点还会带 `ProblemCode=28`（驱动未安装），连「当 U 盘拷文件」都不通。

这时用局域网把包发给手机更快（也绕开了驱动/开发者选项）：

```
一个只读 build/ 目录、只放行 .apk、绑 0.0.0.0 的小静态服务，
并打印每个请求的 req.socket.remoteAddress
```

手机浏览器打开 `http://<电脑局域网IP>:8090/` → 下载 → 允许「安装未知应用」。

> **顺带白拿一个证据**：能下载成功，就说明「手机 → 电脑」这条 TCP 通了，
> 在装应用之前先把网络这关验掉了（本机拿自己的局域网 IP 探自己走的是回环，**自证不了**）。
> 服务端多数不记客户端 IP，所以**自己打印 `remoteAddress`** 往往是唯一的一手证据。
> 跑它的 node 要用**你已经在跑的那个可执行文件** —— 防火墙入站规则按 **exe 路径**匹配，
> 换一个又会弹一次授权框（或被拒）。

**装完必须验的五条：**

1. 打开应用 → 看到登录页（不是白屏、不是闪退）；
2. 用真实账号（**不要用演示账号**）登录 → 进学生首页；
3. 进「复习」→ 能看到错题；进「积分」→ 有账本记录 → **说明服务端链路通了**
   （本地模式也会有数据，所以这一条要配合第 5 条一起看）；
4. 拍照识别一条作业 → 结果里是**真识别出来的内容**（不是本地模拟的固定结果）；
5. **跨设备验证**：换一台设备（或另一个浏览器）用家长账号登录 → **看得到孩子刚提交的作业和照片**。
   这是最容易「假装成立」的一条 —— 它同时验了服务端存储、RLS 可见性与照片字节是否真的在服务端。

**照片这条还有一条不依赖界面、不依赖客户端的真链路判据**（栈在跑时）：

```bash
cd serverless/data-service
npm run probe:photo-e2e      # 7 条，全过才退出码 0
npm run probe:image-access   # 反面 3 条：不存在 id → 404 / 别人的照片 → 404 / 不带票 → 401
npm run probe:media-e2e      # 音视频直传：打**云端**，自带临时账号（跑完照脚本末尾的提示清）
```

⚠️ `probe:media-e2e` 与上面两条不同：它默认打 `.env.prod` 里的**线上**地址，
因为音视频走的是**预签名直传**（字节不经过函数），那条链路只有在真 OSS 上才有意义。
它验的是「签名 → 直传 → **读回逐字节一致** → 写行」四段；
`PUT 回 2xx` **不算**判据 —— OSS 不会帮你检查字节有没有落盘，读回才算。

它复现真机上那条路径（上传字节 → 写行 → **按服务端返回的 id** 读回字节），
并带一个**必不能少的对照**：按上传时那个 `img_…` 占位 id 读 **必须 404**
—— 没有这个对照，「按服务端 id 读得到」也不能说明 id 有意义。
`probe:image-access` 再补上可见性反面（少一半，判据会退化成「随便谁都读得到」也能过）。

> ⚠️ 这两条只证明**服务端**这一侧自洽。界面上那张缩略图还多一层：客户端必须把写行时
> 返回的 id **真的采纳进内存**（`saveHomeworkImage` 的返回类型是
> `Future<List<HomeworkImageModel>>`，不是 `void`）。那一层由
> `test/photo_visible_after_submit_test.dart` 钉住。两层都要在。

### 1.6 Web 版发布

```bash
flutter build web --release --no-tree-shake-icons \
  --dart-define=DATA_API_BASE_URL=https://<数据服务域名> \
  --dart-define=AI_BASE_URL=https://<网关域名>
# 产物：build/web/  —— 整个目录丢给静态托管即可
```

**Web 版有两个云端独有的注意点**：

1. **跨域（CORS）**。原生 App 不发 `Origin` 头，不受影响；**Web 版必须由服务端放行**。
   - AI 网关：自己会回 `Access-Control-Allow-Origin: *`（`ai-gateway/src/router.js`），开箱可用；
   - **数据服务：只有本机外壳 `dev-server.js` 加 CORS 头**，云函数入口**不加**
     （来源该由网关统一决定，不该由业务代码各自决定）。
     漏了它的症状是「手机上好好的，浏览器里所有请求被浏览器拦下、**后端日志里一条都没有**」。

   ⚠️ **2026-09-26 真浏览器实测：光「配允许来源」是不够的，卡点在预检的状态码。**

   当时云上**看着已经配好了** —— `curl -X OPTIONS` 拿得到一整套头
   （`Access-Control-Allow-Origin` 按请求回显、`Allow-Credentials: true`、
   `Allow-Methods`、`Allow-Headers`、`Max-Age: 3600`）。但**状态码是 `405`**，
   而浏览器要求预检响应必须是 **2xx** ⇒ 判定失败 ⇒ **实际请求根本不发**。

   这是 FC 的 **Default CORS** 行为：它只处理**简单请求**（回显那几个头），
   带自定义头的请求要先过预检，而预检会被**转发给函数**。本项目每个业务请求
   都带 `accept` + `authorization`，写请求还带 `content-type: application/json`，
   **都不在 CORS 简单请求白名单里** ⇒ Web 版**每一个**请求（**含登录本身**）
   都要过预检，于是全线不通。

   两半必须都在（缺一半就是这次的形态）：
   - `s.yaml` 的 trigger `methods` 里要有 `OPTIONS` —— **本来就配了**；
   - **函数代码里要真的接住它**（`serverless/data-service/src/app.js` 开头的
     OPTIONS 短路，回 `204`）。函数**只终止预检、不回 CORS 头** —— 头仍由平台给，
     自己再给一份会变成**重复的** `Allow-Origin`，那是浏览器直接报错的形态。

   ⚠️ **别按响应头判断配好没有** —— 这次的教训就是「头全在、状态码是 405」。
   判据要**从真浏览器里发请求**（`curl` 看不到浏览器内部的预检判定，Node 的
   `fetch` 压根不做 CORS 检查）：

   ```bash
   node tools/cors-probe.mjs        # 域名从 .env.prod 读；退出码 0 = 浏览器能访问
   ```

   ⚠️ 判据是「**拿得到状态码**」而不是「状态码是 200」：`/auth/login` 用假账号
   本来就该回 401 —— 那恰恰证明请求到达了服务端。`Failed to fetch` 才是被拦下。

2. **换域名 = 换一个空库**。浏览器 localStorage 按「协议 + 主机 + 端口」隔离，
   `https://a.example.cn` 与 `https://b.example.cn` 是两个完全不同的库。
   站点域名定下来再发布，别中途换。
3. **静态托管还没有落点**。`build/web/` 是个纯静态目录，云上目前**没有**
   托管它的资源（`s.yaml` 只有两个 `fc3` 函数；OSS 桶存的是作业照片，不是站点）。
   要发 Web 版得先定：放 OSS 静态网站 / CDN / 别的托管 —— 这是**产品决策**，不是配置。

### 1.7 提审前还缺什么（诚实清单）

- **应用商店素材**：截图（各尺寸）、宣传图、应用简介、**隐私政策 URL**（收集手机号与照片，必须有）；
- **iOS**：`ios/Runner/Assets.xcassets` 里的图标仍是 Flutter 模板图，且没有 macOS 就构建不了；
- **应用备案 / 软著**（国内商店的常规要求，与代码无关）。

---

## 2 云端部署

> **用阿里云？** 看 `doc/aliyun-deploy-plan.md`（RDS PostgreSQL + 百炼）。
> 那一份把「平台无关」（迁移脚本、两个函数、环境变量名、验收命令 —— 照抄就行）
> 和「平台相关」（照片存储后端、函数形态、跨域配置）分开列了。
> **模型厂商已经是一个开关**：`AI_MODEL_PROVIDER=ark|bailian`（不配 = 方舟，零行为变化）。
> 开关扛掉了那些「照抄会静默出错」的协议差异 —— 思维链字段名/取值、
> 以及 `tool_choice` 在思维链开着时不能传对象（百炼会 400）。
> **2026-09-30 晚**：两家的配置改成**并存两组**（`ARK_*` / `BAILIAN_*`），
> **切换 = 改这一个变量 + 重新部署**；模型名、思维链名单、单价都跟着厂商走
> （这三样分错了都不会报错）。详见 `aliyun-deploy-plan.md` §3.3
> 与 `serverless/ai-gateway/README.md` 的「换模型厂商」。

### 2.0 一条命令看全貌（先跑这个）

```bash
node serverless/deploy-prepare.mjs            # 自检 + 打印逐步命令 + 环境变量清单
node serverless/deploy-prepare.mjs --zip      # 顺手打出两个待上传的 zip
node serverless/deploy-prepare.mjs --env-file serverless/data-service/.env.prod
```

它**不登录云账号、不上传、不碰生产库** —— 只把「能离线验证的部分」全部验一遍，
并把下面 §2.1–§2.9 的步骤浓缩成一份可照抄的清单。凡它报 `!` 的行都是真问题
（例如「网关目录里有 `.env.local`，绝不能打进上传包」）。

打包会顺手做两件断言：**包体积**（`--exclude` 写错会打出 0 KB 的包，而平台照样部署成功、
直到线上第一个请求才 500）和**包里没有 `.env.*`**（空包会「通过」泄漏检查，所以先断言条目数）。

> ⚠️ 打包用 `tar` 时必须传**相对**输出路径（配 `cwd`）：GNU tar 把 `host:path` 当远端规格，
> `D:\x.zip` 里的 `D:` 会被当成主机名 → `Cannot connect to D: resolve failed`、退出码 2。
> 同理 `--exclude=.*` 会把归档顶层条目 `./` 自己吃掉（打出空包），要用 `--exclude=./.*`。（2026-09-23 两条都踩过）

### 2.0.1 配置的唯一定义处（`s.yaml`）

一键上传走 `s.yaml`（Serverless Devs）。**平台实际拿到的配置是两半加起来的**：

| 一半 | 唯一定义处 | 内容 | 进版本库吗 |
|---|---|---|---|
| **固定值** | `s.yaml` 的 `environmentVariables` | `NODE_ENV=production`、池大小、驱动名、配额…… | ✅ 进（没有密钥） |
| **注入值** | `.env.prod`（照 `.env.prod.example` 抄） | 主机、口令、密钥、Key…… | ❌ 不进（`.gitignore` 拦着） |

`s.yaml` 里对密钥只写**引用** `${env('X')}`，值由 shell 注入。这让「需要什么」和
「值是什么」变成了**分开的两份**，所以必须对账 —— 漏一边的症状都是安静的：

- `s.yaml` 引用了 X 而 `.env.prod` 没写 X → 平台拿到**空串**。函数照样启动、
  `/health` 照样 200，只在**第一个用到它的请求**上以奇怪的样子失败。
- `.env.prod` 写了 Y 而 `s.yaml` 没引用 Y → 你明明配了，值**根本没上传**。
  这个更难查：控制台上也看不到 Y，因为没人问过平台要它。

```bash
node serverless/scripts/deploy-check.mjs --env-file .env.prod
```

它做四件事：**①** 逐个核对 `s.yaml` 的引用在当前环境里有没有值；**②** 反过来找「配了却没被引用」的孤儿；
**③** 确认 `code:` 指向的暂存目录已生成；**④** 把这份**合并后**的配置喂给两个服务各自的
`validateConfig`（不复写规则 —— 抄一份就多一处会漂的副本，而漂的方向是把拦截悄悄放松）。
退出码 0 = 可以上传。

**`# @optional` 标记**：`s.yaml` 里某行引用后面跟 `# @optional`，表示**留空是一种合法选择**
（如 `OSS_PREFIX`、`AI_PRICE_*`、`AI_MODEL_VISION`）。没有标记 = 必填。
这个标记是「怎么判」的唯一定义处 —— **不要**在 `deploy-check.mjs` 里另抄一份名单：
抄了之后 `s.yaml` 新增变量而名单没跟上时，新变量会永远被判成「可空」，而它恰恰最可能被漏配。

> ⚠️ **只标 `@optional` 是不够的 —— 引用本身必须带回落值：`${env('X', '')}`。**
> `s` CLI 把「值为空」和「变量不存在」看成**同一件事**，两种都直接抛
> `RuntimeError: env('X') not found`，**整个部署失败**（不是「函数里少个变量」那么轻）。
> 2026-09-24 实测踩到：8 个标了 `@optional` 的引用**全都没有回落值** ——
> `deploy-check` 说「允许留空」，`s` 却拒绝部署，报错只指向第一个变量，
> 修完一个再撞下一个（连撞 8 次）。两条一起看才算「对」：
> **引用带回落值** + **行尾标 `@optional`**。少前者，`deploy-check` 现在直接判致命。

一键上传的完整顺序：

```bash
npm i -g @serverless-devs/s
s config add                                       # 填阿里云 AK/SK，别名用 default
node serverless/deploy-prepare.mjs                 # 先构造暂存目录（s.yaml 的 code 指向它）
node serverless/scripts/deploy-check.mjs --env-file .env.prod
node serverless/scripts/run-s.mjs deploy           # 一把上传两个函数
```

> ⚠️ **最后一步别手写成 `set -a && . ./.env.prod && set +a && s deploy`。**
> 那样会漏掉「清代理」，而在带本地代理的机器上（本机就是：`http_proxy=http://127.0.0.1:<port>`，
> 这个变量是环境自带的，不是谁配的）`s` 拉取 component 时会把**完整的 https URL 当成路径**
> 发给那个代理，只拿回一句 `Request failed with status code 400`。
> 而 `s` **不打印响应体** —— `--debug` 不打，`~/.s/logs/*/error.json` 里也只有那一句。
> 报错里没有任何线索指向代理。
>
> 症状组合很有辨识度，记住它就不用再查第二遍：
> **任何子命令都 400（连只读的 `s info` 也一样）· 2 秒内失败 · `~/.s/components/` 是空的**
> —— 「没有任何请求真的发到业务 API 上」。
>
> `run-s.mjs` 做四件事：载入 `.env.prod` · **清掉代理变量** · 确认暂存目录在 · 打印它做了什么。
> 真出问题时加 `--sniff`（注入 `net-sniff.cjs`，把状态码 ≥400 的**响应体**打到 stderr）。

> ⚠️ **最后那行的 `source` 有个陷阱**：只要 `.env.prod` 里有**任何一行不符合 shell 语法**
> （最常见的就是还没填完的 `<占位符>`），bash 会**当场报语法错、并且不再执行它后面的行** ——
> 结果是环境变量只灌进去一半，而 `s deploy` 照常跑，拿到若干个空值。
> 函数能起来、健康检查照样 200，问题被留到第一个用到那个变量的请求上。
> 判据很土但有效：`set -a; . ./.env.prod; set +a` 之后
> `echo ${#AI_SESSION_SECRET}` 必须是一个**非零**的数字。
>
> 这是「一份文件、三个解析器」的老问题：本项目的解析器忽略 `#` 开头的整行注释，
> 而 shell 会把**值里**的 `#` 当成注释开始 —— 所以 `.env.prod` 里不要写行尾注释。

> ⚠️ **`s.yaml` 的 `code:` 指向 `build/deploy/<服务>-code/`，不是 `serverless/<服务>/`。**
> 两个服务都 `import '../../shared/xxx.js'`，而**包的根 = `code` 指向的那个目录** ——
> 直接传服务目录会让那两级落在包外，函数**起不来**（`Cannot find module .../shared/token.js`）。
> 暂存目录是为这件事存在的：它把 `index.cjs` 放在根、把 `shared/` 放在根、服务自身放进子目录，
> 正好让原来的相对路径对齐。**这个错误本地永远复现不出来** —— 本地跑的时候
> `serverless/shared` 就躺在服务目录旁边。
> 所以顺序是「先 prepare（建暂存目录）→ 再 deploy」，反过来会传一个不存在的目录。


### 2.1 云数据库（PostgreSQL）

**选型**：托管 PostgreSQL（本项目在火山引擎上验证配套最顺，RDS for PostgreSQL）。
**区域：和函数同一个区域（华东 1 杭州 —— 2026-09-24 实测确认）** —— 跨区往返的延迟会在一次批改里**逐次叠加**。
⚠️ **方舟不在同一个区域，也不需要**：它是火山引擎的服务、数据面在北京，`ARK_REGION` 是它自己的东西
—— 别为了「统一地域」把它也改掉（改了签名就挂）。判定依据见 `doc/aliyun-deploy-plan.md` §2。

**要记下的五个连接参数**：主机、端口、库名、管理员账号、管理员口令。

⚠️ **库名按你建的填，别照抄代码里的默认值。** `src/db.js` 与 `migrate.mjs` 的默认是
`easy_learn`，那是**本机**的；实测那台云 RDS 上叫 `easylearn_db`。
填错的报错很清楚（`database "easy_learn" does not exist`），但如果你以为默认值就是对的，
会去怀疑别的地方。

**版本**：本机 **PG 17**、云上实测那台 **PG 18.4** —— 两边都跑通了全部迁移
（2026-09-24 实测，不是推断）。迁移只用标准 SQL。要选更低的版本，
仍建议先在预发库上跑 `migrate.mjs --dry-run` 再真跑。

**网络**：迁移要能从你的机器连上（把出口 IP 加白名单，或在跳板机上跑），
数据服务要能从函数所在网络连上 —— **已定：给数据服务配 `vpcConfig` 走 VPC 内网**，
白名单放行**交换机网段 CIDR**（一个固定值）。⚠️ 别指望放行 FC 的出口 IP：它是**动态**的。
三个 ID 从哪抄、以及三条不明显的官方口径（**别用安全组授权** / **安全组出方向要放行 ICMP** /
交换机要在 FC 支持的可用区）见 `doc/aliyun-deploy-plan.md` §5.2 第 1 条。
⚠️ 只有**需要连库的那个函数**要配 VPC；AI 网关刻意不配（不碰库，且配了会拖慢冷启动）。

⚠️ **`PGSSLMODE` 这条被实测推翻过一次，别照旧记载走。** 旧记载是
「实测那台**默认不接受 SSL** —— 带 ssl 选项时服务端回 `N`，所以只能填 `disable`」。
2026-09-24 傍晚的三条独立判据把它推翻：`pg_stat_ssl` 报 `ssl=true` / `TLSv1.3` /
`TLS_AES_256_GCM_SHA384`、`show ssl` = `on`、19 条连接里 8 条走在 SSL 上。
所以现在填 **`require`** —— 判据是「实测能用」，不是「安全更重要」；
而且 `disable` 时口令是**明文**过的，跑迁移那条路走的正是公网。
⚠️ 换新实例仍要**先问一句**（`probe-db-access.mjs` 会直接告诉你这行该填什么）；
那个方向的失败是**吵的**（`The server does not support SSL connections`），不会静默降级。
（`require` 的语义是**不校验证书链** —— 云厂商自签 CA 的常见形态；要做到「验证书」得挂 CA 文件，
本服务没实现，且**不会**被悄悄当成 `require` 放过：真校验会明确报
`unable to get local issuer certificate`。）
改完记得**重跑一次迁移**验证：`migrate.mjs` 读的是同一个 `PGSSLMODE`（与函数同一套规则），
不会出现「配置里写着加密、迁移走明文」这种分裂。

⚠️ **连接数**：实测那台 `max_connections = 420`。套公式
`FC 实例上限 × (PG_POOL_MAX + PG_AUTH_POOL_MAX) < 420`（默认 5 + 3 = 8/实例）
→ 实例上限**别超过 50**。
换算错误的表现是**高峰期大面积超时**（看着像接口变慢，其实是连不上库）。

> ⚠️ 生产库**不要**用管理员账号跑应用。下面 §2.2 会建两个专用角色，
> 应用只用它们连库 —— 拿超级用户当应用账号，**整套 RLS 会静默失效**（不报错、照常返回全部行）。

### 2.2 建角色与建表（顺序：先角色、后表）

**这是上线第一步，也是以前缺的一环**（原先 `runMigrations` 只被本机路径调用过，
也就是说**没有任何办法把表结构建到云库上**）。现在有了：

```bash
cd serverless/data-service

# ① 先看会做什么（只读，不写）
node scripts/migrate.mjs --env-file .env.prod --dry-run

# ② 真执行（生产必须显式 --yes）
node scripts/migrate.mjs --env-file .env.prod --yes
```

`.env.prod` 里至少要有（**别提交，`.gitignore` 的 `.env.*` 已拦**）：

```ini
# ⚠️ 只用最保守的子集：KEY=VALUE，不加引号、不写行尾注释、值里别带 #。
# 这份文件有**三个消费者**，而三者语法并不完全一致：
#   · migrate.mjs / provision-app-roles.mjs / check-config.mjs（本项目的解析器）
#   · Serverless Devs（读 .env）
#   · 你手滑 `source` 它（shell）
# 「键值对」是三者都认的公共子集。
PGHOST=<RDS 的**内网**地址>      # 函数侧用它；配了 vpcConfig 才走得通（见 §2.4 的 FC_VPC_*）
PGPORT=5432
PGDATABASE=<你建的库名>
#   ⚠️ 代码里的默认值是 easy_learn，那只是**本机**的默认。云上按实际库名填
#      （实测那台叫 easylearn_db）。填错的报错很清楚（database "..." does not exist），
#      但如果你以为默认值就是对的，会去怀疑别的地方。
# ⚠️ RDS 的**内网地址与外网地址是两个不同的域名**（实例 ID 尾部只差两个字符 ——
#    别当成复制时截断了）。这个键**不上云**，只给「在 VPC 外跑」的本机脚本
#    （迁移 / 建角色 / 各探针）用；否则那些脚本会解析到私网 IP 而连不上，
#    现象是「库挂了 / 白名单没放行」，方向完全错：
PGHOST_EXTERNAL=<RDS 的**外网**地址>
PG_OPS_USER=<管理员账号>
PG_OPS_PASSWORD=<管理员口令>
PGUSER=app_rls
PGPASSWORD=<强口令>
PG_AUTH_USER=app_auth
PG_AUTH_PASSWORD=<另一个强口令>
NODE_ENV=production
```

**它做什么 / 不做什么**：做 —— 按文件名顺序执行 `sql/*.sql`，用 `schema_migrations` 记账；
不做 —— 不建库本身、不改业务数据、**不动任何已应用的迁移**。
所以它**幂等**：重复跑只输出「没有待应用的迁移」。

**两个必须知道的点**：

1. **它用的刻意是管理连接**（`PG_OPS_USER`），不是应用角色 —— `002_rls.sql` /
   `003_session.sql` 会建 `app_auth`（`BYPASSRLS`），而 `BYPASSRLS` 只有超级用户才授得出来。
   ⚠️ 为什么单独用一个变量名而不是 `PGUSER`：同一个名字上挂着**两个互斥的值**
   （迁移要管理员、函数上必须是 `app_rls`），而 `loadEnv` 是**文件优先**（shell 里临时覆盖无效）。
   分开命名还顺带保证**管理员凭证不上云**：`s.yaml` 不引用 `PG_OPS_*`。
2. **顺序是「先建角色、后迁移」**，原因见下一段。

#### 先建角色、再迁移（顺序不能颠倒）

`db/migrations/002_rls.sql` 与 `003_session.sql` 里那句 `CREATE ROLE ... PASSWORD` 的
口令由迁移器在事务内 `set_config` 注入，**SQL 里没有任何可用口令**；没注入、角色也不存在时
迁移会显式报错，不会兜底。两处都被 `DO $$ IF NOT EXISTS (...) $$` 包着 →
**角色已存在时整句跳过**。于是：

- **先跑 `provision-app-roles.mjs`**：角色带着**你的强口令**建出来，迁移里那句直接跳过 ——
  这是生产唯一允许的顺序；
- 反过来直接跑迁移：要么报错（没注入口令），要么用的是本机开发栈随机生成的口令，
  **绝不能带到云端库**。

```bash
cd serverless/data-service

# ① 先把两个应用角色建出来（用 .env.prod 里那两个强口令）
node scripts/provision-app-roles.mjs --env-file .env.prod --yes

# ② 看迁移会做什么（只读，不写）
node scripts/migrate.mjs --env-file .env.prod --dry-run

# ③ 真执行（生产必须显式 --yes）
node scripts/migrate.mjs --env-file .env.prod --yes
```

`provision-app-roles.mjs` 会**拒绝四类口令**（每一类都对应一个真实踩过的坏结果）：
空 · **等于源码里那两串开发口令** · 短于 24 字符 · 两个角色用同一个（或与管理员相同）。
它**只改口令、不重复定义角色属性** —— 属性（`app_rls` 无 BYPASSRLS、`app_auth` 有、
都没有 CREATEDB/CREATEROLE）的唯一定义处是那两个 sql 文件。

跑完它做**正反两侧验证**：新口令能连上 → **开发口令连不上**。
后面那条不只是礼貌：它顺带证明**口令认证真的在生效** ——
若 `pg_hba` 是 `trust`，任何口令都能连，这条会红，而那是一个必须知道的事实。

**怎么算做完了**（2026-09-24 在一台真的 RDS 上全程跑过，不是照文档推的）：
`sql/` 里的迁移全部按序应用 → `schema_migrations` 记录条数 = 迁移文件数（实测 10 → 10）→
**再跑一次输出「没有待应用的迁移」** → `public` 下 26 张表 →
**25 张启用 RLS、且 25 张都是 `FORCE`**（第 26 张是 `schema_migrations`，它不需要）→
两个角色都建立（`app_auth.rolbypassrls=true`、`app_rls.rolbypassrls=false`，**且都不是超级用户**）。

#### 行为判据：别用「迁移成功」推断「隔离生效」

这是两件事。**隔离的唯一判据是「不同身份分别能看到几行」**，做法很直接：

1. 用管理员（`PG_OPS_USER`，带 BYPASSRLS）插几行探针数据，两个不同 `student_id` 各一行，
   **再故意插一行 `student_id = ''`**；
2. 用 `app_rls` 连库，逐个试：不设 `app.visible_students` / 空串 / `'stu_a'` / `'stu_b'` /
   `'stu_a,stu_b'` / 一个不存在的学生 / `',,'`；
3. 期望分别是 `0 / 0 / 1 / 1 / 2 / 0 / 0` 行；
4. **反向对照**：管理员必须看到全部 —— 否则上面那些 0 行只是「表里没数据」，
   判据没有区分力；
5. 写路径也要试一次：以 A 的身份插一行 B 的数据，必须被拒
   （`42501 new row violates row-level security policy`）。

> **第 2 步里那个 `',,'` 不是凑数的。** 2026-09-24 实测发现：
> `string_to_array('', ',')` 返回的是**空数组**（安全），但 `string_to_array(',,', ',')`
> 返回 `{'','',''}` —— **含空串元素**，会匹配 `student_id = ''` 的行。
> 而那些行的归属列在 15 张业务表上是 `TEXT NOT NULL DEFAULT ''`，
> 所以「某处漏传 student_id」+「某次下发的集合含空元素」这条链会让无主数据对所有人可见。
> 两个条件都罕见，且**都不报错**。→ 已由 `010_rls_empty_collection_safe.sql` 修掉：
> 它把「解析 csv 会话变量」收进一个函数 `app_csv_setting()`（带 `array_remove(..., '')`），
> 并**就地重建**了库里那 21 个用到它的 policy。
>
> ⚠️ 那条迁移用的是「**从 `pg_policies` 读当前表达式再替换**」，而不是手抄表名清单 ——
> 因为 policy 的最终形状分散在 002 / 003 / 004 / 005 / 008 五个文件里
> （004 把 `app_user` 的 `own_rows` 拆成读写两条、008 又给 `user_read` 加了 EXISTS 子查询）。
> 第一版手抄的写法**漏掉了 005 的 `notification_insert`**，而漏掉不会报错，
> 只会留下一条比别处宽的 policy。

### 2.3 部署数据服务

要上传的是 `serverless/data-service/` 整个目录（含 `sql/`）。

| 配置 | 填什么 | 为什么 |
|---|---|---|
| 类型 | **事件函数**（HTTP 触发） | 服务形状是「事件 → 响应」，不是常驻 Web 服务 |
| 运行时 | **Node.js 20+** | `package.json` 的 `engines` 就是 `>=20` |
| 入口 | **`index.cjs` 的 `handler`** | 源码是 ESM；有些平台只认 CJS，那里有个五行垫片 |
| 区域 | **和数据库同区（华东 1 杭州）** | 见 §2.1。⚠️ 别写成「与方舟同区」—— 方舟的 `ARK_REGION` 是它自己的 |
| 超时 | **60s** | 照片上传（最大 8MB）与冷启动建连都要时间；平台默认 3s 会大面积超时 |
| CPU / 内存 | **0.5 vCPU / 1024MB** | ⚠️ FC3 要求 `cpu : 内存(GB)` 落在 **1:1 ~ 1:4** 之间。256MB(0.25GB) 配 0.5 核 = 2:1，**创建时直接报 `InvalidArgument`** —— 而那行报错看不出是内存配小了。1GB 也不是随便挑的：照片要 base64 编解码，8MB 原图解码后还要再留一份给图片处理，512MB 以下容易 OOM（表现为函数被强杀、无响应）|
| 请求体上限 | 部署后**实测**一遍（见下） | 照片是原图上传（本服务的上限是 8MB，见 `IMAGE_MAX_BYTES`）。超了会得到**平台自己发的 413** —— 那个 413 不是本服务的，排查时会找错地方 |
| 触发器路径 | 直连 FC3 HTTP 触发器**不用配**（见下） | 路由表是**精确整串匹配**，但 FC3 会把完整路径透传给函数 |

⚠️ **触发器路径是这一节最容易踩的坑 —— 但要分两种情形，别混。**

`handler.js` 会抹掉网关前缀，但抹的方式是「**从路径里找出 `/data/` 或 `/auth/` 那一段，
从那里截断**」（这样 `/prod/data/bootstrap` → `/data/bootstrap`）。

- **直接挂 FC3 的 HTTP 触发器（`s.yaml` 的做法）：不用配路径。**
  FC3 把完整路径透传给函数（事件里的 `requestContext.http.path` 就是 `/data/bootstrap`），
  截断逻辑正常工作。这也是为什么 `s.yaml` 的触发器里**没有**路径配置这一项。
- **前面再挂 API Gateway / 自定义域名、并且做了路径重写：必须保住完整前缀。**
  一旦事件里的 `path` 只剩 `/bootstrap`，截断就无从谈起，
  结果是**线上每个请求都 404** —— 而那个响应体就是本服务的标准错误信封，
  **看起来完全正常**，很容易被误判成「这次部署漏了这段代码」。

**部署后立刻验**：`curl https://<域名>/health` 必须返回 200（这条路径被特殊处理，
任何前缀都能命中）。再去 `curl -X POST https://<域名>/auth/login -H 'content-type: application/json' -d '{"phone":"...","password":"..."}'`。

**请求体上限怎么实测**（FC3 的函数配置里没有这一项，不是可调参数）：

```bash
# 发一张接近上限的原图（约 8MB）。期望：收到**本服务**的响应
# （成功，或本服务自己判的超限错误）。若收到平台发的 413，就是平台那层的限制先到 ——
# 那时要把客户端的 IMAGE_MAX_BYTES 往下调，否则学生拍的原图会成片失败。
curl -i -X POST https://<数据服务域名>/data/homework/images \
  -H "authorization: Bearer <票>" -H 'content-type: application/json' \
  --data-binary @<(node -e "console.log(JSON.stringify({images:[{data:'x'.repeat(11*1024*1024)}]}))")
```


### 2.4 数据服务的环境变量（全）

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `NODE_ENV` | ✅ **`production`** | 空 | 决定下面那些拦截是否生效。**大小写与两侧空格都容忍** |
| `PGHOST` / `PGPORT` / `PGDATABASE` | ✅ | `127.0.0.1` / `5432` / `easy_learn` | 数据库地址。⚠️ 云上 `PGHOST` 必须是 RDS 的**内网地址** —— 内网/外网是**两个不同的域名**（实例 ID 尾部差两个字符），填成外网地址时函数会从 FC 的**共享出口**连库（源 IP 会变），**配了 VPC 也等于白配**，而且不报错。上传前看 `deploy-check.mjs` 的 ⑥ 节，部署后看 `doc/aliyun-deploy-plan.md` §7.1 |
| `PGHOST_EXTERNAL` | 否（**只给本机脚本**） | 空 | RDS 的**外网地址**，给「在 VPC 外跑」的迁移/探针用，**不上云**（`s.yaml` 刻意不引用它）。取址统一走 `scripts/lib/env-file.mjs` 的 `cloudHost()` |
| `PGUSER` / `PGPASSWORD` | ✅ | `app_rls` / 空 | **应用角色**（不是管理员） |
| `PG_AUTH_USER` / `PG_AUTH_PASSWORD` | ✅ | `app_auth` / 空 | 鉴权角色，只碰三张账号表 |
| `AI_SESSION_SECRET` | ✅ | 空 | ≥32 字符，**与 AI 网关必须是同一把**（§2.5） |
| `AI_GATEWAY_BASE_URL` | 打卡必填 | 空 | 数据服务调 AI 网关的基址。云上是网关函数的**公网 URL**（两个服务是两个函数）。为空时只有 `/data/checkin/generate` 回 `model_not_enabled`，其余路由照常，启动日志有一条警告。⚠️ **不许给它写 `127.0.0.1` 当兜底** —— 云上那就是「打卡永远出不了题」，而日志看起来一切正常 |
| `AI_GATEWAY_TIMEOUT_MS` | 否 | 30000 | 数据服务 → 网关的单次超时。客户端那份是 **45 秒**，必须比它久：服务端可能**已经把题存好了**而客户端先报超时，用户点重试又生成一份覆盖掉 |
| `IMA_CREDENTIAL_SECRET` | 用 ima 才要 | 空 | ima OpenAPI 密钥的**加密口令**（AES-256-GCM，密钥由 `SHA-256(secret)` 派生）。为空时家长点「连接」回 `server_config_missing`，其余功能零影响（ima 本来就是 opt-in）。⚠️ 轮换后**旧密文解不开**，家长需要重新连接一次 |
| `PGSSLMODE` | 视情况 | 空（不加密） | `disable` / `require` 二选一，见 §2.6。⚠️ 本项目云上那台实测**支持 SSL**，所以填 `require`（填 `disable` 时口令**明文**过公网）；换新实例先用探针问一句 |
| `FC_VPC_ID` / `FC_VSWITCH_ID` / `FC_SECURITY_GROUP_ID` | 走 VPC 时必填 | 空 | **函数走 VPC 内网连库**的三个 ID（由 `s.yaml` 的 `vpcConfig` 引用）。不配的话函数只能从公网连库，而 FC 的公网出口 IP 是**动态**的 → 白名单追不上。⚠️ 只有**需要连库的函数**要配（数据服务配了，AI 网关刻意没配）。⚠️ RDS 白名单要用 **IP 段**方式授权（**别用安全组**，否则会「偶尔连不上」），并把**交换机网段 CIDR** 加进去；安全组**出方向**要放行 5432 与 **ICMP**（FC 用它探连通性）。见 `doc/aliyun-deploy-plan.md` §5.2。✅ 2026-09-24 实测：**光配这三个 ID 不够** —— 配完 `app_auth` 仍从**公网**连库（VPC 白配），直到把 `PGHOST` 换成内网地址后才变成 `172.21.26.148`（私有）。两者**必须同时**做对 |
| `IMAGE_DRIVER` | 否 | `fs` | 照片存哪：`fs`（本地/共享盘）或 `oss`（对象存储）。**写错直接起不来**，不会静默退回 `fs`（退回 = 照片写进函数实例本地盘 →「上传成功但过一会儿图没了」）。见 §2.7 |
| `IMAGE_ROOT_DIR` | `fs` 时必填 | 空 | `fs` 后端的根目录。为空时照片功能如实回 `upload_not_configured`（**503，不是 500**） |
| `IMAGE_MAX_BYTES` | 否 | 8MB | 单张照片上限 |
| `IMAGE_QUOTA_PER_STUDENT` | 否 | 3000 | 每个学生的照片**张数**上限。达到上限时写照片回 `storage_quota_exceeded`（**409**、`retryable:false`）—— 必须与「网络抖一下」区分开，否则客户端只会说「保存失败」，而学生要做的其实是删旧照片。**配错（0 / 负数 / 非数字）直接起不来**：静默变成「没有上限」的代价是账单，不是报错。⚠️ 3000 张按实拍 1–3MB 估约 **3–9GB/学生**（约 4–13 元/年），这是**真的在计费**的量 |
| `IMAGE_QUOTA_WARN_REMAINING` | 否 | 20 | 剩余不足多少张时，提交成功后给学生一句「快满了」提示（`photoUsage.nearLimit`）。**写 0 = 不提前提示** —— 与上面那条不同，`0` 在这里只有一个读法，所以是合法值。**配错（负数 / 非数字）直接起不来**。⚠️ 刻意不用百分比：3000 的 10% 等于提前两个月开始喊，而这类提示只在「这几天内要做点什么」时才有用 |
| `OSS_BUCKET` | `oss` 时必填 | 空 | 桶名。**桶必须私有** —— 键里含 `studentId`，公共读等于猜到一个 uuid 就能看别人家孩子的照片 |
| `OSS_REGION` | `oss` 时必填 | 空 | 如 `cn-hangzhou`。**参与签名**，必须与桶所在区域一致；填错报 `SignatureDoesNotMatch`（看着像密钥错了）。⚠️ 还须与 `OSS_ENDPOINT` 里的区域**互相一致** —— 两处不同区同样报 403，同样看不出原因 |
| `OSS_ACCESS_KEY_ID` / `OSS_ACCESS_KEY_SECRET` | `oss` 时必填 | 空 | **RAM 子账号**，只授予该桶 `PutObject`/`GetObject`；别用主账号 AK |
| `OSS_ENDPOINT` | 否 | 空 | 留空按区域推外网域名。与桶同区域时填 `oss-<region>-internal.aliyuncs.com` 走内网（省流量费）|
| `OSS_PREFIX` | 否 | 空 | 多套环境共用一个桶时用它隔离。⚠️ 只在存储层生效，**写进库的键不带前缀** → 改它会让老照片失联 |
| `CORS_ALLOW_ORIGIN` | Web 版必填 | 空（只放本机来源） | **写具体来源，不要 `*`**：`/auth/login` 是公开端点，通配等于给每个网页一个免费的口令爆破入口 |
| `PG_POOL_MAX` / `PG_AUTH_POOL_MAX` | 建议显式 | 5 / 3 | 见 §2.8 |
| `PG_CONNECT_RETRY_BUDGET_MS` / `PG_CONNECT_RETRY_MAX` | 否 | 5000 / 8 | 冷启动建连重试 |

**⚠️ 「配额」在仓库里不止一处 —— 但改生产只需要一处**

仓库里提到这个数的地方有十几处。它们**不是重复的配置**，而是五种不同角色：

| 角色 | 例子 | 改「生产配额」要动吗 |
|---|---|---|
| **定义** | `src/image-store-factory.js` 的 `DEFAULT_QUOTA_PER_STUDENT` | **不用** —— 生产靠环境变量，默认值只是「没配时」的兜底 |
| **引用** | `handler.js` / `app.js` / `dev-server.js` 读 env、往下传 | 不用 —— 它们**不写数字**，只传 |
| **部署产物** | `deploy-prepare.mjs` 里那份 `NAME=值` 清单 | 要 —— 云上那份默认值就来自它 |
| **断言** | `test/photo-quota.test.js` 的 `EXPECTED_DEFAULT_QUOTA` | 要，**且必须手抄** |
| **注释 / 文档** | 各处的「默认 3000」 | 要 —— 人读的，不会自己同步 |

断言那一行**不许 `import` 常量**：若写成 `expect(quota).toBe(DEFAULT_QUOTA_PER_STUDENT)`，
把常量改成 1，那条测试照样绿。断言一旦从被测代码里取值，它就从**判据**变成了**回音**。

所以「改的时候怕漏」这件事有工具兜着 —— 改之前跑一条命令：

```bash
npm run quota:where          # 列出全部位置，按「要动 / 不用动」分组
```

它还会检查「写了『默认 N』的地方，N 是否等于代码里的真值」，不一致就 `exit 1`，
因此它也挂在 `npm test` 里（`--quiet` 模式，一致时只打一行）。

这条检查的存在理由是一起**已经发生过**的事故：配额从 10000 下调到 3000 时，
`scripts/run-tests.mjs` 的注释漏改了，而**没有任何测试因此变红** ——
因为当时没有任何判据读注释。判据本身也被证伪过两轮：先发现它**漏扫**了
「只写数字、不写配置名」的注释（正是最容易漂的一类），收紧范围后又发现它
把 `AI_QUOTA_UNITS_PER_DAY`（默认 200 单位）和分页 `limit`（默认 50、上限 200）
误判成漂移 —— 一个会误报的检查，最后一定会被人关掉。

**启动时会发生什么（两类自检，失败都是看得见的）**：

1. **配置自检**（不连库，`config-check.js`）：生产缺 `AI_SESSION_SECRET`、
   用的是仓库里公开的**开发栈密钥**、生产没 `PGPASSWORD` → **直接抛错，进程起不来**。
   宁可起不来，也不要裸奔 —— 这几项的共同点是「配错之后行为看起来完全正常」。
2. **冷启动自检**（连库之后，每次都跑一次、热实例复用不重跑）：
   RLS 到底生效没有、鉴权角色有没有被多授权、照片存储能不能写。
   前两道不通过就不服务（它们失效时不会有任何症状，只会在某天变成一次数据泄露）；
   第三道只进日志（它是功能，不该把其余 40 多条路由一起拖死）。

### 2.5 两个服务共用的那把密钥

`AI_SESSION_SECRET` 是**数据服务签发、网关校验**的会话签名密钥，所以：

- **两边必须是同一个值**。不一致的症状极其误导：登录**成功**，但每个业务读都判「未配置」，
  客户端表现为「登录成功，但进去一片空」—— 排查的人会先怀疑数据没同步、再怀疑 RLS，
  最后才想到密钥（因为「登录都成功了，密钥怎么可能有问题」）。
- **≥ 32 字符**（HMAC 的强度等于密钥的熵）；
- **绝不能是** `dev-stack-secret-not-for-production`（它写在仓库里，任何人拿它都能自己签一张有效的票，
  而且**票据校验全过、不留痕**）。生产环境两个服务都会在启动时把这条拦下来。
- 生成：`node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"`

### 2.6 连数据库要不要加密（`PGSSLMODE`）

云上的托管 PG 常常**只接受 TLS 连接**，这时配：

```ini
PGSSLMODE=require
```

⚠️ 但**先确认你的实例真的开了 SSL** —— `node scripts/probe-db-access.mjs
--env-file .env.prod` 会直接把「SSL 支不支持」和「这一行该填什么」一起打出来。
**探针的输出优先于本文的任何结论**（本文就被它纠正过一次：旧记载说那台「没开 SSL，
服务端回 `N`」，而探针一直在报「SSL 可用 → 可以填 `require`」——
是**记载没跟上探针**。2026-09-24 傍晚用三条独立判据确认了探针是对的）。

- `disable` → 不加密。**口令是明文过的**，所以只在「确实连不上、且确认是内网」时用；
- `require` → 加密，**不校验证书链**（= libpq `require` 的语义，云厂商自签 CA 的常见形态）；
- `allow` / `prefer` / `verify-ca` / `verify-full` → **直接抛错**（不是回落到 require）。

最后一条是刻意的：`prefer` 的语义是「加密失败就退回明文」，而悄悄退回明文是最不希望发生的事；
`verify-*` 要挂 CA 证书文件，本服务没实现。**把它当成 `require` 悄悄放过，会得到一个
「配置里写着要校验、实际一次都没校验」的状态**，从外部完全看不出来。

> ✅ **「真 TLS 握手能不能成」现在验过了（2026-09-24 傍晚）** —— 早先这段写的是
> 「本机没有强制加密的 PG，所以没验过」。现在有真库可测了，结论是**能成**：
> 用 `require` 的语义（`db.js:78` → `{ rejectUnauthorized: false }`）连上真实例，
> 服务端确认 `pg_stat_ssl.ssl = true`、`version = TLSv1.3`、
> `cipher = TLS_AES_256_GCM_SHA384`；`show ssl` = `on`；全库 19 条连接里 8 条走在 SSL 上。
> 反面也在同一个实验里（**反面判据不能省**）：改成**校验**证书链（`ssl: true`）
> 会明确失败 —— `unable to get local issuer certificate`，
> 也就是「不校验证书链」这件事是**看得出来的**，不是被悄悄放过。

### 2.7 照片存在哪 —— 后端可选，别让 `fs` 跑在函数计算上

作业照片有**两条独立的路径**，别混：

| 路径 | 走哪 | 云上状态 |
|---|---|---|
| **给模型看的** | 客户端 → 网关（TOS 直传预签名 / proxy） → 方舟 | 代码已在（`ai-gateway/src/tos.js`），配 `AI_UPLOAD_SIGNER=tos` + TOS 凭证即可；**外链模式受环境限制没跑过**（见 `open-items.md` §B2） |
| **给家长看的** | 客户端 → 数据服务 `/data/homework/images/upload` → **照片存储后端** → 家长端读 | **两条后端都已实现**（见下） |

**后端由 `IMAGE_DRIVER` 选**，默认 `fs`，所以既有部署行为完全不变：

| 值 | 实现 | 适用 | 配置项 |
|---|---|---|---|
| `fs`（默认） | `data-service/src/imagestore.js` | 本机开发；ECS + 挂载云盘/NAS | `IMAGE_ROOT_DIR` |
| `oss` | `data-service/src/ossimagestore.js` | **函数计算**（那边没有持久磁盘，这是唯一正确的选择） | `OSS_BUCKET` / `OSS_REGION` / `OSS_ACCESS_KEY_ID` / `OSS_ACCESS_KEY_SECRET`，可选 `OSS_ENDPOINT` / `OSS_PREFIX` |

⚠️ **函数计算上必须用 `oss`**：实例回收后 `fs` 写的文件就没了，多实例之间也不共享 ——
症状是「上传成功，过一会儿图没了」或「换台设备就看不到」。生产跑 `fs` 时启动自检会**警告但不拦**
（刻意如此：ECS 挂盘是正当部署，一律拦下等于让一种正确做法起不来）。

⚠️ `IMAGE_DRIVER` **写错会直接起不来**，不会静默退回 `fs` —— 那会把照片写进一个
你以为不是那里的地方。

换后端时**别丢**的几条（都踩过或差点踩）：

- **键的格式单点定义**：`YYYYMMDD/<studentId>/<uuid><ext>` 由 `buildStorageKey` 一处产出，
  两条后端共用。两处各写一份的话，切后端等于让老照片**全部失联** ——
  而失联的表现是「照片位置一片空白」，没有一处会报错。
- **读图的 404 分三种**，别合成一个：`not_on_server`（旧版设备本地标识 → 客户端回退本地读）、
  `file_missing`（真被清理了）、`storage_backend_error`（桶名/区域/凭证配错）。
  ⚠️ 后两种在 OSS 侧**都是 404**（`NoSuchKey` vs `NoSuchBucket`），只看状态码会把
  「环境变量填错」读成「照片被清理了」，于是所有人去查清理策略。
- **OSS 必须用 V4 签名**（V1 自 2025-03 对新用户、2025-09 对新桶已不可用）。
  本仓是零依赖自写（`ossimagestore.js`），判据在 `test/oss-imagestore.test.js`：
  对齐官方文档算例的规范请求哈希，以及「用文档的 SigningKey 能签出文档的 Signature」。
- ⚠️ 但**签名对不对最终只有 OSS 说了算**。上线前用真凭证打一次：

  ```bash
  cd serverless/data-service
  node --env-file=.env.oss scripts/probe-oss.mjs
  ```

  它验的是「配好了」这件事 —— 桶 ACL、RAM 权限、区域、内网域名可达性、时钟偏差，
  这些本地一个都测不出来，而失败时给的都是长得一样的 403。

生产建议：用**只授予该桶 `PutObject`/`GetObject` 的 RAM 子账号**，不要用主账号 AccessKey。

### 2.8 Serverless 的连接数坑

函数的实例数会弹性伸缩，**每个实例都有自己的连接池** →
`实例数 × (PG_POOL_MAX + PG_AUTH_POOL_MAX)` 会一起打向数据库。
默认值下是 **8 连接/实例**，50 个实例 = 400 连接，很容易打爆数据库的连接上限，
症状是**高峰期大面积超时**（看着像接口变慢，其实是连不上库）。

对策按优先级：

1. **在数据库前面放连接池代理**（PgBouncer / RDS 自带的代理），应用侧把 `PG_POOL_MAX` 降到 2–3；
2. **给函数设并发上限**（同时存在的实例数上限）；
3. 记一条算式放进值班手册：`实例上限 × (PG_POOL_MAX + PG_AUTH_POOL_MAX) < 数据库 max_connections`。

### 2.9 部署后的验收

```bash
# ① 活着（这条路径被特殊处理，任何前缀都能命中）
curl -i https://<数据服务域名>/health

# ② 账号端点通（公开端点，不需要票）
curl -i -X POST https://<数据服务域名>/auth/login \
  -H 'content-type: application/json' \
  -d '{"phone":"<真实测试账号>","password":"<口令>"}'
# 期望 200 且返回 token；401 说明账号不在这个库里（**注意别拿本地模式的账号来试**）

# ③ 受保护端点：不带票必须 401（**这条是反面判据，不能省**）
curl -i https://<数据服务域名>/data/bootstrap
# 期望 401。返回 200 说明鉴权链断了 —— 而「永远 200」从正面看和正常一模一样

# ④ 配置自检（部署完把线上那套环境变量抄成文件，本地跑一遍）
node scripts/check-config.mjs --env-file .env.prod --production

# ⑤ **新加的路由到底上没上去** —— 这一条是 2026-10-03 事故之后补的
#    判据不是「deploy 命令退 0」，而是这条路从 **404 变成 401**：
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  https://<数据服务域名>/data/homework/images/sign-upload \
  -H 'content-type: application/json' -d '{}'
# 期望 401（路由在，只是没票）。**404 = 这版代码根本没上去**。

# 反面（不能省）：随便一个不存在的路径也必须 404 ——
# 否则上面那个 401 说明不了任何事（可能什么路径都先过鉴权）
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  https://<数据服务域名>/data/__no_such_route__ \
  -H 'content-type: application/json' -d '{}'

# ⑥ 附件**读回**那两条路（2026-10-03 修 B32 之后新加的一条）
#    小附件走函数（GET …/images/file）、大附件走直读（GET …/images/sign-read）。
#    两条都要在，且**不带票都必须 401**：
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://<数据服务域名>/data/homework/images/sign-read?id=x"
# 期望 401（路由在，只是没票）。404 = 这版代码根本没上去。
```

> ⚠️ **「传得上去」不等于「取得回来」—— 部署完必须量一次读回。**
> 上传侧走预签名直传（函数不搬字节），但**读回侧有平台硬限制**：
> 函数计算的响应体上限是 **32 MiB**，而视频上限 50 MB。
> 超过 32 MiB 的附件只能走 `sign-read` 直读（客户端对视频已经这么做了）。
> 判据（真凭证，会传 50MB 上去、跑完自己删）：
> ```bash
> node serverless/data-service/scripts/probe-readback-ceiling.mjs --bytes 52428800 --mime video/mp4
> ```
> 看 **⑦ 直读**那几条（含 `Range` → 206，那是「能拖动进度」的判据），
> 13/13 才算过；⚠️ ⑥ 函数读回那几条**在超过 32 MiB 时一定是红的**，
> 那是预期、是修法的依据，**别去「修」它**。

> ⚠️ **2026-10-03 的真实事故**：客户端加了 `sign-upload` 这条路由、`analyze` 0 error、
> `test` 745/747 全绿、APK 也打出来了，用户装上一点「上传视频」却报「未知端点」——
> 因为**服务端没重新部署**，线上还是 10-01 那份代码。
> 部署类命令的「成功」只说明它自己跑完了；**新端点在上线前，必须先被请求过一次**，
> 并看到它从 404 变成 401/400（不是 200：200 才需要解释）。
> 同类：`s deploy` 回显成功但传的是旧暂存树 ⇒ 先跑 `node serverless/deploy-prepare.mjs`。

---

## 3 AI 大模型配置

### 3.1 方舟侧：开通清单

1. **注册 + 实名认证**（火山引擎）。**不做实名开不了任何模型**，会一直卡在「开通失败」。
2. 开通 **火山方舟**（按量后付费，无需预充值）、**函数服务 veFaaS**、**API 网关**。
   首次使用函数服务要完成「跨服务授权」；子账号还要主账号授 `VeFaaSFullAccess`、
   `APIGFullAccess`、`STSAssumeRoleAccess`。
3. **创建 API Key**：控制台 → API Key 管理 → 创建 → **立即复制**。
   刷新页面后**再也看不到明文**。
4. **逐个开通模型**：模型广场 → 找到目标 → 「立即开通」。
   ⚠️ **不是「拿了 Key 就能调所有模型」**。
5. 接入地址：`https://ark.cn-beijing.volces.com/api/v3`（网关默认值，一般不用改）。

> **「模型不存在」有两种，处置动作相反**，日志里长得一样（都是 404）：
>
> | 现象 | 真实含义 | 该做什么 |
> |---|---|---|
> | `404 ModelNotOpen` | 平台有这个模型，**你的账号没开通** | 去控制台开通 |
> | `404 InvalidEndpointOrModel.NotFound` | 目录里挂着但**已经调不动** | 换个新型号，别去开通它 |
>
> 判据是**实际调一次**，不是翻目录：`node scripts/probe-ark-catalog.mjs --dry` 先只看目录，
> 去掉 `--dry` 逐个实调、直接给出可粘贴的 `ARK_MODEL_*` 行，一个都没开通时退出码 1。

### 3.2 三个档位分别填什么

| 环境变量 | 谁在用 | 选型要求 |
|---|---|---|
| `ARK_MODEL_VISION` | 作业拍照识别、手写批改 | **必须真多模态**（要能读图） |
| `ARK_MODEL_REASONING` | 错题判定、讲解生成、出题、批量参考答案 | 强推理 |
| `ARK_MODEL_LIGHT` | —— **当前没有任何业务端点用它** | 没有就留空 |

**两条硬规矩**：

1. **留空 = 该能力未开通。** 网关会如实回 `model_not_enabled`，
   客户端探到 `capabilities.vision = false` 后**根本不发图**，直接走本地识别。
   这是**正确行为，不是故障**。
2. **没有的档位就留空，绝对不要拿同一个模型名填满。** 把纯文本模型填进视觉档
   **不会报错** —— 它只会**编一份批改结果**，而那份结果会进错题库、被组卷、
   被打印出来让孩子重做。

> ⚠️ 同族模型往往只有某一个 ID 开通（实测：`deepseek-v4-pro-ga-260813` 开通，
> `deepseek-v4-pro-260425` 是 `ModelNotOpen`）。**填错 ID 不会报错**，
> 只会回 `model_not_enabled`，所以**别凭记忆写**，用 `probe-ark-catalog.mjs` 的输出。

### 3.3 部署网关与环境变量

上传 `serverless/ai-gateway/` 整个目录，**不需要 `npm install`**
（依赖为空，只用 Node 内置模块 + 全局 `fetch`，所以冷启动快）。

| 配置 | 填什么 | 为什么 |
|---|---|---|
| 入口 | `index.cjs` 的 `handler` | 同数据服务 |
| 运行时 | Node.js 20+ | 用了全局 `fetch` |
| 区域 | **华东 1 杭州** | 与数据库同区（见 §2.1）。⚠️ **不是「与方舟同区」** —— 方舟在火山引擎，与本地域无关 |
| 超时 | **≥ 60s** | 模型调用本身 10–30s，默认超时会在模型返回前掐断 |
| CPU / 内存 | **0.25 vCPU / 512MB** | 纯网络等待（等模型返回），CPU 用不满。⚠️ 但**别只填 `memorySize`**：FC3 要求 `cpu : 内存(GB)` 落在 1:1~1:4，256MB 只在 cpu ≤ 0.25 时才合法，随手配 0.5 核就成 2:1 → `InvalidArgument` |
| 触发器 | 直连 FC3 HTTP 触发器即可（`s.yaml` 就是这么配的） | 服务自己会抹掉 `/ai/` 之前的前缀，所以**只要事件里的 path 还含 `/ai/` 就行**。⚠️ 前面再挂 API 网关并做了路径重写时，**必须保住 `/ai/` 这一段**（见 §2.3 那段） |

**生产环境必须设的环境变量**（完整清单与每一项的取舍见
`serverless/ai-gateway/README.md` §环境变量）：

```ini
NODE_ENV=production                       # 决定下面那些拦截是否生效
ARK_API_KEY=<Key>
ARK_REGION=cn-beijing
ARK_MODEL_VISION=<视觉档 ep-xxx 或模型 ID>   # 没有就留空
ARK_MODEL_REASONING=<强推理档>
ARK_MODEL_LIGHT=                          # 没有就留空

AI_REQUIRE_AUTH=true                      # 生产必须 true（见下）
AI_SESSION_SECRET=<与数据服务同一把，≥32 字符>

AI_KV_DRIVER=http                         # 共享 KV（见下）
AI_KV_URL=<KV 地址>
AI_KV_TOKEN=<KV 口令>

AI_METRICS_TOKEN=<看板口令>                # 公网部署必须配

# 思维链开关（见 §3.4，按实测值）
# ⚠️ 视觉路由也在里面：实测 homeworkOcr / homeworkCheck 不产生思维链 token，
#    关掉是**零代价换回 tool_choice 硬约束** —— 而批量识别恰恰最需要硬约束。
#    reviewJudge **刻意不在**：它只花 8 个思考 token，而准确率决定错题是否毕业。
AI_THINKING_DISABLED_KINDS=homeworkOcr,homeworkCheck,reviewExplain,reviewPractice,reviewReferenceBatch

# 单价：要么三级全填、要么全空。全空 = 看板如实显示「成本未知」（不是 0）
# ⚠️ 格式是**纯数字**（单位「元 / 千 token」），**别带货币符号**：`¥0.008` 会被读成
#    NaN → 于是被当成「没配」→ 看板说「未配置模型单价」，而配置里明明填了、重填也不会好。
#    启动自检会拦下这种（刻意做成响亮的失败，不做静默降级）。
# AI_PRICE_VISION_IN / _OUT / AI_PRICE_REASONING_IN / _OUT / AI_PRICE_LIGHT_IN / _OUT
```

**四条「配错会静默出错、所以被做成启动即拦」的**（生产档）：

| 拦截项 | 不拦会怎样 |
|---|---|
| `AI_REQUIRE_AUTH` 不是 `true` | `studentId` 由请求头 `X-Student-Id` 声明，**可被任意伪造** → 配额与审计失去意义。接口表现与「鉴权正常工作」**完全一样** |
| `AI_MODEL_CLIENT=mock` | 识别/批改/讲解返回的全是**写死的假数据**，界面完全正常、日志也没有异常 |
| `AI_KV_DRIVER` 不是 `http`（且没写 `AI_ALLOW_EPHEMERAL_KV=true`） | 配额计数落在每个实例各自的内存里，多实例下**额度成倍放大**，只有账单看得出来 |
| `AI_SESSION_SECRET` = 仓库里那把开发密钥 | 任何人拿它都能签一张有效的票，并以此花你的模型额度 |

还有三条不分环境的：老变量名（`AI_RATE_PER_STUDENT_PER_DAY` 等，**语义变过、不能沿用旧值**）、
每日额度小于最大权重（那档一次都跑不了，却表现为一切正常的 429）、
**单价只配了一部分**（缺的被算成 0，看板报出一个偏小但看起来完整的数字 —— 这是最坏的一种）。

### 3.4 思维链开关（有实测依据，不是玄学）

`AI_THINKING_DISABLED_KINDS` 是**关掉部分路由的思维链**。默认空（不关），
因为 `thinking` 是方舟特有字段，网关也可以指向本机 Ollama / vLLM，那些服务收到不认识的字段可能直接 400。

**用方舟就该打开它**，依据是 2026-09-20 的真凭证实测：

- 讲解（`reviewExplain`）在推理型模型下 **2/4 用例超客户端 12s 窗口，最坏 41.6s**；
  超窗口的后果不是报错 —— 客户端会**安静地退回本地模板**，
  从外部看就是「讲解功能好像没用上 AI」；
- 关掉后同一批题目 **6.6–8.4s，4/4 落进窗口且全部通过 schema 校验**；
  学生看到的分步过程还在（那是输出 schema 要求的），被去掉的是模型给自己看的草稿。

**判定（`reviewJudge`）不建议关**：它本来只花 21–84 个思维链 token，关掉省不下时间，
而它的准确率直接决定错题是否毕业。

### 3.5 验收：三步，每一步都能红

```bash
cd serverless/ai-gateway

# ① 配置活着（只反映「有没有 Key、模型 ID 填没填」，**不反映方舟那边是否真开通**）
curl https://<网关域名>/ai/health
# 看 capabilities（三级能力是否 true）与 quota

# ② 用真凭证探活 —— 退出码 0 才算通过
ARK_API_KEY=<Key> ARK_MODEL_VISION=<视觉档> ARK_MODEL_REASONING=<强推理档> \
  node scripts/probe-ark.mjs
# 它做两件本地怎么测都测不出来的事：确认模型**确实已开通**；
# 核对 usage 的字段名（网关成本链路只认 usage.prompt_tokens / completion_tokens，
# 换了名字看板不会报错，只会把 token 安静地记成 0、让成本退化成「下限」）

# ③ 量一遍「跑得完吗」—— probe 只证明接得上，证明不了在客户端窗口内跑完
E2E_VARIANT=1 node scripts/e2e-local-homework.mjs
# ⚠️ 复跑要换 E2E_VARIANT：网关按 payload 缓存 10 分钟，
#    同一个 payload 的第二次调用是几毫秒的缓存命中 —— 那是一次什么都没测的验收
```

最后是**真机端到端**：装上新构建的 APK → 拍照识别一条作业 → 结果里是**真识别出来的内容**。
也可以看网关 stdout 的审计行：

```bash
grep '"path":"/ai/homework/ocr"' gateway.log | tail -3
```

- `"ok":true` 且 `latencyMs` 几百毫秒以上 → **模型真的跑了**，问题在识别质量；
- `"ok":false` 且 `latencyMs:0`、`model:null` → **请求根本没到模型**，是入口校验拦下的，看 `code`。

### 3.6 成本与配额

- **配额按「成本权重」记，不按次数**：视觉一次 8 单位、强推理 2、轻量 1；
  每日上限 `AI_QUOTA_UNITS_PER_DAY` 默认 200 单位。
  按次数记账会同时错在两个方向（文字解析用光额度，而拍照批改还剩着却已超支）。
- **两个窗口各管一件事**：分钟窗口防脚本猛打（超限 `rate_limited`，可重试）；
  天窗口防超支（超限 `quota_exhausted`，**不可重试** —— 让客户端立刻回落本地并如实告知）。
- **成本看板口径是「单实例」**（响应里带 `scopeNote`）。这是**刻意的**：
  KV 只有 `get/set/incr`、没有键列举，多实例的计数合并不出正确总数。
  宁可如实标明口径，也不报一个「看起来是全局、其实是某个实例」的数字。
  要全局口径就把审计事件接到日志/指标服务。
- **单价留空 = 看板显示「成本未知」**，这是预期结果不是缺功能。
  设计文档写明「以控制台实际定价为准」，写死一份很快过期的价格会让看板报出一个错的数字。

---

## 4 上线前 Checklist（每条都有判据）

**A. 客户端**

- [ ] `node tools/app-identity.mjs --release` → 退出码 0
- [ ] `node tools/make-app-icon.mjs --check` → 退出码 0
- [ ] `pubspec.yaml` 的 `version` 已递增（`+` 后的 `versionCode` **必须比上一版大**）
- [ ] 构建命令**没有**带 `SEED_DEMO_DATA=true`
- [ ] 两个 `--dart-define` 地址指向**生产域名**（不是 `127.0.0.1`、不是内网 IP）
- [ ] `apksigner verify --print-certs` → DN 是本项目的 keystore（**不是 `Android Debug`**）
- [ ] `aapt2 dump badging` → `package: name='cn.easylearn.app'`、`application-label:'伴学'`
- [ ] **keystore 与两个口令已离线备份**（🔴 没有替代方案）
- [ ] `node tools/build-mode.mjs --expect cloud`（Web 版）
- [ ] 商店素材与**隐私政策 URL** 准备好

**B. 服务端**

- [ ] 数据库已建、`migrate.mjs --yes` 跑过且**第二次输出「没有待应用的迁移」**
- [ ] **白名单分两段都放行了**：① 跑迁移那台机器的出口 IP ② **交换机网段 CIDR**（给函数的）
      —— ⚠️ 不是「放行 FC 的出口 IP」，那个是动态的，追不上
- [ ] `FC_VPC_ID` / `FC_VSWITCH_ID` / `FC_SECURITY_GROUP_ID` 已填，且 `deploy-check` 里这三项是 ✓
- [ ] **VPC 真的通了**（配了 ≠ 通了）：`/auth/login` 用真账号回 **200**，
      且 `pg_stat_activity` 里出现 `172.21.26.x` 来源的连接（§2.9 / `aliyun-deploy-plan.md` §7.1）
- [ ] `ALTER ROLE app_rls / app_auth WITH PASSWORD ...` **已执行**（迁移建的是开发口令）
- [ ] 平台环境变量按 §2.4 配齐，`NODE_ENV=production`
- [ ] `AI_SESSION_SECRET` 与网关**是同一把**、≥32 字符、不是开发栈那把
- [ ] 函数入口 `index.cjs`、超时 60s / 120s、**cpu : 内存 = 1:2**（0.5/1024 与 0.25/512，
      ⚠️ 不是「内存 256MB」—— 那样配 0.5 核会 `InvalidArgument`）
- [ ] 走 `s.yaml` 的话：`deploy-check.mjs --env-file .env.prod` **退出码 0**（§2.0.1）
- [ ] **请求体上限实测过**：接近 8MB 的原图能到达本服务（收到 413 且不像本服务的信封 = 平台那层先拦了）
- [ ] `curl https://<域名>/health` → 200
- [ ] `curl https://<域名>/data/bootstrap`（不带票）→ **401**
- [ ] 冷启动日志里出现「冷启动自检通过（应用角色=…，鉴权角色=…）」与照片存储那一行
- [ ] **照片存储配齐并探活过**：`IMAGE_DRIVER=oss` + 四个 `OSS_*` 必填项已设，
      且 `node --env-file=.env.oss scripts/probe-oss.mjs` **退出码 0**（§2.7）
- [ ] `实例上限 × (PG_POOL_MAX + PG_AUTH_POOL_MAX) < 数据库 max_connections`
- [ ] Web 版要能打的话：**平台 API 网关已配跨域**，来源写具体域名

**C. AI**

- [ ] `probe-ark.mjs` **退出码 0**
- [ ] `e2e-local-homework.mjs` 的实测耗时落在客户端 12s 窗口内
- [ ] `AI_REQUIRE_AUTH=true`、`AI_KV_DRIVER=http` + `AI_KV_URL`、`AI_METRICS_TOKEN` 已配
- [ ] `AI_THINKING_DISABLED_KINDS` 按 §3.4 设置
- [ ] 单价**要么全填、要么全空**
- [ ] 网关环境变量里**没有任何已改名的旧变量**
- [ ] 真机跑一次拍照识别，确认走的是真模型
- [ ] **`serverless/*/.env.local` 里的 Key 如果曾经出现在聊天/日志里，已轮换**

---

## 5 回滚与应急

**客户端**：商店**不支持降级**（`versionCode` 必须递增），所以「回滚」= **重新发布上一个版本、
把 versionCode 加一**。这意味着发布前要留好上一个版本的构建命令与产物。

**服务端**：两个服务都是函数，**保留上一版部署**即可回滚（平台的版本/别名功能，或重新上传上一版代码）。
数据库迁移**只加不改**（`migrate.mjs` 不动已应用的迁移、没有 down 迁移），
所以**回滚服务端代码不会撞上「列被删了」**。反过来：如果某次改动要求「先上新代码再跑迁移」，
回滚时必须确认旧代码不依赖新列。

**AI 紧急止血**（按止血速度排序）：

| 手段 | 效果 | 代价 |
|---|---|---|
| 把网关的 `ARK_API_KEY` 改空 | 网关如实回 `model_not_enabled`，**客户端自动回落本地实现**，界面照常可用 | 全量 AI 不可用，但应用不崩 |
| `AI_QUOTA_UNITS_PER_DAY=1` | 快速耗尽额度，客户端收到 `quota_exhausted` | 同上，且用户会看到明确的额度提示 |
| 网关回滚到上一版 | 取决于上一版的问题 | —— |
| 客户端 `AI_DISABLED=true` | 完全不发 AI 请求 | **需要重新发版**，不适合救火 |

**数据库**：上线前先确认有没有**自动备份**并做过一次**恢复演练**。
`dev-stack --reset` 只清本机库，**永远不要对着生产库跑任何 `--reset`**。

---

## 6 症状 → 真因（本项目的「静默失败」清单）

失败**不报错**、只表现为「某个功能安静地不对」时，按这张表查：

| 现象 | 真因 |
|---|---|
| 登录成功，但进去一片空 | `AI_SESSION_SECRET` 为空，或两个服务**不是同一把** |
| 本地全绿、发到云上**全是 404**，且响应体看着正常 | 函数入口指错，或**触发器把路径前缀重写掉了**（§2.3） |
| 手机上好好的，**浏览器里所有请求被拦、后端日志一条都没有** | 云上没配跨域（数据服务的 CORS 头只在本机外壳里有，§1.6） |
| 拍照识别「没反应」，也不报错 | `ARK_MODEL_VISION` 为空 → 客户端探到 `vision=false`，**根本不发图**，直接走本地识别。这是设计行为 |
| 识别「成功」了，但每次回的都是**同样那两条**假作业 | 网关跑在 `AI_MODEL_CLIENT=mock`（**本机 `dev-stack` 的默认值**，见 `dev-stack.mjs`）→ 返回的是写死的假数据。它和上一行的区别是：这一种 `capabilities.vision` 仍报 `true`，所以客户端**照发图**、界面也不报错。要真识别：`AI_MODEL_CLIENT=ark` + 填 `ARK_MODEL_VISION` |
| 「讲解好像没用上 AI」 | 模型超客户端 12s 窗口 → **安静地退回本地模板**。处置见 §3.4 的思维链开关 |
| 成本看板是 0 或明显偏小 | `usage` 字段名变了（记成 0），或**单价只配了一部分**（缺的当 0） |
| 家长端看不到孩子提交的照片 | 照片**挂错作业 id**：客户端把本地 `hw_…` 当成了作业 id，而服务端自己生成 uuid（迁移规则 R2）→ 按作业查照片**恒为空**；或字节**从没离开学生那台设备**（旧的 `storage_key` 是设备本地标识）；或云上没配持久存储（§2.7）。已修 `0807ddb` / `9d3297c`，判据 `test/homework_id_adoption_test.dart` |
| **学生提交后当前界面看不到照片，换页签/返回都没用，但重登就好** | 上传接口回了真行、客户端把它扔了（`saveHomeworkImage` 声明 `Future<void>`）→ 内存里留的是 `img_…` 占位 id，而读图**按 id 查**（服务端 `imageRow()` 写死 `newId()`，**从不用客户端给的 id**）→ 404、一片空白。⚠️ **「重登就好」是 id 问题的招牌**（重登重走 `queryHomeworkImages`，那时才拿到真 id）。已修 `9fc639f`；判据 `test/photo_visible_after_submit_test.dart`（1 断言 + 2 控制组）+ 真链路 `npm run probe:photo-e2e` |
| 「我注册的账号说没有注册」 | **换了模式的构建**（两份库从不同步），或 Web 端换了域名/端口（localStorage 按 origin 隔离）。先跑 `node tools/build-mode.mjs` |
| 家长端永远「尚未与任何学生结伴」 | `relationship.status` 两侧用词不同 |
| 配额看起来不生效、账单却超了 | 共享 KV 没接（多实例各算一份）。生产环境现在会**拦下**这种配置 |
| 换个网络后 AI 全线不通，但数据正常 | 只改了 `DATA_API_BASE_URL`，`AI_BASE_URL` 还指着旧地址（两个都是编译期常量，**都得重新构建**） |

---

## 附：一句话版本

1. **建库 → `migrate.mjs` → 改角色口令**；
2. **部署数据服务**（入口 `index.cjs`、`NODE_ENV=production`、密钥两服务共用、CORS 在平台配）；
3. **部署网关**（`AI_REQUIRE_AUTH=true`、共享 KV、思维链开关、单价全空或全填）→ `probe-ark.mjs` 退出码 0；
4. **构建客户端**（两个地址指向生产域名、不带演示种子、真签名）→ 装机验五条；
5. **跑 §4 的 checklist**，特别是带 **401/404 反面**的那几条 —— 只验正面的话，
   「鉴权没生效」和「鉴权正常」看起来一模一样。

> 照片存储的**两条后端都已实现**（§2.7），剩下的是**选一条、配上去、验一次**：
> 跑函数计算就选 `oss`（那边没有持久磁盘）；跑 ECS 挂云盘/NAS 则 `fs` 也成立。
> 配完**必须用真凭证跑一次 `probe-oss.mjs`** —— 在那之前，「配好了」只是推断：
> 签名算法本身已被单测对齐到官方算例，但桶 ACL、RAM 权限、区域、时钟偏差验不到，
> 而它们失败时给的都是一样的 403。没验过就上线，照片会**静默地丢**（不报错）。
