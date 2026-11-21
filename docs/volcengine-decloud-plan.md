# 去阿里云化：整个后端搬到火山引擎（评估 + 路线）

> 🛑 **2026-09-30 20:0x 拍板：本条路线整体放弃。**
> 决定：**回到「阿里云基础设施 + 火山方舟模型」的混云形态** ——
> 数据库/函数/存储留在阿里云，只有大模型出公网调方舟。
> ⇒ **本文 §1–§12 全部转为「留档备查」，不再是待办清单**；§12（换 MySQL）连同它的前置问题一起作废。
> 混云方案的可行性论证、实测证据、代价与唯一缺口 → **§13**。
> 阶段 0（模型切方舟）**保留且不受影响** —— 它本来就是「云不动、只换模型」。

> **状态（原文，已作废）**：**评估完成 + 开通清单已实测，未动一行代码**（2026-09-30）。
> 前置文档：`volcengine-migration-plan.md`（总规划，阶段 0 已完成 —— 模型层已切方舟）。
> 本文只讲**阶段 1：计算 / 数据库 / 存储 一起搬**。
> 🔑 **「全量上火山还缺什么」→ 直接看 §10**（最新一次复跑 = §10.9，09-30 19:00）。
> §9 是它的证据链与探测命令。结论经过**五次翻转**，别只看其中一段：
> ① 15:39「没开通」→ ② 16:17 有人开通了 veFaaS → ③ 17:2x「策略没挂」其实是**策略挂了、作用域限在项目**
> → ④ 17:4x **TLS 也没开通**（它的报错伪装成 `AccessDenied`）→ ⑤ 19:00 **APIG / TLS 也都开通了**。
> ⇒ **开通侧已归零**；还差 **1 条权限 + 5 个资源 + 代码 + 数据搬迁**。
> ⛔ **运行时已锁定：Node.js on veFaaS**（2026-09-30 拍板：**不考虑 Deno**）。
> §11 保留那次 Deno 实测只为**备查**，**不是待选路线**；代价为 0 —— 现有代码一行不用改。
> ⚠️ **一个可能改变整个清单的前置问题**：**个人账号可能开不了 RDS-PG** ⇒
> 见 **§12**（换 MySQL 的代价盘点 + **ECS 自建 PG 这条 0 改动的替代路**）。

---

## 0. 先把一个措辞钉住：方舟不是计算平台

「部署在方舟引擎上」这个说法里，**方舟（Ark）是大模型平台**，它不托管你的 Node 代码。
要去阿里云化，计算这块的对应物是 **veFaaS（函数服务）**。两者是火山里两个不同的产品。

区分它们有实际后果 —— 因为这两块的进度**差得很远**：

| | 现网 | 火山侧 | 状态 |
|---|---|---|---|
| **大模型** | 百炼 `qwen3.5-omni-plus` | **方舟** `doubao-seed-2-1-lite-260915` | ✅ **上一轮已切完并实测**（`.env.prod` 已改，未部署） |
| **计算 / 数据库 / 存储** | FC3 + RDS-PG 18.4 + OSS | veFaaS + RDS-PG 17 + TOS | ⬜ **本次要评估的，一行没动** |

所以「去阿里云化」= 只做下面这张表的后半部分。模型层不在本次范围内。

---

## 1. 三环边界（**代码级实测**，不是从文档推的）

判据方法：全仓 grep 厂商名 + 读每个引用点的上下文 + 看默认值常量。

### 🔵 第 1 环：一根手指都不用动

| 组件 | 为什么不用动 | 证据 |
|---|---|---|
| **Flutter 客户端** | 只认一个 URL，且是**构建期** `--dart-define` 注入的 | `lib/services/ai_config.dart:134`（`String.fromEnvironment('AI_BASE_URL')`）、`data_config.dart` |
| **业务代码**（routes / auth / session / mapper / vocab / schema / prompts / coerce / insert / patch） | 没出现过任何厂商名 | 全仓 grep 无命中 |
| **10 个 SQL 迁移脚本** | **零 PG 版本专有语法** | `grep -rn "gen_random_uuid\|uuidv7\|identity\|generated always\|not enforced" sql/*.sql` → **0 命中** |
| **RLS / 多家庭隔离** | 标准 PG 特性（`SET LOCAL app.visible_students` + FORCE RLS） | `002_rls.sql` / `010_rls_empty_collection_safe.sql` |
| **无状态 HMAC 票据** | 两个函数共享一把密钥即可，**与平台无关** | `shared/token.js` |
| **Web 产物 `site/`** | Flutter Web 构建产物，换托管只是换上传目的地 | 目录内容 |

⚠️ 最后一行有个例外要注意：**托管方式**是平台相关的（见 §5），但**产物本身**不用重建逻辑。

### 🟡 第 2 环：改配置 / 加一个驱动

| 组件 | 改动 | 现状 |
|---|---|---|
| 大模型三档 | ✅ **已完成** | 上一轮已改 `.env.prod` 六行 |
| **照片存储** | `IMAGE_DRIVER=oss` → `tos`，**要新写一个驱动文件** | 工厂已存在（`image-store-factory.js`，`IMAGE_DRIVERS = ['fs','oss']`） |
| 数据库连接串 | `PGHOST` / `PGUSER` / `PGPASSWORD` / … | 换值即可，**读代码的方式不变** |
| 客户端 URL | 重新构建（`--dart-define`） | 一行命令 |
| `CORS_ALLOW_ORIGIN` | 可能不变（取决于 Web 产物挂哪） | 见 §5 |
| **KV** | `AI_KV_DRIVER=memory` + 逃生门 → 真共享 KV | 见 §4 第 5 条 |

⚠️ 存储那个「加一个驱动」比听起来麻烦 —— **签名部分不能照抄 OSS**，理由见 §4 第 4 条。

### 🔴 第 3 环：真工作（钱和人天都在这儿）

| 组件 | 说明 |
|---|---|
| **部署描述** | `s.yaml`：`component: fc3` → 火山组件；`logConfig` → `TlsConfig`；`vpcConfig` 字段名全换 |
| **事件形状适配** | **两个硬未知**，见 §3。这是本次最大的技术风险 |
| **运维脚本** | `aliyun-rpc.mjs` / `provision-fc-vpc-role.mjs` **可退役**（火山不需要单独建 VPC 角色，见 §5） |
| **新 TOS 驱动** | 一个文件，但要按 AWS SigV4 重写签名 |
| **Web 托管** | 定方案（TOS 静态站点 + CDN / 保持现状） |

---

## 2. ⭐ 一个「当年的债，今天免单」的发现

**`shared/query.js` 已经把火山的字段名读进去了。**

那个文件是 2026-09-24 一次真实故障的产物：阿里云 FC3 把查询参数放在
`event.queryParameters`，而代码读的是 `queryStringParameters` ⇒ 所有 query 参数
**静默变成空**，症状是「上传照片说缺少 studentId，同样的值放进 body 就正常」。

当时的修法**不是**改成 `event.queryParameters`，而是：

```js
const QUERY_MAP_KEYS = [
  'queryParameters',            // ← 阿里云 FC3
  'queryStringParameters',      // ← API 网关 / Lambda 风格
  'multiValueQueryStringParameters',
];
```

理由写在源码里：**「多读一个不存在的键成本是零，漏读一个的代价是一次线上故障」**。
而且**取并集**，不赌 `??` 的顺序。

**而火山的 APIG 触发器事件用的正是 `queryStringParameters`**（官方文档
「触发器事件消息结构」页）。也就是说 —— **这一环在换厂商时不需要改，也不用重踩一次。**

同理 `event?.path ?? event?.rawPath` 也已经兼容（火山用 `path`，阿里用 `rawPath`）。

> 📌 这条值得记下来：**当时把「读哪个键」这一事实收敛到一处、并选择「都读一遍」这种
> 看起来多余的写法，恰好是跨厂商迁移时最值钱的一个决定。** 它不是运气 —— 是那次的
> 教训（「字段名猜错一次 = 静默丢参数」）被写成了代码结构。

---

## 3. 🔴 两个必须实测的硬未知（选「事件函数」路线的前置条件）

这两条**文档里查不到定论**，必须在真环境各打一次。它们的共同特征是：
**错了不报错**，只是安静地返回错误的东西。

### ① 请求侧：事件里到底有没有 `isBase64Encoded`

现有代码（两个 `handler.js` 各一份，逐字相同）：

```js
const raw = event?.isBase64Encoded
  ? Buffer.from(event?.body ?? '', 'base64')
  : Buffer.from(event?.body ?? '', 'utf8');
```

- 阿里 FC3 实测：**有**这个字段（且**连 GET 请求都是 `true`**，见 `fc3-http-event.js` 的注释）。
- 火山文档的 APIG 触发器事件结构里列的是：
  `httpMethod` / `path` / `pathParameters` / `queryStringParameters` / `headers` / `body`
  —— **没有列 `isBase64Encoded`**。

⇒ 如果火山把二进制 body 按别的形态给（或者直接给字符串），这一行会**静默产出乱码**，
而症状是「照片存进去了，但显示不出来」。

**判据**：挂一个 `GET/POST /__diag` 原样回显事件层键名（`fc3-http-event.js` 就是这么抓的），
真打一次**二进制**请求，把顶层键原样抄回来。**不要照着我们以为的字段名造测试事件** ——
当年那条测试就是这么失效的（抄对了键名、值写 `{}`）。

### ② 响应侧：`isBase64Encoded` 会不会被丢掉

现有 `toPlatformResponse`：

```js
return {
  statusCode: result.status,
  headers: result.headers,
  body: isBinary ? result.body.toString('base64') : result.body,
  isBase64Encoded: isBinary,     // ← 照片接口靠它
};
```

而火山文档**反复**只说一件事：

> 「返回值中，**只有 `statusCode`、`headers`、`body` 三个键值对**最终会返回给请求方。」

⇒ 如果 `isBase64Encoded` 被丢弃，`body` 就是一个 **base64 字符串**，
平台按文本发出去 ⇒ 客户端拿到的不是图片字节 ⇒ **裂图，且全程零报错**。

**判据**：部署后真取一张照片，看响应的 `Content-Type` 与**实际字节**
（不是看状态码 200）。

### 📌 这两条直接决定架构选型

见 §5 —— 有一条路线**把这两个未知直接消灭掉**。

---

## 4. 逐个说清「火山那边长什么样」

### 4.1 计算：FC3 → veFaaS（字段级）

| FC3（现在） | veFaaS（火山） | 说明 |
|---|---|---|
| `component: fc3` | `component: volcano-vefaas` | ⚠️ 组件名来自第三方项目转述，**未亲自验证** |
| `internetAccess: true` | `VpcConfig.EnableSharedInternetAccess` | 语义一致：开了 = 能出公网 |
| `vpcConfig.vpcId` | `VpcConfig.VpcId` | |
| `vpcConfig.vSwitchIds[]` | `VpcConfig.SubnetIds[]` | |
| `vpcConfig.securityGroupId` | `VpcConfig.SecurityGroupIds[]` | 火山是**数组** |
| `role:`（RAM 角色） | **不需要** | ✅ 省一步：火山把 VPC 直接配在函数上，不必先建一个能建 ENI 的角色 |
| `logConfig.project/logstore` | `TlsConfig` | 火山默认项目 `tls-vefaas/tls-vefaas-logstore` |
| `runtime: nodejs20` | `node20/v1`（事件函数） | 火山事件函数内置运行时含 `node20/v1` |
| `cpu` / `memorySize`（1:1~1:4 约束） | `MemoryMB` / … | ⚠️ **火山是否也有这个约束未确认** |
| `diskSize: 512` | ⚠️ **未找到对应项** | 待确认 |
| `timeout: 120`（网关） | `RequestTimeout` | **⚠️ 见下面那条坑** |

**🔴 坑：超时是两处取短，不是取长**

火山 APIG 触发器**自己也有一个超时设置**，官方原话：

> 「If you also set the timeout period for the current function on the veFaaS side,
> **the short timeout period will take effect**.」

⇒ 网关函数的 `RequestTimeout` 是 120s（为了容纳强推理档），
但如果 APIG 触发器那边配了个更短的（或不配 = 无限制），行为就变了。
**部署时必须把这两处显式对齐并写下来** —— 症状是「AI 有时候没反应」，
看着像网络抖动，与 FC3 那边超时被掐断的症状**一模一样**。

**✅ 省下来的：**
- `provision-fc-vpc-role.mjs`（建 RAM 角色）**整个退役** —— 没有「角色必须能建 ENI」这一层。
- `aliyun-rpc.mjs`（为那件事手写的 RPC 签名客户端）**一起退役**。

### 4.2 数据库：RDS PostgreSQL 18.4 → 17

- 火山云数据库 PostgreSQL **支持 11–17 七个大版本** ⇒ 我们是**从 18 降到 17**。
- **但这不是问题**：`sql/001_schema.sql` 的文件头**自己写的就是**：
  > `目标：PostgreSQL 17`

  ⇒ 迁移脚本**本来就是照 17 写的**（现网跑 18.4 属于超标运行）。加上 §1 那个
  「零版本专有语法」的 grep 判据，**这条落差是非事件**。
- ⚠️ 但**别用「迁移跑成功」推断「隔离生效」** —— RLS 是**行为**问题，
  要跑 `/data/*` 越权请求做判据（现成的 `probe-rls.mjs`）。

### 4.3 存储：OSS → TOS（**签名不能照抄**）

TOS 兼容 S3 协议，**但只支持 V4**（和 OSS 现状一致，这点是好事）。

🔴 **但两个 V4 不是同一个 V4。** `ossimagestore.js` 里自己写着：

> 「⚠️ **`host` 不在其中** —— 这与 AWS SigV4 不同（**AWS 必签 host**）。」

而 TOS 的 S3 兼容协议走的就是 **AWS SigV4**（签 host、`x-amz-*` 头、`x-amz-content-sha256`）。

