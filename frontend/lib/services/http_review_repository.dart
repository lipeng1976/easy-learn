import 'dart:convert';

import '../models/practice_figure.dart';
import '../models/review_model.dart';
import '../repositories/review_repository.dart';
import 'data_api_client.dart';
import 'data_row_values.dart';
import 'judgement_ab.dart';

/// 复习闭环的**服务端实现**（`ReviewRepository` 的第二个实现）。
///
/// 本地那份在 `local_database_service.dart`。两者实现同一契约，所以
/// `ReviewController` 一行都不用改 —— 这正是当初抽 L2 接口的目的。
///
/// ## 四处「照搬本地写法就会错」的地方
///
/// **① 归属来自 token，不在 body 里声明。** 本地实现里 `studentId` 是行的一列，
/// 写什么就是什么。服务端从 token 推导可见集合，写端点 body 里的 `studentId`
/// 只是「在这个集合里挑一个」（见 `app.js` 的 `narrowToVisible`），越界直接 403。
/// 所以这里不自己判断权限，但**不能省略**这个字段 —— `insertExplain` /
/// `upsertSummary` / `createPaper` 等端点靠它定位可见学生，缺了会 400。
///
/// **② id 由服务端生成（R2）。** 所有 `insert*` 与 `createPaper` 的契约都返回
/// `void`，而服务端会忽略客户端送的 id 并自己生成一个。插入之后调用方手里的
/// id 已经作废；需要 id 的路径一律走列表端点重新查询。本地实现没有这个问题。
///
/// **③ 时间上行要 UTC、下行要本地。** 服务端 `rowToApi` 一律回带 `Z` 的 UTC；
/// 模型自带的 `fromMap` 用 `DateTime.tryParse` 解析、**不 `.toLocal()`**，
/// 若直接调 `fromMap`，云端界面上每个时间都会差一个时区（东八区差 8 小时）。
/// 所以这里不调 `fromMap`，而是像 `http_homework_repository` 那样写一组 `_fromRow`，
/// 时间统一走 `timeOf` / `timeOr`，上行走 `utcTimeText`。这是本实现与「模型已有
/// fromMap」这件事的唯一偏离，已在报告里如实说明。
///
/// **④ 删一道错题 = 一次删 5 张表，必须走单端点。** 服务端 `deleteMistake`
/// 在一个事务里级联 `review_attempt` / `judgement_ab` / `ai_practice_question` /
/// `explain_record`。客户端**绝不能**编排 5 次调用 —— 中途失败会留下孤儿行，
/// 让毕业判定与一致率悄悄偏掉。同理 `deleteReviewMistakesByHomeworkId` 在服务端
/// 也是级联（这点和本地「只读 `review_mistake`」是**有意的行为变化**，见
/// `routes/review.js` 的 `deleteMistakesByHomework`）。
class HttpReviewRepository implements ReviewRepository {
  HttpReviewRepository(this._api);

  final DataApiClient _api;

  // ===== 错题池 =====

  /// 错题列表（按场景合成一条：不传 homeworkId 时取全部）。
  ///
  /// 本地有 `queryReviewMistakes` 与 `queryReviewMistakesByHomeworkId` 两个方法，
  /// 差别只是 where 一个条件；服务端合成一条、用 `homeworkId` 查询参数下推，
  /// 范围永远由 token 决定（见 `listMistakes` 注释）。
  @override
  Future<List<ReviewMistake>> queryReviewMistakes() async {
    final items = await _api.getItems('/data/review/mistakes');
    return items.map(_fromMistake).toList();
  }

  @override
  Future<List<ReviewMistake>> queryReviewMistakesByHomeworkId(
    String homeworkId,
  ) async {
    final items = await _api.getItems(
      '/data/review/mistakes',
      query: {'homeworkId': homeworkId},
    );
    return items.map(_fromMistake).toList();
  }

  /// 写一道错题。**返回值是空的，服务端生成的新 id 拿不回来**（见类注释 ②）。
  @override
  Future<void> insertReviewMistake(ReviewMistake mistake) =>
      insertReviewMistakes([mistake]);

