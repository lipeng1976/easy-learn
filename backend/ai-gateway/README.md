# AI 网关（easy-learn-ai-gateway）

把 Flutter 客户端的一次 AI 请求，转成火山方舟的模型调用。

**存在的唯一理由**：模型 API Key 不能进客户端产物。Web 端会编译进 JS（打开控制台就能抄走），
移动端可反编译提取 —— 这不是「有风险」，是几天内必然被扫号脚本捞走，账单失控且查不到是谁用的。

```
Flutter 客户端 ──(X-Student-Id / 自己的 token)──▶ 本服务 ──(ARK_API_KEY)──▶ 火山方舟
                                                   │
                                                   ├─ 鉴权：谁在调用
                                                   ├─ 配额：每人每日**成本额度**
                                                   ├─ 缓存：相同输入不重复计费
                                                   ├─ 审计：谁在什么时候花了多少
                                                   ├─ 看板：用量与成本从审计聚合（只读端点）
                                                   └─ 降级：结构化输出校验失败就快速失败
```

## 零依赖

`dependencies` 是空的。只用了 Node 内置的 `node:crypto` / `node:http` 与全局 `fetch`（Node 20+）。
理由很实际：Serverless 冷启动要装依赖会显著拉长首次响应，而这里需要的外部能力只有
「发一个 HTTP 请求」和「算一个 HMAC」。

## 目录

```
src/
  handler.js      平台入口 + 事件归一化（veFaaS / SCF / FC 形状一致）
  router.js       路由、信封、CORS、配额前置检查
  handlers.js     六个业务端点 + 上传签名
  config.js       环境变量 → 配置；能力开关的真实状态
  errors.js       错误码（协议的一部分，改它要同步客户端）
  schema.js       结构化输出契约（同一份定义供 function calling 与运行时校验共用）
  prompts.js      各能力的系统提示词
  ark.js          火山方舟客户端：三级模型路由、tool calling、超时重试
  mock-model.js   确定性假模型，仅供本地联调与测试
  model-client.js 按配置装配 ark / mock
  guard.js        鉴权、配额（成本权重）、缓存、审计
  store.js        KV 抽象：内存（默认）/ HTTP 共享 KV
  metrics.js      用量与成本看板：从审计事件聚合，不另开埋点
  auth.js         会话 token 签发与校验（HMAC + 明文载荷）
  tos.js          火山引擎 TOS V4 预签名（PUT / GET）
  media.js        图片载荷归一（内联 base64 / 对象存储 URL）
  uploads.js      上传签名与（proxy 模式的）内存对象存储
  dev-server.js   本地 http 服务器
scripts/
  probe-ark-catalog.mjs     模型目录探查：**本账号**开通了哪些、该往 ARK_MODEL_* 填哪个（首次接入先跑它）
  probe-ark.mjs             三级模型真凭证探活（已知模型 ID 后验通道：鉴权 / 结构化输出 / usage 字段）
  issue-session-token.mjs   签发会话 token（AI_REQUIRE_AUTH=true 时用）
  probe-tos.mjs             真凭证验证 TOS 直传签名
  probe-ollama.mjs          本机 Ollama 适配探测（tool calling 与读图实测）
  e2e-local-homework.mjs    本机模型的**业务链路**验收（四条链路各自对着客户端超时看）
  verify-ocr-identity.mjs   拍照识别的**身份链路**验收（占位符/缺头/真实学号，四种情形）
  measure-handwriting-ocr.mjs  **手写识别率**实测（字迹为唯一变量，按任务级算召回）
  probe-ocr-tasks.mjs       把 OCR 返回的 `tasks` **原样摊开**看（拆没拆干净、有没有带耗时）
  make-homework-photos.ps1  生成验收用的作业照片（Windows 自带 .NET 绘图，不联网）
  make-handwriting-samples.ps1  生成四档工整度的手写样本（逐字抖动/旋转/基线漂移）
  fixtures/                 上面那些照片里的作业文本（UTF-8）
examples/
  kv-server.mjs            可跑的共享 KV 示例（验证多实例配额与缓存）
  local-model-stub.mjs     最小的 OpenAI 兼容端点（验「接本机模型」这一层）
index.cjs         CommonJS 平台入口垫片
test/             node --test，219 条
```

## 环境变量

### 模型（必填）

| 变量 | 默认 | 说明 |
|---|---|---|
| `AI_MODEL_PROVIDER` | `ark` | ⭐ **选厂商，也是唯一的切换方式**：`ark`（火山方舟）或 `bailian`（阿里云百炼）。见下 |
| `ARK_API_KEY` / `BAILIAN_API_KEY` | 空 | 各家的模型 API Key。**只在这里出现**，不进任何返回体与日志 |
| `ARK_REGION` | `cn-beijing` | 见下方「区域」。**只有方舟用**，百炼端点固定 |
| `ARK_BASE_URL` / `BAILIAN_BASE_URL` | 按厂商 | 改它就能换后端，见「接本机模型」 |
| `ARK_MODEL_VISION` / `BAILIAN_MODEL_VISION` | 空 | 视觉档模型 ID（作业识别 / 手写批改） |
| `ARK_MODEL_REASONING` / `BAILIAN_MODEL_REASONING` | 空 | 强推理档模型 ID（判定 / 讲解 / 出题） |
| `ARK_MODEL_LIGHT` / `BAILIAN_MODEL_LIGHT` | 空 | 轻量档模型 ID（解析 / 格式化） |
| `AI_MODEL_CLIENT` | `ark` | `ark`（真实模型，OpenAI 兼容协议）或 `mock`。**`mock` 只用于联调** |
| `AI_MODEL_TIMEOUT_MS` | `25000` | 单次模型调用超时 |
| `AI_MODEL_MAX_ATTEMPTS` | `2` | 只对传输层失败重试（429/5xx/超时） |
| `ARK_THINKING_DISABLED_KINDS` / `BAILIAN_THINKING_DISABLED_KINDS` | 空 | **各家一份**：关掉思维链的路由名（逗号分隔，`*` = 全部）。见下 |
| `ARK_PRICE_*` / `BAILIAN_PRICE_*` | 空 | **各家一份**的单价（元/千 token），只喂成本看板。见下 |

### 换模型厂商（`AI_MODEL_PROVIDER`）

⭐ **切换 = 改这一个变量 + 重新部署。** 两家的配置**同时存在、互不覆盖**：

```
方舟那一组   ARK_API_KEY · ARK_REGION · ARK_MODEL_* · ARK_PRICE_* · ARK_THINKING_DISABLED_KINDS
百炼那一组   BAILIAN_API_KEY          · BAILIAN_MODEL_* · BAILIAN_PRICE_* · BAILIAN_THINKING_DISABLED_KINDS
```

> 📌 2026-09-30 之前只有**一组通用槽**（`ARK_API_KEY` / `ARK_MODEL_*` / `AI_PRICE_*`），
> 于是「换厂商」实际要改 5–10 个值、**覆盖掉上一家的**，切回来还得再改一遍 ——
> 开关是有的，但它不是「只改一个配置」。分开之后才是。
>
> 旧的单套写法**仍然有效**（本家那一组为空时回退到 `ARK_*` / `AI_PRICE_*` /
> `AI_THINKING_DISABLED_KINDS`）。但若打算两套并存，请填各自的 ——
> 是否发生了回退，看 `/ai/health` 的 `modelProviderEnvFallbacks`（正常是 `[]`）。

请求形态是 OpenAI 兼容的，所以换厂商**看起来**只是换 baseUrl、Key、模型名三样。
但有三处差异**藏在协议之外**，照抄过去不会报「你配错了」，只会静默做错：

| | `ark`（方舟） | `bailian`（百炼） |
|---|---|---|
| baseUrl | `ark.<region>.volces.com/api/v3` | `dashscope.aliyuncs.com/compatible-mode/v1` |
| 关思维链的字段 | `thinking: { type: 'disabled' }` | `enable_thinking: false` |
| `tool_choice` 能否传对象 | 始终可以 | **思维链开着时不行**（会 400） |
| 会不会把嵌套结构**序列化成字符串** | 不会 | **会**（实测 4/4） |
| 关思维链的名单 | 只需省时间 | **必须更长**（补偿上一条限制） |

