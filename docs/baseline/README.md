# 伴学 APP · 工程交接基线

> **这是什么**：从在研主工程整理出的**标准、可移交**工程包。前端 / 后端 / 文档 / 数据库四分区，
> 每个文件都是**完整可运行代码**（无 `...` 省略、无伪代码、无占位实现），不含任何真实密钥、
> 用户数据、构建产物或数据库快照。
>
> **这不是什么**：不是全量源码副本。原工程有 277 个 Dart 文件、175 个测试、2 个 Node 服务、
> 29 个增量迁移、32 份设计文档，以及 APK / pgdata / node_modules。业务源码**留在原仓库继续开发**，
> 位置与迁入顺序见 [`docs/source-index.md`](docs/source-index.md)。
> 本包负责把「目录规范、配置规范、路径规范、DDL 终态、启动方式」固定下来。
>
> **交接必读**：[`docs/handover.md`](docs/handover.md)。

---

## 1. 目录结构

```
easy-learn/
├── .env.example                     # 唯一允许提交的环境变量文件，全部为占位符
├── .gitignore                       # 根忽略规则（密钥 / 运行期数据 / 构建产物）
├── package.json                     # npm workspaces 根，统一脚本入口
├── README.md                        # 本文件
│
├── frontend/                        # ── 前端：Flutter 应用（完整 Flutter 工程根）
│   ├── .gitignore
│   ├── analysis_options.yaml
│   ├── pubspec.yaml
│   ├── lib/
│   │   ├── main.dart                # 入口：装配 → runApp
│   │   ├── app.dart                 # GetMaterialApp / 路由表
│   │   ├── config/
│   │   │   ├── app_config.dart      # 构建期配置（--dart-define），零密钥
│   │   │   └── api_endpoints.dart   # 端点常量单一来源
│   │   ├── core/
│   │   │   ├── network/
│   │   │   │   ├── api_client.dart       # HTTP 传输层
│   │   │   │   └── api_exception.dart    # 错误码与异常
│   │   │   └── storage/
│   │   │       └── relative_path.dart    # ★ 相对路径规则（与后端同一口径）
│   │   ├── data/
│   │   │   ├── models/attachment.dart
│   │   │   └── repositories/attachment_repository.dart
│   │   └── pages/home_page.dart
│   └── test/relative_path_test.dart
│
├── backend/                         # ── 后端：Node 20+ ESM，双服务 + 共享包
│   ├── .gitignore
│   ├── shared/                      # 一处定义，两个服务共用
│   │   ├── package.json
│   │   ├── config.js                # ★ 唯一读 env 的地方；缺必需项即抛错
│   │   ├── paths.js                 # ★ STORAGE_ROOT + 相对路径 ↔ 绝对路径
│   │   ├── errors.js                # 统一错误码与状态词
│   │   ├── http.js                  # JSON / 二进制响应、请求体读取
│   │   ├── session.js               # 会话票据签发与校验（两服务共用）
│   │   └── db.js                   # pg 连接池（懒加载，health 不依赖 DB）
│   ├── data-service/                # 数据服务：/auth/* 与 /data/*
│   │   ├── package.json
│   │   ├── index.cjs                # 函数计算（FC3）入口
│   │   ├── scripts/migrate.mjs      # 按序执行 db/*.sql
│   │   └── src/
│   │       ├── server.js            # 本地 dev server
│   │       ├── app.js               # 组合中间件 + RLS 事务边界
│   │       ├── router.js
│   │       ├── auth.js                # 登录、身份解析
│   │       ├── password.js            # scrypt 口令哈希
│   │       ├── routes/{health,auth,attachments}.js
│   │       └── storage/local_driver.js   # ★ 唯一拼绝对路径的地方
│   └── ai-gateway/                  # AI 网关：模型 Key 只存在于此进程
│       ├── package.json
│       ├── index.cjs
│       └── src/
│           ├── server.js
│           ├── app.js
│           ├── router.js
│           ├── routes/{health,review}.js
│           └── model_client.js
│
├── db/                              # ── 数据库：只有 DDL 与种子，无敏感数据
│   ├── 001_schema.sql               # 全部建表 / 索引 / 约束 / RLS 策略（终态，非增量）
│   ├── 002_seed.sql                 # 字典种子（学科 / 年级 / 状态词），无账号无口令
│   └── README.md                    # 初始化顺序与迁移约定
│
├── docs/                            # ── 文档
│   ├── README.md                    # 文档索引
│   ├── architecture.md              # 架构、调用链、隔离模型
│   ├── environment.md               # 环境变量全表
│   ├── database.md                  # ★ 相对路径规范与 DB 约定
│   ├── source-index.md              # 原工程源码位置与迁入顺序
│   └── handover.md                  # ★ 交接注意事项
│
└── scripts/
    ├── init-db.mjs                  # 建角色（口令来自 env）+ 执行 DDL + 种子
    ├── check-env.mjs                # 启动前环境变量自检
    ├── create-user.mjs              # 运维建账号（口令运行期传入，不进仓库）
    └── verify.mjs                   # 静态自检：语法 / 密钥 / 绝对路径 / 文件完整性
```

