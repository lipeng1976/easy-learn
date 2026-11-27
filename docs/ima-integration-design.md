# ima 集成设计（按学生配置 · 多学生独立知识库）

> 状态：**归属规则 2026-11-08 由虫子重新定稿，§11 六步当日全部落地**。
> 服务端 / 客户端 / RLS 迁移 / 判据均已对齐；每步都做过还原证伪。
> 关联：`concept-drill-c-plan.md`（C 方案：App 打卡 + ima 综合卷）、`错题闭环设计.md`、`专注计时设计.md`
> 已核实事实：ima OpenAPI 支持 `create_knowledge_base` / `create_folder`（此前「只能手动」是 MCP 连接器限制，非 API 上限）

## 1. 设计目标与边界

- 伴学面向很多家庭、每个学生，学习资料（错题、打卡记录、教学资料）必须累计在 ima，且**学生之间物理隔离，绝不混库**。
- ima 在此的角色 = 公网存储 + 知识沉淀，**不是**出题 / 判题大脑（出题判题由 App / 公网大模型负责）。
- **ima 同步为可选项**：没有 ima 的家庭，相关功能可以不出现，但**绝不能报错**（11-07 硬规矩）。数据只存本地 PG，ima 不是任何功能的前置条件。
- 所有 ima 调用统一由后端 `data-service` 的 `ima_openapi` 模块发起；App 不直接持有 ima 凭证。
- 隔离粒度是「**按学生建独立知识库**」，不是一个库里用文件夹分：`search_knowledge` 是库级检索，文件夹隔离会被搜索击穿。

## 2. 所有权模型（唯一口径）

**配置主体 = 学生。一个学生 = 一份 ima 配置 = 一个独立 KB + 一行配置记录。**

| 角色 | 在这条规则里做什么 |
|---|---|
| 学生 | 配置的**归属主体**。配置以 `student_id` 为唯一键，与「哪个家长填的密钥」无关。每个学生一个独立 KB，绝不混库 |
| 家长（配置人） | 唯一的**配置入口**。在「当前伴学的学生」上下文中连接 ima；服务端逐个校验该学生在其 active 可见范围内 |
| 同一学生的其他家长 | **共享同一份配置**。父亲给孩子 A 配好后，母亲登录并选中 A 时看到的就是「已配置 + 库名」，不再出现连接表单，也不会产生第二份凭证 / 第二个 KB |
| 学生本人 | **只读**能看到「我家的 ima 同步开没开」；绝不返回凭证（明文或密文），不允许连接 / 断开 |

### 2.1 三条硬规则

1. **按学生，不按家长**：切孩子不改变配置归属；给 A 配的不会跑到 B，B 要单独配。
2. **父母共享同一行**：`status` / `kbId` / `kbName` 一律按 `studentId` 查同一行；「后连的家长覆盖映射」这类冲突从模型上就不存在。
3. **ima 仍然可选**：没开通时不弹红错、不抛异常、入口可以隐藏；只有用户**主动点「连接」**才允许回明确错误。

### 2.2 为什么不是「一个库 + 名字 / 文件夹分学生」

`search_knowledge` 是库级检索，文件夹级隔离会被一次搜索击穿。`伴学-<姓名>-<学号前 6 位>` 只是**幂等查重键 + 给人看的标签**（ima 库名 ≤25 字节），不是隔离手段；真正的身份是「学生 → kb_id」那行映射。

### 2.3 为什么废止「按家长 / 按家庭存凭证」

本工程 `app_user` **没有 `family_id`，库里也没有 family 表**，旧文档写的 per-family 模型从未落地。实际落地的是「凭证挂当前登录家长个人」，于是一个学生绑父母两人时会出现：

- 另一位家长的状态恒为「未开启」，KB 列表为空；
- 学生交卷时 `select parent_id ... limit 1` 无排序，可能取到没配的那位 → 交卷成功但档案**静默不推**；
- 两位家长都去连接 → `on conflict (student_id) do update` 互相覆盖归属，先连的那位反而读不到自己的 KB。

`relationship` 的约束是 `UNIQUE(student_id, parent_id)`，**一个学生绑多个 active 家长在结构上是允许的**，所以这不是边角情况。

### 2.4 边界与待定实现决策（规则已定，代码未改）