`tool_choice` 那条是真正的陷阱：本项目靠传对象**硬约束结构化输出**，
而百炼在思维链开启时只接受 `"none"` / `"auto"` —— 单看每一处都对，合起来就报错。
适配层只在**「百炼 + 思维链开着」**这一种组合下退成 `'auto'`，
其余情况照旧传对象，结构约束不丢。

⚠️ **模型名、思维链名单、单价都必须跟着厂商走**，而它们**不会报错**：
- 模型名两家**互不认** —— 配置自检在**两个方向**都拦（除非 `*_BASE_URL` 指向自建网关，
  那时"互不认"这个前提不成立，守卫会让路，否则本机 Ollama 那条退路会被堵死）。
- 思维链名单错了：百炼用短名单 → 硬约束悄悄降级、偶发 502；
  方舟用长名单 → 白关思维链，讲解变快但推理质量下降。
- 单价错了：接口全通、看板给出一个**格式完整、数值错误**的成本数字。

验证当前真的在用哪家、以及它**读的是哪一组变量**：

```bash
curl -s https://<网关域名>/ai/health | grep -E 'modelProvider|modelProviderEnv'
```

### 🔴 一条已被推翻的旧结论（别照着做）

> 旧笔记：「百炼**非流式**调用思考模式模型会被拒
> （`enable_thinking must be set to false for non-streaming calls`），而本网关正是非流式。」

**2026-09-24 真凭证实测推翻了它**：不发 `enable_thinking` 时思考照常跑
（`usage.reasoning_tokens` 有值）。真正被禁的只有
**「思考模式 + 对象/required 形式的 `tool_choice`」**。
所以上面那份名单的语义是「换回硬约束 + 省时间」，**不是**「否则会 400」。

**留空 = 该能力未开通。** 网关会如实回 `model_not_enabled`，
而不是拿一个便宜档的模型顶上 —— 用轻量档做错题判定会静默产生错判，
学生看到「上次写这个算对、这次算错」就会不信任整个 APP。

### 思维链开关（`AI_THINKING_DISABLED_KINDS`）

推理型模型默认会先写一段**思维链**再给结果，而思维链算在**出参 token** 里 ——
出题、讲解这种「本来就要写上千字」的链路会因此翻倍变慢。

2026-09-20 真方舟实测（客户端窗口 12s，`scripts/e2e-local-homework.mjs`）：

| 路由 | 思维链不关 | 关掉后 |
|---|---|---|
| `reviewExplain` 讲解 | 23.5s ❌ / 14.0s ❌ | **6.8s ✅** |
| `reviewPractice` 出题 | 10.4s ✅ / 15.9s ❌ | **6.3s ✅** |
| `reviewReferenceBatch` 批量参考答案 | 6.1s ✅ / 18.2s ❌ | **2.1s ✅** |
| `reviewJudge` 判定 | 2.9–4.1s ✅（思维链只有 21–84 token） | **不要关** |

超窗口的后果**不是报错** —— 客户端会安静地退回本地模板，
从外部看就是「讲解这个功能好像没用上 AI」。

三点必须一起记住：

1. **这是方舟特有的字段**，不是 OpenAI 兼容协议的一部分。网关指向本机
   Ollama / vLLM 时**必须留空** —— 那些服务收到不认识的字段可能直接 400，
   把「本机跑得好好的」变成「上线就全挂」。
2. **判定不要放进来**。它本来只花 21–84 个思维链 token，关掉省不下时间，
   而它的准确率直接决定错题是否毕业（判错一次的影响比多判一次大得多）。
3. **拼错的路由名会被启动自检拦下**。这类错误不会报错、只会静默不生效 ——
   表现为「我明明关掉了，讲解还是慢」，而排查方向会落到模型和网络上。

关掉思维链不影响输出结构：讲解的 schema 本来就要求 `steps` 逐步写出解法，
被去掉的是**模型给自己看的草稿**，学生看到的分步过程还在（实测四个用例全部通过 schema 校验）。

### 请求护栏

| 变量 | 默认 | 说明 |
|---|---|---|
| `AI_MAX_BODY_BYTES` | `6291456` | 请求体上限（6MB），超了直接 413 |
| `AI_MAX_IMAGES` | `4` | 单次最多几张照片 |
| `AI_MAX_IMAGE_BYTES` | `3145728` | 照片总体积上限（3MB，base64 解码后） |
| `AI_CACHE_TTL_MS` | `600000` | 结果缓存时长 |
| `AI_CACHE_MAX_ENTRIES` | `500` | 缓存条数上限（LRU 淘汰） |
| `AI_REQUIRE_AUTH` | `false` | 见下方「鉴权」 |
| `AI_AUDIT_LOG` | 开 | 设 `off` 关闭调用日志 |
| `AI_MAX_REFERENCE_BATCH` | `20` | 单次批量取参考答案的条数上限 |

### 配额（按成本权重，不是按次数）

阈值按**成本单位**计，每级能力有一个权重：

| 变量 | 默认 | 说明 |
|---|---|---|
| `AI_QUOTA_UNITS_PER_DAY` | `200` | 每学生每日成本额度（单位） |
| `AI_QUOTA_UNITS_PER_MINUTE` | `120` | 每学生每分钟成本额度（防脚本刷） |
| `AI_WEIGHT_VISION` | `8` | 视觉档单次消耗 |
| `AI_WEIGHT_REASONING` | `2` | 强推理档单次消耗 |
| `AI_WEIGHT_LIGHT` | `1` | 轻量档单次消耗 |

**为什么按成本算而不是按次数**：一次拍照批改（视觉模型）和一次文本解析
（轻量模型）单价差一个量级，按次数算等于让最贵的那类调用享受和最便宜的
一样的额度 —— 额度看起来还在，账单已经翻倍。

对外报的是**换算后的次数**（`/ai/health` 的 `quota.dailyCalls`）：阈值本身按单位算，
但对学生说「你还有 24 个单位」毫无意义，他不知道一次批改要几个单位。

两处自检会在**启动时**直接抛错，因为它们的失败方式都是静默的：

- **`AI_QUOTA_UNITS_PER_DAY` 小于最大权重** → 那一档一次都跑不了，
  表现出来是「这孩子一次拍照批改都不行」，而不是任何一条错误日志。
- **配了旧的 `AI_RATE_PER_STUDENT_PER_*`** → 它现在**不再生效**。
  继续接受它等于让运维以为限流还开着，实际配额已经换了口径。
  启动时直接报错并给出新变量名。

### 成本看板

配了单价才会报成本；没配就只报用量。

| 变量 | 默认 | 说明 |
|---|---|---|
| `AI_PRICE_VISION_IN` / `AI_PRICE_VISION_OUT` | 空 | 视觉档单价（元 / 千 token） |
| `AI_PRICE_REASONING_IN` / `AI_PRICE_REASONING_OUT` | 空 | 强推理档单价 |
| `AI_PRICE_LIGHT_IN` / `AI_PRICE_LIGHT_OUT` | 空 | 轻量档单价 |
| `AI_PRICE_CURRENCY` | `CNY` | 展示币种 |
| `AI_METRICS_TOKEN` | 空 | 看板口令。配了之后 `/ai/metrics` 要求 `X-Metrics-Token` |
| `AI_METRICS_MAX_DIMENSIONS` | `40` | 看板维度基数上限（防高基数把内存吃光） |
| `AI_METRICS_LATENCY_SAMPLES` | `500` | 延迟分位保留的样本数 |

**单价按能力配，不按模型 ID 配**：当前是「一级能力一个模型」的一对一关系，
而模型 ID 带日期后缀、每次换代都要改配置 —— 漏改一次成本就是错的。

**只配一部分会被拒绝启动**（`partial` 状态）。理由：未配的那部分会被算成 0，
总额偏小，而这个偏小的数字看起来是完整的。

