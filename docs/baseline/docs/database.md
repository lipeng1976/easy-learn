# 相对路径规范（★ 动附件前必读）

## 规则一句话

**数据库里只存相对路径；根目录只由 `STORAGE_ROOT` 配置；绝对路径只在代码运行时拼出来，且只有一个地方能拼。**

三层各管一段，缺一层都不算落实：

| 层 | 文件 | 做什么 |
|---|---|---|
| DB | `db/001_schema.sql` → `CREATE DOMAIN rel_path` | 用 `CHECK` 从**数据库层拒绝**绝对路径 / 盘符 / `..` / 反斜杠 |
| 配置 | 根 `.env.example` → `STORAGE_ROOT` | 唯一配置根目录的地方 |
| 代码 | `backend/shared/paths.js` | 校验 + 归一化 + 解析；`local_driver.js` 是唯一拼绝对路径处 |

---

## 1. DB 层：`rel_path` 域

```sql
CREATE DOMAIN rel_path AS TEXT
  CHECK (
    VALUE = '' OR (
      left(VALUE, 1) <> '/'
      AND left(VALUE, 1) <> chr(92)
      AND position(chr(92) in VALUE) = 0
      AND position('..' in VALUE) = 0
      AND substring(VALUE from 2 for 1) <> ':'
      AND right(VALUE, 1) <> '/'
    )
  );
```

**允许空串**是刻意的：历史行与「还没上传完」的状态需要它，不许用 NULL 代替
（客户端依赖空串，不是 NULL）。

### 正例 / 反例

| 值 | 结果 | 原因 |
|---|---|---|
| `20261121/stu_001/ab12cd34.jpg` | ✅ | 标准相对键 |
| `教学资料/English/Unit1.md` | ✅ | ima 逻辑路径也用它 |
| `''` | ✅ | 允许空串 |
| `/var/data/a.jpg` | ❌ | Unix 绝对路径 |
| `C:\data\a.jpg` | ❌ | 盘符 + 反斜杠 |
| `D:/data/a.jpg` | ❌ | 盘符 |
| `\\nas\share\a.jpg` | ❌ | UNC |
| `20261121/../../etc/passwd` | ❌ | 含 `..` |
| `20261121\stu_001\a.jpg` | ❌ | 反斜杠，不跟操作系统漂 |
| `20261121/` | ❌ | 指向目录而不是文件 |

> 做成 `DOMAIN` 而不是每张表各写一条 CHECK：新增附件表只要声明成 `rel_path`，
> 全部约束自动继承 —— 符合「一个语义只许一处定义」。

---

## 2. 配置层：`STORAGE_ROOT`

```dotenv
STORAGE_ROOT=./var/storage
```

- 值可以是相对项目根的路径，也可以是绝对路径（换机器时改这一行即可）。
- **绝不写进数据库**，也不写进前端配置。
- `var/` 已被 `.gitignore` 排除，运行期附件不会进版本库。

换磁盘 / 换机器 / 本地迁 OSS 时：把字节按**同样的相对路径**搬到新根下，
改一行 `STORAGE_ROOT`，数据库一行都不用动。这就是不存绝对路径的全部意义。

---

## 3. 代码层：`paths.js`

四个函数，别在别处重写：

| 函数 | 作用 |
|---|---|
| `assertRelative(value)` | 校验相对路径，不合法抛 `ERR_INVALID_PATH` |
| `normalizeRelative(value)` | 去掉前导 `./`、统一分隔符、拒绝 `..` |
| `toStorageKey({ studentId, ext, at })` | 生成 `YYYYMMDD/<studentId>/<uuid>.<ext>` |
| `resolveStoragePath(relative)` | `path.resolve(storageRoot, relative)` 后**二次校验仍在根内** |

`resolveStoragePath` 的二次校验不能省：数据库约束可能被绕过（运维直连、
旧数据迁移、未来某段代码没走 `assertRelative`），最终防线必须在文件系统边界上。