- **多孩子**：每个孩子一行配置；家长切孩子时状态必须跟着切，不许缓存上一个孩子的状态。
- **重连 / 换密钥**：写同一行，不新增行。⚠️ 若换成**另一个 ima 账号**，新账号下会另建同名 KB，旧库成为孤儿（ima 无删除接口）——是否限制「已有配置时只允许换密钥、不允许换账号」待定。
- **解除结伴**：配置属于学生，不随关系删除；新绑定的家长按学生即可查到（RLS 放行范围待定）。
- **凭证可见性**：客户端永远只见「状态 + 库名」；明文只在服务端调用 ima 的那一瞬存在。父母共享的是**状态**，不是凭证本身。
- **RLS**：需要放行「同一学生的其他 active 家长」读状态；或服务端先用 `requireVisibleStudent` 校验关系，再用特权只读连接取配置。⚠️ 多家庭隔离仍靠 PG RLS + `SET LOCAL`，任何绕过 RLS 的读都必须带判据。
- ✅ **已按最小实现落地**：保留 `ima_credential.owner_user_id`（谁配的谁持有），把已有的 `ima_student_kb`（`student_id` 主键 + `owner_user_id`）作为「学生 → 配置」的唯一入口；所有查询统一走 `getStudentImaConfig(studentId)` = `studentId → 映射行 → owner_user_id → 凭证`。**没有新表、没有数据迁移**，真库原有那一行天然符合新规则。

> 配置状态的现实字段：服务端是 `ima_credential.status`（`unconnected` / `active` / `expired`）；「某学生是否可用」由 `ima_student_kb` 有没有这行 + 该行 owner 的 `status` 共同决定。旧文档里的 `family.ima_status` **在本工程不存在**，不要再引用。

## 3. 配置流程（按学生 · 家长端发起 · 可选）

1. 家长端选中**当前伴学的学生** A（客户端是 `ParentController.selectedStudentId`，家长首页 / 总览页的孩子切换器）。未查到 A 的配置时才显示连接表单；已配置则直接显示状态与库名。
2. 提交 `clientid` / `apikey` 时**必须带 `studentId=A`**。服务端用 `requireVisibleStudent(ctx.visibleStudents, studentId)` 校验，防止一个家长往别人家孩子名下写配置。
3. 服务端：加密凭证 → `ensureStudentKb`（按库名幂等查重，命中就复用，不重复建库）→ **写 / 更新一行**「学生 A → 凭证持有人 + kb_id + kb_name」→ backfill 错题与打卡。
4. 另一位家长选中 A 时，状态按 `studentId` 查到同一行 → `active`；不出现连接表单，不新建 KB。
5. 学生端只读状态；`connect` / `disconnect` 对 `role !== 'parent'` 一律拒绝。

## 4. KB 生命周期（建库不可逆，省着用）

- 首次为**某个学生**配置时 `create_knowledge_base` 一次（库名带学号前 6 位），再 `create_folder` 建三个固定文件夹，**全程只建一次**。
- 后续只往里 `add_knowledge`，绝不为每次打卡新建库。
- 删除 / 清理不依赖 ima 删除 API（社区反馈不稳定），以「标记作废 + 不检索」为主。

## 5. ima_openapi 模块职责（后端）

统一封装所有 ima 调用，作为唯一出口：

- `ensureStudentKb({ studentId, displayName, credential })`：幂等建库 + 建文件夹（建库前先 `search_knowledge_base` 按库名查重）。
- `uploadMarkdown(kbId, folderId, title, md)`：`check_repeated_names` → `create_media`（拿 COS 凭证）→ COS 上传 → `add_knowledge`。
- `searchStudentKb(kbId, query)`：**始终带 `kbId`**，从机制上杜绝跨库检索。
- `verifyCredential(cred)`：连通性自检，供「连接 ima」时与定时健康检查调用。
- 所有调用带统一头 `ima-openapi-clientid` / `ima-openapi-apikey` + 重试退避（社区反馈有频控）。

## 6. 两条写入链路（均受「该学生配置 active」守卫）

> 每条链路执行前按 `studentId` 查该学生的 ima 配置，守卫条件是配置 `status === active`：**非 active 直接返回，不报错、不阻断主流程**，数据留在 PG。ima 永远不是功能前置条件。

1. **错题档案**：data-service 从 PG 读该学生错题 → 按学科分档 → 每科按知识点聚合 md → 上传到该生 KB 的 `错题档案`，文件名 `错题档案-<学科>-YYYY-MM-DD.md`。
2. **打卡档案**：打卡记录入库后汇总 → 同样按学科分档 → `打卡档案-<学科>-YYYY-MM-DD.md` → 该生 KB 的 `打卡档案`。

> ⚠️ **为什么必须分科**（2026-11-02）：原实现把语文 / 数学 / 英语塞进同一份 md，连 `subject` 都不写，家长在 ima 里翻档案根本看不出某道题是哪一科。现在一科一份，标题带科目，每题带一行 `- 学科：xx`；`subject` 为空进 `未分科`，不并进任何一科（猜错科目比不猜更糟）。
> ⚠️ 分档后同一天一次同步会上传 N 份（N = 学科数）；ima 侧没有删除接口，旧文件只能手动清。

