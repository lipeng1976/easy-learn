# 数据上云迁移计划

> 目标：**账号与全部业务数据存在云端数据库**，客户端只是访问端。
> 学生换手机、家长换设备、以后加小程序，数据都跟着账号走。
>
> 前置阅读：`architecture-refactor-plan.md`（为什么改、五个陷阱）、`multi-device-architecture.md`（多端论证）、`open-items.md` §A2/C1（现状缺口）。
> 本文只回答一件事：**按什么顺序、怎么实现、每步怎么验收。**

---

## 0. 一句话

第 0 步已经把客户端的数据访问面**冻结成 9 个接口 / 74 个方法**（`lib/repositories/`）。
这让「上云」从「重写客户端」降级成「**照接口写一个服务端实现**」——
接口边界就是未来的 API 路由分组，改的是接口背后那一层，不动上层。

---

## 1. 目标形态

```
┌─ Flutter 客户端（Android / iOS / Web / 以后的鸿蒙·小程序）
│    只依赖 lib/repositories/ 的 9 个接口
│    本地 SQLite 降级为：只读缓存（不再持有权威副本）
└───────────────┬────────────────────────────────
                │ HTTPS + Bearer session token
┌───────────────▼────────────────────────────────
│  数据服务（Serverless，与 AI 网关同形态、独立部署）
│    /data/*   账号 · 关系 · 作业 · 复习 · 积分 · 心愿 · 计划 · 运动 · 通知
│    横切层复用 AI 网关已跑通的：信封 / 鉴权 / 限流 / 审计 / 指标
└───────────────┬────────────────────────────────
                │ 连接池（PgBouncer 或 RDS Proxy）
┌───────────────▼────────────────────────────────
│  PostgreSQL（云 RDS）
│    22 张表 · 部分唯一索引 1:1 迁移 · 事务边界保持
└────────────────────────────────────────────────
        ┌──────────────┴──────────────┐
  对象存储（TOS）                  会话/配额
  作业照片 · 库里只存 key           （PG 表，可加 Redis 加速）
```

**关键点：客户端的上云改造不是「重写」，是「多实现一份」。**
现有的 `DatabaseService`（本地 SQLite）**保留**，与新的 `HttpXxxRepository` 并存，
用编译期开关切换。这样每一步都能回退，也才能做对账（§6）。

---

## 2. 服务端必须定死的 6 条规则

这 6 条是「怎么写服务端」的核心。**每一条现在都靠"单机 + 只有一个客户端"侥幸成立**，
上云后会以不同方式坏掉。先定规则再写代码，否则会写出一个不安全、也没法对账的服务端。

### R1 身份只能由 token 给出，且 token 必须带角色

| 现状 | 上云后 |
|---|---|
| `app_user.role` 存在本地库 | token payload 带 `{sub, role, studentId}` |
| `wish.userRole` / `study_plan.userRole` 是**客户端自报后写进表**的值 | 服务端从 token 取，body 里的 role 一律忽略 |
| 网关 token 的 `sub` 就是 studentId、**没有角色** | `sub` 改为 **userId**，另加 `role` 字段 |

⚠️ **兼容冲突（必须处理）**：AI 网关的配额现在是**按 studentId 分桶**的。
`sub` 改成 userId 会让配额桶换语义。定案：

```
payload = { v, sub: <userId>, role: 'student'|'parent',
            studentId: <该生操作针对的孩子，家长的会话里可为空>,
            iat, exp }
```

- **配额按 `sub`（发起人）计** —— 谁花的钱占谁的额度，这才对。
- `studentId` 降级为「本次操作针对的孩子」，只用于审计与归属，不用于限流。

### R2 ID 必须服务端生成

现状是客户端生成：`pl_${microsecondsSinceEpoch}_${seq}`、`batch_...`、`n_...`、`img_...`。
两个问题：**可伪造**（能造出别人的 ID 去覆盖数据）、**多设备时钟不同步会撞**。

- 服务端生成 ID（`randomUUID()` 或 `前缀_ULID`），body 里的 `id` **一律忽略**。
- **例外**：若最终采用「离线写队列」（见 §7），客户端必须先有 ID →
  那就统一用 **ULID**（时间有序、无需中心、不撞），服务端**校验前缀与格式**后再接受。

### R3 时间戳必须服务端生成 —— 但要区分两类时间

这是最容易一刀切切错的一条。

| 类别 | 例子 | 谁定 |
|---|---|---|
| **记录时间** | `createdAt` / `checkedAt` / `gradedAt` / `submittedAt` / `reversedAt` / `exportedAt` | **服务端 `now()`**。设备时钟可任意改，改到 2020 年会让周期报表、积分排序、复习轮次全乱 |
| **业务时间** | `workout_record.startAt`（实际开始跑步的时刻）、`study_plan_checkin.date`（打卡日期）、`expectedDate` | **客户端提供**，服务端**校验范围**（不得是未来、跨度不超过 N 天） |

⚠️ **时区是真坑**：`study_plan_checkin.date` 是唯一约束 `(planId, date)` 的一部分，
语义是「**学生所在时区的今天**」。服务端按 UTC 算会**错一天** ——
晚上 8 点后打卡会记到明天。定案：

- 库里的时刻一律 `TIMESTAMPTZ`（存 UTC）。
- 纯日期用 `DATE` 类型，**由客户端给出**，服务端只校验不换算。
- `review_summary.scopeKey` 的 **ISO 周年**也必须在客户端时区计算后再上报。

### R4 归属字段服务端填

`studentId` / `userRole` 现在是客户端传的。上云后：

- 会话角色是学生 → `studentId = token.sub`
- 会话角色是家长 → `studentId` 取自 body，**但必须先通过 R5 的关系鉴权**
- 无论哪种，body 里的 `studentId` 只当「申请访问哪个孩子」，**绝不直接落库**

### R5 关系鉴权必须服务端判定（陷阱④的服务端落点）

现在 `_requireActiveRelationship` 是**客户端**在查本机库 —— 上云后等于没有鉴权。
服务端每个「家长访问孩子数据」的端点都必须走一次：

```sql
SELECT 1 FROM relationship
 WHERE student_id = $1 AND parent_id = $2 AND status = 'active'
```

建议做成中间件（`requireBound(studentId)`），**不允许端点各自实现** ——
散落实现早晚有人忘，而忘了的那一个就是越权口子。

### R6 幂等在 HTTP 下要重做一遍

积分账本的 `idx_point_ledger_active_key` 部分唯一索引
（`WHERE idempotencyKey <> '' AND reversedAt IS NULL`）**在 PG 上可以 1:1 照搬** ✅ ——
这是上一节选型里 PostgreSQL 胜出的直接原因。

但 HTTP 带来了 SQLite 时代不存在的问题：**网络超时后客户端会重试，而服务端可能已经写成功了。**
此时返回 409 报错是错的（用户看到"重复"却不知道到底成没成）。定案：

```sql
INSERT INTO point_ledger (...) VALUES (...)
ON CONFLICT (idempotency_key) WHERE idempotency_key <> '' AND reversed_at IS NULL
DO NOTHING
RETURNING *;
-- 没返回行 → SELECT 回原记录，按「成功」返回
```

**同一个规则适用于所有写端点**：重试命中已存在的记录 = 返回原结果，不是报错。

> **还有第 7 条**：多家庭隔离必须是**数据库机制**（PostgreSQL RLS）而不是「记得写 where」。
> 它由「一个班都在上面」这个需求逼出来 —— 见 **§10.2**。

---

## 3. 22 张表 → PostgreSQL 对照

按改造难度分四类。**先看结论**：

| 类别 | 表数 | 说明 |
|---|---|---|
| **A 直接搬** | 13 | 改列名风格 + 类型映射，语义不动 |
| **B 类型要改** | 22（横切） | 所有表的布尔列、时间列、金额列 |
| **C 约束要迁移** | 4 张含约束 | 部分唯一索引 + 3 个 UNIQUE |
| **D 要重新设计** | 4 | 通知、图片、账号口令、头像 |

### 3.1 三条全局映射规则

**① 列名：库内 `snake_case`，API 传输 `camelCase`，映射只在服务端 DAO 层做一次。**

理由：PG 里驼峰列名必须每次加双引号（`"studentId"`），这是**永久摩擦**；
而改成下划线的成本是**一次性**的（DDL + 一个映射函数），客户端完全无感
（客户端 JSON 仍收 camelCase）。

**② 类型映射**

| SQLite | PostgreSQL | 影响的列 |
|---|---|---|
| `INTEGER` 存布尔 | **`BOOLEAN`** | `isPublic` `isActive` `isRead` `aiEnabled` `needsGrading` `parentConfirmed` `studentConfirmed` `isArchived` `correct` `masteredBySelf` `enabled` |
| `REAL` | **`NUMERIC(6,2)` / `NUMERIC(5,4)`** | `estimatedMinutes`、`passRate`（比率用 4 位小数，避免浮点误差让报表对不上） |
| `TEXT` 存时间 | **`TIMESTAMPTZ`** | 全部 `*At` 列（121 处 `toIso8601String()`） |
| `TEXT` 存日期 | **`DATE`** | `study_plan_checkin.date` |
| `TEXT` 存 JSON 数组 | 保留 `TEXT`（第一阶段） | `weekdays` `customWeekdays` `knowledgePoints` `hobbies` `weakPoints` |

> JSON 数组为什么先不动：客户端解析逻辑是稳定的，改 `JSONB` 只为了「能在库里查询」，
> 而这个需求现在不存在。**留着 TEXT，等真有查询需求再迁** —— 一次性改两件事是灾难。

**③ 空值语义：`phone` / `wechatOpenId` 是 `NULL` 而非 `''`** ✅ 已经是对的
（`auth_service.dart:94` 微信注册写 `phone: null`）。PG 的 `UNIQUE` 允许多个 `NULL`，
与 SQLite 行为一致，**这里不用改**。但如果哪天改成写 `''`，第二个微信用户就注册不进来 —— 值得留一条注释。

### 3.2 A 类：13 张直接搬

| 表 | 备注 |
|---|---|
| `homework` | 注意 `gradingSource` 是降级溯源，迁移时**不能丢** |
| `review_mistake` | 错题池主表，状态机字段 `state` 语义严格 |
| `review_paper` / `review_paper_item` | `review_paper_item` 是**快照**，迁移时必须整体搬，不能重新生成 |
| `review_attempt` | 毕业判定的唯一依据 |
| `judgement_ab` | 影子比对观察数据 |
| `ai_practice_question` / `explain_record` / `review_summary` | 直接搬 |
| `wish` / `study_plan` / `workout_plan` / `workout_record` | 直接搬，但 `userRole` 列要停用（见 R1） |
| `chat_message` / `daily_comment` / `point_rule` / `point_ledger` / `relationship` / `app_user` | 见 C / D 类 |

### 3.3 C 类：约束迁移（PostgreSQL 全部原生支持 ✅）

```sql
-- 1. 部分唯一索引（选型的决定性因素）
CREATE UNIQUE INDEX idx_point_ledger_active_key
  ON point_ledger(idempotency_key)
  WHERE idempotency_key <> '' AND reversed_at IS NULL;

-- 2. 三个业务唯一键
ALTER TABLE study_plan_checkin ADD CONSTRAINT uq_checkin UNIQUE (plan_id, date);
ALTER TABLE relationship       ADD CONSTRAINT uq_relation UNIQUE (student_id, parent_id);
ALTER TABLE point_rule         ADD CONSTRAINT uq_point_rule UNIQUE (student_id, action);

-- 3. 账号唯一（多个 NULL 合法，与 SQLite 一致）
ALTER TABLE app_user ADD CONSTRAINT uq_user_phone  UNIQUE (phone);
ALTER TABLE app_user ADD CONSTRAINT uq_user_wechat UNIQUE (wechat_open_id);
```

⚠️ **补一个现有库没有、上云后必须有索引**：

