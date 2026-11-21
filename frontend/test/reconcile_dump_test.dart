/// 对账脚本的**本地链路一侧**：读同一份操作序列，在真 SQLite 上执行，dump 成 JSON。
///
/// ## 为什么它是一个测试文件
///
/// 因为「在真 SQLite 上驱动 `DatabaseService`」这件事已经在这里铺好了 ——
/// `helpers/db_test_helper.dart` 用 `sqflite_common_ffi` 起真库、并把
/// path_provider 指到临时目录（否则平台通道在测试进程里会抛
/// MissingPluginException）。复用它比另起一套 Dart 脚本省事得多，也**不会**
/// 因为另起一套而让「测试里的库」和「对账里的库」变成两件事。
///
/// ## 为什么默认跳过
///
/// 它会写文件（dump 到 `RECONCILE_OUT`）。`flutter test` 全套里不该有
/// 「跑一次就往仓库里写东西」的用例，所以没设环境变量时整组跳过。
/// 专门跑（路径相对**项目根**，因为 `flutter test` 的 cwd 是项目根）：
///
///     RECONCILE_OUT=serverless/data-service/out/local-dump.json \
///       flutter test test/reconcile_dump_test.dart
///
/// 产物与 Node 侧执行器写在同一个目录（`data-service/out/`），比对器只认那一处。
///
/// ## 它只做「执行 + dump」，不做比对
///
/// 比对全在 Node 侧（`scripts/reconcile/compare.mjs`）。理由是**比对逻辑只能有一份** ——
/// 两侧各写一份 diff，会漂，而漂了的对账脚本比没有更坏（它会给出「一致」的假结论）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:easy_learn_app/controllers/point_controller.dart';
import 'package:easy_learn_app/models/daily_comment_model.dart';
import 'package:easy_learn_app/models/homework_image_model.dart';
import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/models/point_model.dart';
import 'package:easy_learn_app/models/relationship_model.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/models/study_plan_checkin_model.dart';
import 'package:easy_learn_app/models/study_plan_model.dart';
import 'package:easy_learn_app/models/wish_model.dart';
import 'package:easy_learn_app/models/workout_model.dart';
import 'package:easy_learn_app/repositories/homework_repository.dart';
import 'package:easy_learn_app/services/database_service.dart';
// 这里要直连**本地库**跑原生 SQL（造数据 / 断言存储层），
// 而上云门面 `DatabaseService` 不承诺「`.database` 就是当前数据源」——
// 云端模式下它是服务端。所以显式指名本地实现。
import 'package:easy_learn_app/services/local_database_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/db_test_helper.dart';