**唯一允许把相对路径拼成绝对路径的地方**：
`backend/data-service/src/storage/local_driver.js`。
其它文件一律只持有相对路径字符串。

---

## 4. 读取入口：客户端不传路径

```
GET /data/attachments/:id
  → 按 id 查行（RLS 过滤可见性）
  → 拿到 relative_path
  → local_driver.resolveStoragePath()
  → 返回字节
```

客户端**没有**传路径的参数。所以「路径穿越」在这里不是「记得校验」的问题，
而是「根本没有入口」的问题。新增附件接口时不要开这个口子。

前端自己也有对应的规则（`frontend/lib/core/storage/relative_path.dart`），
用于本地缓存键的归一化：口径与后端逐字一致，且有单测盯住。

---

## 5. 列名映射（整理版 vs 原工程）

| 表 | 本包列名 | 原工程列名 | 类型 |
|---|---|---|---|
| `homework_image` | `relative_path` | `storage_key` | `rel_path` |
| `review_mistake_image` | `relative_path` | `storage_key` | `rel_path` |
| `review_paper` | `relative_path` | `file_path` | `rel_path` |
| `review_paper_item` | `relative_path` | `photo_path` | `rel_path` |
| `subject_book` | `source_path` | 同名 | `rel_path` |
| `reading_book` | `source_path` | 同名 | `rel_path` |
| `word_book` | `source_path` | 同名 | `rel_path` |

迁入原工程 DAO 层时，映射表要同步改。**这类改动不报错**：
字段名对不上只会读出空串，症状是「照片位置一片空白」。

---

## 6. 三类「路径」别混为一谈

| 类型 | 例子 | 存哪 |
|---|---|---|
| 附件字节路径 | `20261121/stu_001/ab12cd34.jpg` | `rel_path` 列，根目录 `STORAGE_ROOT` |
| 导出文件 | `exports/20261121/paper.pdf` | `review_paper.relative_path`，同一根目录 |
| ima 逻辑路径 | `教学资料/English/Unit1.md` | `source_path`，相对知识库根，**不是本地文件系统** |

第三类不解析成本地绝对路径，只作为「这本书哪来的」留痕。
教材/词表导入时 `grade` / `term` 只来自家长显式选择，**绝不解析 ima 路径**。

---

## 7. 旧数据迁移

旧库可能存在设备本地标识或绝对路径历史值。它们不是坏数据，
但**不能原样搬进新库**（`rel_path` 域会拒绝）。一次性运维动作：

1. 剥离根目录前缀；
2. 反斜杠换 `/`；
3. 去掉盘符；
4. 转换不了的行标记为「待补传」，不要硬塞、不要静默丢弃；
5. 校验行数守恒（转换前后行数一致，差异必须有清单）。

转换脚本属于一次性动作，不进 `db/`（`db/` 里只有 DDL + 种子）。

---

## 8. 判据（怎么知道规范真生效）

| 判据 | 期望 |
|---|---|
| `INSERT` 一个绝对路径到 `homework_image` | 数据库报错 `23514`，不是应用报错 |
| `assertRelative('C:/x')` / `assertRelative('../x')` | 抛 `ERR_INVALID_PATH` |
| `resolveStoragePath('a/../../etc/passwd')` | 抛错，不返回根外路径 |
| 把 `STORAGE_ROOT` 改到另一块盘，重启服务 | 库里数据零改动，附件仍可读 |
| 全仓搜 `process.env` | 只出现在 `backend/shared/config.js` 与 `scripts/*.mjs` |
| 全仓搜 `C:\\` / `/var/` 字面量 | 生产代码与 SQL 中不得出现（文档示例、测试反例除外） |

> 最后两条由 `npm run verify` 静态检查。判据要能**证伪**：
> 故意写一行绝对路径，检查它确实变红，而不是「全绿就当通过」。
