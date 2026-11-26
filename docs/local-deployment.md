# 本机后台部署与看门狗（2026-11-21 切换后）

本仓是**唯一源码真值**。本机后台（数据服务、AI 网关）已从旧工程切到本仓 `backend/`，
数据库、附件、配置、日志与看门狗仍留在 `D:\easy_learn_home`。两套目录的分工如下：

| 目录 | 职责 | 是否进 git |
|---|---|---|
| `D:\workbuddy-project\handover\easy-learn\` | 前端 / 后端 / DB / 文档全量源码；`--dart-define` 构建客户端 | ✅ 本仓 |
| `D:\easy_learn_home\` | PostgreSQL 数据目录、附件、config/*.env、备份、日志、watchdog 脚本 | ❌ 本机运行数据 |
| `D:\workbuddy-project\projects\easy_learn_db\` | 旧工程，**只读参照**；保留依赖目录供本机联接使用 | ❌ 不再提交 |

## 1. 启动链路

```
启动文件夹\easylearn-watchdog.cmd
  └─ node watchdog-supervisor.mjs      常驻；watchdog 退出 5s 后重开
       └─ node watchdog.mjs            每 10s 探活，连续 3 次失败就杀 PID 重起
            ├─ PostgreSQL :5433        TCP 探活；PGDATA/二进制都在 easy_learn_home
            ├─ 数据服务 :8788           cwd = <本仓>\backend\data-service
            ├─ AI 网关 :8787            cwd = <本仓>\backend\ai-gateway
            └─ frpc                    公网 13390/13391 → 本机 8788/8787
