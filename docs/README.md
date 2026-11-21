# 文档索引

本仓 `docs/` 分三类：**迁入的设计文档**（原工程 `doc/` 32 份）、**迁移记录**、**整理版基线快照**。

## 接手先读

| 文档 | 内容 |
|---|---|
| [`../README.md`](../README.md) | 技术栈、本地启动、环境变量、建库、交接注意事项 |
| [`migration.md`](migration.md) | ★ 全量源码迁入映射、排除清单、已知规范差异、验收口径 |
| [`DETAIL.md`](DETAIL.md) | ★ 「静默失败」全表与判据纪律（原工程治理沉淀） |
| [`操作手册.md`](操作手册.md) | 家长端 / 学生端功能操作说明 |

## 原工程设计文档（32 份）

| 主题 | 文档 |
|---|---|
| 需求与架构 | `需求规格说明书.md`、`architecture-refactor-plan.md`、`multi-device-architecture.md`、`cloud-migration-plan.md`、`local-migration-plan.md`、`self-hosting-feasibility.md` |
| 复习与错题 | `错题闭环设计.md`、`review-vs-plan.md`、`exam-mistake-import.md`、`historical-data-plan.md`、`word-checkin-design.md`、`word-checkin-ima-prompt.md` |
| 打卡与出題 | `student-daily-checkin-layout.md`、`subject-board-design.md`、`subject-textbook-design.md`、`textbook-ima-format.md`、`concept-drill-c-plan.md`、`专注计时设计.md` |
| ima 知识库 | `ima-integration-design.md`、`open-items.md` |
| 云端与部署 | `aliyun-deploy-plan.md`、`android-deploy-guide.md`、`release-guide.md`、`stage-archive-aliyun.md`、`credential-rotation-and-hygiene.md`、`auth-extension-seams.md` |
| 厂商切换 | `volcengine-decloud-plan.md`、`volcengine-migration-plan.md` |
| 其他 | `migration-2026-10-18.md`、`parent-push-notification-todo.md` |

## 整理版基线快照（`baseline/`）

上一轮交付的 59 个规范骨架文件，**完整保留、不删除**。它们是「目标规范形态」，不是当前运行真值：

| 位置 | 内容 |
|---|---|
| `baseline/frontend/` | Flutter 分层骨架（config / core / data / pages）+ 相对路径规则判据 |
| `baseline/backend/` | 双服务最小骨架 + `shared/{config,paths,session}.js` 单点规范 |
| `baseline/db/` | `001_schema.sql` 合并终态 DDL（43 表 / 44 RLS / `rel_path` 域）+ 字典种子 |
| `baseline/docs/` | 架构、环境、数据库、源码索引、交接注意事项、文档索引 |
| `baseline/scripts/` | `init-db.mjs` / `check-env.mjs` / `create-user.mjs` / `verify.mjs` |

> ⚠️ `baseline/db/001_schema.sql` 是合并终态，**不能对已有库直接执行**；
> 现有库继续走 `db/migrations/001~029.sql`。两者差异见 [`migration.md`](migration.md) §4。
