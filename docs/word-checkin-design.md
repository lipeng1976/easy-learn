# 英语单词打卡 · 闭环设计

> 状态：**2026-11-11 设计定稿，同日 §11 四阶段全部落地**。七项需求由虫子拍板；
> 实现清单见 §11，验收与证伪记录见 §11.1。
> 同日追加：**出题范围口径**（当前书 / 单元模式 / 学生 id）见 §5.4，数据模型见 §3.1。
> 关联：`concept-drill-c-plan.md`（每日训练骨架）、`ima-integration-design.md`（可选能力规则）、
> `错题闭环设计.md`（毕业判定，本次刻意不接入）、`操作手册.md`（英文阅读 / 词表 MD 现状）。

---

## 0. 已拍板的决策（不再讨论）

| # | 决策 | 含义 |
|---|---|---|
| 1 | **新建教材词表 MD** | 虫子手工把教材 PDF 的单词章节整理成规范 MD，放 ima 新目录 `教学资料/Wordlist`；写一个极简解析器。现有 96 课故事书词表 `reading_lesson.vocabulary` **不动、不复用**。 |
| 2 | **导入时本地规则生成** | 不用 AI 网关出题。导入时建「干扰项池」，每日按日期种子成题。**零 AI、零配额、离线可用、答案确定**。 |
| 3 | **复用每日训练骨架** | 仿 `DrillController` / `DrillSelector` / `DailyDrillPage`：一天一组、日期种子、三态、本机 sqflite 事务。⚠️ 代价：要补「上云摘要 / 家长端页面 / 错词回流」三块。 |
| 4 | 闭环范围 | 含 **错词回流复习、家长端可见、单词发音**；**不做** ima 结果归档（未选）。 |
| 5 | **出题范围** | 家长配一次「当前书 + 单元模式」，学生每天零操作；**只从当前一本**抽词，不多本混出；单元四种模式、**默认已学区间**。不做按年级自动选书（§5.4 / §12）。 |

### ⚠️ 由决策 3 引出的一处口径调整（必须写清，不能偷偷改）

`daily_drill` 整条链路都在**客户端本地**（`lib/data/drill_bank.dart` 的 Dart 常量题库 → `DrillSelector` → `drill_answer` 本机表）。
所以决策 2 的「导入时生成」落在**客户端**：服务端导入词表后下发 JSON，客户端缓存进本地 sqflite，
在导入数据落本地时建好每个词的干扰项候选池；**每天按种子从池里抽 3 个干扰项成题**。

为什么不在导入时把整道题定死：同一词永远是同一组选项，孩子会背「C 是答案」而不是背单词。
改成「池固定、每日抽选项 + 打乱顺序」，答案依然确定、依然零 AI，且每天题目不同。

职责边界一句话：**服务端 = 词表真值 + 练习范围 + 成绩摘要；客户端 = 出题 + 判分 + 错词权重 + 发音。**

---

## 1. 目标与验收标准

**目标**：学生每天用 5～10 分钟，按教材单元进度把单词过一遍（英→中 / 中→英双向选择题），
答错的词自动加权复现，家长在计划页看得到当天完成与正确率。

**验收标准**（缺一条不算完成）：

1. 一本教材词表 MD 能从 ima 导入 → 落 PG → 下发 → 客户端本地缓存，断网后仍可打卡。
2. 每天自动出 N 道双向选择题，同一天同学生重进是同一组；不同天不同组。
3. 本机立即判分、立即出结果；不依赖网络、不依赖 AI 网关。
4. 答错的词在后续几天出现概率显著升高；连续答对 2 次后降权。
5. 家长端计划页看得到今日完成 / 正确率 / 连续天数 / 错词 Top，可查历史。
6. 点单词能发音（男声本机/直连、女声 Qwen 兜底），慢速档生效。
7. **没有 ima 的家庭：导入入口隐藏，已缓存词表照常打卡，全程不弹红条、不抛异常。**
8. 每环有判据且证伪成立（还原实现后恰好对应判据变红）。
9. 家长配一次范围后学生每天零操作；**切孩子不串书 / 不串单元**（范围按 `student_id` 隔离）。

---

## 2. 词源：教材词表 MD 格式约定

### 2.1 放置与命名

- ima 学生自己的 KB 下新建目录 `教学资料/Wordlist`（与现有 `教学资料/English` 平级，避免把故事书 MD 误当词表）。
- 文件名 `words-<教材名>.md`，例：`words-人教版七上.md`。`media_type = 7`（MarkDown）过滤。
- 一本 MD = 一本教材；`##` 分单元，单元是干扰项池的边界。