**补推（backfill）**：某个学生的配置从 `unconnected` 变为 `active`（首次连接或重连）时，触发一次历史补推 —— 把该生已有错题与历史打卡全量写入 ima，保证「先本地后用 ima」的用户资料不丢、不重。

> 教学资料（如《初一数学逻辑转换训练手册》）由家长 / 老师上传，落到 `教学资料` 文件夹，作为 C 方案综合卷的出题素材。
>
> ⚠️ **11-15 起 ima 不再是纯单向**：考完的试卷由家长在 ima 里手工整理成错题 MD，
> 放到 `教学资料/试卷错题/`，App 可以**读回来写进 `review_mistake`**，见
> `doc/exam-mistake-import.md`。但「错题档案」文件夹本身仍是**只写不读**的镜像，
> 两个目录物理隔离 —— 否则误选一份 83 条的镜像会把旧错题整批重复灌回去。
> ima 依然**不是**出题 / 判题大脑。

## 7. 鉴权与隔离的硬约束（来自真实 API）

- **写权限看 `role_type`**：共享库普通成员拒写。配置持有者是 owner，天然可写。
- **建库不可逆**：一次建库永久存在，绝不为每次操作新建库。
- **检索隔离**：所有读取必须带 `kbId`；禁止无 `kbId` 的全库搜索。
- **密钥失效兜底**：key 可能过期。探测到 401 / 403 → 把该学生配置对应 owner 的 `ima_credential.status` 标为 `expired` → 家长端提示「重新连接 ima」；App 侧打卡 / 错题导出暂时降级为本地存、等重连后补推，**绝不静默丢数据**。

## 8. 部署形态

| 形态 | ima 调用方 | 凭证位置 |
|---|---|---|
| 本地部署（当前） | `data-service` 跑在家里机器 | 本机环境变量 + PG 加密列 |
| 云端部署 | FC3 函数出网访 `ima.qq.com` | 函数计算密钥 + RDS 加密列 |

两种部署 ima 集成代码完全一致（都是后端模块出网调公网 API），与「是否在家局域网」无关。

## 9. 与既有工作的关系

- 已验证可用：`ima_kb_LpF9Nc31`（李雨霏个人库）、COS 上传脚本、MCP 连接器。
- 打卡出题 / 判题链路不受影响，结果通过本模块落 ima。
- 已跑通的是「一个家长 + 一个学生」；按 §2 改为按学生配置后，**父母共管 / 多孩子**才是正式支持的场景。

## 10. 开放风险 / 待实测

- OpenAPI key 真实有效期与配额（决定重连频率设计）。
- 单 ima 账号 KB 数量上限（影响多孩子家庭是否要分账号）。
- ~~父母共管时，非配置人家长的读权限如何放行~~ → 已定：`024_ima_coparent_read.sql` 加两条 FOR SELECT policy，只依赖 `relationship`（家长可读自己的关系行），不绕过 RLS、不放开写。真库判据见 `scripts/probe-ima-coparent.mjs`。
- 「换成另一个 ima 账号」要不要禁止（见 §11 已知边界）。

## 11. 落地记录（2026-11-08，§2 规则 → 代码）

| # | 代码 | 说明 |
|---|---|---|
| 1 | `ima_repository.js:getStudentImaConfig`、`routes/ima.js` 三端点、`lib/repositories/ima_repository.dart`、`http_ima_repository.dart`、`ImaController.bindStudent`、`ima_settings_page`、`profile_page` | 三端点带 `studentId`；客户端从 `ParentController.selectedStudentId` 取，`ever` 监听切孩子；`getStatus` 的 query 进读缓存 key，切孩子不会命中上一个孩子的状态。写端点用 `requireVisibleStudent` 拦越界（403），只读 status 永不抛错。 |
| 2 | `connectIma` | 只给请求里那一个学生建库；该学生已有 active 配置 → **直接复用返回**（`reused:true`），不联网、不写库、不建第二个 KB；已有映射且配置人是另一位家长 → 明确提示由对方更新，绝不覆盖归属。 |
| 3 | `syncStudentArchive` / `resolveConfigForStudent` | 废掉 `resolveImaOwner` 及其 `limit 1`；按 `quiz.student_id → 映射行 → 配置人凭证`，与「谁在提交」无关。母亲交卷也能推到父亲配好的库。 |
| 4 | `reading.js:resolveReaderContext` | 只认该学生自己的 `kbId`，删掉「owner 名下第一个 KB」兜底。 |
| 5 | `sql/024_ima_coparent_read.sql` + `scripts/probe-ima-coparent.mjs` | 两条 FOR SELECT policy 放行共管家长读映射 / 凭证状态；真库探针在单事务内插临时关系 → 以 `app_rls` 身份验四种可见性 → ROLLBACK，一行数据不落库。 |
| 6 | `test/ima-student-scope.test.js`（12 条）+ `test/ima_student_scope_test.dart`（12 条） | 父母共管、不建第二个库、切孩子（含慢响应竞态）、越界、学生只读、交卷、阅读不串库、无 ima 不报错；两份新测试都进了各自的 runner（`run-tests.mjs` 清单 / `flutter test` 自动发现）。 |