  @override
  Future<void> insertReviewMistakes(List<ReviewMistake> mistakes) async {
    // 空列表时直接跳过：服务端 `batchOf` 对空 `items` 会回 400。插入零行本就是
    // 无操作，跳过与发送语义等价，不必为它去撞一次错误。
    if (mistakes.isEmpty) return;
    await _api.postJson('/data/review/mistakes/insert', body: {
      // `studentId` 只用于在可见集合里挑一个（见类注释 ①），缺失会 400。
      'studentId': mistakes.first.studentId,
      'items': mistakes.map(_mistakeRow).toList(),
    });
  }

  /// 新增错题 + 图片：**一次请求**。
  ///
  /// 服务端在处理这条路由时已经处在一个事务里（`withRequestContext` 开了
  /// begin/commit），所以「写题 + 写图」在服务端是原子的。拆成两次请求就会
  /// 留下「题在、图没了」的半条记录，而界面看起来完全正常。
  @override
  Future<void> insertReviewMistakeWithImages(
    ReviewMistake mistake,
    List<ReviewMistakeImage> images,
  ) async {
    await _api.postJson('/data/review/mistakes/insert', body: {
      'studentId': mistake.studentId,
      'items': [
        {
          ..._mistakeRow(mistake),
          'images': images
              .map(
                (image) => {
                  'storageKey': image.storageKey,
                  'mimeType': image.mimeType,
                  'fileSize': image.fileSize,
                  'sortOrder': image.sortOrder,
                },
              )
              .toList(),
        },
      ],
    });
  }

  // ===== 错题图片 =====

  @override
  Future<List<ReviewMistakeImage>> queryMistakeImages(String mistakeId) async {
    if (mistakeId.isEmpty) return <ReviewMistakeImage>[];
    final items = await _api.getItems(
      '/data/review/mistake-images',
      query: {'mistakeId': mistakeId},
    );
    return items.map(_fromMistakeImage).toList();
  }

  @override
  Future<void> insertMistakeImages(List<ReviewMistakeImage> images) async {
    if (images.isEmpty) return;
    await _api.postJson('/data/review/mistake-images/insert', body: {
      'studentId': images.first.studentId,
      'items': images
          .map(
            (image) => {
              'mistakeId': image.mistakeId,
              'storageKey': image.storageKey,
              'mimeType': image.mimeType,
              'fileSize': image.fileSize,
              'sortOrder': image.sortOrder,
            },
          )
          .toList(),
    });
  }

  @override
  Future<void> deleteMistakeImage(String id) async {
    if (id.isEmpty) return;
    await _api.postJson('/data/review/mistake-images/delete', body: {'id': id});
  }

  /// 整体覆盖一条错题（`overwrite` 端点，写全部 spec 字段）。
  ///
  /// 掩码更新走 [updateReviewMistakeState]，两者刻意不是一个端点：
  /// 合成一个会得到「传了什么覆盖什么、没传就清空」，而那是静默的数据损坏。
  @override
  Future<void> updateReviewMistake(ReviewMistake mistake) async {
    await _api.postJson('/data/review/mistakes/overwrite', body: {
      'id': mistake.id,
      ..._mistakeRow(mistake),
    });
  }

  /// 删一道错题 + 全部从属数据（单端点原子级联，见类注释 ④）。
  ///
  /// ⚠️ **不**在这里编排 5 次删除调用。客户端若自己拆，中途失败留下的孤儿行
  /// 不报错，只是让统计数字慢慢偏掉。
  @override
  Future<void> deleteReviewMistake(String id) async {
    await _api.postJson('/data/review/mistakes/delete', body: {'id': id});
  }

  /// 清掉某次作业带出的全部错题。
  ///
  /// 服务端按 `homeworkId` 先捞出该题下所有错题 id、再对每张从属表做级联删除 ——
  /// 这和本地「只读 `review_mistake`」是**有意的行为变化**（一致率分母口径不同），
  /// 不是漏写。云端实现跟随服务端语义。
  @override
  Future<void> deleteReviewMistakesByHomeworkId(String homeworkId) async {
    await _api.postJson('/data/review/mistakes/delete-by-homework', body: {
      'homeworkId': homeworkId,
    });
  }