---

## 2. 技术栈

| 层 | 技术 | 版本 / 约束 |
|---|---|---|
| 前端 | Flutter + Dart | Dart SDK `^3.13.2`；GetX 路由与状态；sqflite 本地库；`http` 传输 |
| 前端配置 | `--dart-define` | **构建期注入**，端点不写死、不编译期读 `.env` |
| 后端 | Node.js（ESM） | `>=20`；内置 `http`，无 Web 框架依赖 |
| 数据库驱动 | `pg` | `^8.23.0`；连接池；`SET LOCAL` 设置 RLS 会话变量 |
| 数据库 | PostgreSQL | 17 / 18；行级安全（RLS）+ 非 superuser 应用角色 |
| 附件存储 | 本地文件系统 / OSS | `IMAGE_DRIVER` 显式选择，写错直接抛错，不静默回退 |
| 部署 | 函数计算 FC3 / 本地 dev-server | `index.cjs` 为云入口；`src/server.js` 为本地入口 |
| 可选能力 | ima 知识库、AI 厂商（百炼 / 方舟） | 未配置时静默降级，不影响主流程 |

**分层规则**：`config → core/network → data/repositories → pages`。上游不反向依赖下游；
一个语义只在一个文件里定义（端点、错误码、路径规则、环境变量读取各只有一处）。

---

## 3. 本地启动

前置：Node.js ≥ 20、Flutter SDK（Dart ≥ 3.13）、一个空的 PostgreSQL 库。

```bash
# 1) 配置：.env.example 是唯一模板，复制后填真实值
cp .env.example .env
#    必改：DATABASE_URL / PG_OPS_URL / APP_RLS_PASSWORD /
#          AI_SESSION_SECRET / STORAGE_ROOT；生产另改 AI_REQUIRE_AUTH=true

# 2) 装依赖（npm workspaces 会一次装好三个包，并把 pg 提升到根 node_modules）
npm install

# 3) 环境变量自检（缺必需项会直接报错退出）
npm run check:env

# 4) 建空库（若还没有）
createdb easylearn
#    Windows/psql 亦可： psql -c "CREATE DATABASE easylearn"

# 5) 初始化数据库：建应用角色 → 001_schema.sql → 002_seed.sql
#    角色口令来自 APP_RLS_PASSWORD，DDL 文件里不含任何口令
npm run db:init

# 5b) 建首个账号（登录链路需要；口令运行期传入，绝不写进版本库）
NEW_USER_PASSWORD='<强口令>' node scripts/create-user.mjs \
  --phone 13800000000 --name 学生姓名 --role student

# 6) 起后端（两个终端，或后台各起一个）
npm run dev:data      # http://127.0.0.1:8788
npm run dev:ai        # http://127.0.0.1:8787

# 7) 起前端（构建期注入端点）
cd frontend
flutter pub get
flutter run -d chrome \
  --dart-define=DATA_API_BASE_URL=http://127.0.0.1:8788 \
  --dart-define=AI_BASE_URL=http://127.0.0.1:8787
```

健康检查与自检：

```bash
curl http://127.0.0.1:8788/health
curl http://127.0.0.1:8787/health
npm run verify          # 语法 / 密钥 / 绝对路径 / 文件完整性静态自检
cd frontend && flutter test   # 相对路径规则的单测
```

> `health` 端点不连数据库，因此**未装依赖也能起服务**，用来区分「服务没起来」与「库没连上」。