### 2.2 格式（极简，可纯手工整理）

```markdown
# 人教版七年级上册 单词表

## Unit 1 My name's Gina
hello | həˈləʊ | 你好；喂
name | neɪm | 名字；名称
nice | naɪs | 令人愉快的；宜人的
meet || 遇见；结识

## Unit 2 This is my sister
sister | ˈsɪstə(r) | 姐；妹
mother | ˈmʌðə(r) | 母亲；妈妈
```

| 规则 | 口径 |
|---|---|
| `#` 一级标题 | 书名；缺省取文件名（去 `words-` 前缀与 `.md`） |
| `##` 二级标题 | **单元名，必须**；无单元的词条归入 `默认单元` 并记 warning |
| 词条行 | 三段用半角竖线分隔：`word \| phonetic \| meaning`，各自 `trim`；音标可空 |
| 多义项 | `；` / `;` / `,` 分隔，**只取首义**作为题目答案（唯一口径，见 §5.2） |
| 忽略行 | 空行、`#` / `>` 开头、无竖线、含中文的 word |
| 坏行 | 记 `warning` 并跳过，**不整单失败**；全坏 → 拒绝导入（响亮失败，不存 0 词的书） |
| 重复词 | 同单元内 `normalizeWord` 相同 → 保留首条 + warning；跨单元允许，但选题时按 `normalizeWord` 去重 |
| 编码 | UTF-8；≤ 2MB（词表远小于 3.4MB 的故事书） |

### 2.3 教材 PDF → MD

工程**不做 PDF 抽取**。两条路：① 手工复制整理；② 把教材 PDF 放进**学生自己**的 ima KB，
用 `doc/word-checkin-ima-prompt.md` 的提示词让 ima 产出词表 MD 初稿，**人工核对后再上传**。
扫描版需先 OCR（MinerU 只在 MCP 侧可用，本工程无 OCR 代码）。
无论哪条路，最终都必须是 §2.2 那一份 UTF-8 `.md` 文件，由人放进 `教学资料/Wordlist`；
ima 输出只是初稿，解析规则以 §2.2 为唯一口径。

### 2.4 解析器

新建 `serverless/data-service/src/word_import.js`：`parseWordlist(markdown, {title})` →
`{ title, units: [{unit, entries: [{word, phonetic, meaning, primaryMeaning}]}], warnings, rawLineCount }`。

⚠️ **不复用** `reading_import.js:parseVocabulary`：那边强制「编号 + 音标方括号 + `Lesson N` 三段式」，
是针对 MinerU 故事书的另一套语义。两套解析器各管一种 MD，不许互相兜底（「一个语义只许一处定义」）。

---

## 3. 数据模型

### 3.1 服务端 PG（新迁移 `025_word_checkin.sql`，四表，RLS ENABLE + FORCE）

| 表 | 主要列 | 说明 |
|---|---|---|
| `word_book` | `id, student_id, owner_user_id, title, source_media_id, source_path, unit_count, word_count, created_at` | 一本书一行；`uq_word_book_source(student_id, source_media_id) WHERE source_media_id <> ''` 去重，重复导入 = 覆盖更新 |
| `word_entry` | `id, book_id, student_id, unit, word, phonetic, meaning, primary_meaning, normalized_word, sort_no` | 词条真值；`uq_word_entry(book_id, unit, normalized_word)`；索引 `idx_word_entry_student_unit` |
| `word_daily_result` | `student_id, date, total, correct, streak, wrong_words JSONB, synced_at`, PK `(student_id, date)` | **成绩摘要**，幂等 upsert；不含逐题明细 |
| `word_scope` | `student_id` **PK**, `book_id`, `unit_mode(current/learned/selected/all) DEFAULT 'learned'`, `current_unit`, `selected_units JSONB DEFAULT '[]'`, `daily_count INT DEFAULT 10`, `updated_at` | **练习范围真值**：一学生一行，家长可写、学生只读。导入首本书时自动建行（`book_id` = 该书、`current_unit` = 第 1 单元） |

四表统一 `student_id = ANY(app_csv_setting('app.visible_students'))`（与 `023_reading.sql` 同口径）。
`wrong_words` 只存 `[{word, count}]` Top5，用于家长端展示，不作为权重真值（权重在客户端本地）。