/// 与 Node 侧执行器读的是**同一个文件**。路径从项目根算（`flutter test` 的 cwd）。
const _scenarioPath = 'serverless/data-service/scripts/reconcile/scenario.json';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final outPath = Platform.environment['RECONCILE_OUT'];
  final skipReason = (outPath == null || outPath.isEmpty)
      ? '未设置 RECONCILE_OUT —— 对账 dump 不参与常规测试'
      : null;

  Directory? tempDir;

  setUp(() async {
    // 会灌演示种子（三个账号 + 结伴 + 若干作业）。
    // 对本文件来说种子只需要提供**账号与关系** —— 业务表下面会被清掉。
    tempDir = await setUpTestDatabase();
  });

  tearDown(() async {
    final dir = tempDir;
    if (dir != null) await tearDownTestDatabase(dir);
  });

  test('按 scenario 在真 SQLite 上跑一遍并 dump', () async {
    final scenario =
        jsonDecode(File(_scenarioPath).readAsStringSync()) as Map<String, dynamic>;
    final tables = (scenario['dump'] as List).cast<String>();
    final db = await LocalDatabaseService.instance.database;
    final out = File(outPath!);

    // 先删掉自己上一轮的产物。
    //
    // 理由不是「省空间」，是**防止旧 dump 冒充新结论**：本文件在写文件之前失败
    // （某一步的别名解析失败、某个模型字段改名）时，上一轮那份 dump 会留在原地，
    // 而比对器只认路径不认时间 —— 于是它会对着一份从未发生过的运行宣布「一致」。
    // 服务端执行器里有对称的一句。
    if (out.existsSync()) out.deleteSync();

    // ===== 起点：业务表清空，账号与关系保留 =====
    //
    // 两侧的种子**不同源**（本地走 `seedIfEmpty()`，服务端由测试直接写 SQL），
    // 所以「比对种子数据」既没有意义也不可能通过。对账的对象是
    // **同一串操作产生的行**，起点只能是「业务表为空」。
    for (final t in tables) {
      await db.delete(t);
    }

    // 别名表。`$student` 这类引用统一在这里解析 —— 序列里因此可以完全不出现
    // 真实 id，而真实 id 在两侧本来就不同（R2：ID 由服务端生成）。
    final aliases = <String, String>{
      'student': (scenario['actor'] as Map)['student'] as String,
      'parent': (scenario['actor'] as Map)['parent'] as String,
    };
    final log = <Map<String, Object?>>[];
    final service = DatabaseService.instance;

    for (final raw in scenario['steps'] as List) {
      final step = raw as Map<String, dynamic>;

      // `sides` 缺省 = 两侧都跑。声明「只有一侧能跑」的步骤必须留下痕迹
      // （进 executed 日志），否则它就退化成一次静默跳过 —— 而静默跳过
      // 正是对账最坏的失败方式：另一侧会认真地比一份少了一步的落库结果。
      final sides = (step['sides'] as List?)?.cast<String>();
      if (sides != null && !sides.contains('local')) {
        log.add({'step': step['step'], 'ok': false, 'skipped': '序列声明只在一侧执行'});
        stdout.writeln('[reconcile/local] · 跳过（序列声明只在一侧执行）：${step['step']}');
        continue;
      }

      final key = '${step['repo']}.${step['method']}';
      final args = _resolve(step['args'], aliases) as Map<String, dynamic>;
      final alias = step['as'] as String?;

      switch (key) {
        case 'homework.insertHomework':
          // 本地 id 由**调用方**生成（`StudentController` 用 microsecondsSinceEpoch），
          // 所以执行器自己造一个。服务端那一侧会从响应里取 —— 这正是对账要
          // 用别名而不是真实 id 的原因。
          final id = 'L_${alias ?? 'hw'}';
          await service.insertHomework(
            HomeworkItem(
              id: id,
              title: args['title'] as String,
              subject: args['subject'] as String,
              imageUrl: args['imageUrl'] as String? ?? '',
              dueAt: DateTime.parse(args['dueAt'] as String),
              estimatedMinutes: (args['estimatedMinutes'] as num).toDouble(),
              status: HomeworkStatus.values.byName(args['status'] as String),
              wrongCount: (args['wrongCount'] as num?)?.toInt() ?? 0,
              aiEnabled: _truthy(args['aiEnabled']),
              needsGrading: _truthy(args['needsGrading']),
              userRole: 'student',
              studentId: args['studentId'] as String,
            ),
            'student',
          );
          aliases[alias ?? id] = id;

        case 'homework.updateHomework':
          final patch = HomeworkPatch(id: args['id'] as String);
          final mask = (args['mask'] as Map?)?.cast<String, dynamic>() ?? {};
          for (final e in mask.entries) {
            switch (e.key) {
              case 'status':
                patch.status =
                    HomeworkStatus.values.byName(e.value as String);
              case 'wrongCount':
                patch.wrongCount = (e.value as num).toInt();
              case 'imageUrl':
                patch.imageUrl = e.value as String;
              case 'submittedAt':
                patch.submittedAt = DateTime.parse(e.value as String);
              case 'checkedAt':
                patch.checkedAt = DateTime.parse(e.value as String);
              case 'score':
                patch.score = (e.value as num).toInt();
              case 'summary':
                patch.summary = e.value as String;
              case 'imageCount':
                patch.imageCount = (e.value as num).toInt();
              case 'submitBatchId':
                patch.submitBatchId = e.value as String;
              case 'gradingSource':
                patch.gradingSource = e.value as String;
              case 'needsGrading':
                patch.needsGrading = _truthy(e.value);
              case 'clearResult':
                // 四个字段必须一起清，所以序列里不逐个写空值，而是点名这个动作
                // （`HomeworkPatch` 的 setter 是 `DateTime` 非空，写不出「清空」）。
                patch.clearResult();
              default:
                fail('掩码里有执行器不认识的字段：${e.key}');
            }
          }
          if (!patch.isEmpty) await service.updateHomework(patch);

        case 'homework.saveHomeworkImages':
          final items = (args['images'] as List).cast<Map<String, dynamic>>();
          final studentId = args['studentId'] as String;
          await service.saveHomeworkImages([
            for (final (i, x) in items.indexed)
              HomeworkImageModel(
                id: 'L_${alias ?? 'img'}_$i',
                studentId: studentId,
                homeworkId: x['homeworkId'] as String,
                storageKey: x['storageKey'] as String,
                fileName: x['fileName'] as String,
                fileSize: (x['fileSize'] as num).toInt(),
                mimeType: x['mimeType'] as String,
                ocrStatus: x['ocrStatus'] as String? ?? 'none',
                ocrText: x['ocrText'] as String? ?? '',
                createdAt: DateTime.parse(
                  x['createdAt'] as String? ?? '2026-09-18T12:30:00.000Z',
                ),
                batchId: x['batchId'] as String? ?? '',
                sortOrder: (x['sortOrder'] as num?)?.toInt() ?? i,
              ),
          ]);
          for (final (i, _) in items.indexed) {
            aliases['${alias ?? 'img'}_$i'] = 'L_${alias ?? 'img'}_$i';
          }

        case 'review.insertReviewMistakes':
          final items = (args['items'] as List).cast<Map<String, dynamic>>();
          final studentId = args['studentId'] as String;
          await service.insertReviewMistakes([
            for (final (i, x) in items.indexed)
              ReviewMistake(
                id: 'L_${alias ?? 'mis'}_$i',
                subject: x['subject'] as String,
                title: x['title'] as String,
                originalAnswer: x['originalAnswer'] as String? ?? '',
                wrongReason: x['wrongReason'] as String? ?? '',
                createdAt: DateTime.parse(
                  x['createdAt'] as String? ?? '2026-09-18T12:31:00.000Z',
                ),
                state: ReviewState.values.byName(x['state'] as String? ?? 'pending'),
                studentId: studentId,
                homeworkId: x['homeworkId'] as String? ?? '',
                knowledgePoint: x['knowledgePoint'] as String? ?? '',
                wrongCount: (x['wrongCount'] as num?)?.toInt() ?? 1,
                sourceHomeworkTitle: x['sourceHomeworkTitle'] as String? ?? '',
              ),
          ]);
          for (final (i, _) in items.indexed) {
            aliases['${alias ?? 'mis'}_$i'] = 'L_${alias ?? 'mis'}_$i';
          }

        case 'review.insertReviewPaperWithItems':
          final paperId = 'L_${alias ?? 'paper'}';
          final paperArgs = (args['paper'] as Map).cast<String, dynamic>();
          final itemArgs = (args['items'] as List).cast<Map<String, dynamic>>();
          await service.insertReviewPaperWithItems(
            ReviewPaper(
              id: paperId,
              studentId: args['studentId'] as String,
              title: paperArgs['title'] as String,
              subject: paperArgs['subject'] as String? ?? '',
              knowledgePoints: _splitList(paperArgs['knowledgePoints']),
              status: PaperStatus.values
                  .byName(paperArgs['status'] as String? ?? 'draft'),
              itemCount: (paperArgs['itemCount'] as num?)?.toInt() ?? 0,
              passCount: (paperArgs['passCount'] as num?)?.toInt() ?? 0,
              failCount: (paperArgs['failCount'] as num?)?.toInt() ?? 0,
              // 本地 `createdAt` 是必填且由**调用方**给；服务端由 `now()` 给（R3）。
              // 两者必然不同 —— 比对器把它列在忽略清单里，理由就在 R3。
              createdAt: DateTime.parse(
                paperArgs['createdAt'] as String? ?? '2026-09-18T12:35:00.000Z',
              ),
              filePath: paperArgs['filePath'] as String? ?? '',
              note: paperArgs['note'] as String? ?? '',
            ),
            [
              for (final (i, x) in itemArgs.indexed)
                ReviewPaperItem(
                  id: 'L_${alias ?? 'paper'}_$i',
                  paperId: paperId,
                  mistakeId: x['mistakeId'] as String? ?? '',
                  subject: x['subject'] as String? ?? '',
                  knowledgePoint: x['knowledgePoint'] as String? ?? '',
                  questionTitle: x['questionTitle'] as String? ?? '',
                  questionBody: x['questionBody'] as String? ?? '',
                  originalAnswer: x['originalAnswer'] as String? ?? '',
                  wrongReason: x['wrongReason'] as String? ?? '',
                  answerKey: x['answerKey'] as String? ?? '',
                  sortOrder: (x['sortOrder'] as num?)?.toInt() ?? i,
                  studentAnswer: x['studentAnswer'] as String? ?? '',
                  result: PaperItemResult.values
                      .byName(x['result'] as String? ?? 'pending'),
                  photoPath: x['photoPath'] as String? ?? '',
                  comment: x['comment'] as String? ?? '',
                ),
            ],
          );
          // `review_paper_item.paperId` 由执行器填（两侧都是）—— 序列里不写它，
          // 因为两侧的卷 id 本来就不同（R2），写了也只能是占位符。
          aliases[alias ?? 'paper'] = paperId;
          for (final (i, _) in itemArgs.indexed) {
            aliases['${alias ?? 'paper'}_$i'] = 'L_${alias ?? 'paper'}_$i';
          }

        case 'review.updateReviewPaper':
          // ⚠️ 本地接口是**整体覆盖**（`updateReviewPaper(ReviewPaper)`，
          // 实现是 `db.update` 写全部列），而服务端端点是**掩码**。
          // 所以执行器必须「读回来 → 套掩码 → 整体写回」——
          // 这也正是 `ReviewController` 的真实做法（它手里本来就有一个完整对象）。
          //
          // 如果这里改成「只把掩码字段拼成 map 去 update」，测的就变成
          // 「我临时发明的那个掩码」，而不是真实路径了。
          final paperId = args['id'] as String;
          final rows = await db.query(
            'review_paper',
            where: 'id = ?',
            whereArgs: [paperId],
            limit: 1,
          );
          if (rows.isEmpty) fail('review.updateReviewPaper 找不到卷子：$paperId');
          var paper = ReviewPaper.fromMap(rows.first);
          final paperMask =
              (args['mask'] as Map?)?.cast<String, dynamic>() ?? {};
          for (final e in paperMask.entries) {
            switch (e.key) {
              case 'status':
                paper = paper.copyWith(
                  status: PaperStatus.values.byName(e.value as String),
                );
              case 'itemCount':
                paper = paper.copyWith(itemCount: (e.value as num).toInt());
              case 'passCount':
                paper = paper.copyWith(passCount: (e.value as num).toInt());
              case 'failCount':
                paper = paper.copyWith(failCount: (e.value as num).toInt());
              case 'exportedAt':
                paper = paper.copyWith(
                  exportedAt: DateTime.parse(e.value as String),
                );
              case 'submittedAt':
                paper = paper.copyWith(
                  submittedAt: DateTime.parse(e.value as String),
                );
              case 'gradedAt':
                paper = paper.copyWith(
                  gradedAt: DateTime.parse(e.value as String),
                );
              case 'closedAt':
                paper = paper.copyWith(
                  closedAt: DateTime.parse(e.value as String),
                );
              case 'filePath':
                paper = paper.copyWith(filePath: e.value as String);
              case 'note':
                paper = paper.copyWith(note: e.value as String);
              default:
                fail('掩码里有执行器不认识的字段：${e.key}');
            }
          }
          await service.updateReviewPaper(paper);

        case 'review.insertReviewAttempts':
          final items = (args['items'] as List).cast<Map<String, dynamic>>();
          final studentId = args['studentId'] as String;
          await service.insertReviewAttempts([
            for (final (i, x) in items.indexed)
              ReviewAttempt(
                id: 'L_${alias ?? 'att'}_$i',
                studentId: studentId,
                mistakeId: x['mistakeId'] as String? ?? '',
                paperId: x['paperId'] as String? ?? '',
                itemId: x['itemId'] as String? ?? '',
                channel: AttemptChannel.values
                    .byName(x['channel'] as String? ?? 'paper'),
                round: (x['round'] as num?)?.toInt() ?? 1,
                answer: x['answer'] as String? ?? '',
                correct: _truthy(x['correct']),
                score: (x['score'] as num?)?.toInt() ?? 0,
                comment: x['comment'] as String? ?? '',
                createdAt: DateTime.parse(
                  x['createdAt'] as String? ?? '2026-09-18T12:50:00.000Z',
                ),
              ),
          ]);
          for (final (i, _) in items.indexed) {
            aliases['${alias ?? 'att'}_$i'] = 'L_${alias ?? 'att'}_$i';
          }

        case 'review.updateReviewMistakeState':
          // 这一侧**天然就是掩码**（命名可选参数，`null` = 本次不改），
          // 与服务端 `MISTAKE_STATE_SPEC` 同形 —— 与 `updateReviewPaper`
          // 那处的「覆盖 vs 掩码」正好相反，值得对照着看。
          await service.updateReviewMistakeState(
            args['id'] as String,
            ReviewState.values.byName(args['state'] as String),
            wrongCount: (args['wrongCount'] as num?)?.toInt(),
            lastWrongAt: args['lastWrongAt'] == null
                ? null
                : DateTime.parse(args['lastWrongAt'] as String),
            reviewRound: (args['reviewRound'] as num?)?.toInt(),
            lastReviewedAt: args['lastReviewedAt'] == null
                ? null
                : DateTime.parse(args['lastReviewedAt'] as String),
            masteredAt: args['masteredAt'] == null
                ? null
                : DateTime.parse(args['masteredAt'] as String),
            masteredBySelf: args.containsKey('masteredBySelf')
                ? _truthy(args['masteredBySelf'])
                : null,
            knowledgePoint: args['knowledgePoint'] as String?,
            wrongReason: args['wrongReason'] as String?,
          );

        case 'review.insertReviewSummary':
          // 本地 id 由调用方拼（`sum_{studentId}_{scopeKey}`，见 review_service），
          // 服务端按 `sum_{studentId}_{scope}_{scopeKey}` 拼 —— 拼法不同，
          // 于是又一次说明「对账必须用别名，而不是真实 id」。
          final summaryId = 'L_${alias ?? 'sum'}';
          await service.insertReviewSummary(
            ReviewSummary(
              id: summaryId,
              studentId: args['studentId'] as String,
              scope: SummaryScope.values
                  .byName(args['scope'] as String? ?? 'paper'),
              scopeKey: args['scopeKey'] as String,
              totalCount: (args['totalCount'] as num?)?.toInt() ?? 0,
              passCount: (args['passCount'] as num?)?.toInt() ?? 0,
              masteredCount: (args['masteredCount'] as num?)?.toInt() ?? 0,
              remainCount: (args['remainCount'] as num?)?.toInt() ?? 0,
              passRate: (args['passRate'] as num?)?.toDouble() ?? 0,
              weakPoints: _splitList(args['weakPoints']),
              body: args['body'] as String? ?? '',
              // 记录时间：本地客户端给，服务端 `now()`（R3）→ 比对器忽略。
              generatedAt: DateTime.parse(
                args['generatedAt'] as String? ?? '2026-09-18T13:10:00.000Z',
              ),
            ),
          );
          aliases[alias ?? 'sum'] = summaryId;

        // ===== 打卡 / 积分 / 心愿（第三段）=====

        case 'studyPlan.insertStudyPlan':
          final id = 'L_${alias ?? 'plan'}';
          await service.insertStudyPlan(
            StudyPlanModel(
              id: id,
              title: args['title'] as String,
              content: args['content'] as String? ?? '',
              startAt: DateTime.parse(args['startAt'] as String),
              endAt: DateTime.parse(args['endAt'] as String),
              type: args['type'] as String? ?? 'daily',
              // ⚠️ 两侧词表仍不同（见 scenario 的 vocabDiff）：本地落的是
              // `StudyPlanStatus.name`，服务端是一套 pending/active/… 的白名单
              // （`src/vocab.js`），交集只有 active 与 rejected 与 completed。
              // 场景因此只用 completed —— 这不是随手挑的值，是被词表逼出来的那一个。
              // 2026-09-20 之前交集更小：服务端那个词还叫 `accepted`。
              status: StudyPlanStatus.values.byName(args['status'] as String),
              studentId: args['studentId'] as String,
              cycleType: WorkoutCycleType.values.byName(
                args['cycleType'] as String? ?? 'daily',
              ),
              customWeekdays: _splitList(args['customWeekdays']),
              rejectReason: args['rejectReason'] as String? ?? '',
            ),
            'student',
          );
          aliases[alias ?? id] = id;

        case 'studyPlan.insertStudyPlanCheckin':
          // 重复打卡是**原地替换**（`ConflictAlgorithm.replace`，id 不变）——
          // 与服务端「`on conflict do nothing` + 回查已有行」选的是同一个行为。
          // 执行器两次都用同一个 id，所以这条一致性比得出来。
          final id = 'L_${alias ?? 'chk'}';
          await service.insertStudyPlanCheckin(
            StudyPlanCheckin(
              id: id,
              planId: args['planId'] as String,
              studentId: args['studentId'] as String,
              date: args['date'] as String,
              createdAt: DateTime.parse(args['createdAt'] as String),
            ),
          );
          aliases[alias ?? id] = id;

        case 'points.earnPoints':
          // 走 `PointController` 而不是裸 `DatabaseService` —— 它才是**真实路径**：
          // 分值裁决（家长关掉这项）、幂等结论、createdBy 的兜底都在它里面。
          // 自己拼一条 PointLedgerEntry 去 insert，测的就变成「我临时发明的入账」。
          final controller = PointController();
          final action = pointActionFromCode(args['action'] as String);
          if (action == null) {
            fail('积分动作认不出来：${args['action']}');
          }
          final signed = (args['points'] as num).toInt();
          final studentId = args['studentId'] as String;
          if (signed >= 0) {
            await controller.award(
              action: action,
              studentId: studentId,
              reason: args['reason'] as String? ?? '',
              idempotencyKey: args['idempotencyKey'] as String? ?? '',
              refType: args['refType'] as String? ?? '',
              refId: args['refId'] as String? ?? '',
              createdBy: studentId,
              pointsOverride: signed,
            );
          } else {
            // 扣分走 `spend`：它刻意不看分值表（定价由家长在兑现那一次决定）。
            // 用 `award` 送负数会被它当「0 分」拒掉，症状是「本地少了一笔扣分」。
            await controller.spend(
              action: action,
              studentId: studentId,
              points: -signed,
              reason: args['reason'] as String? ?? '',
              idempotencyKey: args['idempotencyKey'] as String? ?? '',
              refType: args['refType'] as String? ?? '',
              refId: args['refId'] as String? ?? '',
              createdBy: studentId,
            );
          }
          // 入账笔的 id：回查那条「还活着」的记录（幂等重复时拿到的是同一笔）。
          final entry = await service.findActivePointEntry(
            studentId: studentId,
            idempotencyKey: args['idempotencyKey'] as String? ?? '',
          );
          if (entry != null) aliases[alias ?? 'pt'] = entry.id;

        case 'points.revokePoints':
          final controller = PointController();
          final studentId = args['studentId'] as String;
          await controller.revoke(
            studentId: studentId,
            idempotencyKey: args['idempotencyKey'] as String,
            reason: args['reason'] as String? ?? '',
            createdBy: studentId,
          );
          // 冲正笔的 id 由 Controller 内部生成、也不返回 —— 回查一次登记别名。
          // 服务端侧是直接从响应取的（`data.reversal.id`），两侧登记**同一个**
          // 别名，比对器才配得上这两行，而不是报「两侧各多一行」。
          final reversalOf = aliases[alias ?? 'pt'] ?? '';
          final reversal = await db.query(
            'point_ledger',
            where: 'reversalOf = ?',
            whereArgs: [reversalOf],
            limit: 1,
          );
          if (reversal.isNotEmpty) {
            aliases['${alias ?? 'pt'}_reversal'] = reversal.first['id'] as String;
          }

        case 'wish.insertWish':
          final id = 'L_${alias ?? 'wish'}';
          await service.insertWish(
            WishModel(
              id: id,
              title: args['title'] as String,
              description: args['description'] as String? ?? '',
              isPublic: _truthy(args['isPublic']),
              parentConfirmed: _truthy(args['parentConfirmed']),
              studentConfirmed: _truthy(args['studentConfirmed']),
              isArchived: _truthy(args['isArchived']),
              studentId: args['studentId'] as String,
              expectedDate: _time(args['expectedDate']),
              pointCost: (args['pointCost'] as num?)?.toInt() ?? 0,
            ),
            'student',
          );
          aliases[alias ?? id] = id;

        case 'wish.updateWishRedeemState':
          // 三步（定价 / 申请 / 兑现）共用一个方法，差别只在传了哪个具名参数 ——
          // 与服务端「传什么改什么」的掩码语义同形。
          await service.updateWishRedeemState(
            id: args['id'] as String,
            pointCost: (args['pointCost'] as num?)?.toInt(),
            redeemRequestedAt: _time(args['redeemRequestedAt']),
            redeemedAt: _time(args['redeemedAt']),
            redeemRejectedAt: _time(args['redeemRejectedAt']),
            clearRedeemRequest: _truthy(args['clearRedeemRequest']),
            clearRedeemRejected: _truthy(args['clearRedeemRejected']),
          );

        case 'notification.markFirstRead':
          // 本地没有「读者」这个维度（`app_notification.isRead` 是个行级布尔，
          // 记不下谁读的），序列里已声明它只在服务端跑。真走到这里说明声明坏了。
          fail('序列声明这一步只在服务端执行，本地执行器却收到了它');

        // ===== 运动 / 点评 / 结伴（第四段）=====

        case 'workout.insertPlan':
          // ⚠️ `id` **由序列给出**，不由执行器生成 —— 这一列服务端不会生成
          // （R2 的唯一例外：id 同时是幂等键，见 `routes/workout.js` 的文件头）。
          // 两侧必须是同一个值；执行器自己造 id 反而会把「服务端原样存下客户端 id」
          // 这条一致性一起测掉 —— 别名是从**响应**登记的，响应里给什么、dump 里
          // 就是什么，把 id 换成服务端生成的也照样「一致」。
          // 所以服务端那一侧另有一条直白断言（`server-run.mjs`）。
          await service.insertWorkoutPlan(
            WorkoutPlan(
              id: args['id'] as String,
              title: args['title'] as String? ?? '',
              project: args['project'] as String? ?? '',
              weekdays: _splitList(args['weekdays']),
              targetMinutes: (args['targetMinutes'] as num?)?.toInt() ?? 0,
              isActive: _truthy(args['isActive']),
              // `startDate` / `endDate` 是**业务时间**，序列里必须写带 Z 的完整
              // 时刻：写 `2026-09-14` 会让 `DateTime.parse` 落成设备本地午夜，
              // 而服务端把它当 UTC 解释 —— 差一整天，且只在对比时才看得见。
              startDate: _time(args['startDate']),
              endDate: _time(args['endDate']),
              startTime: args['startTime'] as String? ?? '08:00',
              endTime: args['endTime'] as String? ?? '09:00',
              cycleType: WorkoutCycleTypeX.fromName(
                args['cycleType'] as String? ?? 'weekly',
              ),
              customWeekdays: _splitList(args['customWeekdays']),
              studentId: args['studentId'] as String,
            ),
          );
          aliases[alias ?? 'wp'] = args['id'] as String;

        case 'workout.setPlanActive':
          await service.updateWorkoutPlanActive(
            args['id'] as String,
            _truthy(args['isActive']),
          );

        case 'workout.insertRecord':
          // 与 `insertPlan` 同一条约定：id 由序列给、原样上行。
          await service.insertWorkoutRecord(
            WorkoutRecord(
              id: args['id'] as String,
              project: args['project'] as String? ?? '',
              start: DateTime.parse(args['startAt'] as String),
              end: DateTime.parse(args['endAt'] as String),
              minutes: (args['minutes'] as num?)?.toInt() ?? 0,
              feedback: args['feedback'] as String? ?? '',
              planId: args['planId'] as String? ?? '',
              studentId: args['studentId'] as String,
            ),
          );
          aliases[alias ?? 'wr'] = args['id'] as String;

        case 'relationship.invite':
          // 本地这边要**显式传发起人**（`senderId`），服务端那一侧从 token 取。
          // 于是序列里两样都写：`senderId` 给本地，`identity` 给服务端选票。
          // 这不是冗余 —— 它正是「身份在本地是参数、在云端是 token」的落点。
          final invited = await service.createRelationshipInvitation(
            senderId: args['senderId'] as String,
            targetPhone: args['targetPhone'] as String,
          );
          aliases[alias ?? 'rel'] = invited.id;

        case 'relationship.updateStatus':
          await service.updateRelationshipStatus(
            id: args['id'] as String,
            status: RelationshipStatus.values.byName(args['status'] as String),
          );

        case 'comment.insertDailyComment':
          // 本地 id 由调用方给（真实路径是 `dc_<millis>`，执行器换成一个确定的），
          // 服务端由 `newId()` 生成 —— 别名把它们接上。
          final commentId = 'L_${alias ?? 'dc'}';
          await service.insertDailyComment(
            DailyCommentModel(
              id: commentId,
              rating: args['rating'] as String,
              content: args['content'] as String? ?? '',
              // 记录时间：本地存的是调用方给的（真实路径是 `DateTime.now()`），
              // 服务端**根本不读**这个字段、直接 `now()`（R3）→ 比对器忽略该列。
              createdAt: DateTime.parse(
                args['createdAt'] as String? ?? '2026-09-21T02:00:00.000Z',
              ),
              studentId: args['studentId'] as String,
            ),
          );
          aliases[alias ?? 'dc'] = commentId;

        default:
          fail(
            '执行器不认识这一步：$key —— '
            '序列里加了新动作时，两侧执行器都要补，**不能只补一边**'
            '（只补一边的后果是那一步在另一侧静默不执行，对账却仍然「通过」）。',
          );
      }

      log.add({'step': step['step'], 'ok': true});
    }

    // ===== dump：列名不写死，从库里现取 =====
    //
    // 手抄列名会漏掉「某一侧多了/少了一列」——而那本身就是最该被报出来的差异之一
    // （本地 `homework` 有 `userRole`，服务端没有）。
    final dump = <String, Object?>{};
    for (final t in tables) {
      final info = await db.rawQuery('PRAGMA table_info($t)');
      dump[t] = {
        'columns': [for (final c in info) c['name'] as String],
        'rows': [
          for (final row in await db.query(t))
            {for (final e in row.entries) e.key: _norm(e.value)},
        ],
      };
    }

    final payload = {
      'side': 'local',
      'scenario': scenario['scenario'],
      'aliases': aliases,
      'executed': log,
      'tables': dump,
    };

    out.parent.createSync(recursive: true);
    out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(payload));

    // 只在没输出的时候失败，正常情况下把行数打出来给人看。
    final counts = [
      for (final t in tables)
        '$t=${((dump[t] as Map)['rows'] as List).length}',
    ].join(' / ');
    stdout.writeln('[reconcile/local] $counts → $outPath');
  }, skip: skipReason);
}

