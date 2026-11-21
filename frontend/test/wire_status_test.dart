import 'dart:io';

import 'package:easy_learn_app/models/relationship_model.dart';
import 'package:easy_learn_app/models/study_plan_model.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/wire_status.dart';
import 'package:flutter_test/flutter_test.dart';

/// 跨端状态词映射的判据。
///
/// ## 为什么这份测试非有不可
///
/// 这层映射的失败方式是**静默的**：漏一个词的后果不是异常，而是
/// 「状态悄悄变成另一个意思」。历史上真出过 —— 服务端的 `accepted` 落到
/// `default` 被当成 `pending`，而家长端筛的是 `active`，于是家长端永远显示
/// 「尚未与任何学生结伴」，同时作业那条路完全是好的（它不经过这个枚举）。
/// 两个功能各说各话，看起来像「结伴没成功」，其实关系在库里好好的。
///
/// 所以这里钉三件事：
///   ① 每个词去哪个状态（含「旧词仍然读得懂」这条兼容性 ——
///      一个还没跑迁移的库不该表现为「读不到」）；
///   ② **上行方向绝不发出服务端白名单里没有的词**（发出去就是 400）；
///   ③ 与服务端词表 `serverless/data-service/src/vocab.js` 做**跨栈对照**：
///      服务端改了词而客户端没跟上，这里要红。
///
/// 第 ③ 条是本文件里最值钱的部分 —— 它把「两侧靠人记得同步」
/// 变成「不一致就编译不了测试」。
void main() {
  group('结伴关系 · 读（服务端词 → 客户端枚举）', () {
    test('四个现行词各归各位', () {
      expect(relationshipStatusFromWire('pending'), RelationshipStatus.pending);
      expect(relationshipStatusFromWire('active'), RelationshipStatus.active);
      expect(relationshipStatusFromWire('rejected'), RelationshipStatus.rejected);
      // ⚠️ 2026-09-26：`removed` 归入这一组。它**原先**是「客户端独有」
      // （只有本地删好友会写），所以另立了一条测试；现在服务端也会产生它
      // （家长解除结伴，`routes/relationship.js: revoke`），单列的理由没有了。
      // 而「读旧数据仍然要认」这件事依然成立：统一之前本地写下的那些
      // `removed` 行还在某些库里。
      expect(relationshipStatusFromWire('removed'), RelationshipStatus.removed);
    });

    test('⚠️ 旧词 accepted 必须读成 active，不能退化成 pending', () {
      // 这条是那个历史 bug 的判据本身。
      // 退化成 pending 的后果：家长端筛 `active` → 一条都筛不到 →
      // 永远显示「尚未与任何学生结伴」，而库里关系好好的、且**不报错**。
      expect(
        relationshipStatusFromWire('accepted'),
        RelationshipStatus.active,
        reason: '旧词 accepted 落到 default 会让家长端看不到任何孩子',
      );
    });

    test('认不出的词退到 pending，不抛异常（脏数据不该让整页解析崩）', () {
      expect(relationshipStatusFromWire(''), RelationshipStatus.pending);
      expect(relationshipStatusFromWire('who_knows'), RelationshipStatus.pending);
    });

    test('现行词与客户端枚举名**逐字相同**（这才叫「统一」）', () {
      // 四个词 —— 与上面那条「四个词逐字相同」是同一个事实的两面：
      // 那条从服务端源码读词表来比，这条从客户端读回来的枚举名比。
      for (final word in ['pending', 'active', 'rejected', 'removed']) {
        expect(
          relationshipStatusFromWire(word).name,
          word,
          reason: '服务端词 $word 与客户端枚举名不一致，说明有一侧又漂了',
        );
      }
    });
  });

  group('结伴关系 · 写（客户端枚举 → 服务端词）', () {
    test('active / rejected 直传（与服务端同词）', () {
      expect(relationshipStatusToWire(RelationshipStatus.active), 'active');
      expect(relationshipStatusToWire(RelationshipStatus.rejected), 'rejected');
    });

    test('⚠️ 上行的不是旧词 accepted —— 服务端已统一，发它会被 400 拒', () {
      expect(relationshipStatusToWire(RelationshipStatus.active), isNot('accepted'));
    });

    test('pending / removed 抛 bad_request，不猜用户意图', () {
      for (final s in [RelationshipStatus.pending, RelationshipStatus.removed]) {
        expect(
          () => relationshipStatusToWire(s),
          throwsA(
            isA<DataApiException>().having((e) => e.code, 'code', 'bad_request'),
          ),
          reason: '$s 不是一个可以「改过去」的目标状态',
        );
      }
    });
  });

  group('学习计划 · 读', () {
    test('两侧同词的三个各归各位', () {
      expect(studyPlanStatusFromWire('active'), StudyPlanStatus.active);
      expect(studyPlanStatusFromWire('rejected'), StudyPlanStatus.rejected);
      expect(studyPlanStatusFromWire('completed'), StudyPlanStatus.completed);
    });

    test('同一个语义两个词的那一个（服务端 pending ↔ 客户端 pendingStudentConfirm）', () {
      expect(
        studyPlanStatusFromWire('pending'),
        StudyPlanStatus.pendingStudentConfirm,
      );
    });

    test('旧词 accepted 仍然读成 active（同结伴关系，为读旧数据保留）', () {
      expect(studyPlanStatusFromWire('accepted'), StudyPlanStatus.active);
    });

    test('expired / null / 未知词都回落 withdrawn（仅为「不崩」，非语义等价）', () {
      // 注意这里**不是**在说 `expired == withdrawn`。
      // 服务端 `expired` 是「到期自动失效」，客户端 `withdrawn` 是「家长撤回」——
      // 两件不同的事。回落只是不让整行解析失败；要真的表达它，客户端得补一个
      // `expired` 枚举值（见 wire_status.dart 的说明）。
      expect(studyPlanStatusFromWire('expired'), StudyPlanStatus.withdrawn);
      expect(studyPlanStatusFromWire(null), StudyPlanStatus.withdrawn);
      expect(studyPlanStatusFromWire('nope'), StudyPlanStatus.withdrawn);
    });
  });

  group('学习计划 · 写', () {
    test('四个有对应值的正常映射', () {
      expect(
        studyPlanStatusToWire(StudyPlanStatus.pendingStudentConfirm),
        'pending',
      );
      expect(studyPlanStatusToWire(StudyPlanStatus.active), 'active');
      expect(studyPlanStatusToWire(StudyPlanStatus.rejected), 'rejected');
      expect(studyPlanStatusToWire(StudyPlanStatus.completed), 'completed');
    });

    test('withdrawn 返回 null（服务端无对应值，由调用方显式失败）', () {
      // 返回 null 而不是硬塞 `expired`：塞过去之后状态会变成「到期失效」，
      // 与「家长撤回」是两件事，而且没有任何地方记下这次偏离。
      expect(studyPlanStatusToWire(StudyPlanStatus.withdrawn), isNull);
    });
  });

  group('跨栈对照：服务端词表（vocab.js）', () {
    // `flutter test` 的工作目录是包根目录，所以这个相对路径是稳的。
    // 故意**不**在文件缺失时跳过：静默跳过等于把这条护栏悄悄关掉，
    // 而它存在的全部意义就是「不一致时要吵」。
    final file = File('serverless/data-service/src/vocab.js');
    final source = file.readAsStringSync();

    /// 从 `名字 = Object.freeze({...})` 或 `Object.freeze([...])` 里取引号词。
    Set<String> wordsOf(String constName) {
      final block = RegExp(
        '$constName\\s*=\\s*Object\\.freeze\\(([\\s\\S]*?)\\)\\s*;',
      ).firstMatch(source);
      expect(block, isNotNull, reason: '在 vocab.js 里找不到 $constName');
      return RegExp("'([a-z_]+)'")
          .allMatches(block!.group(1)!)
          .map((m) => m.group(1)!)
          .toSet();
    }

    test('结伴关系词表 = 客户端枚举名（**四个词逐字相同**）', () {
      // ⚠️ 2026-09-26：`removed` 从「客户端独有」变成了两侧都有
      // （家长解除结伴，`routes/relationship.js: revoke`）。
      //
      // 所以这一条从「三个词全等 + 排除 removed」变成**真正的全等** ——
      // 那个 `.where(...)` 原来就是缝本身：它把「服务端不产生的那个词」
      // 排除在比对之外，于是**没人盯着它**。现在缝补上了。
      final serverWords = wordsOf('RELATIONSHIP_STATUS');
      expect(serverWords, {'pending', 'active', 'rejected', 'removed'});
      expect(
        serverWords,
        RelationshipStatus.values.map((s) => s.name).toSet(),
        reason: '两侧词表不一致 —— 要么服务端改了词，要么客户端枚举改了名',
      );
    });

    test('⚠️ 服务端**不再**输出 accepted（旧词只剩客户端读得懂的兼容）', () {
      // 这条是「我们真的统一了、且没有为了兼容留别名」的守门人。
      // 一旦有人把 `accepted` 加回服务端词表（哪怕理由是「兼容老客户端」），
      // 同一个语义就又有两个词了 —— 那正是这件事要被解决的原因。
      expect(
        wordsOf('RELATIONSHIP_STATUS').contains('accepted'),
        isFalse,
        reason: 'accepted 已经不是服务端词表的一部分；加回来等于把同一个语义拆成两个词',
      );
    });

    test('客户端上行绝不会发出服务端白名单外的词', () {
      final serverRel = wordsOf('RELATIONSHIP_STATUS');
      final serverPlan = wordsOf('STUDY_PLAN_STATUSES');

      for (final s in RelationshipStatus.values) {
        // pending / removed 走的是「明确抛错」那一支，不发请求。
        if (s == RelationshipStatus.pending || s == RelationshipStatus.removed) {
          continue;
        }
        final out = relationshipStatusToWire(s);
        expect(serverRel, contains(out), reason: '关系上行词 $out 不在服务端白名单里');
      }

      for (final s in StudyPlanStatus.values) {
        final out = studyPlanStatusToWire(s);
        if (out == null) continue; // withdrawn：服务端无对应值
        expect(serverPlan, contains(out), reason: '计划上行词 $out 不在服务端白名单里');
      }
    });

    test('服务端每个计划状态词，客户端都读得懂（不落到「未知」）', () {
      final serverPlan = wordsOf('STUDY_PLAN_STATUSES');
      expect(serverPlan, {'pending', 'active', 'rejected', 'completed', 'expired'});
      for (final word in serverPlan) {
        // 不抛异常即为通过；具体映射由上面各条钉住。
        expect(() => studyPlanStatusFromWire(word), returnsNormally);
      }
      // `expired` 是唯一一个「服务端有、客户端枚举没有」的词 —— 它回落成
      // `withdrawn` 是兜底而非等价，这一条把它显式记下来（将来客户端补了
      // `expired`，这条断言会红，提醒把兜底改成真映射）。
      expect(
        studyPlanStatusFromWire('expired'),
        StudyPlanStatus.withdrawn,
        reason: '客户端若已补上 expired 枚举，把这里改成真映射并更新说明',
      );
    });
  });
}