⚠️ **`word_scope` 是范围的唯一真值**：`book_id` 必须属于同一 `student_id` 的 `word_book`（服务端校验，越界 403）；
`unit_mode` / `current_unit` / `selected_units` 的合法值由服务端白名单校验，客户端不自行拼口径。
每日题量 `daily_count` 也放这里，避免再造一个按学生隔离的本地设置键（见 §3.2）。

> 本地为主 → 服务端**不存逐题作答、不复算判分**。理由与边界见 §7.3。

### 3.2 客户端 sqflite（DB **v32**，两表）

| 表 | 主要列 | 说明 |
|---|---|---|
| `word_entry_local` | `id, studentId, bookId, unit, word, phonetic, primaryMeaning, normalizedWord, distractorPool, importedAt` | 词表缓存；`distractorPool` 是 JSON 字符串（候选词 id 列表） |
| `word_answer` | `id, studentId, date, wordId, direction(en2zh/zh2en), optionsJson, answer, picked, correct, createdAt` | 每日作答；整组一个事务写入（仿 `drill_answer`） |

⚠️ **不建 `word_miss` 表**：错词权重从 `word_answer` 按 `wordId` 聚合派生（近 30 天），
与 `DrillSelector` 从 `drill_answer` 读历史同一思路。少一张表 = 少一处漂移。

⚠️ **练习范围不落本地 `app_setting`**：现有 `app_setting(key, value)` 是**裸 key、无 studentId 列**
（`focus.restReminderMinutes` / `reading.speechRate` 都是全机一份），多孩切孩子必然串。
范围与每日题量一律从服务端 `word_scope` 拉，本地只做只读缓存，不写设置键。

⚠️ **DB 版本三处同步**（项目硬规矩）：建表语句、`if (oldVersion < 32)` 迁移分支、`currentVersion` 常量。

---

## 4. 闭环七环

| 环 | 谁做 | 做什么 |
|---|---|---|
| 1 词源 | 虫子 | 教材 PDF → 规范 MD → 放 ima `教学资料/Wordlist` |
| 2 导入 | 服务端 | 从 ima 拉 MD → `parseWordlist` → 落 `word_book` / `word_entry`；无 ima 静默降级（§9） |
| 3 下发 | 客户端 | `GET /data/word/scope` 拉当前书与单元模式 → `GET /data/word/entries` 拉该书词表 → 落 `word_entry_local`，**建干扰项池** |
| 4 选词 | 客户端 | 按 scope 过滤单元 → 日期种子 + 掌握度加权 → 今日 N 词（默认 10），双向各半 |
| 5 成题 | 客户端 | 从池抽 3 个干扰项 + 打乱选项 → 重算答案字母；渲染层不看答案 |
| 6 判分 | 客户端 | 本机立即出分 → 整组事务写 `word_answer` → 三态切「已完成」 |
| 7 回流 | 客户端 + 服务端 | 错词权重派生、连对降权；异步 POST 成绩摘要；家长端读摘要 |

**入口**：学生端复习 tab 加 `WordDrillEntryCard`（与 `/daily-drill` 并列，路由 `/word-drill`，**只答题、不给选择**）；
家长端计划页加 `WordDailyCard`（结果摘要 + 历史入口 `/word-daily-logs`）与 `WordScopePage`（选当前书 / 单元模式 / 当前单元 / 题量）。
照抄英文阅读范式：`reading_setup_page.dart` 家长点书，`reading_page.dart` 学生端明确「不给选择，只给现在这一篇」。

---

## 5. 出题规则（本地规则生成器，零 AI）

### 5.1 干扰项池（导入进本地时建一次）

对词条 `w`：

```
candidates = 同 unit 内其它词条
             排除 normalizeWord == w.normalizeWord
             排除 primaryMeaning == w.primaryMeaning   ← 同义项会造出两个正确答案
             排除 primaryMeaning 为空
若 candidates < 3 → 扩到同书相邻 unit（按 unit 顺序，先近后远）
仍 < 3 → 标记 insufficient_distractors，该词不出题（宁可少一题，不造错题）
```

### 5.2 清洗（单点定义，放 `word_normalizer.dart`）

- `normalizeWord(word)` = `trim` → `toLowerCase` → 去首尾标点。
- `primaryMeaning(meaning)` = 按 `；|;|,|，` 切首段 → `trim` → 去词性前缀
  （`n. / v. / adj. / adv. / prep. / conj. / pron. / num. / art. / int.`，允许不带点）→ `trim`。
- 教材一词多义时**只考首义**。已知不公平点，写进 §12，不在本次解决。

### 5.3 两种方向，各半