```sql
-- 现在全库 JOIN 数为 0，但服务端要开始做关系鉴权与按学生过滤，
-- 这两个查询会在每个请求上跑一遍
CREATE INDEX idx_homework_student_status ON homework(student_id, status);
CREATE INDEX idx_review_mistake_student  ON review_mistake(student_id, state);
CREATE INDEX idx_relationship_parent     ON relationship(parent_id, status);
CREATE INDEX idx_notification_target     ON app_notification(target_user_id, created_at DESC);
```

### 3.4 D 类：4 张要重新设计

**① `app_notification` —— 陷阱⑦，不改则功能直接不成立**

现在 `addNotification` 把通知写进**自己这台设备**的库，单机演示能通
**只因为两个角色共用一个库**。两台手机后，家长端 `targetUserId` 填得再准也换不来一条记录。

- **产生位置**：改到服务端，在事件发生时生成（家长不用调这个接口，只读）。
  → `NotificationRepository` 的写方法**从客户端接口里移除**，只留读。
- **已读状态**：现在只有一列 `isRead`，而**广播行是全角色共用的同一行** →
  学生点掉一条广播，家长的未读数一起消失。必须拆表：

```sql
CREATE TABLE app_notification_read (
  notification_id TEXT NOT NULL REFERENCES app_notification(id) ON DELETE CASCADE,
  user_id         TEXT NOT NULL,
  read_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (notification_id, user_id)
);
```

**② `homework_image` —— `storageKey` 语义要换**

现在是设备本地绝对路径（原生）或 localStorage 键（Web）。
换手机后读取失败是**静默返回 null**（用户看到"图片不可用"，不知道原因）。

- 上传改走网关已有的 `uploads.js` 签名直传 → TOS
- `storage_key` 改存**对象 key**（如 `students/{studentId}/homework/{ulid}.jpg`）
- 库里**不存字节**；本地可留只读缓存副本

**③ `app_user.password` —— 现在是明文比对 ⚠️ 上云前必修** ✅ **S2 已做**

```dart
// auth_service.dart:72 —— 现状
if (user == null || user['password'] != password || user['role'] != role) { ... }
```

单机时代"只有本机用户能读到自己的库"，还说得过去；**上云后明文口令入库是硬伤**。
- 服务端只存哈希（`bcrypt` 或 `argon2id`，加盐）
  → 实现用的是 **scrypt**（`node:crypto` 自带，零依赖；bcrypt/argon2 都是原生模块，
  要跟着 Node 版本走）。存储格式**自带参数**（`scrypt$N$r$p$salt$hash`），
  将来调高成本参数时老行仍可校验、逐条惰性升级 —— 参数写死在代码里的话，
  调参那天全体用户直接登不进来。
- 迁移时**不搬明文**：存量演示账号直接重设口令（它们本来就都是 `abc123`）
- 客户端永不接触哈希

⚠️ **S2 实现时发现这条下面还压着一个更严重的问题**：哈希与资料放在**同一行**，
而 `app_user` 的 policy 是**行级**的（`id = 自己 OR id = ANY(可见学生)`）——
家长既然能看孩子的资料，就顺带能读到孩子的哈希，**也能 UPDATE 孩子的密码**。
policy 管得了行，管不了列。所以 S2 把凭证拆到了独立表 `app_user_credential`
（policy 只有 `user_id = app.user_id`），并把 `app_user` 的策略按命令拆成
「读 = 自己 + 可见学生 / 写 = 只有自己」。详见 `sql/004_credential.sql`。

**④ `app_user.avatar` —— 现在存的是 emoji 或 `'student'`/`'parent'` 字符串**

不是图片 URL。本期**不建议动**（够用），但要知道：将来要接微信头像或自定义上传，
得加 `avatar_url` 列而不是塞进 `avatar`。留一条注释即可。

---

## 4. 服务端 API 怎么设计

### 4.1 命名空间与横切层

```
/data/*   ← 新的数据 API
/ai/*     ← 已有，不动
```

**横切层直接复用 AI 网关已经跑通的那套**（这是现有网关最值钱的部分）：

| 已有能力 | 文件 | 数据 API 怎么用 |
|---|---|---|
| 统一信封 `{ok,data,meta}` / `{ok,error}` | `src/router.js` | 原样用，客户端解析逻辑不用改 |
| 鉴权与错误码语义 | `src/auth.js` | **改用**（payload 加 role，见 R1） |
| 限流 / 配额 | `src/guard.js` | 数据 API 不需要按成本扣配额，但**需要独立限流**（防刷） |
| 审计 | `guard.js` | 复用（数据写操作要留痕） |
| KV 抽象 | `src/store.js` | 会话吊销表可用（或直接用 PG） |

### 4.2 读写用两种不同策略

**写：1:1 映射**（74 个方法里约 30 个写方法 → 约 30 个端点）
写操作本来就需要精确的语义、明确的幂等键和事务边界，一一对应最保真。

**读：按场景聚合**（不是 1:1）
现在 74 个方法里有 `queryUsersByIds` 这种**明显是本地拼装产物**的接口 ——
在服务端它应该是一次 JOIN 或一个聚合返回，而不是让客户端发 N 个请求。

> 直接 1:1 复制 74 个方法会得到一个「请求数爆炸 + 暴露内部实现」的 API。
> 判据：**这个方法是"页面需要的数据形状"还是"本地数据库的存取形状"？**
> 后者不该出现在 HTTP 层。

建议的聚合端点：

```
GET /data/bootstrap                   登录后首屏：用户信息 + 绑定关系 + 未读数
GET /data/home/student/{studentId}    学生首页：今日作业 + 打卡 + 积分余额
GET /data/home/parent/{studentId}     家长首页：孩子概览（含关系鉴权）
GET /data/review/board/{studentId}    复习看板：错题池 + 卷子 + 周期报告
```

### 4.3 端点清单（按 Repository 分组）

下表是**开工前的设想**，S3 实现时按客户端接口逐条核对过，**有几处被改掉**（改动与理由见 §4.5）。

| 分组 | 写端点（1:1） | 读端点（聚合） |
|---|---|---|
| `auth` | `register` `login` `login-wechat`(预留) `logout` `refresh` `password` | `me` |
| `users` | `saveUser` | `bootstrap` |
| `relationships` | `createInvitation` `accept` `reject` `unbind` | `byUser` |
| `homework` | ~~`insert`~~ `update`(掩码) ~~`clearResult`~~ ~~`delete`~~ ~~`submit`~~ ~~`check`~~ | `byStudent` ~~`detail`~~ |
| `review` | `insertMistake` `updateState` `delete` `createPaper` ~~`submitPaper`~~ `gradePaper`→`papers/update` `recordAttempt` `recordExplain` `savePractice` | `board` `papers` `attempts` `summary` |
| `points` | `append`(幂等) `reverse` `setRule` | `balance` `ledger` |
| `wishes` | `insert` `update` `redeem` `confirm` | `byStudent` |
| `study-plans` | `insert` `update` `checkin`(幂等) `review` | `byStudent` |
| `workouts` | `insertPlan` `insertRecord` | `plans` `records` |
| `notifications` | **无**（服务端产生，见 3.4①） | `byUser` `markRead` |

### 4.5 S3 实现时改掉的四处（都对账脚本看得到）

**① 作业的 `submit` / `check` / `delete` / `clearResult` 全部删掉**，只留 `insert` / `update`(掩码) / 照片行。

核过 `HomeworkRepository` 才发现**接口里根本没有这几个方法**：「提交作业」在
`StudentController.submitHomework` 里就是**一次 `updateHomework(patch)`**（掩码由控制器逐字段拼出
status / submittedAt / submitBatchId / imageCount / needsGrading + `clearResult()`），「批改完成」同样是
一次 `updateHomework(patch)`。它们是 **L1 的业务动作**，而 L2 只提供「按掩码写回」。

照着动作建端点的后果是**服务端要把 L1 的规则抄一遍**（「什么时候算提交完成」「什么情况清空批改结果」），
于是同一件事有两份实现，一定会漂 —— 漂的表现是家长端看到的分数与孩子端不一致。

**② 复习合成 9 个写端点**（squash 掉 `submitPaper` / `gradePaper` 这类动作名），并额外拆出
`mistakes/overwrite` 与 `mistakes/state` **两个**写端点：前者写全部 15 个字段，后者只写掩码里那几个。
合成一个就得到「传了什么就覆盖什么、没传的就清空」的接口 —— 学生在这台设备改状态、家长在另一台改知识点，
后写的那次会把先写的抹掉，**而且不报错**。

**③ 通知**：`notifications` 组的写端点数**确实为 0**（`insertNotification` 退化成服务端内部调用，
见 `src/routes/notify.js`）。而且**刻意不注册** `POST /data/notifications`：让接口*不存在*
比「存在但返回 403」更少一个将来被误用的口子。标记已读写 `POST /data/notifications/read`
（落到 `app_notification_read`，**不碰行上的 `is_read`**，见 §3.4①）。

**④ §4.2 的聚合读端点（`/data/bootstrap`、`/data/home/*`、`/data/review/board/*`）推迟到 S4**。
（**2026-09-21 更新**：`/data/bootstrap` 已在客户端重写的过程中落地，见本节末尾；`home/*` 与
`review/board/*` 仍未做 —— 逐场景 1:1 当前够用。）

S3 的读端点先按「场景内的 where 差异合并」做 1:1（例如 `queryHomework` 与
`queryHomeworkByStudentIds` 合成一条 `GET /data/homework`）。理由：**S3 的验收是 §6 对账脚本**，
它要比对的是「同一批操作之后两边库里的行」，而聚合端点是一种**新的数据形状** ——
老客户端不需要它、对账脚本也用不上它。聚合的真正收益（首屏一次往返）只有在
**客户端被重写时**才拿得到，那正是 S4 的事。先做聚合只会得到一组没人调用、也没被对账覆盖的接口。

**落地时的三条纪律**（`src/routes/bootstrap.js`，2026-09-21）：

1. **零行自有 SQL**：每一段都转调对应路由导出的那个 list handler，而不是在这里重写一句
   `select ... from homework`。否则「首屏看到的」与「点进去看到的」会各有一份实现，然后各自漂。
   判据是**逐行等价**（`test/bootstrap.test.js` 把每一段与对应单端点 `deepEqual`）。
2. **每段一个 SAVEPOINT**：PG 里一条语句失败会让整个事务 aborted、连 `COMMIT` 都被拒 ——
   没有 savepoint 时，一张表的权限问题会把整个首屏变成**空白**，比不做聚合还差。
   失败段名如实进响应的 `failed`，客户端照旧逐条读那几段。
3. **默认关，只在装配点打开**（`CloudRuntime` 传 `bootstrapPrefetch: true`）：它是加速手段，
   不是数据通路。404 / 超时 / 段名不符 → 退回逐条读，行为一字不变。

### 4.4 部署形态：**独立服务，共享代码**

不建议把数据 API 塞进现有 `ai-gateway`：

| 理由 | 说明 |
|---|---|
| **零依赖约束** | AI 网关刻意零依赖（`package.json` 无 runtime 依赖，易部署、冷启动快）。数据 API **必须**带 PG 驱动 |
| **冷启动敏感度不同** | 数据 API 是用户打开页面就要等的（必须快）；AI 网关本来就要等 10–30s |
| **流量特征相反** | AI 低频重（每次 10–30s、外呼模型）；数据高频轻（每次 10–50ms、无外呼） |
| **连接池** | 数据 API 需要管 PG 连接，AI 网关不需要 |
| **故障隔离** | AI 挂了不该影响登录和查作业 |

共享方式：把 `errors.js`（错误码）、`auth.js`（token）、`store.js`（KV）抽成
`serverless/shared/`，两个服务都引。**不复制粘贴** —— 错误码分叉是最难查的一类 bug。

⚠️ **Serverless + PostgreSQL 的经典坑：连接数**

每个函数实例持有一个连接会被并发瞬间打满（云 RDS 通常只有几十到几百个连接）。
必须选一种：**PgBouncer/RDS Proxy** 或**用 Serverless PG 的 HTTP 驱动**。
这一条要在 S1 就定，不能等上线才发现。

---

## 5. 六个阶段

