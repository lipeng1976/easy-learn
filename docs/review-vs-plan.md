# 复习与计划：两条线，两个来源

> 2026-11-12 定稿。改这两个页面之前先读完本文 —— 它们看起来都像「做题」，
> 但一头是**查漏**，一头是**日常推进**，混在一起就会出现「界面完全正常、
> 数据悄无声息地错」的那类故障。

## 0. 一句话

- **复习 = 从错题出发的深加工**：错题重做 + 由错题引出的举一反三，
  题型不受限，可以打印出来做完再回传批改。**它是错题的消费端。**
- **计划 = 从教材/家长范围出发的碎片练习**：只出选择、判断，一分钟量级。
  **它是错题的生产端** —— 做错的题回流到错题本。

```
作业批改 ─┐
拍照/手录 ─┼→ 错题本 review_mistake ─→ 复习：重做 / 举一反三 / 组卷打印 / 回传批改
每日打卡 ─┘         ↑
                    └── 计划：教材章节 / 家长范围 → AI 出题（只出选择·判断）
                              → 交卷即判分 → 做错的题回流错题本
```

## 1. 对照表

| | **复习**（学生端「复习」tab） | **计划**（学生端「计划」tab·家长端「今天练什么」） |
|---|---|---|
| 内容来源 | **错题本**（`review_mistake`） | **教材章节**（`subject_book` / `subject_unit`）或**家长指定**（`subject_scope.points`、发起页临时勾选） |
| 出题方式 | 错题原题重做；举一反三由模型据此出变式 | 模型现场生成（服务端 `/data/checkin/generate`） |
| 题型 | 选择 / 填空 / 判断 / 解答，**四型都有** | **只有选择 / 判断** |
| 判分 | 选择判断本地判；填空解答走批改链路（文字或拍照回传） | 交卷时本机即时判分，不等网络 |
| 节奏 | 一个错题走完闭环：待复习 → 复习中 → 待批改 → 已掌握 | 碎片时间，一次 3 / 5 / 8 题 |
| 出口 | **打印 / 另存 PDF → 孩子做完 → 回传 → 批改** | 屏幕上直接做，交卷即出分 |
| 与错题本的关系 | **输入**（从那里来） | **输出**（做错的题写回去） |
| 写入的表 | `review_paper` / `review_attempt` / `explain_record` / `ai_practice_question` | `checkin_quiz` / `checkin_result` / `review_mistake`（只写错题） |

两边的「做完没有」口径也不一样：

- 复习按**错题状态**分段（`pending → reviewing → verifying → mastered`），
  tab 上的数字就是那一堆卡片的数量。
- 计划按**成绩行在不在**判断（`checkin_result` 有这行 = 已交卷），不读 `status` 字段。

## 2. 为什么必须分开（三个真实事故）

1. **历史永远出不了题（2026-11-12）**
   计划原来在没有范围时静默回落到「同科错题」。历史还没学过 ⇒ 不可能有错题 ⇒
   每点一次报一次「错题本还是空的」，而家长明明配好了教材。**教材看起来配好了、
   实际从没生效过** —— 因为取点函数把「没写考点」当成了「没有内容」。
2. **语文拿「阅读」当知识点（同轮修复）**
   语文目录是 `阅读 → 1 春 → 2 济南的冬天`。标题兜底上线后，第一节标题「阅读」
   被当成知识点，模型会出「阅读方法」这类通识题 —— 题本身通顺、界面看不出跑偏。
   现在板块名（阅读/写作/综合性学习/名著导读…）会被跳过。
3. **填空不能进计划（题型边界）**
   计划是「本机立刻判分」，而填空的 `0.5` 和 `1/2` 是同一个答案。字符串比对会把
   做对的孩子判错，且没有任何解释。所以计划只出选择/判断；要开填空，必须先把
   归一化判分做出来。

## 3. 不变量（改代码前逐条确认）

1. **计划不从错题本取内容**。错题本只有两个用处：给家长挑候选（选完就算「家长指定」）、
   给已选中的知识点补 `wrongCount / wrongReason`（模型据此调难度）。
2. **计划只出 `choice` / `judge`**。白名单在网关 schema 与 `normalizeQuestions` 两处，
   客户端判分只认这两种。
3. **交卷必须把错题写回错题本**（`submitCheckin` 的 `recordCheckinMistakes`）：
   - 幂等：写前按 `source_ref = quizId` 删掉这份卷上一次产出的错题；
   - 失败隔离：整段包在 savepoint 里，**写失败不能拖垮成绩保存**，
     但返回值要带 `mistakes.failed`，界面如实说「错题没记上」。
4. **复习不写 `checkin_*`，计划不写 `review_paper`**。两条线的数据不要互相借用。
5. **id 只有服务端说了算**：这是全局规矩（R2），两条线都一样。

## 4. 代码位置