  /// 状态与随行字段的部分更新。
  ///
  /// 掩码规则与服务端 `MISTAKE_STATE_SPEC` 一致：**键出现即写，值为 null 即写成
  /// NULL**。但 Dart 侧的可选参数用 `null` 表示「本次不改」（契约陷阱 ②），
  /// 所以这里**省略值为 null 的键** —— 绝不把 `null` 送上去当「清空」，
  /// 否则「清空某字段」会在网络边界上被静默抹掉。当前客户端只会省略键、从不送
  /// null，行为与本地 `if (x != null)` 完全等价；等 S4 补 `ReviewMistakeStatePatch`，
  /// 「撤销毕业」才有真正的「写 NULL」表达方式。
  @override
  Future<void> updateReviewMistakeState(
    String id,
    ReviewState state, {
    int? wrongCount,
    DateTime? lastWrongAt,
    int? reviewRound,
    DateTime? lastReviewedAt,
    DateTime? masteredAt,
    bool? masteredBySelf,
    String? knowledgePoint,
    String? wrongReason,
  }) async {
    final mask = <String, dynamic>{
      'state': state.name,
      'wrongCount': ?wrongCount,
      if (lastWrongAt != null) 'lastWrongAt': utcTimeText(lastWrongAt),
      'reviewRound': ?reviewRound,
      if (lastReviewedAt != null) 'lastReviewedAt': utcTimeText(lastReviewedAt),
      if (masteredAt != null) 'masteredAt': utcTimeText(masteredAt),
      'masteredBySelf': ?masteredBySelf,
      'knowledgePoint': ?knowledgePoint,
      'wrongReason': ?wrongReason,
    };
    await _api.postJson('/data/review/mistakes/state', body: {
      'id': id,
      ...mask,
    });
  }

  // ===== 组卷 =====

  @override
  Future<List<ReviewPaper>> queryReviewPapers() async {
    final items = await _api.getItems('/data/review/papers');
    return items.map(_fromPaper).toList();
  }

  /// 取卷内题目（快照）。`paperId` 下推成服务端过滤（缺失会 400）。
  @override
  Future<List<ReviewPaperItem>> queryReviewPaperItems(String paperId) async {
    final items = await _api.getItems(
      '/data/review/paper-items',
      query: {'paperId': paperId},
    );
    return items.map(_fromPaperItem).toList();
  }

  /// 建卷（无题目）。返回空，新 id 由服务端生成（见类注释 ②）。
  @override
  Future<void> insertReviewPaper(ReviewPaper paper) async {
    await _api.postJson('/data/review/papers/create', body: {
      'studentId': paper.studentId,
      'paper': _paperRow(paper),
      'items': const [],
    });
  }

  /// 建卷并写题目 —— **一次原子写入**（卷 + 题目在同一个端点里）。
  ///
  /// 拆成两次调用会得到一份点开就空的卷子，而它的状态是 `draft`，从任何界面看
  /// 都正常。题目里的 `id` / `paperId` 由服务端生成、广播，所以这里不送。
  @override
  Future<SavedPaper> insertReviewPaperWithItems(
    ReviewPaper paper,
    List<ReviewPaperItem> items,
  ) async {
    final data = await _api.postJson('/data/review/papers/create', body: {
      'studentId': paper.studentId,
      'paper': _paperRow(paper),
      'items': items.map(_paperItemRow).toList(),
    });

    // ⚠️ 必须采纳服务端返回的那一行：卷 id 是服务端重新生成的 UUID，
    // 客户端传的 `rp_...` 只是占位。继续用占位 id 的后果是「刚生成的资料
    // 点进去说没有题目、过一会儿又好了」—— 详见 `SavedPaper` 的注释。
    final savedPaper = data['paper'];
    final savedItems = data['items'];
    if (savedPaper is! Map || savedItems is! List) {
      // 服务端没按契约返回时**硬失败**，不要静默退回占位 id ——
      // 那样会把「id 对不上」伪装成正常，症状跟现在这个 bug 一模一样。
      throw StateError('建卷接口没有返回 paper/items，无法采纳服务端 id');
    }
    return SavedPaper(
      paper: _fromPaper(Map<String, dynamic>.from(savedPaper)),
      items: savedItems
          .whereType<Map>()
          .map((row) => _fromPaperItem(Map<String, dynamic>.from(row)))
          .toList(),
    );
  }

