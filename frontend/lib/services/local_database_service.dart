import 'dart:async';
import 'dart:convert';

// ⚠️ 这个文件是**本地实现**（SQLite / Web 内存 + localStorage），不是唯一入口。
// 上云之后，调用方走的是 `database_service.dart` 里的 `DatabaseService` 门面，
// 由它决定这一次读走本地还是走服务端（见那个文件的长注释）。
// 名字改成 `LocalDatabaseService` 就是为了让「谁在实现、谁在分发」一眼分得开。

import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/homework_model.dart';
import '../models/homework_image_model.dart';
import '../models/chat_message_model.dart';
import '../models/daily_comment_model.dart';
import '../models/drill_question.dart';
import '../models/focus_session_model.dart';
import '../models/knowledge_tip.dart';
import '../models/notification_model.dart';
import '../models/point_model.dart';
import '../models/review_model.dart';
import '../models/relationship_model.dart';
import '../models/study_plan_model.dart';
import '../models/study_plan_checkin_model.dart';
import '../models/user_profile_model.dart';
import '../models/wish_model.dart';
import '../models/word_checkin.dart';
import '../models/workout_model.dart';
import '../repositories/drill_repository.dart';
import '../repositories/focus_repository.dart';
import '../repositories/homework_repository.dart';
import '../repositories/notification_repository.dart';
import '../repositories/point_repository.dart';
import '../repositories/relationship_repository.dart';
import '../repositories/review_repository.dart';
import '../repositories/study_plan_repository.dart';
import '../repositories/user_repository.dart';
import '../repositories/wish_repository.dart';
import '../repositories/workout_repository.dart';
import 'auth_data_source.dart';
import 'demo_seed.dart';
import 'judgement_ab.dart';
import 'web_storage.dart';