| 关注点 | 位置 |
|---|---|
| 计划出题（服务端） | `serverless/data-service/src/routes/checkin.js` → `generateCheckin` |
| 计划取范围 | 同文件 `scopePointsOf`（家长范围）、`routes/textbook.js` → `resolveTextbookPoints`（教材） |
| 计划交卷 + 错题回流 | 同文件 `submitCheckin` / `recordCheckinMistakes` |
| 错题回流需要的列 | `sql/028_mistake_source_ref.sql`（`source_ref`） |
| 复习状态机 | `lib/controllers/review_controller.dart`、`lib/services/review_service.dart` |
| 复习组卷 / 导出 | `lib/services/review_paper_pdf.dart`、`lib/services/review_exporter.dart`、`lib/pages/student/widgets/review_export_sheet.dart` |
| 计划入口（学生） | `lib/pages/student/tabs/plan_tab.dart` + `lib/widgets/daily_practice_block.dart` |
| 计划入口（家长） | `lib/widgets/subject_board.dart` + `lib/controllers/subject_board_controller.dart` |
| 错题来源标签 | `lib/models/review_model.dart` → `MistakeSource`（`checkin`「每日打卡」/ `imaExam`「试卷导入」） |
| 来源 wire 名 | 同文件 `mistakeSourceWire()`：`imaExam` ↔ `ima_exam` 的唯一换算点，读、写都走它 |
| 家长复习页四区 | `lib/pages/parent/tabs/review_parent_tab.dart`（①导入 ②本周结论 ③学科色块 ④资料与记录） |
| 学科错题汇总口径 | `lib/models/subject_mistake_summary.dart`（归一 / 待复习 / 自评单列 / 排序） |
| 学科色块 | `lib/widgets/subject_mistake_board.dart`（前 4 主位 + 其余小色块） |
| 学科错题详情 | `lib/pages/parent/review_subject_page.dart`（只读、按错次降序） |
| 资料与记录页 | `lib/pages/parent/review_records_page.dart` + `lib/widgets/review_components.dart` |
| 错题卡（两页共用） | `lib/widgets/mistake_card.dart` |

### 4.1 家长复习页为什么按学科色块收口（11-15）

真库实测：109 条错题里数学 88 条（待复习 87、已掌握 1），英语 10、语文 9、历史 2。
平铺成一张长清单时数学占 80%，其它三科被压到页面很下面 —— 家长看不出「现在该管
哪一科」，也滚不到页面顶部的导入入口。

四区顺序按家长的动作走：**能做的一件事 → 本周结论 → 按学科看 → 查历史**。
色块与「计划」标签共用 `subjectColor()` 配色和科目名文字，但**语义刻意不同**：

- 排序：复习页按待复习数降序（先看最该管的科）；计划页固定白名单顺序。
- 点击：复习页只做查看；计划页是出题 / 去配置。
- 显示范围：复习页只列**有错题**的科；`subject` 为空或白名单外归「其他」灰块
  （不吞题，详情页仍显示原始科目名），零错题科不占位。

口径与护栏：待复习 = `state.inPool`（与 `visiblePoolMistakes` 同源）；已掌握含自评但
**单独计数**（掌握率仍排除自评）；自评警告默认露出、不折叠；复习页不出现任何改状态
按钮，明细只在学科详情页。

## 5. 判据

| 判据 | 盯什么 |
|---|---|
| `test/checkin_mistake_handoff_test.dart` | 服务端说的「几道题进了错题本」被客户端如实带出；老服务端缺字段不报错；来源标签不冒充作业批改 |
| `test/checkin_answer_test.dart` | 交卷后界面上真能看到「做错的 N 题已进错题本」 |
| `serverless/.../test/checkin-store.test.js` | 错题行带来源/题干/答案；全对不写；写失败不影响成绩；写前按 `source_ref` 清旧行 |
| `serverless/.../test/checkin-generate.test.js` | 计划的范围只来自家长配置；学生自发起读范围页；一条范围都没有时明确报错 |
| `test/review_*.dart` | 复习的组卷、作答、导出、毕业判定 |
| `test/mistake_source_wire_test.dart` | `ima_exam` ↔ `imaExam` 双向；上行必须发 `ima_exam`（源码级盯住，防止改回 `name` 造成重导翻倍） |
| `test/subject_mistake_summary_test.dart` | 学科归一 / 待复习 / 自评单列 / 排序 / `examCount` 只数 ima 导入 |
| `test/subject_mistake_board_test.dart` | 色块位置、零错题不占位、点击回调的是这一科 |
| `test/review_subject_page_test.dart` | 详情页不串科、分段、排序、只读、试卷导入行显隐 |
| `test/review_parent_tab_redesign_test.dart` | 四区顺序、色块在首屏、明细不再平铺 |
| `test/subject_mistake_summary_test.dart` | 科目归一 / 待复习口径 / 自评单列 / 排序（含「其他」垫底） |
| `test/subject_mistake_board_test.dart` | 前 4 主位与其余小色块 / 零错题不占位 / 点击传对科目 |
| `test/review_subject_page_test.dart` | 只显示这一科 / 待复习与已掌握分段 / 错次降序 / 只读 |
| `test/review_parent_tab_redesign_test.dart` | 色块在首屏 / 明细不平铺 / 自评警告默认露出 / 记录收两行 |

## 6. 遗留（有意没动的）

- 计划页大方块里的 **「今日概念训练」** 仍是本地固定题库（71 题，只练
  「文字描述 → 数学式子」，`/daily-drill`）。它既不是教材也不是家长指定，
  严格说落在两条线之外；没删是因为它是当前唯一不依赖网络的练习。
  要不要并入「数学教材范围」，等产品决定。
- 计划目前只支持选择/判断。填空、解答想开，先做归一化判分（见 §2.3）。