/// `$alias` 的形态。整串引用与内嵌引用都用它认。
final RegExp _aliasRef = RegExp(r'\$[A-Za-z_][A-Za-z0-9_]*');

String _lookup(String ref, Map<String, String> aliases) {
  final hit = aliases[ref.substring(1)];
  if (hit == null) {
    throw StateError(
      '序列引用了不存在的别名 `$ref` —— '
      '要么它出现在被引用步骤之后，要么那一步的执行器没有登记别名。',
    );
  }
  return hit;
}

/// 把 `$alias` 引用换成真实 id。递归处理 map / list —— 序列里两者都有。
Object? _resolve(Object? node, Map<String, String> aliases) {
  if (node is String) {
    if (!node.contains(r'$')) return node;
    // 整串引用（`$hw1`）与**内嵌引用**（`plan:$plan1:2026-09-18`）都要能解析。
    // 后者是幂等键的真实形态（`PointController.planKey`），而键里带错 id 的
    // 后果是静默的：第二天的分会被前一天的键吞掉，不报错。与 Node 侧对称。
    return node.replaceAllMapped(_aliasRef, (m) => _lookup(m.group(0)!, aliases));
  }
  if (node is Map) {
    return {
      for (final e in node.entries)
        e.key.toString(): _resolve(e.value, aliases),
    };
  }
  if (node is List) return [for (final x in node) _resolve(x, aliases)];
  return node;
}