每阶段都可独立验收、可回滚，**且不依赖前一步"完全做完"**。
顺序的关键约束只有一个：**S2 必须早于 S3** —— 没有身份的服务端数据库，
只是把「数据在谁的手机里」变成「数据在谁都没管的表里」。

```
S1 服务端骨架 ──▶ S2 账号与登录 ──▶ S3 数据 API 全量 ──▶ S4 客户端切换 ──▶ S5 图片上云 ──▶ S6 存量迁移
   (不碰客户端)      (瓶颈，必先)        (照接口实现)        (开关切换)        (复用已有)      (下线本地库)
        │                  │                  │                  │                │              │
        └── 本机 PG 即可 ───┴── 首个用户可见证明 ┴── 对账脚本 ──────┴── 325 测试 ─────┴── 换设备可看 ┴─ 删除实现
```

| 阶段 | 做什么 | 验收（可执行） | 回滚 |
|---|---|---|---|
| **S1 骨架** ✅ | 建 PG 库 + 22 表 DDL + 索引；`/data/*` 路由 + 鉴权中间件 + 连接池；抽 `serverless/shared/` | `node --test` 新增契约测试：读 / 写 / **重试幂等返回原结果** 三条通过 | 无客户端改动，直接停服务 |
| **S2 账号登录** ✅服务端 | 注册 / 登录 / 登出 / 改密 / 会话表 / 可吊销 token / scrypt 口令哈希；**顺带修掉结伴**（§10.6）。客户端切换见 S2-b | 服务端：两台设备各自独立会话、登出只下线自己、改密踢掉全部旧会话（契约测试）；**端到端「两台设备看到同一条数据」要等 S4** | 无客户端改动，现有开关不受影响 |
| **S3 数据 API** | 9 组端点全量；R1–R6 六条规则落地 | **对账脚本通过**（见 §6） | 端点可单组下线 |
| **S4 客户端切换** | 新增 9 个 `HttpXxxRepository`；按接口逐个切换 + 325 测试 + Web 端到端 | 开关在本地/云端之间来回切，结果一致 | **每个接口独立开关** |
| **S5 图片上云** | 复用 `uploads.js` 签名直传 TOS；`storage_key` 改对象 key | 换设备登录能看到同一张作业照片 | 本地缓存副本仍在 |
| **S6 存量迁移** | 「上传本机数据」显式入口；删除 SQLite 实现或降级为只读缓存 | 演示账号数据完整出现在云端 | 保留 `.db` 文件不删 |

### S1 落地情况（已完成 · 2026-09-18 · 提交 `7d97c7c`）

**验收：契约测试 16/16 + HTTP 端到端冒烟 6/6 + ai-gateway 132 无回归。**
全程**不需要云账号**，也**不需要 Docker**。

产物在 `serverless/data-service/`：

| 文件 | 作用 |
|---|---|
| `sql/001_schema.sql` | 22 张表 → PG DDL（类型映射 + 3 个 UNIQUE + 部分唯一索引） |
| `sql/002_rls.sql` | 应用角色 `app_rls` + 逐表 policy（`review_paper_item` 顺父卷判） |
| `src/db.js` | 连接池、事务内 `SET LOCAL`、`assertRlsEnforced` 启动自检 |
| `src/auth.js` / `app.js` / `routes/*` | 鉴权中间件 + `/data/*` 路由骨架（6 个端点） |

`serverless/shared/` 抽出 `errors.js`（错误码表）与 `token.js`（签发/校验）。
**ai-gateway 侧改为薄壳 + 适配层**（保留 `GatewayError` 别名、返回值仍带 `studentId`），
调用点零改动、132 测试全绿 —— 错误码只有一份，不会分叉。
角色枚举**一次把 `teacher` 放进去**（§10.5 ② 的落地，现在成本为零）。

本机怎么跑：

```
cd serverless/data-service && npm install
npm test              # 契约测试（自起自停真实 PostgreSQL 17）
npm run smoke:http    # HTTP 端到端冒烟
```

⚠️ 两个前提：**必须在无沙箱隔离下运行**（沙箱会把常驻 postgres 当残留进程回收），
且**起库命令不要接管道**（postgres 继承 stdout，`| tail` 永远等不到 EOF，现象像"无输出的被杀"）。

#### 用真实 PG 验出来的三条硬事实（直接影响 §2 的写法）

1. **部分唯一索引上的 `ON CONFLICT` 必须带 `WHERE`（与索引谓词一致）**，漏了就 `42P10` ——
   PG 推断不出该索引。**§2 的 R5 已经写对了**，这里记的是**它为什么必须那样写**：
   把 `ON CONFLICT (idempotency_key)` 简化成不带 `WHERE` 是个很自然的动作，而它会当场报错。
2. **superuser 绕过 RLS，连 `FORCE ROW LEVEL SECURITY` 也拦不住** → 应用必须用普通角色，
   启动时自检（`assertRlsEnforced`）。
3. **建了 policy 却漏 `ENABLE ROW LEVEL SECURITY` = 隔离静默失效**（policy 建成功、无任何报错）。

后两条是同一类：**安全机制静默失效** —— 不报错、不告警，只在某天变成「一个班互相看得见」。
所以 RLS 的验收必须是**断言**，人工检查没有意义。

### S2 落地情况（服务端 · 2026-09-18）

**验收：契约测试 28/28（原 16 条 + S2 新增 12 条）+ HTTP 冒烟 13/13 + ai-gateway 132 无回归。**
同样**不需要云账号、不需要 Docker**。

产物在 `serverless/data-service/`：

| 文件 | 作用 |
|---|---|
| `sql/003_session.sql` | `user_session` 表 + 它的 RLS；鉴权角色 `app_auth`（BYPASSRLS，**只授权三张账号表**） |
| `sql/004_credential.sql` | 口令哈希搬出 `app_user`（凭证与资料分表）；`app_user` 的 policy 按命令拆分 |
| `src/password.js` | scrypt 口令哈希，存储格式自带参数（可逐条惰性升级） |
| `src/session.js` | 会话签发 / 校验 / 吊销（登出、改密全量下线） |
| `src/routes/auth.js` | 注册 / 登录 / 登出 / 改密 / `me` / `sessions` |
| `src/routes/relationship.js` | 结伴：按手机号邀请 → 对方确认 → 家长可见（修掉 `open-items.md` §C1） |
| `test/auth.test.js` | S2 验收，12 条（其中 4 条是「不该发生的不会发生」） |

**三条设计决定**，都属于「不做不会报错、只会在某天出事」那一类：

**① 可吊销 = 每个请求查一次会话。** token 载荷多一个 `sid`，验签之后必须再问一次
「这个凭证还活着吗」。省掉这次查询，S2 加的会话表就只是个装饰 ——
登出、改密踢设备、丢手机立刻失效，三件事一件都做不到。
代价是诚实的：每个带 token 的请求多一次主键查询（走鉴权连接）。
配套的一条硬边界：**不带 `sid` 的 token 一律拒绝**，否则自己签一个就绕过了整张表。

**② 口令哈希与用户资料分表。** 这条是 S2 实现时才浮出来的：
policy 是**行级**的，管不了列。`app_user` 原来的策略是「自己 + 可见学生」，
于是家长既然能看孩子资料，就顺带能读到**孩子的哈希**、也能 UPDATE **孩子的密码**。
拆到 `app_user_credential`（policy 只有 `user_id = app.user_id`）之后，
「读孩子资料」与「读孩子凭证」不再共用一条 policy。
顺带避开了列级权限的坑：表级 `GRANT` 会覆盖列级，要收口得先 `REVOKE SELECT` 整张表，
而那会让任何一处 `select *` 当场炸掉 —— 改一处、炸一片。

**③ 鉴权连接 `app_auth`：BYPASSRLS + 只授权三张表。** 注册与登录发生在**还没有身份**的时刻，
而 RLS 的 policy 全部依赖 `current_setting('app.user_id')` —— 没有身份就读不到任何行，
连「这个手机号注册过没有」都答不出来。这是账号表结构上的特殊性，不是设计疏忽。
代价是这条连接绕过 RLS，所以越权面必须被**权限**锁死：业务表一行权限都不给
（写错就是 `permission denied`，而不是静默读到全部数据），
并由 `assertAuthRoleScoped()` 在启动时**逐张业务表断言** —— 与 `assertRlsEnforced()` 同一族，
都是「宁可起不来，也不要静默失效」。

#### S2-b：客户端 `AuthService` 接入**刻意没做**

上面表格里原本写着「客户端 `AuthService` 切服务端」。本轮只做服务端，理由不是工作量：

**登录态在数据 API 就绪之前没有意义。** 现在客户端登录后拿不到任何数据（那是 S3 的 9 组端点），
切过去的结果是「注册成功 → 页面全空」，比现在更糟。所以顺序调整为：

```
S2 服务端（本轮，可独立验收）──▶ S3 数据 API 全量 ──▶ S2-b 客户端 AuthService + S4 客户端切换
```

S2-B 与 S4 **合并成一个动作**更合适：它们共享同一件新东西 —— **token 的持久化与注入**
（客户端要存 token、每个请求带上它）。分开做等于把那套管道写两遍。

客户端接入前必须知道的五件事（都已在服务端定死，写在这里免得重新发现）：

1. **老 token 一律失效**（无 sid → `token_invalid`）→ 上线即全体重新登录，
   客户端要做一次「清 token → 去登录页」的迁移路径；
2. `token_expired`（可续签）与 `token_invalid`（必须重新登录）**处置不同**，别合起来判；
3. **登出后重试会拿到 401**（会话已吊销，鉴权就过不去）；
   登出流程里收到 401 应视为「已经登出」并清本地 token，而不是报错；
4. 改密会**吊销全部旧会话并返回新 token** —— 必须用新 token 覆盖本地那份，否则当场被登出；
5. 时间戳是 **UTC ISO8601**（`toIso8601String()` 不带 `Z` 的老写法会差 8 小时，见 §R3）。

### S3 落地情况（服务端 · 2026-09-18）

**验收：`npm test`（data-service）63/63 全绿** —— 契约 28 + 鉴权 12 + S3 数据 23。
仍然**不需要云账号、不需要 Docker**（本机真实 PG 17，`embedded-postgres`）。

> ⚠️ **S3 的准入条件（对账脚本）已覆盖六个业务闭环。** 本节开头给 S3 定的验收
> 是 §6 的**对账脚本**。截至 2026-09-21（§6.3），它覆盖
> **结伴 + 作业 + 复习 + 打卡/积分/心愿 + 运动 + 点评**：31 步 / 16 张表逐行一致，
> 另 2 张通知表按声明核对一致。
> 63 条用例测的是「那些不报错、只是结果不对的失效不会发生」，
> 它**证明不了**「服务端与本地实现行为一致」—— 那件事只有对账能做。
> 所以准确的说法是：**S3 的实现做完了，验收走到了「六个业务闭环已对平」。**
>
> 2026-09-21 补的三张表里，`relationship` 是**约定层面的改动**：它原先只当
> 两侧种子的起点，于是永远进不了 dump 列表 —— 而它是可见集合的来源，状态词写错
> 只表现为后面某一步 403。现在改由序列头两步产生，错误直接落在报告里。

产物在 `serverless/data-service/`（只列 S3 新增/大改的；S2 的表见上一节）：

| 文件 | 作用 |
|---|---|
| `sql/005_notification.sql` | 通知表的读写策略**按命令拆开**；收件人改为「应用声明 + policy 认集合」；**收回 UPDATE 权限** |
| `sql/006_review.sql` | 周期报告的唯一键 `(student_id, scope, scope_key)` —— 重算即覆盖，不是追加 |
| `src/coerce.js` | 类型强制：`toTs` **拒绝带小时差的假时间**、`toDate` 只收 `YYYY-MM-DD`、`toBool` |
| `src/insert.js` | 掩码写入（**缺键 = 不动，`null` = 清空**）；`returning: null` 开关（见下面的②） |
| `src/patch.js` | 掩码解析与 `changedTs`（「这个时刻真的变了吗」） |
| `src/routes/notify.js` | 通知**生成**：服务端内部函数，**没有端点** |
| `src/routes/homework.js` `review.js` `points.js` `wish.js` `study_plan.js` `workout.js` `notification.js` | 剩下 7 组（9 组里另外 2 组 `auth` / `relationship` 是 S2 的） |
| `test/data.test.js` | S3 验收 23 条 |
| `src/app.js` | 路由表 **65 条** |