`AI_METRICS_TOKEN` 是**给运维工具用的**（curl / 内部看板）。
**不要把它放进客户端产物** —— Web 端编译进 JS 就能被抄走。
客户端侧「运行观察」页依赖常规身份校验，口令一旦配上它会收到 401，
那时正确的话术是「从运维侧查看」。

看板读 `/ai/metrics`（`GET` 或 `POST` 都行）：**要身份、不占配额** ——
运维看数据这件事本身不该吃掉孩子的批改额度。
响应字段与读法见 `doc/AI后端协议.md` §3。

### 共享 KV（多实例时才需要）

不配就退化成进程内存 —— 本地联调、单实例足够，**多实例上配额会成倍放大**。

| 变量 | 默认 | 说明 |
|---|---|---|
| `AI_KV_DRIVER` | `memory` | `memory` 或 `http` |
| `AI_KV_URL` | 空 | 共享 KV 的基址（仓库里有 `examples/kv-server.mjs` 可本地跑） |
| `AI_KV_TOKEN` | 空 | 访问令牌（`Authorization: Bearer`） |
| `AI_KV_TIMEOUT_MS` | `1500` | 单次 KV 调用超时 |
| `AI_KV_FAIL_MODE` | `open` | KV 故障时：`open`=记审计后放行（仅本地计数兜底）/ `closed`=直接 503 |

`open` 是默认值，理由是：KV 抖一下就把全体学生的 AI 停掉，代价比一次短暂的
配额放大高得多。但这是**业务选择**，不是技术定论，所以做成开关。

### 强鉴权（对外上线前必须开）

| 变量 | 默认 | 说明 |
|---|---|---|
| `AI_REQUIRE_AUTH` | `false` | 打开后只认 `Authorization: Bearer <token>`，请求头里的学号被忽略 |
| `AI_SESSION_SECRET` | 空 | token 签名密钥。**开了鉴权却没配它，网关启动即报错** |
| `AI_SESSION_TTL_SECONDS` | `43200` | 会话有效期（12 小时，约一个学习日） |

签发：

```bash
AI_SESSION_SECRET=xxx node scripts/issue-session-token.mjs stu_001
```

### 图片上传（可选）

内联模式（客户端默认）**不需要**配置这些。

| 变量 | 默认 | 说明 |
|---|---|---|
| `AI_UPLOAD_SIGNER` | `proxy` | `proxy`（网关自存，仅联调）或 `tos`（生产） |
| `AI_UPLOAD_URL_BASE` | 空 | proxy 模式下本服务的公网地址 |
| `AI_UPLOAD_SIGNING_SECRET` | 空 | 上传凭证签名密钥。**不要复用 `ARK_API_KEY`** |
| `AI_UPLOAD_TTL_SECONDS` | `600` | 凭证有效期 |
| `TOS_BUCKET` / `TOS_REGION` / `TOS_ENDPOINT` | 空 | TOS 配置（`TOS_ENDPOINT` 留空时按 `tos-<region>.volces.com` 拼） |
| `TOS_ACCESS_KEY_ID` / `TOS_ACCESS_KEY_SECRET` | 空 | TOS 凭证 |
| `TOS_OBJECT_URL_BASE` | 空 | 上传对象的公共读前缀（CDN 域名），用于给模型回一个能读的 URL |

**TOS 签名未经真实凭证验证**，先看这一条再决定用不用：

官方文档给出的两个签名示例**互相矛盾** —— 同一份示例里区域串一会儿是
`ap-southeast-1`、一会儿是 `tos-ap-southeast-1`，日期也在 `20220101` 与
`20220322` 之间混用，明显是复制粘贴留下的错误。没有可用的测试向量，
所以这里**没有伪造一个「看起来对」的单元断言**（那种断言只会让人误以为验过），
而是按官方公式实现，并把验证做成一条真凭证命令：

```bash
TOS_BUCKET=my-bucket TOS_REGION=cn-beijing \
TOS_ACCESS_KEY_ID=xxx TOS_ACCESS_KEY_SECRET=yyy \
node scripts/probe-tos.mjs put ./probe.txt
```

脚本会走完整链路：签名 → `PUT` 上传 → 再用 `GET` 读回（模型读图走的就是这条路）。
**退出码 0 才算通过**；403 表示签名串对不上，脚本会列出最常见的三个错处
（region 带没带 `tos-` 前缀、系统时间偏差、`CanonicalRequest` 的分隔符）。
只想看 URL 用 `node scripts/probe-tos.mjs url`。
在验证通过之前请用内联模式（默认）。

## 接本机模型（Ollama / vLLM / llama.cpp）

**不用改代码，只改环境变量。** 网关调模型走的是标准 OpenAI Chat Completions
协议：`POST {base}/chat/completions`、`Authorization: Bearer`、
`tools` + `tool_choice` 做结构化输出（`ark.js`）、多模态走 `image_url` 片段
（`media.js`）、参数是标准 JSON Schema（`schema.js` 的 `toTool`）。方舟只是这个
协议的一个实现，本地推理服务也都是 —— `ArkModelClient` 这个名字是历史原因，
里面**没有任何方舟私有逻辑**，换 `ARK_BASE_URL` 就是换后端。

```bash
# 用下面「选型实测」里验过可用的组合；换模型前先跑一遍那个探测脚本
ARK_BASE_URL=http://127.0.0.1:11434/v1 \
ARK_API_KEY=local \
ARK_MODEL_VISION=gemma4:26b \
ARK_MODEL_REASONING=qwen2.5:7b \
node src/dev-server.js
```

接着走这条路的话，「区域」与「开通清单（方舟侧）」两节都不适用。

四条**容易踩的配置项**：

1. **`ARK_API_KEY` 不能留空**，哪怕本机不校验。`capabilities()` 把「有 Key」
   当作能力可用的必要条件，留空会让三级能力全报 `model_not_enabled` ——
   症状是「网关起来了但一次都调不动」。填个 `local` 即可。
2. **没有的档位就留空，不要拿同一个模型名填满。** 只跑文本模型时
   `ARK_MODEL_VISION` 必须留空：网关如实回 `model_not_enabled`，客户端探到
   `capabilities.vision = false` 后**根本不发图**，直接走本地识别。
   把文本模型填进视觉档不会报错，它只会**编一份批改结果** ——
   而那份结果会进错题库、被组卷、被打印出来让孩子重做。
3. **单价（`AI_PRICE_*`）全部留空。** 本机推理没有单价，而 `pricingState`
   只接受「全配」或「全空」，只填一部分会在启动时直接报错（`validateConfig`
   里的自检是故意的）。留空后看板显示 `cost: null` + `pricing.state: none`，
   即「成本未知，仅有用量」—— 这是正确结果，不是缺功能。
4. **`ARK_REGION` 填什么都无所谓**：`ARK_BASE_URL` 一旦显式给出，region 就不再
   参与拼地址，健康检查里那个 `region` 只是个标签。

### 不下载真模型也能先验这一层

`examples/local-model-stub.mjs` 是一个最小的 OpenAI 兼容端点，它**照着请求里的
schema 合成结构合法的输出**（不是编业务数据）：

```bash
node examples/local-model-stub.mjs          # 127.0.0.1:8792
```

把它跑起来、`ARK_BASE_URL` 指过去，就能在花时间下载模型之前确认
「网关这一侧没有方舟特有的假设」。它顺带还是 `toTool()` 的廉价护栏：
哪天内部 schema 混进非标准 JSON Schema 字段，它会立刻解析不出来。
**它只回占位内容、不懂题目** —— 不要拿它的输出去评效果。

### 本机已装模型的选型实测

「本机有模型」和「本机模型能顶上网关的档位」是两件事。`scripts/probe-ollama.mjs`
把这件事测成一张表 —— 它**只测那件不可替代的事**：模型到底会不会按 `tools` 调函数。

```bash
node scripts/probe-ollama.mjs               # 测默认几个模型
node scripts/probe-ollama.mjs gemma4:26b    # 只测指定的
OLLAMA_BASE_URL=http://127.0.0.1:11434 node scripts/probe-ollama.mjs
```

