# 数据库脚本说明

本目录**只有两类 SQL**：

| 文件 | 内容 | 是否含数据 |
|---|---|---|
| `001_schema.sql` | DDL 终态：43 张表、索引、约束、`rel_path` 域、RLS 策略、授权 | 无 |
| `002_seed.sql` | 非敏感字典种子：学科 / 年级 / 状态词 / 难度 | 仅字典行 |

没有数据 dump、没有真实账号、没有口令、没有增量迁移历史、没有绝对路径。

---

## 执行顺序

```bash
# 推荐（角色口令从 env 注入，单事务，失败即回滚）
npm run db:init

# 手工执行（顺序不可颠倒）
psql "$PG_OPS_URL" -v ON_ERROR_STOP=1 -f db/001_schema.sql
psql "$PG_OPS_URL" -v ON_ERROR_STOP=1 -f db/002_seed.sql
```

`001_schema.sql` 与 `002_seed.sql` **不自带** `BEGIN` / `COMMIT`：
`scripts/init-db.mjs` 把「建角色 + DDL + 种子」包在一个事务里，避免留下半套表。
手工执行时每条 `psql` 各自成事务，失败要整库重来，所以务必带 `-v ON_ERROR_STOP=1`。

---

## 应用角色与口令

DDL 里只有：

```sql
CREATE ROLE app_rls LOGIN;   -- 无口令
```

口令由 `scripts/init-db.mjs` 读取 `APP_RLS_PASSWORD`，用 `ALTER ROLE ... PASSWORD` 设置。
**口令不进 SQL 文件、不进代码、不进版本库。**

⚠️ 应用连接串 `DATABASE_URL` 必须使用 `app_rls`。
用 superuser / 表 owner 连接时 **RLS 会被静默绕过**（`FORCE ROW LEVEL SECURITY`
也拦不住 superuser），症状是「多家庭数据互相可见，且不报任何错」。
运维脚本、对账、迁移才用 `PG_OPS_URL`，那是刻意绕过。

---

## 相对路径规范（★ 硬约束）

### 数据库侧

`001_schema.sql` 定义了 SQL 域：

```sql
CREATE DOMAIN rel_path AS TEXT CHECK (
  VALUE = '' OR (
    left(VALUE, 1) <> '/'                  -- 非 Unix 绝对路径
    AND left(VALUE, 1) <> chr(92)         -- 非 UNC / Windows 根
    AND position(chr(92) in VALUE) = 0    -- 统一用 / 分隔
    AND position('..' in VALUE) = 0       -- 无路径穿越
    AND substring(VALUE from 2 for 1) <> ':'  -- 无盘符
    AND right(VALUE, 1) <> '/'            -- 必须指向文件
  )
);
```

所有路径列**类型都是 `rel_path`**，插入绝对路径会在数据库层直接被拒：

| 表 | 列 | 旧工程列名 | 存什么 |
|---|---|---|---|
| `homework_image` | `relative_path` | `storage_key` | `YYYYMMDD/<studentId>/<uuid>.jpg` |
| `review_mistake_image` | `relative_path` | `storage_key` | 同上 |
| `review_paper` | `relative_path` | `file_path` | 导出 PDF 的相对路径 |
| `review_paper_item` | `relative_path` | `photo_path` | 作答照片的相对路径 |
| `subject_book` | `source_path` | 同名 | ima 知识库内的逻辑路径 |
| `reading_book` | `source_path` | 同名 | 同上 |
| `word_book` | `source_path` | 同名 | 同上 |

> 类型做成 `DOMAIN` 而不是「每张表各写一条 CHECK」，是为了让规则只有一处定义：
> 新增附件表时只要声明成 `rel_path`，全部约束自动继承。

### 配置侧

根目录**只**由 `STORAGE_ROOT` 配置（见 `.env.example`）：

```dotenv
STORAGE_ROOT=./var/storage
```