⇒ **`tosimagestore.js` 的签名部分要按 S3 重写，不能把 `ossimagestore.js` 改名了事。**
可以复用的是**上层**：`buildStorageKey`（键格式单点）、`validateUpload`、
接口形状（现有 `fs` / `oss` 两个实现**接口逐字相同**，所以调用方不用动）。

**域名形态也不同**（易踩）：
| | 外网 | 内网 |
|---|---|---|
| OSS | `oss-cn-hangzhou.aliyuncs.com` | `oss-cn-hangzhou-**internal**.aliyuncs.com` |
| TOS | `tos-s3-cn-beijing.volces.com` | `tos-s3-cn-beijing.**ivolces.com**` |

⚠️ 注意 **TOS 还有一套「原生协议」域名** `tos-cn-beijing.volces.com`（不带 `-s3-`）。
用 S3 协议就必须用 `-s3-` 那套，**混用会得到一个看着像权限错的错误**。
⚠️ RDS 也是同一规律：内网是 `*.rds-pg.ivolces.com`。

### 4.4 KV：`AI_KV_DRIVER=memory` 这件事要一起解决

现网配置里带着一个**显式的逃生门**：

```
AI_KV_DRIVER: memory
AI_ALLOW_EPHEMERAL_KV: 'true'
```

代码里写得很清楚：`memory` 驱动下**配额计数落在每个实例各自的内存里**，
多实例下「配额上限本身测不准」。而 `config.js:726` 有一条守卫：
生产环境用非 `http` 驱动且没开逃生门 ⇒ **直接报错**。

⇒ 换云是个好时机：**接一个真共享 KV（火山 Redis 或表格存储）**，
把这个逃生门关掉。否则这个问题会**原样搬过去**，还会被「新环境」的注意力掩盖。

### 4.5 日志：SLS → TLS

`logConfig` 的 `project` 现在是 SLS 首次部署时自动生成的名字。
火山对应 `TlsConfig`，默认会建 `tls-vefaas/tls-vefaas-logstore`。
⚠️ **要显式配**：不配的话 `s logs` / `vefaas fn logs` 一条都拿不到，
而**网关恰恰是最需要日志的那个函数**（AI 调用失败时审计日志是唯一线索）。

---

## 5. ⭐ 架构选型：两条路，我建议走第二条

> ⛔ **先把范围钉住**：本节的「两条路」**都跑 Node.js on veFaaS**
> （`node20/v1` / `native-node20/v1`）。**运行时不在讨论范围内** ——
> 2026-09-30 拍板**不考虑 Deno**（那条路的实测存档在 §11）。
> 所以这里只决定「**请求怎么进来**」（事件 vs HTTP），不决定「**用什么语言写**」。

veFaaS 有两类函数，**选哪类决定上面两个硬未知是否存在**。

| | **路 A：事件函数 + APIG 触发器** | **路 B：Web 应用函数** |
|---|---|---|
| 用哪个入口 | `handler.js`（现有生产入口） | **`dev-server.js`**（现有 HTTP 外壳） |
| 事件形状适配 | 🔴 **必须移植**，两个硬未知（§3） | ✅ **不存在** —— Node `http` 直接读写字节 |
| 照片二进制 | 🔴 有裂图风险 | ✅ 天然正确 |
| 运行时 | `node20/v1`（内置运行时） | `native-node20/v1`（要 `run.sh`） |
| 冷启动 | 最快 | 稍慢一点 |
| 改动量 | 中（事件 + 二进制两处适配） | **小**（改一个默认值 + 写 `run.sh`） |
| 已验证程度 | 本地单测喂的是**自己造的事件**（当年就是这么漏掉 `queryParameters` 的） | ⭐ **上一轮已端到端真跑过** |

### 走 B 的理由（不是偏好，是证据）

`dev-server.js` 的**第一句注释**就是：

> 「云函数入口用的是**同一个 `createApp`** —— 两者只差「请求怎么进来的」。」

也就是说它**不是**「只能本地跑的玩具」，它是同一个应用的另一层外壳。而且：

- ⭐ **上一轮我刚用它起了三个实例（8787/8788/8789），通过真实 HTTP 跑通了三条链路**
  （`answer-ocr` / `homework/check` / `homework/ocr`）。那是**已验证的路径**，
  不是「应该可以」。
- 它已经自带 FC3 那边**靠「平台 + 应用」两半才凑出来**的东西：
  OPTIONS 短路 204、CORS 头、12MB 请求体上限、未匹配路径兜底。

### 走 B 要改的三个地方（都很小但都会踩）

1. 🔴 **`BIND_HOST` 默认是 `127.0.0.1`**（两个 `dev-server.js` 都是，且是**刻意收紧**的）。
   平台探不到端口 ⇒ 症状是「**函数起不来**」，而日志可能什么都没写。
   ⇒ 生产必须设 `BIND_HOST=0.0.0.0`。
2. **端口**：veFaaS Web 应用默认 8000，有效范围 [1024, 65535]，
   **必须避开 9000 / 9001 / 9990**（平台自己占用）。
3. **要写 `run.sh`**（代码包部署时默认执行根目录的 `./run.sh`），并在里面
   设好 `PORT` / `BIND_HOST`。

### ⚠️ 无论走哪条路：CORS 的「谁给头」分工必须重验

现在这套是**两半**配合的（源码注释写得很清楚）：
- **平台**给 CORS 响应头（FC3 的触发器配了 `OPTIONS` 放行）
- **应用**在 OPTIONS 上**短路回 204 且不自己加 CORS 头** —— 因为「那份由平台给，
  自己再给一份会**重复**，浏览器直接报错」

而火山的 APIG 触发器**有个「跨域开关」，开了就加 `Access-Control-Allow-Origin: *`**：

⇒ 两个后果，都要在部署时定：
1. 如果平台加了 `*` 而应用也加一份 ⇒ **重复头 ⇒ 浏览器报错**（比不加还糟）。
2. 那个 `*` 与项目原则冲突 —— `release-guide.md` 里写着「**写具体来源，不要 `*`**：
   `/auth/login` 是公开端点，通配等于给每个网页一个免费的口令爆破入口」。
   ⇒ **别顺手把这个开关打开**。

---

## 6. 实测出来的阻塞：**从「没开通」变成了「没权限」**

> ⏱ **本节保留 15:39 那次原始记录**（它把三种错误码的形状钉下来了，值得反复看）。
> 🔴 **结论已过期三次**：① 16:17 veFaaS 被开通；② 17:2x 发现策略早就挂齐了（6 条）；
> ③ **17:3x 又推翻「项目参数不通用」** —— 带上 `ProjectName` 其实能过（见 §9.10 更正）。
> 一句话现状：**策略齐、服务基本齐，只剩「开通 APIG」+「一条 `CreateSubnet` 权限」**。

用现有 AK/SK 真签了一次 veFaaS OpenAPI（`probe_volc_vefaas_perm.mjs`）：

```
vefaas.cn-beijing.volcengineapi.com   GET  →  HTTP 401  ServiceNotActivated   ← 2026-09-30 15:39
      "You need to create a service-linked role for veFaaS by visiting
       the main page of veFaaS."
```

三件事同时被钉住：

1. **AK/SK 是对的、网络与端点也是对的** —— 两套端点（新旧）、两种方法都拿到了
   **业务层错误**，说明请求真的打到了 veFaaS 并被鉴权层认了。
   （对比：上一轮 IAM 探测得到的是 `AccessDenied`，那是「开通了但没权限」。）
2. **veFaaS 这个产品还没开通** ⇒ 要先去控制台首页**创建服务关联角色**。
   ✅ **16:17 已做完**（角色已建，函数 `easy-learn-ai-api` 就是那时候建的）。
3. 🔴 **它回的是 HTTP 401，不是 403** —— 401 的常规读法是「未认证 / 密钥不对」，
   于是排查方向会先走到「重新生成一对 AK/SK」上去。**那是个无效动作。**
   区分靠 `ResponseMetadata.Error.Code` 那个词，**不靠状态码**：

   | Code | 含义 | 该做什么 |
   |---|---|---|
   | `ServiceNotActivated` | 产品没开通 | 去控制台**开通** |
   | `AccessDenied` | 开通了、没权限 | 去控制台**加策略** |
   | `InvalidAccessKey` | 密钥真有问题 | 重新生成 |

   ⚠️ 这三个的下一个是**完全不同**的，但都会长得像「鉴权失败」。

   ⭐ **还有第四态（17:3x 补进去的）**：`AccessDenied` 也可能是**「调用没带对项目参数」** ——
   子账号的策略作用域是**项目 `easy-learn`**，而 API 调用不带项目时**默认落 `default`**
   ⇒ 同样回 `AccessDenied`，**不报"缺参数"**。必须自己想到要带，而且**位置要对**
   （`GET`→query / `POST`→body，见 §9.10）。**这一态不会自我暴露。**

**顺带**：权限清单（火山官方「veFaaS 部署指南」要求）——
`VeFaaSFullAccess` · `VPCFullAccess` · `TLSFullAccess` · `APIGFullAccess` ·
`CRFullAccess`（用代码包可缓）· `CloudMonitorReadOnlyAccess`。
**按需给这几条就够**，别像阿里那次直接上 `AliyunRAMFullAccess`（事后要撤）。

---

## 7. 开工顺序

```text
0. 【前置，与换云无关】提交那 68 项未提交改动
      ← 线上四个产物全部来自这份未提交代码。不做这个，后面全建在流沙上。

1. 【控制台，你来】**现在只剩这几件事**（§10 汇总过，别多开）：
     ① ✅ ~~开通 veFaaS~~ —— **已于 09-30 16:17 完成**，跳过
     ② ✅ ~~给子账号加策略~~ —— **17:2x 发现早就挂齐了（6 条）**，跳过
     ③ 🔴 **二选一**（取舍见 §9.10 表）：
        · **路线 A（省心）**：把 4 条 FullAccess 的作用范围改成「**全局**」
        · **路线 B（最小权限）**：不动策略，**所有调用都带 `ProjectName=easy-learn`**
          ⚠️ 位置要对（`GET`→query / `POST`→body）；漏带 = 403，且**与"真没权限"同形**
          ✅ 17:4x 已找到活样本：控制台建的 `easy-learn-ai-api` 就落在该项目下
     ④ 🔴 **开通 API 网关（APIG）** —— `CreateGateway` 回
        `ForbiddenOperation: account … has not authorized` = **服务未开通**（§9.10 ①）
     ⑤ 🔴 **开通日志服务（TLS）** —— 🔴 报错**伪装成 `AccessDenied`**，原文才是真相：
        「**The account does not open tls service.**」（§9.3 动作 5）
     ⑥ 🔴 **建 VPC / 子网 / 安全组 + RDS-PG 17 + TOS 桶**（都选 `easy-learn` 项目）
        —— `vpc:CreateSubnet` 子账号建不了（§9.10 ②，机理未定性），子网老实走控制台
   → 判据 = 重跑 `node probe_volc_project_scope.mjs` + `node probe_volc_tls_scope.mjs`，
     看那几行由 🔒/🔴 变成 ✅
     ⚠️ **别用「控制台点了确认」当判据**
   → ✅ **已确认**：账号里那个 `easy-learn-ai-api` 是虫子建的（2026-09-30），
     控制台默认 Go 模板、**触发器 0**、无 VPC / 无日志。**不撞名，留着不碍事。**

2. 【决定】架构选型：事件函数（要攻两个未知）还是 Web 应用函数（我推荐）
3. 【实测】若选事件函数：先做 §3 的两个硬未知，一次一个判据
4. 【建库】RDS-PG 17 实例 + 跑 10 个迁移
   → 判据是**行为**（跑 probe-rls.mjs 验越权），不是「迁移成功」
5. 【建桶】TOS + 写 tos 驱动（S3 SigV4，别抄 OSS）+ 真凭证探一次
6. 【改描述】部署描述重写（component / VpcConfig / TlsConfig / 超时两处对齐）
7. 【部署】两个函数，逐个探 /health
8. 【重构建】客户端 URL（--dart-define）+ Web 产物托管
9. 【对账】双跑对照一段时间，再决定什么时候关阿里那套
```

⚠️ **第 4–7 步之间别并行**：RDS、TOS、函数是三段独立依赖，
中间任何一步「看起来成了」都要用行为判据确认（这个项目在阿里云那边
反复栽在「EXIT=0 / 部署成功 / 配置正确」这三句上）。

---

## 8. 不做什么（免得被「迁移」这个词带偏）

- ❌ **不动客户端代码** —— 它只认一个 URL，换的是构建参数不是源码。
- ❌ **不重建业务逻辑** —— routes / RLS / 票据 / 校验全是厂商无关的。
- ❌ **不改 SQL 语义** —— 脚本本来就是照 PG 17 写的，18→17 是回到它声明的目标。
- ❌ **不为了「保持一致」给网关也配上 VPC** —— 网关不碰数据库（票据是无状态 HMAC），
  配 VPC 只会拖慢冷启动。这条 FC3 的注解里已经写过一次，别在新平台重犯。
- ❌ **不同时换云 + 改业务** —— 换云已经引入足够多的未知，别再叠 B29 的修法。

---

## 9. 火山侧开通清单（**2026-09-30 用 AK/SK 逐个真签实测**）

回答的是那个具体问题：「**坚持原来的 App + 云函数 + 云数据库 + 大模型，火山要开通哪些？**」
—— 答案不是「大概这些」，而是逐条分清四种状态。判据脚本：
`probe_volc_service_activation.mjs`（OpenAPI 类）+ `probe_volc_tos.mjs`（S3 类）。

### 9.1 实测结果（**09-30 17:2x 复跑 —— 推翻了 15:5x 那版的结论**）

⚠️ 旧版写「已开通、但子账号没权限」。**17:2x 的细粒度复跑证明那句话是错的**：
策略**早就挂上了**，卡住的是**策略的作用范围**。详见 §9.10。