判据是**实际行为**而不是 `capabilities`（理由见下面第 1 条）。
一台 12GB 显存笔记本（RTX 5070 Ti Laptop，空闲显存约 3.6GB）上的实测：

| 模型 | 产出 tool_calls | 单次判定耗时 | 读图 |
| --- | --- | --- | --- |
| `qwen2.5:7b` | 可用 | **4.2s** | ✗ 明确拒绝（HTTP 400 *does not support images*） |
| `gemma4:e4b` | 可用 | 12.7s | ✗ 声明支持，实际读不了（见第 1 条） |
| `qwen3-coder:30b` | 可用 | 25.1s | ✗ 同上 HTTP 400 |
| `gemma4:26b` | 可用 | 33.1s | ✓ 通过 |
| `deepseek-r1:14b` | **不可用** | 21.8s | ✗ HTTP 500 *image input is not supported* |

三条要一起看的判断：

1. **`capabilities` 会骗人，必须实测。** 两个反例都在上表里：
   - `deepseek-r1:14b` 的 `/api/show` 明明报了 `tools`，实际却回了 578 个 token 的
     思考过程、根本不调函数。推理模型把「想」和「调」写在同一个通道里，
     这类模型不适合做结构化输出。
   - `gemma4:e4b` 报了 `vision`（还带 `audio`），实际回答「我无法看到图片」。
     查 `/api/show` 能看到差别：`gemma4:26b` 有 **`projector_info`**
     （`clip.has_vision_encoder: true`），而 `e4b` 根本没有这个字段 ——
     **架构里声明了 `gemma4.vision.*`，但 mmproj 视觉权重没装上**。
     拿它当视觉档，症状是「批改结果在胡说」，而模型自带的那句
     「请上传图片」会被网关当成正常输出解析掉。
     先 `ollama pull gemma4:e4b` 重拉一次；仍没有 `projector_info` 就说明这个 tag
     的 manifest 里不含 mmproj，只能换模型。
2. **耗时必须对着客户端超时看**（`ai_config.dart`：判定/讲解 **12s**，带图批改 **30s**），
   而且**必须区分冷启动与预热** —— 这一条我第一版写错过，值得留在这里：
   表里的 33.1s 是**首次调用**（那次只产出 78 个输出 token，却花了 33s，
   多出来的 31s 是 18.6GB 权重从磁盘加载）。我据此写过「26B 做判定会顶穿 12s」，
   而按业务提示词实测预热后只要 **10.3s**。**冷启动是一次性成本，不是模型的速度。**
   正确读法是：上表回答「这个模型会不会按 `tools` 调函数」，耗时仅供参考；
   真正决定可用性的数字在下面的「只用 26B 一条模型跑完整链路」里。
3. **决定速度的是显存，不是参数量。** `gemma4:26b`（17.3GB）和
   `qwen3-coder:30b`（17.3GB）都塞不进 12GB 显存，要大量 offload 到 CPU，
   于是一个 A4B 的 MoE 模型比 7B 稠密模型慢 8 倍。**跑之前先看 `nvidia-smi`
   的空闲显存** —— 桌面上开着的其它程序（浏览器、播放器）会把额度吃掉，
   而症状同样是「莫名其妙很慢」。

选型结论（这台机器）：**两个档位都有可用的本机模型，怎么配取决于要哪几条链路** ——
- 只跑**作业**（拍照识别 + 批改）：`ARK_MODEL_VISION=gemma4:26b` 一条就够，
  实测批改 16.4s、识别 18.2s，都在 30s 窗口内（见下一节的表）。
- 要**复习闭环也全在本机**：26B 单独当三档能覆盖判定，但 12s 的窗口只剩 1.7s 余量，
  且讲解必然超时 —— 想留余量就各配各的：
  `ARK_MODEL_REASONING=qwen2.5:7b`（判定 7.0s、讲解 2.4s）、
  `ARK_MODEL_VISION=gemma4:26b`（批改 20.0s）。

`AI_PRICE_*` 仍要全留空，看板显示 `cost: null` 是正确结果 ——
注意 `usageMissing` 会是 **0**：Ollama 是返回用量的（判定那次 `in:567/out:78`），
缺的只是单价，不是用量。

### 只用 26B 一条模型跑完整链路（`scripts/e2e-local-homework.mjs`）

「哪个模型能顶哪个档位」是选型问题；「配好之后学生的作业能不能真的走完一条链路」
是另一个问题 —— 一个模型既能 `tool_calls` 又能读图，仍然可能在**业务提示词**下跑飞。
所以这条验收走网关的真 HTTP 端点、送真照片，四条链路各自对着自己的客户端窗口看。
照片用 `scripts/make-homework-photos.ps1` 现生成（作业页里有两道故意做错的题）。

四个档位全填 `gemma4:26b`（`ARK_MODEL_VISION/REASONING/LIGHT` 同一个），实测：

| 链路 | 客户端窗口 | 冷启动 | 预热后 | 结果 |
| --- | --- | --- | --- | --- |
| 作业批改 `/ai/homework/check` | 30s | 41.8s | **16.4s** | 通过 |
| 作业清单识别 `/ai/homework/ocr` | 30s | 20.6s | **18.2s** | 通过 |
| 错题判定 `/ai/review/judge` | 12s | — | **10.3s** | 通过（余量仅 1.7s） |
| 错题讲解 `/ai/review/explain` | 12s | — | **42.6s** | **超窗口**（客户端会降级） |

质量是真实通过，不是"没报错"：

```json
// 批改：两道错题都抓到了，且判对了正确答案应该是什么
{"items":[{"knowledgePoint":"乘法口诀","originalAnswer":"26","wrongReason":"9乘以3应该是27，算成了26"},
          {"knowledgePoint":"乘法口诀","originalAnswer":"42","wrongReason":"6乘以8应该是48，算成了42"}],
 "score":60,"summary":"共有 2 处乘法计算错误。"}

// 识别：6 条任务全部认出，科目标注正确（客户端据此 groupBySubject 归类）
{"confidence":0.98,"subject":"语文、数学、英语",
 "tasks":[{"subject":"语文","text":"抄写第3课生字"},{"subject":"语文","text":"背诵《静夜思》"},
          {"subject":"数学","text":"练习册P12 第1-5题"},{"subject":"数学","text":"口算20题"},
          {"subject":"英语","text":"听读Unit 2"},{"subject":"英语","text":"默写单词"}]}
```

讲解那次也**判得对、讲得好**（给出了 `9+9+9` 的分步、指出"最后一步加法漏进位"这个
真实易错点、还编了口诀），它唯一的问题是**太长**：

```json
// 讲解：内容没问题，是长度问题
{"whyWrong":"…你可能先算了 9 + 9 = 18，但在算 18 + 9 时…导致结果变成了 26。",
 "steps":["第一步：把 9 × 3 理解成 3 个 9 相加，即 9 + 9 + 9。",
          "第二步：先算前两个 9 相加，9 + 9 = 18。",
          "第三步：在 18 的基础上再加上最后一个 9，即 18 + 9 = 27。"],
 "mnemonic":"九九口诀，凑个九"}
```

**所以本机模型的瓶颈常常不是「快不快」，而是「12s 里能吐多少字」。**
把四次实测按输出 token 摊开算，这台机器上的生成速率是 **46–55 token/s**，
于是 12s 的窗口实际只够 **约 500–600 个输出 token**：

| 链路 | 输出 token | 耗时 | 折算 |
| --- | --- | --- | --- |
| 判定 | 470 | 10.3s | 46 tok/s |
| 批改 | 707 | 16.4s | 43 tok/s |
| 识别 | 1001 | 18.2s | 55 tok/s |
| 讲解 | **1975** | 42.6s | 46 tok/s |

讲解的结构化输出（`whyWrong` + `steps` + `pitfalls` + `mnemonic`）天然要 2000 个 token，
**在 12s 窗口下不可能跑完 —— 换成云端模型也一样是"能跑完但很慢"，
只是云端的 tok/s 高一个量级，所以平时看不见这条约束。**
本机部署要过这一关只有两条路，都不是改代码：