```

判据是**业务端点**而非进程存在：进程活着但事件循环卡死时，进程判据会报「一切正常」。
两个 node 服务用 `detached:true` 启动，所以重启看门狗不会连带杀掉它们。

## 2. 改了什么（2026-11-21）

| 文件 | 改动 |
|---|---|
| `D:\easy_learn_home\watchdog.mjs` | `PROJ` 默认值 → 本仓；`cwd` 拼接 `serverless` → `backend`；env 仍读 `ROOT/config/*.env` |
| `D:\easy_learn_home\easylearn-watchdog.cmd` | 显式设 `EASYLEARN_PROJ`，并保留 CRLF |
| `D:\easy_learn_home\start-backend.cmd` | `PROJ` 与 `cd /d` → 本仓 `backend/data-service` |
| `D:\easy_learn_home\start-gateway.cmd` | 同上 → `backend/ai-gateway` |
| `D:\easy_learn_home\start_8788.cjs` | 硬编码 `CWD` → 本仓 `backend/data-service` |

**数据库一行没动**：`config/local.env` 里的 `PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE`
仍指向原有库，新代码从同一组变量读；会话密钥仍是两服务同一把 `AI_SESSION_SECRET`。

## 3. 依赖目录联接（重要）

`backend/data-service/src/db.js` 用 `import pg from 'pg'`，本仓不提交 `node_modules`。
本机用目录联接复用旧仓库已装好的依赖：

```
目标（真实内容）：D:\workbuddy-project\projects\easy_learn_db\serverless\data-service\node_modules
联接（本仓内）  ：D:\workbuddy-project\handover\easy-learn\backend\data-service\node_modules
```

重建命令（**仅本机**，旧仓库被清理或服务报 `ERR_MODULE_NOT_FOUND: pg` 时执行）：

```powershell
New-Item -ItemType Junction `
  -Path 'D:\workbuddy-project\handover\easy-learn\backend\data-service\node_modules' `
  -Target 'D:\workbuddy-project\projects\easy_learn_db\serverless\data-service\node_modules'
```

- `ai-gateway` 零第三方依赖，不需要联接。
- `scripts/verify.mjs` 的遍历显式跳过 `node_modules`，联接存在时自检仍全绿。
- 联接被 `.gitignore` 忽略，`git status --ignored` 会显示它是**预期行为**。
- 若要彻底独立：先删联接，再在 `backend/data-service` 执行 `npm install`（包版本见其 `package.json`）。

## 4. 日常操作

- **改了本仓后端代码**：杀掉 8787/8788 的监听 PID，看门狗约 25–35s 后用新代码拉起。
  日志 `D:\easy_learn_home\logs\watchdog.log` 会出现
  `▶ 已启动 pid=…（cwd=D:\workbuddy-project\handover\easy-learn\backend\…）`。
- **改了 watchdog / 启动脚本本体**：这些脚本的运行真值在 `D:\easy_learn_home`（部署目录，
  非源码目录）。改完需重启 watchdog 进程；外层 supervisor 会自动拉起新版。
- **改环境变量**：只改 `D:\easy_learn_home\config\local.env` / `ai.env`，不要改本仓
  `.env.example`（那是占位示例）。改 `AI_SESSION_SECRET` 必须两边同时改且两服务重启。
- **换源文件根目录**：设 `EASYLEARN_PROJ` 环境变量；这是唯一开关，不要满仓搜路径硬改。

## 5. 回滚（保留退路）

旧工程 `projects/easy_learn_db` 只读保留，未删任何文件。回滚步骤：
在 `easylearn-watchdog.cmd` 里把 `EASYLEARN_PROJ` 改回 `D:\workbuddy-project\projects\easy_learn_db`，
杀 watchdog 让 supervisor 重起，再杀两个 8787/8788 进程即可。
数据库、附件、配置、FRP 全程不用动 —— 这也是「源码与运行数据解耦」的直接收益。

## 6. 2026-11-21 切换验收（真跑）

| 项 | 结果 |
|---|---|
| 新目录独立端口 18788 用原有 `local.env` 起服务 | `/health` 200，`instanceId=easylearn-home-36148178` |
| 新目录 `createPool` 连原有库 | `current_user=app_rls`，43 张表；RLS 未设身份 0 行（fail-closed） |
| 重启 watchdog | supervisor 用新配置拉起 `pid=60072` |
| 杀两个旧服务后恢复 | 约 **25s** 恢复；日志 cwd 明确为本仓 `backend\...` |
| 本机 health | `:8788/health` 200、`:8787/ai/health` 200，instanceId 与切换前一致 |
| 公网 FRP | `8.138.227.136:13390/health` 与 `:13391/ai/health` 均 200；FRP 4s 后恢复探活 |
| 业务端点 | `GET /auth/me` 无票据 → 401；`POST /auth/login-wechat` → 501（路由表与鉴权链路正常） |
| 本仓 `npm run verify` | 12 项全绿；联接存在时不误报 |

> 切换前已把 5 个部署脚本备份到
> `D:\workbuddy-project\handover\_backup-local-deploy-20261121\`（无密钥）。

## 7. 客户端 APK：用新目录出包（2026-11-21 真跑）

**命令（仓库根执行，本机版·FRP）：**

```bash
node scripts/tools/build-local-apk.mjs \
  --host 8.138.227.136 --data-port 13390 --ai-port 13391 \
  --instance-id easylearn-home-36148178 --out
```

- 脚本已按移交后的布局修正：`scripts/tools/` 为脚本目录，**Flutter 项目根是 `frontend/`**。
  `build-local-apk.mjs` 与 `make-app-icon.mjs` 都从这里定位 `android/`、manifest、
  `network_security_config.xml` 和 Gradle；旧布局那套 `resolve(here, '..')` 会指到
  `scripts/`，补丁全部打空。
- `--out` 把 APK 另存到 `D:\easy_learn_home\dist\easy-learn-local-<host>-<时间>.apk`；
  构建产物本体在 `frontend/build/app/outputs/flutter-apk/app-release.apk`。
- `--data-port/--ai-port` **不能省**：FRP 对外是 13390/13391，脚本默认 8788/8787
  （那是本机直连端口，手机上不通）。`--instance-id` 与 `config/local.env` 一致，
  客户端探测 `/health` 时会核对它，防止连到同网段别人的机器。

**签名材料**（按规则不入库，复制自旧工程，仅本机使用）：

```
projects/easy_learn_db/android/key.properties          → frontend/android/key.properties
projects/easy_learn_db/android/app/release-keystore.p12 → frontend/android/app/release-keystore.p12
```

新包与 `easy-learn-local-20261028.apk` 的 v2 签名证书 SHA-256 完全相同
（`5E:45:01:5D:…:9C:D3:83`），所以能**直接覆盖安装**，不必先卸载、不会丢数据。
构建日志里没有「release 但用 debug key」警告，即 Gradle 确实读到了发布签名。

**本次验收：** 预检（FRP 两个 health 200 + 实例标识一致）→ 图标补丁（绿色采样
`rgb=58,217,160`）→ 应用名「伴学·本机」→ 包名 `cn.easylearn.app.local` →
release 构建 248s → 包内 `lib/*/libapp.so` 三个 ABI 都含两个 FRP 地址与实例标识 →
`npm run verify` 12 项全绿。产物 SHA-256
`0dc249c25fcc8995371606049e41437619df1ed09c3985d933bd916cd33bc84a`。

> `npm run verify` 的禁入项/大文件/绝对路径扫描现在以 **git 会跟踪的文件**为准
> （`git check-ignore`），因此 `frontend/build/`、`frontend/.dart_tool/`、签名材料
> 这些本机产物存在时不会误报；未忽略的 `fake.env.prod` 仍会立刻把禁入项判红。

## 8. 前台自我更新（2026-11-26）

**目标**：每次重新编译本机 APK 后，已装旧版在前台收到提醒，用户**手工**选择是否升级；
绝不后台自动下载或静默安装。

**服务端**（`backend/data-service/src/routes/app_update.js`，两条公开路由）：

| 端点 | 作用 |
|---|---|
| `GET /app/update` | 读 `UPDATE_PACKAGE_DIR/manifest.json`，回 `{available, latest}`；没配目录/没生成清单回 `available:false`，静默 |
| `GET /app/download` | `raw: true`，按清单点名的 APK 回字节；`fileName` 必须裸名 + `.apk`，挡 `../` 穿越 |

- 公开而非挂 `AuthGuard`：旧版可能因 bug 根本登不进去，更新检查必须在登录前可用。
- `manifest.json` 只回契约字段（versionCode/versionName/changelog/fileName/size/sha256/publishedAt），
  不回清单里的内部字段，也不回绝对路径。
- 本机 `D:\easy_learn_home\config\local.env` 加 `UPDATE_PACKAGE_DIR=D:/easy_learn_home/app-updates`。
  改完要重启数据服务（看门狗会拉起）。

**客户端**：

- `UpdateController.currentVersionCode` 读 `APP_VERSION_CODE` dart-define（默认 1）。
- `main.dart` 冷启动后 post-frame 静默检查一次；有新版本弹确认框，只显示「下载并更新 / 稍后」。
- 个人页「版本更新」卡片可手工触发；没有更新包时整卡不渲染。
- 下载走 `http.StreamedResponse` 流式写 `getTemporaryDirectory()`，按 `sha256` 校验；
  校验失败删掉坏包（否则下次会被相同大小骗过不再重下）。主地址失败自动切 FRP 备用。
- 安装走 `MethodChannel('cn.easylearn.app/updater')` → Android `FileProvider` +
  `ACTION_VIEW`。**卓易通容器能否拉起安装器未实测**：失败时 Dart 端显示 APK 完整路径，
  让用户去文件管理器手动点装；绝不把「intent 发出去」说成「装好了」。

**构建脚本**（`scripts/tools/build-local-apk.mjs`）：

- 每次构建用 epoch 秒当 `versionCode`（`--build-number` + `APP_VERSION_CODE` 双写），
  解决历史所有包 `versionCode=1` 导致无法判断新旧的问题；2038 年前不溢出。
- 构建成功后把 APK 和 `manifest.json` 一起拷到 `UPDATE_PACKAGE_DIR`；
  `--changelog "…"` 可指定更新说明，`--no-publish` 可只构建不发布。
- 清单先写临时文件再整体覆盖，避免客户端读到半截 JSON。

**验收（真跑）**：

- 服务端 7 条判据真跑通过；证伪：临时去掉公开 raw 分支，恰好「APK 必须是 Buffer」那条红。
- 客户端 7 条判据真跑通过；证伪：临时关掉 sha256 校验，恰好「sha256 不匹配」那条红。
- 真 HTTP：`GET /app/update` 回 `versionCode=1795656761`；`GET /app/download` 回 200 +
  `application/vnd.android.package-archive` + 77,971,251 字节，首字节 `PK`；
  公网 `8.138.227.136:13390/app/update` 同样 200。
- APK `aapt dump badging` 的 versionName=`1.0.0+202611260132`；三个 ABI 的 `libapp.so`
  都含该字符串；v2 签名指纹与 10-28 旧包一致，可直接覆盖安装。
- `npm run verify` 12 项全绿；`flutter analyze` 无 error（仅剩 2 条历史 info）。

**已知历史遗留**（非本次引入，未改）：`npm test` 的 `quota-positions` 判据、
前端 5 条跨栈对照/批处理测试仍读迁移前路径（`serverless/...`、`lib/...`、`tools/`），
因此全量套件里有 6 条红；本次新增判据独立全绿。