  /// 整体覆盖一份卷子（写全部 spec 字段）。
  @override
  Future<void> updateReviewPaper(ReviewPaper paper) async {
    await _api.postJson('/data/review/papers/update', body: {
      'id': paper.id,
      ..._paperRow(paper),
    });
  }

  /// 改一道卷内题目（批改时逐题写回）。这张表没有学生列，可见性顺父卷判。
  @override
  Future<void> updateReviewPaperItem(ReviewPaperItem item) async {
    await _api.postJson('/data/review/paper-items/update', body: {
      'id': item.id,
      ..._paperItemRow(item),
    });
  }

  // ===== 作答记录 =====

  /// 作答记录。不传 `mistakeId` 时返回全部（周期报告要按时间窗口聚合）。
  @override
  Future<List<ReviewAttempt>> queryReviewAttempts({String? mistakeId}) async {
    final items = await _api.getItems(
      '/data/review/attempts',
      query: mistakeId == null ? null : {'mistakeId': mistakeId},
    );
    return items.map(_fromAttempt).toList();
  }

  @override
  Future<void> insertReviewAttempt(ReviewAttempt attempt) =>
      insertReviewAttempts([attempt]);

  @override
  Future<void> insertReviewAttempts(List<ReviewAttempt> attempts) async {
    if (attempts.isEmpty) return;
    await _api.postJson('/data/review/attempts/insert', body: {
      'studentId': attempts.first.studentId,
      'items': attempts.map(_attemptRow).toList(),
    });
  }

  // ===== AI 练习 =====

  @override
  Future<List<AiPracticeQuestion>> queryPracticeQuestions({
    String? sourceMistakeId,
  }) async {
    final items = await _api.getItems(
      '/data/review/practice',
      query: sourceMistakeId == null
          ? null
          : {'sourceMistakeId': sourceMistakeId},
    );
    return items.map(_fromPractice).toList();
  }

  /// 用一批新题**替换**某道错题的练习题（语义是替换不是追加）。
  ///
  /// ⚠️ `questions` 为空时**跳过请求**：服务端 `replacePractice` 需要 `studentId`
  /// 定位可见集合，而契约没有单独传 `studentId`、空列表又取不到；跳过等价于
  /// 「本次没有要替换的题」，避免一次必然的 400（实际调用方总会带题进来）。
  /// 若将来要支持「清空全部练习题」，应在契约上加 `studentId` 入参。
  @override
  Future<void> replacePracticeQuestions(
    String sourceMistakeId,
    List<AiPracticeQuestion> questions,
  ) async {
    if (questions.isEmpty) return;
    await _api.postJson('/data/review/practice/replace', body: {
      'sourceMistakeId': sourceMistakeId,
      'studentId': questions.first.studentId,
      'questions': questions.map(_practiceRow).toList(),
    });
  }

  @override
  Future<void> updatePracticeQuestion(AiPracticeQuestion question) async {
    await _api.postJson('/data/review/practice/update', body: {
      'id': question.id,
      ..._practiceRow(question),
    });
  }

  // ===== 讲解 =====

  /// 讲解记录。不传 `mistakeId` 时返回全部。
  @override
  Future<List<ExplainRecord>> queryExplainRecords({String? mistakeId}) async {
    final items = await _api.getItems(
      '/data/review/explains',
      query: mistakeId == null ? null : {'mistakeId': mistakeId},
    );
    return items.map(_fromExplain).toList();
  }

  /// 写讲解记录。讲解不构成毕业，服务端只留痕、不碰 `review_mistake`。
  ///
  /// `studentId` 必填（端点用 `requireVisibleStudent` 定位），缺失会 400。
  @override
  Future<void> insertExplainRecord(ExplainRecord record) async {
    await _api.postJson('/data/review/explains/insert', body: {
      'studentId': record.studentId,
      ..._explainRow(record),
    });
  }

  // ===== 周期报告 =====

  @override
  Future<List<ReviewSummary>> queryReviewSummaries() async {
    final items = await _api.getItems('/data/review/summaries');
    return items.map(_fromSummary).toList();
  }