/// 逗号分隔的字符串 → 列表。
///
/// 序列里写**字符串**（`"分数,小数"`）而不是数组，是因为那才是**线格式**：
/// 服务端 `knowledge_points` / `weak_points` 就是 TEXT，本地模型虽然存
/// `List<String>`，但 `toMap()` 会再 `join(',')` 存回去。
/// 序列贴着线格式写，对账验的才是真实路径，而不是我为对账发明的一种格式。
List<String> _splitList(Object? v) {
  if (v == null) return const [];
  if (v is List) return [for (final x in v) x.toString()];
  return [
    for (final s in v.toString().split(','))
      if (s.trim().isNotEmpty) s.trim(),
  ];
}

/// 可空时间戳：`null` 原样穿过（「本次不改这个字段」与「清空」是两件事）。
DateTime? _time(Object? v) => v == null ? null : DateTime.parse(v as String);

/// 1/0 与 true/false 都认。
///
/// 序列里写 `1/0` 是刻意的：那是 `HomeworkPatch.toMap()` 的**真实线格式**
/// （SQLite 没有布尔，本地一律写 1/0）—— 序列贴着真实线格式写，
/// 对账才是在验真实路径，而不是在验我为对账临时发明的一种格式。
bool _truthy(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v == '1' || v.toLowerCase() == 'true';
  return false;
}

/// SQLite 会给出 JSON 表达不了的类型（blob → `Uint8List`）。
/// 不转换的话 `jsonEncode` 直接抛，而报错位置离原因很远。
Object? _norm(Object? v) {
  if (v == null || v is num || v is String || v is bool) return v;
  if (v is Uint8List) return 'blob:${v.length}';
  return v.toString();
}
