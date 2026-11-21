# 伴学 APP · 全量工程

> **这是什么**：从在研主工程迁入的**全量可开发源码**，按 `frontend / backend / db / docs` 四分区重组。
> 2026-11-21 起**所有需求只在本仓库实现**；原工程 `projects/easy_learn_db` 只读参照，不再改。
> 迁入映射、排除清单与已知差异见 [`docs/migration.md`](docs/migration.md)。

上一轮的「整理版基线」（59 个规范骨架文件）完整保留在 [`docs/baseline/`](docs/baseline/)，
作为**目标规范形态**参考；当前运行真值是本仓 `frontend/` `backend/` `db/migrations/` 里的源码。

---

## 1. 目录结构

```
easy-learn/
├── README.md  .env.example  .gitignore  package.json
├── frontend/                     ── 完整 Flutter 工程（包名 easy_learn_app）
│   ├── lib/                      # 277 个 Dart：pages / controllers / services / repositories / models / widgets
│   ├── test/                     # 175 个 widget / 单元测试
│   ├── assets/fonts/             # NotoSansSC（PDF 导出用）
│   ├── pubspec.yaml / pubspec.lock / analysis_options.yaml / .metadata
│   └── android/ ios/ web/ windows/ macos/ linux/   # 平台工程（构建产物已剔除）
├── backend/                      ── Node 20 ESM，双服务 + 共享层
│   ├── shared/                   # env / errors / token / query / fc3-http-event
│   ├── data-service/             # src/（30 + routes 23）、scripts/（51）、index.cjs
│   ├── ai-gateway/               # src/（23：模型客户端 / 提示词 / 图形校验 / TTS）、index.cjs
│   └── scripts/                  # deploy-prepare.mjs 与云端部署脚本
├── db/
│   └── migrations/               # 001~029 共 29 个增量迁移（当前唯一真值）
├── docs/                         ── 32 份设计文档 + 迁移记录 + baseline 快照
│   ├── DETAIL.md                 # 「静默失败」全表与判据纪律，接手必读
│   ├── migration.md              # ★ 迁入映射、排除清单、已知差异
│   └── baseline/                 # 上一轮整理版基线完整快照（59 文件）
└── scripts/
    ├── verify.mjs                # 全量工程静态自检
    └── tools/  tool/             # 构建、探针、出包工具
```

## 2. 技术栈

| 层 | 技术 |
|---|---|
| 前端 | Flutter / Dart，GetX 状态管理，sqflite（客户端 DB v32），Web / Android / iOS / 桌面多端 |
| 后端 | Node.js 20 ESM，原生 `node:http`（本机）与阿里云 FC3 handler（云上）双外壳共用 `app.js` |
| 共享层 | `backend/shared/`：`env.js` `errors.js` `token.js` `query.js` `fc3-http-event.js` |
| 数据库 | PostgreSQL（云上 RDS-PG），**PG RLS** 做多家庭隔离，事务内 `SET LOCAL` |
| 存储 | 本地文件 / OSS（V4 签名），`IMAGE_DRIVER` 切换 |
| AI | 阿里云百炼为主，`ARK_*` 为可切回备份；ima 知识库为可选能力 |
| 云 | 阿里云华东1（杭州）：FC3 + RDS-PG + OSS |

## 3. 本地启动

前置：Node ≥20、Flutter SDK、PostgreSQL（本机栈可用 `dev:stack` 自带的嵌入式 PG）。

```bash
# 1) 配置：只改 .env，绝不提交
cp .env.example .env
#    把所有 CHANGE_ME 换成真实值；生产 AI_REQUIRE_AUTH 必须为 true

# 2) 装依赖（npm workspaces 一次装齐三个包）
npm install

# 3) 建库 + 跑迁移（001~029 顺序执行）
createdb easylearn
npm run db:migrate
npm run check:config

# 4) 起后端（两个终端）
npm run dev:data          # 数据服务，默认 8788
npm run dev:ai            # AI 网关，默认 8787
#    或一条起全套（含本机 PG / 附件目录 / 种子账号）：
npm run dev:stack

# 5) 起前端
cd frontend
flutter pub get
flutter run --dart-define=...   # 变量名见 lib/services/ 下的 data_config / ai_config / cloud_runtime
```

