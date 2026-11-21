# 「今天练什么」· 配置区 / 出题区分层设计

> 状态：**2026-11-12 设计定稿并落地；2026-11-13 追加英语两本资料**（§0 决策 3、§6 点击语义、§9 判据同步修订）。
> 起因：虫子提出「今天练什么这一块分成两块 —— 一块配置各科的练习范围（数学哪些题型、英语单词、
> 语文的字词诗词、历史的时间点和关键事件），一块出题，不同科目用不同色块区分，
> 家长平时只配置、出题时只在出题区操作」；追加一句「还有其他科目，都预留着，物理生物化学地理……」。
> 关联：`concept-drill-c-plan.md`（概念打卡骨架）、`word-checkin-design.md`（英语单词打卡）、
> `错题闭环设计.md`（知识点来源）、`ima-integration-design.md`（可选能力规矩）。

---

## 0. 已拍板的决策（不再讨论）

| # | 决策 | 含义 |
|---|---|---|
| 1 | **两段式版面** | 上＝「学科范围」（长期配置，一年改几次）；下＝「今天出什么」（每日出题色块）。两者在同一个卡组里，用分段标题隔开。 |
| 2 | **点色块直接出题** | 不再弹确认框、不再进设置页。范围就是上次配好的那份；要改先改配置区。 |
| 3 | **十科都出题，题型只有选择 / 判断** | 十科走服务端 AI 出**教材题**（`/data/checkin/generate`）；英语另有本地**单词题**（`WordDrillController`）。11-12 取消「出题待开放」：卡住的不是模板，是**题型要先定**。11-13 修订：英语不再只有单词题 —— 见决策 7。 |
| 7 | **英语两本资料并存（11-13）** | ①词表 MD（`教学资料/Wordlist`）→ 本地单词打卡；②教材骨架 MD（`教学资料/教材/英语/`）→ AI 出语法 / 时态 / 句型题。两套范围各存一处（`word_scope` / `subject_scope`），各有一个配置入口，色块并列两个动作。 |
| 4 | **十科全开** | 语文 / 物理 / 化学 / 生物 / 历史 / 地理 / 政治 / 其他 都能配范围、都能直接出题。统一只出 `choice` / `judge`——判分在客户端本地做，填空的 `0.5` vs `1/2` 会被判错，做对的孩子却不知道发生了什么。 |
| 5 | **范围 = 家长指定（可借错题本挑）+ 教材章节** | 配置页会列出这一科在错题本里出现过的知识点当**候选**（点一下等于家长指定），也允许手打补充。错题本只是挑选时的参考，不是出题的来源。上限 6 条。 |
| 6 | **合并掉三张平级卡** | 原「概念打卡 / 阅读 / 单词」三张卡里的前两张并入看板；阅读仍是独立卡（它有自己的任务与进度）。信息不丢 —— 英语块保留「今天做了几题 · 正确率」。 |

### ⚠️ 口径澄清（一句话讲清「配置区」和「出题区」的分工）

- **配置区回答「这一科练什么」** → 落库在 `subject_scope`，一科一行，长期有效。
- **出题区回答「今天出不出」** → 只读配置，不产生新配置；出完把份数记在 `checkin_quiz` 里。
- 出题**不写回配置**：家长点一次色块不该改变他长期设的范围（否则「今天随手点一下」会污染配置）。
- 未配置的科目**不出题**：一个点了才失败的按钮比没有按钮更糟。点了会进配置页并说明
  「先给这一科选教材或填两个知识点」。⚠️ 错题本**不兜底** —— 它属于「复习」那条线
  （见 `doc/review-vs-plan.md`）。

---

## 1. 目标与验收标准

**目标**：家长在「计划」页的**一个区块**里完成两件事 —— ① 平时把十科的范围配好；
② 每天点一下色块出题，不用再回答「哪科、几题、什么难度」。

**验收标准**（缺一条不算完成）：