1. **把窗口调大**（推荐）—— 客户端的两条超时线现在也能用编译期常量覆盖：
   ```bash
   flutter build web --dart-define=AI_BASE_URL=http://127.0.0.1:8787 \
     --dart-define=AI_TIMEOUT_MS=90000 --dart-define=AI_UPLOAD_TIMEOUT_MS=120000
   ```
   另加 `AI_IMAGE_TRANSPORT` / `AI_MAX_ATTEMPTS` / `AI_CAP_*` 也可按需覆盖。
   **云端部署不要动它们**：那是把「模型一句话都不回」的等待时间一起放大了。
2. **把讲解交给更快的档位** —— 但当前设计里**判定与讲解同属强推理档**，
   分不开，要分开得再切一级能力位（见「本机模型真实部署要预期的事」）。

### 端到端实跑（网关 → 真 Ollama，不是 stub）

上面那套配置**真跑通过**，三条链路的结果：

| 链路 | 档位/模型 | 耗时 | 结果 |
| --- | --- | --- | --- |
| 单题判定 | reasoning / `qwen2.5:7b` | 7.0s（含首次加载） | `verdict=correct, score=100`，判定理由正确 |
| 错题讲解 | reasoning / `qwen2.5:7b` | 2.4s | 结构化输出完整，还自己编了口诀「分母不同先通分，大小比较心中明」 |
| 作业批改 | vision / `gemma4:26b` | 20.0s | 见下 |

批改那次喂的是一张模拟作业图（`12 + 11 = 23` 与 `9 x 3 = 26`，第二行是错的）：

```json
{"items":[{"knowledgePoint":"整数乘法","originalAnswer":"26",
           "wrongReason":"9 乘以 3 应该是 27，这里算成了 26"}],
 "score":50,"summary":"共有 1 处乘法计算错误。"}
```

**它准确认出了 `9 x 3 = 26` 是错的** —— 这是真读懂了图，不是猜。
（顺带：重复发同样的请求会命中网关缓存，`latencyMs: 0`、`units: 0`。）

### 本机模型最典型的一种失败，值得单独说

第一次跑批改时喂错了图（一张四色方格图）。`gemma4:26b` **正确识别出「这不是数学作业」**，
然后回了一段人话请求重拍 —— 而不是调函数。网关因此如实报
`model_output_invalid`（`retryable: true`），**没有编一份批改结果**。

这一次失败同时验证了两件事，都是好消息：它的视觉是**真的**（准确描述了图里有什么）；
网关「**不替模型补空**」的设计确实在起作用（补空就会把「这不是作业」变成一份
假批改结果进错题库、被组卷、被打印出来让孩子重做）。

但它也点出了本机模型相对云端的风险：**输入不合预期时，它会跳出 schema 说人话**，
而云端模型更倾向于照 schema 输出。这类 `model_output_invalid` 是可重试的，
客户端会重试一次 —— 但重试大概率同样失败，因为两次失败的原因相同。

### 手写体识别率实测（`scripts/measure-handwriting-ocr.mjs`）

「手写体识别率是不是很低」这个问题不能靠印象回答，所以做了一组**只改字迹、不改内容**的对照：
同一份作业清单渲染成 5 张图，文字完全相同，差在字体与抖动。

```bash
# 造样本（Windows 自带 .NET 绘图，不联网）
powershell -ExecutionPolicy Bypass -File scripts/make-handwriting-samples.ps1 -OutDir <dir> -Font KaiTi -BodySize 40 -OutName L1_kaiti.png
# …下略，四档参数见脚本头注释
# 跑实测（第 4 个参数可选，只跑某几档）
node scripts/measure-handwriting-ocr.mjs <dir> stu_001
```

字迹档位：**L1** 楷体工整 · **L2** 行楷工整（连笔）· **L3** 行楷 + 逐字抖动/旋转/大小不均/基线漂移 ·
**L4** 舒体 + 更强抖动 + 手机拍照式不均光照 · **S0** 既有样例（楷体）作对照。

| 档位 | 字迹 | 任务召回 | 多出 | 可疑条目 | 自报置信度 | 耗时 |
|---|---|---|---|---|---|---|
| L1 | 楷体·工整 | 6/6 | 0 | 0 | 0.98 | 40.5s |
| L2 | 行楷·工整 | 6/6 | 0 | 0 | 0.98 | 14.9s |
| L3 | 行楷·逐字抖动 | 6/6 | 0 | 0 | 0.95 | 23.6s |
| L4 | 舒体·潦草+不均光照 | 5/6 | 1 | 0 | **0.9** | 45.8s |
| S0 | 对照（楷体） | 6/6 | 0 | 0 | 0.98 | 15.4s |

（`gemma4:26b`，同一台 12GB 笔记本，模型已预热；L1 的 40s 含一次冷启动。）

**结论有两条，第二条比第一条重要得多：**

1. **手写本身不是瓶颈。** 连笔的行楷、逐字大小不一、基线漂移加起来，26B 依然 6/6 全对。
   真正掉档的只有最潦草那一档，而它掉的方式不是「认不出」。
2. **真正的失败是「认成了一个读起来通顺的错词」。** L4 把「静夜思」认成了「静在恩」——
   转录读起来毫无异常，**置信度还报 0.9**（客户端门槛是 0.8）。
   也就是说：这个错误从文字上看不出来，置信度也指不出来，学生扫一眼就过，
   最后照着一项**假的作业**去做。**「认错」比「认不出」危险，而现有信号全都拦不住它。**

因此改了三处：

- **提示词**（`src/prompts.js`）：把「认不准就标出来、**不要换成读起来通顺的词**」提到最显眼的
  位置，并给出这一条为什么比「认不出」更糟；补上手写体常见的混淆（形近字、1/7、0/6/8、l/I）。
  改完之后 L4 的转录里出现了 `背诵《静在恩（？）》` —— 模型开始**自己承认不确定**了。
- **schema**（`src/schema.js`）：`tasks[]` 增加**可选** `uncertain` 布尔字段。
  可选是刻意的：设成必填会逼模型在没把握时也填一个值，而它更容易随手填 `false` ——
  那比不给更危险，因为客户端会把「没表态」和「明确说没问题」当成同一件事。
  同时给运行时校验补上 `boolean` 分支：之前 schema 里写 `boolean` 的字段**完全不被校验**，
  模型回 `"是"` 会被当成通过，然后客户端 `== true` 判假、标记静默丢失。
- **客户端**（`ocr_service.dart` / `homework_tab.dart`）：标记一路带到核对对话框，
  **指名道姓地点出是哪几条**（`ⓘ`），而不是只说一句「识别把握 90%」——
  六条里错两个通顺的字，一句「把握 90%」没法告诉学生该看哪一条。
  学生改过内容就撤掉标记（已经人核对过了），免得稀释剩下那些真需要看的。

改完之后单独复跑 L4 验证（`node scripts/measure-handwriting-ocr.mjs <dir> stu_001 L4`）：

```
多出：背诵《静在恩（？）》 / 听课Unit 2
模型标了「没把握」：背诵《静在恩（？）》
```

即 `uncertain: true` 确实置位并传到了调用方 —— 这一条会在对话框里被点出来。

**别高估这个标记**：同一次里「听读」认成「听课」**没有**被标记。它只抓到了一半的错误。
但此前是**零信号**，现在至少有一条能被指出来；剩下那些仍要靠「对着原图核对」兜住。
另外，同一次 L4 的耗时是 109s，而上一轮是 45.8s —— **并行做别的事时本机推理的耗时会成倍波动**，
报耗时一定要写清当时机器在干什么，否则数字没有意义。

### 本机模型真实部署要预期的事

这几条不是编码问题，是物理问题：

- **视觉档必须真多模态。** 手写作业识别要 Qwen2.5-VL 这类；纯文本模型填进
  视觉档不会报错，只会编。7B 级别的手写识别质量会明显低于云端。
- **延迟会顶到超时。** 客户端 `requestTimeout` 12s、批改单独放宽到 30s
  （`ai_config.dart`）。4 张图 + 长提示词，消费级单卡跑 7B–14B 的首 token
  延迟很容易越过 30s → `model_timeout` → 客户端降级。
  **现象是「AI 好像没生效」，实际是超时**，要去网关日志看 `error.code`。