**四条设计决定**，都属于「不做不会报错、只会在某天出事」那一类：

**① 通知的生成位置整体搬到服务端。** 本地实现是「哪台设备显示，就由哪台设备把通知写进
本机的库」—— 单机演示下它成立，因为两个角色**共用同一个库**。两台手机之后，
学生手机写的那条通知在家长手机上**根本不存在**，`targetUserId` 填得再准也换不来一行记录。
所以 `NotificationRepository.insertNotification` 在服务端**退化成内部调用**，
并且**刻意不注册 `POST /data/notifications`**：让接口*不存在*比「存在但返回 403」
少一个将来被误用的口子（`notification.js` 文件头）。

**② `INSERT … RETURNING` 在 RLS 下要求新行能被*读*策略看见 —— 而报错指向的是写策略。**

这是 S3 里最贵的一个坑，也是唯一一个**报错文案把人送错文件**的坑。
通知是写给**别人**的，而读策略是「发给自己的 + 广播」，于是：

```
42501  new row violates row-level security policy for table "app_notification"
```

而 `notification_insert` 完全放行（收件人已经由 `app.notify_targets` 声明过）。
本机实测的六格矩阵（同一事务、同一份声明，唯一变量是语句形态）钉住了成因：

| 语句 | 结果 |
|---|---|
| 字面量 / 参数化，**无** `RETURNING` | 通过 |
| 字面量 / 参数化，**带** `RETURNING *` | 42501 |
| 参数化，`RETURNING id` | 42501（是**行级**可见性，不是列） |
| 带 `RETURNING`，但收件人是**调用者自己** | 通过（对照组） |

后果是**所有跨用户写通知的路径同时 500**（作业提交/批改、打卡、点评、心愿…），
看起来像五六个互不相关的 bug。处置：写完之后**不读回来**，返回值由 JS 侧组装，
时间戳取同一事务里的 `select now()`（与 INSERT 里 `now()` 逐字节相同）。
`test/data.test.js` 有一条专门的回归用例把这条边界钉住。

> ⚠️ **顺带纠正 §4.5 之前的一处因果**：`005_notification.sql` 的第一版策略当时也被这条
> 报错拒过，而那次失败**很可能混着 `RETURNING` 这一份** —— 也就是说
> 「第一版策略本身跑不通」并没有被干净地验证过。这一版保留下来，
> 理由已改为**工程判断**（policy 里再嵌 RLS 子查询之后不可推理），而不是那次测量。
> 这段更正写在 `005_notification.sql` 里，免得后人把那句「实测被拒」当证据。

**③ 掩码两态：缺键 = 不动，`null` = 清空。** 客户端 `updateHomework(patch)` 的语义是
「只写我传的字段」，而「传了 `null`」与「没传」是两件事（前者是清空批改结果）。
这两态被抹平的症状是**「重新提交后家长仍看到上一次的旧分数」** —— 不报错。
所以写入层按**键是否出现**判定，而不是按值是否为空。

**④ 撤销是「标记 + 反向分录」，不是删除。** 积分撤销写 `reversed_at` 并补一条负数分录，
余额由分录求和得出；重复撤销靠**部分唯一索引**（`WHERE idempotency_key <> '' AND reversed_at IS NULL`）
挡，而不是靠客户端生成 id 的命名约定 —— 后者换个客户端就失效。

#### 与 §4.3 端点清单的四处出入

见 §4.5（作业的四个「动作端点」没建、复习合成、通知写端点为 0、聚合读端点推迟到 S4）。

### 每阶段都要跑的回归

```
flutter analyze                        → 无 error
flutter test                           → 全绿
node --test (serverless/ai-gateway)    → 132 全绿
npm test (serverless/data-service)     → 契约 28 + 鉴权 12 + 数据 23 = 63 全绿
npm run smoke:http (data-service)      → HTTP 链路全绿（当前 6）
对账脚本（S3 起）                       → 逐表一致
```

**S3 这一轮的实测口径**（写清楚哪条跑了、哪条没跑，免得下次把「清单上有」读成「已经绿了」）：

| 项 | 这轮 | 说明 |
|---|---|---|
| `npm test`（data-service） | **63/63** | 提交前在最终树上重跑了一次 |
| `node --test`（ai-gateway） | **132/132** | 串行跑；S3 未改 `shared/`，属保险 |
| `flutter analyze` / `flutter test` | **未跑** | S3 的改动里 **一个 Dart 文件都没有**（`git status` 可证），结构上不可能回归 |
| `smoke:http` | **未跑** | 同上：它测的是 S1/S2 那批端点的 HTTP 信封，S3 未改那些端点 |
| 对账脚本 | **差异 0（22 步 / 12 张表 + 2 张通知表按声明核对）** | 作业 + 复习 + 打卡/积分/心愿全覆盖；余下见 §6.3 |

⚠️ 两条「未跑」都是**有意的**，理由是可核对的（改动面为空），而不是没时间。
一旦哪一轮碰了客户端或 HTTP 横切层，这两条就必须真跑。

### S4 落地情况（客户端切换到服务端 · 2026-09-19）

**目标**：从「服务端能用」推进到「**整套系统能在本机跑起来做演示**」——
一条命令起后端、客户端指向它、登录 → 学生首页有数据 → 家长看到同一个孩子的数据。

**客户端这边做了什么**

| 件 | 位置 | 说明 |
|---|---|---|
| 门面 | `lib/services/database_service.dart` | 唯一数据入口，按契约逐个转发到本地或云端；默认仍是本地（零行为变化） |
| 云端运行时 | `lib/services/cloud_runtime.dart` | 一次装配 9 个仓库共享一个 client/会话；没配地址就返回 null |
| HTTP 数据层 | `lib/services/http_*_repository.dart` | L2 契约的第二个实现，控制器零改动 |
| 取值归一化 | `lib/services/data_row_values.dart` | 布尔 `true/false` ↔ `1/0`、时间 UTC → 本地 |
| 会话落盘 | `lib/services/session_store*.dart` | token 必须持久化，否则刷新即登出 |
| 本机演示栈 | `serverless/data-service/scripts/dev-stack.mjs` | `--reset` / `--no-ai` / `--run "命令"` |

**`--run` 是这个阶段最实用的一件东西**：它让「起栈 → 跑一条命令 → 收栈」在**一个进程里**
完成。分成两个终端做在交互式环境没问题，但在任何非交互环境都会散架（栈是常驻进程，
命令一返回它就被回收，于是「连不上」看起来像代码坏了）。

**这轮撞出来的 8 个 bug，全部是「只有真跑起来才会暴露」的那一类**

| # | 症状 | 根因 |
|---|---|---|
| 1 | 数据服务起不来 | `src/app.js` 注册了 `/data/users` 却**没 import** `routes/user.js` |
| 2 | 提交/批改 400 | `HomeworkPatch` 把时间写成**不带时区**的本地 ISO（§R3）。本地库原样存文本没问题，上行必被拒 |
| 3 | 登出后旧 token **仍然可用** | `HttpAuthApi.logout` 先清本地、再打服务端，而请求要靠会话里的 token 才能鉴权 → 那次请求是未认证的，被 catch 吞掉，**服务端会话一直活着** |
| 4 | 数据上了云、登录还在本地 | `currentCloudRuntime` 是**第二份**可变状态，`useCloudRuntime()` 只改了 `DatabaseService._cloud` |
| 5 | 冷启动带着会话却停在登录页 | 登录页只填表单，**没有「已登录就进主界面」的逻辑**；首屏固定在 `LoginPage` |
| 6 | 家长端心愿 500 | `listWishes` 的 `scope=public` 分支 SQL 里没有 `$3`，参数数组却永远传 3 个 |
| 7 | 家长端永远「尚未与任何学生结伴」 | 服务端关系词表是 `accepted`，客户端枚举是 `active` —— 读进来落成 `pending`；**写方向也坏**（发 `active` 被 400）。**已修（2026-09-20）**：两侧统一成 `active`，见 §8.5 |
| 8 | **AI 链路静默缺失**：网关子进程抛 `EADDRINUSE` 崩掉，而栈照常报**退出码 0 / 全部判据通过** | 起栈时没做端口预检。8787 上挂着一条两天前的旧网关（占着口但不健康），新网关起不来只留一段异常栈；而「AI 不在」在演示里表现为功能悄悄回落本地实现，**不报错** |

第 4、5 两条是同一类：**同一件事有两个答案**。修法不是补一句赋值，而是**删掉那份重复状态**
（`currentCloudRuntime` 已删除，只留 `DatabaseService.cloud`），并补了
`test/cloud_wiring_test.dart` 守住它 —— 这类 bug 不报错、不崩，只会静默地少数据显示。

第 7 条与 `study_plan.status` 是同一类问题（**同一个语义两个词**），见 §8 的待拍板项。

第 8 条是**演示链路的可靠性**问题：栈报成功，而其中一个组件其实没起来。修法是**起栈前预检端口**
（`dev-stack.mjs` 的 ⓪ 段）。两个口的处理方式刻意不同 —— 因为这两个端口是**客户端编译期常量**
（`--dart-define=DATA_API_BASE_URL=…:8788` / `AI_BASE_URL=…:8787`），服务端**不能**像静态托管那样
「被占就换一个口」，换了口客户端就找不到服务：

- **数据口被占 → 直接退出**，报出占用者的 PID 与进程名。复用别人的数据服务等于在演示**另一个库**，
  而且那次演示看不出任何异常，是最难分辨的一种坏。
- **AI 口被占 → 先探活再判**：探活通过就**复用**（本机常常本来就挂着一个网关，比如接 Ollama 的那份，
  此时再起一个 mock 是多余的）；被占但不健康就**本次不起**并说明原因，而不是让子进程崩出一段
  与真正问题无关的异常栈。

探活走**进程内 socket**，不用 `netstat`：实测这个环境里**每次 `spawnSync` 固定约 5.2 秒**
（连 `node --version` 也一样，预热后仍是），而 socket 探测是 **1 毫秒**。每次起栈白等约 10 秒
去换「知道占用者的名字」不划算 —— 名字挪到真被占的分支里再查。

**这一轮的实测口径**（哪条真跑了、结果是什么）

| 项 | 结果 |
|---|---|
| `flutter analyze` | **No issues found** |
| `flutter test` | **328 全绿**（2 跳过：对账 dump 组 + 联调组，都需要外部服务） |
| `test/cloud_live_test.dart`（打真在跑的数据服务） | **8/8** —— 登录、读演示数据、掩码语义、家长跨 token 可见、越权 403、登出后旧 token 失效 |
| `scripts/probe-demo.mjs` | **19/19**（本轮补了家长侧的「关系 / 孩子档案 / 心愿三个 scope」） |
| `tools/walkthrough-cloud.mjs`（真浏览器） | **全部判据通过** —— 登录 → 主界面 → 看到种子作业 → 刷新仍在线 → 换家长看到同一个孩子的作业（复核时又跑了一遍，静态托管这次落在 8088，未触发端口退让） |
| `dev-stack` 端口预检（4 组用例） | **4/4** —— 数据口被占 → `exit 1` 并报出 PID；AI 口被占且不健康 → 不起重复进程、**无异常栈**、`exit 0`；AI 口有健康网关 → 报「直接复用」；两个口都空闲（正常路径）→ 无警告、两个服务都起、`exit 0` |
| `npm test`（data-service） | **63/63**（契约 28 + 鉴权 12 + 数据 23） |
| `npm run smoke:http`（data-service） | 未跑（本轮没动 S1/S2 那批端点的信封） |
| 对账脚本 | **差异 0**（22 步 / 12 表逐行一致；另 2 张通知表按声明核对）—— 本轮改了 `wish.js` 的 SQL 参数拼法，所以特意补跑确认 |

**演示怎么跑**（一条命令）