> `health` 端点不连数据库，用来区分「服务没起来」与「库没连上」。
> 客户端连哪份后端由 `--dart-define` **构建期**决定，换后端必须重新出包。

## 4. 环境变量

- `.env.example` 是**唯一允许提交**的 env 文件；值要么是 `CHANGE_ME` 占位符，要么留空由本机栈运行期生成。
- 真实工程里环境变量由各模块直接读取（见 `backend/shared/env.js`、`src/config*.js`、
  `backend/data-service/scripts/check-config.mjs`）；**完整必需变量清单以 `check-config.mjs` 为准**。
- 密钥不得写进代码或 SQL；生产口令从云控制台 / 环境变量注入，两服务共用同一把 `AI_SESSION_SECRET`（≥32 字符）。
- **本机凭据已无硬编码**：`backend/shared/dev-credentials.js` 统一提供 4 个值（3 个 PG 角色口令 + 会话密钥），
  环境变量优先；本机没配时随机生成一次并持久化到 `.dev-credentials.json`（gitignore，重启复用）。
  迁移 SQL 的口令由 `migrate.js` 在事务内 `set_config` 注入，不注入就显式报错、绝不兜底。
  仓库里保留的三个历史弱值只作**黑名单**，用于拒绝把它们粘进生产配置。
- 可选能力（ima / AI 厂商）未配置时静默降级，但降级结果必须标 `degraded:true`，不许冒充模型输出。

## 5. 数据库初始化

- **当前真值**：`db/migrations/001~029.sql`，由 `src/migrate.js` 在事务内按文件名顺序执行；文件不自带 `BEGIN/COMMIT`。
- 顺序陷阱：先 `provision-app-roles` 再 `migrate`（SQL 不含口令、角色不存在时显式报错）；
  `app_rls` 必须是非 superuser、非表 owner，否则 RLS 静默失效。
- `docs/baseline/db/001_schema.sql` 是**合并终态**，只作目标形态参考，**不能对已有库直接执行**。
- 附件路径规范（统一 `relative_path` + `rel_path` 域）尚未在迁入源码里落地，差异清单见 `docs/migration.md` §4。

## 6. 验证

```bash
npm run verify                 # 全量静态自检：规模 / 禁入项 / 语法 / 密钥 / 路径 / 入库完整性
cd frontend && flutter analyze
cd frontend && flutter test    # Windows 需先 unset *_proxy，且要 USERPROFILE 等环境变量
```

自检不替代真库执行与端到端探针。端到端探针在 `backend/data-service/scripts/probe-*.mjs`。

## 7. 交接注意事项

1. **本仓是唯一开发主目录**；原工程只读参照（里面有含真实密钥的 `.env.prod`，不要 `cp -r`）。
   本机后台（数据服务 / AI 网关 / 看门狗）已改为从本仓 `backend/` 启动，数据库与配置仍留在
   `D:\easy_learn_home`；依赖联接、回滚开关、切换判据见 [`docs/local-deployment.md`](docs/local-deployment.md)。
2. **禁入项**：`.env.prod*` / `s.yaml` / `key.properties` / APK / `*.db` / `build/` / `node_modules/` / `*.log`，
   `npm run verify` 会逐项扫描。
3. **应用只用 `app_rls`**，身份一律事务内 `SET LOCAL`；superuser 会静默绕过 RLS。
4. id 只有服务端说了算：写接口返回的那行必须被采纳。
5. 状态词 / 端点 / 错误码保持「一个语义一处定义」，改词要四处同步。
6. 每修复必须**能证伪**（还原后恰好那几条变红）；「全绿」本身不是判据。详见 `docs/DETAIL.md`。

完整迁移背景见 [`docs/migration.md`](docs/migration.md)，文档索引见 [`docs/README.md`](docs/README.md)。