| 方向 | 题干 | 选项 |
|---|---|---|
| `en2zh` | `「hello」的意思是？` | 正确首义 + 3 个池词的首义 |
| `zh2en` | `「你好」对应的单词是？` | 正确 word + 3 个池词的 word |

- 选项**出题时**按日期种子打乱（`Random(seed ^ wordIdHash)`），打乱后重算 `answer` 字母。
- 答案随题目一起落 `word_answer`，但**渲染层只读 stem / options**（沿用 `CheckinQuestionCard` 的纪律：
  「答题时看不到答案」靠渲染层不看，不靠网络延迟）。
- 判分口径与 `CheckinSubmitResult.judge` 同源：`trim()` + 大写 + 字符串相等，**空作答恒错**。
  只出 `choice`，不出现 `judge` / 填空 / 解答（本地确定性比对会把 `0.5` 与 `1/2` 判错，项目踩过）。

### 5.4 练习范围与选词权重（11-11 定稿）

#### 5.4.1 范围由家长配一次，学生零操作

| 项 | 口径 |
|---|---|
| 谁定 | 家长在 `WordScopePage` 选**一本当前书** + 单元模式 + 当前单元 + 每日题量，写 `PUT /data/word/scope`；学生端只读 `GET /data/word/scope` |
| 几本书 | 一个学生**可导入多本**（七上 / 七下 / 课外词表），但**一次出题只从当前一本**抽词，不多本混合 —— 干扰项池边界清楚、单元顺序有意义 |
| 按年级自动选 | **不做**。`app_user.grade` / `term` 是自由文本且口径不统一（个人页只到六年级，错题筛选含初高中）；全仓无教材版本 / 册次 / 书目映射；同年级有人教 / 外研 / 译林，年级推不出书。ima 词表本就按学生分库，书天然属于学生，不需要靠年级选学生 |
| 学生 id | 全线用 `ParentController.selectedStudentId`，**不用** `CheckinController.targetStudentId()`（后者取 `boundStudents.first`，与 ima 的 `selectedStudentId` 口径不一致；多孩家庭会拿 A 的词表给 B 打卡） |

#### 5.4.2 四种单元模式

| 模式 | 取词单元 | 场景 |
|---|---|---|
| `current` | 仅 `currentUnit` | 跟课堂同步 |
| **`learned`（默认）** | 第 1 单元 → `currentUnit` 的**已学区间** | 累计复习 + 错词回流，最常用 |
| `selected` | `selectedUnits` 里家长多选的单元 | 查漏补缺 |
| `all` | 整本全部单元 | 考前总复习 |

- `currentUnit` **由家长显式设定**，导入首本书时默认第 1 个单元。
  ⚠️ 旧稿「由最近一次打卡的最大 unit 推导」是错的：打卡不推进单元，会永远停在 Unit 1。
  不做「完成 N 天自动 +1」这类自动跳单元（§12）。
- 单元顺序取 MD 里 `##` 的出现顺序（落 `word_entry.unit_order` / `sort_no`），**不按标题文本排序**。
- `selected` 模式照抄 `review_tab.dart:321-370` 的多选弹层 + `RxSet<String>`；其余模式用 `Wrap + ChoiceChip`
  （`checkin_setup_page.dart` 范式）。工程没有通用多选组件，**不要为此新建通用 widget**。
- 干扰项池仍按 §5.1「同单元优先、相邻单元兜底」，且**只在当前书内**，不跨书。

#### 5.4.3 范围变更何时生效

> **已开始的那组题当天不重算**：已经选过答案（进行中）或已交卷的一组题，家长改范围也不换题、
> 不清已选 —— 避免「改一半的答案落到另一套完全不同的题上」。
> 当天**还没作答**时，题本来就没落盘、不存在「今天的卷」，下一次进答题页就按新范围重出。
>
> ⚠️ 2026-11-12 修正：旧稿写的是「次日生效（当天即使未完成也不重新选题）」，与实现不符 ——
> 未作答的组每次进页面都是新生成，改完范围当天就变。UI 文案因此改为
> 「今天还没作答的话，回到学生端就是新范围；今天已答过的不变」，
> **不要再写「次日生效」**：家长第二天会发现昨天说的和实际不一样，比不提示更糟。
>
> 种子**不带 `bookId`**：同一天、同一范围下重进拿到的是同一组题（换书当天题目自然不同）。
> 选题时把 `bookId / unitMode / currentUnit` 快照随 `word_answer` 当日组一起记，
> 「已完成」回放时可显示「当时用的是哪本书 / 哪个模式」。