**已验证**（2026-11-21）：DDL + 种子在隔离的临时 PostgreSQL 17.10 空库执行通过
（43 张表 / 41 行字典 / 44 条 RLS policy）；绝对路径被 `rel_path` 域以 `23514` 拒绝；
RLS fail-closed 与 `SET LOCAL` 生效均通过；双服务 `/health`、AI 降级链路、票据与路径函数真跑通过。
明细见 [`docs/handover.md`](docs/handover.md) 第 8 节。

---

## 4. 环境变量说明

**唯一入口**是 `backend/shared/config.js`：所有变量只在该文件读取并校验，其余文件一律
通过 `config` 对象取值。缺必需变量时**启动即抛错**，不静默用默认值兜底。
完整表格见 [`docs/environment.md`](docs/environment.md)，模板见 [`.env.example`](.env.example)。

| 变量 | 必填 | 用途 |
|---|---|---|
| `DATABASE_URL` | 是 | 应用连接串，**必须**使用非 superuser 的 `app_rls` 角色 |
| `PG_OPS_URL` | 初始化时 | 运维连接串，仅 `scripts/init-db.mjs` 使用 |
| `APP_RLS_PASSWORD` | 初始化时 | 应用角色口令；只在 env 中，不进 SQL、不进代码 |
| `AI_SESSION_SECRET` | 是 | 会话签名密钥，≥32 字符；**两个服务必须同一把** |
| `AI_REQUIRE_AUTH` | 是 | 生产必须 `true`；本地开发可 `false` |
| `STORAGE_ROOT` | 是 | ★ 附件根目录，**唯一**配置处；库里只存相对它的路径 |
| `IMAGE_DRIVER` | 是 | `local` / `oss`，写错直接抛错 |
| `OSS_*` | `oss` 时 | 对象存储凭证，全部来自 env |
| `AI_MODEL_PROVIDER` / `BAILIAN_*` / `ARK_*` | 用 AI 时 | 厂商与模型凭证，只在网关进程内 |
| `IMA_*` | 否 | 可选能力；留空时功能静默降级，不报错 |
| `DATA_API_BASE_URL` / `AI_BASE_URL` / `*_TIMEOUT_MS` | 前端构建 | 转成 `--dart-define`，**不注入 Node 进程** |

---

## 5. 数据库初始化

`db/` 里**只有两类 SQL**：`001_schema.sql`（DDL 终态）与 `002_seed.sql`（非敏感字典种子）。
没有数据 dump、没有真实账号、没有口令、没有增量迁移历史。

```bash
# 推荐：一条命令完成「角色 → DDL → 种子」，口令从 env 注入
npm run db:init

# 或手工执行（顺序不可颠倒；角色需事先由运维创建）
psql "$PG_OPS_URL" -v ON_ERROR_STOP=1 -f db/001_schema.sql
psql "$PG_OPS_URL" -v ON_ERROR_STOP=1 -f db/002_seed.sql
```

关键约定（详见 [`db/README.md`](db/README.md) 与 [`docs/database.md`](docs/database.md)）：

1. **相对路径**：所有路径列的类型是 SQL `DOMAIN relative_path`，数据库层面用 `CHECK` 拒绝
   绝对路径（`/`、`C:`、`\`）、`..` 上跳和非法分隔。根目录只由 `STORAGE_ROOT` 配置，
   解析逻辑只在 `backend/shared/paths.js`。
2. **RLS**：应用连接必须是非 superuser 角色 `app_rls`；superuser 会绕过 RLS 且**不报错**。
   每个请求在事务内用 `SET LOCAL app.user_id` / `SET LOCAL app.visible_students` 设可见集合，
   未设置时 fail-closed（查不到数据，而不是放行全部）。
3. **建表即终态**：`001_schema.sql` 是「一次建到最终形态」的合并 DDL，不是 29 个增量迁移。
   增量迁移历史留在原仓库（见 `docs/source-index.md`），新库初始化不需要跑它们。
4. **幂等**：种子用 `ON CONFLICT DO NOTHING`，重复执行不会产生重复字典行。

---

## 6. 交接

见 [`docs/handover.md`](docs/handover.md)：接手第一周做什么、哪些坑**不报错但行为错**、
改动必须配套更新的文件、验证纪律、以及从原仓库迁入业务代码的顺序。