- **第一次调用要算上加载时间。** 18.6GB 的 26B 从磁盘装进来要 30s 上下，
  这一次必然超窗口 —— 但它是**一次性**的，别把它当成模型的速度。
  想避开就在服务起来后先发一次预热请求（或 `ollama run` 让它常驻）。
- **超时窗口可以按部署方式调，但别把默认值当摆设。**
  `AI_TIMEOUT_MS` / `AI_UPLOAD_TIMEOUT_MS` 是给本机部署用的：
  本机 46–55 token/s 意味着 12s 只够约 500 个输出 token，
  而「讲解」一个人就要 2000 个。云端部署请保持默认 —— 那里 12s 够用，
  调大只是把「模型一句话都不回」的等待一起放大。
- **并发会排队。** 学生点一次「提交检查」客户端会连发 N 次判定，本地单实例
  串行推理只能排队。分钟窗口额度（120 单位）够用，但等待时间会很长。
- **判定质量是硬伤。** 错题判定用 7B 会判错数学题，而错判会让学生不信任整个
  闭环 —— `config.js` 里为「不要拿轻量档做判定」写过一次同样的理由。
  ⚠️ 注意**三级能力是按档位分的，判定与讲解同属强推理档**，所以「只把讲解
  放到本机、判定留在云端」在当前设计里做不到，要那样得再加一级能力位。

## 区域：两个「同区」诉求，数据库那个更强

有两件事都想要「同区」，而它们指向不同的地方：

| 想跟谁同区 | 为什么 | 延迟敏感度 |
|---|---|---|
| **数据库（RDS）** | 数据服务每个请求要查好几次 PG | **高**：小请求、高频，几十毫秒**逐次叠加** |
| 方舟的模型 API | 一次批改调若干次模型 | 低：单次好几秒，几十毫秒占比很小 |

**所以跟数据库走。** 本服务与数据服务共用 `s.yaml` 的 `vars.region`，
2026-09-24 实测后定为**华东 1（杭州）**（依据：RDS 实例 ID 前缀 `bp1`、
OSS 桶 endpoint 是 `oss-cn-hangzhou`、以及从长沙测的 TCP 往返 RDS 31ms / 杭州 31ms / 北京 38ms，
详见 `doc/aliyun-deploy-plan.md` §2）。

⚠️ `ARK_REGION=cn-beijing` **照旧不要动** —— 它是**火山引擎**的地域、只影响方舟签名。
不要因为「统一地域」把它也改成杭州；百炼的端点固定，压根不吃这个变量。

## 开通清单（方舟侧）

开工前先确认这四件事，它们决定了客户端能用到哪些能力：

0. **先问清楚「该填哪个」—— 跑 `probe-ark-catalog.mjs`。**
   这一步不能靠翻目录解决，因为「模型不存在」有两种，**处置动作相反**：

   | 现象 | 真实含义 | 该做什么 |
   |---|---|---|
   | `404 ModelNotOpen` | 平台有这个模型，**你的账号没开通** | 去控制台「开通管理」开通 |
   | `404 InvalidEndpointOrModel.NotFound` | 目录里挂着但**已经调不动**（老型号、非 chat 端点） | 换个新型号，别去开通它 |

   两者在日志里长得一样（都是 404），而 `GET /models` **帮不上忙**：它返回的是
   **平台模型目录**（实测 133 条，其中 69 条 `Shutdown`、22 条 `Retiring`）——
   列出来的是「平台上有」，不是「你账号开通了」。唯一的判据是**实际调一次**：

   ```bash
   ARK_API_KEY=xxx node scripts/probe-ark-catalog.mjs --dry   # 先只看目录，一次调用都不发
   ARK_API_KEY=xxx node scripts/probe-ark-catalog.mjs         # 逐个实调，判本账号是否开通
   ```

   它会直接给出可粘贴的 `ARK_MODEL_*` 行；**一个都没开通时以退出码 1 结束**，
   并说明「这不是 Key 的问题」（Key 无效是 401，`ModelNotOpen` 的文案里带着你的 account id）。
   每个候选一次 `max_tokens: 8` 的调用，合计约 30 秒、两位数输入 token。

1. **视觉模型需要单独开通**，部分型号还需在控制台单独申请。没开通时
   `ARK_MODEL_VISION` 留空即可 —— 客户端会拿到 `capabilities.vision = false`，
   转而直接走本地识别，而不是把 3MB 照片发上来等一个必然失败的响应。
2. **强推理模型与视觉是不同的模型 ID**，不要用同一个。
3. **配额**：方舟侧有 TPM/RPM 限制。`AI_QUOTA_UNITS_PER_MINUTE` 要按
   「学生数 × 该值 ÷ 平均权重」估一遍，别让网关把方舟打限流。

`GET /ai/health`（或 `POST`）会回报真实可调用状态，客户端启动后会探一次。
但**健康检查只反映配置**（有没有 Key、模型 ID 填没填），不反映方舟那边
是不是真的开通了。上线前用这条命令各调一次：

```bash
ARK_API_KEY=xxx \
ARK_MODEL_VISION=doubao-... ARK_MODEL_REASONING=doubao-... \
node scripts/probe-ark.mjs
node scripts/probe-ark.mjs reasoning        # 只探一级
```

它做两件**本地怎么测都测不出来**的事：确认三级模型确实开通，
以及核对 `usage` 的字段名。第二件事尤其重要 —— 网关的成本链路只认
`usage.prompt_tokens` / `usage.completion_tokens`（见 `guard.js`），
方舟某个模型若换了字段名或干脆不返回 usage，看板**不会报错**，
它只会安静地把 token 记成 0、让成本退化成「下限」。
脚本发现这种情况会以退出码 1 结束，并列出实际返回了哪些键。

它**不验**业务契约的正确性（探活用的是一个极简 schema）：判定准不准、
批改得对不对要靠真实使用来评，不是一条探活命令能证明的。
**退出码 0 才算通过。**

### 本账号的开通现状（2026-09-20）

| 档位 | 模型 | 状态 |
|---|---|---|
| `ARK_MODEL_REASONING` | `deepseek-v4-pro-ga-260813` | ✅ 已开通，`probe-ark.mjs` 退出码 0 |
| `ARK_MODEL_VISION` | —— | ❌ 在售的 26 个 chat 候选里没有一个开通 → 拍照识别 / 作业批改仍回 `model_not_enabled` |
| `ARK_MODEL_LIGHT` | —— | 空（**没有业务端点用到它**，不需要就别填） |

⚠️ 同族两个 ID 只有 GA 那个开通（`deepseek-v4-pro-260425` 是 `ModelNotOpen`）——
**填错 ID 不会报错**，只会回 `model_not_enabled`，所以别凭记忆写。

### 通道通了之后：量一遍「跑得完吗」

`probe-ark.mjs` 证明**接得上**，证明不了**在客户端的窗口内跑得完**。
这两件事的差别就是一个功能可用不可用：客户端文本请求的窗口只有 **12s**，
超了它不会报错，而是**安静地退回本地模板**。

```bash
# 网关按真方舟启动（另一个终端 npm run dev，ARK_MODEL_* 填真 ID）
E2E_VARIANT=1 node scripts/e2e-local-homework.mjs
```

它把六条端点各跑一遍，把实测耗时与客户端窗口摆在一起，并区分
「通过 / 超窗口 / 命中缓存 / 网关拒绝」。**复跑要换 `E2E_VARIANT`** ——
网关按 payload 做响应缓存（默认 10 分钟），同一个 payload 的第二次调用
是几毫秒的缓存命中，那是一次什么都没测的验收。

## 部署

入口：`src/handler.js` 导出的 `handler`。
平台若只认 CommonJS，把入口指向 `index.cjs`。

