import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:easy_learn_app/models/knowledge_tip.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/services/ai_api_client.dart';
import 'package:easy_learn_app/services/ai_config.dart';
import 'package:easy_learn_app/services/ai_data_source.dart';
import 'package:easy_learn_app/services/ai_data_source_factory.dart';
import 'package:easy_learn_app/services/ai_image_transport.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:easy_learn_app/services/remote_ai_data_source.dart';
import 'package:easy_learn_app/services/simulated_ai_data_source.dart';

/// 记录发出的每一次请求，用来断言「重试了几次」「重试时带没带提示」。
class _Probe {
  final List<http.Request> requests = [];

  int get count => requests.length;

  /// 按路径过滤。对象存储模式下会混进直传请求（body 是二进制），
  /// 不区分就会在 jsonDecode 上炸。
  List<http.Request> requestsFor(String path) =>
      requests.where((request) => request.url.path == path).toList();

  Map<String, dynamic> bodyAt(int index) =>
      jsonDecode(requests[index].body) as Map<String, dynamic>;

  Map<String, dynamic> get lastBody => bodyAt(requests.length - 1);
}

/// 网关成功响应。
http.Response okBody(Map<String, dynamic> data) => _envelope(
  200,
  jsonEncode({
    'ok': true,
    'data': data,
    'meta': {'requestId': 'r_test'},
  }),
);

/// 网关失败响应，形状与后端一致。
http.Response errorBody(
  String code, {
  int status = 502,
  bool retryable = true,
  String message = '模型不可用',
}) => _envelope(
  status,
  jsonEncode({
    'ok': false,
    'error': {
      'code': code,
      'message': message,
      'retryable': retryable,
    },
  }),
);

