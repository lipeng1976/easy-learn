# 架构说明

## 1. 总体形态

```
┌─────────────────────────────────────────────────────────────┐
│  frontend/  Flutter（Android / iOS / Web / 桌面）             │
│  GetX 路由 + 状态 · sqflite 本地库 · http 传输                 │
│  配置：--dart-define（构建期注入，不含密钥）                    │
└───────────────┬─────────────────────────┬───────────────────┘
                │ /auth/*  /data/*          │ /ai/*
                ▼                           ▼
┌───────────────────────────────┐   ┌───────────────────────────┐
│  backend/data-service         │   │  backend/ai-gateway        │
│  账号 / 关系 / 作业 / 复习     │   │  模型调用 / 出题 / 批改     │
│  积分 / 打卡 / 附件           │   │  厂商 Key 只在此进程        │
│  /data/* 走 app_rls 鉴权      │   │  /ai/* 走 app_auth 鉴权     │
└───────────────┬───────────────┘   └──────────────┬────────────┘
                │                                   │
                │  PostgreSQL（RLS 隔离）            │  AI 厂商 HTTP
                ▼                                   ▼
┌───────────────────────────────┐   ┌───────────────────────────┐
│  db/  DDL 终态 + 字典种子      │   │  百炼 / 方舟               │
│  43 张表 · app_rls 非超管角色  │   └───────────────────────────┘
└───────────────┬───────────────┘
                │ 相对路径（rel_path 域）
                ▼
┌───────────────────────────────┐
│  STORAGE_ROOT（仅此一处配置）  │
│  本地文件系统 / OSS           │
└───────────────────────────────┘
```

**两个服务不互相调用数据库**：网关只做模型编排，需要业务数据时通过数据服务的公开端点取。
共享的只有 `backend/shared/` 里的**无状态**模块（配置、错误码、路径、HTTP 工具、连接池工具）。

---

## 2. 请求链路

### 数据服务 `/data/*`

```
HTTP → server.js → app.js（组装）
     → auth.js（解 token，得到 user_id；身份只从 token 来，不信客户端自报）
     → db.js（BEGIN → SET LOCAL app.user_id / app.visible_students → 业务 SQL → COMMIT）
     → router.js → routes/*.js
     → JSON 响应
```

- `SET LOCAL` 必须在事务内。用会话级 `SET` 会让连接池把上一个人的身份带给下一个请求。
- 可见集合 `visible_students` 由服务端从 `relationship` 计算（家长可见 = active 孩子）。
- 未设置时 fail-closed：查不到数据，而不是放行全部。

### AI 网关 `/ai/*`

```
HTTP → server.js → app.js → router.js → routes/review.js
     → model_client.js（厂商凭证从 config 读，不落日志）
     → 降级：配额失败与网络抖动必须分开（独立错误码 + retryable:false）
```

- 路由分工：`/auth/*` 公开走 `app_auth`；其余 `/data/*` 走 `app_rls`。
- `AI_REQUIRE_AUTH` 默认 `false`，**生产必须为 true**。

---

## 3. 目录分层规则

### 前端

```
lib/config      → 构建期配置、端点常量（不依赖任何下层）
lib/core        → 网络传输、路径规则（不依赖 data / pages）
lib/data        → 模型、仓储（依赖 core）
lib/pages       → 页面（依赖 data）
```

依赖**单向向下**，上游不反向引用。端点、错误码、路径规则各只有一处定义。

### 后端

```
shared/                 无状态、无业务、两个服务共用
data-service/src/       server → app → router → routes → storage
ai-gateway/src/         server → app → router → routes → model_client
index.cjs               云函数入口（FC3），与本地 server.js 共用同一份 app
```

`app.js` 只做「组装」，不写业务逻辑；`routes/*.js` 不直接读 `process.env`。

---

## 4. 隔离模型

| 层 | 机制 |
|---|---|
| 身份 | token 的 `sub`，客户端自报的 studentId 一律不采信 |
| 家庭 | PG RLS：`student_id = ANY(app_csv_setting('app.visible_students'))` |
| 角色 | 应用连接只用非 superuser 的 `app_rls`；superuser 会绕过 RLS 且不报错 |
| 附件 | 客户端只传 id，服务端查库拿相对路径；**没有传路径的入口** |
| 可选依赖 | ima 未配置时静默降级，不抛错、不弹红条 |

`app_csv_setting()` 比直接 `string_to_array()` 多一步 `array_remove(..., '')`：
否则 `',,'` 会产生空串元素，匹配到 `student_id = ''` 的「无主行」，让那行对所有用户可见。

---

## 5. 部署形态

| 形态 | 入口 | 说明 |
|---|---|---|
| 本地开发 | `backend/*/src/server.js` | `npm run dev:data` / `dev:ai`；`health` 不连库 |
| 函数计算 FC3 | `backend/*/index.cjs` | 两函数各自打包；`shared/` 由打包脚本收拢 |
| 自托管 | 同上 + 反向代理 | 本机部署用 watchdog 直接跑源码，改服务端代码后重启 dev-server 即生效 |

⚠️ 云上两函数的 `AI_SESSION_SECRET` 必须是**同一把**。
⚠️ 连接数约束：`实例上限 × (PG_POOL_MAX + PG_AUTH_POOL_MAX) < max_connections`。

---

## 6. 配置注入的两条路径

| 谁 | 怎么拿配置 | 为什么 |
|---|---|---|
| Node 服务 | `process.env` → `backend/shared/config.js` | 密钥不进代码、不进镜像层 |
| Flutter 客户端 | `--dart-define` → `lib/config/app_config.dart` | 客户端不会读服务器上的 `.env`；连哪份库**构建期定** |

> 换后端地址 = 重新出包。改服务器 `.env` 不会影响已安装的 APP —— 这是最常见的一类
> 「配置改了却没生效」误判。