解析只发生在 `backend/shared/paths.js`：

```js
resolveStoragePath('20261121/stu_001/ab12cd34.jpg')
// → <项目根>/var/storage/20261121/stu_001/ab12cd34.jpg
```

`backend/data-service/src/storage/local_driver.js` 是**唯一**把相对路径拼成绝对路径的地方，
并且在拼完后二次校验结果仍在根目录内。读附件走 `GET /data/attachments/:id`：
客户端只传 id，服务端查库拿相对路径，**客户端传路径的入口根本不存在**。

### 迁移旧数据

旧库里可能有设备本地标识或绝对路径历史值（原工程在 2026-09-20 之前写下）。
它们不是坏数据，但**不能原样搬进新库**：先跑一次相对化转换（剥离根目录前缀、
反斜杠换 `/`、去掉盘符），转换不了的行标记为待补传，不要硬塞。
转换脚本属于一次性运维动作，不进 `db/`。

---

## RLS 约定

- 每个请求在**事务内**用 `SET LOCAL app.user_id` 与 `SET LOCAL app.visible_students` 设置身份。
  用会话级 `SET` 会让连接池把上一个人的身份带给下一个请求。
- 可见集合由服务端 `resolveVisibleStudents()` 从 `relationship` 计算，家长可见 = active 孩子。
- 未设置变量时 `app_csv_setting()` 返回空数组 → 匹配 0 行（fail-closed）。
  忘设身份的后果因此是「查不到数据」这个**看得见的 bug**，而不是越权事故。
- `app_dict` 是公共只读字典，刻意不启用 RLS。

---

## 合并 DDL 与增量迁移

`001_schema.sql` 是**终态**：把原工程 001~029 共 29 个增量迁移的
`ALTER TABLE ADD COLUMN` / `DROP CONSTRAINT` / `CREATE POLICY` 全部合并进
对应的 `CREATE TABLE`。新库初始化**不需要**跑那些增量文件。

增量迁移历史留在原仓库，位置见 `docs/source-index.md`。
若原库要升级到本基线，不能对已有库直接跑 `001_schema.sql`（表已存在会报错），
须先比对差异再写一次性升级脚本。

---

## 几条容易踩的坑

1. `date >= $2` 必须写成 `$2::date`，写 `$2::text` 会报 `42883`。
2. 「今天完成」按**交卷日**分组，不等于出题日；库里真有跨天行。
3. `point_ledger` 的部分唯一索引谓词必须原样写进 `ON CONFLICT`，否则报 `42P10`：
   `ON CONFLICT (idempotency_key) WHERE idempotency_key <> '' AND reversed_at IS NULL`。
4. `checkin_quiz` 最终态**没有**日期唯一约束，同一天同科目允许多套试卷；
   防串题靠每次新 id，交卷时校验「每题恰好一份」。
5. 客户端时间必须写带时区的 ISO8601，否则 `TIMESTAMPTZ` 会按服务端时区解释，
   产生**不报错**的偏移。

---

## 验证状态（2026-11-21）

在**独立的临时 PostgreSQL 17.10 实例**（自建数据目录、端口 55433）上从空库执行：

| 检查 | 结果 |
|---|---|
| `001_schema.sql` + `002_seed.sql` | 通过，无 SQL 错误 |
| 表数 / 字典行 / RLS 策略 | 43 / 41 / 44 |
| 插入 `/tmp/a.jpg` 到 `homework_image.relative_path` | 报 `23514`（`rel_path_check`），数据库层拒绝 |
| `app_rls` 未设身份查 `app_user` | 0 行（fail-closed） |
| 事务内 `SET LOCAL` 设置身份后 | 1 行（策略生效） |
| `auth_visible_students('u1')` | `["u1"]` |

验证实例跑完即停、临时数据目录已删除，**不接触任何现有库与数据**。
未验证：FC3 真机、Flutter 编译执行、OSS 驱动、端到端附件上传。
