# 本地化搬迁记录 · 2026-10-18

> 一次实际执行的交接单。数据、附件已从阿里云搬到本机 D 盘并逐项对账。
> **代码零改动** —— 只新增了三个脚本和一份配置。

## 一、结果

| 项 | 云端 | 本机 | 判定 |
|---|---|---|---|
| 数据库 | PG 18.4 · 26 表 · 690 行 · 10 MB | PG 18.4 · 26 表 · **690 行** | ✅ 逐表一致 |
| RLS | 27 条策略 · 25 张 FORCE | **27 条 · 25 张** | ✅ 一致 |
| 迁移记录 | `schema_migrations` 10 条 | 10 条 | ✅ |
| 附件 | 127 个 · 72,057,659 B | **127 个 · 72,057,659 B** | ✅ 零缺失、零字节差 |
| 端到端 | —— | 登录 → 作业 88 条 → 附件 123 条 → 取图 92,024 B | ✅ |

附件构成：图片 122（53.75 MB）· 音频 3（12.71 MB）· 视频 2（2.26 MB）。

## 二、目录结构（全部在 D 盘）

```
D:\easy_learn_home\
├── pgsql\            PostgreSQL 18.4 二进制（解压即用，无需安装）
├── pgdata\           数据库数据目录（端口 5433，仅监听 127.0.0.1）
├── attachments\      附件根目录，按 storage_key 原样落盘
│   └── 20260924\<studentId>\<uuid>.jpg ...
├── backups\          easylearn_db-20261018.dump（131 KB）
├── config\           local.env（含明文口令）· pg-superuser.txt
├── logs\             initdb / 数据服务 / 各次验证日志
├── downloads\        pg18-binaries.zip（337 MB，可删）
├── start-pg.cmd      启动 PostgreSQL（幂等：已在跑就跳过）
└── start-backend.cmd 启动数据服务（会先确保 PG 在跑）
```

## 三、怎么起停

```cmd
D:\easy_learn_home\start-pg.cmd        :: 起数据库（5433）
D:\easy_learn_home\start-backend.cmd   :: 起数据服务（8788），已含 PG 检查

D:\easy_learn_home\pgsql\bin\pg_ctl.exe -D D:\easy_learn_home\pgdata stop
```

**开机自启已配**：`start-pg.cmd` 已复制到
`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\easylearn-postgres.cmd`。
登录 Windows 后自动起库。

⚠️ **当前没有崩溃自愈**：进程挂了不会自动重启。要真正的常驻（含崩溃恢复）
得注册 Windows 服务，而 `pg_ctl register` 需要管理员权限 —— 这次没做，见 §6。

## 四、脚本（已提交到项目）

| 脚本 | 作用 | 幂等 |
|---|---|---|
| `serverless/data-service/scripts/migrate-attachments.mjs` | OSS → 本机磁盘，按 storage_key 落盘；`--dry` 只列清单 | 已有且字节对得上就跳过 |
| `serverless/data-service/scripts/verify-local-migration.mjs` | 云端 vs 本地逐表对账 + 附件字节对账 | 只读 |
| `serverless/data-service/scripts/verify-local-e2e.mjs` | 登录 → 作业 → 附件 → 取图，走真 HTTP | 临时改密并**逐字还原** |

## 五、搬迁过程中的两个判断点（不是坑，但容易误读）

1. **`/data/homework` 默认只回 50 条**。`clampLimit` 的 `DEFAULT_LIMIT = 50`
   （`MAX_LIMIT = 200`）。第一次验收看到 50 条就报错，实际是**分页**，不是数据丢失。
   对账要用 `?limit=200` 或者直接查库。
2. **`sign-read` 只支持 OSS**，fs 后端会回 `503 direct_read_unsupported`。
   本机读附件走的是 `/data/homework/images/file`（`raw: true`，直接回字节）。

## 五点五、局域网客户端包（10-18 已出）

`node tools/build-local-apk.mjs --host 192.168.3.80 --out`，约 1 分钟（Gradle 增量）。

产物：`D:\easy_learn_home\dist\easy-learn-local-192.168.3.80-202610181105.apk`
（59.8 MB，sha256 `2175e368…`）

与云版的**三处区别**（都是构建前打补丁、构建后还原，仓库不留痕）：

| 项 | 云版 | 本机版 |
|---|---|---|
| 图标 | 蓝色书 | **绿色书**（`--icon none` 可关） |
| 应用名 | 伴学 | 伴学·本机 |
| 包名 | `cn.easylearn.app` | `cn.easylearn.app.local`（**并存，不覆盖云版**；`--same-app` 才会顶掉） |

进包判据（全部验证过）：

- 包名/应用名在 `AndroidManifest.xml`（UTF-16LE）；地址在 `libapp.so`（UTF-8）—— `apk-contains` 带反面对照
- **图标按 PNG 尺寸找（48/72/96/144/192），不能按文件名找**：AGP 资源路径缩短后
  `ic_launcher.png` 在包里叫 `res/o-.png`。第一版判据按名字找 → 构建成功却报「找不到」，
  是判据写错不是图标没进包。且大图被量化成**调色板 PNG**（colorType=3），采样要支持
- 脚本内置全部判据；失败即退出，且 15 个补丁文件无条件还原

云版 10-06 包已先另存：`build/app/outputs/flutter-apk/app-release-cloud-1006-1831.apk`。

## 六、没做的事（下一步）

| 项 | 状态 | 说明 |
|---|---|---|
| 后台常驻（P4） | ✅ 已做 | 启动文件夹 + `watchdog-supervisor` + `watchdog`（10s 探活、3 次失败重启、退避）。`schtasks` 被安全策略拉黑，故不用任务计划 |
| AI 切方舟 | 🔴 未做 | 方舟 429（额度用尽）。额度恢复后改 `AI_MODEL_PROVIDER=ark` 一个变量 |
| 客户端重出包（P6） | ✅ 已出局域网包 | 见「五点五」。外网访问（Tailscale 组网包）仍未做 |
| 云端停用 | ⏸ 未动 | 云端仍完整可用，随时可回退 |

## 七、回滚

数据侧完全可回退，因为云端一行没改：

- 本机想重来：删 `D:\easy_learn_home\pgdata` 重新 `initdb`，再跑一次导入
- 想回云端：改 `config/local.env` 的 `PGHOST` 指回云端，或用 `.env.prod`
- 原始 dump 在 `D:\easy_learn_home\backups\easylearn_db-20261018.dump`

⚠️ **云端与本机是两份互不相通的数据**。这次搬迁是**单向拷贝**，
之后如果在本机产生新数据（作业、错题），不会回流云端。
决定切换前请确认没有「两边都在用」的窗口。