| 火山产品 | 对应现网 | **实测状态** | 原始判据 |
|---|---|---|---|
| **函数服务 veFaaS** | FC3 | ✅ **可用（读 + 写都过鉴权）** | `ListFunctions` 200；`CreateFunction` / `GetFunction` 回 `MissingParameter` ← 鉴权已过、只差参数 |
| **私有网络 VPC** | VPC + 交换机 + 安全组 | ⚠️ **带项目参数就通**（一处例外） | `DescribeVpcs` + `ProjectName` → 200；**`CreateSubnet` 例外，见 §9.10 ②** |
| **云数据库 PostgreSQL 版** | RDS-PG 18.4 | ⚠️ **带项目参数就通** | `DescribeDBInstances` **POST + body** `ProjectName` → 200 ⚠️（17:3x 更正：上一版写「仍被拒」是**我传错了参数位置**） |
| API 网关 APIG | FC3 自带 HTTP 触发器 | ✅ **已开通**（**09-30 19:00 起**）· 读要带项目参数 | `ListGateways` POST+body → 200（不带 → 403）；`CreateGateway` 的码**从 `ForbiddenOperation` 变成 `InvalidParameter`**，见 §9.1.3 |
| **对象存储 TOS** | OSS | ✅ 已开通且有权 | S3 协议 200（§9.8） |
| 访问控制 IAM | RAM | ⛔ 无权限 —— **但本项目不需要** | `ListUsers` / `ListPolicies` / `ListAccessKeys` 全 `AccessDenied`；**`ListProjects` 却通**（见 §9.10） |
| **日志服务 TLS** | SLS | ✅ **已开通**（**09-30 19:00 起**） | 17:4x 还回 `AccessDenied`「The account does not open tls service.」；**19:00 同一脚本回 200**（`DescribeProjects` / `DescribeTopics` 都 200） |
| 缓存数据库 Redis | 无（现网 KV 是 memory） | ❓ **未探明** | `InvalidActionOrVersion` |
| 方舟大模型 | 百炼 | ✅ 开通且有权 | `ListEndpoints` 200 |

**一句话**：**不用再"加"任何策略，也不用再"开通"任何服务** —— 策略早就挂齐了（6 条，见 §9.10），
六个产品**到 09-30 19:00 全部开通**（TLS / APIG 是当天下午到晚上陆续开的，见 §9.1.3）。
**「调用时带上 `ProjectName=easy-learn`」能把绝大多数调用救回来**（参数位置按接口，见 §9.10）。
🔴 **现在唯一还缺的是「1 条权限」和「一个都没建的资源」** —— 完整清单在 §10.9。
🗂 **「全量上火山还缺什么」的完整清单见 §10**（那节才是回答这个问题的）。

#### 9.1.1 🔴 状态在当天下午变过 —— 这条比表格本身更重要

同一套探测，**同一天相隔 1 小时**给出相反结论：

| 本地时间 | 探测脚本 | 结果 |
|---|---|---|
| 15:39:36 | `probe_volc_vefaas_perm.mjs` | 🔴 HTTP **401** `ServiceNotActivated` |
| 15:57 | `probe_volc_service_activation.mjs` | 🔴 同上（未开通） |
| **16:17:32** | — | **有人在控制台开通了 veFaaS 并建了一个函数** |
| 17:11 | `probe_volc_vefaas_perm.mjs` **原样重跑** | ✅ HTTP 200，列出 1 个函数 |

⚠️ **判据不是「探测脚本变了」，而是「同一个脚本前后不一致」+ `CreationTime`。**
用**当时给出 401 的那个脚本**原样重跑得到 200 ⇒ 排除「上一轮是探针假阴性」；
再用函数的 `CreationTime`（`2026-09-30 08:17:32 +0000 UTC` = **北京 16:17:32**）
与**我自己探测日志的 mtime**（15:39 / 15:57，见上表）对表 ⇒ 落在两次探测**之后**
⇒ **是真实的状态变化，不是观测偏差**。

> 📌 可复用的一条：**「服务未开通」这种结论有保鲜期**。
> 下一个人（或同一个人的下一个小时）可能已经把事办了。
> 所以**引用这类结论前务必带时间戳，并在动手前重跑一次判据**。
> ⚠️ 同时也别反向过度解读：`CreationTime` 的 `+0000 UTC` 是**真 UTC**，
> 不是「本地时间贴了个 UTC 标签」—— 这一点是靠上面那个 mtime 对表**证出来**的，
> 不是假设的。差 8 小时会把「他刚建的」读成「早就有了」，结论正好反过来。

#### 9.1.2 那个已存在的函数 `easy-learn-ai-api` 是什么

```
Name         easy-learn-ai-api          Id      bw0pguo4
ProjectName  easy-learn                 Owner   2109706933（你的主账号）
Description  题目解析专用                Runtime native/v1
CreationTime 2026-09-30 08:17:32 UTC    Command ./run.sh     Port 8000
Cpu 1000（1 核）· MemoryMB 2048 · DiskMB 10240 · RequestTimeout 30 · MaxConcurrency 100
Role         trn:iam::2109706933:role/ServiceRoleForVeFaaS   ← 服务关联角色**已建**
VpcConfig    {"EnableVpc": false}       ← 连不上私有网络（即连不上 RDS）
TlsConfig    {"EnableLog": false}       ← 没有日志（出问题查不到）
TriggersCount 0                          ← 🔴 **没有任何触发器 ⇒ 现在没有访问入口**
CodeSize     2332655
```

**它里面一行我们自己的代码都没有。** 把 `SourceLocation` 那个预签名地址拉下来解开，
里面是 **Go 语言的 veFaaS 默认模板**：

```
go.mod · go.sum · main.go · main · run.sh · build_and_zip.sh
server/handler.go · server/server.go
```

⇒ 结论：**它是「开通 veFaaS 时顺手点的样例函数」，不是任何迁移成果。**
判据是包内语言（Go）+ 文件名（模板自带 `build_and_zip.sh`），不是名字。

✅ **来源已确认（2026-09-30，虫子本人）**：**是他建的。**
`Description` 写的是「**题目解析专用**」—— 意图很清楚，不是随便点出来的。
但**壳里没有实现**：Go 模板代码 + 无触发器 + 无日志 + 无 VPC
⇒ **它现在承担不了「题目解析」**，只是一个占位。

⭐ 它顺带证明了两件事（都写进 §10 了）：

1. **控制台建资源会落到你选的项目里**（它的 `ProjectName = easy-learn`）
   ⇒ §9.10 那条「路线 B：都放 `easy-learn` 项目」有**活样本**，不是纸面推理。
2. **「名字起对了」不等于「事办了」** —— 名字叫 `easy-learn-ai-api`、描述写着「题目解析专用」，
   而里面是厂商默认模板。**判据要看内容，不看命名。**
   （本仓库 `s.yaml` 要发的是 `easy-learn-ai` / `easy-learn-data`，**不撞名**。）

⚠️ 剩下两条仍然成立：

1. **它和本仓库的形态完全不同**。本仓库 `s.yaml` 定义的是 `easy-learn-data` /
   `easy-learn-ai` 两个 **nodejs20 代码包**函数；这个是 **native/v1 应用**（`./run.sh`、
   监听 8000）。**两者不能混为一谈**，也不是「把 `s.yaml` 部署上去了」。
2. **是留是删你来定**。留着不碍事，但它会把「账号里已有 1 个函数」这个事实
   带进后续所有盘点（成本、配额、命名）。


#### 9.1.3 ⭐ 19:00 复跑：**开通侧彻底清空了**（两处状态又变了）

**这是「这类结论有保鲜期」的第三次实证**，而且是同一天内的第三次：

| 服务 | 17:3x–17:4x 的原文 | **19:00 的原文** | 判读 |
|---|---|---|---|
| **日志服务 TLS** | `403 AccessDenied`「The account does not open tls service.」 | **`200`**（`DescribeProjects` / `DescribeTopics`） | 🔴 **未开通 → 已开通** |
| **API 网关 APIG** | `403 ForbiddenOperation`「account 2109706933 has not authorized」 | **`400 InvalidParameter`「Request illegal.」** | 🔴 **未开通 → 已开通**（错误码越过了开通检查那一层） |

APIG 这条**只有一条依据不足以定案**（`InvalidParameter` 也可能是我请求体不对），
所以补了第二条独立依据：**`apig:ListGateways` POST + body `ProjectName` → 200**
（不带项目参数同期仍是 `403 AccessDenied`，resource 是 `project/default`）。
两条同向 ⇒ **APIG 服务已开通，且开通检查、鉴权都过了。**

⚠️ **19:00 复跑里仍然没变的两条**（这才是现在真正的缺口）：

| 项 | 原文 | 说明 |
|---|---|---|
| `vpc:CreateSubnet` | `403 AccessDenied`，resource **为空**；补上 `VpcId` 后**仍拒** | 四种形态全拒而 `DescribeSubnets` 通过 ⇒ **真的缺这条 action**，与项目无关 |
| 全部资源 | `DescribeVpcs` / `DescribeSubnets` / `DescribeSecurityGroups` **`TotalCount` 全是 0** | **一个 VPC / 子网 / 安全组都没有** |

> 📌 复跑命令（§9.9）：`probe_volc_project_scope.mjs` + `probe_volc_tls_scope.mjs`。
> 两个脚本都是**自足判据**：TLS 那个带「故意写错的 action 必须回 404」的对照组，
> 所以它的「200」不是空转的绿。

### 9.2 判据链（为什么敢说「已开通」）

`AccessDenied` 的常规读法是「没权限」，但它**同时**携带一条更重要的信息：
**开通检查已经通过了**。前提是「开通检查排在权限检查之前」—— 这条有对照：

```
veFaaS（09-30 15:39 时确实没开通）→ ServiceNotActivated   ← 未开通的回这个，不是 AccessDenied
VPC   （？）                      → AccessDenied         ← 所以它过了开通这一关
```

⚠️ **veFaaS 这行现在只是「历史对照」，它 16:17 已被开通**（见 §9.1.1）。
保留它是为了说明「两种码确实能区分两种状态」这件事**当时被实测过** ——
**但不代表现在还是那个状态**。这正是 §9.1.1 那条教训的由来。

| 返回 | 能推出什么 |
|---|---|
| `ServiceNotActivated` | 🔴 **没开通** |
| `AccessDenied` | ⚠️ **开通了**，只是没权限 |
| HTTP 200 | ✅ 开通 + 有权 |
| `InvalidActionOrVersion` | service 名对，**开通状态推不出**（半截线索） |
| `fetch failed` / DNS | **我的端点形态猜错了**，与服务无关 |

⚠️ **这个推理的前提是「所有服务的检查顺序一致」**。veFaaS 提供了对照，
但不保证每个服务都这样。所以表中 ⚠️ 那几行是「**最可能的读法**」而不是硬结论 ——
**去控制台服务列表扫一眼即可确认**，成本一分钟。

⚠️ 另注意 **`AccessDenied` 可能装在 HTTP 200 里**（RDS 与 IAM 那两行就是：
状态码 200、body 里 `ResponseMetadata.Error.Code = AccessDenied`）。
看状态码会得出「一切正常」的反结论 —— 与阿里云那次「错误装在 200 里」同源。

### 9.3 要做的其实是这几件事

**动作 1 — 开通 veFaaS** ✅ **已于 2026-09-30 16:17 完成**（服务关联角色已建，
`Role: trn:iam::2109706933:role/ServiceRoleForVeFaaS`）。保留原步骤说明，
因为这是**下一个新账号/新环境会再遇到一次**的动作：

控制台 → **函数服务 veFaaS 首页** → 按提示**创建服务关联角色**。官方原文：

> "You need to create a service-linked role for veFaaS by visiting the main page of veFaaS."

🔴 它回 **HTTP 401** —— 401 的常规读法是「密钥不对」，于是下一步会走成
「重新生成 AK/SK」。**那是无效动作。** 区分靠 `Error.Code` 那个词，不靠状态码。

**动作 2 — 「项目参数」二选一**（两条路**都成立**，取舍见 §9.10）

~~给子账号加策略~~ —— **17:2x 实测发现策略早就挂齐了（6 条）**。
卡点在那 4 条 FullAccess 的**作用范围被限在「指定项目 `easy-learn`」**，
而 API 调用**默认落在 `default` 项目** ⇒ 不带项目参数时一律 `AccessDenied`。
⚠️ 而 17:3x 又实测出：**带上项目参数就能过**（见 §9.10 更正）。

| 路线 | 动作 | 代价 |
|---|---|---|
| **A（省心）** | 那 4 条的作用范围改成 **「全局」** | 子账号权限覆盖账号内**所有项目** |
| **B（最小权限）** | **不动策略**，所有调用带 `ProjectName=easy-learn` | 每处调用都得带、**且位置要对**；漏带 = 403，**与"真没权限"同形** |

（`VeFaaSFullAccess` 不在清单里却可用 —— 见 §9.10 那条「列表里没有 ≠ 没权限」。）

⚠️ **别直接上 `AdministratorAccess`** —— 阿里云那次给的是 `AliyunRAMFullAccess`（过大，事后要撤）。
这 6 条按最小必要原则是合适的，**最多只需放宽作用范围，不需新增策略**。

**动作 3 — 开通 APIG 服务**（🔴 17:3x 新发现，**与路线无关**）

`CreateGateway` 带项目后回 `ForbiddenOperation: account 2109706933 has not authorized`
（不带项目时是 `AccessDenied` ⇒ **项目参数已生效**），这是**服务未开通**的码，不是权限码。
控制台 → **API 网关** → 按向导开通。详见 §9.10 ①。

**动作 4 — 子网**（🔴 17:3x 新发现，**与路线无关**）

`vpc:CreateSubnet` 无权限（多种形态全拒，而同词的 `DescribeSubnets` 通过）。
**子网先用主账号在控制台建好**，函数部署时只引用 `subnet_ids`。
⚠️ 但「为什么拒」**仍未定性**（两种解释都还活着，见 §9.10 ②）—— 别照抄一个机理。

**动作 5 — 开通日志服务 TLS**（🔴 17:4x 新发现，**与路线无关**）

不用这一条，网关就没有日志 —— 而网关恰恰是 AI 失败时唯一能查的地方。

