# 交接注意事项

> 面向：接手继续开发的工程师。
> 前提：先跑通 `README.md` 的「本地启动」，再读这份。

---

## 1. 先弄清楚你拿到的是什么

| | 说明 |
|---|---|
| **是** | 工程基线：目录规范、配置规范、路径规范、DDL 终态、启动与验证方式。每个文件都是完整可运行代码。 |
| **不是** | 全量业务源码，也不是可以直接上生产的成品。业务页面、AI 提示词、29 个增量迁移、175 个测试仍在原仓库。 |
| **不含** | 真实密钥、用户数据、APK、pgdata、node_modules、任何绝对路径的数据库值。 |

**第一件事**：读 `docs/source-index.md`，确认原仓库位置与迁入顺序。
**不要**用 `cp -r` 整目录搬原工程 —— 里面有 `.env.prod` 等含真实密钥的文件。

---

## 2. 接手第一周清单

1. `cp .env.example .env`，填好必填项，`npm run check:env` 通过。
2. 建空库 → `npm run db:init` → 确认 43 张表 + 字典行都在。
3. `npm run dev:data` / `npm run dev:ai`，两个 `/health` 都返回 200。
4. `npm run verify` 全绿；`cd frontend && flutter test` 通过。
5. 故意做一次**证伪**：往 `homework_image.relative_path` 插一条 `/tmp/a.jpg`，
   确认数据库报 `23514`（而不是应用报错、更不是静默成功）。
6. 把 `STORAGE_ROOT` 改到另一个目录、重启服务，确认库里数据零改动、附件仍可读。
7. 读 `doc/DETAIL.md`（原仓库）的「静默失败」全表 —— 那是这个项目真正的坑清单。

---

## 3. 「不报错、只是功能安静地不对」清单

这个项目的历史 bug 大多属于这一类。**全绿不等于没问题**，下面每条都要有能看见它的判据。

| 症状 | 常见根因 |
|---|---|
| 刚提交的数据看不到、重登就好 | 写接口返回的那行被扔了，用了占位 id |
| 按钮点了没反应 | 状态没被响应式追踪 / 路由跳转抛异常被吞 / 子组件不在追踪区 |
| 配好教材却说「题库是空的」 | 上游没生成种子，不是页面 bug —— **先查上游** |
| 照片位置一片空白、无报错 | 把旧设备本地标识当成相对键，或字段名对不上读出空串 |
| 判据一直绿 | 字段名对不上空转 / 只断结果不断过程 / 测试文件没进 runner |
| 家长看不到自己的孩子 | 状态词写错一个字母（`accepted` vs `active`），PG 合法 SQL 但永远匹配不到行 |
| 时间整体偏一天 | 客户端写不带时区的 ISO8601，或 `day::text` 比较；日期必须客户端给本地日 |
| 多家庭数据互相可见 | 用 superuser 连库 → RLS 静默失效；或用了会话级 `SET` 而非 `SET LOCAL` |
| 云上 AI 请求 25s 超时 | 新增模型 kind 漏进「禁用思维链」名单 |
| AI 批改结果是本地模板 | 降级路径没被标记为降级，拿兜底结果冒充模型结果 |
| 「配置改了没生效」 | 客户端连哪份库是**构建期** `--dart-define` 决定的，改服务器 `.env` 不影响已装的包 |

**通则**：用户说「XX 不行」，先查上游；「造了数据」≠「造对数据」；
「配置正确」≠「行为正确」；「部署 EXIT=0」≠「函数能起」。

---

## 4. 改动必须配套更新的文件

| 你改了什么 | 必须同时改 |
|---|---|
| 新增/改表 | `db/001_schema.sql` + `docs/database.md` + 原仓库客户端 DB 版本号（**三处同步**） |
| 新增路径列 | 类型必须是 `rel_path`；`docs/database.md` 列名映射表；`backend/shared/paths.js` |
| 新增环境变量 | `.env.example` + `docs/environment.md` + `backend/shared/config.js` 校验规则 |
| 新增接口 | `frontend/lib/config/api_endpoints.dart` + `backend/*/src/router.js` + 对应单测 |
| 新增状态词 | `db/002_seed.sql` + `backend/shared/errors.js`（词表）+ 客户端枚举（**逐字一致**） |
| 新增测试文件 | 测试 runner 的显式清单（原工程 `scripts/run-tests.mjs` 是显式清单，漏了不报错） |
| 新增模型 kind | 厂商开关对应的「思维链禁用名单」+ 超时配置 |
| 换后端地址 | 重新出包（`--dart-define`），APK / Web 各一份 |

> 🔴 **改同一个文件不要并行提交多个编辑**：只会有最后一个生效，前面的静默丢失。
> 改完必须 grep 确认落地。

---

## 5. 验证纪律

1. **每修一个 bug 都要能证伪**：还原改动后，恰好那几条判据变红、反面仍然绿。
   「全绿」不是判据，先确认红的是**断言**而不是编译错误。
2. **没真跑过的验证不叫通过**。拿不到可信依据时如实写「未验证」，不要编一个看起来对的结果。
3. 涉及平台 API 能力 / 限制，先拉官方文档核参数名再下结论，别凭记忆。
4. HTML/前端类产物：截图会骗人，坐标/数据不会 —— 用探针读真实值。
5. 端到端验证用真 HTTP + 真库，不要用假的 client 证明 SQL 能跑
   （假 client 证明不了 `42883` 这类类型错误）。