### 证伪结果（还原后恰好对应判据变红，恢复后全绿）

| 还原的旧行为 | 红 |
|---|---|
| 只按登录家长读凭证 | 2 条：母亲看不到父亲配的状态、学生端取错家长 |
| 去掉「复用已有配置」 | 1 条：另一位家长再点连接会建第二个库 |
| 恢复「owner 名下第一个 KB」兜底 | 1 条：老二没配置却读到老大的库 |
| 客户端不再传 `studentId` | 4 条：三个端点 + 切孩子缓存不分离 |
| 切孩子不清状态 | 1 条：界面残留上一个孩子的「已开启」 |
| 去掉状态请求代号（不丢弃迟到的旧响应） | 1 条：快速切孩子时界面又被改回上一个孩子 |
| 真库 DROP 024 两条 policy | 探针红；按迁移文件重建后绿 |

全量回归：data-service **408/408**；Flutter **1376 通过 / 2 skipped / 0 失败**；`flutter analyze` 0 error（仅 2 条既有 info）。

> `ImaController.loadStatus` 每次拉取代号 +1，只有最后一次能写 `status` / `busy`：
> 快速切孩子时，上一个学生的慢响应不能把界面改回去（阅读记录那边的 `logsGeneration` 同理）。

### 已知边界（规则未定，代码按最小实现）

- **断开权限只给配置人**：RLS 只允许改自己的凭证行，另一位家长点「断开」会收到明确提示而不是静默失败；两家共享的是**状态**，不是改凭证的权利。
- **同一配置人下的多个学生共用一行凭证状态**：断开其中一个孩子会把该 owner 的 `status` 置 `unconnected`，连带停掉同 owner 的其它学生。要做成真正的「按学生开关」需给 `ima_student_kb` 加 `status` 列（新迁移），本次未做。
- **换 ima 账号**：重连时 `ensureStudentKb` 按库名幂等查重，同一账号不会重复建库；但若换成**另一个账号**，新账号下会另建同名 KB，旧库成孤儿（ima 无删除接口）。是否禁止换账号待定。
- **旧 APK 兼容**：不带 `studentId` 的 status 会挑「第一个有配置的可见学生」，connect 只配可见列表里的第一个孩子；不会报错，但多孩子家长要切孩子分别配置得用新 APK。\n- **越界 studentId 在真 HTTP 层是 403**：`app.js:narrowToVisible` 对所有 `/data/*` 统一先校验，不因为 ima 是可选功能就放行；handler 内的「按未开通返回」只是第二道防线。这是安全语义，不是「没有 ima 却报错」。
- 云上部署必须跑 `024` 迁移（`node scripts/migrate.mjs --env-file <文件> --yes`）；本机 `D:\easy_learn_home` 已应用。

## 12. 交卷归档改为后台队列（2026-11-27）

**症状**：英语打卡常提示「成绩已算出，但还没存到云端：网络较慢或服务繁忙」。服务端 access log 显示 `/data/checkin/submit` 每次 29–65s 才回 200，成绩其实已经落库。

**根因**：`submitCheckin` 在请求里 `await syncStudentArchive`。ima 是**全量重建**（KB 查找 + 每科上传 MD，单次 HTTP 上限 15s / COS 60s），而客户端数据面只有 10s 超时 → 误报。

**新口径**：

- `submitCheckin` 只 `ctx.deferImaArchive(quiz.student_id)`，响应里 `ima = { synced:false, reason:'queued' }`。交卷那一刻如实说「还没同步」，不冒充已同步。
- `app.js` 在 `withRequestContext` **提交后**才调用队列；事务回滚时不排队，避免后台在 commit 前读到旧数据。
- `routes/ima.js:createImaArchiveQueue` 用**自己的连接**跑 `withRequestContext(pool, identity, ...)`。`void syncStudentArchive(client, ...)` 是禁止写法：请求结束连接就归还池里，挂起的 promise 会在别人的事务上继续跑（身份串号）。同一学生重复排队后来者覆盖前者；串行执行，避免占满连接池反过来拖垮交卷。
- 失败只记日志，绝不回滚成绩。没有 ima 的家庭照常交卷。

**判据**：`test/ima-archive-queue.test.js`（独立连接 + SET LOCAL 身份 + 提交后才 schedule）、`test/checkin-store.test.js`（交卷事务里没有 ima 查询、不登记就红）。证伪：恢复 `await syncStudentArchive` 后 2 条变红。