🔴 **它的报错形式值得单独记**：

```
HTTP 403  AccessDenied  "The account does not open tls service."
```

**错误码是 `AccessDenied`（看着像权限问题），真相是「服务未开通」。**
⇒ 又一次印证：**这个平台必须读 `Message`，不能只看 `Code`。**
（对比 §9.1.1 那条：未开通也能装成 **401**。同一个真相，两种伪装。）

⚠️ 而它此前 5 条探针全是 `InvalidActionOrVersion`，**根因不是权限也不是开通状态** ——
是**调用约定根本不同**（TLS 不走 TOP 网关）。详见 §10.4。

### 9.4 **不需要**开通的（省掉，别被「迁移」带偏）

| 不需要 | 为什么 |
|---|---|
| ❌ **短信服务** | `/auth/sms/*` 三条是**预留桩** —— `handleSmsNotImplemented`，服务端从未接入。客户端有 `/sms-login` 页与 `sms_gateway.dart`，但后端不接 |
| ❌ **域名 + SSL 证书** | 客户端两个 URL 现在指向 `*.fcapp.run`（FC 自带域名），**没有自有域名**；veFaaS 也会给访问域名 |
| ❌ **CDN** | App 是 native，不走 CDN；Web 产物挂在 WorkBuddy 域名上（与云厂商无关） |
| ❌ **容器镜像仓库 CR** | 走**代码包**部署（veFaaS 代码包上限 256 MiB，我们的包远小于此）。用镜像才需要 CR |
| ❌ **NAS** | 照片走 TOS；函数临时磁盘 `diskSize` 够用 |
| ⭕ **Redis** | **可选** —— 仅当要解决 `AI_KV_DRIVER=memory` 那个配额逃生门时才需要（见 §4.4） |

### 9.5 火山**比阿里少要**的一样东西

阿里那边 `.env.prod` 里的 `FC_ROLE_NAME`（RAM 角色）**是为了让 FC 能在 VPC 里建 ENI** ——
火山把 VPC 直接配在函数上，**不需要这一层**。连带 `provision-fc-vpc-role.mjs`
与手写的 `aliyun-rpc.mjs` 一起退役。

### 9.6 ⚠️ 一处修正上一轮的说法

上一轮 §5 写「Web 应用函数**可能不需要** APIG」—— **不准确**。
从 veFaaS CLI 的部署流程看，Web 应用也要挂网关：

```
vefaas link --newApp <name> --gatewayName <gateway> -y
vefaas deploy -y
vefaas domains -o json        # 拿访问域名
```

⇒ **APIG 是必开的**（无论走事件函数还是 Web 应用函数）。
好消息是它**已经开通了**，只差子账号权限。

### 9.7 官方依赖清单（控制台文档口径，和上面实测互相印证）

创建 Web 应用函数的前提条件：

- 已开通**函数服务** + 首次使用需完成**跨服务授权** ← 对应动作 1
- (可选) 需访问 VPC → 已开通**私有网络**，并在函数所在地域建好 **VPC / 子网 / 安全组**
- (可选) 需查看日志 → 已开通**日志服务**
- (可选) 需通过 TOS 上传代码 → 已开通 **TOS**

⚠️ 官方把 VPC / TLS / TOS 标成「可选」，**那是通用口径**。
对本项目：**VPC 与 TOS 是必需**（库与照片），**TLS 也是必需**（网关没有日志等于瞎 ——
而且 09-30 17:4x 实测它**还没开通**，见 §9.3 动作 5）。
「可选」二字只说明「别的用法可以不配」，不代表我们可以不配。

### 9.8 一个顺带拿到的地基

`probe_volc_tos.mjs` 用**手写 SigV4**（只用 Node 内置 `crypto`）签通了 TOS：

```
service="s3"  + x-amz-content-sha256  →  HTTP 200   ✅ 签名通过且有权
service="tos"                          →  HTTP 400   AuthorizationHeaderMalformed
```

两件事同时被钉住：

1. **TOS 的 S3 兼容协议用 `service='s3'`**（不是 `'tos'`）—— 这正是 `tosimagestore.js` 要的答案。
2. **`x-amz-content-sha256` 带不带都行** —— TOS **不强制**它（AWS S3 是强制的）。

⚠️ 而且这个探测**自带对照**：两组参数给出不同结果，说明它真在测东西，
不是「永远返回成功」的空转判据。

### 9.9 怎么复核（命令）

```bash
set -a; source .env.volc.local; set +a
node probe_volc_service_activation.mjs --json volc_service_activation.json   # 各服务开通/权限
node probe_volc_tos.mjs                                                      # TOS（S3 协议，不走 OpenAPI）
node probe_volc_vefaas_functions.mjs --json volc_vefaas_functions.json       # 账号里到底有哪些函数
node probe_volc_perm_detail.mjs --json volc_perm_detail.json                 # 细粒度：策略清单 + 项目作用域对照
node probe_volc_project_scope.mjs --json volc_project_scope.json             # ⭐ 参数位置隔离实验：PROJECT=easy-learn 该放 query 还是 body
node probe_volc_tls_scope.mjs --json volc_tls_scope.json                     # ⭐ TLS（不走 TOP 网关，Action 在 path）+ CreateSubnet 补测
```

> ⭐ `probe_volc_project_scope.mjs` 的用法要点：**它的唯一变量是「参数放在哪」**。
> `--project easy-learn` 可换目标项目；判定靠"同一服务不带项目 vs 带项目是否翻转"。

---

## 9.10 ⭐ 权限的真相：**策略早就挂好了，卡的是「作用到了哪个项目」**

> 09-30 17:2x 的细粒度复跑。**它推翻了本节 15:5x 那版的结论**
> （「子账号没权限，要去加策略」）—— 策略不但有，还一次挂了 6 条。
>
> ⚠️ **本节又在 17:3x 自我推翻了一次**：那句「`ProjectName` 不能推广」是**错的** ——
> 不是参数无效，是**我把参数放进了它不读的地方**（GET query vs POST body）。
> 见下面「更正」小节。**同一个错误形态在本文件里出现了两次，值得单独记住。**

### 一条意想不到的好探针

`iam:ListAttachedUserPolicies` —— **允许子账号列出自己挂了什么策略**。
（同服务下 `iam:ListUsers` 是 `AccessDenied`，就这条通。）⇒ **从此不必靠猜。**

### 实测到的策略清单

| 策略 | 作用范围 | 挂载时间（北京） |
|---|---|---|
| `RDSPGFullAccess` 云数据库 PostgreSQL 版管理员权限 | 项目 `easy-learn` | 17:06:53 |
| `TLSFullAccess` 日志服务（TLS）管理员权限 | 项目 `easy-learn` | 16:25:04 |
| `APIGFullAccess` API 网关（APIG）管理员权限 | 项目 `easy-learn` | 16:24:05 |
| `VPCFullAccess` 私有网络（VPC）管理员权限 | 项目 `easy-learn` | 16:22:12 |
| `AccessKeySelfManageAccess` | **全局** | 13:52:43 |
| `ArkFullAccess` 火山方舟 | **全局** | 13:52:43 |

⚠️ **清单里没有 `VeFaaSFullAccess`，可 veFaaS 的读和写都通过了**
（`CreateFunction` 回 `MissingParameter` = 鉴权已过、只差参数）。
⇒ **这份清单不完整**：`ListAttachedUserPolicies` 只列**直接挂在用户上**的，
**不含用户组继承来的**。
**别把「列表里没有」读成「没有权限」** —— 那会让排查方向整个跑偏。

### 决定性对照：只改一样东西

对 `vpc:DescribeVpcs`（已知被拒）逐个变体打：

| 请求形态 | 结果 |
|---|---|
| 原样（对照） | 🔒 `AccessDenied` |
| **query `ProjectName=easy-learn`** | ✅ **200** `{"Vpcs":[],"TotalCount":0}` |
| header `X-Volcengine-Project-Name` | 🔒 拒 |
| header `X-Volcengine-Project` | 🔒 拒 |
| query `Project=easy-learn` | 🔒 拒 |

⇒ 两件事同时钉住：① **「项目归属」就是决定因素**（唯一变量，一拒一通）；
② 参数名是 **`ProjectName`** 且必须在 **query** 里 —— 猜 header 那两种写法是白费力气。

### 🔴 更正：上一版那句「**不能推广**」是错的 —— 我自己踩的坑

本节 17:2x 那版写过「`ProjectName` 不能推广（APIG / RDS 加了也拒）」，
并据此让「把策略改成全局」。**这句已被推翻**，原因是**我传错了参数位置**：

| 服务 | 参数真正该放哪 | 我上一版放哪 |
|---|---|---|
| VPC `DescribeVpcs` | **GET query** | ✅ 蒙对了 |
| APIG `ListGateways` | **POST + JSON body**（文档原文「请求方式:POST」） | ❌ 塞进了 query |
| RDS `DescribeDBInstances` | **POST + JSON body**（示例 `Content-Type: application/json`） | ❌ 塞进了 query |

隔离实验（同服务、同 action、同凭据，**唯一变量 = 参数放在哪**）：

| 请求形态 | 结果 |
|---|---|
| APIG `GET` + query `ProjectName` | 🔒 `AccessDenied`（resource = `project/default`） |
| APIG **`POST` + body** `ProjectName` | ✅ **200** `{"Total":0,"Items":[]}` |
| RDS `POST` 空 body | 🔒 `AccessDenied` |
| RDS **`POST` + body** `ProjectName` | ✅ **200** `{"Instances":[],"Total":0}` |

⇒ **项目参数是管用的**，VPC / APIG / RDS 三家都管用。
⭐ 比结论更值钱的一条：**「拿到 `AccessDenied`」只证明「service/version/action 名对、鉴权没过」，
它证明不了「我把参数放对了地方」** —— 同一个坑我这轮在两个服务上各踩了一次。

### 带项目后的完整矩阵（09-30 17:3x 实测）

| 动作 | 不带项目 | 带 `ProjectName` | 读法 |
|---|---|---|---|
| VPC `DescribeVpcs` / `DescribeSubnets` / `DescribeSecurityGroups` | 🔒 | ✅ 200 | 读通 |
| VPC `CreateVpc` / `CreateSecurityGroup` | 🔒 | ✅ 鉴权过（回 `MissingParameter`） | 写通 |
| **VPC `CreateSubnet`** | 🔒 | 🔒 **仍拒（3 种形态全拒）** | ⚠️ **真缺口 —— 见下 ②** |
| APIG `ListGateways` | 🔒 | ✅ 200 | 读通 |
| **APIG `CreateGateway`** | 🔒 `AccessDenied` | 🔴 `ForbiddenOperation` | ⚠️ **服务未开通 —— 见下 ①** |
| RDS `DescribeDBInstances` / `CreateDBInstance` | 🔒 | ✅ 通 / 鉴权过 | 读写都通 |
| veFaaS `CreateFunction` | ✅ 鉴权过 | ✅ 鉴权过 | 本来就有权限 |
| IAM `ListProjects` | — | ✅ 200 | **项目确实存在**（`easy-learn`，Id `48955066`，建于 09-30 06:06） |

### ⚠️ 三条**与路线无关**的缺口（换哪条路都绕不开）

**① APIG 服务本身没开通** —— 不是权限问题。
带项目后它从 `AccessDenied` 变成了 `ForbiddenOperation: account 2109706933 has not authorized`
（**错误码变了 ⇒ 项目参数确实生效了**）。官方 `CreateGateway` 页「前提条件」原文：
「已开通 API 网关服务。若未开通，请登录 API 网关控制台，根据控制台向导提示，开通服务。」
veFaaS 官方 MCP 文档亦载：「生成公网访问 URL 需先开通 APIG」。
⇒ **动作：控制台开通 APIG。**

**② `vpc:CreateSubnet` 被拒** —— 三形态（GET 不带项目 / GET 带项目 / POST 带项目）**全拒**，
而同词的 `DescribeSubnets` 带项目**通过**；不带项目时它的 resource 是**空的**。

⚠️ **「为什么拒」仍未定性**（17:4x 补测后，两种解释都还活着）：

| 解释 | 支持它的事实 | 怎么才能证伪 |
|---|---|---|
| **(a) 策略少了这条 action** | 同族的 `CreateVpc` / `CreateSecurityGroup` 带项目都**过鉴权**，唯独它不过 | 主账号给它加一条显式 `vpc:CreateSubnet` 后重测 |
| **(b) 同样是项目归属，只是资源是「已存在的那个 VPC」** | 补上 `VpcId` 后 resource **变成可解析**（`trn:vpc:cn-beijing:2109706933:vpc/…`），说明鉴权确实去看那个 VPC 了 —— 而那个 VPC **不在 `easy-learn` 项目里**，项目级策略自然覆盖不到 | **先在 `easy-learn` 里建一个真 VPC，再拿它的 Id 重试**（这个 VPC 反正也要建） |

📌 **两种解释的处置不同**：(a) 要动策略，(b) 不用动、把 VPC 建在项目里就行。
⇒ **所以现在只能给绕法，不给结论**：**子网先用主账号在控制台建好**，函数部署时只引用
（🔴 建子网是「函数挂 VPC」的必需步骤，卡的是**两条路共用的那一段**）。

⚠️ 顺带一条探针纪律：上一版我把「GET 不带项目 / GET 带项目 / POST 带项目」称作
「三形态」，其实**只变了动词和位置、没变那个真正被授权的资源**。
**变量选错 ⇒ 实验做得再整齐也得不出结论。**

**③ TLS 坐标仍未撞对**（`InvalidActionOrVersion`）—— **这条没结论**，
别把「探不动」写成「没开通」。

### 所以该做什么 —— 两条路**都成立**，取舍如下