  /// 写入周期报告，按 `(studentId, scope, scopeKey)` 覆盖（服务端 `UNIQUE` +
  /// `ON CONFLICT DO UPDATE` 保证同一周期只留最新一份）。`studentId` 必填。
  @override
  Future<void> insertReviewSummary(ReviewSummary summary) async {
    await _api.postJson('/data/review/summaries/upsert', body: {
      'studentId': summary.studentId,
      ..._summaryRow(summary),
    });
  }

  // ===== 判定影子比对（A/B）=====

  /// 影子比对记录。按 `studentId` 查时服务端会 **inner join `review_mistake`**
  /// 过滤孤儿行（与本地「直接按 studentId 过滤」口径不同，一致率分母更准）；
  /// 按 `mistakeId` 查时不加这个条件（需要看「错题刚删、记录未清」的中间态）。
  /// 两种口径并存是有意的。读不懂的结论行（verdict 未知）直接丢弃，与
  /// `JudgementABRecord.fromMap` 的约定一致 —— 不把脏数据伪装进分母。
  @override
  Future<List<JudgementABRecord>> queryJudgementAB({
    String? studentId,
    String? mistakeId,
  }) async {
    final query = <String, Object?>{};
    if (studentId != null) query['studentId'] = studentId;
    if (mistakeId != null) query['mistakeId'] = mistakeId;
    final items = await _api.getItems('/data/review/judgement-ab', query: query);
    return items.map(_fromJudgement).whereType<JudgementABRecord>().toList();
  }

  /// 批量写影子比对记录（只观察、不改判定）。`studentId` 必填。
  @override
  Future<void> insertJudgementABRecords(List<JudgementABRecord> records) async {
    if (records.isEmpty) return;
    await _api.postJson('/data/review/judgement-ab/insert', body: {
      'studentId': records.first.studentId,
      'items': records.map(_judgementRow).toList(),
    });
  }

  // ===== 上行：模型 → 协议字段（只送 spec 字段，避免触发服务端的未知字段处理）=====

  Map<String, dynamic> _mistakeRow(ReviewMistake m) => {
    'subject': m.subject,
    'title': m.title,
    'questionBody': m.questionBody,
    'answerKey': m.answerKey,
    // 必须走 wire 名：`imaExam` 上行要写成 `ima_exam`，否则服务端按
    // `source_type='ima_exam'` 做的导入幂等会认不出这一行（见 mistakeSourceWire）。
    'sourceType': mistakeSourceWire(m.sourceType),
    'grade': m.grade,
    'term': m.term,
    'imageCount': m.imageCount,
    'originalAnswer': m.originalAnswer,
    'wrongReason': m.wrongReason,
    'state': m.state.name,
    'homeworkId': m.homeworkId,
    'knowledgePoint': m.knowledgePoint,
    'wrongCount': m.wrongCount,
    // 时间上行必须 UTC（带 Z），否则服务端 `toTs` 直接 400（见 `coerce.js`）。
    'lastWrongAt': utcTimeText(m.lastWrongAt),
    'sourceHomeworkTitle': m.sourceHomeworkTitle,
    'masteredAt': utcTimeText(m.masteredAt),
    // 布尔原样发 `true/false`：服务端 `toBool` 两种都认。
    'masteredBySelf': m.masteredBySelf,
    'reviewRound': m.reviewRound,
    'lastReviewedAt': utcTimeText(m.lastReviewedAt),
    // 故意不送 `id` / `studentId` / `createdAt`：前两者服务端生成（R2），
    // `createdAt` 是记录时间由库 `now()` 给（R3），送了也被忽略。
  };

  Map<String, dynamic> _paperRow(ReviewPaper p) => {
    'title': p.title,
    'subject': p.subject,
    // `knowledgePoints` 在服务端是逗号串（`PAPER_SPEC` 用 `text`），双向都要 join。
    'knowledgePoints': p.knowledgePoints.join(','),
    'status': p.status.name,
    'itemCount': p.itemCount,
    'passCount': p.passCount,
    'failCount': p.failCount,
    'exportedAt': utcTimeText(p.exportedAt),
    'submittedAt': utcTimeText(p.submittedAt),
    'gradedAt': utcTimeText(p.gradedAt),
    'closedAt': utcTimeText(p.closedAt),
    'filePath': p.filePath,
    'note': p.note,
  };