1. 计划页「今天练什么」下只有一块看板：上「学科范围」、下「今天出什么」，分段标题写明各自用途；
2. 十科全部可在配置页配置（白名单逐字一致：语文/数学/英语/物理/化学/生物/历史/地理/政治/其他）；
3. 已配置的科目在配置区逐行显示「每天 N 题 · 难度 · K 个范围」，点行进配置页；
4. 任意已配置的科目色块点一下**直接出题**，用已配范围（题量 / 难度 / 知识点全部来自 `subject_scope`），而且题的 `subject` 就是这一科；
5. 语文 / 历史（及其余五科）与数学走**同一条**出题路径，题型只有选择题 / 判断题；不再有「出题待开放」；
6. 英语色块并列两个动作：「看记录 ›」进单词记录页，「出一组教材题 ›」调 AI；配置区英语那一行显示**两套摘要**（教材 + 词表）与**两个配置入口**（词表 / 教材），互不覆盖；
7. 出题失败按原因说人话（无错题 / 模型超时 / 模型未给合格题），不统一成「出题失败」；
8. 读不到配置（`026` 未迁移 / 断网）时页面照常渲染成「每科未配置」，不弹红条、不抛异常；
9. 切孩子后配置与待完成份数跟着换人（不拿哥哥的范围给弟弟出题）；
10. 本地模式（`DatabaseService.isCloud == false`）整块不渲染。

---

## 2. 信息架构：为什么是「上下两层」而不是「四张并列卡」

改动前的计划页是三张平级卡：

```
┌ 概念打卡 ────────────────┐   ← 既有配置（学科/知识点/题量/难度）又能出题
│ 你今天要做 5 道数学题     │
│ [去配置]  [开始打卡]      │
└─────────────────────────┘
┌ 英语单词打卡 ─────────────┐   ← 同样既配置又打卡
└─────────────────────────┘
┌ 英文阅读 ────────────────┐
└─────────────────────────┘
```

问题不是「卡太多」，是**两种时间尺度混在一张卡里**：「配一次范围」和「每天出一组」
长得一模一样，家长每次都得重新判断「我现在是在配置，还是在出题」。

改动后按时间尺度分层：

```
今天练什么                                    学科范围 · 出题
┌ 学科范围 ──────────────────────────┐   配一次长期有效
│ ■ 数学   每天 5 题 · 基础 · 3 个范围   配置 │
│ ■ 英语   <词表名> · 已学区间 · 每天 10 题 配置 │
└──────────────────────────────────┘
┌ 今天出什么 ─────────────────────────┐   点色块就出
│ ┌ 数学 ──────┐ ┌ 语文 ──────┐ │
│ │ 待完成 1 份 │ │ 未配置      │ │
│ │ 每天5题·基础│ │ 先配范围，再出题│ │
│ │ 再出一组 ›  │ │ 去配置 ›    │ │
│ └────────────┘ └────────────┘ │
│ ┌ 英语 ──────┐ ┌ 历史 ──────┐ │
│ │ 孩子本地出题│ │ 未配置      │ │
│ │ 今天10题·80%│ │ 先配范围，再出题│ │
│ │ 看记录 ›    │ │ 去配置 ›    │ │
│ └────────────┘ └────────────┘ │
│ (物理)(化学)(生物)(地理)(政治)(其他)│  ← 小色块，入口都在
│                    打卡记录与历史 › │
└──────────────────────────────────┘
```

**四个主科进 2×2 色块，其余六科收进一行 `ActionChip`**：十科全做成大色块会把
「阅读」「学习计划」推出首屏；但入口不能少 —— 小色块一样能进配置页。

---

## 3. 数据模型：`026_subject_scope.sql`

```sql
create table if not exists subject_scope (
  student_id  uuid not null,
  subject     text not null,
  daily_count integer not null default 5,
  difficulty  text not null default '基础',
  points      jsonb not null default '[]'::jsonb,
  updated_at  timestamptz not null default now(),
  primary key (student_id, subject),
  constraint subject_scope_count_check check (daily_count in (3, 5, 8)),
  constraint subject_scope_difficulty_check check (difficulty in ('基础','提高','挑战')),
  constraint subject_scope_points_check check (jsonb_typeof(points) = 'array')
);
alter table subject_scope enable row level security;
alter table subject_scope force row level security;
-- 策略：own_rows（using/with check 均走 current_setting('app.visible_students')）
```

四个刻意的选择：

1. **主键是 `(student_id, subject)`** —— 一科只有一行，天然幂等：家长连点两次保存不会长出两行。
2. **`points` 用 JSONB 而不是子表** —— 它是「最多 6 条的短清单」，顺序即优先级，
   不需要单独查询/关联；建子表只会多一次 join 和一套 RLS。
3. **`CHECK` 挡在库上，不只挡在路由上** —— 路由校验会被第二个写入口绕过（这个仓库已经有过先例），
   库上的约束是最后一道。
4. **不用 `ON DELETE CASCADE`** —— 与全库口径一致（删账号靠后台脚本单事务清理），
   这里不加外键，避免删账号时被约束挡住。

---

## 4. 服务端：`/data/subject/*` 四条路由