```bash
# 火山引擎函数服务 veFaaS
#   运行时 Node.js 20+，入口 index.cjs，导出 handler
#   触发器：API 网关，路径 /ai/*（本服务会自己抹掉 stage 前缀）

# 腾讯云 SCF / 阿里云 FC
#   事件形状与上面一致（path / httpMethod / headers / body / isBase64Encoded），
#   不需要改代码
```

### 鉴权现状

**默认值仍是 `false`，但已经不再是「开了会炸」的状态。**

2026-09-20 之前这里写的是「客户端拿不到服务端签发的会话 token，开了会让客户端
全部 401」。那条**已经不成立**了，三段都补齐了：

| 环节 | 现状 |
|---|---|
| 签发 | 数据服务 `POST /auth/login` 用 `AI_SESSION_SECRET` 签会话（`shared/token.js`） |
| 兑换与保存 | 客户端 `HttpAuthApi` 登录即换票，落 `SessionStore`（冷启动恢复） |
| 携带 | 每个 AI 请求带 `Authorization: Bearer …`，由 `AiIdentity.resolve` 统一装配 |

客户端那一环曾经是缺的：`SessionStore` 里存着票，`_identityFromAuth()` 却只传学号，
于是开关一开，数据链路全绿而每条 AI 调用 401。现在有专门的用例钉住它
（`test/ai_identity_session_test.dart`，含「登出后立刻不再带票」）。

**本机演示栈默认打开它**（`serverless/data-service/scripts/dev-stack.mjs` 把
`AI_SESSION_SECRET` 同时给两个服务，并设 `AI_REQUIRE_AUTH=true`）——
演示走的就是严格鉴权那条路。想临时关掉：`AI_REQUIRE_AUTH=false npm run dev:stack`。

打开之后 `X-Student-Id` 依然会发，但只剩**审计对账**的作用：网关拿它与 token 里的
subject 比对，不一致就记一笔 `declaredStudentId` —— 那是抓伪造的信号，
所以客户端发的必须是会话里那个 id（本地 id 会把这条信号灌满）。

**仍然没解决的**：token 是无状态自包含的，没有吊销能力、没有设备绑定
（见下方「已知限制」第 6 条）。真正对外前应换成带服务端会话表的方案。

### 排障：业务说「AI 没生效 / 认不出内容」，先查身份

**先看有没有 `ai_call` 审计。** 这条判断能省掉一半的排查时间：

```bash
# 网关 stdout 里搜一次调用的审计行
grep '"path":"/ai/homework/ocr"' gateway.log | tail -3
```

- `"ok":true` 且 `"latencyMs"` 是几百毫秒以上 → 模型真的跑了，问题在识别质量；
- `"ok":false` 且 `"latencyMs":0`、`"model":null`、`"imageCount":0`
  → **请求根本没到模型**，是入口校验拦下的。看 `"code"`。

`code` 为 `bad_request` 时再分两种，它们的处置完全不同：

| 审计里的 `studentId` | message | 含义 |
|---|---|---|
| `anonymous` | X-Student-Id 是占位符「anonymous」… | 客户端**未登录**就发起了 AI 调用 |
| `unknown` | 缺少 X-Student-Id … | 请求头真的没带 |
| 真实学号 | 至少需要一张作业照片 / images 等 | 身份没问题，是请求体不对 |

第一种曾经以「缺少 X-Student-Id」的形式报出来 —— 而请求头明明在，
只是值是占位符。照着「缺少」去查会一路往「客户端是不是没带头」的方向找，
永远找不到。**文案与审计口径已区分开（`test/gateway.test.js` 有用例钉住）。**

```bash
# 四种情形一次跑完（含两次真实模型调用）
node scripts/verify-ocr-identity.mjs <装着作业照片的目录> stu_001
```

顺带记一条**客户端侧的定论**：占位符是客户端该在上行前拦住的，
不该由网关兜。客户端现在会在 `AiApiClient.postJson` 里判 `AiIdentity.usable`，
无效就直接报 `no_identity` 且**不发请求** ——
省掉一次必然失败的往返，也让「未登录」不再被伪装成「照片认不出」。

## 本地开发

```bash
AI_MODEL_CLIENT=mock \
AI_UPLOAD_URL_BASE=http://127.0.0.1:8787 \
AI_UPLOAD_SIGNING_SECRET=dev-secret \
npm run dev
```

然后把客户端的 `AI_BASE_URL` 指到 `http://127.0.0.1:8787`：

```bash
flutter run --dart-define=AI_BASE_URL=http://127.0.0.1:8787
```

`AI_MODEL_CLIENT=mock` 返回的是确定性假数据，`meta.model` 会标成 `mock`，
一眼能看出来。**不要把它带上生产** —— 那等于给用户编数据。

## 测试

```bash
npm test        # node --test，无需安装任何依赖
```

覆盖：schema 校验与 tool 定义、提示词重试注入、图片裁剪与安全校验、
方舟响应解析（tool_calls / content / 代码块围栏）、错误码映射与重试边界、
路由信封、鉴权（含签发脚本端到端）、**按成本权重的配额**（含预扣/退款、
额度用完与限流的区分、旧变量名拒绝启动）、缓存命中与过期、审计字段、
**成本看板**（未配单价时成本为 null、usage 缺失时标为下限、
缓存/规则与模型调用分开计数、按路径与错误码聚合、口令门禁）、
批量参考答案的 index 对齐与缺条目处理、
上传签名全链路、TOS 规范化签名与派生密钥、平台事件归一化。

`node --test test/` 在本机（Node 22 / Windows）**不认目录**，会报
`not ok 1 - test`。用 `node --test test/*.test.js` 或 `npm test`。

### Node 版本：本机跑测试用 22，别用 24

`package.json` 的 `engines` 写的是 `>= 20`，但**本机实测 Node 24 跑不过**：
用系统的 Node 24.19.0 跑 `npm test`，`test/probe-ollama.test.js` 那 9 条会整组失败，
报的是

```
Expected values to be strictly equal:
3221226505 !== 0
```

`3221226505` = `0xC0000409`（Windows fast-fail）—— 子进程**硬崩**，不是断言写错。
换回 Node 22.22.2 即 **132/132 全通过**：同一份代码、同一个提交，唯一变量是解释器版本。

所以 **见到 `3221226505` 先查 `node -v`**。这个数字长得像某个业务码，实际是
「进程被异常终止」的证据 —— 而读到它的人第一反应通常是去读被测脚本，
那个脚本本身没问题（在 22 下跑得好好的）。

排查时的第二个坑：如果为了「确保 node 可用」而把某个 node 目录**加到 `PATH` 前面**，
可能就把默认的 22 静默换成了 24，症状是「昨天全绿、今天 9 条红，代码一行没改」。

（不排除是 Node 24 与本机杀软/沙箱的交互 —— 换个环境时，先跑一次 `npm test`
确认全绿，再开始改代码。**基线不是「上次记得是绿的」，是这次跑出来的**。）

## 重试次数上界（成本可算）

| 层 | 触发条件 | 次数 |
|---|---|---|
| 网关（`ark.js`） | 传输层失败：429 / 5xx / 超时 / 连不上 | ≤ `AI_MODEL_MAX_ATTEMPTS`（2） |
| 客户端（`RemoteAiDataSource`） | 服务端给的 `retryable` 为真，或响应不合契约（带 `retryHint`） | ≤ 客户端 `maxAttempts`（2） |

**最坏情况 2×2 = 4 次调用**，且只在连续失败时发生。
schema 违约刻意不在网关重试：提示词一个字没变，重试只会让模型原样再错一遍，
白烧一次 token。有意义的第二次必须带 `retryHint`，而那个信息只有客户端有
（它同时握着本地兜底实现）。

## 已知限制（不要当成已解决）

1. **配额与缓存默认仍是单实例的。** 计数放在进程内存里，而 Serverless 实例随时
   会被回收、也会同时存在多个：它拦得住「一个脚本在同一分钟内猛打」，
   **拦不住「刻意拉开间隔刷」**。要让配额真正有效，必须把 `AI_KV_URL`
   指到共享 KV 上（`examples/kv-server.mjs` 可本地验证这条链路）。
   抽象已经就位（`store.js`），但**默认配置不会自动变安全**。
   自建 KV 时注意：计数器里存的是**成本单位**，`incr` 必须支持 `delta`
   （正负都可，负数在 0 处截断）—— 退款靠它。