#### 5.4.4 选词与权重（仿 `DrillSelector`）

```
seed(studentId, dateKey) → FNV hash of "studentId|YYYY-MM-DD"
weight(w) = 1.0
          × (1 + 0.6 × min(wrongCount30d, 5))        错词 boost
          × (consecutiveCorrect >= 2 ? 0.25 : 1.0)    已掌握降权
          × (近 3 天出过 ? 0.2 : 1.0)                 新鲜度
          × (从未做过 ? 1.5 : 1.0)                    新词优先
```

- 候选集 = **当前书 ∩ scope 允许的单元 ∩ 干扰项池足够（≥3）**；不够时页面显示「今日可练 N 题」，不伪造题。
- 抽样用 Efraimidis–Spirakis `key = u^(1/w)`（复用 `DrillSelector._sampleTier` 思路，不复制代码）。
- 今日 N 词读 `word_scope.daily_count`（默认 10，可选 5/10/15），`en2zh : zh2en ≈ 1:1`。
- 同一天同学生同种子 → 同一组；切学生 / 换天 → 不同组。

---

## 6. 判分、三态与错词回流

- 三态仿 `DrillController`：**未开始**（选新题）/ **进行中**（同种子重选，不清空已作答）/ **已完成**（从 `word_answer` 还原当天题与作答）。
- `submit()`：逐题判 → 整组事务 `insertWordAnswers`（先按 `studentId + date` 删再整组插）→ `_refreshStreak` 连续天数。
- **错词回流**：不写 `review_mistake`。错题本有 `review_attempt` 毕业判定，往里塞单词选择题会污染
  「组卷批改 / mastered」语义（§错题闭环设计.md:3）。只在 `word_answer` 里留痕，权重由查询派生。
- 权重查询：`queryWordWeights(studentId, since: now-30d)` → `{wordId → {wrongCount, consecutiveCorrect, lastSeenDate}}`。

---

## 7. 家长可见与同步语义（决策 3 的代价，口径必须明确）

### 7.1 服务端端点（最少 7 个）

| 端点 | 用途 |
|---|---|
| `GET /data/word/books` | 列 ima `教学资料/Wordlist` 里可选 MD；无 ima → 2xx `{connected:false, books:[], reason:'ima_unavailable'}` |
| `POST /data/word/import` | 拉 MD → 解析 → 落 `word_book` / `word_entry`；首次导入自动建 `word_scope` 行 |
| `GET /data/word/entries?bookId=` | 下发该书词表（含 `primaryMeaning` / `unitOrder`）；`bookId` 必须属于该 `studentId` |
| `GET /data/word/scope?studentId=` | 读当前范围（学生 / 家长都可读） |
| `PUT /data/word/scope` | 家长写范围：`requireParent` + `requireVisibleStudent`；校验 `book_id` 归属、模式白名单、单元名存在 |
| `POST /data/word/daily` | 客户端提交当日摘要，`on conflict (student_id, date) do update` 幂等 |
| `GET /data/word/daily?studentId=&from=&to=` | 家长端 / 历史查询 |

写端点用 `requireVisibleStudent` 拦越界（403）；`PUT /data/word/scope` 另加 `requireParent`（学生不能改自己的进度）。
只读端点带 `studentId`，且取 `ParentController.selectedStudentId`，**不用 `targetStudentId()`**（§5.4.1）。
`app.js` 的 `narrowToVisible` 会先对 `query.studentId` 做统一校验，handler 里的兜底只是第二道防线。

### 7.2 同步语义：**本地为主，云上是摘要**

```
submit() 本地写完 → 立刻显示结果（已完成）→ 异步 POST 摘要
失败 → 置 pendingSync 标记，下次进页面重试；绝不回退「已完成」，绝不弹红条
```

- `day` 用 `date` 类型，查询输出一律 `l.day::text as day`（项目踩过 DATE 偏移一天）。
- 家长 `boundStudents` 晚到 → `ever` 重试（阅读记录同款坑）。
- 快速切筛选用 generation 代号丢掉迟到响应（阅读记录 / ima 状态同款坑）。

### 7.3 边界（明说，不藏）

- 服务端**不复算判分**：题目在客户端由同一份词表确定性生成，服务端没有题目快照，也不承担防作弊。
  自家孩子打卡，不做防篡改；若以后要「服务端真值」，得把题目快照也上云，那是另一个量级。