| 方法 | 路径 | 作用 | 失败口径 |
|---|---|---|---|
| GET | `/data/subject/scopes?studentId=` | 该生已配置的所有科目 | 表未迁移 → 空列表（读降级） |
| GET | `/data/subject/scope?studentId=&subject=` | 单科；没配过返回 `configured:false` + 默认值 | 科目不在白名单 → 400 |
| GET | `/data/subject/seeds?studentId=&subject=` | 这一科在错题本里出现过的知识点（配置页候选） | 读不到错题本 → 空列表 |
| PUT | `/data/subject/scope` | 家长保存一科范围（整行覆盖） | `026` 未迁移 / 非家长 / 越界 → 明确报错 |

**为什么 `seeds` 不并到 `/data/checkin/seeds`**：那条路的调用方（出题设置页）要的是全科候选，
加个 `subject` 参数等于让两个用途挤一个形状。这里多一条路由的成本只有一行注册，
聚合逻辑仍是同一份函数 `collectCheckinSeeds(client, studentId, subject)`。

**写端点为什么「响亮」**：家长点了保存正在等结果，静默失败会让他以为配好了。
读端点相反 —— 页面每科显示「未配置」即可，弹红条等于把「可选能力的缺省」报成故障
（11-07 定的规矩：功能可以缺，不能出错）。

**校验清单**（`putSubjectScope`）：

- `requireParent(ctx)` → 学生调用 403；
- `studentScope(ctx, body.studentId)` → 越界学生 403；
- 科目 ∈ `SUBJECTS` 十科白名单，否则 400；
- `dailyCount ∈ {3,5,8}`、`difficulty ∈ {基础,提高,挑战}`；
- 每条范围 ≤ 60 字、最多 6 条、去重保序（空串直接丢，不报错）。

---

## 5. 客户端结构

| 文件 | 职责 |
|---|---|
| `lib/models/subject_scope.dart` | `kSubjectNames`（十科，唯一来源）、`kSubjectDrillReady`（= 十科）、`kCheckinQuestionTypesLabel`（题型说明）、`kSubjectDailyCounts`、`kSubjectDifficulties`、`subjectPointLabel()`（每科的说法）、`SubjectScope` |
| `lib/constants/subject_colors.dart` | 十科配色 + `subjectColor()`（未知科目回中性灰，不抛错） |
| `lib/services/subject_api.dart` | `SubjectScopeRepository` 抽象 + `HttpSubjectScopeRepository` + `UnavailableSubjectScopeRepository`（写抛 `StateError`，读返回空） |
| `lib/controllers/subject_board_controller.dart` | `scopes` / `pendingBySubject` / `wordSummary` / `wordToday` / `generating` / `hint`；`load()` / `generate()` / `scopeOf()` / `canGenerate()` |
| `lib/pages/parent/subject_scope_page.dart` | 配置页：科目配色头、题量 3/5/8、难度、范围条目（InputChip + 手填 + 错题本候选 FilterChip） |
| `lib/widgets/subject_board.dart` | 看板：① 学科范围卡 ② 出题色块 2×2 ③ 其余六科小色块 ④「打卡记录与历史 ›」 |

**只有一个 controller 的原因**：配置区改了范围、出题区立刻要用新范围出题；出题后「待完成」
也要马上变。两块各读各的必然出现「配好了但出题还用旧值」—— 那不是缓存问题，是两个真相。

**`_generation` 自增防串**：切孩子 / 连续 `load()` 时，慢回来的旧请求直接丢弃
（`if (generation != _generation) return`），与 `ParentController` 同一手法。

---

## 6. 色块点击语义（一张表说清）

| 科目状态 | 显示 | 点一下做什么 |
|---|---|---|
| 九科（除英语）· 未配置 | 「未配置 / 先配范围，再出题 / 去配置 ›」 | 进配置页 |
| 九科 · 已配置 · 空闲 | 「今天还没出 / 每天5题·基础 / 出一组 ›」 | **直接出题** → 成功后跳 `/checkin` |
| 九科 · 已配置 · 待完成 N 份 | 「待完成 N 份 / … / 再出一组 ›」 | 再出一组 |
| 九科 · 出题中 | 「出题中 / … / 请稍候…」 | 不可点（防连点出两份） |
| 英语 · 未配词表 | 「未配词表 / 先选一本教材词表 / 去配置 ›」 | 点色块进 `/word-scope` |
| 英语 · 已配词表 | 「每天自动出题 / 今天 10 题 · 正确率 80%＋词表摘要 / **看记录 › ＋ 出一组教材题 ›**」 | 「看记录」进 `/word-daily-logs`；「出一组教材题」调 `generate('英语')` |
| 英语 · 教材题没配范围 | 同上 | 点「出一组教材题」**不发请求**，进 `/subject-scope`（arguments=`英语`），不是词表页 |

