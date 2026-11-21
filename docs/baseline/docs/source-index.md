# 原工程源码索引与迁入顺序

本包是**整理版基线**，业务源码仍在原仓库继续开发。

- 原仓库（本机）：`D:\workbuddy-project\projects\easy_learn_db`
- 设计文档：`D:\workbuddy-project\doc`（需求规格、AI 云端接入设计、AI 后端协议等）
- 本机部署目录：`D:\easy_learn_home`（PG 5433 / 数据服务 8788 / 网关 8787）

下文路径一律相对**原仓库根**。

---

## 1. 目录对照表

| 原仓库 | 内容 | 本包对应位置 |
|---|---|---|
| `lib/` | 277 个 Dart 文件：页面 / 控制器 / 仓储 / 服务 / 模型 / 组件 | `frontend/lib/` |
| `pubspec.yaml` / `analysis_options.yaml` | Flutter 工程配置 | `frontend/` |
| `test/` | 175 个 widget / 单元测试 | `frontend/test/`（本包只留路径规则判据） |
| `serverless/shared/` | `env.js` / `errors.js` / `token.js` / `query.js` / `fc3-http-event.js` | `backend/shared/` |
| `serverless/data-service/src/` | 30 个 JS + `src/routes/` 业务路由 | `backend/data-service/src/` |
| `serverless/data-service/sql/` | `001~029` 共 29 个增量迁移 | `db/001_schema.sql`（合并终态） |
| `serverless/data-service/scripts/` | 迁移、探针、E2E、账号脚本 | 本包只留 `scripts/init-db.mjs` 与 `verify.mjs` |
| `serverless/ai-gateway/src/` | 24 个 JS：模型客户端 / 提示词 / 图形校验 / TTS | `backend/ai-gateway/src/` |
| `serverless/deploy-prepare.mjs` | FC3 打包（含把 `shared/` 收拢进函数） | 未迁入，见 `handover.md` |
| `doc/` | 32 份设计文档（含 `DETAIL.md`、`ima-integration-design.md` 等） | `docs/`（本包只留规范类） |
| `android/` `ios/` `web/` `windows/` `macos/` `linux/` | 平台工程 | 未迁入（Flutter 平台目录随工程走） |

### 原工程的关键文件（要迁时先找这些）

| 文件 | 为什么重要 |
|---|---|
| `lib/services/database_service.dart` | 客户端 SQLite `onCreate`（DB version 32），本地表结构的真值 |
| `lib/services/cloud_runtime.dart` / `data_config.dart` / `ai_config.dart` | 构建期配置与云端运行时装配 |
| `lib/services/image_key.dart` | 分辨「旧设备本地标识」与「服务端相对键」——判错的表现是照片空白且无报错 |
| `lib/main.dart` | 装配顺序：`runApp` 之前要读完凭证、恢复会话、建好控制器 |
| `serverless/shared/vocab.js` | 状态词唯一来源（本包对应 `backend/shared/errors.js` + 字典表） |
| `serverless/data-service/src/db.js` | `SET LOCAL` 与 `resolveVisibleStudents` 的实现 |
| `serverless/data-service/src/imagestore.js` / `ossimagestore.js` | 附件存储驱动 |
| `serverless/data-service/scripts/probe-checkin-e2e.mjs` | 端到端探针（真 HTTP + 真库） |
| `doc/DETAIL.md` | 「静默失败」全表与判据纪律，交接必读 |

---

## 2. 明确不迁入的东西

| 类别 | 原因 |
|---|---|
| `node_modules/`、`.dart_tool/`、`build/` | 依赖与构建产物，由包管理器生成 |
| `serverless/data-service/.pgdata-dev/` | 本地 PG 数据目录，含真实数据 |
| `*.apk`（含 62MB 的 `easy-learn-cloud.apk`）、`*.db` 快照 | 二进制交付物与数据库快照 |
| `.env.prod`、`.env.prod.bak-*`、`s.yaml` | **含真实密钥**，一律不得进新仓库 |
| `*.log`、`out/`、`site/`、`site-old-*` | 日志与历史构建产物 |
| `serverless/*/scripts/probe-*.mjs` | 一次性探针；需要时按名回原仓库取，不随基线带走 |

> ⚠️ 复制任何目录前先跑一遍 `npm run verify`，它能查出「代码里的密钥字面量」
> 和「SQL/代码里的绝对路径」。**原仓库里有含真实密钥的 `.env.prod`，
> 不要用 `cp -r` 整目录搬。**

---

## 3. 建议迁入顺序

1. **对齐数据库**：拿 `db/001_schema.sql` 与原库 `pg_dump -s` 比对，
   列出差异（尤其 `rel_path` 域与 4 处路径列名变更），写一次性升级脚本。
   不要对已有库直接跑 `001_schema.sql`。
2. **共享层**：把 `serverless/shared/` 的词表、错误码、token 逻辑迁到
   `backend/shared/`，保持「一个语义一处定义」。
3. **数据服务**：按 `src/routes/` 逐个迁入，每个路由配套它的单测。
   先把 `attachments` 路由对齐本包的相对路径规范。
4. **AI 网关**：迁模型客户端与提示词；确认厂商凭证只从 `config` 读。
5. **前端**：`lib/config` → `lib/core` → `lib/data` → `lib/pages`，按依赖顺序迁；
   `pubspec.yaml` 依赖逐项核对。
6. **测试**：`test/` 175 个测试整体迁入，先跑通再改。
7. **文档**：把 `doc/` 里的设计文档按主题归到 `docs/`，保留 `DETAIL.md` 的坑清单。

每迁一层跑一次 `npm run verify` + `flutter test` + `/health`，
不要攒到最后一次性验证。

---

## 4. 环境差异（迁入时必须知道）

| 项 | 原工程 | 本基线 |
|---|---|---|
| SQL 形态 | 29 个增量迁移 | 1 个终态 DDL + 1 个种子 |
| 附件列 | `storage_key` / `file_path` / `photo_path` | 统一 `relative_path`（`source_path` 保留） |
| 角色口令 | 写在 `002_rls.sql` 里（开发用） | 只在 `APP_RLS_PASSWORD`，SQL 里没有 |
| 配置读取 | 各模块直接读 `process.env` | 只在 `backend/shared/config.js` |
| 云上厂商 | 阿里云 FC3 / RDS-PG / OSS + 百炼 | 保持；`ARK_*` 为可切换备份 |
| 客户端连库 | `--dart-define` 构建期决定 | 相同，换后端必须重新出包 |