```bash
cd serverless/data-service && npm run dev:stack
# 数据服务 http://127.0.0.1:8788 / AI 网关 8787（mock 模型）
# 演示账号：学生 13800000001 林小宇 / 13800000003 林小桐，家长 13800000002 王老师，密码都是 abc123
```

客户端指向本机（**编译期常量**，必须重建）：

```bash
flutter build web --dart-define=DATA_API_BASE_URL=http://127.0.0.1:8788 \
  --dart-define=AI_BASE_URL=http://127.0.0.1:8787
# 或 flutter run -d chrome --dart-define=...
```

⚠️ **浏览器是跨源请求**（客户端与数据服务不同端口），所以 `src/dev-server.js` 里有 CORS
放行 —— 只放本机来源（`localhost` / `127.0.0.1` / `[::1]`），**不是 `*`**：
这个服务能读真实数据，而 `/auth/login` 是公开端点，放行全部来源等于给每个网页一个
免费的口令爆破口。生产由网关/边缘统一处理。

⚠️ `tools/walkthrough-cloud.mjs` 会**往演示库里写**（`cloud_live_test.dart` 也一样，
它建一份标题带「【联调】」的作业）。要一份干净的演示数据：`npm run dev:stack -- --reset`。

⚠️ **演示数据按天刷新**（`seed-demo.mjs` 的幂等判据里带着「今天有没有」）：
作业的 `dueAt` 是「播种那天」，而客户端是按天过滤列表的 —— 只看标题判重的话，
第二天打开演示栈，首页会说「今天暂无作业」。所以每次起栈都会给两个演示孩子
各补一份**当天**的作业，昨天那份留作历史；同一天重复起栈不会重复造。

---

## 6. 对账：把「行为零变化」从口号变成证据

**这是整份计划里最值得投入的一件事。**

「325 个测试全绿」**证明不了**服务端实现是对的 —— 它们测的是本地实现。
真正有说服力的是**同一份输入，两条链路，逐表比对**：

```
1. 起本机 PostgreSQL + 数据服务
2. 写入同一份种子数据（复用 LocalSeedService 的三个演示账号）
3. 对两条链路执行同一串操作序列：
     登录 → 建关系 → 布置作业 → 提交 → 批改 → 生成错题
     → 组卷 → 导出 → 批改卷子 → 记录作答 → 毕业判定
     → 打卡 → 积分入账 → 兑换心愿 → 复习报告
4. 逐表 dump 两张库（列集 + 行集），忽略时间戳与实际 ID，比对业务字段
5. 输出差异清单；差异必须是 0 才能进下一阶段
```

脚本放在 `scripts/` 下，**作为 S3 的准入条件**。
它同时是以后改服务端逻辑时的回归网 —— 比任何单元测试都接近真实风险。

⚠️ 这几项必须处理掉（否则永远对不平），但**处理方式不能一律用白名单糊过去**。
实际做法见 §6.3 与 `scripts/reconcile/README.md` 的「已知差异」表：

| 项 | 处理方式 |
|---|---|
| 服务端生成的 `id` | 按**别名**归一化（`$hw1`），并用归一化后的 id 配对 |
| `createdAt` 类的记录时间 | 列白名单（R3：本地设备时钟 / 服务端 `now()`） |
| `storageKey` | 列白名单（语义已变） |
| `app_notification` | 按 `behaviorDiff` 的**声明清单**核对，不逐行比 |
| `password` | 不在任何 dump 的表里（已哈希，且没有比对价值） |

### 6.1 最小闭环：已跑通（2026-09-18 · 差异 0）

覆盖「建作业 → 提交 → 传照片 → 写错题」4 步 / `homework`、`homework_image`、
`review_mistake` 3 张表。产物在 `serverless/data-service/scripts/reconcile/`
（跑法见该目录的 `README.md`）：

| 文件 | 作用 |
|---|---|
| `scenario.json` | 操作序列 —— 语言中立的**单一真相**，两侧执行器都读它 |
| `test/reconcile_dump_test.dart` | 本地链路执行器：`sqflite_common_ffi` 起真 SQLite，调 `DatabaseService` 的实现 |
| `scripts/reconcile/server-run.mjs` | 服务端链路执行器：起本机 PG → 迁移 → 打端点 → dump |
| `scripts/reconcile/compare.mjs` | 比对器：**唯一**的 diff 逻辑 |

**比上面那段计划多出四条规矩**，每条都是被实测逼出来的：

1. **序列只有一份。** 两侧各写一份会漂，而漂了的对账脚本比没有更坏 —— 它会报「一致」。
2. **比对逻辑只有一份。** 执行器只做「执行 + dump」，不做判断。
3. **id 按别名归一化。** 两侧 id 必然不同（R2），而表之间有外键引用：序列里写 `$hw1`，
   执行器各自解析成真实 id、dump 带上映射，比对器再反查回去。
   **配对用归一化后的 id，不按索引** —— 一侧多一行会让按索引的比法全表错位，
   报出一堆「看起来全都不对」的差异，而真实原因只有一个。
4. **列名也归一化**（本地 camelCase / 服务端 snake_case）。不归一化的话，
   每一列都会被报成「仅一侧有」，真正的行为差异会被淹没在命名风格差异里。

**首次实测抓到的差异与处置**（这张表就是对账的价值所在 —— 它看见的是存储层，
不是界面）：

| 差异 | 为什么没人发现 | 处置 |
|---|---|---|
| `wrong_count`：本地 `0` / 服务端 `NULL` | 客户端 `_homeworkFromMap` 有 `?? 0` 兜底 | **改服务端**：`createHomework` 显式写 `wrong_count = 0` |
| `user_role`：本地 `'student'` / 服务端 `NULL` | 服务端不读这一列，客户端兜底 `?? 'student'` | 列白名单，并注明「服务端将来若读它，这条必须删」 |
| `ai_enabled` / `needs_grading` / `mastered_by_self`：`1/0` vs `true/false` | SQLite 没有布尔类型 | **归一化，不进白名单** |

⚠️ 第三条是纪律的关键：**表示差异要归一化，不要用白名单糊。**
白名单会让这些列完全不比，于是 `needs_grading` 真的从 `true` 变成 `false`
（学生关掉了批改开关）也会被放过 —— 而那恰恰是最该被看见的一类差异。

⚠️ 另一条：**执行器遇到失败步骤必须抛错，不能静默跳过。** 跳过之后 dump 照样生成，
比对器于是对一次「从未发生」的操作宣布「一致」。

### 6.2 复习闭环：已跑通（2026-09-18 · 差异 0）

在 §6.1 之上加一段：**组卷 → 导出 → 作答 → 批改 → 毕业 → 报告（同一周期写两次）**，
6 步 / 4 张新表。现在一次跑完 **11 步 / 7 张表**：

| 阶段 | 步骤 | 表 |
|---|---|---|
| 作业闭环 | 建作业 → 提交 → 传照片 → 写错题 | `homework` `homework_image` `review_mistake` |
| 复习闭环 | 组卷 → 导出 → 作答 → 批改 → 毕业 → 两次报告 | `review_paper` `review_paper_item` `review_attempt` `review_summary` |

**抓到 1 处差异，处置是白名单**：

| 差异 | 为什么必然不同 | 处置 |
|---|---|---|
| `review_summary.generated_at`：本地 `13:20:00.000Z`（序列给的）/ 服务端 `16:17:20.614Z`（`now()`） | 服务端**不读**客户端给的 `generatedAt`（`SUMMARY_SPEC` 里没有这个字段，直接 `generated_at = now()`）—— 与 `created_at` 同属 R3 | 列白名单，**并在注释里记下它掩盖的那个小不一致**：`scopeKey`（ISO 周）是客户端按设备日期算的，而 `generated_at` 是服务端时钟，设备时钟偏一天就会出现「scopeKey 说这周、generated_at 说下周」，而列表按 `generated_at DESC` 排序。要收紧应**把 scopeKey 交给服务端算**，而不是让 `generated_at` 改成信任客户端 |

**这一步验出三处「两侧接口形状不同」——都是只有对账才看得见的东西**：

1. **`updateReviewPaper`：本地是整体覆盖，服务端是掩码。** 本地实现是
   `db.update` 写全部列；服务端端点是 `buildUpdate` 的掩码。执行器因此必须
   「读回来 → 套掩码 → 整体写回」（这也正是 `ReviewController` 的真实做法）。
   若图省事改成「只把掩码字段拼成 map 去 update」，测的就变成我临时发明的那个掩码。
2. **`updateReviewMistakeState`：这一侧天然就是掩码**（命名可选参数，
   `null` = 本次不改），与服务端 `MISTAKE_STATE_SPEC` 同形 —— 与上一条正好相反，
   对照着看更清楚。
3. **周期报告的 id 拼法不同**：本地 `sum_{studentId}_{scopeKey}`、服务端
   `sum_{studentId}_{scope}_{scopeKey}` —— 又一次说明「对账必须用别名，不能用真实 id」。
   更值得注意的是**去重机制**：本地靠 `ConflictAlgorithm.replace`（按 **id** 去重，
   也就是「一个周期一份」只靠 id 的命名约定撑着），服务端靠
   `UNIQUE (student_id, scope, scope_key)`。实测两侧都是 1 行 ——
   但只有服务端那一侧，换个客户端、或改了 id 拼法之后**仍然成立**。

⚠️ **一条加了但没有被触发的归一化**（写在这里，以免下次有人以为它验证过）：
预判「PG 的 `NUMERIC` 列经 node-pg 会回成字符串」而加了数值归一化，
实测 `pass_rate`（`NUMERIC(5,4)`）在两侧都是 **number** `0.5`。
它保留在 `compare.mjs` 里（且只在两侧数值真正相等时生效，不会掩盖 `0.5` vs `1`），
但**本机没有验证到它起作用**。

**三条被这一轮实测逼出来的执行器改造**（都在 `server-run.mjs`）：

1. **dump 要在 PG 还活着的时候落盘。** 原本写在 `withMigratedDatabase` 返回之后，
   而收尾（强杀 postgres + 删数据目录）在 Windows 上要一两分钟 —— 那次运行的进度日志
   显示 11 步全部跑完、收尾拖到总时长 4m53s。收尾一旦被外部超时杀掉，
   **一次成功的运行会变成「什么都没有」**。现在写完 dump 才进收尾。
2. **进度同步追加到一个文件，而不只写 stderr。** 上一版把输出重定向到文件、
   postgres 继承了那个句柄，出问题时看到的状态是「进程还在、文件 0 字节」——
   完全看不出它跑到哪一步。同步追加不受重定向与缓冲影响。
3. **执行器开跑前先删掉自己上一轮的 dump。** 否则在写文件之前失败（起库失败、
   某一步报错）时，旧 dump 会留在原地，而比对器只认路径不认时间 ——
   于是它会对一次**从未发生**的运行宣布「一致」。

另外实测记一笔：**本机 PG 启动约 2m52s**（initdb + start），而 11 步工作本身只要 20s。
对账的耗时几乎全在起库上，所以别把「跑得久」当成卡住 —— 先看进度日志。

⚠️ **`app_notification` 进 dump 了，但按「声明」核对而不是逐行比对。**
它的产生位置在两条链路上本来就不同（陷阱⑦），所以它必然是一条差异 ——
真正的问题不是「能不能对平」，而是**这条差异要不要被看见**。早先的做法是不 dump 它，
那只解决了一半：「服务端多发 / 少发一条通知」「客户端自己也发了一条」全都看不见了。
现在写进 `scenario.behaviorDiff`：按**标题多重集**声明两侧各该有什么
（不按 id —— 两侧 id 本来就没有对应关系），比对器对着清单核。
2026-09-19 反向验证过：故意删掉一条声明，比对器立刻报
`✗ 服务端多出「心愿已兑现」×1` 并退出码 1。

### 6.3 打卡 / 积分 / 心愿 / 通知：已跑通（2026-09-19 · 差异 0）