> 11-13 口径：英语那一行在配置区显示两套摘要，行尾「词表」「教材」两个按钮各进各的页；
> 整行点击保持旧行为（`/word-scope`）。两个动作写在 `Wrap` 里而不是 `Row`，
> 360dp 窄屏会自动换行，不会撞成红条。

两条刻意的规则：

- **未配置的科目必须能点**。曾经写成「没配好就禁用」，结果「去配置 ›」摆在那里点不动 ——
  比没有入口更糟。
- **出题中不能点**。防连点出两份 —— 那会出现「孩子做了一套、另一套挂着待完成」，
  家长以为系统坏了。

---

## 7. 十科预留的口径

- `kSubjectNames` 十项，与服务端 `SUBJECTS`、`HomeworkItemNormalizer.subjectNames` **逐字同序**。
  三处散着写的话，新增一科时总有一处漏掉，症状是「客户端能选、服务端 400」或
  「配好了但没有色块」。服务端那份有 `test/subject-scope.test.js` 逐字断言，客户端有
  `test/subject_board_test.dart` 断言同一串字面量。
- `kSubjectDrillReady = kSubjectNames`（十科）。**它是「能出题」的唯一开关**：
  色块不再有「出题待开放」分支。要临时关掉某科，从这份名单里去掉即可，配置、存储、
  列表全部不用动。
- ⚠️ 开一科**只改名单是不够的**：题型必须是 `choice` / `judge`。服务端 `normalizeQuestions`
  与网关 schema 双层只放这两种，客户端判分也是纯比较。想加填空/解答，先做归一化判分
  （`0.5` vs `1/2`、`x=3` vs `3`），否则做对的孩子会被判错。
- 同一个字段 `points` 在各科叫不同名字（`subjectPointLabel`）：数学「知识点」、语文
  「字词 / 古诗 / 课文」、历史「时间点 / 关键事件」、物理化学生物「章节 / 知识点」、
  地理「区域 / 知识点」、政治「考点」。在历史页写「知识点」会让家长以为填错了地方。

---

## 8. 失败与降级

| 场景 | 表现 | 判据 |
|---|---|---|
| `026` 未迁移（读） | 每科显示「未配置」，页面正常 | `subject-scope.test.js` 读降级用例 |
| `026` 未迁移（写） | 保存回明确错误，不假装成功 | 同上写响亮用例 |
| 断网 / 401 | `Unavailable/Http` 仓库抛错 → controller 吞掉 → 按未配置渲染 | `subject_board_test.dart`「读不到配置不抛错」 |
| 出题无错题（`no_seed`） | 灰字「这科还没有错题记录，先在配置里填两条范围再出。」 | `subject_board_test.dart`「no_seed 说人话且退出 generating」 |
| 模型超时（`model_timeout`） | 灰字「模型这次太慢了，过一会儿再试。」 | 同上（`_describe`） |
| 模型给的题不合格（`schema_violation`） | 灰字「模型这次没给出合格题目，点一下重试。」 | 同上 |
| 本地模式 | 整块 `SizedBox.shrink()` | 与 `CheckinEntryCard` 同一条理由：范围存在服务端 |
| 切孩子 | `ever(selectedStudentId)` 触发 `load()` 重拉 | `parent_plans_tab_test` + controller 用例 |

**用灰字而不是红条**：出题失败是可以自己处理的（去录错题 / 过会儿重试），不是故障。
红条只留给「点了保存但没保存上」这种需要立刻知道的事。

---

## 9. 判据清单

