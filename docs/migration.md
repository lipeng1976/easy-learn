# 全量源码迁入记录（2026-11-21）

## 目标与验收口径

虫子 11-21 定：**后续所有需求只在本仓库实现**，因此本目录必须包含全量可开发源码，不能只是规范骨架。

| 验收项 | 判据 |
|---|---|
| 前端源码齐全 | `frontend/lib/` 277 个 Dart、`frontend/test/` 175 个测试，逐目录与原工程文件名清单一致 |
| 后端源码齐全 | `backend/{shared,data-service,ai-gateway}/` 的 JS 文件数与原工程一致 |
| SQL 齐全 | `db/migrations/` 恰好 `001~029` 共 29 个增量迁移 |
| 文档齐全 | `docs/` 含原工程 `doc/` 32 份设计文档 |
| 无禁入项 | 全仓零命中：`.env.prod*`、`.env.volc.local`、`s.yaml`、`key.properties`、`*.apk`、`*.db`、`*.log`、`node_modules/`、`.pgdata*/`、`build/`、`site*/` |
| 无密钥 | `scripts/verify.mjs` 扫描密钥字面量与 SQL 口令，零命中 |
| 可运行 | `node --check` 全量 JS 通过；`npm run verify` 全绿；Flutter 侧 `analyze`/`test` 结果如实记录 |
| 版本库 | 一次提交，工作区 clean |

> 「文件在磁盘」不等于「会进版本库」：提交前用 `git status --ignored` 与 `git check-ignore` 复核。

---

## 1. 四分区映射

| 原工程 `projects/easy_learn_db/` | 本仓库 | 说明 |
|---|---|---|
| `lib/`（277 Dart） | `frontend/lib/` | 保持原子目录，不重排、不改名 |
| `test/`（175） | `frontend/test/` | 含 `helpers/` |
| `pubspec.yaml` / `pubspec.lock` / `analysis_options.yaml` / `.metadata` | `frontend/` | 包名 `easy_learn_app` |
| `assets/` | `frontend/assets/` | 字体等 |
| `android/` `ios/` `web/` `windows/` `macos/` `linux/` | `frontend/` 同名目录 | 只取平台工程，剔除构建产物与本机配置 |
| `serverless/shared/`（6） | `backend/shared/` | 原样 |
| `serverless/data-service/`（src 53 + scripts + index.cjs + package*.json） | `backend/data-service/` | `sql/` 单独归 `db/` |
| `serverless/ai-gateway/` | `backend/ai-gateway/` | 原样 |
| `serverless/scripts/` + `deploy-prepare.mjs` | `backend/scripts/` | 部署脚本 |
| `serverless/data-service/sql/001~029` | `db/migrations/` | **当前真值是增量迁移** |
| `doc/`（32 份） | `docs/` | 与本仓规范文档并存 |
| `tools/` `tool/` | `scripts/tools/` | 构建、探针、出包工具 |
| `serverless/data-service/test/`（31） | `backend/data-service/test/` | 契约测试，首次漏迁后补 |
| `serverless/ai-gateway/test/`（16） | `backend/ai-gateway/test/` | 契约测试，首次漏迁后补 |
| `serverless/ai-gateway/{scripts,examples}/`（25） | `backend/ai-gateway/` 同名目录 | 探针脚本与模型 stub，首次漏迁后补 |
| 顶层 `scripts/`（空目录） | 不迁 | 无内容 |

## 2. 排除清单（严禁进仓库）

| 类别 | 具体 |
|---|---|
| 真实密钥 | `.env.prod`、`.env.prod.bak-*`、`.env.prod.example`、`.env.volc.local`、`serverless/ai-gateway/.env.local`、`s.yaml`、`android/key.properties`、`android/local.properties` |
| 数据库与数据 | `.pgdata-dev/`、`android_db_*.db`、`*.db`、`*.sqlite`、`*.dump` |
| 二进制交付物 | `easy-learn-cloud.apk`（62MB）、`build/` 下全部 APK / zip |
| 构建与依赖 | `build/`（4.1G）、`node_modules/`、`android/.gradle/`、`android/.kotlin/`、`android/app/{build,debug,profile,release}/`、`.dart_tool/`、`site/`、`site-old-*/` |
| 日志与临时 | `*.log`、`.devstack.log`、`.dstests.log`、`tmp_test.log`、`nul`、`.workbuddy-tmp/`、`.run3.txt` 等探针输出；`serverless/data-service/{out,build}/`（12+15 个日志/探针输出） |
| 平台 IDE 配置 | `*.iml`、`.idea/` |

> 只用白名单复制，**禁止 `cp -r` 原工程整目录**。

## 3. 整理版基线的去向

上一轮交付的 59 个骨架文件是「目标规范形态」，不是当前运行真值。为避免同名文件混放造成「一个语义两处定义」，整体快照移到 `docs/baseline/`，**不删除**：

- `docs/baseline/frontend/`、`backend/`、`db/` —— 骨架代码
- `docs/baseline/docs/` —— 7 份规范文档快照
- `docs/baseline/scripts/`、`README.md`、`.env.example`、`.gitignore`、`package.json` —— 骨架配套