6. `flutter test` 前记得 `unset *_proxy`；本机还需 `USERPROFILE` 与
   `PROGRAMFILES(X86)` 两个环境变量，否则工具进程直接崩。

---

## 6. 安全红线

- **应用连接只用 `app_rls`**（非 superuser、非表 owner）。运维/迁移才用 `PG_OPS_URL`。
- **每个请求在事务内 `SET LOCAL`** 设 `app.user_id` / `app.visible_students`。
- `AI_SESSION_SECRET` 两服务同一把、≥32 字符；生产 `AI_REQUIRE_AUTH=true`。
- 密钥只在 `.env`；`.env.example` 里永远只有 `CHANGE_ME`。
- 客户端只传附件 id，**不要开「客户端传路径」的口子**。
- 可选能力（ima、AI 厂商）**不是人人都有**：未配置时静默降级，
  不弹红条、不抛异常、不拖垮主流程；只有用户主动点该功能才允许回明确反馈。
- 历史数据永久保留，不做批量删除；删账号前先备份（无外键，会留孤儿行）。

---

## 7. 部署真相（容易误判的几条）

| 项 | 事实 |
|---|---|
| 本机「部署」 | watchdog 直接跑原工程**源码**，`dist/` 只有 APK。改服务端代码后重启 dev-server 即生效 |
| 网关读哪份配置 | `config/ai.env`，**不是** `local.env` |
| 外网访问 | 自建 FRP；公网是明文 HTTP，不要传敏感数据 |
| 云上 | 华东 1（杭州）：FC3 + RDS-PG(18.4) + OSS + 百炼；`PGSSLMODE=require` |
| 迁移顺序 | 先 `provision-app-roles`，再 `migrate`；`easylearn_admin` 有 `rolbypassrls`，**绝不上函数** |
| 连接数 | `实例上限 × (PG_POOL_MAX + PG_AUTH_POOL_MAX) < max_connections` |
| 存储驱动 | `IMAGE_DRIVER` 写错直接抛，绝不静默退回；OSS 必须 V4 签名，region ≠ endpoint 地域会 403 |

---

## 8. 已验证项（2026-11-21）

| 项 | 结果 |
|---|---|
| `001_schema.sql` + `002_seed.sql` 在**全新空库**执行 | 通过：43 张表、41 行字典、44 条 RLS policy |
| `rel_path` 域拒绝绝对路径 | 插入 `/tmp/a.jpg` 报 `23514`（数据库层拒绝，不是应用拦截） |
| RLS fail-closed | 未设身份时 `app_rls` 查 `app_user` = 0 行 |
| RLS 事务内生效 | `SET LOCAL app.user_id / app.visible_students` 后 = 1 行 |
| `auth_visible_students()` | 学生本人返回 `["u1"]` |
| 双服务 HTTP | `/health` ×2 = 200；未知路径 404；坏票据 401；AI 未配置时 `degraded:true` |
| 相对路径规则 / 会话票据 | 全部反例抛错；票据签发→校验往返通过 |
| `npm run verify` | 11 项静态检查全绿（59 个关键文件、28 个 JS 语法检查） |
| 关键文件可入库 | 新增 `git check-ignore` 判据：59 个关键文件无一被忽略；证伪＝把 `/storage/` 还原成 `storage/` 后**恰好这一项变红**，其余 10 项仍绿 |

> 数据库验证用**独立的临时 PG 17.10 实例**（自建数据目录、端口 55433），
> 跑完即停并删除目录，**不接触任何现有库与数据**。
>
> 2026-11-21 本目录已 `git init -b main` 并首次提交，是**独立仓库**；
> 提交身份沿用原工程的 `李鹏 <lp_pr@localhost>`（仓库级 local 配置，未改全局）。
> 原工程 `projects/easy_learn_db` 保持只读参照，其 253 个遗留改动不在本次提交范围。

**仍未验证**：FC3 云函数真机、`flutter test` 本机编译执行、OSS 驱动与签名、
端到端上传/读取附件（需真库 + 应用账号）。接手后按 `README.md` 补跑。

---

## 9. 已知限制 / 未验证项（接手后补）

- `db/001_schema.sql` 是合并终态，**不能对已有库直接执行**（表已存在会报错）。
- RLS 策略在本包是统一后的清晰版；原仓库 `sql/002~010/018/024` 有更多演进
  （coparent 读、通知插入权限等），迁入业务代码时须逐条核对差异。
- 本包只保留最小路由示例（health / auth / attachments / review），
  其余业务路由、AI 提示词、175 个测试、29 个增量迁移都在原仓库。
- `npm run verify` 是**静态**自检（语法、密钥、路径、文件完整性），
  不替代端到端探针与真机验证。
- 前端只给了最小可运行骨架，页面/控制器/仓储需按 `source-index.md` 迁入。

---

## 10. 资料位置

| 想找什么 | 去哪 |
|---|---|
| 启动 / 技术栈 / 建库 | 根 `README.md` |
| 环境变量全表 | `docs/environment.md` |
| 路径规范 | `docs/database.md` + `db/README.md` |
| 架构与调用链 | `docs/architecture.md` |
| 原工程源码位置 | `docs/source-index.md` |
| 历史坑与判据纪律 | 原仓库 `doc/DETAIL.md` |
| 需求规格 | `D:\workbuddy-project\doc\伴学APP 详细需求规格说明书.md` |
