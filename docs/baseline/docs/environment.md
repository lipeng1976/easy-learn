# 环境变量说明

**唯一读取入口**：`backend/shared/config.js`。其余文件一律通过 `config` 对象取值，
不得直接 `process.env.XXX`（`scripts/check-env.mjs` 会静态检查这一条）。

**唯一模板**：根目录 `.env.example`。复制成 `.env` 后填值，`.env` 已被 `.gitignore` 排除。

---

## 校验规则（启动即执行，不静默兜底）

| 规则 | 不满足时 |
|---|---|
| 必需变量存在且非空 | 抛错退出，打印缺失变量清单 |
| `AI_SESSION_SECRET` 长度 ≥ 32 | 抛错退出 |
| `NODE_ENV=production` 时任何值不得含 `CHANGE_ME` | 抛错退出 |
| `NODE_ENV=production` 时 `AI_REQUIRE_AUTH` 必须为 `true` | 抛错退出 |
| `IMAGE_DRIVER` 只能是 `local` / `oss` | 抛错退出（**绝不静默退回 local**） |
| `IMAGE_DRIVER=oss` 时 `OSS_*` 全部必填 | 抛错退出 |
| `OSS_ENDPOINT` 的地域必须等于 `OSS_REGION` | 不在这里校验（运行时 403 才暴露），见交接清单 |
| `STORAGE_ROOT` 必须能创建且可写 | 抛错退出 |
| 端口为 1–65535 的整数 | 抛错退出 |

> 设计取向：**配置错了要炸在启动那一刻**。原工程吃过「存储驱动名写错、静默退回本地」
> 的亏 —— 症状是「照片位置一片空白、无任何日志」。

---

## 变量全表

### 运行模式

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `NODE_ENV` | 否 | `development` | `production` 时启用全部严格校验 |
| `LOG_LEVEL` | 否 | `info` | `debug` / `info` / `warn` / `error` |
| `DATA_SERVICE_PORT` | 否 | `8788` | 数据服务监听端口 |
| `AI_GATEWAY_PORT` | 否 | `8787` | AI 网关监听端口 |

### 数据库

| 变量 | 必填 | 说明 |
|---|---|---|
| `DATABASE_URL` | **是** | 应用连接串。**必须**用非 superuser 的 `app_rls` 角色，否则 RLS 静默失效 |
| `PG_OPS_URL` | 初始化时 | 运维连接串，只给 `scripts/init-db.mjs` 用；不要给应用进程 |
| `PGSSLMODE` | 否 | 云上 RDS 设 `require`；本机可 `disable` |
| `PG_POOL_MAX` | 否 | 连接池上限。云上注意：`实例上限 × 池大小 < max_connections` |
| `PG_APP_ROLE` | 否 | 默认 `app_rls`；与 DDL 里的角色名一致 |
| `APP_RLS_PASSWORD` | 初始化时 | 应用角色口令。**只在 env**，不进 SQL、不进代码 |

### 鉴权

| 变量 | 必填 | 说明 |
|---|---|---|
| `AI_SESSION_SECRET` | **是** | 会话签名密钥，≥32 字符。**两个服务必须同一把**，否则一边签的票另一边验不过 |
| `AI_REQUIRE_AUTH` | **是** | 本地可 `false`；**生产必须 `true`**，否则 `/data/*`、`/ai/*` 可匿名调用 |
| `SESSION_TTL_HOURS` | 否 | 默认 `168`（7 天） |

### 附件存储 ★

| 变量 | 必填 | 说明 |
|---|---|---|
| `STORAGE_ROOT` | **是** | 附件根目录，**唯一配置处**。库里只存相对它的路径。可以写绝对路径或相对项目根，但**绝不写入数据库** |
| `IMAGE_DRIVER` | **是** | `local` / `oss`。写错直接抛错 |
| `OSS_ENDPOINT` | `oss` 时 | 对象存储 endpoint |
| `OSS_REGION` | `oss` 时 | 必须与 endpoint 的地域一致，不一致会 403 |
| `OSS_BUCKET` | `oss` 时 | 桶名 |
| `OSS_ACCESS_KEY_ID` | `oss` 时 | AK |
| `OSS_ACCESS_KEY_SECRET` | `oss` 时 | SK |

> `STORAGE_ROOT` 只影响**字节放在哪**，不影响库里的相对路径。
> 换机器、换磁盘、从本地迁到 OSS，只要把文件按同样的相对路径搬过去，
> 数据库一行都不用改 —— 这就是不存绝对路径的全部意义。

### AI 网关

| 变量 | 必填 | 说明 |
|---|---|---|
| `AI_MODEL_PROVIDER` | 用 AI 时 | `bailian` / `ark`。切换后模型名、单价、思维链名单要一起换，三者都不报错 |
| `BAILIAN_API_KEY` / `BAILIAN_MODEL` | provider=bailian | 百炼凭证与模型名 |
| `ARK_API_KEY` / `ARK_MODEL` | provider=ark | 方舟凭证与模型名 |
| `AI_GATEWAY_TIMEOUT_MS` | 否 | 默认 `12000`。视觉/批改类请求另设更长超时 |

> 模型 Key **只存在于 AI 网关进程**。前端只与网关通信，永远拿不到厂商凭证。

### 可选能力（没有就整段留空）

| 变量 | 说明 |
|---|---|
| `IMA_CLIENT_ID` / `IMA_API_KEY` | ima 知识库凭证 |
| `IMA_CREDENTIAL_SECRET` | 加密落库凭证用，≥32 字符 |

> **不是所有人都有 ima**。未配置时功能可以不出现、入口可隐藏，但绝不能报错：
> 不弹红条、不抛异常、不拖垮主流程。只有用户主动点该功能按钮才允许回明确反馈。

### 前端构建期变量（不注入 Node 进程）

| 变量 | 说明 |
|---|---|
| `DATA_API_BASE_URL` | 转成 `--dart-define=DATA_API_BASE_URL=...` |
| `AI_BASE_URL` | 转成 `--dart-define=AI_BASE_URL=...` |
| `DATA_TIMEOUT_MS` | 数据请求超时 |
| `AI_TIMEOUT_MS` | AI 请求超时 |
| `AI_UPLOAD_TIMEOUT_MS` | 图片上传超时 |
| `AI_JUDGE_TIMEOUT_MS` | 批改判定超时 |

> 客户端连哪份库**构建期决定**。换后端地址必须重新出包，改 `.env` 不会影响已装的 APP。

---

## 密钥轮换

1. 改 `.env` → 重启服务；`AI_SESSION_SECRET` 两服务**同时**改，否则在途会话全部失效。
2. `APP_RLS_PASSWORD` 改完执行 `npm run db:init`（幂等，会 `ALTER ROLE`）。
3. 轮换后跑 `npm run check:env` 与 `curl /health`。
4. 绝不把旧值复制进 `.env.example`；模板里永远只有 `CHANGE_ME`。