- **多设备不合并**：换手机 / 两端都打卡，云上摘要以最后一次同步为准。要合并需同步逐题 `word_answer`，本次不做。
- **离线期间家长看不到**当天结果，恢复网络后自动补上。

---

## 8. 单词发音

新建 `lib/services/word_tts.dart`，**不动** `ServerTts` 的课文朗读链路（全局单例 + 分块 + 60s 超时 + 全文 digest 对单词全是负担）：

- `WordTts.speak(word)`：复用 `EdgeTtsClient.synthesize` + `TtsAudioCache`，缓存键加前缀
  `'word\n${TtsVoices.cacheSchema}\n$word'`，**与课文全文 digest 不互串**（音色版本进键，11-08 踩过）。
- 音色：本机/直连 `en-US-GuyNeural` 男声，Qwen 兜底 `Cherry` 女声；来源徽标复用 `SpeechSourceBadge`。
- 语速复用 `SpeechRateSettings`（播放层 `setSpeed` 0.8×，音高不变、缓存与语速无关）。
- Qwen 兜底结果**不落盘**（否则女声会被误当本地男声命中，11-08 踩过）。
- 设备不支持 / 断网且无缓存 → 喇叭图标置灰 + 灰字提示，**不抛异常**（可选能力规矩）。

---

## 9. 可选能力降级（硬规矩，不可协商）

> 「不是所有人都有 ima；没有时功能可以缺、不可错」——不弹红条、不抛异常、不拖垮主流程。

| 场景 | 表现 |
|---|---|
| 未配置 ima / 凭证失效 / `025` 未迁移 / 目录不存在 | `GET /data/word/books` 回 2xx `connected:false`；客户端**隐藏导入入口**，不写页面级 `error` |
| 用户主动点导入但 ima 不可用 | 温和 `badRequest` + snackbar，不抛红 |
| 词表为空 / 全坏行 | 拒绝导入并说明原因（**响亮失败**，不存 0 词的书）——这是与「可选降级」相反的唯一例外 |
| 已缓存词表、ima 后来断了 | 打卡、发音、错词复习**全部照常**，只是不能导入新书 |
| 无 TTS 能力 | 喇叭置灰，打卡不受影响 |

客户端沿用 `ReadingController.imaBooksAvailable` 模式：单独一个 `wordImportAvailable` 开关，失败只写灰字 hint。

---

## 10. 判据清单（每条要能证伪）

| # | 判据 | 证伪方式 |
|---|---|---|
| 1 | MD 解析：单元数、词条数、首义、空音标、坏行 warning、全坏拒绝 | 还原旧 `VOCAB_ENTRY` 正则 → 解析判据红 |
| 2 | 干扰项：同单元、≠正确词、释义不相同、恰好 3 个；池不足扩单元；仍不足不出题 | 去掉「排除同义项」→ 出现双正确答案的判据红 |
| 3 | 双向题各半；打乱后答案字母与选项一致；渲染层拿不到答案 | 固定选项顺序 → 「每天题目不同」判据红 |
| 4 | 日期种子：同日同学生同组、换天不同组、切学生不同组 | 种子去掉 studentId → 切学生判据红 |
| 5 | 判分：字母 trim 大写、空作答恒错、只认 `choice` | 放宽空作答 → 判据红 |
| 6 | 错词权重：答错 boost、连对 2 次降权、近 3 天降新鲜度；**不写 `review_mistake`** | 权重不读 `word_answer` → 判据红 |
| 7 | 断网可打卡；摘要失败留 `pendingSync` 不回退已完成；恢复后幂等补传 | 摘要失败抛错 → 判据红 |
| 8 | 家长端今日/正确率/连续/错词 Top + 历史按天分组；`day::text` 不偏一天 | 去掉 `::text` → 日期判据红 |
| 9 | 单词缓存与课文缓存不互串；慢速档生效；Qwen 不落盘 | 缓存键去掉 `word` 前缀 → 判据红 |
| 10 | **无 ima 不报错**：入口隐藏、无红条、已缓存词表照常打卡 | 还原「失败写页面级 error」→ 判据红 |
| 11 | 新测试进各自 runner（服务端 `run-tests.mjs` 显式清单 / Flutter 自动发现） | `runner-list.test.js` 盯完整性 |
| 12 | 范围按 `student_id` 隔离：切孩子不串书 / 单元 / 题量 | `word_scope` 去掉 `student_id` 或用裸 `app_setting` key → 判据红 |
| 13 | 四种单元模式过滤正确；`learned` 只取第 1→`currentUnit`；`currentUnit` 不被打卡改写 | 还原「打卡最大 unit 推导」→ 判据红 |
| 14 | 只从当前一本抽词；越界 `bookId` 403；跨书词不进干扰项池 | 去掉 `book_id` 过滤 → 判据红 |
| 15 | 范围变更**不打断当天进度**：已作答 / 已交卷的那组不重算、已选不清；未作答则按新范围重出 | 去掉「进行中直接返回」→ `word_drill_controller_test` 那条变红 |
| 16 | 学生 id 取 `selectedStudentId`：`boundStudents.first` 与所选孩子不同时不串库 | 换成 `targetStudentId()` → 判据红 |