2. **看板是单实例口径。** `onAudit` 现在喂两个下游（日志 + `metrics.js`
   的进程内聚合），所以日志里的数和看板上的数同源、不会分叉。
   但聚合体在内存里：重启实例会丢历史、多实例各算一份。
   要全局口径得把审计事件接到日志 / 指标服务；`/ai/metrics` 的 `scopeNote`
   已经把这句话带在响应里，不会让它被当成全局数字。
3. **`proxy` 上传模式的对象存在内存里**，实例一回收就没了，仅适合联调与预发。
4. **TOS 签名按官方公式实现，但未经真实凭证验证**（官方示例自相矛盾，
   没有可信测试向量）。先拿真凭证跑一次 `scripts/probe-tos.mjs` 再用；
   在那之前请用内联模式（默认）。未配齐时网关会如实回 `upload_not_configured`，
   而不是给一个「看起来能用、上传时 403」的假 URL。
5. **会话 token 没有吊销能力**（无状态自包含、无设备绑定）：泄露后在有效期内
   谁都能用。有效期取 12 小时（约一个学习日）；真正对外前应换成带服务端会话表的
   方案（可吊销、可单点下线）。
   （签发与携带本身已经打通：数据服务登录即签票，客户端每个 AI 请求都带上。
   本机演示栈默认打开 `AI_REQUIRE_AUTH`，见上方「鉴权现状」。）
6. **审计日志不含学生答案与作业照片**，这是刻意的：照片里有孩子的姓名、班级、
   住址，而审计要回答的问题只有「谁调的、花了多少、有没有异常」。
   （反过来，**作业照片默认内联进请求体**，不产生公网 URL。）
8. **`usage` 的字段名未经真实凭证验证。** 成本链路只认
   `usage.prompt_tokens` / `usage.completion_tokens`（见 `guard.js`）。
   mock 客户端返回的就是这两个名字，所以本地全绿说明不了任何事 ——
   方舟某个模型若换了名字或不返回 usage，看板不会报错，只会把成本
   退化成「下限」。上线前跑一次 `scripts/probe-ark.mjs` 核对。
9. **轻量档（`ARK_MODEL_LIGHT`）目前没有业务端点使用。** `router.js` 的六条路由
   经 `CAPABILITY_BY_KIND` 只落到视觉与强推理两档；文本解析在客户端是纯规则
   （`HomeworkTextParser`），不经过网关。所以这个模型 ID 现在**配了也不会有调用**。
   探活脚本仍然会探它 —— 它决定「以后要加小任务时有没有现成的档位可用」。
   注意由此带来的一个组合：`pricingState` 要求三级能力的单价**同时**配齐或留空，
   于是「只填视觉与强推理」会让网关启动即报错（报错信息里已给出两种合法写法）。
   这是刻意的保守选择，不是 bug —— 但要知道轻量档的单价也得填。
10. **接本机模型时，配额单位不再对应金额。** 配额本身仍然工作（防止脚本猛打、
   仍是按能力权重扣），但本机推理没有单价，所以 `AI_PRICE_*` 只能全空，
   看板的 `cost` 会恒为 `null`、`pricing.state` 恒为 `none`。
   这时 `AI_QUOTA_UNITS_PER_DAY` 是个**纯内部记账单位**，别再把「200 单位
   ≈ ¥0.3/天/学生」那句话套上去 —— 那个换算是照云端单价算的。
   接法与坑见上文「接本机模型」。
11. **`confidence` 对手写识别基本没有区分度，别拿它当质量闸门。**
    实测同一份清单从工整楷体换到最潦草的手写体，自报置信度只从 **0.98 掉到 0.90**，
    而客户端的门槛是 **0.8** —— 也就是说它会一直放行，包括那次把「静夜思」
    认成「静在恩」的结果。它实际能筛掉的是「根本读不出来」这一类
    （提示词里定义为 0.5 以下），筛不掉「读成了另一个通顺的词」。
    能指出后者的是 `tasks[].uncertain`，而这个标记**只抓到一部分**
    （同一次实测里两个错词只标出了一个）。
    所以核对这一环不能省，也不该因为「把握 90%」而放松。
12. **`estimatedMinutes` 是量级估计，不是测算结果。** 它是模型给的起点
    （schema 约束在 5–120 的整数），客户端还会在标题改动时按规则重算，
    学生也能直接改。**它不该被用来做任何排期或负荷判断** ——
    「今天作业合计 65 分钟」这种结论的误差可能有一倍。
    另外它不是必填：模型没把握时可以省掉，客户端会按作业类型退默认值
    （背诵 10 / 口算 15 / 书面 30……）。省掉比猜一个像模像样的数要好。

## 识别之后：谁负责把文字变成作业项

「让模型直接拆好，应用只接收结果」这个方向是对的，而且代码里就是这么分的。
但**「只接收」不等于「不检查」** —— 边界画在这里：

| 环节 | 交给谁 | 为什么 |
|---|---|---|
| 看见文字、判断版式（哪几个字属于同一行） | **模型** | 版式信息只有图像模型有 |
| 拆分（一条 = 一件事）、判定科目、估耗时 | **模型** | 它是理解语义的那一方，用规则去猜远不如它 |
| 契约约束（字段形状、`estimatedMinutes` 范围、`minItems: 1`） | **网关 schema** | 让模型的自由发挥必须落进可用结构 |
| 归一化（科目同义写法收敛、漏拆时兜底、去重） | **客户端纯规则** | **同一段文字两次必须得到同一结果** |
| 呈现（按科目分组、类型标签、可疑标记、可改的耗时） | **客户端** | |

为什么最后两行不交给模型：模型对同一张图重跑会**漂**（采样温度、上下文、
图像编码差异）。而「今天有几项作业」是要落库、要被家长端另一个会话读到、
要按条统计完成度的 —— 一份会漂的清单没法当数据源。
原则一句话：**理解用模型，定形用规则。**

归一化层在 `lib/services/homework_item_normalizer.dart`，它处理的具体情形：

- **科目同义写法收敛**：`数学作业` / `数学 ` / `Math` 归成同一个「数学」。
  不收敛的代价是分散 —— 同一门课会在按科目筛错题、家长端统计里被算成两门，
  而每一处单看都「没错」。
- **正文里的科目前缀优先于 `subject` 字段**：模型偶尔会 `subject` 填「待确认」
  而正文写着「数学：练习册P12」。同一张图里明明认出来了，不该当成没认出来。
  前缀不是已知科目时（「要求：朗读课文」）原样不动 —— 把「要求」当科目
  只会平白多出一门不存在的课。
- **模型漏拆时兜底拆开**：至少出现两个序号才按列表拆；
  `做1、2、3题` 是一件事，拆开就凭空多出两条待办。
- **去重**：多张照片拍到同一页时，「练习册 P12」和「练习册P12」算同一条。
  重复时宁可保留 `uncertain` 标记 —— 多提醒一次比漏掉一个错字好。
- **下拉框选项 = 固定清单 ∪ 实际出现的**：`DropdownButtonFormField` 要求
  `initialValue` 必须在 `items` 里，而科目是自由字符串。只给固定清单的话，
  模型回一个「科学」就会断言失败（release 下不崩，但输入框显示为空，
  学生既看不到识别出的科目、也选不回它）。

**实测（gemma4:26b，L4 潦草样本，`scripts/probe-ocr-tasks.mjs`）**：
模型自己就返回了 6 条、按科目分好、每条带 `estimatedMinutes`（15/10/20/10/10/10），
归一化**没有需要兜底的地方** —— 也就是说这一层在当前模型上是「保险」而不是「主力」。
它的价值在于模型退化、换更小的模型、或被接上质量更差的视觉档时兜住结构。
同一次实测还暴露了一个旧缺陷：模型没在**顶层**填 `subject`（它在每条里填了），
旧逻辑就直接退回「待确认」，而新逻辑按 tasks 聚合会正确显示「多科目」。