  Map<String, dynamic> _paperItemRow(ReviewPaperItem i) => {
    'mistakeId': i.mistakeId,
    'subject': i.subject,
    'knowledgePoint': i.knowledgePoint,
    'questionTitle': i.questionTitle,
    'questionBody': i.questionBody,
    'originalAnswer': i.originalAnswer,
    'wrongReason': i.wrongReason,
    'answerKey': i.answerKey,
    'sortOrder': i.sortOrder,
    'studentAnswer': i.studentAnswer,
    'result': i.result.name,
    'photoPath': i.photoPath,
    'comment': i.comment,
    'checkedAt': utcTimeText(i.checkedAt),
    // 不送 `id`（逐行生成）/`paperId`（服务端按卷广播）/`studentId`
    // （这张表没有学生列，且带上会与卷子的 studentId 做一致性校验、易 400）。
  };

  Map<String, dynamic> _attemptRow(ReviewAttempt a) => {
    'mistakeId': a.mistakeId,
    'paperId': a.paperId,
    'itemId': a.itemId,
    'channel': a.channel.name,
    'round': a.round,
    'answer': a.answer,
    'correct': a.correct,
    'score': a.score,
    'comment': a.comment,
  };

  Map<String, dynamic> _practiceRow(AiPracticeQuestion q) => {
    'sourceMistakeId': q.sourceMistakeId,
    'knowledgePoint': q.knowledgePoint,
    'subject': q.subject,
    'title': q.title,
    'content': q.content,
    'answer': q.answer,
    'difficulty': q.difficulty,
    'studentAnswer': q.studentAnswer,
    'state': q.state.name,
    'round': q.round,
    'checkedAt': utcTimeText(q.checkedAt),
    // 选项按 JSON 文本上车：服务端列是 `text`，而 `RowDescription` 里
    // 嵌套数组会被序列化成奇怪的东西（百炼那条链踩过）。字符串最稳。
    'questionType': q.questionType.name,
    'optionsJson': jsonEncode(q.options),
    // 配图同样按 JSON 文本上车。没有图就发 null —— 服务端把 NULL 当
    // 「这道题不需要图」，而 `'{}'` 会被解析成一张缺点的空图。
    'figureJson': q.figure == null
        ? null
        : jsonEncode(AiPracticeQuestion.figureToJson(q.figure!)),
  };

  Map<String, dynamic> _explainRow(ExplainRecord r) => {
    'mistakeId': r.mistakeId,
    'knowledgePoint': r.knowledgePoint,
    'channel': r.channel.name,
    'summary': r.summary,
    'staySeconds': r.staySeconds,
  };

  Map<String, dynamic> _summaryRow(ReviewSummary s) => {
    'scope': s.scope.name,
    'scopeKey': s.scopeKey,
    'totalCount': s.totalCount,
    'passCount': s.passCount,
    'masteredCount': s.masteredCount,
    'remainCount': s.remainCount,
    'passRate': s.passRate,
    'weakPoints': s.weakPoints.join(','),
    'body': s.body,
  };

  Map<String, dynamic> _judgementRow(JudgementABRecord j) => {
    'mistakeId': j.mistakeId,
    'channel': j.channel.name,
    'subject': j.subject,
    'knowledgePoint': j.knowledgePoint,
    'modelVerdict': j.modelVerdict.name,
    'ruleVerdict': j.ruleVerdict.name,
  };

  // ===== 下行：服务端行 → 模型（时间统一 toLocal，见类注释 ③）=====

  ReviewMistake _fromMistake(Map<String, dynamic> row) => ReviewMistake(
    id: textOf(row['id']),
    subject: textOf(row['subject']),
    title: textOf(row['title']),
    questionBody: textOf(row['questionBody']),
    questionNo: textOf(row['questionNo']),
    studentProcess: textOf(row['studentProcess']),
    answerKey: textOf(row['answerKey']),
    sourceType: mistakeSourceOf(
      textOf(row['sourceType']),
      homeworkId: textOf(row['homeworkId']),
    ),
    grade: textOf(row['grade']),
    term: textOf(row['term']),
    imageCount: intOf(row['imageCount']),
    originalAnswer: textOf(row['originalAnswer']),
    wrongReason: textOf(row['wrongReason']),
    createdAt: timeOr(row['createdAt'], DateTime.now()),
    state: ReviewState.values.firstWhere(
      (e) => e.name == row['state'],
      orElse: () => ReviewState.pending,
    ),
    studentId: textOf(row['studentId']),
    homeworkId: textOf(row['homeworkId']),
    knowledgePoint: textOf(row['knowledgePoint']),
    wrongCount: intOf(row['wrongCount'], fallback: 1),
    lastWrongAt: timeOf(row['lastWrongAt']),
    sourceHomeworkTitle: textOf(row['sourceHomeworkTitle']),
    masteredAt: timeOf(row['masteredAt']),
    masteredBySelf: boolOf(row['masteredBySelf']),
    reviewRound: intOf(row['reviewRound']),
    lastReviewedAt: timeOf(row['lastReviewedAt']),
  );