> ⚠️ 纪律：先确认红的是断言不是编译；还原实现后**恰好**对应判据变红、反面仍绿；
> 样本别太少（项目踩过「3 次样本称 87.5%」）。

---

## 11. 落地清单（四阶段已完成）

| 阶段 | 文件 | 验收 |
|---|---|---|
| 1 词源与导入 | `sql/025_word_checkin.sql`（四表含 `word_scope`）、`src/word_import.js`、`src/routes/word.js`、`app.js` 注册、`WordScopePage` 里的「从 ima 导入」区、`test/word-import.test.js`、`test/word-scope.test.js` | 真 MD 样本导入；首次导入建 scope；无 ima 降级判据 |
| 2 范围与本地出题 | `WordScopePage` + `GET/PUT /data/word/scope`、`local_database_service.dart` v32、`word_normalizer.dart`、`word_question_generator.dart`、`word_selector.dart`、`word_drill_controller.dart`、`word_drill_page.dart`、`WordDrillEntryCard`、`app.dart` 路由 | 四种模式过滤正确、切孩子不串、断网可打卡 |
| 3 同步与家长可见 | `/data/word/daily` GET/POST、`word_daily_card.dart`、`word_daily_logs_page.dart`、家长计划页接线 | 家长端看得到；`day::text`；晚到重试 |
| 4 发音与收尾 | `word_tts.dart`、无 ima 判据、全量回归 + 逐条证伪、重出本机 APK | `analyze` 0 error、两套全量测试绿、新 APK |

**每阶段收尾**：`flutter analyze` 无 error + 全量测试绿 + DB 版本三处同步 + 新测试进 runner。
实现时**只动上表文件**，不顺手改 `reading_import.js` / `checkin.js` / `ServerTts`。

### 11.1 验收记录（2026-11-12 00:15）

**判据**

| 项 | 结果 |
|---|---|
| 服务端全量 `npm test` | **434 / 434 通过**（原 433 + 大小写判据 1） |
| Flutter 全量 `flutter test` | **1405 通过 / 2 跳过 / 0 失败** |
| `flutter analyze` | **0 error / 0 warning**（仅 2 条既有 info：`test/data_api_retry_test.dart` 的 `prefer_initializing_formals`，与本次无关） |
| 真库 `025` | 四表存在，`relrowsecurity` + `relforcerowsecurity` 均 true |
| 端到端冒烟 `probe:word-e2e` | **10 / 10**（真 HTTP + 真库，自带清理，残留 0） |
| 本机服务 | `:8788` / `:8787` / FRP `13390`·`13391` 全部恢复探活；新端点 401（已加载）、不存在路径 404 |

**逐条证伪（客户端 8 组，全部命中）**

| 变异 | 变红的判据 |
|---|---|
| 日期种子丢 `studentId` | 日期种子：同学生同日同组、换天不同组、切学生不同组 |
| 干扰项不排除同义项 | 干扰项池：同单元、排除同词与同义项、只在同一本书内 |
| 单词缓存键去 `word` 前缀 | 缓存键带 word 前缀，与课文全文 digest 不互串 |
| 摘要失败不写 `pendingSync` | 摘要失败：留 pendingSync，不回退已完成；恢复后幂等补传 |
| `learned` 放行整本 | 四种单元模式：learned 只取 1→当前单元；只从当前一本 |
| 喇叭置灰失效 | 源码契约：喇叭置灰 + 页级一条灰字提示 |
| 选项顺序固定 | 池固定但每日抽选项：同一个词跨天选项顺序不能一模一样 |
| 家长卡读失败冒泡 | 源码契约：摘要读失败不得冒泡成页面红条 |

服务端 9 组（导入/覆盖保留 `book.id`/全坏拒绝/无 ima 降级/`025` 未迁移/越界 403/四种模式/`day::text`/幂等 upsert/日期窗）同样逐条还原验证，恢复后 0 红。