class LocalDatabaseService
    implements
        AuthDataSource,
        HomeworkRepository,
        NotificationRepository,
        PointRepository,
        RelationshipRepository,
        ReviewRepository,
        StudyPlanRepository,
        UserRepository,
        WishRepository,
        WorkoutRepository,
        FocusRepository,
        DrillRepository {
  LocalDatabaseService._();
  static final LocalDatabaseService instance = LocalDatabaseService._();

  static Database? _database;
  static final Map<String, List<Map<String, dynamic>>> _webStore = {};

  /// 仅供测试：关闭当前连接并清空内存缓存。
  ///
  /// 数据库句柄是进程级静态字段，测试之间若不清理，后一个用例会看到
  /// 前一个用例写入的数据，「数据隔离」这类断言就会变得不可靠。
  @visibleForTesting
  static Future<void> resetForTesting() async {
    try {
      await _database?.close();
    } catch (_) {}
    _database = null;
    _webStore.clear();
  }

  Future<Database> get database async {
    if (kIsWeb) {
      throw UnsupportedError(
        'Web runtime uses in-memory data storage; SQLite is not available in browser builds.',
      );
    }

    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final path = join(documentsDirectory.path, 'easy_learn_v2.db');

    return openDatabase(
      path,
      version: 33,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE app_user (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        phone TEXT UNIQUE,
        role TEXT NOT NULL,
        avatar TEXT NOT NULL,
        password TEXT,
        wechatOpenId TEXT UNIQUE,
        gender TEXT DEFAULT '',
        grade TEXT DEFAULT '',
        term TEXT DEFAULT '',
        hobbies TEXT DEFAULT '',
        bio TEXT DEFAULT '',
        passwordUpdatedAt TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE homework (
        id TEXT PRIMARY KEY,
        title TEXT,
        subject TEXT,
        imageUrl TEXT,
        dueAt TEXT,
        estimatedMinutes REAL,
        actualSeconds INTEGER NOT NULL DEFAULT 0,
        status TEXT,
        wrongCount INTEGER,
        aiEnabled INTEGER,
        needsGrading INTEGER NOT NULL DEFAULT 1,
        userRole TEXT,
        studentId TEXT NOT NULL DEFAULT '',
        submittedAt TEXT,
        checkedAt TEXT,
        score INTEGER,
        summary TEXT NOT NULL DEFAULT '',
        imageCount INTEGER NOT NULL DEFAULT 0,
        submitBatchId TEXT NOT NULL DEFAULT '',
        gradingSource TEXT NOT NULL DEFAULT ''
      )
    ''');

    await db.execute('''
      CREATE TABLE workout_plan (
        id TEXT PRIMARY KEY,
        title TEXT,
        project TEXT,
        weekdays TEXT,
        targetMinutes INTEGER,
        isActive INTEGER,
        startDate TEXT,
        endDate TEXT,
        startTime TEXT,
        endTime TEXT,
        cycleType TEXT,
        customWeekdays TEXT,
        studentId TEXT NOT NULL DEFAULT ''
      )
    ''');

    await db.execute('''
      CREATE TABLE workout_record (
        id TEXT PRIMARY KEY,
        project TEXT,
        startAt TEXT,
        endAt TEXT,
        minutes INTEGER,
        feedback TEXT,
        planId TEXT,
        studentId TEXT NOT NULL DEFAULT ''
      )
    ''');

    await db.execute('''
      CREATE TABLE review_mistake (
        id TEXT PRIMARY KEY,
        subject TEXT,
        title TEXT,
        questionBody TEXT NOT NULL DEFAULT '',
        questionNo TEXT NOT NULL DEFAULT '',
        studentProcess TEXT NOT NULL DEFAULT '',
        answerKey TEXT NOT NULL DEFAULT '',
        sourceType TEXT NOT NULL DEFAULT 'manual',
        grade TEXT NOT NULL DEFAULT '',
        term TEXT NOT NULL DEFAULT '',
        imageCount INTEGER NOT NULL DEFAULT 0,
        originalAnswer TEXT,
        wrongReason TEXT,
        createdAt TEXT,
        state TEXT,
        studentId TEXT NOT NULL DEFAULT '',
        homeworkId TEXT NOT NULL DEFAULT '',
        knowledgePoint TEXT NOT NULL DEFAULT '',
        wrongCount INTEGER NOT NULL DEFAULT 1,
        lastWrongAt TEXT,
        sourceHomeworkTitle TEXT NOT NULL DEFAULT '',
        masteredAt TEXT,
        masteredBySelf INTEGER NOT NULL DEFAULT 0,
        reviewRound INTEGER NOT NULL DEFAULT 0,
        lastReviewedAt TEXT
      )
    ''');

    // 错题图片。与 homework_image 分表：作业图片跟着作业走，
    // 错题图片必须独立于作业存在（作业删了，错题还在）。
    await db.execute('''
      CREATE TABLE review_mistake_image (
        id TEXT PRIMARY KEY,
        studentId TEXT NOT NULL DEFAULT '',
        mistakeId TEXT NOT NULL,
        storageKey TEXT NOT NULL DEFAULT '',
        mimeType TEXT NOT NULL DEFAULT '',
        fileSize INTEGER NOT NULL DEFAULT 0,
        sortOrder INTEGER NOT NULL DEFAULT 0,
        createdAt TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_review_mistake_image_mistake '
      'ON review_mistake_image(mistakeId, sortOrder)',
    );

    // 复习资料（试卷）。它是「生成资料」从一句提示语升级成的一等实体：
    // 可冻结、可导出、可回传、可批改、可结算，每个阶段都留时间戳。
    await db.execute('''
      CREATE TABLE review_paper (
        id TEXT PRIMARY KEY,
        studentId TEXT NOT NULL DEFAULT '',
        title TEXT NOT NULL DEFAULT '',
        subject TEXT NOT NULL DEFAULT '',
        knowledgePoints TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'draft',
        itemCount INTEGER NOT NULL DEFAULT 0,
        passCount INTEGER NOT NULL DEFAULT 0,
        failCount INTEGER NOT NULL DEFAULT 0,
        createdAt TEXT,
        exportedAt TEXT,
        submittedAt TEXT,
        gradedAt TEXT,
        closedAt TEXT,
        filePath TEXT NOT NULL DEFAULT '',
        note TEXT NOT NULL DEFAULT ''
      )
    ''');

    // 卷内单题快照。纸质卷一旦印出去，学生手上的纸和库里的题就分叉了；
    // 若批改时实时读原错题，题目内容随时可能对不上。快照是
    // 「先打印、后完成、再检查」这条链路能成立的前提。
    await db.execute('''
      CREATE TABLE review_paper_item (
        id TEXT PRIMARY KEY,
        paperId TEXT NOT NULL,
        mistakeId TEXT NOT NULL DEFAULT '',
        subject TEXT NOT NULL DEFAULT '',
        knowledgePoint TEXT NOT NULL DEFAULT '',
        questionTitle TEXT NOT NULL DEFAULT '',
        questionBody TEXT NOT NULL DEFAULT '',
        originalAnswer TEXT NOT NULL DEFAULT '',
        wrongReason TEXT NOT NULL DEFAULT '',
        answerKey TEXT NOT NULL DEFAULT '',
        sortOrder INTEGER NOT NULL DEFAULT 0,
        studentAnswer TEXT NOT NULL DEFAULT '',
        result TEXT NOT NULL DEFAULT 'pending',
        photoPath TEXT NOT NULL DEFAULT '',
        comment TEXT NOT NULL DEFAULT '',
        checkedAt TEXT
      )
    ''');

    // 判定影子比对：同一道题「模型怎么判」与「本地规则会怎么判」各记一行。
    //
    // 独立成表而不是往 `review_attempt` 加两列：后者是**毕业判定的唯一依据**，
    // 语义被收得很紧（一条 = 一次作答证据）。往里塞观测数据以后，
    // 任何按它统计的毕业率都要先过滤掉「不是作答」的行 —— 迟早有人忘。
    //
    // 一行 = 一次比对，不是一次作答：举一反三一次提交里有 3 道题就有 3 行。
    // 这样「一致率」的分母才等于模型真正判定过的题数。
    await db.execute('''
      CREATE TABLE judgement_ab (
        id TEXT PRIMARY KEY,
        studentId TEXT NOT NULL DEFAULT '',
        mistakeId TEXT NOT NULL DEFAULT '',
        channel TEXT NOT NULL DEFAULT 'paper',
        subject TEXT NOT NULL DEFAULT '',
        knowledgePoint TEXT NOT NULL DEFAULT '',
        modelVerdict TEXT NOT NULL DEFAULT '',
        ruleVerdict TEXT NOT NULL DEFAULT '',
        createdAt TEXT
      )
    ''');

    // 作答证据：毕业判定的唯一依据。三条路（纸质卷 / 自评 / 练习）都写这里。
    await db.execute('''
      CREATE TABLE review_attempt (
        id TEXT PRIMARY KEY,
        studentId TEXT NOT NULL DEFAULT '',
        mistakeId TEXT NOT NULL DEFAULT '',
        paperId TEXT NOT NULL DEFAULT '',
        itemId TEXT NOT NULL DEFAULT '',
        channel TEXT NOT NULL DEFAULT 'paper',
        round INTEGER NOT NULL DEFAULT 1,
        answer TEXT NOT NULL DEFAULT '',
        correct INTEGER NOT NULL DEFAULT 0,
        score INTEGER NOT NULL DEFAULT 0,
        comment TEXT NOT NULL DEFAULT '',
        createdAt TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE ai_practice_question (
        id TEXT PRIMARY KEY,
        studentId TEXT NOT NULL DEFAULT '',
        sourceMistakeId TEXT NOT NULL DEFAULT '',
        knowledgePoint TEXT NOT NULL DEFAULT '',
        subject TEXT NOT NULL DEFAULT '',
        title TEXT NOT NULL DEFAULT '',
        content TEXT NOT NULL DEFAULT '',
        answer TEXT NOT NULL DEFAULT '',
        difficulty TEXT NOT NULL DEFAULT '基础',
        studentAnswer TEXT NOT NULL DEFAULT '',
        state TEXT NOT NULL DEFAULT 'pending',
        round INTEGER NOT NULL DEFAULT 1,
        createdAt TEXT,
        checkedAt TEXT,
        questionType TEXT NOT NULL DEFAULT 'solution',
        optionsJson TEXT NOT NULL DEFAULT '[]',
        figureJson TEXT
      )
    ''');

    // 讲解留痕。讲解不构成毕业（看懂 ≠ 会做），只进过程时间线，不改掌握率。
    await db.execute('''
      CREATE TABLE explain_record (
        id TEXT PRIMARY KEY,
        studentId TEXT NOT NULL DEFAULT '',
        mistakeId TEXT NOT NULL DEFAULT '',
        knowledgePoint TEXT NOT NULL DEFAULT '',
        channel TEXT NOT NULL DEFAULT 'ai',
        summary TEXT NOT NULL DEFAULT '',
        staySeconds INTEGER NOT NULL DEFAULT 0,
        createdAt TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE review_summary (
        id TEXT PRIMARY KEY,
        studentId TEXT NOT NULL DEFAULT '',
        scope TEXT NOT NULL DEFAULT 'paper',
        scopeKey TEXT NOT NULL DEFAULT '',
        totalCount INTEGER NOT NULL DEFAULT 0,
        passCount INTEGER NOT NULL DEFAULT 0,
        masteredCount INTEGER NOT NULL DEFAULT 0,
        remainCount INTEGER NOT NULL DEFAULT 0,
        passRate REAL NOT NULL DEFAULT 0,
        weakPoints TEXT NOT NULL DEFAULT '',
        body TEXT NOT NULL DEFAULT '',
        generatedAt TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE wish (
        id TEXT PRIMARY KEY,
        title TEXT,
        description TEXT,
        isPublic INTEGER,
        parentConfirmed INTEGER,
        studentConfirmed INTEGER,
        isArchived INTEGER,
        userRole TEXT,
        studentId TEXT NOT NULL DEFAULT '',
        expectedDate TEXT,
        pointCost INTEGER NOT NULL DEFAULT 0,
        redeemRequestedAt TEXT,
        redeemedAt TEXT,
        redeemRejectedAt TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE study_plan (
        id TEXT PRIMARY KEY,
        title TEXT,
        content TEXT,
        startAt TEXT,
        endAt TEXT,
        type TEXT,
        status TEXT,
        userRole TEXT,
        studentId TEXT NOT NULL DEFAULT '',
        cycleType TEXT NOT NULL DEFAULT 'daily',
        customWeekdays TEXT,
        rejectReason TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE study_plan_checkin (
        id TEXT PRIMARY KEY,
        planId TEXT NOT NULL,
        studentId TEXT NOT NULL DEFAULT '',
        date TEXT NOT NULL,
        createdAt TEXT,
        UNIQUE(planId, date)
      )
    ''');

    await db.execute('''
      CREATE TABLE relationship (
        id TEXT PRIMARY KEY,
        studentId TEXT NOT NULL,
        parentId TEXT NOT NULL,
        senderId TEXT NOT NULL,
        status TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        UNIQUE(studentId, parentId)
      )
    ''');

    await db.execute('''
      CREATE TABLE chat_message (
        id TEXT PRIMARY KEY,
        relationshipId TEXT NOT NULL,
        senderId TEXT NOT NULL,
        receiverId TEXT NOT NULL,
        content TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        isRead INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE homework_image (
        id TEXT PRIMARY KEY,
        studentId TEXT NOT NULL,
        homeworkId TEXT,
        storageKey TEXT NOT NULL,
        fileName TEXT NOT NULL,
        fileSize INTEGER NOT NULL,
        mimeType TEXT NOT NULL,
        ocrStatus TEXT NOT NULL,
        ocrText TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        batchId TEXT NOT NULL DEFAULT '',
        sortOrder INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE app_notification (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        isRead INTEGER NOT NULL DEFAULT 0,
        targetUserId TEXT NOT NULL DEFAULT '',
        type TEXT NOT NULL DEFAULT 'system',
        relatedBizId TEXT NOT NULL DEFAULT ''
      )
    ''');

    await db.execute('''
      CREATE TABLE daily_comment (
        id TEXT PRIMARY KEY,
        rating TEXT NOT NULL,
        content TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        studentId TEXT NOT NULL DEFAULT ''
      )
    ''');

    // ===== 积分 =====
    //
    // point_rule：家长给每个动作设的分值。**没配的行等于用出厂默认值**，
    // 所以家长从没进过设置页也能正常计分，不需要预生成一大堆行。
    await db.execute('''
      CREATE TABLE point_rule (
        studentId TEXT NOT NULL,
        action TEXT NOT NULL,
        points INTEGER NOT NULL DEFAULT 0,
        enabled INTEGER NOT NULL DEFAULT 1,
        updatedAt TEXT,
        UNIQUE(studentId, action)
      )
    ''');

    // point_ledger：唯一真相。余额永远由这张表求和得来，不另存字段。
    await db.execute('''
      CREATE TABLE point_ledger (
        id TEXT PRIMARY KEY,
        studentId TEXT NOT NULL DEFAULT '',
        action TEXT NOT NULL DEFAULT '',
        points INTEGER NOT NULL DEFAULT 0,
        reason TEXT NOT NULL DEFAULT '',
        idempotencyKey TEXT NOT NULL DEFAULT '',
        reversalOf TEXT NOT NULL DEFAULT '',
        refType TEXT NOT NULL DEFAULT '',
        refId TEXT NOT NULL DEFAULT '',
        createdAt TEXT,
        createdBy TEXT NOT NULL DEFAULT '',
        reversedAt TEXT
      )
    ''');

    // 行为扣分的配置表（v33）。一个孩子一个行为一行，id 是稳定标识，
    // 内置行为也落表 —— 家长可以改分值/关闭，但不能删，否则历史扣分
    // 记录在账本里只剩一个看不懂的 refId。
    await db.execute('''
      CREATE TABLE point_behavior (
        studentId TEXT NOT NULL,
        id TEXT NOT NULL,
        name TEXT NOT NULL DEFAULT '',
        points INTEGER NOT NULL DEFAULT 0,
        enabled INTEGER NOT NULL DEFAULT 1,
        builtin INTEGER NOT NULL DEFAULT 0,
        updatedAt TEXT,
        PRIMARY KEY (studentId, id)
      )
    ''');
    await db.execute('''
      CREATE INDEX idx_point_behavior_student
        ON point_behavior(studentId, enabled)
    ''');

    // 防重的最后一道闸。
    //
    // 同一个动作只能有一条「还活着」的发分记录：撤销时原记录会打上
    // reversedAt、退出这个索引范围，于是重新打卡能正常记新的一笔，
    // 而「连点两次打卡」「重放同一个请求」会被数据库直接挡掉。
    // 只靠 Dart 侧查一次再插是不牢的 —— 查与插之间永远有缝。
    await db.execute('''
      CREATE UNIQUE INDEX idx_point_ledger_active_key
        ON point_ledger(idempotencyKey)
        WHERE idempotencyKey <> '' AND reversedAt IS NULL
    ''');
    await db.execute('''
      CREATE INDEX idx_point_ledger_student
        ON point_ledger(studentId, createdAt)
    ''');

    // 知识点提示：由错题库归纳、只在本机使用的缓存（见 v27 迁移的说明）。
    await db.execute('''
      CREATE TABLE knowledge_tip (
        id TEXT PRIMARY KEY,
        studentId TEXT NOT NULL DEFAULT '',
        subject TEXT NOT NULL DEFAULT '',
        knowledgePoint TEXT NOT NULL DEFAULT '',
        text TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL DEFAULT 'rule',
        sortOrder INTEGER NOT NULL DEFAULT 0,
        generatedAt TEXT NOT NULL DEFAULT '',
        signature TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE INDEX idx_knowledge_tip_scope
        ON knowledge_tip(studentId, subject)
    ''');

    // 应用设置：只在**这台设备**上生效的偏好。
    await db.execute('''
      CREATE TABLE app_setting (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL DEFAULT ''
      )
    ''');

    // 每日概念训练流水（`drill_question.dart` 的 DrillAnswer）。
    // 与 knowledge_tip 同一路线：**只在本机**，不进服务端。
    await db.execute('''
      CREATE TABLE drill_answer (
        id TEXT PRIMARY KEY,
        studentId TEXT NOT NULL DEFAULT '',
        questionId TEXT NOT NULL DEFAULT '',
        pattern TEXT NOT NULL DEFAULT '',
        knowledge TEXT NOT NULL DEFAULT '',
        tier TEXT NOT NULL DEFAULT '',
        chosenIndex INTEGER NOT NULL DEFAULT -1,
        correct INTEGER NOT NULL DEFAULT 0,
        date TEXT NOT NULL DEFAULT '',
        createdAt TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE INDEX idx_drill_answer_student_date
        ON drill_answer(studentId, date)
    ''');
    await db.execute('''
      CREATE INDEX idx_drill_answer_question
        ON drill_answer(questionId)
    ''');

    // 英语单词打卡（v32）：词表缓存 + 整组作答流水，两张表都只在本机。
    // 题目快照跟着作答一起存，回看已完成的那组题不依赖网络 / 词表。
    await _createWordCheckinTables(db);

    // 专注计时流水：一次会话一行（`focus_session_model.dart`）。
    await db.execute('''
      CREATE TABLE focus_session (
        id TEXT PRIMARY KEY,
        studentId TEXT NOT NULL DEFAULT '',
        kind TEXT NOT NULL DEFAULT 'free',
        sourceId TEXT NOT NULL DEFAULT '',
        title TEXT NOT NULL DEFAULT '',
        date TEXT NOT NULL DEFAULT '',
        seconds INTEGER NOT NULL DEFAULT 0,
        startedAt TEXT,
        updatedAt TEXT
      )
    ''');
    await db.execute('''
      CREATE INDEX idx_focus_session_student_date
        ON focus_session(studentId, date)
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE app_user (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          phone TEXT UNIQUE,
          role TEXT NOT NULL,
          avatar TEXT NOT NULL,
          password TEXT,
          wechatOpenId TEXT UNIQUE,
          gender TEXT DEFAULT '',
          grade TEXT DEFAULT '',
          hobbies TEXT DEFAULT '',
          bio TEXT DEFAULT ''
        )
      ''');
    }
    if (oldVersion < 3) {
      await db.execute(
        'ALTER TABLE app_user ADD COLUMN gender TEXT DEFAULT \'\'',
      );
      await db.execute(
        'ALTER TABLE app_user ADD COLUMN grade TEXT DEFAULT \'\'',
      );
      await db.execute(
        'ALTER TABLE app_user ADD COLUMN hobbies TEXT DEFAULT \'\'',
      );
      await db.execute('ALTER TABLE app_user ADD COLUMN bio TEXT DEFAULT \'\'');
      await db.execute('''
        CREATE TABLE relationship (
          id TEXT PRIMARY KEY,
          studentId TEXT NOT NULL,
          parentId TEXT NOT NULL,
          senderId TEXT NOT NULL,
          status TEXT NOT NULL,
          createdAt TEXT NOT NULL,
          UNIQUE(studentId, parentId)
        )
      ''');
    }
    if (oldVersion < 4) {
      await db.execute('''
        CREATE TABLE chat_message (
          id TEXT PRIMARY KEY,
          relationshipId TEXT NOT NULL,
          senderId TEXT NOT NULL,
          receiverId TEXT NOT NULL,
          content TEXT NOT NULL,
          createdAt TEXT NOT NULL,
          isRead INTEGER NOT NULL DEFAULT 0
        )
      ''');
    }
    if (oldVersion < 5) {
      await db.execute('''
        CREATE TABLE homework_image (
          id TEXT PRIMARY KEY,
          studentId TEXT NOT NULL,
          homeworkId TEXT,
          storageKey TEXT NOT NULL,
          fileName TEXT NOT NULL,
          fileSize INTEGER NOT NULL,
          mimeType TEXT NOT NULL,
          ocrStatus TEXT NOT NULL,
          ocrText TEXT NOT NULL,
          createdAt TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 7) {
      await db.execute('''
        CREATE TABLE app_notification (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          body TEXT NOT NULL,
          createdAt TEXT NOT NULL,
          isRead INTEGER NOT NULL DEFAULT 0
        )
      ''');
    }
    if (oldVersion < 8) {
      await db.execute('''
        CREATE TABLE daily_comment (
          id TEXT PRIMARY KEY,
          rating TEXT NOT NULL,
          content TEXT NOT NULL,
          createdAt TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 9) {
      await db.execute(
        'ALTER TABLE wish ADD COLUMN studentId TEXT NOT NULL DEFAULT \'\'',
      );
    }
    if (oldVersion < 10) {
      await db.execute('ALTER TABLE workout_plan ADD COLUMN startDate TEXT');
      await db.execute('ALTER TABLE workout_plan ADD COLUMN endDate TEXT');
      await db.execute(
        'ALTER TABLE workout_plan ADD COLUMN startTime TEXT DEFAULT \'08:00\'',
      );
      await db.execute(
        'ALTER TABLE workout_plan ADD COLUMN endTime TEXT DEFAULT \'09:00\'',
      );
      await db.execute(
        'ALTER TABLE workout_plan ADD COLUMN cycleType TEXT DEFAULT \'weekly\'',
      );
      await db.execute(
        'ALTER TABLE workout_plan ADD COLUMN customWeekdays TEXT',
      );
      await db.execute(
        'ALTER TABLE workout_record ADD COLUMN planId TEXT DEFAULT \'\'',
      );
    }
    if (oldVersion < 11) {
      await db.execute('ALTER TABLE wish ADD COLUMN expectedDate TEXT');
    }
    if (oldVersion < 12) {
      await db.execute(
        "ALTER TABLE homework ADD COLUMN studentId TEXT NOT NULL DEFAULT ''",
      );
      // 历史作业数据归属演示学生，保证演示家长可继续查看
      await db.update('homework', {
        'studentId': 'stu_001',
      }, where: "studentId = '' OR studentId IS NULL");
    }
    if (oldVersion < 13) {
      // 其他模块补充学生归属字段
      for (final table in [
        'workout_plan',
        'workout_record',
        'review_mistake',
        'review_cycle',
        'study_plan',
        'daily_comment',
      ]) {
        await db.execute(
          "ALTER TABLE $table ADD COLUMN studentId TEXT NOT NULL DEFAULT ''",
        );
        await db.update(table, {
          'studentId': 'stu_001',
        }, where: "studentId = '' OR studentId IS NULL");
      }
    }
    if (oldVersion < 14) {
      // 多孩演示：补充第二个孩子 stu_002 的业务数据（幂等插入）
      await _seedSecondChildDemoData(db);
    }
    if (oldVersion < 15) {
      // 学习计划支持与运动计划相同的周期规则：每天/每周/每月 + 执行星期
      await db.execute(
        "ALTER TABLE study_plan ADD COLUMN cycleType TEXT NOT NULL DEFAULT 'daily'",
      );
      await db.execute('ALTER TABLE study_plan ADD COLUMN customWeekdays TEXT');
    }
    if (oldVersion < 16) {
      // 学习计划拒绝理由
      await db.execute('ALTER TABLE study_plan ADD COLUMN rejectReason TEXT');
    }
    if (oldVersion < 17) {
      // 学习计划每日打卡
      await db.execute('''
        CREATE TABLE IF NOT EXISTS study_plan_checkin (
          id TEXT PRIMARY KEY,
          planId TEXT NOT NULL,
          studentId TEXT NOT NULL DEFAULT '',
          date TEXT NOT NULL,
          createdAt TEXT,
          UNIQUE(planId, date)
        )
      ''');
    }
    if (oldVersion < 18) {
      // 作业链路增强：提交时间 / 批改结果 / 图片计数 / 提交批次
      for (final column in const [
        'submittedAt TEXT',
        'checkedAt TEXT',
        'score INTEGER',
        "summary TEXT NOT NULL DEFAULT ''",
        'imageCount INTEGER NOT NULL DEFAULT 0',
        "submitBatchId TEXT NOT NULL DEFAULT ''",
      ]) {
        await db.execute('ALTER TABLE homework ADD COLUMN $column');
      }
      // 图片批次：老数据没有批次概念，按「每张图自成一批」回溯填充，
      // 保证历史图片仍能被家长端按批展示，而不是全部糊成一批。
      await db.execute(
        "ALTER TABLE homework_image ADD COLUMN batchId TEXT NOT NULL DEFAULT ''",
      );
      await db.execute(
        'ALTER TABLE homework_image ADD COLUMN sortOrder INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        "UPDATE homework_image SET batchId = id WHERE batchId = ''",
      );

      // 错题回溯到来源作业
      await db.execute(
        "ALTER TABLE review_mistake ADD COLUMN homeworkId TEXT NOT NULL DEFAULT ''",
      );

      // 通知定向：此前通知表没有归属字段，学生端与家长端共用一个列表。
      // 历史通知既无法判定归属，统一按「广播」处理（targetUserId 留空），
      // 由用户按需点开，不做猜测性归属。
      for (final column in const [
        "targetUserId TEXT NOT NULL DEFAULT ''",
        "type TEXT NOT NULL DEFAULT 'system'",
        "relatedBizId TEXT NOT NULL DEFAULT ''",
      ]) {
        await db.execute('ALTER TABLE app_notification ADD COLUMN $column');
      }

      // 旧的 `submitted` 状态语义是「已上传照片」，与作业完成度混在一起。
      // 归一为 pending：状态只描述作业推进阶段，图片有无由 imageCount 表达。
      await db.update('homework', {
        'status': HomeworkStatus.pending.name,
      }, where: 'status = ?', whereArgs: ['submitted']);
      // 已有图片的历史作业补上计数，避免家长端显示「0 张照片」。
      await db.execute('''
        UPDATE homework
        SET imageCount = (
          SELECT COUNT(*) FROM homework_image
          WHERE homework_image.homeworkId = homework.id
        )
        WHERE EXISTS (
          SELECT 1 FROM homework_image WHERE homework_image.homeworkId = homework.id
        )
      ''');
    }
    if (oldVersion < 19) {
      // 复习闭环：错题池增强 + 资料快照 + 作答证据 + 讲解 / 练习 / 总结。
      //
      // 这里新增的列与表，_onCreate 必须同步补全。上一次升级就是因为
      // _onCreate 漏了列，老库升级没事、全新安装却直接报
      // "has no column named summary" —— 两个入口必须一起改。
      for (final column in const [
        "knowledgePoint TEXT NOT NULL DEFAULT ''",
        'wrongCount INTEGER NOT NULL DEFAULT 1',
        'lastWrongAt TEXT',
        "sourceHomeworkTitle TEXT NOT NULL DEFAULT ''",
        'masteredAt TEXT',
        'masteredBySelf INTEGER NOT NULL DEFAULT 0',
        'reviewRound INTEGER NOT NULL DEFAULT 0',
        'lastReviewedAt TEXT',
      ]) {
        await db.execute('ALTER TABLE review_mistake ADD COLUMN $column');
      }
      // 历史错题没有「最近做错时间」，回填 createdAt 而不是留空，
      // 否则薄弱度衰减会拿不到基准时间。知识点宁可为空也不猜，
      // 错误的标签会把薄弱点画像带偏。
      await db.execute(
        'UPDATE review_mistake SET lastWrongAt = createdAt '
        'WHERE lastWrongAt IS NULL',
      );

      await db.execute('''
        CREATE TABLE IF NOT EXISTS review_paper (
          id TEXT PRIMARY KEY,
          studentId TEXT NOT NULL DEFAULT '',
          title TEXT NOT NULL DEFAULT '',
          subject TEXT NOT NULL DEFAULT '',
          knowledgePoints TEXT NOT NULL DEFAULT '',
          status TEXT NOT NULL DEFAULT 'draft',
          itemCount INTEGER NOT NULL DEFAULT 0,
          passCount INTEGER NOT NULL DEFAULT 0,
          failCount INTEGER NOT NULL DEFAULT 0,
          createdAt TEXT,
          exportedAt TEXT,
          submittedAt TEXT,
          gradedAt TEXT,
          closedAt TEXT,
          filePath TEXT NOT NULL DEFAULT '',
          note TEXT NOT NULL DEFAULT ''
        )
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS review_paper_item (
          id TEXT PRIMARY KEY,
          paperId TEXT NOT NULL,
          mistakeId TEXT NOT NULL DEFAULT '',
          subject TEXT NOT NULL DEFAULT '',
          knowledgePoint TEXT NOT NULL DEFAULT '',
          questionTitle TEXT NOT NULL DEFAULT '',
          questionBody TEXT NOT NULL DEFAULT '',
          originalAnswer TEXT NOT NULL DEFAULT '',
          wrongReason TEXT NOT NULL DEFAULT '',
          answerKey TEXT NOT NULL DEFAULT '',
          sortOrder INTEGER NOT NULL DEFAULT 0,
          studentAnswer TEXT NOT NULL DEFAULT '',
          result TEXT NOT NULL DEFAULT 'pending',
          photoPath TEXT NOT NULL DEFAULT '',
          comment TEXT NOT NULL DEFAULT '',
          checkedAt TEXT
        )
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS review_attempt (
          id TEXT PRIMARY KEY,
          studentId TEXT NOT NULL DEFAULT '',
          mistakeId TEXT NOT NULL DEFAULT '',
          paperId TEXT NOT NULL DEFAULT '',
          itemId TEXT NOT NULL DEFAULT '',
          channel TEXT NOT NULL DEFAULT 'paper',
          round INTEGER NOT NULL DEFAULT 1,
          answer TEXT NOT NULL DEFAULT '',
          correct INTEGER NOT NULL DEFAULT 0,
          score INTEGER NOT NULL DEFAULT 0,
          comment TEXT NOT NULL DEFAULT '',
          createdAt TEXT
        )
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS ai_practice_question (
          id TEXT PRIMARY KEY,
          studentId TEXT NOT NULL DEFAULT '',
          sourceMistakeId TEXT NOT NULL DEFAULT '',
          knowledgePoint TEXT NOT NULL DEFAULT '',
          subject TEXT NOT NULL DEFAULT '',
          title TEXT NOT NULL DEFAULT '',
          content TEXT NOT NULL DEFAULT '',
          answer TEXT NOT NULL DEFAULT '',
          difficulty TEXT NOT NULL DEFAULT '基础',
          studentAnswer TEXT NOT NULL DEFAULT '',
          state TEXT NOT NULL DEFAULT 'pending',
          round INTEGER NOT NULL DEFAULT 1,
          createdAt TEXT,
          checkedAt TEXT
        )
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS explain_record (
          id TEXT PRIMARY KEY,
          studentId TEXT NOT NULL DEFAULT '',
          mistakeId TEXT NOT NULL DEFAULT '',
          knowledgePoint TEXT NOT NULL DEFAULT '',
          channel TEXT NOT NULL DEFAULT 'ai',
          summary TEXT NOT NULL DEFAULT '',
          staySeconds INTEGER NOT NULL DEFAULT 0,
          createdAt TEXT
        )
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS review_summary (
          id TEXT PRIMARY KEY,
          studentId TEXT NOT NULL DEFAULT '',
          scope TEXT NOT NULL DEFAULT 'paper',
          scopeKey TEXT NOT NULL DEFAULT '',
          totalCount INTEGER NOT NULL DEFAULT 0,
          passCount INTEGER NOT NULL DEFAULT 0,
          masteredCount INTEGER NOT NULL DEFAULT 0,
          remainCount INTEGER NOT NULL DEFAULT 0,
          passRate REAL NOT NULL DEFAULT 0,
          weakPoints TEXT NOT NULL DEFAULT '',
          body TEXT NOT NULL DEFAULT '',
          generatedAt TEXT
        )
      ''');

      // 旧「复习轮次」迁入资料表。旧记录只有「生成过一轮」这个事实，
      // 没有题目内容，所以统一置为已归档：它能说明历史，但不该参与
      // 当前闭环（否则一批没有题目的空卷会污染待作答列表）。
      try {
        await db.execute('''
          INSERT OR IGNORE INTO review_paper
            (id, studentId, title, subject, knowledgePoints, status,
             itemCount, passCount, failCount, createdAt, closedAt, filePath, note)
          SELECT id, studentId, title, '', '', 'closed',
                 totalMistakes, masteredCount,
                 MAX(totalMistakes - masteredCount, 0),
                 generatedAt, generatedAt, pdfUrl, '由旧版复习轮次迁入'
          FROM review_cycle
        ''');
      } catch (_) {
        // 极老版本的库里可能没有 review_cycle，迁移失败不影响新表可用。
      }
    }
    if (oldVersion < 20) {
      // 批改来源：'' 未批改 / cloud 云端模型 / local 本地兜底。
      //
      // 新增列与 _onCreate 必须同时补，否则会出现「老库升级没事、
      // 全新安装直接炸」——上一轮就是栽在这上面。
      await db.execute(
        "ALTER TABLE homework ADD COLUMN gradingSource TEXT NOT NULL DEFAULT ''",
      );

      // 已有批改结果的历史行，全部回填为 local。
      //
      // 这不是保守估计，是事实：**这个版本之前根本不存在云端路径**，
      // 所有批改结果都由 `SimulatedAiDataSource` 产出。留空的话它们会被
      // 当成模型输出 —— 而这正是本列要防的那件事。
      await db.execute(
        "UPDATE homework SET gradingSource = ? "
        "WHERE gradingSource = '' AND checkedAt IS NOT NULL",
        [GradingSource.local],
      );
    }
    if (oldVersion < 21) {
      // 判定影子比对表。**纯新增表，不需要回填** ——
      // 这个版本之前系统从没记录过规则侧结论，凭空造一份历史等于伪造数据。
      // 老库升级后一致率会是「暂无样本」，这是如实的结果。
      //
      // 与 _onCreate 必须同步补：漏在 _onCreate 那边会造成
      // 「老库升级没事、全新安装直接炸」——前面版本已经栽过一次。
      await db.execute('''
        CREATE TABLE IF NOT EXISTS judgement_ab (
          id TEXT PRIMARY KEY,
          studentId TEXT NOT NULL DEFAULT '',
          mistakeId TEXT NOT NULL DEFAULT '',
          channel TEXT NOT NULL DEFAULT 'paper',
          subject TEXT NOT NULL DEFAULT '',
          knowledgePoint TEXT NOT NULL DEFAULT '',
          modelVerdict TEXT NOT NULL DEFAULT '',
          ruleVerdict TEXT NOT NULL DEFAULT '',
          createdAt TEXT
        )
      ''');

      // 批改口径：1 需要批改 / 0 这类作业没有对错可判（朗读、背诵、预习）。
      //
      // ⚠️ 这个分支原本挂在这里，但 `_initDatabase` 的 `version` 停在了 20 ——
      // 于是 `oldVersion < 21` 对任何旧库都成立，判定表「碰巧」被建出来，
      // 而版本号本身没动。功能上没坏（建表语句是 IF NOT EXISTS），
      // 但「分支号」与「版本号」是这套迁移唯一的一致性依据，脱节之后
      // 下一个人就没法从版本号推断哪些迁移跑过了。这次加列正好把 21 补上。
      await db.execute(
        'ALTER TABLE homework ADD COLUMN needsGrading INTEGER NOT NULL DEFAULT 1',
      );
    }
    if (oldVersion < 22) {
      // 积分体系：两张新表 + 心愿的兑换状态。
      //
      // **纯新增，不回填**：这个版本之前没有任何积分流水，凭空造一份历史
      // 等于伪造孩子的得分。老库升级后余额从 0 开始，这是如实的结果。
      //
      // 与 _onCreate 必须同步补 —— 漏在 _onCreate 那边会造成
      // 「老库升级没事、全新安装直接炸」，前面版本已经栽过一次。
      await db.execute('''
        CREATE TABLE IF NOT EXISTS point_rule (
          studentId TEXT NOT NULL,
          action TEXT NOT NULL,
          points INTEGER NOT NULL DEFAULT 0,
          enabled INTEGER NOT NULL DEFAULT 1,
          updatedAt TEXT,
          UNIQUE(studentId, action)
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS point_ledger (
          id TEXT PRIMARY KEY,
          studentId TEXT NOT NULL DEFAULT '',
          action TEXT NOT NULL DEFAULT '',
          points INTEGER NOT NULL DEFAULT 0,
          reason TEXT NOT NULL DEFAULT '',
          idempotencyKey TEXT NOT NULL DEFAULT '',
          reversalOf TEXT NOT NULL DEFAULT '',
          refType TEXT NOT NULL DEFAULT '',
          refId TEXT NOT NULL DEFAULT '',
          createdAt TEXT,
          createdBy TEXT NOT NULL DEFAULT '',
          reversedAt TEXT
        )
      ''');
      await db.execute('''
        CREATE UNIQUE INDEX IF NOT EXISTS idx_point_ledger_active_key
          ON point_ledger(idempotencyKey)
          WHERE idempotencyKey <> '' AND reversedAt IS NULL
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_point_ledger_student
          ON point_ledger(studentId, createdAt)
      ''');

      // 心愿兑换：0 = 不消耗积分（家长确认时定的）。
      await db.execute(
        'ALTER TABLE wish ADD COLUMN pointCost INTEGER NOT NULL DEFAULT 0',
      );
      // 三个时间戳代替一个状态字段：申请 / 兑现 / 拒绝各有各的时间点，
      // 压成一个状态就得再定一套「谁覆盖谁」的规则，而那正是扯皮的来源。
      await db.execute('ALTER TABLE wish ADD COLUMN redeemRequestedAt TEXT');
      await db.execute('ALTER TABLE wish ADD COLUMN redeemedAt TEXT');
      await db.execute('ALTER TABLE wish ADD COLUMN redeemRejectedAt TEXT');
    }
    if (oldVersion < 23) {
      // 登录方式的预留（见 doc/auth-extension-seams.md）。
      //
      // 只加**一列**，而且刻意不建「验证码表」：
      // 验证码的校验必须发生在服务端，客户端数据库里存一份等于给了
      // 一条「本地把码比出来」的捷径，而改密码这件事一旦能在本地成立，
      // 就等于没有鉴权。所以客户端只留「密码什么时候改的」这一个时间戳。
      //
      // 老库升级后该列为 NULL，语义正是「从未设置过密码」——
      // 但这是**不对的**：老账号显然有密码。回填成空串也同样不对
      // （`DateTime.tryParse('')` 得到 null，和「没设过密码」区分不开）。
      // 因此这里用升级时刻回填「密码至少在这个版本之前就存在」，
      // 并把精确归因交给 `password IS NOT NULL` —— 见 `UserModel.hasPassword`，
      // 它判的是密码本身，而不是这个时间戳。
      await db.execute('ALTER TABLE app_user ADD COLUMN passwordUpdatedAt TEXT');
      await db.execute(
        'UPDATE app_user SET passwordUpdatedAt = ? '
        "WHERE password IS NOT NULL AND password <> ''",
        [DateTime.now().toIso8601String()],
      );
    }
    if (oldVersion < 24) {
      // 错题闭环 P1：主动录入与学期归档。
      //
      // ⚠️ 这里新增的列与表，_onCreate 必须同步补全（上一次升级就是因为
      //    _onCreate 漏列，老库能升、全新安装直接炸）。
      //
      // 历史数据**不回填** questionBody / grade / term：
      //   · title 是「作业标题 · 知识点」，不是题目原文，拿它冒充题干会让
      //     讲解继续拿一句标签当题讲；
      //   · 年级学期无从推断，猜一个比空着更糟（历史错题会被归到错误的学期）。
      // 空值在 UI 里如实显示为「未归档」，并由默认筛选兜住，见 review_tab。
      //
      // ⚠️ **先问表在不在，再问列在不在**。看着啰嗦，但这是「老库能升、
      //    新装不炸」之外的第二层护栏：迁移用例造的库可能只有 `app_user`
      //    一张表（v3 时代的形状），`ALTER TABLE review_mistake` 会直接抛
      //    `no such table`，而它发生在 `openDatabase` 期间 —— 后果不是
      //    「少一个字段」，是**整个库打不开**。列判断则让迁移可以重跑。
      if (await _hasTable(db, 'app_user') &&
          !await _hasColumn(db, 'app_user', 'term')) {
        await db.execute("ALTER TABLE app_user ADD COLUMN term TEXT DEFAULT ''");
      }

      if (await _hasTable(db, 'review_mistake')) {
        const columns = <String, String>{
          'questionBody': "questionBody TEXT NOT NULL DEFAULT ''",
          'answerKey': "answerKey TEXT NOT NULL DEFAULT ''",
          'sourceType': "sourceType TEXT NOT NULL DEFAULT 'manual'",
          'grade': "grade TEXT NOT NULL DEFAULT ''",
          'term': "term TEXT NOT NULL DEFAULT ''",
          'imageCount': 'imageCount INTEGER NOT NULL DEFAULT 0',
        };
        for (final entry in columns.entries) {
          if (await _hasColumn(db, 'review_mistake', entry.key)) continue;
          await db.execute('ALTER TABLE review_mistake ADD COLUMN ${entry.value}');
        }
        // 来源按「有没有来源作业」判定：有 homeworkId 的确实是批改产出的。
        await db.execute(
          "UPDATE review_mistake SET sourceType = 'homework' "
          "WHERE homeworkId <> ''",
        );
      }
      await db.execute('''
        CREATE TABLE IF NOT EXISTS review_mistake_image (
          id TEXT PRIMARY KEY,
          studentId TEXT NOT NULL DEFAULT '',
          mistakeId TEXT NOT NULL,
          storageKey TEXT NOT NULL DEFAULT '',
          mimeType TEXT NOT NULL DEFAULT '',
          fileSize INTEGER NOT NULL DEFAULT 0,
          sortOrder INTEGER NOT NULL DEFAULT 0,
          createdAt TEXT
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_review_mistake_image_mistake '
        'ON review_mistake_image(mistakeId, sortOrder)',
      );
    }

    if (oldVersion < 25) {
      // 变式题的题型与选项。
      //
      // 默认 `solution` + 空选项：加这两列之前生成的题**全都是**解答题
      // （文字作答 + 拍照识别 + 模型判定），按它走与以前完全一致。
      // 默认成 choice 会让老题变成「没有选项的选择题」—— 学生点不了任何东西。
      //
      // ⚠️ 先判表在不在：`PRAGMA table_info(不存在的表)` 返回空列表而不报错，
      // 于是「表不存在」会表现得像「每一列都缺」，接下来那条 ALTER 会把
      // `openDatabase` 一起炸掉（v24 已经栽过一次）。
      if (await _hasTable(db, 'ai_practice_question')) {
        if (!await _hasColumn(db, 'ai_practice_question', 'questionType')) {
          await db.execute(
            "ALTER TABLE ai_practice_question "
            "ADD COLUMN questionType TEXT NOT NULL DEFAULT 'solution'",
          );
        }
        if (!await _hasColumn(db, 'ai_practice_question', 'optionsJson')) {
          await db.execute(
            "ALTER TABLE ai_practice_question "
            "ADD COLUMN optionsJson TEXT NOT NULL DEFAULT '[]'",
          );
        }
        // 配图（图形 DSL 的 JSON）。**故意允许 NULL**：绝大多数题不需要图，
        // 给一个 '{}' 默认值会让「有没有图」变成必须解析才知道，
        // 而 `figureJson IS NULL` 能直接数出「有多少道题带图」。
        if (!await _hasColumn(db, 'ai_practice_question', 'figureJson')) {
          await db.execute(
            'ALTER TABLE ai_practice_question ADD COLUMN figureJson TEXT',
          );
        }
      } else {
        // 极简老库可能压根没有这张表（只建过 `app_user` 的那条升级路径）。
        // 缺表时只跳过 ALTER 是不够的：库能打开、其它功能都正常，
        // 直到学生点「生成变式题」才炸，而那时报的是「no such table」,
        // 看起来像存储层坏了。这里直接按**最终形态**建出来。
        await db.execute('''
          CREATE TABLE IF NOT EXISTS ai_practice_question (
            id TEXT PRIMARY KEY,
            studentId TEXT NOT NULL DEFAULT '',
            sourceMistakeId TEXT NOT NULL DEFAULT '',
            knowledgePoint TEXT NOT NULL DEFAULT '',
            subject TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL DEFAULT '',
            content TEXT NOT NULL DEFAULT '',
            answer TEXT NOT NULL DEFAULT '',
            difficulty TEXT NOT NULL DEFAULT '基础',
            studentAnswer TEXT NOT NULL DEFAULT '',
            state TEXT NOT NULL DEFAULT 'pending',
            round INTEGER NOT NULL DEFAULT 1,
            createdAt TEXT,
            checkedAt TEXT,
            questionType TEXT NOT NULL DEFAULT 'solution',
            optionsJson TEXT NOT NULL DEFAULT '[]',
            figureJson TEXT
          )
        ''');
      }
    }

    if (oldVersion < 26) {
      // 作业的实际用时（秒）。
      //
      // 默认 0 = 「从来没计过时」。**不回填**：这个版本之前根本没有计时功能，
      // 把 `estimatedMinutes * 60` 填进去等于伪造一份「孩子实际用了多久」的记录，
      // 而这份数字接下来会进家长端与学习报告 —— 假数据比空着坏得多。
      //
      // 与 v24 同一条护栏：先问表在不在。极简老库（只建过 `app_user` 的那条
      // 升级路径）里 `ALTER TABLE homework` 会抛 `no such table`，
      // 而它发生在 `openDatabase` 期间 —— 后果是整个库打不开。
      if (await _hasTable(db, 'homework') &&
          !await _hasColumn(db, 'homework', 'actualSeconds')) {
        await db.execute(
          'ALTER TABLE homework '
          'ADD COLUMN actualSeconds INTEGER NOT NULL DEFAULT 0',
        );
      }
    }

    if (oldVersion < 27) {
      // 知识点提示（本机缓存）+ 应用设置（本机偏好）。
      //
      // 两张表都**只在本机存在**，不进服务端：
      //  · `knowledge_tip` 是从「本机这份错题池」一次归纳出来的快照，
      //    跟着设备走才对 —— 写进云库会让 A 的提示出现在 B 的计时页；
      //  · `app_setting` 里放的是「这台手机上的提醒阈值」，
      //    换设备时孩子本来就该按新设备的节奏重新设一次。
      //
      // 都用 `IF NOT EXISTS`：这条迁移可能在一台已经手工建过表的机器上重跑，
      // 报错在 `openDatabase` 里就等于整个库打不开。
      await db.execute('''
        CREATE TABLE IF NOT EXISTS knowledge_tip (
          id TEXT PRIMARY KEY,
          studentId TEXT NOT NULL DEFAULT '',
          subject TEXT NOT NULL DEFAULT '',
          knowledgePoint TEXT NOT NULL DEFAULT '',
          text TEXT NOT NULL DEFAULT '',
          source TEXT NOT NULL DEFAULT 'rule',
          sortOrder INTEGER NOT NULL DEFAULT 0,
          generatedAt TEXT NOT NULL DEFAULT '',
          signature TEXT NOT NULL DEFAULT ''
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_knowledge_tip_scope '
        'ON knowledge_tip(studentId, subject)',
      );
      await db.execute('''
        CREATE TABLE IF NOT EXISTS app_setting (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL DEFAULT ''
        )
      ''');
    }

    if (oldVersion < 28) {
      // 专注计时流水（作业 / 计划 / 临时打卡共用）。
      //
      // 与 `knowledge_tip`、`app_setting` 不同，这张表**要上云**：
      // 「今天读了多久」换设备也得答得出来。
      // `IF NOT EXISTS` 的理由同上 —— 报错在 `openDatabase` 里 = 整个库打不开。
      await db.execute('''
        CREATE TABLE IF NOT EXISTS focus_session (
          id TEXT PRIMARY KEY,
          studentId TEXT NOT NULL DEFAULT '',
          kind TEXT NOT NULL DEFAULT 'free',
          sourceId TEXT NOT NULL DEFAULT '',
          title TEXT NOT NULL DEFAULT '',
          date TEXT NOT NULL DEFAULT '',
          seconds INTEGER NOT NULL DEFAULT 0,
          startedAt TEXT,
          updatedAt TEXT
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_focus_session_student_date '
        'ON focus_session(studentId, date)',
      );
    }

    if (oldVersion < 29) {
      // 这道题在**原作业卷面上的题号**（「第 20 题 (4)」里的 `20(4)`）。
      //
      // 空串是合法值：老错题不知道题号，有些作业本来就没编号。
      // **不回填** —— 拿知识点去猜题号只会猜错，而这一列的全部价值就是准确。
      //
      // ⚠️ 先判表、再判列：这条 `ALTER` 跑在 `openDatabase` 里，
      //    抛一次错 = 整个库打不开（老库可能根本没有这张表）。
      if (await _hasTable(db, 'review_mistake') &&
          !await _hasColumn(db, 'review_mistake', 'questionNo')) {
        await db.execute(
          'ALTER TABLE review_mistake '
          "ADD COLUMN questionNo TEXT NOT NULL DEFAULT ''",
        );
      }
      // 学生那次写出来的解题过程。空串是常态（选择/填空题没有过程），
      // 也**不回填** —— 老错题当时没记过，编不出来。
      if (await _hasTable(db, 'review_mistake') &&
          !await _hasColumn(db, 'review_mistake', 'studentProcess')) {
        await db.execute(
          'ALTER TABLE review_mistake '
          "ADD COLUMN studentProcess TEXT NOT NULL DEFAULT ''",
        );
      }
    }

    if (oldVersion < 31) {
      // 每日概念训练流水（v31）。
      //
      // 与 `knowledge_tip`、`app_setting` 一样**只在本机**：训练是孩子
      // 一个人在手机上完成的动作，跟着设备走；上云会让 A 学生的流水
      // 出现在 B 学生的选题加权里。
      // `IF NOT EXISTS` 同上 —— 报错在 `openDatabase` 里 = 整个库打不开。
      await db.execute('''
        CREATE TABLE IF NOT EXISTS drill_answer (
          id TEXT PRIMARY KEY,
          studentId TEXT NOT NULL DEFAULT '',
          questionId TEXT NOT NULL DEFAULT '',
          pattern TEXT NOT NULL DEFAULT '',
          knowledge TEXT NOT NULL DEFAULT '',
          tier TEXT NOT NULL DEFAULT '',
          chosenIndex INTEGER NOT NULL DEFAULT -1,
          correct INTEGER NOT NULL DEFAULT 0,
          date TEXT NOT NULL DEFAULT '',
          createdAt TEXT NOT NULL DEFAULT ''
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_drill_answer_student_date '
        'ON drill_answer(studentId, date)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_drill_answer_question '
        'ON drill_answer(questionId)',
      );
    }

    if (oldVersion < 32) {
      // 英语单词打卡（v32）。`IF NOT EXISTS` 同上：openDatabase 里抛错
      // 会让整个库打不开，而不是「只少一个新功能」。
      await _createWordCheckinTables(db);
    }
    if (oldVersion < 33) {
      // 行为扣分配置（v33）。纯新增，不回填历史流水 —— 老记录里的原因
      // 已经写了行为名，不需要凭空造一批配置行。
      await db.execute('''
        CREATE TABLE IF NOT EXISTS point_behavior (
          studentId TEXT NOT NULL,
          id TEXT NOT NULL,
          name TEXT NOT NULL DEFAULT '',
          points INTEGER NOT NULL DEFAULT 0,
          enabled INTEGER NOT NULL DEFAULT 1,
          builtin INTEGER NOT NULL DEFAULT 0,
          updatedAt TEXT,
          PRIMARY KEY (studentId, id)
        )
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_point_behavior_student
          ON point_behavior(studentId, enabled)
      ''');
    }
  }

  /// v32 两张表的**唯一建表定义**：onCreate 与 onUpgrade 共用。
  /// 分开写两份 DDL 的症状是「新装的机好用、升级上来的少了索引」。
  static Future<void> _createWordCheckinTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS word_entry_local (
        id TEXT PRIMARY KEY,
        studentId TEXT NOT NULL DEFAULT '',
        bookId TEXT NOT NULL DEFAULT '',
        unit TEXT NOT NULL DEFAULT '',
        unitOrder INTEGER NOT NULL DEFAULT 1,
        word TEXT NOT NULL DEFAULT '',
        phonetic TEXT NOT NULL DEFAULT '',
        primaryMeaning TEXT NOT NULL DEFAULT '',
        normalizedWord TEXT NOT NULL DEFAULT '',
        sortNo INTEGER NOT NULL DEFAULT 0,
        distractorPool TEXT NOT NULL DEFAULT '[]'
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_word_entry_local_scope '
      'ON word_entry_local(studentId, bookId, unitOrder, sortNo)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS word_answer (
        id TEXT PRIMARY KEY,
        studentId TEXT NOT NULL DEFAULT '',
        date TEXT NOT NULL DEFAULT '',
        wordId TEXT NOT NULL DEFAULT '',
        direction TEXT NOT NULL DEFAULT '',
        stem TEXT NOT NULL DEFAULT '',
        optionsJson TEXT NOT NULL DEFAULT '[]',
        answer TEXT NOT NULL DEFAULT '',
        picked TEXT NOT NULL DEFAULT '',
        correct INTEGER NOT NULL DEFAULT 0,
        word TEXT NOT NULL DEFAULT '',
        primaryMeaning TEXT NOT NULL DEFAULT '',
        bookId TEXT NOT NULL DEFAULT '',
        bookTitle TEXT NOT NULL DEFAULT '',
        unitMode TEXT NOT NULL DEFAULT '',
        currentUnit TEXT NOT NULL DEFAULT '',
        createdAt TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_word_answer_student_date '
      'ON word_answer(studentId, date)',
    );
  }

  /// 迁移里「这张表在不在」。
  ///
  /// 光判断列不够：`PRAGMA table_info(不存在的表)` 返回空列表而不是报错，
  /// 于是「表不存在」会表现得像「每一列都缺」，接下来那条 `ALTER TABLE`
  /// 就会把整个 `openDatabase` 炸掉。
  static Future<bool> _hasTable(Database db, String table) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [table],
    );
    return rows.isNotEmpty;
  }

  /// 迁移里「这一列在不在」，用来让加列可以重跑。
  ///
  /// 表名直接拼进 PRAGMA —— SQLite 不支持把它参数化。这里拼的都是
  /// 本文件里的字面量常量，不来自任何外部输入。
  static Future<bool> _hasColumn(
    Database db,
    String table,
    String column,
  ) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows.any((row) => row['name'] == column);
  }

  /// 第二个演示孩子 stu_002（林小桐）的业务数据，幂等插入
  Future<void> _seedSecondChildDemoData(DatabaseExecutor db) async {
    final now = DateTime.now();
    Future<void> insert(String table, Map<String, dynamic> row) =>
        db.insert(table, row, conflictAlgorithm: ConflictAlgorithm.ignore);

    await insert('homework', {
      'id': 'hw_101',
      'title': '科学观察日记',
      'subject': '科学',
      'imageUrl': 'https://picsum.photos/seed/science/600/400',
      'dueAt': now.add(const Duration(hours: 5)).toIso8601String(),
      'estimatedMinutes': 35,
      'status': HomeworkStatus.pending.name,
      'wrongCount': 0,
      'aiEnabled': 1,
      'userRole': 'student',
      'studentId': 'stu_002',
    });
    await insert('homework', {
      'id': 'hw_102',
      'title': '数学口算练习',
      'subject': '数学',
      'imageUrl': 'https://picsum.photos/seed/math2/600/400',
      'dueAt': now.add(const Duration(days: 1)).toIso8601String(),
      'estimatedMinutes': 20,
      'status': HomeworkStatus.finished.name,
      'wrongCount': 1,
      'aiEnabled': 1,
      'userRole': 'student',
      'studentId': 'stu_002',
    });

    await insert('workout_plan', {
      'id': 'wp_101',
      'title': '每日跳绳',
      'project': '跳绳',
      'weekdays': '[二,四,六]',
      'targetMinutes': 20,
      'isActive': 1,
      'startDate': now.subtract(const Duration(days: 7)).toIso8601String(),
      'endDate': now.add(const Duration(days: 60)).toIso8601String(),
      'startTime': '17:30',
      'endTime': '17:50',
      'cycleType': 'weekly',
      'customWeekdays': '[二,四,六]',
      'studentId': 'stu_002',
    });
    await insert('workout_record', {
      'id': 'wr_101',
      'project': '跳绳',
      'startAt': now.subtract(const Duration(hours: 3)).toIso8601String(),
      'endAt': now
          .subtract(const Duration(hours: 2, minutes: 40))
          .toIso8601String(),
      'minutes': 20,
      'feedback': '连续跳了 3 组，很有进步。',
      'planId': 'wp_101',
      'studentId': 'stu_002',
    });

    await insert('review_mistake', {
      'id': 'rm_101',
      'subject': '数学',
      'title': '乘法竖式进位',
      'originalAnswer': '24 × 13 = 242',
      'wrongReason': '进位忘记加一',
      'createdAt': now.subtract(const Duration(days: 1)).toIso8601String(),
      'state': ReviewState.pending.name,
      'studentId': 'stu_002',
      'knowledgePoint': '竖式进位',
      'wrongCount': 1,
      'lastWrongAt': now.subtract(const Duration(days: 1)).toIso8601String(),
      'sourceHomeworkTitle': '数学口算练习',
      'masteredBySelf': 0,
      'reviewRound': 0,
    });

    await insert('wish', {
      'id': 'w_101',
      'title': '新画笔套装',
      'description': '想要一套水彩画笔，周末用来画风景画。',
      'isPublic': 1,
      'parentConfirmed': 0,
      'studentConfirmed': 0,
      'isArchived': 0,
      'userRole': 'student',
      'studentId': 'stu_002',
      'expectedDate': now.add(const Duration(days: 2)).toIso8601String(),
    });

    await insert('study_plan', {
      'id': 'sp_101',
      'title': '每日练字',
      'content': '每天练字帖一页，注意坐姿和笔顺。',
      'startAt': now.toIso8601String(),
      'endAt': now.add(const Duration(days: 7)).toIso8601String(),
      'type': '作业',
      'status': StudyPlanStatus.pendingStudentConfirm.name,
      'userRole': 'parent',
      'studentId': 'stu_002',
      'cycleType': 'daily',
    });
    await insert('study_plan', {
      'id': 'sp_102',
      'title': '周末阅读',
      'content': '周末阅读课外书 30 分钟，并写一段读书笔记。',
      'startAt': now.subtract(const Duration(days: 3)).toIso8601String(),
      'endAt': now.add(const Duration(days: 28)).toIso8601String(),
      'type': '阅读',
      'status': StudyPlanStatus.active.name,
      'userRole': 'student',
      'studentId': 'stu_002',
      'cycleType': 'weekly',
      'customWeekdays': '六,日',
    });
  }

  // v5：学习计划每日打卡（study_plan_checkin）
  static const String _webStoreCacheKey = 'easy_learn_web_store_v5';

  void _loadWebStore() {
    if (!kIsWeb) return;
    final raw = webStorage.read(_webStoreCacheKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      decoded.forEach((key, value) {
        _webStore[key] = (value as List<dynamic>)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      });
    } catch (e) {
      debugPrint('Web 存储数据损坏，已重置为演示数据：$e');
      _webStore.clear();
    }
  }

  void _saveWebStore() {
    if (!kIsWeb) return;
    try {
      webStorage.write(_webStoreCacheKey, jsonEncode(_webStore));
    } catch (e) {
      // 写入失败（如配额超限）不能静默吞掉，否则表现为数据“丢失”
      debugPrint('Web 存储写入失败：$e');
    }
  }

  /// 把 localStorage 里的真实数据读进内存；**只在演示环境下**、且内存里
  /// 一份作业都没有时，才补一批演示数据。
  ///
  /// ⚠️ `_loadWebStore()` 与「灌演示数据」是**两件事**，不要合并判断：
  /// 前者读的是用户自己的数据，后者才是种子。把 `_loadWebStore()` 也放进
  /// 开关里，真实 Web 用户会**所有列表恒空且不报错** —— 这正是最容易改错的一行。
  Future<void> _ensureWebSeed({bool demoData = DemoSeed.enabled}) async {
    if (!kIsWeb) return;
    _loadWebStore();
    if (!demoData) return;
    if (_webStore['homework'] != null) return;

    final now = DateTime.now();
    // 演示作业的截止时间统一落到「今天」的稍晚时刻，而不是 now + 6h ——
    // 作业列表是按截止日期筛「当天」的（`homework_tab` 里 `_isSameDay`），
    // 过了傍晚再打开演示，now+6h 已经是明天，那条作业干脆看不见，
    // 表现为「演示数据缺了一条」而不是「筛选在按日期工作」。
    final todayDue = DateTime(now.year, now.month, now.day, 23, 30);

    _webStore['homework'] = [
      {
        'id': 'hw_001',
        'title': '数学作业A',
        'subject': '数学',
        'imageUrl': 'https://picsum.photos/seed/math/600/400',
        'dueAt': todayDue.toIso8601String(),
        'estimatedMinutes': 30,
        'status': HomeworkStatus.pending.name,
        'wrongCount': 0,
        'aiEnabled': 1,
        'userRole': 'student',
        'studentId': 'stu_001',
        'submittedAt': null,
        'checkedAt': null,
        'score': null,
        'summary': '',
        'imageCount': 0,
        'submitBatchId': '',
      },
      {
        'id': 'hw_002',
        'title': '语文阅读理解',
        'subject': '语文',
        'imageUrl': 'https://picsum.photos/seed/chinese/600/400',
        'dueAt': todayDue.toIso8601String(),
        'estimatedMinutes': 25,
        'status': HomeworkStatus.needFix.name,
        'wrongCount': 1,
        'aiEnabled': 1,
        'userRole': 'student',
        'studentId': 'stu_001',
        'submittedAt': now
            .subtract(const Duration(hours: 5))
            .toIso8601String(),
        'checkedAt': now.subtract(const Duration(hours: 5)).toIso8601String(),
        'score': 78,
        'summary': '整体思路清晰，第 2 题的论证层次需要补充，建议回看课文第 4 段的写法。',
        'imageCount': 0,
        'submitBatchId': 'batch_seed_hw_002',
        // 种子数据的批改结果本来就由本地实现产出（演示环境默认完全离线），
        // 所以如实标 local，而不是让它在家长端冒充模型输出。
        'gradingSource': GradingSource.local,
      },
      {
        'id': 'hw_003',
        // 标题改过：原来叫「英语单词抄写」，而抄写现在默认**不批改**，
        // 这一行要演示的却是「要批改但这台环境没开 AI」—— 标题和口径当场打架，
        // 演示时会让人以为系统还认为抄写要批。换成书面作业（练习册既有题干
        // 也有答案），口径就一致了。
        //
        // ⚠️ `status` 原先是 `timeout`，2026-09-28 随该状态一起废弃（见 B26）。
        // 现在它是一条**普通的「还没交」**作业：`dueAt` 落在 2 小时前并不影响
        // 任何显示 —— 系统不再拿这个时间判断什么，界面也不再提它。
        'title': '英语练习册P22-P23',
        'subject': '英语',
        'imageUrl': 'https://picsum.photos/seed/english/600/400',
        'dueAt': now.subtract(const Duration(hours: 2)).toIso8601String(),
        'estimatedMinutes': 20,
        'status': HomeworkStatus.pending.name,
        'wrongCount': 0,
        'aiEnabled': 0,
        // 显式写出来，而不是靠列默认值：这条演示的是「这份作业要批改，
        // 但当前环境没开 AI」。不写也一样（列默认 1），但那是**碰巧**对 ——
        // 哪天有人动了列默认值，这条演示就会安静地变成另一种形态。
        'needsGrading': 1,
        'userRole': 'student',
        'studentId': 'stu_001',
        'submittedAt': null,
        'checkedAt': null,
        'score': null,
        'summary': '',
        'imageCount': 0,
        'submitBatchId': '',
      },
      {
        'id': 'hw_004',
        'title': '朗读课文第5课',
        'subject': '语文',
        'imageUrl': 'https://picsum.photos/seed/reading/600/400',
        'dueAt': todayDue.toIso8601String(),
        'estimatedMinutes': 10,
        'status': HomeworkStatus.pending.name,
        'wrongCount': 0,
        'aiEnabled': 1,
        // 朗读是过程型作业，没有可判的产出：交上来就算完成，不走批改。
        //
        // 留一条这样的演示数据，是为了让「不需要批改」这个形态在演示环境里
        // **看得见** —— 否则这个开关只存在于文档和测试里，而它恰恰是
        // 一个必须让学生自己认出来的东西（系统默认猜错时，他得知道能改）。
        'needsGrading': 0,
        'userRole': 'student',
        'studentId': 'stu_001',
        'submittedAt': null,
        'checkedAt': null,
        'score': null,
        'summary': '',
        'imageCount': 0,
        'submitBatchId': '',
      },
      {
        'id': 'hw_101',
        'title': '科学观察日记',
        'subject': '科学',
        'imageUrl': 'https://picsum.photos/seed/science/600/400',
        'dueAt': now.add(const Duration(hours: 5)).toIso8601String(),
        'estimatedMinutes': 35,
        'status': HomeworkStatus.pending.name,
        'wrongCount': 0,
        'aiEnabled': 1,
        'userRole': 'student',
        'studentId': 'stu_002',
        'submittedAt': null,
        'checkedAt': null,
        'score': null,
        'summary': '',
        'imageCount': 0,
        'submitBatchId': '',
      },
      {
        'id': 'hw_102',
        'title': '数学口算练习',
        'subject': '数学',
        'imageUrl': 'https://picsum.photos/seed/math2/600/400',
        'dueAt': now.add(const Duration(days: 1)).toIso8601String(),
        'estimatedMinutes': 20,
        'status': HomeworkStatus.finished.name,
        'wrongCount': 0,
        'aiEnabled': 1,
        'userRole': 'student',
        'studentId': 'stu_002',
        'submittedAt': now
            .subtract(const Duration(hours: 8))
            .toIso8601String(),
        'checkedAt': now.subtract(const Duration(hours: 8)).toIso8601String(),
        'score': 96,
        'summary': '口算全部正确，速度和准确率都很好，继续保持。',
        'imageCount': 0,
        'submitBatchId': 'batch_seed_hw_102',
        'gradingSource': GradingSource.local,
      },
    ];

    _webStore['app_user'] = [
      {
        'id': 'stu_001',
        'name': '林小宇',
        'phone': '13800000001',
        'role': 'student',
        'avatar': '👦',
        'password': 'abc123',
        'wechatOpenId': null,
        'gender': '男',
        'grade': '六年级',
        'hobbies': '阅读,跑步',
        'bio': '',
        'passwordUpdatedAt': now
            .subtract(const Duration(days: 30))
            .toIso8601String(),
      },
      {
        'id': 'stu_002',
        'name': '林小桐',
        'phone': '13800000003',
        'role': 'student',
        'avatar': '👧',
        'password': 'abc123',
        'wechatOpenId': null,
        'gender': '女',
        'grade': '四年级',
        'hobbies': '画画,跳绳',
        'bio': '',
        'passwordUpdatedAt': now
            .subtract(const Duration(days: 20))
            .toIso8601String(),
      },
      {
        'id': 'par_001',
        'name': '王老师',
        'phone': '13800000002',
        'role': 'parent',
        'avatar': '👨',
        'password': 'abc123',
        'wechatOpenId': 'mock-wechat-parent',
        'gender': '女',
        'grade': '',
        'hobbies': '阅读,运动',
        'bio': '',
        'passwordUpdatedAt': now
            .subtract(const Duration(days: 30))
            .toIso8601String(),
      },
    ];

    _webStore['relationship'] = [
      {
        'id': 'rel_001',
        'studentId': 'stu_001',
        'parentId': 'par_001',
        'senderId': 'par_001',
        'status': RelationshipStatus.active.name,
        'createdAt': now.subtract(const Duration(days: 2)).toIso8601String(),
      },
      {
        'id': 'rel_002',
        'studentId': 'stu_002',
        'parentId': 'par_001',
        'senderId': 'par_001',
        'status': RelationshipStatus.active.name,
        'createdAt': now.subtract(const Duration(days: 1)).toIso8601String(),
      },
    ];

    _webStore['chat_message'] = [
      {
        'id': 'msg_001',
        'relationshipId': 'rel_001',
        'senderId': 'par_001',
        'receiverId': 'stu_001',
        'content': '今天的作业完成得怎么样？有需要我陪你一起复习吗？',
        'createdAt': now
            .subtract(const Duration(minutes: 30))
            .toIso8601String(),
        'isRead': 0,
      },
      {
        'id': 'msg_101',
        'relationshipId': 'rel_002',
        'senderId': 'par_001',
        'receiverId': 'stu_002',
        'content': '小桐，今天的跳绳任务完成后记得打卡哦。',
        'createdAt': now
            .subtract(const Duration(minutes: 20))
            .toIso8601String(),
        'isRead': 0,
      },
    ];

    _webStore['workout_plan'] = [
      {
        'id': 'wp_001',
        'title': '每周跑步计划',
        'project': '跑步',
        'weekdays': '[一,三,五]',
        'targetMinutes': 30,
        'isActive': 1,
        'startDate': now.subtract(const Duration(days: 7)).toIso8601String(),
        'endDate': now.add(const Duration(days: 60)).toIso8601String(),
        'startTime': '07:00',
        'endTime': '07:30',
        'cycleType': 'weekly',
        'customWeekdays': '[一,三,五]',
        'studentId': 'stu_001',
      },
      {
        'id': 'wp_002',
        'title': '周末跳绳',
        'project': '跳绳',
        'weekdays': '[六,日]',
        'targetMinutes': 20,
        'isActive': 1,
        'startDate': now.subtract(const Duration(days: 7)).toIso8601String(),
        'endDate': now.add(const Duration(days: 60)).toIso8601String(),
        'startTime': '17:00',
        'endTime': '17:20',
        'cycleType': 'weekly',
        'customWeekdays': '[六,日]',
        'studentId': 'stu_001',
      },
      {
        'id': 'wp_101',
        'title': '每日跳绳',
        'project': '跳绳',
        'weekdays': '[二,四,六]',
        'targetMinutes': 20,
        'isActive': 1,
        'startDate': now.subtract(const Duration(days: 7)).toIso8601String(),
        'endDate': now.add(const Duration(days: 60)).toIso8601String(),
        'startTime': '17:30',
        'endTime': '17:50',
        'cycleType': 'weekly',
        'customWeekdays': '[二,四,六]',
        'studentId': 'stu_002',
      },
    ];

    _webStore['workout_record'] = [
      {
        'id': 'wr_001',
        'project': '跑步',
        'startAt': DateTime.now()
            .subtract(const Duration(hours: 2))
            .toIso8601String(),
        'endAt': DateTime.now()
            .subtract(const Duration(hours: 1))
            .toIso8601String(),
        'minutes': 30,
        'feedback': '今天状态不错，呼吸节奏稳定。',
        'planId': 'wp_001',
        'studentId': 'stu_001',
      },
      {
        'id': 'wr_101',
        'project': '跳绳',
        'startAt': DateTime.now()
            .subtract(const Duration(hours: 3))
            .toIso8601String(),
        'endAt': DateTime.now()
            .subtract(const Duration(hours: 2, minutes: 40))
            .toIso8601String(),
        'minutes': 20,
        'feedback': '连续跳了 3 组，很有进步。',
        'planId': 'wp_101',
        'studentId': 'stu_002',
      },
    ];

    _webStore['review_mistake'] = [
      {
        'id': 'rm_001',
        'subject': '数学',
        'title': '分数比较题',
        'originalAnswer': '3/4 > 2/3',
        'wrongReason': '分母处理错误',
        'createdAt': now.subtract(const Duration(days: 2)).toIso8601String(),
        'state': ReviewState.pending.name,
        'studentId': 'stu_001',
        'knowledgePoint': '分数计算',
        'wrongCount': 2,
        'lastWrongAt': now.subtract(const Duration(days: 2)).toIso8601String(),
        'sourceHomeworkTitle': '数学作业A',
        'masteredBySelf': 0,
        'reviewRound': 0,
      },
      {
        'id': 'rm_101',
        'subject': '数学',
        'title': '乘法竖式进位',
        'originalAnswer': '24 × 13 = 242',
        'wrongReason': '进位忘记加一',
        'createdAt': now.subtract(const Duration(days: 1)).toIso8601String(),
        'state': ReviewState.pending.name,
        'studentId': 'stu_002',
        'knowledgePoint': '竖式进位',
        'wrongCount': 1,
        'lastWrongAt': now.subtract(const Duration(days: 1)).toIso8601String(),
        'sourceHomeworkTitle': '数学口算练习',
        'masteredBySelf': 0,
        'reviewRound': 0,
      },
    ];

    _webStore['review_paper'] = [
      {
        'id': 'rp_001',
        'studentId': 'stu_001',
        'title': '数学错题重做卷 · 第1轮',
        'subject': '数学',
        'knowledgePoints': '分数计算',
        'status': PaperStatus.closed.name,
        'itemCount': 1,
        'passCount': 1,
        'failCount': 0,
        'createdAt': now.subtract(const Duration(days: 3)).toIso8601String(),
        'gradedAt': now.subtract(const Duration(days: 3)).toIso8601String(),
        'closedAt': now.subtract(const Duration(days: 3)).toIso8601String(),
        'filePath': '',
        'note': '历史轮次示例',
      },
    ];

    _webStore['wish'] = [
      {
        'id': 'w_001',
        'title': '新滑板',
        'description': '想购买一个更轻便的滑板，平时放学后锻炼。',
        'isPublic': 1,
        'parentConfirmed': 0,
        'studentConfirmed': 0,
        'isArchived': 0,
        'userRole': 'student',
        'studentId': 'stu_001',
        'expectedDate': now.add(const Duration(days: 1)).toIso8601String(),
      },
      {
        'id': 'w_002',
        'title': '私人目标',
        'description': '整理自己的学习计划和书桌。',
        'isPublic': 0,
        'parentConfirmed': 0,
        'studentConfirmed': 0,
        'isArchived': 0,
        'userRole': 'student',
        'studentId': 'stu_001',
        'expectedDate': now.add(const Duration(days: 7)).toIso8601String(),
      },
      {
        'id': 'w_101',
        'title': '新画笔套装',
        'description': '想要一套水彩画笔，周末用来画风景画。',
        'isPublic': 1,
        'parentConfirmed': 0,
        'studentConfirmed': 0,
        'isArchived': 0,
        'userRole': 'student',
        'studentId': 'stu_002',
        'expectedDate': now.add(const Duration(days: 2)).toIso8601String(),
      },
    ];

    _webStore['study_plan'] = [
      {
        'id': 'sp_001',
        'title': '数学强化训练',
        'content': '每天完成 20 道应用题，并总结错题。',
        'startAt': now.toIso8601String(),
        'endAt': now.add(const Duration(days: 5)).toIso8601String(),
        'type': '作业',
        'status': StudyPlanStatus.active.name,
        'userRole': 'student',
        'studentId': 'stu_001',
        'cycleType': 'daily',
        'customWeekdays': null,
      },
      {
        'id': 'sp_004',
        'title': '每日阅读30分钟',
        'content': '每天课外阅读 30 分钟，并在摘抄本记录好词好句。',
        'startAt': now.subtract(const Duration(days: 2)).toIso8601String(),
        'endAt': now.add(const Duration(days: 12)).toIso8601String(),
        'type': '阅读',
        'status': StudyPlanStatus.active.name,
        'userRole': 'parent',
        'studentId': 'stu_001',
        'cycleType': 'daily',
        'customWeekdays': null,
      },
      {
        'id': 'sp_003',
        'title': '英语背单词',
        'content': '每天背诵 20 个单词并复习。',
        'startAt': now.toIso8601String(),
        'endAt': now.add(const Duration(days: 4)).toIso8601String(),
        'type': '复习',
        'status': StudyPlanStatus.pendingStudentConfirm.name,
        'userRole': 'parent',
        'studentId': 'stu_001',
        'cycleType': 'daily',
        'customWeekdays': null,
      },
      {
        'id': 'sp_101',
        'title': '每日练字',
        'content': '每天练字帖一页，注意坐姿和笔顺。',
        'startAt': now.toIso8601String(),
        'endAt': now.add(const Duration(days: 7)).toIso8601String(),
        'type': '作业',
        'status': StudyPlanStatus.pendingStudentConfirm.name,
        'userRole': 'parent',
        'studentId': 'stu_002',
        'cycleType': 'daily',
        'customWeekdays': null,
      },
      {
        'id': 'sp_102',
        'title': '周末阅读',
        'content': '周末阅读课外书 30 分钟，并写一段读书笔记。',
        'startAt': now.subtract(const Duration(days: 3)).toIso8601String(),
        'endAt': now.add(const Duration(days: 28)).toIso8601String(),
        'type': '阅读',
        'status': StudyPlanStatus.active.name,
        'userRole': 'student',
        'studentId': 'stu_002',
        'cycleType': 'weekly',
        'customWeekdays': '六,日',
      },
    ];

    // 学习计划打卡演示数据：昨日均已打卡，今日待打卡
    final yesterdayKey = studyPlanDateKey(
      now.subtract(const Duration(days: 1)),
    );
    _webStore['study_plan_checkin'] = [
      {
        'id': 'spc_001',
        'planId': 'sp_001',
        'studentId': 'stu_001',
        'date': yesterdayKey,
        'createdAt': now.subtract(const Duration(days: 1)).toIso8601String(),
      },
      {
        'id': 'spc_002',
        'planId': 'sp_004',
        'studentId': 'stu_001',
        'date': yesterdayKey,
        'createdAt': now.subtract(const Duration(days: 1)).toIso8601String(),
      },
    ];

    _webStore['app_notification'] = [
      {
        'id': 'n_001',
        'title': '作业提醒',
        'body': '数学作业还未完成，距离截止时间仅剩 2 小时。',
        'createdAt': now.toIso8601String(),
        'isRead': 0,
      },
      {
        'id': 'n_002',
        'title': '复习完成',
        'body': '英语单词复习已完成并记录在错题库中。',
        'createdAt': now.subtract(const Duration(hours: 3)).toIso8601String(),
        'isRead': 1,
      },
    ];

    _saveWebStore();
  }

  /// 演示种子数据的入口。**默认一个字节都不写**（开关见 `demo_seed.dart`）。
  ///
  /// 为什么不「只去掉演示作业、账号照旧补」：`app_user` 里那三个账号就是
  /// 「别人的孩子」本身 —— 家长端的关系列表读的正是它们。留账号只去掉作业，
  /// 是把症状从「看到别人的孩子和别人的作业」变成「看到别人的孩子但作业是空的」，
  /// 更难解释，也不是更安全。
  Future<void> seedIfEmpty({bool demoData = DemoSeed.enabled}) async {
    if (kIsWeb) {
      await _ensureWebSeed(demoData: demoData);
      return;
    }

    // 真实环境到这里就结束：连默认账号都不补。
    if (!demoData) return;

    final db = await database;

    // 默认账号与结伴关系必须和业务数据一起准备好。
    // 它们原先只在 findUserById / findUserByPhone 里按需插入，等于把
    // 「演示数据是否完整」绑在了「谁先发起一次用户查询」上：学生先登录时
    // 种子业务数据被写入，但关系表还是空的，家长端就会查不到任何孩子。
    await _ensureDefaultUsers(db);

    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM homework'),
    );
    if (count != null && count > 0) return;

    final now = DateTime.now();
    // 今天的 23:30，而不是 `now.add(hours: N)`：作业列表按**当天**筛
    // （`_isSameDay(item.dueAt, selectedDate)`），傍晚跑演示时
    // `now.add(hours: 20)` 会落到明天，那条演示数据就从列表里消失了。
    // Web 与原生两个种子必须同口径 —— 只修一边，症状就是「手机上看得见、
    // 浏览器里看不见」（或反过来），而两边代码都是对的。
    final todayDue = DateTime(now.year, now.month, now.day, 23, 30);

    await db.insert('homework', {
      'id': 'hw_001',
      'title': '数学作业A',
      'subject': '数学',
      'imageUrl': 'https://picsum.photos/seed/math/600/400',
      'dueAt': todayDue.toIso8601String(),
      'estimatedMinutes': 30,
      'status': HomeworkStatus.pending.name,
      'wrongCount': 0,
      'aiEnabled': 1,
      'userRole': 'student',
      'studentId': 'stu_001',
      'summary': '',
      'imageCount': 0,
      'submitBatchId': '',
    });

    await db.insert('homework', {
      'id': 'hw_002',
      'title': '语文阅读理解',
      'subject': '语文',
      'imageUrl': 'https://picsum.photos/seed/chinese/600/400',
      'dueAt': todayDue.toIso8601String(),
      'estimatedMinutes': 25,
      'status': HomeworkStatus.needFix.name,
      'wrongCount': 1,
      'aiEnabled': 1,
      'userRole': 'student',
      'studentId': 'stu_001',
      'submittedAt': now.subtract(const Duration(hours: 5)).toIso8601String(),
      'checkedAt': now.subtract(const Duration(hours: 5)).toIso8601String(),
      'score': 78,
      'summary': '整体思路清晰，第 2 题的论证层次需要补充，建议回看课文第 4 段的写法。',
      'imageCount': 0,
      'submitBatchId': 'batch_seed_hw_002',
      'gradingSource': GradingSource.local,
    });

    await db.insert('homework', {
      'id': 'hw_003',
      // 与 Web 端种子同一条改动：抄写现在默认不批改，而这条要演示的是
      // 「要批改但环境没开 AI」，标题必须换成书面作业才不会自相矛盾。
      // （它的 `status` 原先是 `timeout`，2026-09-28 随该状态废弃，见 B26 ——
      //   现在就是一条普通的「还没交」作业。）
      'title': '英语练习册P22-P23',
      'subject': '英语',
      'imageUrl': 'https://picsum.photos/seed/english/600/400',
      'dueAt': now.subtract(const Duration(hours: 2)).toIso8601String(),
      'estimatedMinutes': 20,
      'status': HomeworkStatus.pending.name,
      'wrongCount': 0,
      'aiEnabled': 0,
      'needsGrading': 1,
      'userRole': 'student',
      'studentId': 'stu_001',
      'summary': '',
      'imageCount': 0,
      'submitBatchId': '',
    });

    await db.insert('homework', {
      'id': 'hw_004',
      'title': '朗读课文第5课',
      'subject': '语文',
      'imageUrl': 'https://picsum.photos/seed/reading/600/400',
      'dueAt': todayDue.toIso8601String(),
      'estimatedMinutes': 10,
      'status': HomeworkStatus.pending.name,
      'wrongCount': 0,
      'aiEnabled': 1,
      // 朗读是过程型作业，没有可判的产出：交上来就算完成，不走批改。
      // 与 Web 端种子保持一致（两边都要能看到这个形态）。
      'needsGrading': 0,
      'userRole': 'student',
      'studentId': 'stu_001',
      'summary': '',
      'imageCount': 0,
      'submitBatchId': '',
    });

    await db.insert('workout_plan', {
      'id': 'wp_001',
      'title': '每周跑步计划',
      'project': '跑步',
      'weekdays': '[一,三,五]',
      'targetMinutes': 30,
      'isActive': 1,
      'studentId': 'stu_001',
    });

    await db.insert('workout_plan', {
      'id': 'wp_002',
      'title': '周末跳绳',
      'project': '跳绳',
      'weekdays': '[六,日]',
      'targetMinutes': 20,
      'isActive': 1,
      'studentId': 'stu_001',
    });

    await db.insert('workout_record', {
      'id': 'wr_001',
      'project': '跑步',
      'startAt': DateTime.now()
          .subtract(const Duration(hours: 2))
          .toIso8601String(),
      'endAt': DateTime.now()
          .subtract(const Duration(hours: 1))
          .toIso8601String(),
      'minutes': 30,
      'feedback': '今天状态不错，呼吸节奏稳定。',
      'studentId': 'stu_001',
    });

    await db.insert('review_mistake', {
      'id': 'rm_001',
      'subject': '数学',
      'title': '分数比较题',
      'originalAnswer': '3/4 > 2/3',
      'wrongReason': '分母处理错误',
      'createdAt': now.subtract(const Duration(days: 2)).toIso8601String(),
      'state': ReviewState.pending.name,
      'studentId': 'stu_001',
      'homeworkId': '',
      'knowledgePoint': '分数计算',
      'wrongCount': 2,
      'lastWrongAt': now.subtract(const Duration(days: 2)).toIso8601String(),
      'sourceHomeworkTitle': '数学作业A',
      'masteredBySelf': 0,
      'reviewRound': 0,
    });

    // 与 hw_002（待更正）配套，让家长端作业详情一进去就能看到错题明细
    await db.insert('review_mistake', {
      'id': 'rm_002',
      'subject': '语文',
      'title': '阅读理解 · 第 2 题论证层次',
      'originalAnswer': '只写了结论，没有引用课文原句作为依据。',
      'wrongReason': '论证缺少文本依据，需要按「观点 + 原文 + 分析」三层展开。',
      'createdAt': now.subtract(const Duration(hours: 5)).toIso8601String(),
      'state': ReviewState.pending.name,
      'studentId': 'stu_001',
      'homeworkId': 'hw_002',
      'knowledgePoint': '阅读理解层次',
      'wrongCount': 1,
      'lastWrongAt': now.subtract(const Duration(hours: 5)).toIso8601String(),
      'sourceHomeworkTitle': '语文阅读理解',
      'masteredBySelf': 0,
      'reviewRound': 0,
    });

    // 一条已毕业的错题，用来演示「已掌握档案」与历史复习轮次。
    await db.insert('review_mistake', {
      'id': 'rm_003',
      'subject': '英语',
      'title': '单词拼写 · environment',
      'originalAnswer': 'enviroment',
      'wrongReason': '漏写中间的 n，拼读时没有按音节切分。',
      'createdAt': now.subtract(const Duration(days: 6)).toIso8601String(),
      'state': ReviewState.mastered.name,
      'studentId': 'stu_001',
      'homeworkId': '',
      'knowledgePoint': '单词拼写',
      'wrongCount': 2,
      'lastWrongAt': now.subtract(const Duration(days: 6)).toIso8601String(),
      'sourceHomeworkTitle': '英语 Unit 3 听写',
      'masteredAt': now.subtract(const Duration(days: 3)).toIso8601String(),
      'masteredBySelf': 0,
      'reviewRound': 1,
      'lastReviewedAt': now.subtract(const Duration(days: 3)).toIso8601String(),
    });

    await db.insert('review_paper', {
      'id': 'rp_001',
      'studentId': 'stu_001',
      'title': '英语错题重做卷 · 第1轮',
      'subject': '英语',
      'knowledgePoints': '单词拼写',
      'status': PaperStatus.closed.name,
      'itemCount': 1,
      'passCount': 1,
      'failCount': 0,
      'createdAt': now.subtract(const Duration(days: 3)).toIso8601String(),
      'exportedAt': now.subtract(const Duration(days: 3)).toIso8601String(),
      'submittedAt': now.subtract(const Duration(days: 3)).toIso8601String(),
      'gradedAt': now.subtract(const Duration(days: 3)).toIso8601String(),
      'closedAt': now.subtract(const Duration(days: 3)).toIso8601String(),
      'filePath': '',
      'note': '历史轮次示例',
    });

    await db.insert('review_paper_item', {
      'id': 'rpi_001',
      'paperId': 'rp_001',
      'mistakeId': 'rm_003',
      'subject': '英语',
      'knowledgePoint': '单词拼写',
      'questionTitle': '单词拼写 · environment',
      'questionBody': '拼写单词：环境 / 周围',
      'originalAnswer': 'enviroment',
      'wrongReason': '漏写中间的 n，拼读时没有按音节切分。',
      'answerKey': 'environment',
      'sortOrder': 0,
      'studentAnswer': 'environment',
      'result': PaperItemResult.correct.name,
      'photoPath': '',
      'comment': '拼写正确，注意按音节记忆。',
      'checkedAt': now.subtract(const Duration(days: 3)).toIso8601String(),
    });

    await db.insert('wish', {
      'id': 'w_001',
      'title': '新滑板',
      'description': '想购买一个更轻便的滑板，平时放学后锻炼。',
      'isPublic': 1,
      'parentConfirmed': 0,
      'studentConfirmed': 0,
      'isArchived': 0,
      'userRole': 'student',
      'studentId': 'stu_001',
    });

    await db.insert('wish', {
      'id': 'w_002',
      'title': '私人目标',
      'description': '整理自己的学习计划和书桌。',
      'isPublic': 0,
      'parentConfirmed': 0,
      'studentConfirmed': 0,
      'isArchived': 0,
      'userRole': 'student',
      'studentId': 'stu_001',
    });

    await db.insert('study_plan', {
      'id': 'sp_001',
      'title': '数学强化训练',
      'content': '每天完成 20 道应用题，并总结错题。',
      'startAt': now.toIso8601String(),
      'endAt': now.add(const Duration(days: 5)).toIso8601String(),
      'type': '作业',
      'status': StudyPlanStatus.active.name,
      'userRole': 'student',
      'studentId': 'stu_001',
      'cycleType': 'daily',
    });

    await db.insert('study_plan', {
      'id': 'sp_003',
      'title': '英语背单词',
      'content': '每天背诵 20 个单词并复习。',
      'startAt': now.toIso8601String(),
      'endAt': now.add(const Duration(days: 4)).toIso8601String(),
      'type': '复习',
      'status': StudyPlanStatus.pendingStudentConfirm.name,
      'userRole': 'parent',
      'studentId': 'stu_001',
      'cycleType': 'daily',
    });

    await db.insert('study_plan', {
      'id': 'sp_004',
      'title': '每日阅读30分钟',
      'content': '每天课外阅读 30 分钟，并在摘抄本记录好词好句。',
      'startAt': now.subtract(const Duration(days: 2)).toIso8601String(),
      'endAt': now.add(const Duration(days: 12)).toIso8601String(),
      'type': '阅读',
      'status': StudyPlanStatus.active.name,
      'userRole': 'parent',
      'studentId': 'stu_001',
      'cycleType': 'daily',
    });

    final yesterday = now.subtract(const Duration(days: 1));
    for (final entry in {'sp_001': 'spc_001', 'sp_004': 'spc_002'}.entries) {
      await db.insert('study_plan_checkin', {
        'id': entry.value,
        'planId': entry.key,
        'studentId': 'stu_001',
        'date': studyPlanDateKey(yesterday),
        'createdAt': yesterday.toIso8601String(),
      });
    }

    await db.insert('app_notification', {
      'id': 'n_001',
      'title': '作业提醒',
      'body': '数学作业还未完成，距离截止时间仅剩 2 小时。',
      'createdAt': now.toIso8601String(),
      'isRead': 0,
    });
    await db.insert('app_notification', {
      'id': 'n_002',
      'title': '复习完成',
      'body': '英语单词复习已完成并记录在错题库中。',
      'createdAt': now.subtract(const Duration(hours: 3)).toIso8601String(),
      'isRead': 1,
    });

    // 第二个演示孩子 stu_002 的业务数据
    await _seedSecondChildDemoData(db);
  }

  @override
  Future<List<HomeworkItem>> queryHomework(String userRole) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = (_webStore['homework'] ?? const <Map<String, dynamic>>[])
          .where((row) => row['userRole'] == userRole)
          .toList();
      return rows.map(_homeworkFromMap).toList();
    }

    final db = await database;
    final rows = await db.query(
      'homework',
      where: 'userRole = ?',
      whereArgs: [userRole],
    );
    return rows.map(_homeworkFromMap).toList();
  }

  /// 按学生ID集合查询作业（家长端按结伴孩子过滤）
  @override
  Future<List<HomeworkItem>> queryHomeworkByStudentIds(
    List<String> studentIds,
  ) async {
    if (studentIds.isEmpty) return <HomeworkItem>[];
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = (_webStore['homework'] ?? const <Map<String, dynamic>>[])
          .where(
            (row) =>
                studentIds.contains((row['studentId'] as String?) ?? 'stu_001'),
          )
          .toList();
      return rows.map(_homeworkFromMap).toList();
    }

    final db = await database;
    final placeholders = List.filled(studentIds.length, '?').join(',');
    final rows = await db.query(
      'homework',
      where: 'studentId IN ($placeholders)',
      whereArgs: studentIds,
    );
    return rows.map(_homeworkFromMap).toList();
  }

  /// 按 ID 集合查询用户（家长端获取结伴学生信息）
  @override
  Future<List<Map<String, dynamic>>> queryUsersByIds(List<String> ids) async {
    if (ids.isEmpty) return <Map<String, dynamic>>[];
    if (kIsWeb) {
      await _ensureWebSeed();
      return (_webStore['app_user'] ?? const <Map<String, dynamic>>[])
          .where((row) => ids.contains(row['id']))
          .map(Map<String, dynamic>.from)
          .toList();
    }
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.query(
      'app_user',
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    return rows.map(Map<String, dynamic>.from).toList();
  }

  @override
  Future<List<WorkoutPlan>> queryWorkoutPlans() async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['workout_plan'] ?? const <Map<String, dynamic>>[];
      return rows.map(_workoutPlanFromRow).toList();
    }

    final db = await database;
    final rows = await db.query('workout_plan');
    return rows.map(_workoutPlanFromRow).toList();
  }

  WorkoutPlan _workoutPlanFromRow(Map<String, dynamic> row) {
    final startDateStr = row['startDate'] as String?;
    final endDateStr = row['endDate'] as String?;
    return WorkoutPlan(
      id: row['id'] as String,
      title: row['title'] as String,
      project: row['project'] as String,
      weekdays: _parseWeekdayList(row['weekdays'] as String?),
      targetMinutes: row['targetMinutes'] as int,
      isActive: (row['isActive'] as int) == 1,
      startDate: startDateStr != null && startDateStr.isNotEmpty
          ? DateTime.parse(startDateStr)
          : null,
      endDate: endDateStr != null && endDateStr.isNotEmpty
          ? DateTime.parse(endDateStr)
          : null,
      startTime: (row['startTime'] as String?) ?? '08:00',
      endTime: (row['endTime'] as String?) ?? '09:00',
      cycleType: WorkoutCycleTypeX.fromName(
        (row['cycleType'] as String?) ?? 'weekly',
      ),
      customWeekdays: _parseWeekdayList(row['customWeekdays'] as String?),
      studentId: (row['studentId'] as String?) ?? '',
    );
  }

  List<String> _parseWeekdayList(String? raw) {
    if (raw == null || raw.isEmpty) return const <String>[];
    return raw
        .replaceAll('[', '')
        .replaceAll(']', '')
        .split(',')
        .where((e) => e.trim().isNotEmpty)
        .map((e) => e.trim())
        .toList();
  }

  @override
  Future<List<WorkoutRecord>> queryWorkoutRecords() async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows =
          _webStore['workout_record'] ?? const <Map<String, dynamic>>[];
      return rows.map(_workoutRecordFromRow).toList();
    }

    final db = await database;
    final rows = await db.query('workout_record');
    return rows.map(_workoutRecordFromRow).toList();
  }

  WorkoutRecord _workoutRecordFromRow(Map<String, dynamic> row) {
    return WorkoutRecord(
      id: row['id'] as String,
      project: row['project'] as String,
      start: DateTime.parse(row['startAt'] as String),
      end: DateTime.parse(row['endAt'] as String),
      minutes: row['minutes'] as int,
      feedback: row['feedback'] as String,
      planId: (row['planId'] as String?) ?? '',
      studentId: (row['studentId'] as String?) ?? '',
    );
  }

  @override
  Future<List<ReviewMistake>> queryReviewMistakes() async {
    // ⚠️ 排序在 Dart 里做、**不写 `order by createdAt`**：
    // sqlite 里 `createdAt` 存的是 ISO 字符串（字典序可用），而 Web 那份是
    // 内存表，两边各写一套就会漂。用同一个 [ReviewMistake.byNewestFirst]
    // 保证三种模式（服务端 / sqlite / Web）顺序一致。
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows =
          _webStore['review_mistake'] ?? const <Map<String, dynamic>>[];
      return rows.map(ReviewMistake.fromMap).toList()
        ..sort(ReviewMistake.byNewestFirst);
    }

    final db = await database;
    final rows = await db.query('review_mistake');
    return rows.map(ReviewMistake.fromMap).toList()
      ..sort(ReviewMistake.byNewestFirst);
  }

  /// 复习资料（试卷）。学生归属过滤在控制器层做。
  @override
  Future<List<ReviewPaper>> queryReviewPapers() async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['review_paper'] ?? const <Map<String, dynamic>>[];
      return rows.map(ReviewPaper.fromMap).toList();
    }
    final db = await database;
    final rows = await db.query('review_paper', orderBy: 'createdAt DESC');
    return rows.map(ReviewPaper.fromMap).toList();
  }

  /// 卷内题目（快照），按卷面顺序返回。
  @override
  Future<List<ReviewPaperItem>> queryReviewPaperItems(String paperId) async {
    if (paperId.isEmpty) return <ReviewPaperItem>[];
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = (_webStore['review_paper_item'] ??
              const <Map<String, dynamic>>[])
          .where((row) => row['paperId'] == paperId)
          .map(ReviewPaperItem.fromMap)
          .toList();
      rows.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      return rows;
    }
    final db = await database;
    final rows = await db.query(
      'review_paper_item',
      where: 'paperId = ?',
      whereArgs: [paperId],
      orderBy: 'sortOrder ASC',
    );
    return rows.map(ReviewPaperItem.fromMap).toList();
  }

  /// 作答证据。传 mistakeId 可只看某道题的历次作答（错题时间线用）。
  @override
  Future<List<ReviewAttempt>> queryReviewAttempts({String? mistakeId}) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = (_webStore['review_attempt'] ?? const <Map<String, dynamic>>[])
          .where(
            (row) => mistakeId == null || row['mistakeId'] == mistakeId,
          )
          .map(ReviewAttempt.fromMap)
          .toList();
      rows.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return rows;
    }
    final db = await database;
    final rows = await db.query(
      'review_attempt',
      where: mistakeId == null ? null : 'mistakeId = ?',
      whereArgs: mistakeId == null ? null : [mistakeId],
      orderBy: 'createdAt ASC',
    );
    return rows.map(ReviewAttempt.fromMap).toList();
  }

  /// 判定影子比对的明细。传 [studentId] 只看某个学生。
  ///
  /// 读不懂的行直接丢弃（见 [JudgementABRecord.fromMap]）：宁可少一条样本，
  /// 也不能让一行坏数据混进一致率的分母。
  @override
  Future<List<JudgementABRecord>> queryJudgementAB({
    String? studentId,
    String? mistakeId,
  }) async {
    List<Map<String, dynamic>> rows;
    if (kIsWeb) {
      await _ensureWebSeed();
      rows = (_webStore['judgement_ab'] ?? const <Map<String, dynamic>>[])
          .where(
            (row) =>
                (studentId == null || row['studentId'] == studentId) &&
                (mistakeId == null || row['mistakeId'] == mistakeId),
          )
          .toList();
    } else {
      final db = await database;
      final filters = <String>[
        if (studentId != null) 'studentId = ?',
        if (mistakeId != null) 'mistakeId = ?',
      ];
      final args = <String>[?studentId, ?mistakeId];
      rows = await db.query(
        'judgement_ab',
        where: filters.isEmpty ? null : filters.join(' AND '),
        whereArgs: args.isEmpty ? null : args,
        orderBy: 'createdAt ASC',
      );
    }
    return rows
        .map(JudgementABRecord.fromMap)
        .whereType<JudgementABRecord>()
        .toList();
  }

  /// 落一批比对记录。
  ///
  /// 为什么是批量而不是逐条：一次举一反三提交里有 3 道题要判，
  /// 逐条写就是 3 次事务 —— 而它们本来就是同一件事的产物。
  @override
  Future<void> insertJudgementABRecords(
    List<JudgementABRecord> records,
  ) async {
    if (records.isEmpty) return;
    if (kIsWeb) {
      await _ensureWebSeed();
      final store = _webStore.putIfAbsent(
        'judgement_ab',
        () => <Map<String, dynamic>>[],
      );
      for (final record in records) {
        store.insert(0, record.toMap());
      }
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      for (final record in records) {
        await txn.insert(
          'judgement_ab',
          record.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// 举一反三题目。
  @override
  Future<List<AiPracticeQuestion>> queryPracticeQuestions({
    String? sourceMistakeId,
  }) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = (_webStore['ai_practice_question'] ??
              const <Map<String, dynamic>>[])
          .where(
            (row) =>
                sourceMistakeId == null ||
                row['sourceMistakeId'] == sourceMistakeId,
          )
          .map(AiPracticeQuestion.fromMap)
          .toList();
      rows.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return rows;
    }
    final db = await database;
    final rows = await db.query(
      'ai_practice_question',
      where: sourceMistakeId == null ? null : 'sourceMistakeId = ?',
      whereArgs: sourceMistakeId == null ? null : [sourceMistakeId],
      orderBy: 'createdAt ASC',
    );
    return rows.map(AiPracticeQuestion.fromMap).toList();
  }

  /// 讲解留痕。
  @override
  Future<List<ExplainRecord>> queryExplainRecords({String? mistakeId}) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = (_webStore['explain_record'] ?? const <Map<String, dynamic>>[])
          .where((row) => mistakeId == null || row['mistakeId'] == mistakeId)
          .map(ExplainRecord.fromMap)
          .toList();
      rows.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return rows;
    }
    final db = await database;
    final rows = await db.query(
      'explain_record',
      where: mistakeId == null ? null : 'mistakeId = ?',
      whereArgs: mistakeId == null ? null : [mistakeId],
      orderBy: 'createdAt ASC',
    );
    return rows.map(ExplainRecord.fromMap).toList();
  }

  /// 总结报告。
  @override
  Future<List<ReviewSummary>> queryReviewSummaries() async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['review_summary'] ?? const <Map<String, dynamic>>[];
      return rows.map(ReviewSummary.fromMap).toList();
    }
    final db = await database;
    final rows = await db.query('review_summary', orderBy: 'generatedAt DESC');
    return rows.map(ReviewSummary.fromMap).toList();
  }

  @override
  Future<List<WishModel>> queryWishes(String userRole) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = (_webStore['wish'] ?? const <Map<String, dynamic>>[])
          .where((row) => row['userRole'] == userRole)
          .toList();
      return rows.map(_wishFromMap).toList();
    }

    final db = await database;
    final rows = await db.query(
      'wish',
      where: 'userRole = ?',
      whereArgs: [userRole],
    );
    return rows.map(_wishFromMap).toList();
  }

  @override
  Future<List<WishModel>> queryPublicWishes() async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = (_webStore['wish'] ?? const <Map<String, dynamic>>[])
          .where((row) => (row['isPublic'] as int) == 1)
          .toList();
      return rows.map(_wishFromMap).toList();
    }

    final db = await database;
    final rows = await db.query('wish', where: 'isPublic = ?', whereArgs: [1]);
    return rows.map(_wishFromMap).toList();
  }

  @override
  Future<List<WishModel>> queryPublicWishesByStudent(String studentId) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = (_webStore['wish'] ?? const <Map<String, dynamic>>[])
          .where(
            (row) =>
                (row['isPublic'] as int) == 1 && row['studentId'] == studentId,
          )
          .toList();
      return rows.map(_wishFromMap).toList();
    }

    final db = await database;
    final rows = await db.query(
      'wish',
      where: 'isPublic = ? AND studentId = ?',
      whereArgs: [1, studentId],
    );
    return rows.map(_wishFromMap).toList();
  }

  /// 查询所有未归档、未闭环的心愿（用于提醒检查）
  @override
  Future<List<WishModel>> queryUnfulfilledWishes() async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = (_webStore['wish'] ?? const <Map<String, dynamic>>[])
          .where((row) => (row['isArchived'] as int) == 0)
          .where(
            (row) =>
                !((row['parentConfirmed'] as int) == 1 &&
                    (row['studentConfirmed'] as int) == 1),
          )
          .toList();
      return rows.map(_wishFromMap).toList();
    }
    final db = await database;
    final rows = await db.query(
      'wish',
      where: 'isArchived = 0 AND NOT (parentConfirmed = 1 AND studentConfirmed = 1)',
    );
    return rows.map(_wishFromMap).toList();
  }

  WishModel _wishFromMap(Map<String, dynamic> row) {
    return WishModel(
      id: row['id'] as String,
      title: row['title'] as String,
      description: row['description'] as String,
      isPublic: (row['isPublic'] as int) == 1,
      parentConfirmed: (row['parentConfirmed'] as int) == 1,
      studentConfirmed: (row['studentConfirmed'] as int) == 1,
      isArchived: (row['isArchived'] as int) == 1,
      studentId: (row['studentId'] as String?) ?? '',
      expectedDate: row['expectedDate'] != null
          ? DateTime.tryParse(row['expectedDate'] as String)
          : null,
      // 老库升级上来的行没有这几列，取不到就是「不花积分、没申请过」。
      pointCost: (row['pointCost'] as num?)?.toInt() ?? 0,
      redeemRequestedAt: DateTime.tryParse(
        (row['redeemRequestedAt'] as String?) ?? '',
      ),
      redeemedAt: DateTime.tryParse((row['redeemedAt'] as String?) ?? ''),
      redeemRejectedAt: DateTime.tryParse(
        (row['redeemRejectedAt'] as String?) ?? '',
      ),
    );
  }

  @override
  Future<List<StudyPlanModel>> queryStudyPlans(String userRole) async {
    // 学生可见自己的全部计划（含家长发来待确认的）；家长仅看家长侧记录
    bool visible(Map<String, dynamic> row) =>
        userRole == 'student' || row['userRole'] == userRole;

    StudyPlanModel mapRow(Map<String, dynamic> row) {
      return StudyPlanModel(
        id: row['id'] as String,
        title: row['title'] as String,
        content: row['content'] as String,
        startAt: DateTime.parse(row['startAt'] as String),
        endAt: DateTime.parse(row['endAt'] as String),
        type: row['type'] as String,
        status: StudyPlanStatus.values.firstWhere(
          (e) => e.name == row['status'],
        ),
        studentId: (row['studentId'] as String?) ?? '',
        cycleType: WorkoutCycleTypeX.fromName(
          (row['cycleType'] as String?) ?? 'daily',
        ),
        customWeekdays: _parseWeekdayList(row['customWeekdays'] as String?),
        rejectReason: (row['rejectReason'] as String?) ?? '',
      );
    }

    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = (_webStore['study_plan'] ?? const <Map<String, dynamic>>[])
          .where(visible)
          .toList();
      return rows.map(mapRow).toList();
    }

    final db = await database;
    if (userRole == 'student') {
      final rows = await db.query('study_plan');
      return rows.map(mapRow).toList();
    }
    final rows = await db.query(
      'study_plan',
      where: 'userRole = ?',
      whereArgs: [userRole],
    );
    return rows.map(mapRow).toList();
  }

  @override
  Future<Map<String, dynamic>?> findUserByPhone(String phone) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['app_user'] ?? const <Map<String, dynamic>>[];
      for (final row in rows) {
        if (row['phone'] == phone) return Map<String, dynamic>.from(row);
      }
      return null;
    }

    final db = await database;
    // 只在演示环境补默认账号（开关见 `demo_seed.dart`）。真实用户按手机号
    // 查不到就该查不到 ——「查一次账号就凭空多出一个演示账号」是最不该有的行为。
    if (DemoSeed.enabled) {
      await _ensureDefaultUsers(db);
    }
    final rows = await db.query(
      'app_user',
      where: 'phone = ?',
      whereArgs: [phone],
      limit: 1,
    );
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  @override
  Future<Map<String, dynamic>?> findUserByWechat(String openId) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['app_user'] ?? const <Map<String, dynamic>>[];
      for (final row in rows) {
        if (row['wechatOpenId'] == openId) {
          return Map<String, dynamic>.from(row);
        }
      }
      return null;
    }

    final db = await database;
    if (DemoSeed.enabled) {
      await _ensureDefaultUsers(db);
    }
    final rows = await db.query(
      'app_user',
      where: 'wechatOpenId = ?',
      whereArgs: [openId],
      limit: 1,
    );
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  @override
  Future<void> saveUser(Map<String, dynamic> user) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['app_user'] ??= <Map<String, dynamic>>[];
      final index = rows.indexWhere((row) => row['id'] == user['id']);
      if (index >= 0) {
        rows[index] = Map<String, dynamic>.from(user);
      } else {
        rows.add(Map<String, dynamic>.from(user));
      }
      _saveWebStore();
      return;
    }

    final db = await database;
    await db.insert(
      'app_user',
      user,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 改密码。见 [AuthDataSource.updatePassword] 的两个约束。
  ///
  /// 这里用 `db.update` 而不是 `saveUser`（后者是 replace 整行）：
  /// replace 会把没传的列**清成默认值**，而改密只需要动两列。
  /// 拿整行替换的写法改密码，会把 `hobbies` 之类的资料顺手抹掉 ——
  /// 和先前那个「空 hobbies 字符串崩登录」是同一类事故。
  @override
  Future<void> updatePassword({
    required String userId,
    required String newPassword,
    required String updatedAt,
  }) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['app_user'] ?? const <Map<String, dynamic>>[];
      final index = rows.indexWhere((row) => row['id'] == userId);
      if (index < 0) throw StateError('用户不存在：$userId');
      rows[index] = <String, dynamic>{
        ...rows[index],
        'password': newPassword,
        'passwordUpdatedAt': updatedAt,
      };
      _saveWebStore();
      return;
    }

    final db = await database;
    final changed = await db.update(
      'app_user',
      <String, dynamic>{
        'password': newPassword,
        'passwordUpdatedAt': updatedAt,
      },
      where: 'id = ?',
      whereArgs: [userId],
    );
    if (changed == 0) throw StateError('用户不存在：$userId');
  }

  /// 本地实现原样返回入参：本地 id 由客户端自己拼，落库前后是同一个，
  /// 与云端「服务端生成 id、必须采纳返回行」的语义在这里合流 ——
  /// 调用方拿到的永远是「这一行的最终 id」。
  @override
  Future<List<HomeworkImageModel>> saveHomeworkImage(
    HomeworkImageModel image,
  ) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['homework_image'] ??= <Map<String, dynamic>>[];
      rows.add(image.toMap());
      _saveWebStore();
      return <HomeworkImageModel>[image];
    }
    final db = await database;
    await db.insert(
      'homework_image',
      image.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return <HomeworkImageModel>[image];
  }

  @override
  Future<List<HomeworkImageModel>> queryHomeworkImages(String studentId) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      return (_webStore['homework_image'] ?? const <Map<String, dynamic>>[])
          .where((row) => row['studentId'] == studentId)
          .map(HomeworkImageModel.fromMap)
          .toList();
    }
    final db = await database;
    final rows = await db.query(
      'homework_image',
      where: 'studentId = ?',
      whereArgs: [studentId],
      orderBy: 'createdAt DESC',
    );
    return rows.map(HomeworkImageModel.fromMap).toList();
  }

  /// 按作业ID查询已上传的作业图片
  @override
  Future<List<HomeworkImageModel>> queryHomeworkImagesByHomeworkId(
    String homeworkId,
  ) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      return (_webStore['homework_image'] ?? const <Map<String, dynamic>>[])
          .where((row) => row['homeworkId'] == homeworkId)
          .map(HomeworkImageModel.fromMap)
          .toList();
    }
    final db = await database;
    final rows = await db.query(
      'homework_image',
      where: 'homeworkId = ?',
      whereArgs: [homeworkId],
      orderBy: 'createdAt DESC',
    );
    return rows.map(HomeworkImageModel.fromMap).toList();
  }

  /// 删除某作业关联的全部图片记录
  /// 删除一份作业：作业行 + 它的照片行 + 它带出来的错题（连从属表）。
  ///
  /// ## 为什么三张表要一起删
  ///
  /// 本地这份 DDL **一个 `FOREIGN KEY` 都没写**（云端那份也只有三条，
  /// 都指 `app_user` / `app_notification`）。所以「删掉作业行」不会级联
  /// 任何东西，留下的是**查不出来的孤儿**：照片行还在、错题还在错题本里，
  /// 而它们都指向一份不存在的作业。
  ///
  /// ## 与 [deleteReviewMistakesByHomeworkId] 的差别是刻意的
  ///
  /// 那个方法只删 `review_mistake` 一张表（接口注释把这件事记成了**已知缺陷**，
  /// 因为它压着「本地模式零行为变化」的承诺）。本方法是**新功能**，
  /// 没有历史行为要背，所以直接按服务端 `deleteHomework` 的口径做级联 ——
  /// 否则同一个「删作业」动作在两种构建模式下留下的孤儿行不一样，
  /// 对账时又多一处要单独解释的差异。
  ///
  /// 删不到就抛，语义与服务端回 403 一致。静默放过的话，界面会显示删除成功，
  /// 而那条作业刷新之后又回来了。
  @override
  Future<void> deleteHomework(String id) async {
    if (id.isEmpty) throw StateError('找不到这份作业（或无权删除）');

    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['homework'];
      if (rows == null || !rows.any((row) => row['id'] == id)) {
        throw StateError('找不到这份作业（或无权删除）');
      }
      // 先收齐这道作业带出来的错题 id 再动手：从属表存的是 `mistakeId`
      // 而不是 `homeworkId`，错题行一删就再也找不到它们了。
      final mistakeIds = (_webStore['review_mistake'] ?? const <Map<String, dynamic>>[])
          .where((row) => row['homeworkId'] == id)
          .map((row) => row['id'])
          .whereType<String>()
          .toList();
      rows.removeWhere((row) => row['id'] == id);
      _webStore['homework_image']?.removeWhere(
        (row) => row['homeworkId'] == id,
      );
      _webStore['review_mistake']?.removeWhere(
        (row) => row['homeworkId'] == id,
      );
      for (final mistakeId in mistakeIds) {
        for (final child in _mistakeChildTables.entries) {
          _webStore[child.key]?.removeWhere(
            (row) => row[child.value] == mistakeId,
          );
        }
      }
      _saveWebStore();
      return;
    }

    final db = await database;
    final found = await db.query(
      'homework',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [id],
    );
    if (found.isEmpty) throw StateError('找不到这份作业（或无权删除）');

    await db.transaction((txn) async {
      // 同上：错题 id 要在错题行被删掉之前收齐。
      final mistakes = await txn.query(
        'review_mistake',
        columns: ['id'],
        where: 'homeworkId = ?',
        whereArgs: [id],
      );
      await txn.delete('homework', where: 'id = ?', whereArgs: [id]);
      await txn.delete(
        'homework_image',
        where: 'homeworkId = ?',
        whereArgs: [id],
      );
      await txn.delete(
        'review_mistake',
        where: 'homeworkId = ?',
        whereArgs: [id],
      );
      for (final row in mistakes) {
        final mistakeId = row['id'];
        if (mistakeId is! String || mistakeId.isEmpty) continue;
        for (final child in _mistakeChildTables.entries) {
          await txn.delete(
            child.key,
            where: '${child.value} = ?',
            whereArgs: [mistakeId],
          );
        }
      }
    });
  }

  @override
  Future<void> deleteHomeworkImagesByHomeworkId(String homeworkId) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      _webStore['homework_image']?.removeWhere(
        (row) => row['homeworkId'] == homeworkId,
      );
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.delete(
      'homework_image',
      where: 'homeworkId = ?',
      whereArgs: [homeworkId],
    );
  }

  /// 批量写入一次提交的全部图片。整批作为一个事务落库，
  /// 避免部分成功导致「作业显示交了3张、实际只存下2张」。
  ///
  /// 返回入参本身（本地 id 就是最终 id），见 [saveHomeworkImage]。
  ///
  /// ⚠️ `photoUsage` 恒为 null：配额是**服务端**的规则，本地模式没有这个概念。
  /// 刻意**不**在本地数一下张数填进去 —— 本地数出来的只反映这台设备见过什么，
  /// 拿它去和配额比会得到一个与服务端不同的结论，而那个结论会让
  /// 「快满了」提示在**不该出现的时候**出现（或该出现时不来）。
  @override
  Future<SavedHomeworkImages> saveHomeworkImages(
    List<HomeworkImageModel> images,
  ) async {
    if (images.isEmpty) return const SavedHomeworkImages(images: []);
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore.putIfAbsent(
        'homework_image',
        () => <Map<String, dynamic>>[],
      );
      for (final image in images) {
        rows.removeWhere((r) => r['id'] == image.id);
        rows.add(image.toMap());
      }
      _saveWebStore();
      return SavedHomeworkImages(images: images);
    }
    final db = await database;
    await db.transaction((txn) async {
      for (final image in images) {
        await txn.insert(
          'homework_image',
          image.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    return SavedHomeworkImages(images: images);
  }

  /// 某作业当前的照片张数。
  @override
  Future<int> countHomeworkImages(String homeworkId) async {
    if (homeworkId.isEmpty) return 0;
    if (kIsWeb) {
      await _ensureWebSeed();
      return (_webStore['homework_image'] ?? const <Map<String, dynamic>>[])
          .where((row) => row['homeworkId'] == homeworkId)
          .length;
    }
    final db = await database;
    final value = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT COUNT(*) FROM homework_image WHERE homeworkId = ?',
        [homeworkId],
      ),
    );
    return value ?? 0;
  }

  Future<Map<String, dynamic>?> findUserById(String id) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['app_user'] ?? const <Map<String, dynamic>>[];
      for (final row in rows) {
        if (row['id'] == id) return Map<String, dynamic>.from(row);
      }
      return null;
    }
    final db = await database;
    if (DemoSeed.enabled) {
      await _ensureDefaultUsers(db);
    }
    final rows = await db.query(
      'app_user',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  @override
  Future<UserProfileModel?> queryUserProfile(String userId) async {
    final user = await findUserById(userId);
    if (user == null) return null;
    return UserProfileModel(
      userId: userId,
      name: user['name'] as String? ?? '',
      gender: user['gender'] as String? ?? '',
      grade: user['grade'] as String? ?? '',
      term: user['term'] as String? ?? '',
      hobbies: (user['hobbies'] as String? ?? '')
          .split(',')
          .where((item) => item.isNotEmpty)
          .toList(),
      bio: user['bio'] as String? ?? '',
    );
  }

  @override
  Future<void> updateUserProfile(UserProfileModel profile) async {
    final user = await findUserById(profile.userId);
    if (user == null) throw StateError('用户不存在');
    user.addAll(profile.toMap());
    await saveUser(user);
  }

  @override
  Future<RelationshipModel> createRelationshipInvitation({
    required String senderId,
    required String targetPhone,
  }) async {
    final sender = await findUserById(senderId);
    final target = await findUserByPhone(targetPhone.trim());
    if (sender == null || target == null) throw StateError('手机号对应的用户不存在');
    final senderRole = sender['role'] as String;
    final targetRole = target['role'] as String;
    if (senderRole == targetRole) {
      throw StateError('学生和家长之间才能结伴');
    }
    if (senderRole != 'student' && senderRole != 'parent') {
      throw StateError('只有学生或家长可以发起结伴');
    }

    final student = senderRole == 'student' ? sender : target;
    final parent = senderRole == 'parent' ? sender : target;

    final existing = await queryRelationships(senderId);
    final duplicate = existing
        .where(
          (item) =>
              item.studentId == student['id'] && item.parentId == parent['id'],
        )
        .toList();
    if (duplicate.isNotEmpty &&
        duplicate.first.status != RelationshipStatus.removed) {
      throw StateError('双方已有邀请或已结伴');
    }

    final id = 'rel_${DateTime.now().millisecondsSinceEpoch}';
    final row = {
      'id': id,
      'studentId': student['id'],
      'parentId': parent['id'],
      'senderId': senderId,
      'status': RelationshipStatus.pending.name,
      'createdAt': DateTime.now().toIso8601String(),
    };
    await _saveRelationship(row);
    return _relationshipFromRow(
      row,
      student['name'] as String,
      parent['name'] as String,
    );
  }

  @override
  Future<List<RelationshipModel>> queryRelationships(String userId) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      return _relationshipsFromRows(
        _webStore['relationship'] ?? const <Map<String, dynamic>>[],
        userId,
      );
    }
    final db = await database;
    final rows = await db.query(
      'relationship',
      where: 'studentId = ? OR parentId = ?',
      whereArgs: [userId, userId],
    );
    return _relationshipsFromRows(rows, userId);
  }

  @override
  Future<void> updateRelationshipStatus({
    required String id,
    required RelationshipStatus status,
  }) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['relationship'] ??= <Map<String, dynamic>>[];
      final index = rows.indexWhere((row) => row['id'] == id);
      if (index >= 0) rows[index]['status'] = status.name;
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.update(
      'relationship',
      {'status': status.name},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 解除结伴（本地 / Web 模式）。
  ///
  /// 与云上一致的三件事：
  ///   · **只改状态，不删行** —— 本地这张表同样有 `unique(studentId, parentId)`
  ///     （见建表处），删行会让「解除后重新结伴」在本地失败、在云上成功；
  ///   · **校验当前必须是 `active`** —— 云上的 UPDATE 带了 `and status = active`，
  ///     本地不校验的话「重复解除」会一边成功一边 403；
  ///   · 数据一行都不动。
  ///
  /// ⚠️ 与云上**不一致**的一处：这里没有角色校验（云上 `revoke` 只放给家长）。
  /// 本地模式没有「请求方」这个概念（同一台设备上的库），硬造一个出来只会让
  /// 两边差得更远；而这个动作的唯一入口是 `binding_page` 里**只对家长渲染**的按钮。
  /// 顺带记一笔：上面那条 `updateRelationshipStatus` 连状态校验都没有（历史遗留），
  /// 新开的这条路不重复那个问题。
  @override
  Future<void> revokeRelationship({required String id}) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['relationship'] ??= <Map<String, dynamic>>[];
      final index = rows.indexWhere((row) => row['id'] == id);
      if (index < 0 || rows[index]['status'] != RelationshipStatus.active.name) {
        throw StateError('找不到可解除的结伴关系（或无权操作）');
      }
      rows[index]['status'] = RelationshipStatus.removed.name;
      _saveWebStore();
      return;
    }
    final db = await database;
    final changed = await db.update(
      'relationship',
      {'status': RelationshipStatus.removed.name},
      where: 'id = ? AND status = ?',
      whereArgs: [id, RelationshipStatus.active.name],
    );
    if (changed == 0) {
      // 与云上同一句话：id 不存在 / 不是 active / 已解除，对调用方是同一件事。
      throw StateError('找不到可解除的结伴关系（或无权操作）');
    }
  }

  @override
  Future<List<ChatMessageModel>> queryChatMessages({
    required String relationshipId,
    required String requesterId,
  }) async {
    await _requireActiveRelationship(
      relationshipId: relationshipId,
      requesterId: requesterId,
    );
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = (_webStore['chat_message'] ?? const <Map<String, dynamic>>[])
          .where((row) => row['relationshipId'] == relationshipId)
          .toList();
      return rows.map(_chatMessageFromRow).toList();
    }
    final db = await database;
    final rows = await db.query(
      'chat_message',
      where: 'relationshipId = ?',
      whereArgs: [relationshipId],
      orderBy: 'createdAt ASC',
    );
    return rows.map(_chatMessageFromRow).toList();
  }

  @override
  Future<ChatMessageModel> sendChatMessage({
    required String relationshipId,
    required String senderId,
    required String content,
  }) async {
    final relationship = await _requireActiveRelationship(
      relationshipId: relationshipId,
      requesterId: senderId,
    );

    final receiverId = relationship.studentId == senderId
        ? relationship.parentId
        : relationship.studentId;
    final now = DateTime.now();
    final row = {
      'id': 'msg_${now.millisecondsSinceEpoch}',
      'relationshipId': relationshipId,
      'senderId': senderId,
      'receiverId': receiverId,
      'content': content.trim(),
      'createdAt': now.toIso8601String(),
      'isRead': 0,
    };
    if (kIsWeb) {
      await _ensureWebSeed();
      (_webStore['chat_message'] ??= <Map<String, dynamic>>[]).add(row);
      _saveWebStore();
    } else {
      final db = await database;
      await db.insert('chat_message', row);
    }
    return _chatMessageFromRow(row);
  }

  ChatMessageModel _chatMessageFromRow(Map<String, dynamic> row) {
    return ChatMessageModel(
      id: row['id'] as String,
      relationshipId: row['relationshipId'] as String,
      senderId: row['senderId'] as String,
      receiverId: row['receiverId'] as String,
      content: row['content'] as String,
      createdAt: DateTime.parse(row['createdAt'] as String),
      isRead: row['isRead'] == 1,
    );
  }

  Future<RelationshipModel> _requireActiveRelationship({
    required String relationshipId,
    required String requesterId,
  }) async {
    Map<String, dynamic>? row;
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['relationship'] ?? const <Map<String, dynamic>>[];
      for (final candidate in rows) {
        if (candidate['id'] == relationshipId) {
          row = candidate;
          break;
        }
      }
    } else {
      final db = await database;
      final rows = await db.query(
        'relationship',
        where: 'id = ? AND (studentId = ? OR parentId = ?)',
        whereArgs: [relationshipId, requesterId, requesterId],
        limit: 1,
      );
      if (rows.isNotEmpty) row = Map<String, dynamic>.from(rows.first);
    }

    if (row == null ||
        (row['studentId'] != requesterId && row['parentId'] != requesterId) ||
        row['status'] != RelationshipStatus.active.name) {
      throw StateError('只有已通过鉴权的学生和家长/教师组队关系可以访问聊天');
    }

    final student = await findUserById(row['studentId'] as String);
    final parent = await findUserById(row['parentId'] as String);
    if (student == null || parent == null) {
      throw StateError('聊天成员不存在');
    }
    return _relationshipFromRow(
      row,
      student['name'] as String,
      parent['name'] as String,
    );
  }

  Future<void> _saveRelationship(Map<String, dynamic> row) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['relationship'] ??= <Map<String, dynamic>>[];
      rows.add(Map<String, dynamic>.from(row));
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.insert(
      'relationship',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<RelationshipModel>> _relationshipsFromRows(
    List<Map<String, dynamic>> rows,
    String userId,
  ) async {
    final result = <RelationshipModel>[];
    for (final row in rows) {
      if (row['studentId'] != userId && row['parentId'] != userId) continue;
      final student = await findUserById(row['studentId'] as String);
      final parent = await findUserById(row['parentId'] as String);
      if (student == null || parent == null) continue;
      result.add(
        _relationshipFromRow(
          row,
          student['name'] as String,
          parent['name'] as String,
        ),
      );
    }
    return result;
  }

  RelationshipModel _relationshipFromRow(
    Map<String, dynamic> row,
    String studentName,
    String parentName,
  ) {
    return RelationshipModel(
      id: row['id'] as String,
      studentId: row['studentId'] as String,
      parentId: row['parentId'] as String,
      senderId: (row['senderId'] as String?) ?? '',
      studentName: studentName,
      parentName: parentName,
      status: RelationshipStatus.values.firstWhere(
        (item) => item.name == row['status'],
      ),
    );
  }

  Future<void> _ensureDefaultUsers(Database db) async {
    final now = DateTime.now();
    final count =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM app_user'),
        ) ??
        0;
    if (count > 0) return;

    // 字段要与 Web 端 `_ensureWebSeed` 的同名条目对齐。少写一列不会报错
    // （列都有默认值），但会让「同一个演示账号」在两端拿到不同的资料，
    // 而用户资料里就藏着类型陷阱：`hobbies` 缺省是空串。
    await db.insert('app_user', {
      'id': 'stu_001',
      'name': '林小宇',
      'phone': '13800000001',
      'role': 'student',
      'avatar': 'student',
      'password': 'abc123',
      'wechatOpenId': null,
      'gender': '男',
      'grade': '六年级',
      'hobbies': '阅读,跑步',
      'bio': '',
      'passwordUpdatedAt': now
          .subtract(const Duration(days: 30))
          .toIso8601String(),
    });
    await db.insert('app_user', {
      'id': 'par_001',
      'name': '王老师',
      'phone': '13800000002',
      'role': 'parent',
      'avatar': 'parent',
      'password': 'abc123',
      'wechatOpenId': 'mock-wechat-parent',
      'gender': '女',
      'grade': '',
      'hobbies': '阅读,运动',
      'bio': '',
      'passwordUpdatedAt': now
          .subtract(const Duration(days: 30))
          .toIso8601String(),
    });

    await db.insert('relationship', {
      'id': 'rel_001',
      'studentId': 'stu_001',
      'parentId': 'par_001',
      'senderId': 'par_001',
      'status': RelationshipStatus.active.name,
      'createdAt': now.subtract(const Duration(days: 2)).toIso8601String(),
    });
  }

  HomeworkItem _homeworkFromMap(Map<String, dynamic> row) {
    return HomeworkItem(
      id: row['id'] as String,
      title: (row['title'] as String?) ?? '',
      subject: (row['subject'] as String?) ?? '',
      imageUrl: (row['imageUrl'] as String?) ?? '',
      dueAt: DateTime.tryParse((row['dueAt'] as String?) ?? '') ??
          DateTime.now(),
      estimatedMinutes: (row['estimatedMinutes'] as num?)?.toDouble() ?? 0,
      // 缺列（v26 之前的老库 / 老 localStorage 行）一律当 0 = 从未计时。
      actualSeconds: (row['actualSeconds'] as num?)?.toInt() ?? 0,
      status: HomeworkStatus.parse(row['status'] as String?),
      wrongCount: (row['wrongCount'] as num?)?.toInt() ?? 0,
      aiEnabled: (row['aiEnabled'] as num?)?.toInt() == 1,
      // 缺列时当成「需要批改」：老库（v21 之前）、老 localStorage 里的行
      // 都没有这一列，而它们全是按「要批改」走的。取反会静默改变历史作业
      // 的性质 —— 一份已经批过的卷子突然变成「无需批改」，家长会以为
      // 系统把结果吃了。
      needsGrading: (row['needsGrading'] as num?)?.toInt() != 0,
      userRole: (row['userRole'] as String?) ?? 'student',
      studentId: (row['studentId'] as String?) ?? 'stu_001',
      submittedAt: _parseNullableTime(row['submittedAt']),
      checkedAt: _parseNullableTime(row['checkedAt']),
      score: (row['score'] as num?)?.toInt(),
      summary: (row['summary'] as String?) ?? '',
      imageCount: (row['imageCount'] as num?)?.toInt() ?? 0,
      submitBatchId: (row['submitBatchId'] as String?) ?? '',
      gradingSource: (row['gradingSource'] as String?) ?? GradingSource.none,
    );
  }

  /// 时间字段容错解析：Web 存储与历史行都可能缺列或存空串。
  static DateTime? _parseNullableTime(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  // ===== Homework writes =====
  /// 本地实现**原样返回入参**：id 本来就是调用方拼的，落库前后是同一行。
  ///
  /// 与云端实现（服务端会换掉 id、必须回填）在**语义**上一致：
  /// 返回的都是「落库之后真实的那一行」。见 `HomeworkRepository.insertHomework`。
  @override
  Future<HomeworkItem> insertHomework(HomeworkItem item, String userRole) async {
    final row = {
      'id': item.id,
      'title': item.title,
      'subject': item.subject,
      'imageUrl': item.imageUrl,
      'dueAt': item.dueAt.toIso8601String(),
      'estimatedMinutes': item.estimatedMinutes,
      'actualSeconds': item.actualSeconds,
      'status': item.status.name,
      'wrongCount': item.wrongCount,
      'aiEnabled': item.aiEnabled ? 1 : 0,
      'needsGrading': item.needsGrading ? 1 : 0,
      'userRole': userRole,
      'studentId': item.studentId,
      'gradingSource': item.gradingSource,
    };
    if (kIsWeb) {
      await _ensureWebSeed();
      _webStore
          .putIfAbsent('homework', () => <Map<String, dynamic>>[])
          .insert(0, row);
      _saveWebStore();
      return item;
    }
    final db = await database;
    await db.insert('homework', row);
    return item;
  }

  /// 按字段掩码更新作业。
  ///
  /// 掩码由 [HomeworkPatch] 显式给出：**只有被 setter 写过的字段**才会进入
  /// `values`，「显式写成 null」也不例外。老签名用「`null` 表示本次不改这个字段」，
  /// 那种区分活不过一次 JSON 序列化 —— 详见 [HomeworkPatch] 的说明（陷阱 ②）。
  @override
  Future<void> updateHomework(HomeworkPatch patch) async {
    final id = patch.id;
    final values = patch.toMap();
    if (values.isEmpty) return;

    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['homework'] ?? <Map<String, dynamic>>[];
      final index = rows.indexWhere((r) => r['id'] == id);
      if (index >= 0) rows[index] = {...rows[index], ...values};
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.update('homework', values, where: 'id = ?', whereArgs: [id]);
  }

  // ===== Workout writes =====
  @override
  Future<void> insertWorkoutRecord(WorkoutRecord record) async {
    final row = {
      'id': record.id,
      'project': record.project,
      'startAt': record.start.toIso8601String(),
      'endAt': record.end.toIso8601String(),
      'minutes': record.minutes,
      'feedback': record.feedback,
      'planId': record.planId,
      'studentId': record.studentId,
    };
    if (kIsWeb) {
      await _ensureWebSeed();
      _webStore
          .putIfAbsent('workout_record', () => <Map<String, dynamic>>[])
          .insert(0, row);
      _saveWebStore();
      return;
    }
    final db = await database;
    // `ignore` 不是「随手加一个容错」，它就是这条表的**契约**：
    // `id` 是幂等键（见 `WorkoutRepository.insertWorkoutRecord` 的注释），
    // 重试必须落成「还是那一行」。服务端那一侧是 `on conflict (id) do nothing`
    // 再回查原行（`routes/workout.js`），两侧必须同形。
    //
    // ⚠️ 不加冲突子句时 SQLite 直接抛 `UNIQUE constraint failed` —— 而调用方
    // `_safePersist`（`student_controller.dart`）会把它吞掉，于是「本地重试报错、
    // 云端重试成功」这处不对称**在界面上完全看不见**，只有对账能撞出来。
    await db.insert(
      'workout_record',
      row,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  @override
  Future<void> insertWorkoutPlan(WorkoutPlan plan) async {
    final row = {
      'id': plan.id,
      'title': plan.title,
      'project': plan.project,
      'weekdays': plan.weekdays.join(','),
      'targetMinutes': plan.targetMinutes,
      'isActive': plan.isActive ? 1 : 0,
      'startDate': plan.startDate?.toIso8601String(),
      'endDate': plan.endDate?.toIso8601String(),
      'startTime': plan.startTime,
      'endTime': plan.endTime,
      'cycleType': plan.cycleType.name,
      'customWeekdays': plan.customWeekdays.join(','),
      'studentId': plan.studentId,
    };
    if (kIsWeb) {
      await _ensureWebSeed();
      _webStore
          .putIfAbsent('workout_plan', () => <Map<String, dynamic>>[])
          .insert(0, row);
      _saveWebStore();
      return;
    }
    final db = await database;
    // 与 `insertWorkoutRecord` 同理：计划表的 `id` 也是幂等键
    // （契约注释把两者写在一起），重复新建必须落成「还是那一行」。
    await db.insert(
      'workout_plan',
      row,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  @override
  Future<void> updateWorkoutPlanActive(String id, bool isActive) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['workout_plan'] ?? <Map<String, dynamic>>[];
      final index = rows.indexWhere((r) => r['id'] == id);
      if (index >= 0) rows[index]['isActive'] = isActive ? 1 : 0;
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.update(
      'workout_plan',
      {'isActive': isActive ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ===== Review writes =====
  Map<String, dynamic> _reviewMistakeToMap(ReviewMistake mistake) =>
      mistake.toMap();

  @override
  Future<void> insertReviewMistake(ReviewMistake mistake) =>
      insertReviewMistakes([mistake]);

  /// 批量写入错题。一次 AI 批改产出的错题应作为一个整体落库，
  /// 避免逐条写入过程中失败导致「作业说错了3道、错题本只有1道」。
  @override
  Future<void> insertReviewMistakes(List<ReviewMistake> mistakes) async {
    if (mistakes.isEmpty) return;
    if (kIsWeb) {
      await _ensureWebSeed();
      final store = _webStore.putIfAbsent(
        'review_mistake',
        () => <Map<String, dynamic>>[],
      );
      for (final mistake in mistakes) {
        store.insert(0, _reviewMistakeToMap(mistake));
      }
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      for (final mistake in mistakes) {
        await txn.insert(
          'review_mistake',
          _reviewMistakeToMap(mistake),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// 整条覆盖更新一道错题。
  ///
  /// 与 [updateReviewMistakeState] 的分工：后者是闭环内部推进状态用的窄接口
  /// （只动状态机相关字段）；这里是**学生手工编辑**用的宽接口——
  /// 改科目、改题干、改知识点都可能发生，窄接口表达不了。
  ///
  /// 之所以不让手工编辑也走窄接口，是因为窄接口为了兼容「只改状态」的场景，
  /// 把多数字段设成了可空。用它来改题干，某天漏传一个参数就会静默清空字段。
  @override
  Future<void> updateReviewMistake(ReviewMistake mistake) async {
    if (mistake.id.isEmpty) return;
    final values = _reviewMistakeToMap(mistake);
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['review_mistake'] ?? <Map<String, dynamic>>[];
      final index = rows.indexWhere((row) => row['id'] == mistake.id);
      if (index >= 0) {
        rows[index] = values;
      } else {
        rows.add(values);
      }
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.update(
      'review_mistake',
      values,
      where: 'id = ?',
      whereArgs: [mistake.id],
    );
  }

  /// Web 端种子数据里的数字可能是 int、也可能是字符串，统一读成 int。
  int _intValue(Object? value) =>
      value is int ? value : int.tryParse('${value ?? ''}') ?? 0;

  /// 某道错题的图片，按卷面顺序。
  @override
  Future<List<ReviewMistakeImage>> queryMistakeImages(String mistakeId) async {
    if (mistakeId.isEmpty) return <ReviewMistakeImage>[];
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = (_webStore['review_mistake_image'] ??
              const <Map<String, dynamic>>[])
          .where((row) => row['mistakeId'] == mistakeId)
          .toList();
      rows.sort((a, b) {
        final byOrder = _intValue(a['sortOrder']).compareTo(
          _intValue(b['sortOrder']),
        );
        if (byOrder != 0) return byOrder;
        return '${a['createdAt'] ?? ''}'.compareTo('${b['createdAt'] ?? ''}');
      });
      return rows.map(ReviewMistakeImage.fromMap).toList();
    }
    final db = await database;
    final rows = await db.query(
      'review_mistake_image',
      where: 'mistakeId = ?',
      whereArgs: [mistakeId],
      orderBy: 'sortOrder ASC, createdAt ASC',
    );
    return rows.map(ReviewMistakeImage.fromMap).toList();
  }

  /// 写入图片。与 [insertReviewMistakes] 分开是因为调用方可能只补图。
  ///
  /// ⚠️ 「新增错题 + 它的图片」必须一起成功：调用方用
  /// `insertReviewMistakeWithImages`，那个方法在一个事务里做两件事。
  @override
  Future<void> insertMistakeImages(List<ReviewMistakeImage> images) async {
    if (images.isEmpty) return;
    if (kIsWeb) {
      await _ensureWebSeed();
      final store = _webStore.putIfAbsent(
        'review_mistake_image',
        () => <Map<String, dynamic>>[],
      );
      for (final image in images) {
        store.add(image.toMap());
      }
      _saveWebStore();
      return;
    }
    final db = await database;
    final batch = db.batch();
    for (final image in images) {
      batch.insert(
        'review_mistake_image',
        image.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// 新增一道错题并关联图片（单事务）。
  ///
  /// 分成两次调用的话，第二步失败会留下「题在、图没了」的半条记录，
  /// 而界面上看起来一切正常 —— 这正是本项目最忌讳的静默失败。
  @override
  Future<void> insertReviewMistakeWithImages(
    ReviewMistake mistake,
    List<ReviewMistakeImage> images,
  ) async {
    if (kIsWeb) {
      await insertReviewMistakes([mistake]);
      await insertMistakeImages(images);
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'review_mistake',
        _reviewMistakeToMap(mistake),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (final image in images) {
        await txn.insert(
          'review_mistake_image',
          image.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  @override
  Future<void> deleteMistakeImage(String id) async {
    if (id.isEmpty) return;
    if (kIsWeb) {
      await _ensureWebSeed();
      _webStore['review_mistake_image']?.removeWhere((row) => row['id'] == id);
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.delete('review_mistake_image', where: 'id = ?', whereArgs: [id]);
  }

  /// 删一道错题时要连带清掉的**从属表**：表名 → 关联列名。
  ///
  /// 单点是刻意的：本方法（删这一道）与 [deleteHomework]（按作业删）
  /// 都要动同一批表，各写一份就会漂 —— 而漂的表现是「留下查不到题目的
  /// 判定影子」，让一致率的分母悄悄变大，**全程不报错**。
  /// 服务端把同一件事放在 `review.js` 的 `cascadeDeleteMistake` 里。
  static const Map<String, String> _mistakeChildTables = {
    'review_attempt': 'mistakeId',
    // 影子比对记录跟着走：留下孤儿行会让一致率多出一个查不到题目的分母。
    'judgement_ab': 'mistakeId',
    'ai_practice_question': 'sourceMistakeId',
    'explain_record': 'mistakeId',
    // 错题图片：题都不在了，图留着既占空间又会被「按 id 查图」查到。
    'review_mistake_image': 'mistakeId',
  };

  /// 删除一道错题（学生手工录入时录错、或确认不再需要）。
  ///
  /// 连带清掉它的作答证据与练习题：`review_attempt` 是毕业判定的唯一依据，
  /// 留下孤儿记录会让「按错题聚合的通过率」多出一个查不到题目的分母。
  @override
  Future<void> deleteReviewMistake(String id) async {
    if (id.isEmpty) return;
    if (kIsWeb) {
      await _ensureWebSeed();
      _webStore['review_mistake']?.removeWhere((row) => row['id'] == id);
      for (final child in _mistakeChildTables.entries) {
        _webStore[child.key]?.removeWhere((row) => row[child.value] == id);
      }
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'review_mistake',
        where: 'id = ?',
        whereArgs: [id],
      );
      for (final child in _mistakeChildTables.entries) {
        await txn.delete(
          child.key,
          where: '${child.value} = ?',
          whereArgs: [id],
        );
      }
    });
  }

  /// 按来源作业查询错题（家长端作业详情用）。
  ///
  /// 顺序与服务端 `?homeworkId=` 那条一致（最新在前），
  /// 用同一个 [ReviewMistake.byNewestFirst]，理由见 `queryReviewMistakes`。
  @override
  Future<List<ReviewMistake>> queryReviewMistakesByHomeworkId(
    String homeworkId,
  ) async {
    if (homeworkId.isEmpty) return <ReviewMistake>[];
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = (_webStore['review_mistake'] ?? const <Map<String, dynamic>>[])
          .where((row) => row['homeworkId'] == homeworkId)
          .toList();
      return rows.map(_reviewMistakeFromMap).toList()
        ..sort(ReviewMistake.byNewestFirst);
    }
    final db = await database;
    final rows = await db.query(
      'review_mistake',
      where: 'homeworkId = ?',
      whereArgs: [homeworkId],
    );
    return rows.map(_reviewMistakeFromMap).toList()
      ..sort(ReviewMistake.byNewestFirst);
  }

  ReviewMistake _reviewMistakeFromMap(Map<String, dynamic> row) =>
      ReviewMistake.fromMap(row);

  /// 清除某作业的错题（重新提交时重算，避免同一道题反复进错题本）。
  @override
  Future<void> deleteReviewMistakesByHomeworkId(String homeworkId) async {
    if (homeworkId.isEmpty) return;
    if (kIsWeb) {
      await _ensureWebSeed();
      _webStore['review_mistake']?.removeWhere(
        (row) => row['homeworkId'] == homeworkId,
      );
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.delete(
      'review_mistake',
      where: 'homeworkId = ?',
      whereArgs: [homeworkId],
    );
  }

  /// 更新错题状态。复习闭环要一起写的字段（错误次数、轮次、毕业时间）都在这里，
  /// 单独一个 `state` 参数无法表达「回炉」和「毕业」的区别。
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
    final values = <String, Object?>{
      'state': state.name,
      'wrongCount': ?wrongCount,
      if (lastWrongAt != null) 'lastWrongAt': lastWrongAt.toIso8601String(),
      'reviewRound': ?reviewRound,
      if (lastReviewedAt != null)
        'lastReviewedAt': lastReviewedAt.toIso8601String(),
      if (masteredAt != null) 'masteredAt': masteredAt.toIso8601String(),
      if (masteredBySelf != null) 'masteredBySelf': masteredBySelf ? 1 : 0,
      'knowledgePoint': ?knowledgePoint,
      'wrongReason': ?wrongReason,
    };
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['review_mistake'] ?? <Map<String, dynamic>>[];
      final index = rows.indexWhere((r) => r['id'] == id);
      if (index >= 0) rows[index].addAll(values);
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.update('review_mistake', values, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> insertReviewPaper(ReviewPaper paper) async {
    final row = paper.toMap();
    if (kIsWeb) {
      await _ensureWebSeed();
      _webStore
          .putIfAbsent('review_paper', () => <Map<String, dynamic>>[])
          .insert(0, row);
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.insert('review_paper', row);
  }

  /// 组卷落库：卷与卷内快照必须一次事务写完。
  /// 只写入卷头而题目写失败，会留下一个点不开的空卷。
  @override
  Future<SavedPaper> insertReviewPaperWithItems(
    ReviewPaper paper,
    List<ReviewPaperItem> items,
  ) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      _webStore
          .putIfAbsent('review_paper', () => <Map<String, dynamic>>[])
          .insert(0, paper.toMap());
      final store = _webStore.putIfAbsent(
        'review_paper_item',
        () => <Map<String, dynamic>>[],
      );
      for (final item in items) {
        store.insert(0, item.toMap());
      }
      _saveWebStore();
      // 本地库的 id 就是权威 —— 客户端给什么就存什么，原样返回。
      return SavedPaper(paper: paper, items: items);
    }
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'review_paper',
        paper.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (final item in items) {
        await txn.insert(
          'review_paper_item',
          item.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    return SavedPaper(paper: paper, items: items);
  }

  @override
  Future<void> updateReviewPaper(ReviewPaper paper) async {
    final row = paper.toMap()..remove('id');
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['review_paper'] ?? <Map<String, dynamic>>[];
      final index = rows.indexWhere((r) => r['id'] == paper.id);
      if (index >= 0) rows[index].addAll(row);
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.update(
      'review_paper',
      row,
      where: 'id = ?',
      whereArgs: [paper.id],
    );
  }

  @override
  Future<void> updateReviewPaperItem(ReviewPaperItem item) async {
    final row = item.toMap()..remove('id');
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['review_paper_item'] ?? <Map<String, dynamic>>[];
      final index = rows.indexWhere((r) => r['id'] == item.id);
      if (index >= 0) rows[index].addAll(row);
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.update(
      'review_paper_item',
      row,
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  @override
  Future<void> insertReviewAttempt(ReviewAttempt attempt) async {
    final row = attempt.toMap();
    if (kIsWeb) {
      await _ensureWebSeed();
      _webStore
          .putIfAbsent('review_attempt', () => <Map<String, dynamic>>[])
          .insert(0, row);
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.insert('review_attempt', row);
  }

  @override
  Future<void> insertReviewAttempts(List<ReviewAttempt> attempts) async {
    if (attempts.isEmpty) return;
    if (kIsWeb) {
      await _ensureWebSeed();
      final store = _webStore.putIfAbsent(
        'review_attempt',
        () => <Map<String, dynamic>>[],
      );
      for (final attempt in attempts) {
        store.insert(0, attempt.toMap());
      }
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      for (final attempt in attempts) {
        await txn.insert(
          'review_attempt',
          attempt.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// 覆盖写入一批举一反三题（同一道错题重新出题时替换旧的未作答题目）。
  @override
  Future<void> replacePracticeQuestions(
    String sourceMistakeId,
    List<AiPracticeQuestion> questions,
  ) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final store = _webStore.putIfAbsent(
        'ai_practice_question',
        () => <Map<String, dynamic>>[],
      );
      store.removeWhere((row) => row['sourceMistakeId'] == sourceMistakeId);
      for (final question in questions) {
        store.insert(0, question.toMap());
      }
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'ai_practice_question',
        where: 'sourceMistakeId = ?',
        whereArgs: [sourceMistakeId],
      );
      for (final question in questions) {
        await txn.insert(
          'ai_practice_question',
          question.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  @override
  Future<void> updatePracticeQuestion(AiPracticeQuestion question) async {
    final row = question.toMap()..remove('id');
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows =
          _webStore['ai_practice_question'] ?? <Map<String, dynamic>>[];
      final index = rows.indexWhere((r) => r['id'] == question.id);
      if (index >= 0) rows[index].addAll(row);
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.update(
      'ai_practice_question',
      row,
      where: 'id = ?',
      whereArgs: [question.id],
    );
  }

  @override
  Future<void> insertExplainRecord(ExplainRecord record) async {
    final row = record.toMap();
    if (kIsWeb) {
      await _ensureWebSeed();
      _webStore
          .putIfAbsent('explain_record', () => <Map<String, dynamic>>[])
          .insert(0, row);
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.insert('explain_record', row);
  }

  @override
  Future<void> insertReviewSummary(ReviewSummary summary) async {
    final row = summary.toMap();
    if (kIsWeb) {
      await _ensureWebSeed();
      final store = _webStore.putIfAbsent(
        'review_summary',
        () => <Map<String, dynamic>>[],
      );
      // 与 SQLite 侧的 ConflictAlgorithm.replace 对齐：按 id 覆盖。
      // 周报是可以反复生成的（多看两眼就多生成一次），
      // 只 insert 不去重会让同一周攒出十几份重复报告。
      store.removeWhere((item) => item['id'] == row['id']);
      store.insert(0, row);
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.insert(
      'review_summary',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ===== Wish writes =====
  @override
  Future<void> insertWish(WishModel wish, String userRole) async {
    final row = {
      'id': wish.id,
      'title': wish.title,
      'description': wish.description,
      'isPublic': wish.isPublic ? 1 : 0,
      'parentConfirmed': wish.parentConfirmed ? 1 : 0,
      'studentConfirmed': wish.studentConfirmed ? 1 : 0,
      'isArchived': wish.isArchived ? 1 : 0,
      'userRole': userRole,
      'studentId': wish.studentId,
      'expectedDate': wish.expectedDate?.toIso8601String(),
      'pointCost': wish.pointCost,
      'redeemRequestedAt': wish.redeemRequestedAt?.toIso8601String(),
      'redeemedAt': wish.redeemedAt?.toIso8601String(),
      'redeemRejectedAt': wish.redeemRejectedAt?.toIso8601String(),
    };
    if (kIsWeb) {
      await _ensureWebSeed();
      _webStore
          .putIfAbsent('wish', () => <Map<String, dynamic>>[])
          .insert(0, row);
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.insert('wish', row);
  }

  @override
  Future<void> updateWishConfirmation({
    required String id,
    bool? parentConfirmed,
    bool? studentConfirmed,
  }) async {
    final values = <String, dynamic>{};
    if (parentConfirmed != null) {
      values['parentConfirmed'] = parentConfirmed ? 1 : 0;
    }
    if (studentConfirmed != null) {
      values['studentConfirmed'] = studentConfirmed ? 1 : 0;
    }
    if (values.isEmpty) return;

    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['wish'] ?? <Map<String, dynamic>>[];
      final index = rows.indexWhere((r) => r['id'] == id);
      if (index >= 0) rows[index] = {...rows[index], ...values};
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.update('wish', values, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> updateWishArchived(String id, bool isArchived) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['wish'] ?? <Map<String, dynamic>>[];
      final index = rows.indexWhere((r) => r['id'] == id);
      if (index >= 0) rows[index]['isArchived'] = isArchived ? 1 : 0;
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.update(
      'wish',
      {'isArchived': isArchived ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 心愿的兑换状态：定价 / 申请 / 兑现 / 拒绝。
  ///
  /// 刻意做成「传什么改什么」，而不是 `updateWish(id, WishModel)` 整体覆盖：
  /// 学生撤回申请和家长同时点兑现，两边都拿一份 WishModel 去覆盖的话，
  /// 后写的会把先写的整段抹掉。只写自己关心的那几列，冲突面就小得多。
  @override
  Future<void> updateWishRedeemState({
    required String id,
    int? pointCost,
    DateTime? redeemRequestedAt,
    DateTime? redeemedAt,
    DateTime? redeemRejectedAt,
    bool clearRedeemRequest = false,
    bool clearRedeemRejected = false,
  }) async {
    final values = <String, dynamic>{};
    if (pointCost != null) values['pointCost'] = pointCost;
    if (clearRedeemRequest) {
      values['redeemRequestedAt'] = null;
    } else if (redeemRequestedAt != null) {
      values['redeemRequestedAt'] = redeemRequestedAt.toIso8601String();
    }
    if (clearRedeemRejected) {
      values['redeemRejectedAt'] = null;
    } else if (redeemRejectedAt != null) {
      values['redeemRejectedAt'] = redeemRejectedAt.toIso8601String();
    }
    if (redeemedAt != null) values['redeemedAt'] = redeemedAt.toIso8601String();
    if (values.isEmpty) return;

    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['wish'] ?? <Map<String, dynamic>>[];
      final index = rows.indexWhere((r) => r['id'] == id);
      if (index >= 0) rows[index] = {...rows[index], ...values};
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.update('wish', values, where: 'id = ?', whereArgs: [id]);
  }

  // ===== Study plan writes =====
  @override
  Future<void> insertStudyPlan(StudyPlanModel plan, String userRole) async {
    final row = {
      'id': plan.id,
      'title': plan.title,
      'content': plan.content,
      'startAt': plan.startAt.toIso8601String(),
      'endAt': plan.endAt.toIso8601String(),
      'type': plan.type,
      'status': plan.status.name,
      'userRole': userRole,
      'studentId': plan.studentId,
      'cycleType': plan.cycleType.name,
      'customWeekdays': plan.customWeekdays.isEmpty
          ? null
          : plan.customWeekdays.join(','),
      'rejectReason': plan.rejectReason.isEmpty ? null : plan.rejectReason,
    };
    if (kIsWeb) {
      await _ensureWebSeed();
      _webStore
          .putIfAbsent('study_plan', () => <Map<String, dynamic>>[])
          .insert(0, row);
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.insert('study_plan', row);
  }

  @override
  Future<void> updateStudyPlanStatus(
    String id,
    StudyPlanStatus status, {
    String? rejectReason,
  }) async {
    final values = <String, dynamic>{'status': status.name};
    if (rejectReason != null) {
      values['rejectReason'] = rejectReason.isEmpty ? null : rejectReason;
    }
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['study_plan'] ?? <Map<String, dynamic>>[];
      final index = rows.indexWhere((r) => r['id'] == id);
      if (index >= 0) rows[index].addAll(values);
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.update('study_plan', values, where: 'id = ?', whereArgs: [id]);
  }

  // ===== Study plan check-in =====
  @override
  Future<List<StudyPlanCheckin>> queryStudyPlanCheckins() async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows =
          _webStore['study_plan_checkin'] ?? const <Map<String, dynamic>>[];
      return rows.map(StudyPlanCheckin.fromMap).toList();
    }
    final db = await database;
    final rows = await db.query('study_plan_checkin');
    return rows.map(StudyPlanCheckin.fromMap).toList();
  }

  @override
  Future<void> insertStudyPlanCheckin(StudyPlanCheckin checkin) async {
    final row = checkin.toMap();
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore.putIfAbsent(
        'study_plan_checkin',
        () => <Map<String, dynamic>>[],
      );
      final index = rows.indexWhere(
        (r) => r['planId'] == checkin.planId && r['date'] == checkin.date,
      );
      if (index >= 0) {
        rows[index] = row;
      } else {
        rows.add(row);
      }
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.insert(
      'study_plan_checkin',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> deleteStudyPlanCheckin(String planId, String date) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['study_plan_checkin'] ?? <Map<String, dynamic>>[];
      rows.removeWhere((r) => r['planId'] == planId && r['date'] == date);
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.delete(
      'study_plan_checkin',
      where: 'planId = ? AND date = ?',
      whereArgs: [planId, date],
    );
  }

  // ===== Notification writes =====
  Map<String, dynamic> _notificationToMap(AppNotificationModel notification) => {
    'id': notification.id,
    'title': notification.title,
    'body': notification.body,
    'createdAt': notification.createdAt.toIso8601String(),
    'isRead': notification.isRead ? 1 : 0,
    'targetUserId': notification.targetUserId,
    'type': notification.type.name,
    'relatedBizId': notification.relatedBizId,
  };

  @override
  Future<void> insertNotification(AppNotificationModel notification) async {
    final row = _notificationToMap(notification);
    if (kIsWeb) {
      await _ensureWebSeed();
      _webStore
          .putIfAbsent('app_notification', () => <Map<String, dynamic>>[])
          .insert(0, row);
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.insert('app_notification', row);
  }

  @override
  Future<int> markAllNotificationsRead({String? userId}) async {
    // 先按「这个人能看见的」筛，再标 —— 与 [queryNotifications] 同一套
    // `isVisibleTo` 规则。不分青红皂白 update 全表的话，单机上家长点一下
    // 会把学生的专属通知也标成已读（两边共用一个库），而这件事**没有任何
    // 报错**，只是孩子的红点莫名其妙消失了。
    final all = await _queryAllNotifications();
    final targets = (userId == null || userId.isEmpty)
        ? all
        : all.where((n) => n.isVisibleTo(userId)).toList();
    final unread = targets
        .where((n) => !n.isRead)
        .map((n) => n.id)
        .toList(growable: false);
    if (unread.isEmpty) return 0;

    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['app_notification'] ?? <Map<String, dynamic>>[];
      final wanted = unread.toSet();
      for (final row in rows) {
        if (wanted.contains(row['id'])) row['isRead'] = 1;
      }
      _saveWebStore();
      return unread.length;
    }

    final db = await database;
    final placeholders = List.filled(unread.length, '?').join(',');
    return db.update(
      'app_notification',
      {'isRead': 1},
      where: 'id in ($placeholders)',
      whereArgs: unread,
    );
  }

  @override
  Future<void> markNotificationRead(String id) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['app_notification'] ?? <Map<String, dynamic>>[];
      final index = rows.indexWhere((r) => r['id'] == id);
      if (index >= 0) rows[index]['isRead'] = 1;
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.update(
      'app_notification',
      {'isRead': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 查询通知。传入 [userId] 时只返回发给该用户的与广播通知，
  /// 避免家长端与学生端看到同一份列表（旧实现的问题）。
  @override
  Future<List<AppNotificationModel>> queryNotifications({String? userId}) async {
    final all = await _queryAllNotifications();
    if (userId == null || userId.isEmpty) return all;
    return all.where((n) => n.isVisibleTo(userId)).toList();
  }

  Future<List<AppNotificationModel>> _queryAllNotifications() async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows =
          _webStore['app_notification'] ?? const <Map<String, dynamic>>[];
      final list = rows.map(_notificationFromMap).toList();
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    }
    final db = await database;
    final rows = await db.query('app_notification', orderBy: 'createdAt DESC');
    return rows.map(_notificationFromMap).toList();
  }

  AppNotificationModel _notificationFromMap(Map<String, dynamic> row) {
    return AppNotificationModel(
      id: row['id'] as String,
      title: (row['title'] as String?) ?? '',
      body: (row['body'] as String?) ?? '',
      createdAt: DateTime.tryParse((row['createdAt'] as String?) ?? '') ??
          DateTime.now(),
      isRead: (row['isRead'] as num?)?.toInt() == 1,
      targetUserId: (row['targetUserId'] as String?) ?? '',
      type: NotificationType.parse(row['type'] as String?),
      relatedBizId: (row['relatedBizId'] as String?) ?? '',
    );
  }

  // ===== Daily comment writes =====
  @override
  Future<void> insertDailyComment(DailyCommentModel comment) async {
    final row = {
      'id': comment.id,
      'rating': comment.rating,
      'content': comment.content,
      'createdAt': comment.createdAt.toIso8601String(),
      'studentId': comment.studentId,
    };
    if (kIsWeb) {
      await _ensureWebSeed();
      _webStore
          .putIfAbsent('daily_comment', () => <Map<String, dynamic>>[])
          .insert(0, row);
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.insert('daily_comment', row);
  }

  @override
  Future<List<DailyCommentModel>> queryDailyComments() async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['daily_comment'] ?? const <Map<String, dynamic>>[];
      return rows.map(_dailyCommentFromMap).toList();
    }
    final db = await database;
    final rows = await db.query('daily_comment', orderBy: 'createdAt DESC');
    return rows.map(_dailyCommentFromMap).toList();
  }

  DailyCommentModel _dailyCommentFromMap(Map<String, dynamic> row) {
    return DailyCommentModel(
      id: row['id'] as String,
      rating: row['rating'] as String,
      content: row['content'] as String,
      createdAt: DateTime.parse(row['createdAt'] as String),
      studentId: (row['studentId'] as String?) ?? '',
    );
  }

  // ===== 积分 =====
  //
  // 这一节只做「读写账本」这一件事，**不发分、不算余额**：
  // 什么时候该发、发多少是业务判断，放在 PointController 里；
  // 余额是流水求和，不在这里缓存。数据库只保证「写得进去、读得出来、
  // 同一件事不会写两遍」。

  /// 家长给孩子配过的分值。没配过的动作**没有行**，回退到出厂默认值。
  @override
  Future<List<PointRule>> queryPointRules(String studentId) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      return (_webStore['point_rule'] ?? const <Map<String, dynamic>>[])
          .where((row) => row['studentId'] == studentId)
          .map(PointRule.fromMap)
          .whereType<PointRule>()
          .toList();
    }
    final db = await database;
    final rows = await db.query(
      'point_rule',
      where: 'studentId = ?',
      whereArgs: [studentId],
    );
    return rows.map(PointRule.fromMap).whereType<PointRule>().toList();
  }

  @override
  Future<void> upsertPointRule(PointRule rule) async {
    final row = rule.toMap();
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore.putIfAbsent(
        'point_rule',
        () => <Map<String, dynamic>>[],
      );
      final index = rows.indexWhere(
        (r) =>
            r['studentId'] == rule.studentId &&
            r['action'] == rule.action.code,
      );
      if (index >= 0) {
        rows[index] = row;
      } else {
        rows.add(row);
      }
      _saveWebStore();
      return;
    }
    final db = await database;
    // 一个孩子一个动作只有一行，replaces 掉旧的分值。
    await db.insert(
      'point_rule',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 孩子的全部积分流水，最新的在前。
  ///
  /// **返回全量而不是分页**：余额与「累计获得/消耗」都是从这份数据算的，
  /// 只取一页会让首页的余额和明细页的合计对不上 —— 那种不一致家长一眼就能
  /// 看出来，而且没法解释。数据量大到需要分页时，聚合数字要改成
  /// 服务端 SUM，两边的口径（跳过已撤销与冲正）必须保持一致。
  @override
  Future<List<PointLedgerEntry>> queryPointLedger(String studentId) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows =
          (_webStore['point_ledger'] ?? const <Map<String, dynamic>>[])
              .where((row) => row['studentId'] == studentId)
              .map(PointLedgerEntry.fromMap)
              .toList();
      rows.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return rows;
    }
    final db = await database;
    final rows = await db.query(
      'point_ledger',
      where: 'studentId = ?',
      whereArgs: [studentId],
      orderBy: 'createdAt DESC',
    );
    return rows.map(PointLedgerEntry.fromMap).toList();
  }

  /// 同一个防重键是否已经有一条「还活着」的记录。
  ///
  /// 撤销过的（reversedAt 非空）不算 —— 那正是为了让「撤销后重新打卡」
  /// 能再记一次分。
  @override
  Future<PointLedgerEntry?> findActivePointEntry({
    required String studentId,
    required String idempotencyKey,
  }) async {
    if (idempotencyKey.isEmpty) return null;
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['point_ledger'] ?? const <Map<String, dynamic>>[];
      for (final row in rows) {
        if (row['studentId'] != studentId) continue;
        if (row['idempotencyKey'] != idempotencyKey) continue;
        if ((row['reversedAt'] as String?) != null) continue;
        return PointLedgerEntry.fromMap(row);
      }
      return null;
    }
    final db = await database;
    final rows = await db.query(
      'point_ledger',
      where: 'studentId = ? AND idempotencyKey = ? AND reversedAt IS NULL',
      whereArgs: [studentId, idempotencyKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PointLedgerEntry.fromMap(rows.first);
  }

  /// 写一笔流水。
  ///
  /// 返回 false 表示**这笔已经存在**（防重键撞上了），调用方据此判断
  /// 「是不是重复发分」。数据库那道部分唯一索引才是真正的保证：
  /// 先查再插中间永远有缝，并发或连点两次都会从缝里钻过去。
  @override
  Future<bool> insertPointLedger(PointLedgerEntry entry) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore.putIfAbsent(
        'point_ledger',
        () => <Map<String, dynamic>>[],
      );
      if (entry.idempotencyKey.isNotEmpty) {
        final duplicated = rows.any(
          (r) =>
              r['studentId'] == entry.studentId &&
              r['idempotencyKey'] == entry.idempotencyKey &&
              (r['reversedAt'] as String?) == null,
        );
        if (duplicated) return false;
      }
      rows.add(entry.toMap());
      _saveWebStore();
      return true;
    }
    final db = await database;
    final rowId = await db.insert(
      'point_ledger',
      entry.toMap(),
      // 撞上 idx_point_ledger_active_key 时安静跳过，返回 0。
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return rowId > 0;
  }

  /// 把一笔标记为已撤销。
  @override
  Future<void> markPointEntryReversed(String id, DateTime reversedAt) async {
    final value = reversedAt.toIso8601String();
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['point_ledger'] ?? <Map<String, dynamic>>[];
      final index = rows.indexWhere((r) => r['id'] == id);
      if (index >= 0) rows[index]['reversedAt'] = value;
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.update(
      'point_ledger',
      {'reversedAt': value},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 某个孩子的行为配置。内置行为由 PointController 首次进入时按稳定 id 落表。
  @override
  Future<List<PointBehavior>> queryPointBehaviors(String studentId) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows =
          (_webStore['point_behavior'] ?? const <Map<String, dynamic>>[])
              .where((row) => row['studentId'] == studentId)
              .map(PointBehavior.fromMap)
              .toList();
      rows.sort((a, b) =>
          a.builtin == b.builtin ? 0 : (a.builtin ? -1 : 1));
      return rows;
    }
    final db = await database;
    final rows = await db.query(
      'point_behavior',
      where: 'studentId = ?',
      whereArgs: [studentId],
      orderBy: 'builtin DESC, id ASC',
    );
    return rows.map(PointBehavior.fromMap).toList();
  }

  @override
  Future<void> upsertPointBehavior(PointBehavior behavior) async {
    final row = behavior.toMap();
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore.putIfAbsent(
        'point_behavior',
        () => <Map<String, dynamic>>[],
      );
      final index = rows.indexWhere(
        (r) => r['studentId'] == behavior.studentId && r['id'] == behavior.id,
      );
      if (index >= 0) {
        rows[index] = row;
      } else {
        rows.add(row);
      }
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.insert(
      'point_behavior',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> deletePointBehavior(String studentId, String id) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['point_behavior'] ?? <Map<String, dynamic>>[];
      rows.removeWhere(
        (r) => r['studentId'] == studentId && r['id'] == id,
      );
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.delete(
      'point_behavior',
      where: 'studentId = ? AND id = ?',
      whereArgs: [studentId, id],
    );
  }

  // ===== 本机缓存：知识点提示 / 应用设置 =====

  /// 读一个科目的知识点提示。
  ///
  /// ⚠️ 这两个方法与上面那些不同：它们是**纯客户端缓存**，
  /// 不走云端、也不进同步。理由很实在 —— 提示是由「本机这份错题池」
  /// 归纳出来的，换一个学生或换一台设备就该重新归纳；
  /// 把它写进云库反而会让 A 学生的提示出现在 B 学生的计时页上。
  Future<List<KnowledgeTip>> queryKnowledgeTips({
    required String studentId,
    required String subject,
  }) async {
    final key = subject.trim();
    if (key.isEmpty) return <KnowledgeTip>[];
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = (_webStore['knowledge_tip'] ?? const <Map<String, dynamic>>[])
          .where((r) => r['studentId'] == studentId && r['subject'] == key)
          .map(KnowledgeTip.fromMap)
          .toList();
      rows.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      return rows;
    }
    final db = await database;
    final rows = await db.query(
      'knowledge_tip',
      where: 'studentId = ? AND subject = ?',
      whereArgs: [studentId, key],
      orderBy: 'sortOrder ASC',
    );
    return rows.map(KnowledgeTip.fromMap).toList();
  }

  /// 用一批新提示**整体替换**某个科目下的旧提示。
  ///
  /// 必须是整体替换，不能逐条 upsert：旧的提示可能指向一个已经毕业的
  /// 知识点，留着它就会在计时页上一直显示「你总在这里错」—— 而那个
  /// 知识点他早就掌握了。
  Future<void> replaceKnowledgeTips({
    required String studentId,
    required String subject,
    required List<KnowledgeTip> tips,
  }) async {
    final key = subject.trim();
    if (key.isEmpty) return;
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore.putIfAbsent(
        'knowledge_tip',
        () => <Map<String, dynamic>>[],
      );
      rows.removeWhere(
        (r) => r['studentId'] == studentId && r['subject'] == key,
      );
      rows.addAll(tips.map((tip) => tip.toMap()));
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'knowledge_tip',
        where: 'studentId = ? AND subject = ?',
        whereArgs: [studentId, key],
      );
      for (final tip in tips) {
        await txn.insert('knowledge_tip', tip.toMap());
      }
    });
  }

  // ===== 每日概念训练流水（只在本机，见 DrillRepository 注释） =====

  /// 该生的训练流水，新的在前。
  @override
  Future<List<DrillAnswer>> queryDrillAnswers({
    required String studentId,
    int limit = 300,
  }) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = (_webStore['drill_answer'] ?? const <Map<String, dynamic>>[])
          .where((r) => r['studentId'] == studentId)
          .map(DrillAnswer.fromMap)
          .toList();
      rows.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return rows.take(limit).toList();
    }
    final db = await database;
    final rows = await db.query(
      'drill_answer',
      where: 'studentId = ?',
      whereArgs: [studentId],
      orderBy: 'createdAt DESC',
      limit: limit,
    );
    return rows.map(DrillAnswer.fromMap).toList();
  }

  /// 一次提交的整组作答。
  ///
  /// 一个事务里整批写入：一组题要么整组记下，要么整组没记。
  /// 逐条 insert 中途失败会留下半组历史，「最近一次做错」的判断
  /// 就会落到一条残记录上 —— 而界面看起来一切正常。
  @override
  Future<void> insertDrillAnswers(List<DrillAnswer> answers) async {
    if (answers.isEmpty) return;
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore.putIfAbsent(
        'drill_answer',
        () => <Map<String, dynamic>>[],
      );
      // 同一天重复提交（比如先交一遍又重练）先删旧记录，避免历史翻倍。
      final dates = answers.map((a) => a.date).toSet();
      rows.removeWhere(
        (r) =>
            r['studentId'] == answers.first.studentId &&
            dates.contains(r['date']),
      );
      rows.addAll(answers.map((a) => a.toMap()));
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      final dates = answers.map((a) => a.date).toSet();
      await txn.delete(
        'drill_answer',
        where: 'studentId = ? AND date IN (${dates.map((_) => '?').join(',')})',
        whereArgs: [answers.first.studentId, ...dates],
      );
      for (final answer in answers) {
        await txn.insert('drill_answer', answer.toMap());
      }
    });
  }

  /// 读一个本地设置项。不存在时返回 null（**不要用空串代替**：
  /// 空串是一个合法的值，两者混在一起就分不出「没配过」和「配成了空」）。
  Future<String?> readLocalSetting(String key) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore['app_setting'] ?? const <Map<String, dynamic>>[];
      for (final row in rows) {
        if (row['key'] == key) return row['value'] as String?;
      }
      return null;
    }
    final db = await database;
    final rows = await db.query(
      'app_setting',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  /// 写一个本地设置项（覆盖）。
  Future<void> writeLocalSetting(String key, String value) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore.putIfAbsent(
        'app_setting',
        () => <Map<String, dynamic>>[],
      );
      final index = rows.indexWhere((row) => row['key'] == key);
      if (index >= 0) {
        rows[index]['value'] = value;
      } else {
        rows.add({'key': key, 'value': value});
      }
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.insert('app_setting', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ===== 英语单词打卡（v32，只在本机） =====
  //
  // 词表缓存 + 整组作答流水。服务端只存「词表真值 / 范围 / 成绩摘要」，
  // 出题与判分全在这里；断网时用缓存照样打卡（doc/word-checkin-design.md）。

  /// 导入/重新下发后覆盖这本书的本地词表（别的书不动：换书可离线）。
  Future<void> replaceWordEntries({
    required String studentId,
    required String bookId,
    required List<WordEntry> entries,
  }) async {
    final rows = entries.map((e) => e.toMap()).toList();
    if (kIsWeb) {
      await _ensureWebSeed();
      final store = _webStore.putIfAbsent(
        'word_entry_local',
        () => <Map<String, dynamic>>[],
      );
      store.removeWhere(
        (r) => r['studentId'] == studentId && r['bookId'] == bookId,
      );
      store.addAll(rows);
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'word_entry_local',
        where: 'studentId = ? AND bookId = ?',
        whereArgs: [studentId, bookId],
      );
      for (final row in rows) {
        await txn.insert(
          'word_entry_local',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<List<WordEntry>> queryWordEntries({
    required String studentId,
    required String bookId,
  }) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      return (_webStore['word_entry_local'] ?? const <Map<String, dynamic>>[])
          .where((r) => r['studentId'] == studentId && r['bookId'] == bookId)
          .map((r) => WordEntry.fromMap(Map<String, dynamic>.from(r)))
          .toList()
        ..sort((a, b) => a.unitOrder != b.unitOrder
            ? a.unitOrder.compareTo(b.unitOrder)
            : a.sortNo.compareTo(b.sortNo));
    }
    final db = await database;
    final rows = await db.query(
      'word_entry_local',
      where: 'studentId = ? AND bookId = ?',
      whereArgs: [studentId, bookId],
      orderBy: 'unitOrder, sortNo',
    );
    return rows.map(WordEntry.fromMap).toList();
  }

  /// 该生的作答流水（错词权重、连续天数、题目回放都从这里派生）。
  Future<List<WordQuestion>> queryWordAnswers({
    required String studentId,
    int limit = 300,
  }) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = (_webStore['word_answer'] ?? const <Map<String, dynamic>>[])
          .where((r) => r['studentId'] == studentId)
          .map((r) => WordQuestion.fromMap(Map<String, dynamic>.from(r)))
          .toList();
      rows.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return rows.take(limit).toList();
    }
    final db = await database;
    final rows = await db.query(
      'word_answer',
      where: 'studentId = ?',
      whereArgs: [studentId],
      orderBy: 'date DESC, createdAt DESC',
      limit: limit,
    );
    return rows.map(WordQuestion.fromMap).toList();
  }

  /// 一组题一个事务：半组历史会让「错词加权」落到残记录上。
  Future<void> insertWordAnswers(List<WordQuestion> answers) async {
    if (answers.isEmpty) return;
    final rows = answers.map((a) => a.toMap()).toList();
    final dates = answers.map((a) => a.date).toSet();
    final studentId = answers.first.studentId;
    if (kIsWeb) {
      await _ensureWebSeed();
      final store = _webStore.putIfAbsent(
        'word_answer',
        () => <Map<String, dynamic>>[],
      );
      store.removeWhere(
        (r) => r['studentId'] == studentId && dates.contains(r['date']),
      );
      store.addAll(rows);
      _saveWebStore();
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'word_answer',
        where: 'studentId = ? AND date IN (${dates.map((_) => '?').join(',')})',
        whereArgs: [studentId, ...dates],
      );
      for (final row in rows) {
        await txn.insert('word_answer', row);
      }
    });
  }

  // ===== Focus session =====
  @override
  Future<void> saveFocusSession(FocusSession session) async {
    final row = session.toMap();
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows = _webStore.putIfAbsent(
        'focus_session',
        () => <Map<String, dynamic>>[],
      );
      final index = rows.indexWhere((r) => r['id'] == session.id);
      if (index >= 0) {
        rows[index] = row;
      } else {
        rows.add(row);
      }
      _saveWebStore();
      return;
    }
    final db = await database;
    // 同一个会话 id 反复写（检查点 / 暂停 / 结束）只更新那一行。
    // 换成 `insert` 而不带 replace 的话，第二次写入会抛主键冲突，
    // 表现是「暂停一次之后保存就失败」，而计时其实一直在走。
    await db.insert(
      'focus_session',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<FocusSession>> queryFocusSessions({
    required String studentId,
    required String from,
    required String to,
  }) async {
    if (kIsWeb) {
      await _ensureWebSeed();
      final rows =
          _webStore['focus_session'] ?? const <Map<String, dynamic>>[];
      return rows
          .where((r) => _inDateRange(r, studentId: studentId, from: from, to: to))
          .map(FocusSession.fromMap)
          .toList();
    }
    final db = await database;
    final rows = await db.query(
      'focus_session',
      where: 'studentId = ? AND date >= ? AND date <= ?',
      whereArgs: [studentId, from, to],
      orderBy: 'date ASC, startedAt ASC',
    );
    return rows.map(FocusSession.fromMap).toList();
  }

  /// 本地日期是 `yyyy-MM-dd` 定长串，字典序 = 时间序，直接比字符串。
  bool _inDateRange(
    Map<String, dynamic> row, {
    required String studentId,
    required String from,
    required String to,
  }) {
    if ((row['studentId'] as String?) != studentId) return false;
    final date = (row['date'] as String?) ?? '';
    return date.compareTo(from) >= 0 && date.compareTo(to) <= 0;
  }
}
