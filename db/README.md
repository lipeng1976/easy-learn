# 数据库脚本

## 当前真值：`migrations/001~029.sql`

29 个**增量迁移**，从原工程 `serverless/data-service/sql/` 原样迁入，文件名序号即执行顺序。

- 执行方式：`npm run db:migrate`（`backend/data-service/src/migrate.js` 在事务内按序执行），
  文件本身**不自带** `BEGIN/COMMIT`。
- 顺序陷阱：先 `provision-app-roles` 再 `migrate`。
  `app_rls` 必须是非 superuser、非表 owner；`app_auth` 带 `BYPASSRLS`，只用于认证路径。
- 多家庭隔离靠 PG RLS，应用必须在事务内 `SET LOCAL app.visible_students` / `app.user_id`。
  用 superuser 连接会让 RLS **静默失效**（不报错、只是数据全可见）。
- `002_rls.sql` / `003_session.sql` 里的 `app_rls_local_dev` / `app_auth_local_dev` 是
  **本机开发公开弱口令**，原工程既有设计；生产口令从云控制台 / 环境变量注入，不要复用。
- 时间窗参数：`date >= $2` 必须写 `$2::date`，写成 `$2::text` 会报 `42883`。
- 客户端时间必须写带时区的 ISO8601，否则 `TIMESTAMPTZ` 会按服务端时区解释，产生不报错的偏移。

## 目标形态：`docs/baseline/db/001_schema.sql`

上一轮整理的**合并终态 DDL**（43 表 / 44 条 RLS policy / `rel_path` 域）与字典种子，
是规范基线，**不是当前库的可执行脚本**：

- 不能对已有库直接跑，切换前须写一次性升级脚本并回归；
- 附件列从 `storage_key` / `file_path` / `photo_path` 统一为 `relative_path`，
  并用 `CREATE DOMAIN rel_path` 在数据库层拒绝绝对路径 / 盘符 / `..`；
- 根目录只从 `STORAGE_ROOT` 配置，不写进数据库。

差异清单与收敛顺序见 [`../docs/migration.md`](../docs/migration.md) §4。