http.Response _envelope(int status, String body) => http.Response.bytes(
  utf8.encode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

const _remoteConfig = AiConfig(
  baseUrl: 'https://gw.test',
  requestTimeout: Duration(seconds: 5),
  inlineImageMaxCount: 4,
  inlineImageMaxBytes: 3 * 1024 * 1024,
  capabilities: AiCapabilities.all,
);

/// 组装一个可观测的远端数据源。
({RemoteAiDataSource ai, _Probe probe, List<AiDegradation> degradations})
buildRemote({
  required Future<http.Response> Function(http.Request request) respond,
  AiConfig config = _remoteConfig,
  ImageStorageService? storage,
}) {
  final probe = _Probe();
  final degradations = <AiDegradation>[];
  final mock = MockClient((request) async {
    probe.requests.add(request);
    return respond(request);
  });

  final remote = RemoteAiDataSource(
    client: AiApiClient(
      config: config,
      identity: const AiIdentity(studentId: 'stu_1'),
      client: mock,
    ),
    config: config,
    imageUploader: InlineHomeworkImageUploader(
      storage: storage ?? LocalImageStorageService(useMemory: true),
      config: config,
    ),
    onDegraded: degradations.add,
    // 不睡：否则每个降级用例都要白等 300ms。
    retryBackoff: Duration.zero,
  );

  return (ai: remote, probe: probe, degradations: degradations);
}

Future<String> saveImage(ImageStorageService storage, List<int> bytes) async {
  final model = await storage.saveHomeworkImage(
    studentId: 'stu_1',
    fileName: 'homework.jpg',
    bytes: Uint8List.fromList(bytes),
  );
  return model.storageKey;
}

void main() {
  group('装配', () {
    test('没有配置 baseUrl 时保持纯本地，行为与接入云端前一致', () {
      final runtime = createAiRuntime(
        config: const AiConfig(),
        identity: const AiIdentity(studentId: 'stu_1'),
      );

      expect(runtime.isRemote, isFalse);
      expect(runtime.client, isNull);
      expect(runtime.dataSource, isA<SimulatedAiDataSource>());
      // 纯本地时不持有连接池，dispose 必须是安全的空操作。
      runtime.dispose();
    });

    test('配了 baseUrl 就走远端，且保留本地实现作为降级终点', () {
      final runtime = createAiRuntime(
        config: _remoteConfig,
        identity: const AiIdentity(studentId: 'stu_1'),
        imageStorage: LocalImageStorageService(useMemory: true),
      );

      expect(runtime.isRemote, isTrue);
      expect(runtime.dataSource, isA<RemoteAiDataSource>());
      expect(
        (runtime.dataSource as RemoteAiDataSource).fallback,
        isA<SimulatedAiDataSource>(),
      );
      runtime.dispose();
    });

    test('用对象存储模式装配时，图片走直传而不是内联', () {
      final runtime = createAiRuntime(
        config: _remoteConfig.copyWith(
          imageTransport: AiImageTransport.objectStorage,
        ),
        identity: const AiIdentity(studentId: 'stu_1'),
        imageStorage: LocalImageStorageService(useMemory: true),
      );

      final uploader = (runtime.dataSource as RemoteAiDataSource).imageUploader;
      expect(uploader, isA<ObjectStorageHomeworkImageUploader>());
      expect(uploader.requiresUpload, isTrue);
      runtime.dispose();
    });
  });

  group('成功路径', () {
    test('判定结果三态都能正确映射', () async {
      for (final (verdict, expected) in [
        ('correct', AnswerVerdict.correct),
        ('wrong', AnswerVerdict.wrong),
        ('inconclusive', AnswerVerdict.inconclusive),
      ]) {
        final remote = buildRemote(
          respond: (_) async => okBody({
            'verdict': verdict,
            'score': verdict == 'correct' ? 100 : 0,
            'comment': '反馈',
          }),
        );

        final result = await remote.ai.judgeAnswer(
          studentAnswer: '11/12',
          referenceAnswer: '11/12',
        );
        expect(result.verdict, expected);
      }
    });

    test('inconclusive 不算通过（判不了 ≠ 会做）', () async {
      final remote = buildRemote(
        respond: (_) async => okBody({
          'verdict': 'inconclusive',
          'score': 0,
          'comment': '信息不足',
        }),
      );

      final result = await remote.ai.judgeAnswer(
        studentAnswer: '随便写',
        referenceAnswer: '说清条件 + 举例',
      );
      expect(result.passed, isFalse);
    });

    test('讲解按契约字段解析', () async {
      final remote = buildRemote(
        respond: (_) async => okBody({
          'knowledgePoint': '分数计算',
          'position': '人教版五年级上册',
          'whyWrong': '通分这一步没做',
          'steps': ['先找公分母', '再统一通分'],
          'pitfalls': ['分子分母同时乘错数'],
          'mnemonic': '异分母先通分',
        }),
      );

      final explanation = await remote.ai.explainMistake(
        subject: '数学',
        knowledgePoint: '分数计算',
        title: '分数比较',
        wrongReason: '分母没统一',
      );
      expect(explanation.steps.length, 2);
      expect(explanation.mnemonic, '异分母先通分');
    });

    test('出题超过请求题量时截断（多做几道只会更烦）', () async {
      final remote = buildRemote(
        respond: (_) async => okBody({
          'questions': List.generate(
            5,
            (index) => {
              'title': '变式$index',
              'content': '题干$index',
              'answer': '答案$index',
              'difficulty': '基础',
            },
          ),
          'referenceAnswer': '要点',
        }),
      );

      final questions = await remote.ai.generatePractice(
        subject: '数学',
        knowledgePoint: '分数计算',
        count: 3,
      );
      expect(questions.length, 3);
    });

    test('选项不是 4 个的选择题被丢弃，同批的其它题保留', () async {
      // 一道选项残缺的选择题，学生点哪个都可能被判错 —— 宁可少一道，
      // 也不能让它在界面上「看起来能做」。但同一批里合格的题必须留下：
      // 等三十秒回来一片空白，比少一道题糟得多。
      final remote = buildRemote(
        respond: (_) async => okBody({
          'questions': [
            {
              'type': 'choice',
              'title': '坏题',
              'content': '题干',
              'options': ['2', '3'],
              'answer': 'A',
              'difficulty': '基础',
            },
            {
              'type': 'solution',
              'title': '好题',
              'content': '计算 1/2+1/3',
              'answer': '5/6',
              'difficulty': '基础',
            },
          ],
          'referenceAnswer': '要点',
        }),
      );

      final questions = await remote.ai.generatePractice(
        subject: '数学',
        knowledgePoint: '分数计算',
      );

      expect(questions.length, 1);
      expect(questions.single.title, '好题');
      // 丢弃必须留痕：否则「这次只出了两道」永远查不到原因。
      expect(
        remote.degradations.any((d) => d.code == 'practice_question_dropped'),
        isTrue,
      );
    });

    test('选择题：选项去掉字母前缀，答案归一成字母', () async {
      final remote = buildRemote(
        respond: (_) async => okBody({
          'questions': [
            {
              'type': 'choice',
              'title': '解为 x=2 的方程',
              'content': '下列方程中，解为 x=2 的是（ ）',
              // 提示词明确要求不带前缀，但模型仍会带，且格式每次不同。
              'options': ['A. 2x+1=5', 'B、3x-1=4', 'C．x/2=2', 'D) 4x=6'],
              'answer': 'C. x/2=2',
              'difficulty': '基础',
            },
          ],
          'referenceAnswer': '要点',
        }),
      );

      final questions = await remote.ai.generatePractice(
        subject: '数学',
        knowledgePoint: '一元一次方程',
      );

      expect(questions.single.questionType, PracticeQuestionType.choice);
      expect(questions.single.options, ['2x+1=5', '3x-1=4', 'x/2=2', '4x=6']);
      expect(
        questions.single.answer,
        'C',
        reason: '答案存字母，判定才是一次字符串相等',
      );
    });

    test('判断题：√ / 对 / true 都归一成「正确」', () async {
      final remote = buildRemote(
        respond: (_) async => okBody({
          'questions': [
            {
              'type': 'judge',
              'title': '判断',
              'content': '1/2+1/3=5/6',
              'answer': '√',
              'difficulty': '基础',
            },
          ],
          'referenceAnswer': '要点',
        }),
      );

      final questions = await remote.ai.generatePractice(
        subject: '数学',
        knowledgePoint: '分数加法',
      );

      expect(questions.single.questionType, PracticeQuestionType.judge);
      expect(questions.single.answer, '正确');
      expect(questions.single.options, isEmpty);
    });

    test('中文响应不带 charset 头也不会乱码', () async {
      // 这是最容易在上线后才暴露的一类问题：http 包在响应头缺 charset 时
      // 按 latin1 解码，英文环境下测不出来，中文全是乱码。
      final remote = buildRemote(
        respond: (_) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'ok': true,
              'data': {
                'verdict': 'correct',
                'score': 100,
                'comment': '答案正确，通分这一步做得很干净。',
              },
            }),
          ),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );

      final result = await remote.ai.judgeAnswer(
        studentAnswer: '11/12',
        referenceAnswer: '11/12',
      );
      expect(result.comment, '答案正确，通分这一步做得很干净。');
    });
  });

  group('图片链路', () {
    test('内联模式把照片字节转成 base64 放进请求体', () async {
      final storage = LocalImageStorageService(useMemory: true);
      final key = await saveImage(storage, [1, 2, 3, 4, 5]);
      final remote = buildRemote(
        storage: storage,
        respond: (_) async => okBody({
          'score': 100,
          'summary': '全部正确',
          'items': <dynamic>[],
        }),
      );

      final outcome = await remote.ai.checkHomework(
        subject: '数学',
        title: '数学作业A',
        imagePaths: [key],
      );

      expect(outcome.score, 100);
      final images = remote.probe.lastBody['images'] as List<dynamic>;
      expect(images.length, 1);
      expect((images.first as Map)['mimeType'], 'image/jpeg');
      // 关键：交出的是字节，不是读不到的本地 storageKey。
      expect(
        (images.first as Map)['base64'],
        base64Encode([1, 2, 3, 4, 5]),
      );
    });

    test('没有照片时不发请求，直接降级（云端批改编不出真错题）', () async {
      final remote = buildRemote(
        respond: (_) async => okBody({'score': 0, 'summary': 'x', 'items': []}),
      );

      final outcome = await remote.ai.checkHomework(
        subject: '数学',
        title: '数学作业A',
      );

      expect(remote.probe.count, 0);
      expect(remote.degradations.single.code, 'no_images');
      // 降级后拿到的是本地实现的结果，不是报错。
      expect(outcome, isNotNull);
    });

    test('照片一张都读不出来时降级，而不是让网关盲判', () async {
      final remote = buildRemote(
        respond: (_) async => okBody({'score': 0, 'summary': 'x', 'items': []}),
      );

      await remote.ai.checkHomework(
        subject: '数学',
        title: '数学作业A',
        // 这些 key 在存储里并不存在 —— 模拟「照片被清理掉了」。
        imagePaths: ['memory://缺失1.jpg', 'memory://缺失2.jpg'],
      );

      expect(remote.probe.count, 0);
      expect(remote.degradations.single.code, 'images_unavailable');
    });

    test('内联预算：超出张数与体积的照片被丢弃并计数', () async {
      final storage = LocalImageStorageService(useMemory: true);
      final keys = <String>[];
      for (var index = 0; index < 6; index++) {
        keys.add(await saveImage(storage, [index + 1, 2, 3]));
      }

      final uploader = InlineHomeworkImageUploader(
        storage: storage,
        config: _remoteConfig.copyWith(inlineImageMaxCount: 4),
      );
      final prepared = await uploader.prepare(keys);

      expect(prepared.images.length, 4);
      expect(prepared.skipped, 2);
      expect(prepared.note, contains('超出内联预算'));
      expect(prepared.totalBytes, 12);
    });

    test('对象存储模式：取签名 → 直传 → 回填 URL', () async {
      final storage = LocalImageStorageService(useMemory: true);
      final key = await saveImage(storage, [9, 9, 9]);

      final probe = _Probe();
      final mock = MockClient((request) async {
        probe.requests.add(request);
        if (request.url.path == '/ai/uploads/sign') {
          return okBody({
            'uploads': [
              {
                'storageKey': key,
                'uploadUrl': 'https://tos.test/object/abc?sign=1',
                'objectUrl': 'https://tos.test/object/abc',
                'contentType': 'image/jpeg',
                'headers': {'x-tos-acl': 'private'},
              },
            ],
          });
        }
        // ⚠️ 这里必须回**自洽**的批改结果（score 与 items 数量对得上）。
        // 原先回的是 `score:80, items:[]` —— 那是自相矛盾输出，会被
        // validate 的「items 空却扣分」重试（B29），这条测试要数的
        // 「签名→直传→批改」就多出一个请求。矛盾处理有专门的判据。
        return okBody({
          'score': 80,
          'summary': '有 1 处错误',
          'items': [
            {
              'knowledgePoint': '分数计算',
              'originalAnswer': '3/4',
              'wrongReason': '分母处理错误',
            },
          ],
        });
      });

      final remote = RemoteAiDataSource(
        client: AiApiClient(
          config: _remoteConfig,
          identity: const AiIdentity(studentId: 'stu_1'),
          client: mock,
        ),
        config: _remoteConfig,
        imageUploader: ObjectStorageHomeworkImageUploader(
          storage: storage,
          client: AiApiClient(
            config: _remoteConfig,
            identity: const AiIdentity(studentId: 'stu_1'),
            client: mock,
          ),
        ),
        retryBackoff: Duration.zero,
      );

      await remote.checkHomework(
        subject: '数学',
        title: '数学作业A',
        imagePaths: [key],
      );

      expect(probe.count, 3); // 取签名 → 直传 → 批改
      // 批改请求里带的是 URL，而不是 base64 —— 这正是对象存储模式的意义。
      final checkBody =
          jsonDecode(probe.requestsFor('/ai/homework/check').single.body)
              as Map<String, dynamic>;
      final images = checkBody['images'] as List<dynamic>;
      expect((images.first as Map)['url'], 'https://tos.test/object/abc');
      expect((images.first as Map).containsKey('base64'), isFalse);
    });
  });

  group('重试与降级', () {
    test('响应不合契约时带 retryHint 重试一次，第二次成功即返回', () async {
      var attempt = 0;
      final remote = buildRemote(
        respond: (_) async {
          attempt++;
          if (attempt == 1) {
            // 缺 comment —— 模拟「模型换了字段名」。
            return okBody({'verdict': 'correct', 'score': 100});
          }
          return okBody({'verdict': 'correct', 'score': 100, 'comment': '对了'});
        },
      );

      final result = await remote.ai.judgeAnswer(
        studentAnswer: '11/12',
        referenceAnswer: '11/12',
      );

      expect(result.comment, '对了');
      expect(remote.probe.count, 2);
      // 第一次没有提示，第二次必须把「上次错在哪」带回去 ——
      // 否则第二次只是盲重试，模型大概率原样再错一遍。
      expect(remote.probe.bodyAt(0).containsKey('retryHint'), isFalse);
      expect(
        remote.probe.bodyAt(1)['retryHint'],
        contains('comment'),
      );
      expect(remote.degradations, isEmpty);
    });

    test(
      '网关说「content 不能为空」时，第二次必须把这句话带回去（不是盲重试）',
      () async {
        // 2026-10-23 实测的真实故障：举一反三偶发 502，
        // `questions[0].content 不能为空；questions[1].content 不能为空`。
        // 网关已经把「哪儿不合格」写在 message 里了 —— 不带回去，第二次
        // 大概率原样再空一遍，学生多等十几秒最后拿到本地兜底的假题。
        var attempt = 0;
        final remote = buildRemote(
          respond: (_) async {
            attempt++;
            if (attempt == 1) {
              return _envelope(
                502,
                jsonEncode({
                  'ok': false,
                  'error': {
                    'code': 'schema_violation',
                    'message': '模型输出不符合约定结构：questions[0].content 不能为空',
                    'retryable': true,
                  },
                }),
              );
            }
            return okBody({
              'questions': [
                {'title': '变式', 'content': '如图，求阴影面积', 'answer': '6'},
              ],
            });
          },
        );

        final items = await remote.ai.generatePractice(
          subject: '数学',
          knowledgePoint: '几何图形面积',
          count: 1,
          images: [
            AiSourceImage(bytes: Uint8List.fromList([1, 2, 3]), mimeType: 'image/jpeg'),
          ],
        );

        expect(items, hasLength(1));
        expect(items.first.content, '如图，求阴影面积');
        expect(remote.probe.count, 2);
        expect(remote.probe.bodyAt(0).containsKey('retryHint'), isFalse);
        expect(remote.probe.bodyAt(1)['retryHint'], contains('content'));
        expect(remote.degradations, isEmpty);
      },
    );

    test('批改结果「items 空却扣分」时带 retryHint 重出一次（口径见 GradingSanity）', () async {
      var attempts = 0;
      final storage = LocalImageStorageService(useMemory: true);
      final key = await saveImage(storage, [1, 2, 3]);
      final remote = buildRemote(
        storage: storage,
        respond: (request) async {
          if (request.url.path != '/ai/homework/check') {
            return errorBody('not_found', status: 404, retryable: false);
          }
          attempts++;
          if (attempts == 1) {
            // 现网实测的形态：**一条错题都没给，却扣了 20 分**，
            // 而 summary 还写着「共有 2 处计算错误」。
            // 这种结果落库之后界面上是「错题 0 道、得分 80」，两边再也对不上。
            return okBody({
              'score': 80,
              'summary': '共有 2 处计算错误。',
              'items': <dynamic>[],
            });
          }
          return okBody({
            'score': 100,
            'summary': '全部正确。',
            'items': <dynamic>[],
          });
        },
      );

      final result = await remote.ai.checkHomework(
        subject: '数学',
        title: '数学作业A',
        imagePaths: [key],
      );

      expect(attempts, 2, reason: '自相矛盾的结果不该被直接接受');
      expect(result.score, 100);
      expect(remote.degradations, isEmpty, reason: '第二次合契约，不该降级');
      // 第二次必须说清「上次错在哪」，否则就是盲重试（大概率原样再犯一遍）。
      expect(remote.probe.bodyAt(0).containsKey('retryHint'), isFalse);
      expect(remote.probe.bodyAt(1)['retryHint'], contains('100'));
      expect(remote.probe.bodyAt(1)['retryHint'], contains('80'));
    });

    test('两次都不合契约时降级到本地，并如实上报', () async {
      final remote = buildRemote(
        respond: (_) async => okBody({'verdict': 'correct', 'score': 100}),
      );

      final result = await remote.ai.judgeAnswer(
        studentAnswer: '11/12',
        referenceAnswer: '11/12',
      );

      expect(remote.probe.count, 2);
      expect(remote.degradations.single.operation, 'judgeAnswer');
      expect(remote.degradations.single.code, 'schema_violation');
      expect(remote.ai.lastDegradation?.code, 'schema_violation');
      // 降级返回的是本地实现的结论，不是异常。
      expect(result.verdict, isNotNull);
    });

    test('未知 verdict 取值判违约，不猜一个默认值', () async {
      final remote = buildRemote(
        respond: (_) async =>
            okBody({'verdict': 'partially_correct', 'score': 60, 'comment': '还行'}),
      );

      await remote.ai.judgeAnswer(
        studentAnswer: 'x',
        referenceAnswer: 'y',
      );

      // 猜成 wrong 会让「模型改了字段名」表现成「学生全错」。
      expect(remote.degradations.single.code, 'schema_violation');
    });

    test('限流（429）可重试，第二次成功', () async {
      var attempt = 0;
      final remote = buildRemote(
        respond: (_) async {
          attempt++;
          if (attempt == 1) {
            return errorBody('rate_limited', status: 429);
          }
          return okBody({'verdict': 'correct', 'score': 100, 'comment': '对了'});
        },
      );

      await remote.ai.judgeAnswer(studentAnswer: 'x', referenceAnswer: 'x');
      expect(remote.probe.count, 2);
      expect(remote.degradations, isEmpty);
    });

    test('凭证错误（401）不重试 —— 重试不会让凭证变好', () async {
      final remote = buildRemote(
        respond: (_) async => errorBody(
          'unauthorized',
          status: 401,
          retryable: false,
        ),
      );

      await remote.ai.judgeAnswer(studentAnswer: 'x', referenceAnswer: 'x');

      expect(remote.probe.count, 1);
      expect(remote.degradations.single.code, 'unauthorized');
    });

    test('模型未开通不重试（配置问题，重试一百次也不会开通）', () async {
      final remote = buildRemote(
        respond: (_) async => errorBody(
          'model_not_enabled',
          status: 503,
          retryable: false,
          message: '服务端未配置 reasoning 能力对应的模型',
        ),
      );

      await remote.ai.judgeAnswer(studentAnswer: 'x', referenceAnswer: 'x');

      expect(remote.probe.count, 1);
      expect(remote.degradations.single.code, 'model_not_enabled');
    });

    test('超时降级', () async {
      // 判定的窗口已是独立的 judgeTimeout（默认 20s），
      // 所以这里必须显式压小它 —— 只改 requestTimeout 已经压不住判定了。
      // 「判定到底认哪条线」由下面那条用例正向盯住。
      final remote = buildRemote(
        config: _remoteConfig.copyWith(
          judgeTimeout: const Duration(milliseconds: 30),
        ),
        respond: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return okBody({'verdict': 'correct', 'score': 100, 'comment': 'x'});
        },
      );

      await remote.ai.judgeAnswer(studentAnswer: 'x', referenceAnswer: 'x');

      expect(remote.degradations.single.code, 'timeout');
    });

    test('判定的窗口来自 judgeTimeout，不是 requestTimeout', () async {
      // 给「12s → 20s」那次改动立的判据，**两边都盯**：
      // requestTimeout 故意压到 30ms（远小于响应的 200ms），judgeTimeout 给 5s。
      // 若哪天有人把判定改回 fallback 到 requestTimeout，这次调用会超时降级，
      // 下面两条断言同时变红 —— 而「只测默认值是 20s」是抓不到这种回归的。
      final remote = buildRemote(
        config: _remoteConfig.copyWith(
          requestTimeout: const Duration(milliseconds: 30),
          judgeTimeout: const Duration(seconds: 5),
        ),
        respond: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return okBody({'verdict': 'correct', 'score': 100, 'comment': 'x'});
        },
      );

      final judged = await remote.ai.judgeAnswer(
        studentAnswer: 'x',
        referenceAnswer: 'x',
      );

      expect(judged.verdict, AnswerVerdict.correct);
      expect(remote.degradations, isEmpty);
    });

    test('请求体过大回 payload_too_large 且不重试', () async {
      final remote = buildRemote(
        respond: (_) async => errorBody(
          'payload_too_large',
          status: 413,
          retryable: false,
          message: '照片总体积超出上限',
        ),
      );

      await remote.ai.judgeAnswer(studentAnswer: 'x', referenceAnswer: 'x');

      expect(remote.probe.count, 1);
      expect(remote.degradations.single.code, 'payload_too_large');
    });

    test('网关返回非 JSON 时不重试（这是网关的 bug，不是模型的问题）', () async {
      final remote = buildRemote(
        respond: (_) async => http.Response('<html>502 Bad Gateway</html>', 200),
      );

      await remote.ai.judgeAnswer(studentAnswer: 'x', referenceAnswer: 'x');

      expect(remote.probe.count, 1);
      expect(remote.degradations.single.code, 'invalid_json');
    });
  });

  group('能力开关', () {
    test('探到强推理未开通后，判定直接降级不再发请求', () async {
      final probe = _Probe();
      final mock = MockClient((request) async {
        probe.requests.add(request);
        if (request.url.path == '/ai/health') {
          return okBody({
            'capabilities': {'vision': true, 'reasoning': false, 'light': true},
          });
        }
        return okBody({'verdict': 'correct', 'score': 100, 'comment': 'x'});
      });

      final remote = RemoteAiDataSource(
        client: AiApiClient(
          config: _remoteConfig,
          identity: const AiIdentity(studentId: 'stu_1'),
          client: mock,
        ),
        config: _remoteConfig,
        imageUploader: const UnavailableHomeworkImageUploader(),
        retryBackoff: Duration.zero,
      );

      final caps = await remote.refreshCapabilities();
      expect(caps?.reasoning, isFalse);

      await remote.judgeAnswer(studentAnswer: 'x', referenceAnswer: 'x');

      // 只发了探活那一次：明知没开通还发请求，代价是用户白等十几秒。
      expect(probe.count, 1);
      expect(remote.lastDegradation?.code, 'capability_disabled');
      expect(remote.config.capabilities.reasoning, isFalse);
    });

    test('能力开关全关时，讲解与出题也直接降级', () async {
      final remote = buildRemote(
        config: _remoteConfig.copyWith(
          capabilities: AiCapabilities.none,
        ),
        respond: (_) async => okBody({
          'knowledgePoint': 'x',
          'position': 'y',
          'whyWrong': 'z',
          'steps': ['a'],
          'pitfalls': <dynamic>[],
          'mnemonic': 'b',
        }),
      );

      await remote.ai.explainMistake(
        subject: '数学',
        knowledgePoint: '分数计算',
        title: '分数比较',
        wrongReason: '通分错',
      );
      await remote.ai.generatePractice(
        subject: '数学',
        knowledgePoint: '分数计算',
      );
      await remote.ai.referenceAnswerFor(
        subject: '数学',
        knowledgePoint: '分数计算',
      );

      expect(remote.probe.count, 0);
      expect(remote.degradations.length, 3);
      expect(
        remote.degradations.every((d) => d.code == 'capability_disabled'),
        isTrue,
      );
    });

    test('探活失败只是维持现状，不该被当成错误', () async {
      final remote = buildRemote(
        respond: (_) async => errorBody('internal', status: 500),
      );

      expect(await remote.ai.refreshCapabilities(), isNull);
      // 配置保持原样（默认全开），后续调用仍会正常尝试。
      expect(remote.ai.config.capabilities.reasoning, isTrue);
    });
  });

  group('配置层', () {
    test('默认值落在「完全离线」一侧，漏配环境变量不会产生费用', () {
      const config = AiConfig();
      expect(config.hasBackend, isFalse);
      expect(config.enabled, isTrue);
      expect(config.maxAttempts, 2);
      expect(config.imageTransport, AiImageTransport.inline);
    });

    test('总开关关掉后即使配了地址也不走云端', () {
      final config = _remoteConfig.copyWith(enabled: false);
      expect(config.hasBackend, isFalse);
    });

    test('能力开关可以由服务端回报修正', () {
      const config = AiConfig(baseUrl: 'https://gw.test');
      final updated = config.withCapabilities(
        const AiCapabilities(vision: false, reasoning: true, light: false),
      );
      expect(updated.capabilities.vision, isFalse);
      expect(updated.capabilities.reasoning, isTrue);
    });

    test('端点表按业务动作划分，不含厂商或模型字样', () {
      for (final path in [
        AiEndpoints.health,
        AiEndpoints.homeworkOcr,
        AiEndpoints.homeworkCheck,
        AiEndpoints.reviewJudge,
        AiEndpoints.reviewExplain,
        AiEndpoints.reviewPractice,
        AiEndpoints.reviewReferenceBatch,
        AiEndpoints.uploadsSign,
      ]) {
        expect(path, startsWith('/ai/'));
        expect(path.toLowerCase().contains('doubao'), isFalse);
        expect(path.toLowerCase().contains('ark'), isFalse);
      }
    });
  });

  group('批量参考答案', () {
    List<ReferenceQuery> threeQueries() => const [
      ReferenceQuery(subject: '数学', knowledgePoint: '分数加减'),
      ReferenceQuery(subject: '数学', knowledgePoint: '比例应用'),
      ReferenceQuery(subject: '语文', knowledgePoint: '病句修改'),
    ];

    test('一次往返取回多条，按 index 装配而不是按数组位置', () async {
      final remote = buildRemote(
        respond: (_) async => okBody({
          // 刻意乱序：真实模型不保证顺序，模型也不保证长度。
          // 按位置装配的话，第 3 题的答案会落到第 1 题上，且不报任何错。
          'answers': [
            {'index': 2, 'referenceAnswer': '病句：先找主干，再看搭配。'},
            {'index': 0, 'referenceAnswer': '分数：先通分再加减。'},
            {'index': 1, 'referenceAnswer': '比例：设未知数，列等量关系。'},
          ],
        }),
      );

      final answers = await remote.ai.referenceAnswersFor(threeQueries());

      expect(remote.probe.count, 1, reason: '三条必须压成一次往返');
      expect(
        remote.probe.requests.single.url.path,
        AiEndpoints.reviewReferenceBatch,
      );
      expect(answers['数学\u0000分数加减'], '分数：先通分再加减。');
      expect(answers['数学\u0000比例应用'], '比例：设未知数，列等量关系。');
      expect(answers['语文\u0000病句修改'], '病句：先找主干，再看搭配。');
    });

    test('同知识点的题只发一条，但返回覆盖全部入参', () async {
      final remote = buildRemote(
        respond: (_) async => okBody({
          'answers': [
            {'index': 0, 'referenceAnswer': '分数：先通分再加减。'},
            {'index': 1, 'referenceAnswer': '比例：设未知数列等式。'},
            {'index': 2, 'referenceAnswer': '病句：先找主干。'},
          ],
        }),
      );

      // 四条请求里「分数加减」重复了一次。
      final queries = const [
        ReferenceQuery(subject: '数学', knowledgePoint: '分数加减'),
        ReferenceQuery(subject: '数学', knowledgePoint: '分数加减'),
        ReferenceQuery(subject: '数学', knowledgePoint: '比例应用'),
        ReferenceQuery(subject: '语文', knowledgePoint: '病句修改'),
      ];
      final answers = await remote.ai.referenceAnswersFor(queries);

      final items = remote.probe.lastBody['items'] as List<dynamic>;
      expect(items.length, 3, reason: '同一知识点重复问一遍是白花钱');
      expect(answers.length, 3);
      expect(answers['数学\u0000分数加减'], '分数：先通分再加减。');
      // 重复的那一条也拿得到答案：去重发生在请求侧，不是让它少一条。
      for (final query in queries) {
        expect(answers[query.key], isNotEmpty, reason: '${query.knowledgePoint} 缺答案');
      }
    });

    test('去重后只剩一个知识点时，连批量端点都不用发', () async {
      final remote = buildRemote(
        respond: (_) async => okBody({'referenceAnswer': '分数：先通分。'}),
      );

      final answers = await remote.ai.referenceAnswersFor(const [
        ReferenceQuery(subject: '数学', knowledgePoint: '分数加减'),
        ReferenceQuery(subject: '数学', knowledgePoint: '分数加减'),
      ]);

      expect(remote.probe.requests.single.url.path, AiEndpoints.reviewPractice);
      expect(answers['数学\u0000分数加减'], '分数：先通分。');
    });

    test('只有一条时走单条接口，不做无谓的批量组装', () async {
      final remote = buildRemote(
        respond: (_) async => okBody({'referenceAnswer': '分数：先通分。'}),
      );

      final answers = await remote.ai.referenceAnswersFor(const [
        ReferenceQuery(subject: '数学', knowledgePoint: '分数加减'),
      ]);

      expect(remote.probe.requests.single.url.path, AiEndpoints.reviewPractice);
      expect(answers['数学\u0000分数加减'], '分数：先通分。');
    });

    test('模型漏条目时只补缺的那几条，并如实报一次降级', () async {
      final remote = buildRemote(
        respond: (_) async => okBody({
          'answers': [
            {'index': 0, 'referenceAnswer': '分数：先通分再加减。'},
          ],
        }),
      );

      final answers = await remote.ai.referenceAnswersFor(threeQueries());

      // 印出去的卷子不允许某道题没有参考答案 —— 学生做完没法对错。
      expect(answers.length, 3);
      expect(answers['数学\u0000分数加减'], '分数：先通分再加减。');
      expect(answers['数学\u0000比例应用'], isNotEmpty);

      final partial = remote.degradations.single;
      expect(partial.code, 'partial_reference');
      expect(partial.reason, contains('比例应用'));
      // 说清是「部分」而不是整批降级，否则运维会以为模型整个挂了。
      expect(partial.reason, contains('1/3'));
    });

    test('格式不对的条目单条跳过，不拿另外 19 道题陪葬', () async {
      final remote = buildRemote(
        respond: (_) async => okBody({
          'answers': [
            {'index': 0, 'referenceAnswer': '分数：先通分再加减。'},
            'garbage',
            {'index': 99, 'referenceAnswer': '越界的下标'},
            {'index': 1, 'referenceAnswer': '   '},
          ],
        }),
      );

      final answers = await remote.ai.referenceAnswersFor(threeQueries());

      expect(answers.length, 3);
      expect(answers['数学\u0000分数加减'], '分数：先通分再加减。');
      expect(remote.degradations.single.code, 'partial_reference');
    });

    test('整批失败时回落到本地逐条，答案依然齐', () async {
      final remote = buildRemote(
        respond: (_) async =>
            errorBody('model_not_enabled', status: 503, retryable: false),
      );

      final answers = await remote.ai.referenceAnswersFor(threeQueries());

      expect(answers.length, 3);
      for (final answer in answers.values) {
        expect(answer, isNotEmpty);
      }
      expect(remote.degradations.single.code, 'model_not_enabled');
    });
  });

  group('批改来源', () {
    test('云端结果标 cloud，降级结果标 local —— 家长端靠它区分模板与模型', () async {
      final storage = LocalImageStorageService(useMemory: true);
      final key = await saveImage(storage, [1, 2, 3]);

      final cloud = buildRemote(
        storage: storage,
        // ⚠️ 合法响应：score 100 + items 空（B29 的不变式：items 空 ⇒
        // score 必须 100）。原先是 `score:96, items:[]` —— 自相矛盾，
        // 会被 validate 重试、仍矛盾就**降级 local**，这条测「来源
        // 标记」的用例就永远到不了 cloud。矛盾路径有专门判据。
        respond: (_) async => okBody({
          'score': 100,
          'summary': '模型批改结论',
          'items': <dynamic>[],
        }),
      );
      final cloudOutcome = await cloud.ai.checkHomework(
        subject: '数学',
        title: '数学作业A',
        imagePaths: [key],
      );
      expect(cloudOutcome.source, AiAnswerSource.cloud);
      expect(cloudOutcome.source.isCloud, isTrue);

      // 同一条链路，网关不可用时。
      final local = buildRemote(
        storage: storage,
        respond: (_) async => errorBody('model_unavailable'),
      );
      final localOutcome = await local.ai.checkHomework(
        subject: '数学',
        title: '数学作业A',
        imagePaths: [key],
      );
      expect(localOutcome.source, AiAnswerSource.local);
      expect(local.degradations, isNotEmpty);
    });

    test('本地实现产出的结果默认标 local，拿不准时不冒充模型输出', () async {
      const simulated = SimulatedAiDataSource();
      final outcome = await simulated.checkHomework(
        subject: '数学',
        title: '数学作业A',
      );
      expect(outcome.source, AiAnswerSource.local);
    });
  });

  group('请求头', () {
    test('带上学生身份与请求 ID，便于配额与排障', () async {
      final remote = buildRemote(
        respond: (_) async => okBody({
          'verdict': 'correct',
          'score': 100,
          'comment': 'x',
        }),
      );

      await remote.ai.judgeAnswer(studentAnswer: 'x', referenceAnswer: 'x');

      final headers = remote.probe.requests.single.headers;
      expect(headers['x-student-id'], 'stu_1');
      expect(headers['x-request-id'], isNotEmpty);
      expect(headers['content-type'], contains('utf-8'));
      // 过渡期没有会话 token，不该硬塞一个假的 Authorization。
      expect(headers.containsKey('authorization'), isFalse);
    });
  });

  group('知识点提示', () {
    const seeds = [
      MistakeTipSeed(knowledgePoint: '分式化简', wrongCount: 3, wrongReason: '没通分'),
      MistakeTipSeed(knowledgePoint: '勾股定理'),
    ];

    test('按契约解析，并只发知识点摘要（不发题干与照片）', () async {
      final remote = buildRemote(
        respond: (_) async => okBody({
          'tips': [
            {'knowledgePoint': '分式化简', 'text': '先通分，分子相加减时分母不动。'},
          ],
        }),
      );

      final tips = await remote.ai.summarizeMistakeTips(
        subject: '数学',
        items: seeds,
      );

      expect(tips.single.knowledgePoint, '分式化简');
      expect(tips.single.source, KnowledgeTipSource.model);

      final body = remote.probe.lastBody;
      expect(body['subject'], '数学');
      final items = body['items'] as List;
      expect(items, hasLength(2));
      expect((items.first as Map)['wrongCount'], 3);
      expect((items.first as Map)['wrongReason'], '没通分');
      expect(
        (items.last as Map).containsKey('wrongReason'),
        isFalse,
        reason: '空错因不必上行；它不是提示的依据',
      );
    });

    test('模型造了一个请求里没有的知识点：丢掉那条，其余照用', () async {
      final remote = buildRemote(
        respond: (_) async => okBody({
          'tips': [
            {'knowledgePoint': '自创知识点', 'text': '听起来很对的一句。'},
            {'knowledgePoint': '勾股定理', 'text': r'$a^2+b^2=c^2$。'},
          ],
        }),
      );

      final tips = await remote.ai.summarizeMistakeTips(
        subject: '数学',
        items: seeds,
      );

      expect(tips.map((tip) => tip.knowledgePoint), ['勾股定理']);
      expect(
        remote.probe.count,
        1,
        reason: '有一条能用就不该整批重试 —— 那会把另外几条好的也丢掉',
      );
    });

    test('一条都挂不回去：重试一次后降级到本地规则提示', () async {
      final remote = buildRemote(
        respond: (_) async => okBody({
          'tips': [
            {'knowledgePoint': '自创知识点', 'text': '听起来很对的一句。'},
          ],
        }),
      );

      final tips = await remote.ai.summarizeMistakeTips(
        subject: '数学',
        items: seeds,
      );

      expect(tips.every((tip) => tip.source == KnowledgeTipSource.rule), isTrue);
      expect(tips, isNotEmpty, reason: '降级也要有东西可显示');
      expect(remote.probe.count, 2, reason: '应当带着原因重试一次');
      expect(remote.degradations, isNotEmpty);
    });
  });
}