  ReviewMistakeImage _fromMistakeImage(Map<String, dynamic> row) =>
      ReviewMistakeImage(
        id: textOf(row['id']),
        studentId: textOf(row['studentId']),
        mistakeId: textOf(row['mistakeId']),
        storageKey: textOf(row['storageKey']),
        mimeType: textOf(row['mimeType']),
        fileSize: intOf(row['fileSize']),
        sortOrder: intOf(row['sortOrder']),
        createdAt: timeOf(row['createdAt']),
      );

  ReviewPaper _fromPaper(Map<String, dynamic> row) => ReviewPaper(
    id: textOf(row['id']),
    studentId: textOf(row['studentId']),
    title: textOf(row['title']),
    subject: textOf(row['subject']),
    knowledgePoints: textOf(row['knowledgePoints'])
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(),
    status: PaperStatus.values.firstWhere(
      (e) => e.name == row['status'],
      orElse: () => PaperStatus.draft,
    ),
    itemCount: intOf(row['itemCount']),
    passCount: intOf(row['passCount']),
    failCount: intOf(row['failCount']),
    createdAt: timeOr(row['createdAt'], DateTime.now()),
    exportedAt: timeOf(row['exportedAt']),
    submittedAt: timeOf(row['submittedAt']),
    gradedAt: timeOf(row['gradedAt']),
    closedAt: timeOf(row['closedAt']),
    filePath: textOf(row['filePath']),
    note: textOf(row['note']),
  );

  ReviewPaperItem _fromPaperItem(Map<String, dynamic> row) => ReviewPaperItem(
    id: textOf(row['id']),
    paperId: textOf(row['paperId']),
    mistakeId: textOf(row['mistakeId']),
    subject: textOf(row['subject']),
    knowledgePoint: textOf(row['knowledgePoint']),
    questionTitle: textOf(row['questionTitle']),
    questionBody: textOf(row['questionBody']),
    originalAnswer: textOf(row['originalAnswer']),
    wrongReason: textOf(row['wrongReason']),
    answerKey: textOf(row['answerKey']),
    sortOrder: intOf(row['sortOrder']),
    studentAnswer: textOf(row['studentAnswer']),
    result: PaperItemResult.values.firstWhere(
      (e) => e.name == row['result'],
      orElse: () => PaperItemResult.pending,
    ),
    photoPath: textOf(row['photoPath']),
    comment: textOf(row['comment']),
    checkedAt: timeOf(row['checkedAt']),
  );

  ReviewAttempt _fromAttempt(Map<String, dynamic> row) => ReviewAttempt(
    id: textOf(row['id']),
    studentId: textOf(row['studentId']),
    mistakeId: textOf(row['mistakeId']),
    paperId: textOf(row['paperId']),
    itemId: textOf(row['itemId']),
    channel: AttemptChannel.values.firstWhere(
      (e) => e.name == row['channel'],
      orElse: () => AttemptChannel.paper,
    ),
    round: intOf(row['round']),
    answer: textOf(row['answer']),
    correct: boolOf(row['correct']),
    score: intOf(row['score']),
    comment: textOf(row['comment']),
    createdAt: timeOr(row['createdAt'], DateTime.now()),
  );