在 §6.2 之上再加一段：**建计划 → 打卡（含重复打卡）→ 记分（含同键重试）→ 撤销 →
许愿 → 定价 → 申请 → 兑现 → 扣分 →（只在一侧）标记一条通知已读**，
11 步 / 5 张新表。现在一次跑完 **22 步 / 12 张表**，另 2 张通知表按声明核对：

| 阶段 | 步骤 | 表 |
|---|---|---|
| 作业闭环 | 建作业 → 提交 → 传照片 → 写错题 | `homework` `homework_image` `review_mistake` |
| 复习闭环 | 组卷 → 导出 → 作答 → 批改 → 毕业 → 两次报告 | `review_paper` `review_paper_item` `review_attempt` `review_summary` |
| 打卡 / 积分 / 心愿 | 建计划 → 打卡×2 → 记分×2 → 撤销 → 许愿 → 定价 → 申请 → 兑现 → 扣分 | `study_plan` `study_plan_checkin` `point_ledger` `wish` |
| 通知 | 标记一条已读（**只在一侧**） | `app_notification` `app_notification_read` |

**抓到 3 处差异，两种处置**：

| 差异 | 性质 | 处置 |
|---|---|---|
| `study_plan_checkin.date`：本地 `2026-09-18` / 服务端 `2026-09-17T16:00:00.000Z` | **表示差异，里面裹着一个真陷阱** | **改 dump 侧**：按 `information_schema` 的 `data_type` 认出 DATE 列，输出 `YYYY-MM-DD` |
| `point_ledger.idempotency_key`：本地 `plan:L_plan1:…` / 服务端 `plan:c6673ca6-…:…` | 别名归一化没生效 | **改比对器**：真实 id 会嵌在字符串中间（幂等键的形态就是 `plan:<planId>:<date>`），替换要做在字符串内部，且按 id 长度**降序** |
| `point_ledger.reversed_at`：本地 `10:05:43.203741` / 服务端 `01:56:28.677Z` | 时钟来源不同（R3） | **只比存在性**，不进白名单 —— `空 ↔ 非空` 正是「这笔有没有被撤销」 |

⚠️ 第一条差点被当成格式噪音放过：`2026-09-17T16:00:00.000Z` 看起来只是
「日期被写成了时刻」，实际是**这个日子在 UTC 下退到了前一天** ——
而这一列的全部意义就是「打卡记到了哪一天」，按 UTC 算正好会造成
「晚 8 点后打卡记到明天」。同一个坑在 `toDate()`（`coerce.js`，**入站**方向）
里已经写明并拒绝过一次，这次是它以**出站**方向的形态又出现了一次。

⚠️ 第二条同理：「id 不同」这件事早就用别名解决了，但**别名只认整串**，
而幂等键把 id 放在了中间。这类「已经解决过的同类问题以新形态复现」
是对账脚本自身最容易松掉的地方。

**这一轮新增的三件事**：

1. **`scenario.behaviorDiff`：结构级差异的出口。** 与 `IGNORE_VALUES` 的区别是
   「核对」与「抹掉」—— 前者会随行为变化报警，后者只会安静地不再看那一列。
   能用前者的差异不要降级成后者。
2. **`sides` 声明。** 序列里可以写某一步只在一侧执行（目前只有「标记通知已读」），
   另一侧执行器**显式记录跳过**、比对器要求它必须在 `behaviorDiff` 里有对应条目。
   不许静默跳过 —— 静默跳过正是对账最坏的失败方式。
3. **`scenario.vocabDiff`：词表差异要打印出来。** 见下面那条 ⚠️。

⚠️ **本轮发现的一处真问题（不在落库层，但会被它挡住）**：
`study_plan.status` 两侧是**两套枚举** —— 本地 `StudyPlanStatus.name` =
`pendingStudentConfirm / active / rejected / withdrawn / completed`，
服务端 `STUDY_PLAN_STATUSES` = `pending / active / rejected / completed / expired`，
**交集只有 `active` / `rejected` / `completed`**。而客户端上行时送的正是 `.name`，
服务端的 `toEnum` 又是严格白名单 → 「学生确认计划」这条路径会以 400 收场。
本场景因此只能用交集值，这不是随手挑的，是被词表逼出来的。
**已定（2026-09-20）**：映射只有一份，在客户端 `lib/services/wire_status.dart`，
并有 `test/wire_status_test.dart` 的**跨栈对照**（直接读服务端 `vocab.js`）盯着。
没做成「服务端一份 enum_map」是因为服务端不该知道客户端有 `withdrawn` 这种它不支持的状态 ——
翻译的方向是「客户端的表达力 → 服务端的能力」，放在客户端才不需要服务端为它没实现的动作留词。

**还欠着的**：运动打卡（`workout_*`）、家长点评（`daily_comment`），
以及通知「已读」在**客户端读路径**上的改造 —— 本地 `app_notification.isRead`
是一个行级布尔，**记不下「谁读的」**，于是广播通知（`targetUserId = ''`）
被学生点掉之后，家长那端的未读数会跟着消失。服务端已改成
`app_notification_read(notification_id, user_id)` 关联表，但客户端要到 S4 才会读它。
**这一步在两侧不可比**（不是数据不同，是表达能力不同），所以它只在一侧执行。
每加一步，**两侧执行器都要加** —— 只加一边的后果是那一步在另一侧静默不执行，
而对账仍然「通过」。

---

## 7. 一个必须先拍板的决策：客户端要不要离线能力

这个决定**改写 S4 的全部工作量**，而且不可逆（决定了 ID 生成、时间戳、写队列三件事）。

| 方案 | 做法 | 代价 | 适用 |
|---|---|---|---|
| **A 纯在线** | 客户端不再持有 SQLite，读写都走网络，失败即提示 | 断网完全不可用 | 家里有 WiFi 的场景勉强够 |
| **B 读缓存** ✅ **已拍板** | 读：本地缓存优先 + 后台刷新；**写：必须在线** | 中等。缓存失效策略要设计 | 教育场景够用 —— 写操作（交作业、打卡）本来就需要即时反馈 |
| **C 写队列** | 写也进本地队列，联网后同步 | **高**。要解决冲突合并（同一道题两台设备改成不同答案） | 需要真正的离线可用 |

**已选 B（2026-09-19 拍板，同日落地）**：它把最难的「冲突解决」整个跳过，同时保住读体验。
A 太脆（孩子家里断网就打不开）；C 的复杂度不在客户端，在**你以后要一直维护合并逻辑**，
而现在的业务里没看到必须离线写的原因。

> 选了 B，R2 的 ID 仍由服务端生成（客户端只有读缓存，不产生 ID）；
> 选了 C，R2 要改用 ULID 并允许客户端生成。

### 7.1 B 的落地情况（2026-09-19）

**总开关不变**：客户端默认仍走本地实现，切到服务端要显式配 `DATA_API_BASE_URL`，
`baseUrl` 为空 = 完全离线安全默认 → 这次改动**可回滚、零行为变化**。

落地四件事，每件都对应一个真会出的 bug：

| # | 机制 | 挡住的 bug | 落在哪 |
|---|---|---|---|
| 1 | **`ReadCache` 门面**（stub / io / html 三实现，照 `SessionStore` 范式） | —— | `lib/services/read_cache*.dart` |
| 2 | **世代（generation）校验** | 「改完刷新又变回去」：飞行中的后台刷新把**写之前**的数据回写进来。只在慢网络出现 | `data_api_client.dart` |
| 3 | **容量上限 + 写盘失败让步** | Web 上 localStorage 配额满，缓存把用户**自己的本地库**挤出门外 | `ReadCacheLimits`：单条 128KB / 24 条 / 总 1MB，LRU 按 `storedAt` 淘汰 |
| 4 | **陈旧读可见** | B 的固有代价：旧数据和实时数据长得一样，用户以为「这就是现在的」 | `DataStalenessLog` → `DataStatusController` → `OfflineDataBanner` |

几条硬约定：

- `lookup` 必须**同步**（数据常驻内存，落盘只是持久化）；落盘 200ms 防抖，
  启动先 `initialize()` 载入 —— 否则「断网首屏」这个唯一场景正好没缓存可用。
- **写必须在线**：`postJson` 全部是写（已核验），成功后 `invalidateAll()`；
  离线写失败只上报 `writeDropped`，**不落本地、不排队**（那就是方案 C 了）。
- 缓存**只对 `/data/` 端点**生效，且 key 必带身份 —— `auth/me` 永不缓存，换账号不串。
- 陈旧读与写丢失是**两种语气**：「正在显示上次同步的内容」（中性）vs「这次修改没有保存」（警示 + 重提提示）。
  合成一句就等于把「看到旧数据」和「以为已经改了」搞混。
- 陈旧读是**过期**触发（TTL 15s），不是断网触发：在线但服务端慢，同样会看到旧数据。

> ⚠️ **踩坑记录（值得单独钉住）**：横幅一开始用 `AnimatedSize` 做展开动画，
> 结果在 `TickerMode(enabled: false)` 或帧调度不推进时，高度永远停在 0
> —— 横幅**在树里、Obx 重建过、日志有事件，但就是看不见**，不报错不崩。
> **可见性不能挂在动画上**：已改成按状态直接返回 `SizedBox.shrink` / 真组件，
> 并在 `test/offline_banner_test.dart` 里加了「静音 ticker 下必须占高度」的回归测试。

### 7.2 这一轮的实测口径（2026-09-19 深夜）

| 项 | 结果 |
|---|---|
| `flutter analyze lib test` | **No issues found** |
| `flutter test` | **365 全绿**（2 跳过：对账 dump 组 + 联调组，都需要外部服务） |
| `tools/walkthrough-cloud.mjs`（真浏览器 + 断网） | **全部判据通过** —— 登录 → 主界面看到当天种子作业 → 刷新仍在线 → **断网刷新仍读得到缓存、且横幅可见** → 恢复在线横幅消失（对照）→ 换家长看到同一个孩子的作业 |
| 数据服务端点耗时（node 侧 10 个端点 × 冷热两轮） | **1–114ms**，没有慢端点 |
| 服务端代码 | 本轮**未改动**（只改了演示种子脚本的日期判重） |

截图与断言日志在 `build/demo-evidence/`。最有说服力的一张是 `06_offline_reload.png`：
**断网状态下，首页同时显示着缓存里的作业（`数学练习册 P32`）和「正在显示上次同步的内容」横幅**
—— 也就是方案 B 的两条判据（还读得到 / 看得出是旧的）在同一张图上成立。

#### 三个「看起来像功能坏了，其实是判据/演示数据坏了」的坑

1. **演示数据会按天失效**（真 bug，已修）。种子作业的 `dueAt` 固定在**播种那天**
   21:00，而客户端是按 `dueAt` 那**一天**过滤列表的（`homework_tab.dart` 的
   `_isSameDay`，首页与家长端同理）。于是「演示栈放一晚上，第二天打开首页说
   今天没作业」—— 数据都在，只是全留在昨天。而种子的幂等判据只看标题，
   于是永远跳过、永远补不回来。修法：**幂等判据带上「今天有没有」**，
   没有就补一份今天的（昨天的留作历史），`dueAt` 定当天 23:00
   （更早会被客户端的超时扫描改成 `timeout`，那是一次真写库的副作用）。
   错题本的判重也一并从 `homeworkId` 改成**题面** —— 否则同样的两道题
   一天进一次，一周后错题本里躺着 14 条一模一样的记录。

2. **横幅判据自己来晚了**（判据 bug，已修）。横幅 20s 自动隐藏，而走查在断网
   刷新后**先去花 10s 找作业**、再回头探横幅 —— 窗口已经关上。现象是
   「功能没做」：`06_offline_reload.png` 里横幅清清楚楚（还带着「已 19 次」），
   15 秒后去探却什么都不剩。修法：**先探横幅，再找作业**。
   教训：断言有时间窗口的东西，必须把它排在**窗口之内**去看。