| | 路线 A：**策略作用范围改「全局」** | 路线 B：**指定 `easy-learn` 项目** |
|---|---|---|
| 策略要动吗 | 动 4 条：项目 → 全局 | **不用动**（现在就是这么挂的） |
| 调用方要求 | 无 | **每处调用都要带 `ProjectName`，且位置要对**（GET→query / POST→body） |
| 漏带的后果 | — | 403，**和"真没权限"完全同形**（我这轮就误判了一次） |
| 工具链 | 与工具链无关 | Serverless Devs `volcano-vefaas` 组件是否暴露该字段 **未验证** |
| 权限面 | 覆盖账号内所有项目 | 收敛在项目内（最小权限） |

**路线 A 的动作**：控制台 → 访问控制 → 用户 → `easylearn` → 权限 → **项目权限** →
该策略 →「修改作用范围」→ **全局**。

**建议**：求「少踩坑」→ **A**；求「最小权限」→ **B**，但要接受
「每处调用都得带对参数」这个**持续约束**。

✅ **验收判据（两条路通用）**：重跑
`node probe_volc_project_scope.mjs` —— 看 `APIG` / `RDS-PG` 两组的
「不带项目」与「带项目」**是否都为 ✅**。
⚠️ **别把「控制台点了确认」当判据。**

### 顺带修正一处**端点**错误

```
rds_postgresql.cn-beijing.volcengineapi.com   → ENOTFOUND     ← 下划线，**不存在**（我猜错了）
rds-postgresql.cn-beijing.volcengineapi.com   → 111.62.119.228 ✅ **连字符才对**
```

⚠️ 而**签名用的 service 名仍是 `rds_postgresql`（下划线）**——
见被拒消息里的 `rds_postgresql:DescribeDBInstances`。**域名连字符、service 名下划线**。

更值钱的是它暴露的**判据污染**：上一轮那条「RDS = AccessDenied」是老脚本
`hostsFor()` **回退到通用端点 `open.volcengineapi.com`** 拿到的，**并非 RDS 专属端点**。
⇒ 教训：**「拿到了业务层错误」≠「打对了端点」** —— 通用端点照样会回业务层错误。

⚠️ **开通 + 授权做完后必须重跑** —— 判据从 `ServiceNotActivated` 变成 200 才算数，
**不要用「控制台里点了确认」当判据**。同理反过来：**这表可能已经过时**（§9.1.1 实例），
**引它之前先重跑一次**。

**三个脚本各自回答不同的问题**（别用一个代替另一个）：

| 脚本 | 回答 |
|---|---|
| `probe_volc_service_activation.mjs` | 产品**开没开通**、子账号**有没有权限** |
| `probe_volc_vefaas_functions.mjs` | 账号里**实际有哪些函数**、什么形态、有没有触发器 |
| `probe_volc_tos.mjs` | TOS 能不能访问（要走 S3 协议，OpenAPI 那条路探不到） |
| `probe_volc_project_scope.mjs` | 项目参数**该放 query 还是 body**（同服务对照） |
| `probe_volc_tls_scope.mjs` | TLS（**不走 TOP 网关**）+ `CreateSubnet` 补测 |

---

## 10. 全量上火山、不用阿里云：**还缺什么**（2026-09-30 17:4x 实测汇总）

> 回答的就是这句话本身。**这节是收敛结果，前面九节是它的证据。**
> ⚠️ 所有「已开通 / 有权限」的结论**都有保鲜期**（§9.1.1 当天变过两次）—— 动手前重跑 §9.9。

### 10.0 一句话

> **产品层全齐了（6/6 已开通 —— 09-30 19:00 复跑），缺的是 1 条权限 + 5 个资源 + 1 段没写过的代码 + 1 张要搬的数据。**
> 真正的工作量不在「开通」，在**资源创建、数据搬迁、火山版部署工具链**这三块。
> 🔴 **最新一次盘点在 §10.9**（19:00），本节其余小节保留 17:4x 的原始证据。

### 10.1 ✅ 已经齐了的（别再动它）

| 块 | 状态 | 判据（09-30 17:4x 复跑） |
|---|---|---|
| **方舟大模型** | ✅ 开通且有权 | `ListEndpoints` 200；`lite-260915` 三链路端到端全绿 |
| **函数服务 veFaaS** | ✅ 开通，**读 + 写都过鉴权** | `ListFunctions` 200；`CreateFunction` 回 `MissingParameter` |
| **私有网络 VPC** | ✅ 带 `ProjectName` 读写都通 | `DescribeVpcs` 200 / `CreateVpc` 过鉴权 |
| **云数据库 PostgreSQL** | ✅ 带 `ProjectName` 读写都通 | `DescribeDBInstances` 200 / `CreateDBInstance` 过鉴权 |
| **对象存储 TOS** | ✅ 开通且有权（账号下 **0 个桶**） | S3 协议 200（§9.8） |
| **API 网关 APIG** | ✅ **已开通**（19:00 复跑） | `ListGateways` POST+body `ProjectName` → 200；`CreateGateway` → `InvalidParameter`（越过开通检查） |
| **日志服务 TLS** | ✅ **已开通**（19:00 复跑） | `tls-cn-beijing.volces.com` `DescribeProjects` / `DescribeTopics` → **200** |
| **IAM 项目 `easy-learn`** | ✅ 存在（Id `48955066`，建于 09-30 06:06） | `iam:ListProjects` 200 |
| **策略** | ✅ **6 条早就挂齐**，作用域限在 `easy-learn` 项目 | `iam:ListAttachedUserPolicies` |

⇒ **不需要再「加」任何策略。**（⚠️ 那份清单**不含用户组继承的**，所以它是下界不是全集。）

### 10.2 ✅ 缺「开通」：**0 个**（09-30 19:00 已清空）

~~APIG · TLS 两个未开通~~ —— **19:00 复跑时两个都已开通**，原文对照见 **§9.1.3**。
⇒ **开通侧没有任何待办。**

下面保留 17:4x 那次的原始判据，因为它们是**「未开通长什么样」的样本**，
下一个新账号 / 新环境一定会再遇到一次：

| 服务 | 当时回什么（= `未开通` 的形状） | 现在的样子（19:00） |
|---|---|---|
| API 网关 APIG | `403` `ForbiddenOperation: account 2109706933 has not authorized` | `400 InvalidParameter`（越过了开通检查）+ `ListGateways` 200 |
| 日志服务 TLS | `403` `AccessDenied`「**The account does not open tls service.**」 | **`200`**（`DescribeProjects` / `DescribeTopics`） |

⚠️ 两个都要**读到 `Message` 才看得出来**：一个走 `ForbiddenOperation`，一个走 `AccessDenied`。
**光看错误码会把 TLS 那个读成「子账号没权限」，然后把时间花在改策略上。**

### 10.3 🔴 缺「资源」：5 个（都在 `easy-learn` 项目里建）

| # | 资源 | 在哪建 | 备注 |
|---|---|---|---|
| 1 | **VPC + 子网 + 安全组** | 控制台（主账号） | 🔴 `CreateSubnet` 用子账号建不了（§9.10 ②，**机理未定性**）⇒ 子网老实走控制台 |
| 2 | **RDS-PG 17 实例** | 控制台或 OpenAPI（读写在子账号手里） | 现网是 **18.4**；`sql/001_schema.sql` 声明的目标本来就是 **17**（§4.2）。⚠️ **个人实名账号可能开不了 RDS-PG**（MySQL 有开放公告、PG 没有）⇒ 先读 **§12**，别急着换引擎 |
| 3 | **TOS 桶** | 控制台或 S3 API | 照片；若 Web 产物也放进来则再加一个 |
| 4 | ⭕ **Redis / 表格存储**（可选） | 控制台 | 只为了关掉 `AI_KV_DRIVER=memory` 那个逃生门（§4.4） |
| 5 | ✅ **`easy-learn-ai-api`（已被确认是虫子建的）** | — | 控制台默认 Go 模板：`native/v1`、**触发器 0**、无 VPC、无日志、`ProjectName=easy-learn`。**和本仓库要发的 `easy-learn-ai` / `easy-learn-data` 不撞名**，留着不碍事，但要**知道它不是我们的产物** |

> ⭐ 第 5 条顺带证实一件事：**控制台建资源时会把它放进 `easy-learn` 项目**
> ⇒ §9.10 那条「路线 B：都指定 `easy-learn` 项目」**在操作层面是成立的**，
> 不是纸面推理 —— 这个函数就是活样本。

### 10.4 🟡 缺「代码」：6 件（真工作量 60% 在这）

| # | 要写的 | 为什么不能照抄 | 现成的东西在哪 |
|---|---|---|---|
| 1 | **`s.yaml` 重写** | `component: fc3` → 火山；`logConfig` → `TlsConfig`；`vpcConfig` 字段名全换（数组） | §4.1 的字段级对照表 |
| 2 | **事件形状适配** | 两个硬未知（`isBase64Encoded` 请求/响应两侧）——**只有走事件函数才需要** | §3；走 Web 应用函数可整段跳过 |
| 3 | **TOS 存储驱动** | TOS 的 V4 ≠ OSS 的 V4（**AWS 必签 host**） | 上层可复用：`buildStorageKey` / `validateUpload` / 接口形状 |
| 4 | ⭐ **火山版部署工具链** | `run-s.mjs` / `deploy-prepare.mjs` / `deploy-check.mjs` **全是阿里云的**：灌 `.env.prod`、清代理、构造暂存树、`s deploy` —— 一个都用不上 | `@volcengine/openapi` 已验证可直调 `CreateFunction` / `UpdateFunction`（本轮所有探测都是它）；**`volcano-vefaas` 组件是否可用仍未验证** |
| 5 | **`.env.prod` 换值** | 数据库连接串 / `IMAGE_DRIVER=tos` / `region` / `AI_*`（方舟那六行已改，**未部署**） | §3.8 |
| 6 | **客户端重构建** | 只改 `--dart-define`，**源码一行不动**（§1 第 1 环） | `tools/` |

**退役清单**（换云省下来的）：`serverless/scripts/aliyun-rpc.mjs` ·
`serverless/scripts/provision-fc-vpc-role.mjs` · `s.yaml` 里的 `FC_ROLE_NAME`（§9.5）。

### 10.5 🔴 此前**方案里空白**的一块：数据搬迁

前面九节一个字都没写这件事，而它是「不用阿里云」的硬前提 ——
**库和照片都在阿里云上，且历史数据是要永久保留的。**

| 搬什么 | 从 | 到 | 现成工具 | 缺口 |
|---|---|---|---|---|
| **业务数据**（26 表） | 阿里云 RDS-PG 18.4 | 火山 RDS-PG 17 | ⚠️ **没有**。`build/` 下只有 `migrate-diag.mjs` / `_purge-account.mjs`（按账号删），**没有全库导出** | 要写一个 dump/restore；`sql/010` 建表脚本**不能替代**——那是空库 |
| **照片** | OSS | TOS | ⚠️ **没有** | 要写搬运 + 校验 |

🔴 **搬迁的两条硬要求**（写工具前先钉住）：

1. **存储键必须逐字不变** —— 键是 `buildStorageKey` 单点生成的，历史行里存的就是那个键。
   搬运时**改一个字符，所有历史照片全裂**，而且**只在打开那张照片时才看得见**。
2. **判据只能是「对账」，不是「脚本 EXIT=0」** ——
   行数对不上 / 随机抽 N 张照片真取一次并比对字节，才算搬完。
   （这个项目在阿里云那边反复栽在「部署成功 / 配置正确」这两句上。）

⚠️ 另外这次搬迁**顺带修一次历史的欠账**：`homework` 表**没有** `created_at`（只有
`due_at` / `submitted_at` / `checked_at`）—— 照直觉写 `order by created_at` 会在**连上库之后**才报错。

### 10.6 要拍板的 6 件事（每件都会反过来改上面的清单）

> ✅ **已经拍掉的一件（不用再讨论）：运行时 = Node.js on veFaaS。**
> 2026-09-30 虫子的决定：**不考虑 Deno** ⇒「改 TS/Deno」与「走 AIDAP Supabase 版的
> Edge Function」两条路**同时关闭**（实测数据留在 §11 当档案）。
>
> 📌 **最硬的一条依据是代码自己写的**：`serverless/ai-gateway/README.md` 的部署段里，
> **第一顺位就是 veFaaS** —— 注释原文「火山引擎函数服务 veFaaS / 运行时 **Node.js 20+**、
> 入口 `index.cjs`、触发器：**API 网关，路径 `/ai/*`**」；阿里云 FC 反而列在**后面**，
> 且注明「事件形状一致，**不需要改代码**」。
> ⇒ **所以这不是「迁到一个新平台」，是回到代码本来就是为它写的那个平台** ——
> veFaaS + APIG + `node20/v1` 是**原配**，阿里云那段是当年的一次绕行。
>
> **代价 = 0**：现有 15,353 行代码**一行不用改**，`node20/v1` 正是 veFaaS 官方运行时之一。
>
> ⚠️ 这条的意义不只是省事：走 Deno 那条路的**真实代价不是运行时**，而是
> **重写 RLS 身份口径（25 张表 FORCE RLS）+ 重建连接池容量模型（isolate 会打爆 RDS 上限）
> + 重做全部判据链**（§11.3）。本项目刚在「判据不可信」上栽过（B27 / B29），
> **判据链是资产，不是可抛弃的脚手架** —— 为换运行时丢掉它，是拿最贵的东西去换最便宜的。

1. **架构选型**：事件函数（要攻 §3 两个未知）还是 **Web 应用函数**（推荐，§5）
2. **项目归属路线 A / B**：策略改「全局」 vs 处处带 `ProjectName=easy-learn`（§9.10 表）
3. **`reasoning` 档正式值**：现在挂的还是临时的 `lite`，而它扛 `reviewJudge`（错题毕业的判据）
4. **KV 要不要接真共享存储**（决定 §10.3 第 4 项要不要建）
5. **Web 产物挂哪**：TOS 静态站点 + CDN，还是保持现状（现状与云厂商无关，可以不搬）
6. **切换窗口**：双跑多久、什么时候关阿里那套（§7 第 9 步）

### 10.7 ⭐ 本轮新学到的一条（与「还缺什么」无关，但下次一定再遇到）