根目录继续保留并按真实工程改造：`README.md`、`.env.example`、`.gitignore`、`package.json`、`scripts/{init-db,check-env,create-user,verify}.mjs`。

## 4. 已知规范差异（本次**不**改，后续按需求逐项收敛）

迁移是结构搬迁，**不改业务语义**，避免一次性大规模重命名破坏「行为零变化」。以下差异列为待办：

| 项 | 当前真值（迁入的源码） | 目标规范（baseline） |
|---|---|---|
| 附件列名 | `storage_key` / `file_path` / `photo_path` | 统一 `relative_path` + `rel_path` 域 |
| 数据库形态 | `db/migrations/` 29 个增量 | `docs/baseline/db/001_schema.sql` 合并终态 |
| 环境变量 | 各模块直接读 `process.env` | `backend/shared/config.js` 单点 |
| 会话票据 | `shared/token.js` | `backend/shared/session.js` |
| 路径规则 | `imagestore.js` / `ossimagestore.js` | `paths.js` + `local_driver.js` |
| 种子 | `seed-demo.mjs` 等运行期脚本 | `docs/baseline/db/002_seed.sql` 字典种子 |

> ⚠️ `docs/baseline/db/001_schema.sql` 是**合并终态**，不能对已有库直接执行；
> 现有库继续走 `db/migrations/`。切换前须写一次性升级脚本并回归。

## 5. 执行记录（2026-11-21）

| 验收项 | 结果 |
|---|---|
| 逐目录文件名清单对比 | `lib` 277/277、`test` 175/175、`assets` 1/1、`shared` 6/6、`data-service/src` 53/53、`data-service/scripts` 51/51、`sql→migrations` 29/29、`ai-gateway/src` 23/23、**diff 全为 0** |
| 补迁遗漏 | 首次迁移漏了服务端契约测试；补 `data-service/test` 31、`ai-gateway/test` 16、`ai-gateway/scripts` 23、`examples` 2，并把它们写进 `verify.mjs` 规模判据 |
| 32 份设计文档 | 全部在 `docs/` |
| 体积 | 清理 `windows/flutter/ephemeral/`（278MB PDB + 46MB DLL）后：全仓 14MB |
| 权威清单对比 | 原工程 `git ls-files` 共 **749** 个跟踪文件，按四分区映射逐条检查 → **缺失 0**。10 个「根级未映射」中 4 个是中文文档名被 git 引号转义的假阳性，其余为 `.env.prod.example` / `s.yaml`（含密钥，刻意排除）与被本仓重写的 `README.md` / `.gitignore` / `.gitattributes` / `app-identity.json` |
| 禁入项 | `.env.prod*` / `s.yaml` / `key.properties` / `*.p12` / APK / `*.db` / `*.log` / `node_modules` / `build` / `pgdata` 全部零命中 |
| 平台生成物 | `cp -r android` 曾带进 `release-keystore.p12`（**签名密钥**）与 Flutter 生成物（`gradle-wrapper.jar`、`gradlew`、`Generated.xcconfig`、`GeneratedPluginRegistrant.*`）。原工程也没跟踪它们；已全部从工作区删除，`git status --ignored` 现为空 |
| `npm run verify`（迁入当时） | **11 项全绿**，1 条已知差异提示（本机开发口令）；JS 语法 251 个文件通过。**该差异 11-21 已收敛，现为 12 项 0 提示，见 §7** |
| 判据证伪 | ① 注入硬编码绝对路径代码行 ⇒ 恰好「绝对路径」红；② 移走一个非关键测试文件 ⇒ 恰好「源码规模」红；③ 放一个假 `.p12` ⇒ 恰好「禁入项」红。三次还原后均恢复全绿 |
| 未验证 | `flutter pub get` / `analyze` / `test` 本次**未执行**（新目录尚未装 Flutter 依赖）；真库跑迁移、端到端探针、云上 FC3 均未跑 |

> 接手后第一步：`cd frontend && flutter pub get && flutter analyze && flutter test`，
> 再按 `README.md` 起本机栈跑 `backend/data-service/scripts/probe-*.mjs`。

## 6. 遗留差异（未改项）

1. ✅ **本机开发公开弱口令 —— 已收敛（11-21）**，见 §7。
2. **探针脚本里的本机绝对路径默认值**：`D:/easy_learn_home/...`、`D:/easylearn/image`、
   `C:\Windows`（`process.env.SystemRoot` 兜底）保留；数据库里不存绝对路径。
   `verify.mjs` 只扫生产代码/SQL 的代码行，注释示例与测试反例放行。
3. **规范未落地**：`relative_path` 域、`config.js` 单点、合并终态 DDL 仍在 `docs/baseline/`，
   见 §4。后续按需求逐项收敛，不要一次性全仓重命名。