3. **用 CDP 改客户端 localStorage 有竞态**（判据 bug，已修）。客户端把整份缓存
   常驻内存，任何一次落盘都会用**它自己那份带新鲜 `storedAt` 的快照**整份覆盖
   localStorage —— 页面正在卸载时它照样会写。于是「我明明把它改成 1 小时前了」，
   新文档读到的却是几十秒前（实测打印出来是 48–54s，而那一步改的是 3600s）。
   后果是**反向**的：新文档认定缓存新鲜 → 直接命中、连网络都不打 →
   没有失败、没有陈旧读、横幅永远不出现。修法：把做旧脚本交给
   `Page.addScriptToEvaluateOnNewDocument`，**在新文档启动前**改 ——
   那一刻只有 localStorage 一份数据，没有第二份副本可以覆盖它。

---

## 8. 需要你拍板的四件事

| # | 事项 | 我的建议 | 影响 |
|---|---|---|---|
| 1 | 客户端离线策略（§7） | **B 读缓存，写必须在线** ✅ **已拍板并落地（2026-09-19）** | S4 工作量；R2/R3 的实现 |
| 2 | 存量本地数据处理 | **给显式「上传本机数据」入口，不做自动合并** | 自动合并需要冲突解决；演示数据本来不重要 |
| 3 | 数据服务部署形态 | **独立服务 + `serverless/shared/` 共享错误码与 token** | S1 的结构 |
| 4 | 云厂商 | **PostgreSQL 系**（火山 RDS PG / Supabase / 腾讯云 PG，见方案文档 §7） | 选型已论证；只是挑一家 |

### 8.5 状态词表统一（**同一个语义，两个词**）—— ✅ 2026-09-20 已按「A 的变体」落地

S4 撞出来的第 7 个 bug 属于这一类：服务端关系表用 `accepted`，客户端枚举用 `active`。
当时两处各翻译一次（`HttpRelationshipRepository._parseStatus` / `_toServerStatus`），
**这类不一致会持续产生 bug**：

- 读方向漏一支 → 静默当成「最保守的那个态」（家长端因此永远显示「尚未结伴」）；
- 写方向直接用枚举名 → 一半能过（`rejected` 两边同名）、一半 400（`active` vs `accepted`）。

**决定：A 的变体 —— 服务端采用客户端的词 `active`。**
理由是「`accepted` 是关系行的状态，而它表达的是这段关系**生效了**，`active` 更贴近领域语义」；
而且客户端那套词已经落进**每台已装设备的 SQLite**（改客户端要动 DB 迁移），服务端只有演示数据。

落地与判据：

| 件 | 位置 |
|---|---|
| 词的**单一来源** | `serverless/data-service/src/vocab.js`（关系 + 学习计划两套词都在这里） |
| 数据侧迁移（幂等） | `sql/007_status_vocab_active.sql` |
| 客户端翻译层 + 判据 | `lib/services/wire_status.dart` / `test/wire_status_test.dart` |
| 「旧词被拒」的证据 | `test/auth.test.js`：发 `accepted` 断言 400 |
| 「服务端不再有这个词」的证据 | `test/wire_status_test.dart` 的跨栈对照（直接读 `vocab.js`） |

**刻意不做的事**：没有为兼容留别名（两个词都收）。留别名的代价是把「同一个语义两个词」
永久留在系统里，而它的失败方式是**静默的**（词写错不报错，只是永远匹配不到行）。
当前没有真实用户，直接切干净；已装的测试包重装即可。

**`study_plan.status` 仍未统一，且剩下的差异不是命名风格**：

| 表 | 服务端词表 | 客户端枚举 | 现状 |
|---|---|---|---|
| `relationship.status` | `pending / active / rejected` | `pending / active / rejected / removed` | ✅ 一致（客户端多一个本地独有的 `removed`） |
| `study_plan.status` | `pending / active / rejected / completed / expired` | `pendingStudentConfirm / active / rejected / withdrawn / completed` | ⚠️ 三处差异，见下 |

三处各有原因，**都不是「改个名」的事**：

- `pending` ↔ `pendingStudentConfirm`：同一个语义两个词，合并要动客户端**落库值**。
- 服务端 `expired`（到期自动失效）与客户端 `withdrawn`（家长撤回）在对面**都没有对应值** ——
  它们是两个不同的动作，凑成一个词会丢掉「谁把它结束的」。修法是**两侧都加词**，不是改词。
- 因此客户端上行仍需翻译（`wire_status.dart`），**不能**直接送 `.name`。
  这层翻译不是权宜之计，在两侧枚举一样之前它就是正确形态。

真正要避免的是**再出现第三个词**；跨栈对照测试（读 `vocab.js`）就是为这件事设的。

⚠️ **第 3 项和第 4 项其实是同一个决定。** 数据库选型不取决于偏好，取决于部署形态：

- 选 **Serverless**（多实例、无状态）→ **PG 是硬性要求**。服务端 SQLite 在这里不可行
  （实例本地文件重启即失；多实例各写一个文件 = 数据分叉）。
- 选**一台常驻云服务器** → 服务端 SQLite 也成立（写者唯一，文件锁问题消失），
  迁移成本接近于零，但代价是部署被绑死在单机、运维自己做、将来要**再做一次数据迁移**。

完整论证见方案文档 **§7.7**。**这里的建议是 Serverless + PG** ——
理由不是「SQLite 不够用」（一个家庭的数据量它绰绰有余），而是不想在库里有真实用户数据后再迁一次。

已定、无需再问的：**PostgreSQL 系**（部分唯一索引淘汰 MySQL，见 §7.3）、
**S2 先于 S3**、**22 表全迁不拆库**、**S1/S2 不需要云账号**（本机嵌入式 PG 即可，见 §5 落地情况）、
**多家庭隔离走 PG RLS**（§10.2）、**班级由老师创建**（§10.5–10.6）——
后半条的含义是：**本期不做班级，但 S2 实现 token 的 `role` 时要把 `teacher` 放进枚举**。

> §1–§7 是按「一个家庭」写的；**§10 的约束叠加在上面**，两者不冲突。
> 唯一被 §10 推翻的是「服务端 SQLite 可行」——多家庭下它不再成立（§10.1）。


---

## 9. 本计划刻意不做的事

- **不做多学校 / 机构层**——只做到「**班级**」这一级（见 §10）；
  学校、年级、权限矩阵、SaaS 化的组织树都不碰。班级级已经能满足「一个班都在上面」，
  再往上抽象会做错。
- **不做老师角色**（本期）——**同时也不做班级**：表、接口、UI 入口都不做。
  原因是**班级号由老师建班时生成**，没有建班角色就没有真实班级号，
  「申请加入班级号」这条链路**没有服务对象**（见 §10.5）。
  设计已在文档里定死（§10.5–10.6），实现与老师角色**同一个提交**落地。
  **唯一现在要准备的**：S2 实现 token 的 `role` 时，**一次把 `teacher` 放进枚举**（§10.5 ②）。
- **不做实时推送**（聊天、通知即时到达）——先轮询，够用再上 WebSocket。
- **不做离线写队列**（除非 §7 选 C）。
- **不动 `local_seed_service`**——上云后演示数据由服务端 seed，客户端那份整体废弃（见方案文档 §4）。
- **不改包名/签名/图标**——与数据上云无关，见 `open-items.md` §C2–C4。

---

## 10. 扩展到多家庭 / 一个班（2026-09-18 需求补充）

> 需求更新：**要考虑多家庭多学生使用，例如一个班的学生都在上面。**
>
> 这不只是「用户变多」。它**关掉了一个选项、逼出三条必改、还带出一个待定的角色分叉**。
> 本节是 §1–§9 的叠加约束，与前面不冲突的地方照旧。

### 10.1 它直接关掉了「服务端 SQLite」（见方案文档 §7.7）

§7.7 说「服务端独占 SQLite 在单实例下可行」。**一个班把它否决了**——
原因不是性能，是**隔离**：

SQLite **没有 RLS、没有权限系统**，隔离只能靠应用层「记得写 where」。
一个家庭时漏写 = 看到自己家另一台设备的数据，无所谓；
**一个班 40 个学生 + 40 个家长时，一次漏写 = 一整个班的数据泄露。**

→ **PostgreSQL 是唯一选择**，而且 **RLS 从「锦上添花」升格为关键技术**（见 §10.2）。

### 10.2 新增第 7 条权威规则：隔离必须是**数据库机制**，不是约定

这是「一个班」逼出来的、最重要的一条。

现在的隔离靠两样东西：
- `DatabaseService` 的查询「内置了 `studentId` 过滤」——这是**约定**，不是强制；
- 家长端在内存里用 `_belongsToBound` 过滤（陷阱⑥）——这是**最危险的形态**，
  数据已经从库里取出来了，过滤在应用层，新写的端点忘一次就漏一次。

**用 RLS 把它变成机制。** 关键设计是**不按角色写 policy，而是先算出「这个会话能看哪些学生」**：

```sql
-- 鉴权中间件在事务内解析出可见学生集合，来源按角色不同：
--   学生 → 我自己
--   家长 → 我 active 的绑定关系里的孩子（查 relationship，词见 src/vocab.js）
--   老师 → 我班上/我任课的学生（查 classroom_member）
SET LOCAL app.visible_students = 'stu_001,stu_002';

-- 于是每张有 student_id 的表，policy 形状完全一致：
ALTER TABLE homework ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON homework
  USING (student_id = ANY(
    string_to_array(current_setting('app.visible_students', true), ',')
  ));
```

**这个形状的三个好处**：
1. 一处定义、处处一致 —— 22 张表用同一个形状，新增表照抄；
2. 忘写 where 的后果从「**越权事故**」降级为「**查不到数据**」—— 从安全漏洞变成可见的 bug；
3. 可审计 —— 只要检查「这张表有没有 policy」，不用逐条 review SQL。

⚠️ **三个真坑，必须在 S1 就处理**：

1. **连接池会串身份**：必须用 `SET LOCAL`（事务内有效，事务结束即失效）。
   若用会话级 `SET`，连接被复用后**下一个请求会继承上一个人的身份** ——
   这是最隐蔽的一类越权，且测试很容易漏（单请求测试串不了）。
2. **系统级查询要单独的角色**：老师看全班、后台统计这类需要跨集合的查询，
   用 `BYPASSRLS` 的**专用角色**，**绝不能图省事给主账号加 BYPASSRLS** —— 那等于 RLS 白设。
3. **fail-closed 要验证**：`current_setting('app.visible_students', true)` 缺省返回 `NULL`，
   `= ANY(NULL)` 结果是 `NULL` → **所有行被拒**。这是我们要的方向，
   但**必须有测试证明它**（一个忘了 set 的端点应该是查不到数据，不是全放开）。

> RLS 也顺带解决了陷阱⑥的另一半：**客户端自报的 `userRole` 不再能当过滤条件**——
> 它连 SQL 都进不去，过滤依据来自服务端解析的可见集合。

### 10.3 三条必改（都是「一个家庭时无所谓、一个班时致命」）

**① 查询必须下推，不能「取全表再内存过滤」**

现在最后 4 个领域的读方法**全都没有 where**，过滤发生在控制器内存里（家长端 8 处）。
一个家庭时「全表」 = 3 个账号的数据；**一个班时「全表」= 全班学生的全部历史**，
不是慢，是根本取不回来。

**② 分页从「可选」变成「必需」**

现在所有列表查询全量返回。全班积分账本一次就是几万行。
所有列表端点必须：**默认时间窗口 + 游标分页**（键集分页，不用 offset —— 数据在写入时 offset 会跳行）。

**③ 跨学生聚合是全新的工作量**

老师的「全班看板」是 `GROUP BY student_id` 这类查询。
**而全库 JOIN 数现在是 0** —— 这不是「我们写得简单」，是说**这类查询在现有代码里根本不存在**。

⚠️ 这意味着服务端要**突破现有的代码风格**：`DatabaseService` 通篇「单表查询 + Dart 侧拼装」，
而在 40 人 × 一学期的数据量上，内存拼装会先崩。
**这部分不能靠搬代码完成，要重新写。** 索引也要相应补（§3.3 那几个不够，要按查询形状加覆盖索引）。

### 10.4 AI 配额要按人分桶，不按班

`guard.js` 现在按 `studentId` 分桶。老师批改全班作业时按谁计？