  AiPracticeQuestion _fromPractice(Map<String, dynamic> row) => AiPracticeQuestion(
    id: textOf(row['id']),
    studentId: textOf(row['studentId']),
    sourceMistakeId: textOf(row['sourceMistakeId']),
    knowledgePoint: textOf(row['knowledgePoint']),
    subject: textOf(row['subject']),
    title: textOf(row['title']),
    content: textOf(row['content']),
    answer: textOf(row['answer']),
    difficulty: textOf(row['difficulty'], fallback: '基础'),
    studentAnswer: textOf(row['studentAnswer']),
    state: PracticeState.values.firstWhere(
      (e) => e.name == row['state'],
      orElse: () => PracticeState.pending,
    ),
    round: intOf(row['round'], fallback: 1),
    createdAt: timeOr(row['createdAt'], DateTime.now()),
    checkedAt: timeOf(row['checkedAt']),
    questionType: PracticeQuestionType.parse(textOf(row['questionType'])),
    options: _parseOptions(textOf(row['optionsJson'])),
    figure: _parseFigure(textOf(row['figureJson'])),
  );

  /// 解开服务端回来的配图 JSON。
  ///
  /// 解不开就返回 null（当作没有图），**不抛异常**：一条坏掉的 figure
  /// 不该让整个复习页打不开。宁可少一张图，也不能让错题本白屏。
  PracticeFigure? _parseFigure(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      return PracticeFigure.parse(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  /// 解开服务端回来的选项 JSON。
  ///
  /// 坏掉的 JSON 返回空列表，不抛异常：一条选项读不出来不该让整页复习打不开。
  /// 「选择题没有选项」由界面按 `isUsableOptions` 拦下（转成不可作答并明说），
  /// 而不是在这里猜四个选项出来。
  List<String> _parseOptions(String raw) {
    if (raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.whereType<String>().toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  ExplainRecord _fromExplain(Map<String, dynamic> row) => ExplainRecord(
    id: textOf(row['id']),
    studentId: textOf(row['studentId']),
    mistakeId: textOf(row['mistakeId']),
    knowledgePoint: textOf(row['knowledgePoint']),
    channel: ExplainChannel.values.firstWhere(
      (e) => e.name == row['channel'],
      orElse: () => ExplainChannel.ai,
    ),
    summary: textOf(row['summary']),
    staySeconds: intOf(row['staySeconds']),
    createdAt: timeOr(row['createdAt'], DateTime.now()),
  );

  ReviewSummary _fromSummary(Map<String, dynamic> row) => ReviewSummary(
    id: textOf(row['id']),
    studentId: textOf(row['studentId']),
    scope: SummaryScope.values.firstWhere(
      (e) => e.name == row['scope'],
      orElse: () => SummaryScope.paper,
    ),
    scopeKey: textOf(row['scopeKey']),
    totalCount: intOf(row['totalCount']),
    passCount: intOf(row['passCount']),
    masteredCount: intOf(row['masteredCount']),
    remainCount: intOf(row['remainCount']),
    passRate: doubleOf(row['passRate']),
    weakPoints: textOf(row['weakPoints'])
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(),
    body: textOf(row['body']),
    generatedAt: timeOr(row['generatedAt'], DateTime.now()),
  );

  /// 读不懂的结论行返回 `null`，由调用方过滤掉（见 `queryJudgementAB`）。
  ///
  /// 不把未知 verdict 默认成 `inconclusive`：那会把它悄悄混进「弃权」档，
  /// 变成一个数据损坏问题伪装成的统计口径 —— 而分母脏了就再也查不出来。
  JudgementABRecord? _fromJudgement(Map<String, dynamic> row) {
    final modelVerdict = JudgementABRecord.parseVerdict(row['modelVerdict']);
    final ruleVerdict = JudgementABRecord.parseVerdict(row['ruleVerdict']);
    if (modelVerdict == null || ruleVerdict == null) return null;
    return JudgementABRecord(
      id: textOf(row['id']),
      studentId: textOf(row['studentId']),
      mistakeId: textOf(row['mistakeId']),
      channel: AttemptChannel.values.firstWhere(
        (e) => e.name == row['channel'],
        orElse: () => AttemptChannel.paper,
      ),
      subject: textOf(row['subject']),
      knowledgePoint: textOf(row['knowledgePoint']),
      modelVerdict: modelVerdict,
      ruleVerdict: ruleVerdict,
      createdAt: timeOr(row['createdAt'], DateTime.now()),
    );
  }
}
