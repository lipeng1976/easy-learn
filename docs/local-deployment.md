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