**建议按发起人计**（与 R1 一致）：老师有**独立且更大的**额度桶。
理由：老师消耗的额度是学生量的 N 倍，挤进任何一个学生的桶都会让那个学生当天不能用 AI。

> 本期无老师角色，所以这条**不需要实现**，但 R1 的「按发起人计」**现在就要写对** ——
> 配额桶是**从审计事件聚合**出来的（`metrics`），桶的语义一旦发出去，
> 将来改口径要连带解释历史审计数据。**改桶口径比改桶大小贵。**

### 10.5 老师角色是班级功能的**完整前置依赖**（2026-09-18 修正）

**决定**：班级**由老师创建**（班级号 = 老师建班时生成）→
所以**本期既没有建班角色、也没有班级号，这是正常的，不是缺口**。

> ⚠️ 这一节**撤回了同日早些时候的两条建议**。那个版本把「本期要有可用的入班功能」
> 当成了必须满足的前提 —— 而**你的决定恰好取消了这个前提**。

#### 撤回①：不 seed 班级

上一版建议「服务端 seed 造一个班（如四年级二班 / `C4-2-001`）」，理由是「得有班可加」。

撤掉的真正理由不是"麻烦"，而是**它会在班级的生命周期之外造一个孤儿**。
班级现在的生命周期很清楚：

```
老师建班 → 生成班级号 → 学生凭码申请 → 加入
```

seed 造出来的班**没有 owner**。老师上线后只有两条路：**清掉**（成员数据白填）
或**补一个 owner**（假数据变真数据）。而这条路换来的唯一好处「本期有个班可加」，
**建立在一个已经不存在的前提上** —— 没有建班角色就没有真实班级号，
也就没有「学生该加入哪个班」这个真实场景。

#### 撤回②：不让 `owner_user_id` 可空

见下方第 ③ 条 —— **"晚点建"在这里不是延后，是绕开一次约束变更**。

#### 本期改动面：**零代码，DB 不升版本**

- ❌ 不建 `classroom` / `classroom_member`（DDL 设计保留在 §10.6）
- ❌ 不写 `ClassroomRepository`（第 10 个接口）
- ❌ 不做「加入班级」UI 入口
- ❌ DB **仍是 `version: 23`**（不升 24）
- ✅ 设计全部留在文档里：DDL / RLS 形状 / `status` 语义 / 命名 / 与 `relationship` 同构

**为什么"没有调用方的接口"该等**：接口的价值是**冻结契约**，
而**没被真实调用过的接口，冻结的只是文本**。本期既没有班可建、也没有班可加，
这时写出 `ClassroomRepository` 就是**照着想象定签名** —— 老师来时一改，不但白写，
还多一层「当初为什么这么定」的解释成本。

#### ① 真正的依赖链：班级功能比「两张表」长得多

```
班级功能（老师看全班）
  └─ 建班能力（只有老师能建 —— 班级号从这来）
       └─ 老师角色
            ├─ ① token 的 role 枚举含 teacher     ← 现在 token 里连 role 都没有
            ├─ ② 授权中间件不按角色写死            ← §10.2 已定形状，与角色无关
            ├─ ③ 客户端按角色分流（老师首页/导航）  ← 全新界面
            └─ ④ 批改归属语义（gradedAt 谁为准）   ← 数据语义问题
```

**这张图的意思是**：「加老师」的工作量**主要不在数据库**，而在 ①③④ 这三处。

#### ② 现在真正要在 S2 准备的只有一处 —— 而且不在数据库里

**核实过的现状**（2026-09-18）：

- `serverless/ai-gateway/src/auth.js:69` 签发的 token **只有 `sub`（= studentId），没有 `role` 字段**；
- 客户端 `lib/utils/auth_guard.dart` **只判断"登录与否"，不看角色**。

而 S2 的任务清单里本来就有 **R1「身份只由 token 给，且必须带 role」**。

→ **所以：S2 实现 `role` 时必须一次把 `teacher` 放进枚举**，哪怕本期不签发。

这样老师上线时的工作是「**开始签发一种新角色 + 加功能**」，
而不是「改 token 结构 + 改所有校验点 + 改客户端路由 + 兼容已发出去的旧 token」。

> **这就是班级功能真正的预留口 —— 它不在数据库里，在 token 里。**
> 现在放一个枚举值的成本是零；将来补，要动签发端 + 全部校验点 + 一个旧 token 兼容期。

#### ③ 「晚点建表」不是延后，是绕开一次约束变更

`owner_user_id` 两版对比：

| | 定义 | 后果 |
|---|---|---|
| 原方案（本期建） | `TEXT`，**可空**，注释写「本期为 NULL（角色还没有）」 | 将来收紧要**写迁移**处理 NULL 行 |
| 现在（老师来时建） | `TEXT NOT NULL REFERENCES app_user(id)` | 建班时必然有 owner，**约束一开始就是对的** |

**「可空」是一个"因为本期没有老师"而存在的妥协** —— 既然决定不做，
就没必要把这个妥协写进 schema，将来再花一次迁移去抹掉它。

#### ④ 老师角色到来时的完整工作量

| # | 事项 | 归属 | 现在要准备吗 |
|---|---|---|---|
| 1 | token 的 `role` 枚举含 `teacher` | **S2** | ✅ **是**（零成本，见 ②） |
| 2 | 授权中间件先算集合、不按角色写 policy | **S2** | ✅ **是**（§10.2 已定） |
| 3 | 建班端点授权 = `role == 'teacher'` | 老师来时 | ⬜ 设计已定（见下） |
| 4 | 建 `classroom` / `classroom_member` | 老师来时 | ⬜ DDL 已定（§10.6） |
| 5 | 客户端按角色分流 + 老师首页/导航 | 老师来时 | ⬜ 全新界面 |
| 6 | `gradedAt` / `gradingSource` 归属语义 | 老师来时 | ⚠️ **需提前想清楚** |

第 3 项有一个自然推论：**建班端点的授权条件就是 `role == 'teacher'`**，
不是「任意已登录用户」。这也让上一版「先开放人人可建班、上线后再收回」那条建议一并失效 ——
**既然建班权本来就属于老师，就没有"先开放再收回"这一段。
收回权限比放开权限麻烦，而这里根本不需要放开。**

**第 6 项仍要在加老师之前想清楚**（下面这张表不变）。

#### 老师将来能看到什么：三个层次仍要分开定

本期不做老师，但这些问题不会因为「以后再说」而消失：

| 层次 | 隐私敏感度 | 说明 |
|---|---|---|
| 看全班作业**完成情况** | 低 | 合理，老师本职 |
| 看每个学生的**错题与分数** | **高** | 需要学生/家长明确同意，不能默认开 |
| **批改**学生作业 | **高** | 与家长批改冲突：`gradedAt`/`gradingSource` 归谁？谁的结果为准？ |

⚠️ 第三行是**数据语义**问题，不是加个字段能解决的 ——
`gradedAt` / `gradingSource` 现在只有「家长批改」和「AI 批改」两个来源，
老师接入后必须回答「谁的结果为准」。这条要在加老师之前想清楚。

### 10.6 入班流程：设计已定，与老师角色一起实现（2026-09-18 修正）

**决定**：和**结伴逻辑类似** —— 每个班有班级号，**申请加入即可**，暂时不做限制；
后续加上班主任后，**班主任通过才能正式加入**。这部分**不影响目前的功能**。

> **实现时机**：随**老师角色**一起做（见 §10.5）。本期**不建表、不写接口、不做入口**。
> 设计现在就定死，是因为**它决定了将来老师角色必须提供什么**：
> 先有「老师建班」，才有班级号；有班级号，才有「学生申请加入」。

#### 复用结伴那套形态（不新造流程）

| 结伴（已有） | 班级（新增，同构） |
|---|---|
| （无对应） | `createClassroom` —— **老师专属，班级号从这来** |
| `createRelationshipInvitation` 发起 | `applyToClassroom` 申请 |
| `acceptRelationship` / `rejectRelationship` 响应 | `reviewClassroomApplication` 审批 |
| `queryRelationships` 查关系 | `queryClassroomsOfStudent` / `queryClassroomMembers` |
| `relationship.status` 状态机 | `classroom_member.status` **同一状态机** |

`ClassroomRepository` 独立成**第 10 个接口**，**不并进 `RelationshipRepository`** ——
上云后它们是不同的表、不同的授权路径（点对点绑定 vs 班级集合）。

#### 表结构（实现时按这个建）

```sql
CREATE TABLE classroom (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  code          TEXT NOT NULL UNIQUE,                    -- 班级号，老师建班时生成
  owner_user_id TEXT NOT NULL REFERENCES app_user(id),   -- 班主任：建班时必然有（§10.5 ③）
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 与 relationship 表同构
CREATE TABLE classroom_member (
  id           TEXT PRIMARY KEY,
  classroom_id TEXT NOT NULL REFERENCES classroom(id) ON DELETE CASCADE,
  student_id   TEXT NOT NULL,
  sender_id    TEXT NOT NULL,             -- 谁发起的申请，同 relationship.senderId
  status       TEXT NOT NULL,             -- 实现时恒为 'active'；'pending' 留给审批。
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (classroom_id, student_id)
);
```

#### 「预留」做对了的三个判据（实现时按这个写）

判断预留有没有做对，标准是**将来加班主任审批时要改几处**：

**① `status` 要有，且判定条件要写对**

「申请即加入」**不能**写成「插进去就是成员」。正确做法：

- 插入时**显式写 `status: 'active'`**（不是省略）；
- 所有读取**显式带 `WHERE status = 'active'`**。

将来加班主任审批，改动只有**一处**：插入时写 `'pending'`。
**已加入的老成员仍是 `'active'`，不需要数据迁移。**

> 反例（看起来更省事、后期要返工）：「加入即成员、不写 status」→
> 后期要改中间件 + 补历史数据 + 处理「老成员算不算已审批」。

**② 方法名要叫 `apply`，不能叫 `join`**

`applyToClassroom` 行为是「申请即通过」；后期改成「申请待审批」时**语义不变，只是通过条件变了**。
若叫 `join`，后期要么改名（动所有调用点），要么留着一个「会进入待审批状态的 join」（更糟）。

**③ `visible_students` 要留出第三个来源**

§10.2 的中间件只从两处算可见集合（学生自己 / 家长绑定关系）。
老师接入时只需**多一个来源**（`classroom_member` 里 owner 是自己班的），**RLS policy 一行都不用改** ——
因为 policy 形状是 `student_id = ANY(visible_students)`，与「集合怎么算出来的」无关。

这正是 §10.2 那个设计（**先算集合、不按角色写 policy**）的价值 ——
写的时候看不出差别，老师一来，差别就是「改 1 处」vs「改 22 张表的 policy」。

#### 与 S2 的关系（入班顺延，结伴不延）

现在 `AuthService.register` 之后靠手机号找对方建立关系，而 `findUserByPhone` 查的是**本机库**
→ 两台手机必然抛 `StateError`（`open-items.md` §C1）。

两者在 S2 的归属**不一样**，别捆在一起：

| | 何时修 | 为什么 |
|---|---|---|
| **结伴** | ✅ **S2 服务端已修**（`/data/relationship/*`，见 §5） | 产品上就是「注册 → 有身份 → 建立关系」这个动作的后半段 |
| **入班** | **顺延到老师角色** | 入班的前置是班级号，班级号的前置是老师 —— 本期没有码可输 |

> ⚠️ 结伴的**客户端**那一半仍走本机库 —— 服务端端点已就绪，但按 §5 的顺序，
> 客户端要到 S4 才切过来。所以「两台手机互相结伴」这个场景**现在还不能演示**，
> 能演示的是服务端契约（`test/auth.test.js` 里那条结伴闭环用例）。

#### 对现有功能的实际影响：**零**

本期**没有任何代码改动，没有任何页面的行为会变**，DB 也不升版本。
班级相关的一切（表、接口、入口）都与老师角色在同一个提交里落地。

**这才是「预留」的正确形态**：结构在文档里先对（将来不会选错形状），
行为在代码里先不变（本期零风险）。**"先建两张空表"不是预留，那是把将来的决定提前冻结成妥协。**