4. **部署/探针脚本仍引用旧 `serverless/` 路径**：全量迁入改成 `backend/` / `db/`
   后，`backend/scripts/deploy-prepare.mjs`、`deploy-check.mjs` 及多个 `probe-*.mjs`
   里的 `REPO` 拼接与文档命令尚未批量改写。本次只修了本机栈启动链上必需的两处
   （`sqlDir`、`gatewayRoot`），其余不在本次范围，跑云端部署脚本前需单独收敛。

## 7. 已收敛：本机凭据零硬编码（2026-11-21）

### 改了什么

| 层 | 改动 |
|---|---|
| 新增 | `backend/shared/dev-credentials.js`：4 个凭据（PG 3 个角色口令 + 会话密钥）唯一来源。环境变量优先（`PG_ADMIN_PASSWORD` / `APP_RLS_PASSWORD` / `APP_AUTH_PASSWORD` / `AI_SESSION_SECRET`）；本机没配时随机生成一次并持久化到 `.dev-credentials.json`（gitignore，重启复用，避免踢下线 / 连不上旧库）。环境变量齐全时完全不碰本地文件。 |
| SQL | `002_rls.sql` / `003_session.sql` 改为 `current_setting('app.dev_*_password')` + `EXECUTE format(... PASSWORD %L, pw)`；口令由 `migrate.js` 在事务内 `set_config` 注入。**没注入且角色不存在 ⇒ `RAISE EXCEPTION`**，绝不退回默认值。 |
| 迁移器 | `runMigrations(client, sqlDir, options)` 新增 `options.rolePasswords`，仅本机开发栈与临时测试库传；生产 `migrate.mjs` 不传，强制「先 provision 后迁移」。 |
| 本机组态 | `pg-local.js` 的 `LOCAL_PG.*.password` 改为 getter 读取凭据模块，既有 `LOCAL_PG.app.password` 读法不变，`list-accounts` / `reconcile` / `report-storage` 等脚本自动同源。 |
| 开发栈 | `dev-stack.mjs` 去掉固定会话密钥默认值，改用运行期凭据；`--run` 等所有既有行为保留。 |
| 文档 / 配置 | `.env.example` 补 4 个变量（留空合法）；`migrate.mjs`、`deploy-prepare.mjs`、`release-guide.md`、`README.md`、`db/README.md` 里「迁移会建出开发口令」的过时说法全部改正。 |

**三个历史弱值仍以字面量出现在仓库里，但只作黑名单**：`shared/env.js` 的
`DEV_STACK_SECRET`、`provision-app-roles.mjs` 的 `DEV_PASSWORDS`、`deploy-prepare.mjs`
的 `SECRET_BANNED`。它们用于拒绝「有人把旧值粘进生产配置」；删掉等于少一道护栏。
`verify.mjs` 第 9 条只禁「把值当凭据用」的写法，黑名单集合 / 注释 / 测试断言放行。

### 行为变化（只有两处）

1. 生产直接跑 `migrate.mjs` 且角色不存在时，从「静默建出弱口令」变成**显式报错**。
   正确顺序本来就是先 `provision-app-roles.mjs`，这次把它变成强制的。
2. 本机演示栈的 4 个凭据从固定公开值变成**随机值**，首次生成后持久化；
   「一条命令起全套」仍然零配置可用，但旧 `.pgdata-dev` 数据目录需 `--reset` 重建
   （角色口令已变）。

### 验证（真跑）

| 项 | 结果 |
|---|---|
| `npm run verify` | **12 项全绿**（第 9 条从「已知差异警告」升级为硬判据，0 条提示） |
| 判据证伪 ×3 | ① SQL 写回 `PASSWORD 'app_rls_local_dev'`；② `pg-local.js` 写回 `password: '...'`；③ `dev-stack.mjs` 写回 `?? 'dev-stack-secret...'`。三次都恰好第 9 条变红、其余 11 项仍绿，还原后 12 项全绿 |
| 隔离临时 PG 17 空库 | 不注入口令 ⇒ `002_rls.sql` 报「缺少 app_rls 口令」且事务回滚（已提交迁移仅 `001_schema.sql`）；注入后 **29 个增量迁移全通过 / 43 张表 / 48 条 RLS 策略 / 两个角色口令已设置** |
| 凭据模块 | 4 个互不相同的随机值 ≥32 字符 / 重启复用 / env 优先且零副作用 |
| 本机 `dev:stack` 回归 | 复用原工程依赖、独立端口 `--no-ai --no-seed --port 18788 --pg-port 55433 --run` 真跑：29 个迁移全部应用、数据服务 `/health` 200、`STACK_RUN_OK`、自动收栈 rc=0 |
| 顺带修复 | `pg-local.js` 的 `sqlDir` 指向 `db/migrations/`、`dev-stack.mjs` 的 `gatewayRoot` 指向 `backend/ai-gateway`（迁入后路径错位，原本会让本机栈「迁移无新增却一张表都没有」） |
| 未跑 | `flutter analyze/test`、云上 FC3、OSS 驱动、完整端到端探针 |

> 验证用的临时 PG 实例、依赖目录联接、`.pgdata-dev`、`.dev-credentials.json`、
> 附件临时目录均已清理；`git status --ignored` 为空。