**有些火山产品不走 TOP 网关**，它们的**调用约定和错误结构都不一样**：

| | TOP 网关产品（VPC / RDS / APIG / veFaaS…） | **不走网关**（TLS / TOS） |
|---|---|---|
| 域名 | `<svc>.<region>.volcengineapi.com` | `tls-cn-beijing.volces.com`（TLS）· `tos-cn-beijing.volces.com`（TOS） |
| Action 放哪 | **query**（`?Action=X&Version=Y`） | **path 上**（`/DescribeProjects`），`Action`/`Version` 反而可空 |
| 签名 service 名 | 小写产品名（`vpc` / `rds_postgresql`） | **`TLS` 大写** · TOS 用 **`s3`** |
| 必须签的头 | `host;x-content-sha256;x-date`（+ body 时的 `content-type`） | TLS：**额外必须签 `content-type`**（`application/x-www-form-urlencoded; charset=utf-8`） |
| 错误长什么样 | `ResponseMetadata.Error.{Code,Message}` | ⚠️ **没有 `ResponseMetadata`**，是 `{"ErrorCode":…,"ErrorMessage":…}` |

🔴 **后果**：小写 `tls` + 缺签名头 ⇒ **`403 AuthorizationQueryParametersError`**；
按 TOP 的结构去解析它 ⇒ 读出「**无码**」⇒ 卡在「未探明」上不去了。
我此前 5 条 TLS 探针全折在这一步，**并且当时把 `InvalidActionOrVersion` 读成了「坐标没撞对」就收工**。

> 📌 可复用的读法：`InvalidActionOrVersion` 有两种含义 ——
> ① 我参数写错了；② **这家产品的调用约定根本不同**。
> 停在 ① 就会得出「探不动」，而真相在 ②。
> 判据：**同域名的另一个「故意写错」的 action 也回 404** ⇒ 说明这条路根本没接上，
> 别在这里继续试参数，去查「它到底走不走网关」。

### 10.8 最小可发布路径（把所有条件串起来）

```text
0. 提交那 68 项未提交改动            ← 与换云无关，但线上产物全来自这份未提交代码
1. ✅ ~~控制台：开通 APIG + TLS~~      ← **09-30 19:00 复跑已全部开通**（§9.1.3），跳过
2. 控制台：建 VPC/子网/安全组 · RDS-PG 17 · TOS 桶 ·（可选 Redis）
      → 全部选 easy-learn 项目        ← §10.3（5 件）
3. 拍板 §10.6 的 6 件事
4. 写火山版部署工具链（替代 run-s.mjs）   ← §10.4 第 4 项，最容易被低估
5. 建库 → 跑 10 个迁移 → **probe-rls.mjs 验越权**（判据是行为，不是「迁移成功」）
6. 写 tos 驱动 + 搬照片（**键逐字不变**）
7. 重写 s.yaml → 发两个函数 → 逐个探 /health
8. **搬业务数据 + 对账**                ← §10.5，方案里此前空白
9. 重构建客户端 + Web 产物
10. 双跑对账一段时间，再关阿里那套
```

⚠️ 第 5–8 步**别并行**：库 / 桶 / 函数 / 数据是四段独立依赖，中间任何一步「看起来成了」
都要用**行为判据**确认。

⚠️ **`GetFunction` 只认 POST + JSON body**（参数名是 `Id`，不是 `FunctionId`）。
带 query 的 GET 会回 `MissingParameter: The request is missing Function Id parameter.`
—— 这个报错会把人引向「参数名写错了」，而真因是**动词错了**。实测 2026-09-30，
已封装在 `probe_volc_vefaas_functions.mjs` 里。

### 10.9 ⭐ 19:00 复跑：回到 **veFaaS + APIG** 这条路，还差什么

> 这是回答「当前环境还差什么」**最新的一次实测**（09-30 19:00）。
> 三次复跑（15:39 → 17:4x → 19:00）里，**开通侧每一轮都在变**，所以下面每个数字都带时间戳。

**一句话：开通侧已经归零；还差的是「1 条权限 + 5 个资源 + 代码 + 数据」。**

| 类别 | 现状（19:00 实测） | 还差 |
|---|---|---|
| **开通** | ✅ veFaaS · APIG · TLS · TOS · VPC · RDS-PG **全部开通** | **0 件** |
| **权限** | ⚠️ 项目作用域：不带 `ProjectName` 一律 `AccessDenied`；`vpc:CreateSubnet` 四形态全拒 | **2 件**（见下） |
| **资源** | 🔴 VPC **0** · 子网 **0** · 安全组 **0** · TOS 桶 **0** · RDS-PG **0** · 我们的函数 **0** | **5 个资源** |
| **代码/配置** | 🟡 `s.yaml` 仍是阿里云形态；无 TOS 驱动；`run-s.mjs` 是阿里云包装器 | **6 件**（§10.4） |
| **数据** | 🔴 方案里此前空白 | **2 段搬迁**（§10.5） |
| **判据** | 🟡 `deploy-check.mjs` / `build-mode.mjs` 都是阿里云口径 | 待重做 |

**权限侧那 2 件（这是现在真正的阻塞）：**

1. 🔴 **`vpc:CreateSubnet` 缺 action** —— 不带项目 / 带项目 / GET / POST **四种形态全拒**，
   补上 `VpcId` 后**仍然拒**，而 `DescribeSubnets` 通过 ⇒ 与项目归属无关，是**策略本身少了这条**。
   👉 绕法：**子网用主账号在控制台建**，函数部署时只引用 `subnet_ids`。**不挡发版。**
2. ⚠️ **项目作用域**：6 条策略里 4 条 FullAccess 限在 `easy-learn` 项目，而调用默认落 `default`。
   两条路都成立 —— **A** 改成「全局」/ **B** 每处带 `ProjectName`（位置按接口：GET→query、**POST→body**）。取舍见 §9.10。

**资源侧那 5 个**（§10.3）：VPC + 子网 + 安全组 · RDS-PG 17 · TOS 桶 ·（可选 Redis）。
⚠️ 全部选 **`easy-learn` 项目** —— 这不是纸面推理：账号里那个 `easy-learn-ai-api` 的
`ProjectName` 就是 `easy-learn`，**控制台建资源时会落进你选的项目**。

**函数侧**：账号里现在 **1 个函数，不是我们的**（`easy-learn-ai-api`：`native/v1`、Go 控制台模板、
`TriggersCount: 0`、`VpcConfig.EnableVpc: false`、`TlsConfig.EnableLog: false`）。
本仓库 `s.yaml` 期望的 **`easy-learn-data` / `easy-learn-ai` 一个都还没有**。
⚠️ 它还缺触发器 / 日志 / VPC —— 也就是**它现在连入口都没有**，别把它当成"已经有函数了"。

**现在就能动的两件（不依赖任何讨论）：**
1. 主账号在控制台建 **VPC + 子网 + 安全组**（选 `easy-learn`）—— 顺带把第 1 条权限缺口绕过去
2. 建 **TOS 桶** + **RDS-PG 17 实例**

**被卡住、需要先拍板的**：§10.6 的 6 件事（架构选型 / 项目路线 A·B / `reasoning` 档 / KV / Web 托管 / 切换窗口）。
✅ **运行时不在其中** —— 已锁定 **Node.js on veFaaS**（「不考虑 Deno」，§10.6 开头 / §11）。

✅ **验收判据**（别用「控制台点了确认」当判据）：

```bash
cd D:/workbuddy-project/projects/easy_learn_db
set -a; source .env.volc.local; set +a
node <工作区>/probe_volc_project_scope.mjs   # 看 VPC/APIG/RDS 三组的「带项目」是否都为 ✅
node <工作区>/probe_volc_tls_scope.mjs       # 看 TLS 是否仍 200，且对照组（错 action）仍 404
node <工作区>/probe_volc_vefaas_functions.mjs # 看函数清单里有没有多出 easy-learn-data / easy-learn-ai
```

---

## 11. ⛔【已否决 · 留档备查】把后端改成 TS/Deno 的代价（2026-09-30 实测）

> 🔴 **决策（2026-09-30，虫子）：不考虑 Deno。本路线关闭，不再是候选方案。**
> **为什么还要留着这一节**：里面的数字是**真机测出来的**（Node ↔ Deno 双向对账、
> 移植面逐项量化）。将来若再有人提「换个运行时 / 上 BaaS / 100% 兼容 Supabase」，
> **不用重测**，直接读 §11.3 那张表。
> ⚠️ **别把本节读成「两条路选一条」** —— 它是**档案**，不是选项。
> 现行路线见 §5（veFaaS 上跑现有 Node 代码，架构选型只讨论「事件函数 vs Web 应用函数」）。
>
> 起因：有人提出「走火山 Supabase 版（AIDAP）的 Edge Function，运行时是 Deno + TS」。
> 本节把「代价」从**估计**变成**测量**——最大的不确定性已经真机跑过了。

### 11.0 现状：**是 Node.js，不是 Python**

| 项 | 实测 |
|---|---|
| 运行时 | **Node.js 20+ / ESM**（两个 `package.json` 都写 `"type": "module"`、`engines.node >=20`） |
| 业务代码 | **15,353 行**（ai-gateway/src 5,394 · data-service/src 9,108 · shared 851） |
| 测试 | **10,862 行**（ai-gateway/test 4,134 · data-service/test 6,728） |
| 入口 | 两个 **`index.cjs` 五行垫片** → `import('./src/handler.js')`。**没有编译步骤、没有打包** |
| **生产运行时依赖** | **只有 `pg`**。`ai-gateway` **零第三方依赖**（全局 `fetch` 直调方舟 + 手写 TOS V4 签名） |
| devDependency | `embedded-postgres`（本地开发库，不上云） |
| TypeScript | **0 个 `.ts` 文件**、仓库里没有 `tsconfig.json` |
| Deno | 0 个 `deno.json` / `import_map.json` |
| Python | **只出现在 `build/`（patch 脚本、`score_ocr.py` 判分探针）与 `ios/`（Flutter 生成的 lldb helper）—— 不在请求路径上** |

业务面：data-service **75 条路由**（`/auth/*` 7 条 + `/data/*` 68 条）· ai-gateway **14 条**（`/ai/*` 8 个）
· **25 张表** · `app.js` 里 `ROUTES` 数组 + 精确整串匹配。

### 11.1 先更正一处：「不是 Python」是错的

火山「**AI 原生 BaaS 平台 Supabase 版**」（产品线叫 AIDAP）**确实存在**，
「100% 兼容 Supabase 开源用法」。官方原文两条：

- Edge Function **「基于火山引擎 veFaaS 函数服务构建」** ⇒ 底下的权限/开通结论（§9）**继续适用**。
- 「用户可以在其中编写、部署和运行 **JavaScript（Deno）或 Python** 的代码」
  ⇒ 🔴 **Python 也是一个选项**。那份描述里「运行时：Deno + TypeScript（**不是 Python**）」**不成立**。
- 「Edge Function 可以直接调用 Supabase 的其他服务，**无需额外配置密钥**」。

约束页（`docs.volcengine.com/docs/87275/2228232`）能拿到的数字：
单分支 Edge Function **≤500 个** · Storage 单文件默认 **50 MB** · 日志保留 **30 天** · 单个分支共享公网带宽 **100 Mbps**。

🔴 **没拿到**：执行时长 / 内存 / CPU / Deno 版本 / 请求体上限。
`使用 Edge Function` 那页是 JS 渲染的，抓不到正文正文 ⇒ **列入必须实测项**，不许推断。

### 11.2 ⭐ 已经测出来的：Node ↔ Deno **双向对账全绿**

这一条本来是最贵的风险（迁移当天在线 token 集体失效 / 老用户口令验不过），现在是零。
探针 `probe_deno_compat.mjs` 直接 import **真实模块**（`shared/token.js`、`data-service/src/password.js`），
在 **Node 22.22.2** 与 **Deno 2.9.6** 之间双向对账：

| 对账项 | Node→Deno | Deno→Node |
|---|---|---|
| HMAC-SHA256 逐字节相同 | ✅ | ✅ |
| SHA256 逐字节相同 | ✅ | ✅ |
| `Buffer` base64url 一致 | ✅ | ✅ |
| **验对方签发的会话 token** | ✅ | ✅ |
| └ 解出的身份逐字段相同（sub/role/sid） | ✅ | ✅ |
| **验对方产生的 scrypt 口令哈希** | ✅ | ✅ |
| **反面：错口令仍被拒** | ✅ | ✅ |

```bash
node probe_deno_compat.mjs --emit node.json
deno run --allow-read probe_deno_compat.mjs --verify node.json     # 再反向跑一次
```

⇒ `node:crypto` / `Buffer` / `base64url` 在 Deno 下**零改动通过**，连 `scrypt` 的 callback 风格与
`maxmem` 参数都一致。**「要不要重写 crypto 那一层」这个问题被关掉了。**

### 11.3 代价在哪（按贵到便宜）