| # | 判据 | 位置 |
|---|---|---|
| 1 | 十科白名单逐字一致（客户端 / 服务端两侧） | `test/subject_board_test.dart`、`test/subject-scope.test.js` |
| 2 | 十科配色两两不撞、未知科目回中性灰 | `test/subject_board_test.dart` |
| 3 | 点色块用**已配范围**出题（count/points/difficulty 来自 scope） | `test/subject_board_test.dart` |
| 4 | 未配置也能出（`difficulty` 传空串，由服务端回落） | 同上 |
| 5 | 待完成份数按科统计 | 同上 |
| 6 | 读不到配置不抛错、不弹红条 | 同上 |
| 7 | `no_seed` 说人话且 `generating` 必须清空 | 同上 |
| 8 | 英语块保留「今天做了多少」；词表题本地出、教材题走 AI，两条不混 | `test/subject_board_test.dart` |
| 15 | 英语色块两动作、第二动作 `generate('英语')` 且带英语教材范围、无范围进教材页而非词表页、配置区双入口与双摘要 | 同上（11-13 新增 6 条 widget 判据） |
| 9 | 十科都能存 / 越界 400 / 去重保序 / 非家长 403 / 越界学生 403 | `test/subject-scope.test.js` |
| 10 | `026` 未迁移：读降级为空、写报错 | 同上 |
| 11 | `seeds` 按科过滤且上限 30 | 同上 |
| 12 | 计划页锚点从「概念打卡」改为「今天练什么」 | `test/parent_plans_tab_test.dart` |
| 13 | `putJson` 真的发 PUT（不是 POST） | `test/data_api_verb_test.dart` |
| 14 | 测试文件进 runner 清单 | `test/runner-list.test.js` |

### 9.1 证伪记录

- **判据 3 的证伪**：把 `generate()` 里的 `count: scope.dailyCount` 改回写死 `5`，
  「点色块用已配范围」立刻变红；还原后复绿。
- **判据 13 的证伪**：这次是真事故 —— 保存范围连点 6 次都 405。根因是
  `DataApiClient._send` 写成 `method == 'GET' ? get : post`，`putJson` 实际发的是 POST。
  修前 `data_api_verb_test` 红（`[method_not_allowed] 405`），修后绿。
  ⚠️ 教训：`_send` 这种「一处分派三种动词」的地方，必须有一条断言**报文动词**的用例，
  只断「结果对不对」是抓不到的（GET 拿不到东西也会抛，看起来像网络问题）。
- **判据 7 的证伪**：把 `finally { generating.remove(subject); }` 删掉，
  「no_seed … 退出 generating」变红 —— 这条判据专治「出题失败后按钮永久变灰」。
- **布局证伪**：`_drillGrid` 最初用 `Row(crossAxisAlignment: stretch)`，
  在 ListView 里拿到无限高约束，整页抛 `BoxConstraints forces an infinite height`；
  外面包 `IntrinsicHeight` 后正常，同时保留「同一行两块等高」。
- **11-13 英语两本资料 · 三处真还原证伪**（`test/subject_board_test.dart`，21 条）：
  1. 把 `_drill` 的 `_openConfig(subject, forTextbook: subject == '英语')` 改回
     `_openConfig(subject)` → 恰好「英语没配教材范围：点第二动作进教材范围页」1 条红，
     其余 20 条仍绿。
  2. 把 `canGenerate` 改回 `subject != '英语'` → 恰好「十科都能调 AI 出教材题」1 条红
     （`Expected: true / Actual: false`），其余 20 条仍绿。
  3. 把英语色块第二动作换成 `SizedBox.shrink()` → 恰好 3 条与第二动作相关的判据变红，
     其余 18 条仍绿。
  三处还原后均已恢复，恢复后 21 条全绿。

---

## 10. 验收

- `flutter analyze`：**0 error**（2 条既有 info，与本次无关）。
- `flutter test`：**1418 通过 / 2 跳过 / 0 失败**。
- 服务端 `npm test`：**441/441 通过**。
- `probe-subject-e2e.mjs`（真 HTTP + 真库，自带清理）：**10/10 通过，残留 0**。
- 本机服务探活：`/health` 200、`/data/subject/scopes` 401（已加载）、`/data/subject/seeds` 401、
  不存在的路径 404（证明 401 是权限而不是兜底）。
- 本机版 APK：`easy-learn-local-8.138.227.136-202611121046.apk`
  （sha256 `5f3cb4aa6bf02ef1fff507ce4ac393a0b1a06c5f0dd7d71c8e3babe2281f99c2`，73.2 MB）。

---

## 11. 遗留

1. **云上要跑 `025_word_checkin.sql` 与 `026_subject_scope.sql`**（本机已应用 26 个迁移）；
   云函数重新部署后才有 `/data/subject/*`。
2. ~~其余七科出题未接~~ —— **11-12 已全开**：十科走同一条出题路径，题型只有选择/判断。
   仍待补的是「题型之外的形态」（填空/解答需要归一化判分、材料分析要走批改链路）。
3. 真机要亲眼过一遍：配一科 → 点色块出题 → 学生端看到那份 → 家长端「待完成」变 0。
   判据都绿不等于家长看着顺（B27）。