**真实词表实测（这条只有真数据能暴露）**

用真 ima 凭证 + 真库跑 `npm run probe:word-ima`，发现虫子建的目录是
`教学资料/wordlist`（**小写 w**），而代码找 `Wordlist` —— `includes` 区分大小写，
结果是「目录明明在、导入区说没有」。已改为**忽略大小写**匹配（`findFolderByPath`，
阅读书库同一条路径也一起受益），并补判据（去掉 `toLowerCase` 恰好那一条变红）。

修复后实测：`words-英语_七年级上册_人教版.md`（10,374 字节）→
**10 个单元 / 274 条词条 / 0 条警告**，首单元 `Starter Unit 1 Hello!` 10 词，
末单元 `Unit 7 Happy Birthday!` 39 词。

**产物**：`D:\easy_learn_home\dist\easy-learn-local-8.138.227.136-202611111541.apk`
（73.5 MB，sha256 `eff6d940b53372b19baad9d7fbc63db25ddd70d82b8ba0d6f44511a135b36fb2`，
包名 `cn.easylearn.app.local`，与云版共存）。

**还没做**：① 云上跑 `025_word_checkin.sql`；② 真机点一次「从 ima 导入」走 UI 全链路
（服务端解析与落库已由探针证明，缺的只是手指点下去那一下）。

### 11.2 热修（2026-11-12 10:30）：PUT 被发成 POST

真机点「保存范围」→「保存没成功」。数据服务日志：`POST /data/word/scope 405`（连点 6 次）。

根因在 `DataApiClient._send`：`method == 'GET' ? get : post` —— **PUT 也走 post**。
`method` 在此之前只用于「重试几次 / 换不换地址」，从没参与发请求，所以 `putJson()`
自诞生起在网线上一直是 POST，而客户端代码看着完全正确。

> 为什么原有判据全绿：服务端探针自己拼的 PUT（对的），客户端单测用假 client 只断返回值
> （不关心动词）。**两边都没错，错在接缝。**

修：`_send` 用 `switch` 分派 GET / POST / PUT，动词白名单校验移到循环外
（写错动词是编码错误，不该被 `catch` 转成「连不上数据服务」）。
判据 `test/data_api_verb_test.dart`：MockClient 记 `request.method` —— 旧实现下红（405），
修完转绿；另两条盯「POST 没被改坏」「405 必须抛错而不是当成功」。

同时修正 §5.4.3 的「次日生效」口径（见该节 ⚠️）：题不落盘，未作答时改范围当天就生效。

| 项 | 结果 |
|---|---|
| Flutter `flutter test` | **1409 通过 / 2 跳过**（原 1405 + 动词 3 + 改范围 1） |
| `flutter analyze` | 0 error（仅 2 条既有 info） |
| `probe:word-e2e` | 10 / 10（PUT 分支正常） |
| 产物 | `easy-learn-local-8.138.227.136-202611121017.apk`（73.0 MB，sha256 `57567aa8…`） |

---

## 12. 已知边界 / 未定项

- **不做按年级自动选书**：`grade` / `term` 是自由文本且口径不统一，无教材版本 / 册次 / 书目映射（§5.4.1）。
- **不做多本混合抽词**：一次只从当前一本；换书由家长显式改 scope，**当天未作答即生效、已作答的不变**（§5.4.3）。
- `currentUnit` 由家长手改；不做「完成 N 天自动跳下一个单元」。
- 学生 id 全线 `selectedStudentId`；现有阅读 / 打卡用 `boundStudents.first`，两处口径不一致属**既有隐患**，本次不改它们，但单词链路不跟随。
- 一词多义只考首义（教材常见，可能不公平）；后续可加义项标签，本次不做。
- 单元词数 < 4 时该词不出题，词表稀疏会让当日题量不足 → 页面要显示「今日可练 N 题」而非伪造题。
- 本地出题、服务端不复算 → 不防篡改；多设备摘要不合并（§7.3）。
- 教材 PDF 若为扫描版，MD 需先 OCR；本工程不做 PDF 抽取。
- 词形还原（`vocabulary_highlight.dart`）是**正文高亮**用的，与打卡选词无关，不复用。
- 不做 ima 结果归档（未选）；若以后要，沿用 `syncStudentArchive` 的可选降级语义。

> 云上部署需跑 `025` 迁移；本机 `D:\easy_learn_home` 改服务端代码后杀 dev-server 让 watchdog 拉起。