| # | 项 | 代价 | 说明 |
|---|---|---|---|
| 1 | 🔴 **RLS 身份口径重写** | **最贵 · 且是安全机制** | 25 张表 `FORCE ROW LEVEL SECURITY`，policy 全部读 `current_setting('app.user_id')` / `current_setting('app.visible_students')`（`002_rls.sql` 155 行用 DO 循环给全表挂上；代码里 13 处引用）。Supabase 的标准是 **`auth.uid()`**，而**你的 `visible_students`（家长可见集合 = active 状态的孩子）在 Supabase 里没有对应物** —— 它正是 **B22（解除结伴靠它静默变空）生效的机制**。这不是改函数名，是动核心安全模型，且**没有自动化判据能兜住** |
| 2 | 🔴 **连接池口径失效** | 高 | 现网 `pg.Pool(max=PG_POOL_MAX 默认 5, idleTimeoutMillis 30s)` + 一套算过的口径（`实例上限 ×（PG_POOL_MAX+PG_AUTH_POOL_MAX）< max_connections`）。Edge Function 是**无状态 isolate**，会横向拉起很多实例 ⇒ **实例数 × 每 isolate 一个池**会打爆 RDS 连接上限。Supabase 的标准答案是走连接池代理（Supavisor）。**要重建容量模型，不是调数字** |
| 3 | 🟡 **部署链 + 判据链重做** | 中 | `s.yaml` / `deploy-prepare.mjs` / `run-s.mjs` / `deploy-check.mjs` / 打包判据（≥20KB/≥10 条目）/ `build-mode.mjs` 发版闸门**全部失去意义**；换成 `byted-supabase-cli` + Edge Function 目录形态 + Secrets。**判据要重跑**：10,862 行服务端测试 + 803 个 Flutter 用例 + 那套「证伪」纪律 |
| 4 | 🟡 **客户端也要改** | 中 | Flutter 现在打 `/data/*`、`/ai/*` + 自家 token。走 Supabase = 它的客户端 SDK + anon key + JWT ⇒ `DatabaseService.cloud` 与 **`AiIdentity.resolve`** 那套取票逻辑要重做（⚠️ 硬约束 2：另建一份 = 票写进 A 从 B 取，**本地全绿、只有网关 401**） |
| 5 | 🟢 **代码本身（Node→Deno）** | **小** | 零第三方依赖（除 `pg`）+ 已在用全局 `fetch`/`AbortController`/`setTimeout` ⇒ 见 §11.2。`fs`(`migrate.js`) / `child_process`(`pg-local.js`) / `node:http`(`dev-server.js`) **全在本地开发工具里，不在函数内跑，根本不用管**；`process.env`（33 处）要换成平台 Secrets 的注入方式 |
| 6 | 🟢 **JS→TS** | **免费** | Deno 直接吃无类型 JS。15,353 行全是 ESM，`import/export` 与 TS 语法完全兼容 ⇒ **改扩展名就能跑**，类型可以之后慢慢加。而且类型这件事可以**在 Node 上原地做**，不必和迁移绑一起 |

### 11.4 必须先回答的宿主问题

Edge Function **是不是正确的宿主**？

- AI 网关跑的是**30 秒超时**的批改（批改/视觉档覆盖 30s、判定走 `judgeTimeout` 20s）。
  上游 Supabase 的墙钟上限是 400 s，CPU 时间是另一条更紧的线 ⇒ **看起来装得下**，
  但 🔴 **火山版的数字没拿到（§11.1），必须实测**。
- 三件在 isolate 模型下会变的事：**进程内网关缓存**（现在同 body 第二次 10ms）**直接失效**；
  **keep-alive 连接复用**行为不同；照片几 MB base64 进请求体要算限额。
- ⚠️ 「封装掉 APIG/VPC」的代价是**看不见的东西更多** —— 而本项目刚在这个方向上栽过
  （「从推断出发」的教训 + 静默失败清单）。

### 11.5 一句总结

- 「Node → Deno」：**小**（§11.2 真机对账已全绿）。
- 「JS → TS」：**免费**。
- 真正的问题是第三件事：那条路的本质是「**自建后端 → 托管 BaaS**」。
  Supabase 版给的四个模块（Database / Auth / Storage / LLM）**只覆盖 75 条路由里的一小部分**；
  剩下 60 多条业务路由（作业、复习、积分、愿望、学习计划、锻炼、聊天、通知）
  **还是得自己写进 Edge Function**。

⇒ **所以这不是「换个运行时」，是「换地基 + 搬 15k 行 + 重写 RLS + 重建连接池 + 重做判据」。**

⇒ 🎯 **这就是「不考虑 Deno」的依据**：能便宜拿到的只有「JS→TS」那一项（而它**在 Node 上原地也能做**，
不必和迁移绑一起，见 §11.3 第 6 条），要付出的却是**安全模型 + 全部判据链**。
**拿最贵的换最便宜的，不划算。**

### 11.6 未验证项（不许推断，只能实测）

| 项 | 为什么没结论 |
|---|---|
| 火山版 Edge Function 的 Deno 版本 / 超时 / 内存 / CPU / 请求体上限 | 文档页 JS 渲染，正文抓不到 |
| AIDAP Supabase 版在**本账号**是否已开通 | 只知道它存在、需实名认证；**没探** |
| `npm:pg` 在 Deno 下能否建池 | 探针 `probe_deno_pg.mjs` 已写好，**未跑完** |
| Deno 下能否直接 import `data-service/src/app.js`（75 条路由那层） | 未测 |

### 11.7 ⛔ 若将来重开这条线，先跑这三条（**现在不跑 —— 随本路线一起封存**）

1. 探 **AIDAP Supabase 版的开通状态**（口径同 §9：`Error.Code` 分类，不看状态码）。
2. 拿到 **Edge Function 的真实限制数字**（控制台或实测），与 30 s 批改超时对齐。
3. 把 **`app.js` 整个 import 进 Deno** 跑一遍 —— 唯一的第三方依赖 `pg` 就在这一层。
   （探针 `probe_deno_pg.mjs` 已写好但**未跑完**；`probe_deno_compat.mjs` 与两份
   `deno_compat_*.json` 对账产物也在工作区，全部**只归档、不删** —— 它们是已花掉的钱。）

---

## 12. ⚠️ 如果换掉 PostgreSQL（个人账号可能开不了 RDS-PG）

> 起因：虫子反馈「**个人用户不能在火山引擎创建 PostgreSQL**」，问「换成 MySQL 工作量是否大」。
> 本节回答三件事：① 前提有没有依据 ② 换 MySQL 的真实代价 ③ 有没有更便宜的路。
> ⏱ 状态（2026-09-30 19:3x）：**只做了代码级盘点 + 官方文档核查 —— 没动一行代码、没建任何资源。**

### 12.1 前提核查：**成立，而且有官方依据**

| 产品 | 对个人实名用户开放？ | 依据 |
|---|---|---|
| **云数据库 MySQL 版** | ✅ **开放** | 官方公告 `2024-06-06`：「云数据库 MySQL 版**已面向个人用户开放**，个人用户在注册账号并完成个人实名认证后，即可使用」；地域限 **华北2(北京)/华东2(上海)/华南1(广州)** |
| **云数据库 PostgreSQL 版** | ❌ **没找到任何对应公告** | 反复检索，**无**「面向个人开放」声明 |
| **ECS（通用型）** | ⚠️ **大概率可以（未钉死）** | 官方「购买并使用云服务器实例」的前提**只写**「完成账号注册和实名认证」；规格页只对 **GPU / HPC 部分族**标 `Available for individual users = No` |

🔴 **一个必须点破的坑**：`volcengine.com/docs/6438/1265267` —— **PG 的文档路径下，正文是 MySQL 的开放公告**。
那是**公告 ID 被跨产品复用**（同一个 `1265267` 在 `/docs/6313/` 下是 MySQL 的），
**不是**「PG 也面向个人开放」的声明。
⚠️ 所以「我在 PG 文档页里看到它面向个人开放」是一条**会把人引向错误结论的观察** —— 判据要看**公告归属哪个产品**，不看它在哪个路径下显示。

⚠️ 另有一条**与"个人/企业"无关、但同样会挡住创建**的门：
**按量计费要求「账户余额 + 代金券 ≥ 100 元」**（RDS 与 ECS 都是这条口径）。
若控制台报的是余额不足，那**换 MySQL 是无用功** —— 见 §12.5。

### 12.2 换 MySQL 的代价 = 机械替换 ＋ 安全模型拆除（两块性质完全不同）

**块一：机械替换（有量、可预期、可批量）**

| 项 | 数量 | 说明 |
|---|---|---|
| `$N` → `?` 占位符 | **274 个** / 分布在 **19 个文件** | 可正则批量，但要逐条验 |
| SQL 迁移文件 | **1,374 行** / 10 个 | 类型与语法都要改 |
| `.query()` 调用点 | **131 处**（12 个路由文件 + 基础设施） | 最密：`review.js` 28 · `homework.js` 14 · `points.js` 10 |
| 驱动 | `pg` → `mysql2` | `db.js`（**525 行**）基本重写；`setTypeParser` → `decimalNumbers` |
| `RETURNING` | **4 处** | **MySQL 没有** ⇒ 要改 `LAST_INSERT_ID()` + 回查；而 **R2 硬约束**要求「写接口返回的那行**必须被采纳**」⇒ 返回值语义要**重新证伪** |
| `ON CONFLICT` | **3 处** | 含**条件冲突目标**：`ON CONFLICT (idempotency_key) WHERE idempotency_key <> '' AND reversed_at IS NULL` —— MySQL 的 `ON DUPLICATE KEY UPDATE` **不支持条件冲突目标** ⇒ **语义级不兼容，不是写法问题** |
| partial unique index | 1 处（`idx_user_session_alive … WHERE revoked_at IS NULL`） | MySQL 8 **不支持 partial index** ⇒ 要用生成列 + 唯一索引绕 |
| `DO $$` 匿名块 | **7 个** | MySQL 要 `DELIMITER` + 存储过程 |
| `timestamptz` | **47 处** | MySQL **没有带时区的时间类型** ⇒ `due_at` / `submitted_at` / `checked_at` 的**时区语义会变**，而且这是**静默**的 |
| `boolean` / `uuid` / `jsonb` | 13 / 2 / 1 | 落到 `tinyint(1)` / 无原生类型 / `JSON`（函数不同） |
| 错误码 | — | `23505` → `ER_DUP_ENTRY(1062)`；**`42P10`、`57P01`、`57P02`、`57P03` 无对应** ⇒ `translateDbError()` 分支要重建 |

**块二：隔离机制拆掉（贵，且没有对应物）**

25 张表是这么挂上的（`sql/002_rls.sql`，用 `FOREACH … LOOP` + 单独 8 张）：

```sql
FOREACH t IN ARRAY ARRAY['homework','workout_plan','workout_record','review_mistake',
  'review_paper','judgement_ab','review_attempt','ai_practice_question','explain_record',
  'review_summary','wish','study_plan','study_plan_checkin','daily_comment','point_rule',
  'point_ledger','homework_image'] LOOP
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    -- CREATE POLICY own_rows ON %I USING (current_setting('app.visible_students') …)
END LOOP;
```

| 事实 | 数字 / 后果 |
|---|---|
| `FORCE ROW LEVEL SECURITY` | **25 张表** |
| `CREATE POLICY own_rows` | **15 个** |
| `current_setting('app.visible_students')` | **37 处引用** |
| **MySQL 有 RLS 吗** | ❌ **没有**（MariaDB 才有） |
| ⇒ 隔离必须搬到应用层 | **131 个 query 调用点**里凡读业务表的，**全部要显式加 `WHERE student_id IN (…)`** |

🔴 **三条不会报错的后果**（这才是真正贵的地方）：

1. **`SET LOCAL` 没有对应物。** PG 用 `set_config(…, true)` 把身份限定在**事务**内、出事务自动失效
   （`db.js` 开头 30 行专门写这件事）。MySQL **只有会话级 `SET`** ⇒ 连接池复用会**串上上一个人的身份**，
   症状「A 偶尔能看到 B 的数据」，**单请求测试永远串不出来**。
   这**正是本项目已经解决过的坑**，换 MySQL 等于**把它重新打开**。
2. **两道启动自检全部失效。** `assertRlsEnforced()`（防「拿超级用户连库 ⇒ RLS 静默失效」）与
   `assertAuthRoleScoped()`（防「鉴权角色多授权 ⇒ 一片表不受隔离」）**都建在 PG 的
   `pg_roles` / `pg_class` / `has_table_privilege` 上**。MySQL 没有这两个概念可断言 ——
   而它们防的恰恰是**「安全机制静默失效」**，本项目最贵的一类 bug。
3. **失败方向反转。** 底线第 4 条写着 RLS 的价值是「**忘写 where 从越权降级为查不到**」。
   去掉 RLS 后方向反过来：**忘写 = 真的越权**，而且**不报错**。

**块三：判据链重做。** 23 个测试文件 / **10,862 行**，其中 **11 个跑真 PG**；
`scripts/probe-rls.mjs`（越权判据）失效。按「证伪」纪律，改完要**重新证伪一遍**。
⚠️ 且这次更难：**没有 RLS 可以断言了** —— 隔离的正确性**只能靠人逐个 query 看**。

### 12.3 判定：不是「工作量大不大」，是**性质变了**

- 只算语法 + 驱动：**中等**（274 占位符 · 19 文件 · `db.js` + 10 个迁移重写）—— 这是**能估人天**的部分。
- 加上「RLS → 应用层 where」：**大**，且**风险不对称** —— 改错一处 = 一处越权，**不会报错**。
- 加上「判据链重做 + 一段无人能断言的隔离」：**很大**。

⇒ **一句话：换 MySQL 是拿「安全模型降级 + 全部判据重做」，去换「个人账号能开」这一个资格。**

### 12.4 ⭐ 可替代方案：**ECS 自建 PostgreSQL —— 代码 0 改动**

既然卡的是「**托管型 RDS 对个人不开放**」，那**不换数据库、换托管方式**就行：

| | **A. ECS 自建 PG 17** ⭐ | **B. 换 RDS MySQL** | **C. 库留在阿里云** |
|---|---|---|---|
| 代码改动 | **0**（只改连接串） | 🔴 大（§12.2） | **0** |
| RLS（25 表） | ✅ **全保留** | ❌ **拆掉** → 应用层 where | ✅ 全保留 |
| `SET LOCAL` 事务身份 | ✅ | ❌ 无对应物 | ✅ |
| 判据链 | ✅ **全保留**（含 `probe-rls.mjs`） | 🔴 重做 + 重新证伪 | ✅ 全保留 |
| 版本一致性 | ✅ 与本地开发同为 **PG 17** | ❌ 换引擎 | ✅ |
| 运维 | ⚠️ **自理**（备份/高可用/补丁/监控） | ✅ 托管 | ✅ 托管 |
| 违背「不用阿里云」 | 否 | 否 | ✅ **是** |

**A 的代价只有运维** —— 而本项目的库是家庭作业数据（量小、无合规压力），
单机 PG 17 + 定时 `pg_dump` + 盘快照够用。
**B 的代价是安全模型** —— 一个**不会报错、只能靠人看**的东西。

⇒ **建议 A**：ECS（通用型，选 `easy-learn` 项目）装 PG 17，函数走 **VPC 内网**连它。
⚠️ 前提是 **ECS 通用型确实对个人开放** —— 证据较强（官方快速入门只要求注册 + 实名）但**未钉死**，
**请在控制台确认**（§12.5）。

### 12.5 🔴 动手之前先确认一件事（它可能让本节整段作废）

「个人用户不能创建 PostgreSQL」有**几种成因**，而处置**相反**：

| 控制台报的 | 真因 | 处置 |
|---|---|---|
| 「个人实名用户不支持该产品」 | 产品级限制（本节前提成立） | 走 §12.4 的 A 或 B |
| **余额 / 代金券 < 100 元** | 按量计费门槛（**所有 RDS 与 ECS 都要**，与 PG 无关） | **充值即可，不用换库** |
| 「未完成私有网络服务访问授权」 | 少 VPC 跨服务授权 | 授权即可，不用换库 |
| 「该规格不可售 / 无库存」 | 规格级问题 | 换规格，不用换库 |

⚠️ **别跳到「那就换 MySQL」** —— 若真因是余额或授权，**换 MySQL 同样建不出来**，
而你已经为它付了 §12.2 的全部代价。
⇒ **请把控制台报错原文贴给我**，再决定。

### 12.6 本节**没做**的事（避免把它读成结论）

- **没建任何资源**（没试创建 PG / MySQL / ECS）。
- **没动一行代码** —— §12.2 的数字全部来自**代码盘点**，不是改完之后的实测。
- **没验证**：ECS 通用型对个人的可购性（控制台级）· RDS MySQL 在本账号的可达性。
  后者可用现成探针补测（把端点 `rds-postgresql` 换成 `rds`，口径同 §9.10）。

**以上整块已于 2026-09-30 20:0x 随阶段 1 一并作废。** 见 §13。

---

## 13 【2026-09-30 20:0x 拍板】回到阿里云，模型留方舟 —— 混云形态

### 13.1 决定

用户原话：

> 火山引擎除了大模型外，它的数据库、函数这块都不方便，我们还是回到之前的阿里云方案。
> 但是考虑下从阿里云调用火山引擎的大模型这个可能性。

拆成两句，处置相反，**必须分开执行**：

| | 决定 | 依据 |
|---|---|---|
| **基础设施**（计算/数据库/存储） | ⛔ **留在阿里云** | 已上线、已调好、零风险。本文 §1–§12 的搬迁评估**全部作废** |
| **大模型** | ✅ **用火山方舟** | 这不是新方案 —— **阶段 0 本来就是这个**，且 `.env.prod` 早已切好（`volcengine-migration-plan.md` §3.8） |

⇒ 所以用户要的形态**不是「新造一个」，而是「把阶段 0 部署掉、把阶段 1 划掉」**。
本文档（及 §12 换 MySQL 那一整块）自此只作**留档**。

### 13.2 要的形态长什么样

```
Flutter 客户端 ──HTTPS──┐
                        ├─→ [阿里云 FC3 · 杭州]  easy-learn-data ──VPC内网──→ RDS PG 18.4
                        │                       easy-learn-ai   ──┐        OSS（公网域名）
                        └──────────────────────────────────────┘
                                                                  │
                                             公网 HTTPS（跨云）    ↓
                                        ark.cn-beijing.volces.com/api/v3
                                                （火山方舟）
```

**只有最后那条箭头是新增的**，其余全是现网已在跑的东西。

### 13.3 可行性：四层，逐层给判据（不是从方案推的）

#### ① 协议层 —— ✅ **零代码改动**，因为早就抽象好了

| 事实 | 判据（可复核） |
|---|---|
| 网关请求形态是 **OpenAI 兼容**：`POST {baseUrl}/chat/completions` + `Authorization: Bearer` | `src/ark.js:240-252` |
| 方舟的字段/语义差异（`thinking` 对象 · `tool_choice` 可传对象 · 不序列化嵌套结构）**已建表** | `src/config.js:188` `MODEL_PROVIDERS.ark` |
| **默认值本来就是方舟** —— 不配 `AI_MODEL_PROVIDER` 就是它 | `src/config.js:263` `DEFAULT_MODEL_PROVIDER = 'ark'` |
| 切换有断言盯着请求体形态，不是「应该能行」 | `test/provider-switch.test.js` |

⇒ 换回方舟 = **改环境变量**，不是改代码。

#### ② 网络层 —— ✅ **已就绪，且不需要新建任何网络资源**

关键在 `s.yaml` 里这条**给 `ai-gateway` 单独写的**注释（不是通用模板）：

> 📌 **这里刻意没有 vpcConfig** —— 不是因为漏了，是网关**不需要**进 VPC。
> 网关不碰数据库……它唯一要连的外部服务是**百炼的公网 API**。
> 而配 VPC 的代价是**冷启动变慢**（官方原话「建议非必要勿配置」）。
> —— `s.yaml:293-299`（`internetAccess: true` 在 `:291`）

⇒ **需要调模型的只有 `ai-gateway`，而它恰好是唯一一个「不配 VPC、纯公网」的函数。**
这次只是把它出网的目的地从百炼换成方舟 —— **同一条路，同一个开关，不用动**。

⚠️ 但「声明」不等于「事实」。好在**「FC 能出公网」这件事本项目已经实测过**：
`s.yaml:111-137` 记着用 `probe-vpc-path.mjs` 从库侧读到 `app_auth` 的**源 IP 是公网地址**
（`true` 时三个且每次变：`47.96.186.143` / `121.43.100.251` / `118.31.10.23`；
`false` 时稳定为 VPC NAT 网关 EIP `120.26.102.18`）。
⇒ **`internetAccess: true` 会让函数从 FC 共享出口出去，这是实测值不是推断。**

**一个反直觉的推论**：因为这个函数**不配 VPC**，它反而比 `data-service` 更自由 ——
`data-service` 的出入取决于 `PGHOST` 解析到什么，而 `ai-gateway` 没有这层纠葛。

#### ③ 端点层 —— ✅ 实测两个地域都通（2026-09-30，真凭证）

探针：`probe_ark_dual_region.mjs`（工作区）。`.env.prod` 里那把 Key、三档模型、两个地域各打一遍：

| 地域 | vision | reasoning | light | `tool_choice` 传**对象** |
|---|---|---|---|---|
| `cn-beijing` | ✅ 200 | ✅ 200 | ✅ 200 | ✅ 200，`tool_calls=1` |
| **`cn-shanghai`** | ✅ 200 | ✅ 200 | ✅ 200 | ✅ 200，`tool_calls=1` |

两条**此前不知道**的事实：

1. ⭐ **`ark.cn-shanghai.volces.com` 对同一把 Key 可用** —— 不需要迁账号地域。
2. ✅ `tool_choice` 传对象**确实生效**（`tool_calls=1`，不是「200 但被忽略」）——
   这复核了那条唯一的功能性分叉（百炼 `toolChoiceObjectAllowed: false`）。

⚠️ 另有两条**别误读**的观察：

- 不带 `tools` 时，同一只 `lite` 模型耗时会到 **18s / 22–35s**；带上工具约束后回到 **~1s**。
  ⇒ 这是**我探针的人为产物**（生产路径 `src/ark.js:80` 恒带 `tools`，且 `shouldSendToolChoiceObject`
  对方舟恒为 `true`）—— **不要拿它当模型慢的证据**。
  但它顺带解释了一个老现象：**`tool_choice` 一旦退成 `'auto'`，耗时就会掉进 20s+ 的档**。
- 这些耗时是**长沙→X**，**不能外推杭州 FC 的延迟**。本探针只证明「端点存在且可达」。

#### ④ 出口 IP 层 —— ✅ 不构成阻塞（但**不要开**白名单）

方舟官方把 **IP 调用白名单**列为 API Key 的**可选**能力（「启用 IP 白名单后，仅添加至白名单的 IP 地址可调用模型」）。

- **不启用** ⇒ FC 那个**动态**出口 IP 完全无影响 ⇒ 当前形态成立。
- **一旦启用** ⇒ 必须给函数配 **NAT 网关 + EIP + SNAT**（官方口径），
  也就是把 `internetAccess` 翻成 `false`、走 `s.yaml` 里那个已实测过的 `120.26.102.18`。
  ⚠️ 那会**同时断掉 OSS 的公网域名**（同一条出网路），且 NAT/EIP 是**额外计费项**。

⇒ **建议：不要给这把 Key 开 IP 白名单。** 它的收益（防 Key 被盗用）可以用「Key 只授权方舟项目 + 定期轮换」替代。

### 13.4 代价（这才是要拍板的部分）

| # | 代价 | 严重度 | 处置 |
|---|---|---|---|
| 1 | **`AI_PRICE_*` 六个值仍是百炼单价** ⇒ 成本看板**算错** | 🟡 **静默**（不报错、只是数字不对） | 从方舟控制台抄单价覆盖；`.env.prod` 已标红 |
| 2 | **两笔账单**（阿里云 + 火山），余额各自独立 | 🟡 运维面 | 方舟设余额告警 —— 欠费的表现是 `401`，会被读成「Key 失效」 |
| 3 | **故障域变两个云**，排查要跨两家控制台 | 🟠 真痛点 | 已有对冲：`src/ark.js:235-238` 的报错文案**跟着 config 走**（不写死厂商名）。⚠️ 那条注释正是为这类问题写的 |
| 4 | **学生作业照片/文本出阿里云**，到火山方舟 | 🟠 合规判断 | 两家都是境内持牌；但**数据处理者 +1**。这条只能由用户拍板 |
| 5 | 方舟成**唯一模型来源** | 🟢 已被对冲 | **逃生门 = 把 `AI_MODEL_PROVIDER` 改回 `bailian`**。百炼那条路已实测可用（`volcengine-migration-plan.md` §3.5/§3.7），切回是**改环境变量** |

**关于延迟 —— 我判断它不是问题，理由是量级**：

网络 RTT 是 **25–35ms** 量级，而模型推理是 **1–35 秒**量级，**差三个数量级**。
项目里那句「跨地域几十毫秒会逐次叠加」说的是**同区内**的数据库往返（一次批改要查很多次库），
模型调用**不适用**：一次批改调模型的次数是个位数。

⚠️ 但这不等于「部署完不用看」—— **它是本形态唯一一次真跑才能拿到的数字**，见 §13.5。

### 13.5 🔴 唯一的缺口：这条路径**从来没跑过**

`volcengine-migration-plan.md` §3.8 末尾自己写着：

> ⚠️ 那两条**只证明配置合法**。「模型能调通」目前在**本地网关**证明过（§3.7，同一把 Key、
> 同一只模型），**但「从阿里云 FC 出去调方舟」还没验证** —— 那是部署后才知道的事。

按本项目纪律，**没跑过的验证不算通过**。所以 §13.3 的四层论证再完整，也只是**把缺口收窄到了一条**
—— 不是把缺口填上了。两条补法，**任选其一**：

| | 做法 | 影响面 | 拿到什么 |
|---|---|---|---|
| **A（外科手术）** | 建一个一次性探针函数（同 region/nodejs20，代码就一句 `fetch(方舟端点)`），调一次，**跑完即删** | **不碰生产** | 只回答「FC 能不能到方舟」+ 杭州侧延迟 |
| **B（一次到位）** | 直接把 `ai-gateway` 按 `.env.prod` 部署（= 阶段 0 的部署） | **切换线上模型** | 上面全部 + 真实链路延迟 + 三档真实可用性 |

⚠️ **走 B 之前必须先做 `volcengine-migration-plan.md` §3.8「部署前必做」那三条**，
其中两条会**静默出错**：`AI_PRICE_*`（成本看板）与 reasoning 档临时值（扛着 `reviewJudge`）。

### 13.6 上海 vs 北京：建议**保持 `cn-beijing`**

上海端点既然实测可用（§13.3 ③），理论上杭州 FC → 上海更近。**但建议不切**：

1. 收益是**几十毫秒**，而模型推理是秒级 ⇒ **被完全淹没**（§13.4 的量化）。
2. 成本是**引入地域不确定性**：北京是官方文档的主推地域、也是本账号实测最充分的一条；
   上海目前只有本探针一条证据，**没有长期可用性承诺**。
3. 它当前**写死在 `s.yaml:311`**（不是 `${env()}`）⇒ 改它要改部署描述，而 `s.yaml` 的
   注释反复警告「同一个事实两份真值」—— 现在两边一致（`cn-beijing`），是**省事的状态**。

📌 真到了「模型延迟成为体感瓶颈」那天再切 —— 那时才值得为它做一次对照测量。

### 13.7 本节的证据链（可复核）

| 结论 | 怎么验的 |
|---|---|
| 协议层零改动 | 读 `src/config.js:188,263` · `src/ark.js:63,240` · 看 `test/provider-switch.test.js` 存在 |
| 网络层已就绪 | 读 `s.yaml:291,293-299,111-137`（含 `probe-vpc-path.mjs` 的历史实测值） |
| 端点可达 + 上海可用 + `tool_choice` 对象生效 | `probe_ark_dual_region.mjs`（工作区）· 真凭证 · 两地域 × 三档 |
| 端点存在性（无凭证旁证） | `curl` 打两个端点均回 **401**（不是 404/DNS 失败） |
| FC 出公网是既有事实 | `s.yaml:111-137` 记录的三个动态源 IP |
| 「没跑过」 | `volcengine-migration-plan.md` §3.8 末尾自述 |
| 阿里云侧地理（全杭州） | `s.yaml:52` `region: cn-hangzhou` · RDS 前缀 `bp1` · `OSS_ENDPOINT=oss-cn-hangzhou` |

**本节没做的事**：没建任何资源 · 没改一行代码 · 没部署 · 没验证 §13.5 那条路径（**这是刻意的**，
它需要用户拍板走 A 还是 B）。

