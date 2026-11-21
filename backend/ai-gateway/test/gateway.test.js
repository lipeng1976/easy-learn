import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { closeSync, mkdtempSync, openSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { issueSessionToken } from '../src/auth.js';
import { loadConfig } from '../src/config.js';
import { createGateway, toRequest } from '../src/handler.js';
import { MockModelClient } from '../src/mock-model.js';
import { assertCapturedShape, fc3HttpEvent } from '../../shared/fc3-http-event.js';

/** 一个可直接调用的网关，时钟可控、模型是确定性的 mock。 */
function buildGateway(envOverrides = {}, overrides = {}) {
  const config = loadConfig({
    AI_MODEL_CLIENT: 'mock',
    AI_UPLOAD_URL_BASE: 'https://gw.test',
    AI_UPLOAD_SIGNING_SECRET: 'test-secret',
    ...envOverrides,
  });
  let fakeNow = Date.parse('2026-09-15T10:00:00Z');
  const audits = [];
  const gateway = createGateway({
    config,
    now: () => fakeNow,
    onAudit: (record) => audits.push(record),
    ...overrides,
  });
  return {
    gateway,
    config,
    audits,
    advance: (ms) => {
      fakeNow += ms;
    },
  };
}

/**
 * 同上，但把 mock 模型客户端**交出来**。
 *
 * 有几条判据要看的不是响应，而是「模型到底收到了什么、被调用了几次」——
 * 例如「没照片时一次都不许调模型」。这类断言只能从客户端对象上读，
 * 光看响应体区分不了「没调模型」和「调了但结果恰好也对」。
 */
function buildGatewayWithModel(envOverrides = {}) {
  const config = loadConfig({
    AI_MODEL_CLIENT: 'mock',
    AI_UPLOAD_URL_BASE: 'https://gw.test',
    AI_UPLOAD_SIGNING_SECRET: 'test-secret',
    ...envOverrides,
  });
  const model = new MockModelClient({ config });
  const audits = [];
  const gateway = createGateway({
    config,
    model,
    onAudit: (record) => audits.push(record),
  });
  return { gateway, config, model, audits };
}

async function call(gateway, options = {}) {
  const {
    method = 'POST',
    path,
    body,
    query = {},
    headers = {},
    rawBody = null,
    bodyInvalid = false,
  } = options;

  const response = await gateway.handle({
    method,
    path,
    query,
    headers: { 'x-student-id': 'stu_test', ...headers },
    body,
    bodyInvalid,
    rawBody,
  });

  const isJson = String(response.headers['Content-Type']).includes('json');
  return {
    status: response.status,
    body: response.body,
    json: isJson && response.body !== '' ? JSON.parse(response.body) : null,
    headers: response.headers,
  };
}

const IMAGE = { base64: 'aGVsbG8=', mimeType: 'image/jpeg' };

// ===== 基础路由 =====

test('探活返回能力开关，且不需要身份', async () => {
  const { gateway } = buildGateway();
  const result = await call(gateway, {
    method: 'GET',
    path: '/ai/health',
    headers: { 'x-student-id': '' },
  });

  assert.equal(result.status, 200);
  assert.deepEqual(result.json.data.capabilities, {
    vision: true,
    reasoning: true,
    light: true,
  });
  assert.equal(result.json.data.region, 'cn-beijing');
  assert.equal(result.json.data.modelClient, 'mock');
  // 响应里不该出现模型 ID：客户端不需要知道背后是哪个模型，换模型不该要求发版。
  assert.equal(JSON.stringify(result.json).includes('doubao'), false);
});

test('未知端点 404，方法不对 405', async () => {
  const { gateway } = buildGateway();
  const notFound = await call(gateway, { path: '/ai/nope' });
  assert.equal(notFound.status, 404);
  assert.equal(notFound.json.error.code, 'not_found');

  const wrongMethod = await call(gateway, { method: 'GET', path: '/ai/review/judge' });
  assert.equal(wrongMethod.status, 405);
  assert.equal(wrongMethod.json.error.code, 'method_not_allowed');
});

test('缺少学生标识时明确拒绝，而不是静默放行', async () => {
  const { gateway } = buildGateway();
  const result = await call(gateway, {
    path: '/ai/review/judge',
    headers: { 'x-student-id': '' },
    body: { studentAnswer: '1', referenceAnswer: '1' },
  });
  assert.equal(result.status, 400);
  assert.equal(result.json.error.code, 'bad_request');
});

test('学生标识格式非法时拒绝（它会进缓存键与审计日志）', async () => {
  const { gateway } = buildGateway();
  const result = await call(gateway, {
    path: '/ai/review/judge',
    headers: { 'x-student-id': 'stu_1; drop table' },
    body: { studentAnswer: '1', referenceAnswer: '1' },
  });
  assert.equal(result.status, 400);
});

test('开启 requireAuth 后没带 token 会被拒', async () => {
  const { gateway } = buildGateway({
    AI_REQUIRE_AUTH: 'true',
    AI_SESSION_SECRET: 'session-secret',
  });
  const result = await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: '1', referenceAnswer: '1' },
  });
  assert.equal(result.status, 401);
  assert.equal(result.json.error.code, 'unauthorized');
});

test('requireAuth 打开后学号只认 token，请求头里的学号被忽略', async () => {
  // 这是强鉴权能不能成立的关键：如果两者都接受，伪造者只要继续带头
  // 就绕过了整套机制，而外部看起来「已经加了鉴权」。
  const { gateway, config } = buildGateway({
    AI_REQUIRE_AUTH: 'true',
    AI_SESSION_SECRET: 'session-secret',
  });
  const token = issueSessionToken({
    secret: config.auth.sessionSecret,
    studentId: 'stu_real',
    now: Date.parse('2026-09-15T10:00:00Z'),
  });

  const result = await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: '1', referenceAnswer: '1' },
    headers: { authorization: `Bearer ${token}`, 'x-student-id': 'stu_fake' },
  });

  assert.equal(result.status, 200);
  // 审计里记的必须是 token 里那个人，而不是请求头声明的那个。
  const record = gateway.guard.recentEvents().at(-1);
  assert.equal(record.studentId, 'stu_real');
});

test('过期 token 回 token_expired 而不是笼统的 unauthorized', async () => {
  // 两个码的客户端处置完全不同：过期应当静默续签，无效只能重新登录。
  const { gateway, config, advance } = buildGateway({
    AI_REQUIRE_AUTH: 'true',
    AI_SESSION_SECRET: 'session-secret',
  });
  const token = issueSessionToken({
    secret: config.auth.sessionSecret,
    studentId: 'stu_real',
    ttlSeconds: 60,
    now: Date.parse('2026-09-15T10:00:00Z'),
  });

  advance(61_000);
  const result = await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: '1', referenceAnswer: '1' },
    headers: { authorization: `Bearer ${token}` },
  });

  assert.equal(result.status, 401);
  assert.equal(result.json.error.code, 'token_expired');
});

test('签名被改过的 token 回 token_invalid', async () => {
  const { gateway, config } = buildGateway({
    AI_REQUIRE_AUTH: 'true',
    AI_SESSION_SECRET: 'session-secret',
  });
  const token = issueSessionToken({
    secret: config.auth.sessionSecret,
    studentId: 'stu_real',
    now: Date.parse('2026-09-15T10:00:00Z'),
  });
  const tamperedBody = Buffer.from(
    JSON.stringify({ v: 1, sub: 'stu_other', iat: 0, exp: 9999999999 }),
    'utf8',
  ).toString('base64url');

  const result = await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: '1', referenceAnswer: '1' },
    headers: { authorization: `Bearer ${tamperedBody}.${token.split('.')[2]}` },
  });

  assert.equal(result.status, 401);
  assert.equal(result.json.error.code, 'token_invalid');
});

test('requireAuth 与 sessionSecret 不匹配时启动即失败，而不是静默全放行', async () => {
  assert.throws(
    () => buildGateway({ AI_REQUIRE_AUTH: 'true' }),
    /AI_SESSION_SECRET/,
  );
});

/**
 * 跑一个 node 子进程并收下它的输出 —— **用临时文件，不用管道**。
 *
 * ## 为什么不能用 `encoding: 'utf8'` / `stdio: 'pipe'`
 *
 * 那会让 Node 为子进程建管道，而这台机器（2026-09-24 实测）**建管道会失败**：
 *
 * ```
 * execFileSync(node, [...], { encoding: 'utf8' })   → EBUSY   （连 5 次全 EBUSY）
 * execFileSync(node, [...], { stdio: 'ignore' })    → ok      （连 5 次全 ok）
 * ```
 *
 * 管道在 Windows 上就是文件句柄 —— 这与 `CreateFile failed 231` 是同一族
 * （句柄被耗尽）。用临时文件接输出就绕开了它，于是这两条判据能**真的跑起来**。
 *
 * ## 踩过的坑：探测必须用与真调用**相同的形态**
 *
 * 第一版这里的守卫是「`stdio:'ignore'` 试一下，不行就 skip」。而它**能过**
 * （见上表），于是测试没跳过、继续用管道调用、然后 EBUSY 失败。
 * 教训：**探测用的形态与真调用不一致时，探测本身就成了一条假线索** ——
 * 它把你送进「明明探测通过却失败了」的困惑里，比不做探测更糟。
 *
 * ## 拿不到退出码 = 子进程压根没起来
 *
 * `execFileSync` 在「子进程正常退出但码非 0」与「起不来」两种情况下都会抛。
 * 区分它们的唯一依据是 `error.status` 是不是数字：是这个字段才说明
 * 子进程**真的跑过**。不区分的话，「脚本拒绝了」与「脚本没被跑起来」
 * 看起来一模一样 —— 而那正是这条判据要回答的问题。
 */
function runNodeCapture(script, args, env) {
  const dir = mkdtempSync(join(tmpdir(), 'gw-spawn-'));
  const outPath = join(dir, 'out.txt');
  const errPath = join(dir, 'err.txt');
  const outFd = openSync(outPath, 'w');
  const errFd = openSync(errPath, 'w');

  let status = null;
  let spawnError = null;
  try {
    execFileSync(process.execPath, [script, ...args], {
      env,
      stdio: ['ignore', outFd, errFd],
    });
    status = 0;
  } catch (error) {
    if (typeof error.status === 'number') status = error.status;
    else spawnError = error;
  } finally {
    closeSync(outFd);
    closeSync(errFd);
  }

  const result = {
    status,
    spawnError,
    stdout: readFileSync(outPath, 'utf8'),
    stderr: readFileSync(errPath, 'utf8'),
  };
  rmSync(dir, { recursive: true, force: true });
  return result;
}

const SCRIPT_PATH = fileURLToPath(
  new URL('../scripts/issue-session-token.mjs', import.meta.url),
);

test('签发脚本真实存在，且产出的 token 能被校验回来', async (t) => {
  // config.js 的注释里点名了这个脚本。注释指向一个不存在的文件，
  // 下次要签 token 的人就会先去「找一个根本没有的东西」——
  // 这条断言让它没法悄悄失效。
  const result = runNodeCapture(SCRIPT_PATH, ['stu_cli'], {
    ...process.env,
    AI_SESSION_SECRET: 'cli-secret',
  });

  if (result.spawnError) {
    t.skip(`子进程起不来（${result.spawnError.code}）→ 这条判据在这里测不了，跳过而不是判通过`);
    return;
  }
  assert.equal(result.status, 0, `脚本该正常退出，实际退出码 ${result.status}：${result.stderr}`);

  const token = result.stdout.trim();
  const { verifySessionToken } = await import('../src/auth.js');
  const identity = verifySessionToken(token, { secret: 'cli-secret' });
  assert.equal(identity.studentId, 'stu_cli');
  // 换个密钥必须验不过：不然「签发」就只是个字符串生成器。
  assert.throws(() => verifySessionToken(token, { secret: 'wrong' }));
});

test('没有密钥时签发脚本拒绝执行，而不是签出一个永远验不过的 token', async (t) => {
  const result = runNodeCapture(SCRIPT_PATH, ['stu_cli'], {
    ...process.env,
    AI_SESSION_SECRET: '',
  });

  if (result.spawnError) {
    t.skip(`子进程起不来（${result.spawnError.code}）→ 这条判据在这里测不了，跳过而不是判通过`);
    return;
  }

  assert.notEqual(result.status, 0, '没有密钥却正常退出了 —— 那这个「拒绝」是假的');

  // ⚠️ 必须点名**具体原因**，不能只断言「非 0 退出」：
  //    脚本因为别的理由崩掉（比如 import 出错）也是非 0 退出。
  //    要求 stderr 里出现那个变量名，才是「它自己识别出缺密钥」的证据。
  assert.match(
    result.stderr,
    /AI_SESSION_SECRET/,
    `该由脚本自己报「缺少密钥」，实际 stderr 是：${JSON.stringify(result.stderr.slice(0, 200))}`,
  );
});

test('请求体不是合法 JSON 时报 bad_request', async () => {
  const { gateway } = buildGateway();
  const result = await call(gateway, {
    path: '/ai/review/judge',
    bodyInvalid: true,
  });
  assert.equal(result.status, 400);
  assert.match(result.json.error.message, /合法 JSON/);
});

// ===== 判定：规则优先 =====

test('空答案由规则直接判定，不花模型调用', async () => {
  const { gateway } = buildGateway();
  const result = await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: '   ', referenceAnswer: '11/12' },
  });

  assert.equal(result.status, 200);
  assert.equal(result.json.data.verdict, 'wrong');
  assert.equal(result.json.meta.model, 'rule');
  // 关键断言：规则能定的不进模型。这也是成本结构最好的一档。
  assert.equal(gateway.model.calls.length, 0);
});

test('判定返回三态之一，且带上 requestId 便于对日志', async () => {
  const { gateway } = buildGateway();
  const result = await call(gateway, {
    path: '/ai/review/judge',
    body: {
      studentAnswer: '11/12',
      referenceAnswer: '11/12',
      subject: '数学',
      knowledgePoint: '分数计算',
    },
  });

  assert.equal(result.status, 200);
  assert.ok(['correct', 'wrong', 'inconclusive'].includes(result.json.data.verdict));
  assert.ok(result.json.meta.requestId);
  assert.equal(result.json.meta.model, 'mock');
});

// ===== 批改 =====

test('批改不提供照片时明确报错，不让模型凭空编错题', async () => {
  const { gateway } = buildGateway();
  const result = await call(gateway, {
    path: '/ai/homework/check',
    body: { subject: '数学', title: '数学作业A', images: [] },
  });

  assert.equal(result.status, 400);
  assert.match(result.json.error.message, /必须提供至少一张照片/);
  assert.equal(gateway.model.calls.length, 0);
});

test('批改返回的形状与客户端契约一致', async () => {
  const { gateway } = buildGateway();
  const result = await call(gateway, {
    path: '/ai/homework/check',
    body: { subject: '数学', title: '数学作业A', images: [IMAGE] },
  });

  assert.equal(result.status, 200);
  const data = result.json.data;
  assert.equal(typeof data.score, 'number');
  assert.equal(typeof data.summary, 'string');
  assert.ok(Array.isArray(data.items));
  for (const item of data.items) {
    assert.ok(item.knowledgePoint);
    assert.ok(typeof item.originalAnswer === 'string');
    assert.ok(item.wrongReason);
  }
});

test('照片超出张数上限回 413（客户端能自己修，不该被当成模型故障）', async () => {
  const { gateway, config } = buildGateway();
  const result = await call(gateway, {
    path: '/ai/homework/check',
    body: {
      subject: '数学',
      title: '作业',
      images: Array.from({ length: config.maxImages + 1 }, () => IMAGE),
    },
  });

  assert.equal(result.status, 413);
  assert.equal(result.json.error.code, 'payload_too_large');
  assert.equal(result.json.error.retryable, false);
});

// ===== 批改：图形题复核 =====

/**
 * 图形题复核的用例，全部围绕 2026-10-23 那张真实照片：
 * 学法 P51 第 10 题，学生在 L 形图上写了两式，**两式都错**，
 * 而批改给的是 `score=100, items=0`。
 *
 * 判据的关键不是「复核模型说了什么」，而是「程序算出来什么」——
 * 复核模型和第一次批改是同一个视觉模型，它当时就没算。
 */
const FIGURE_QUESTION = {
  questionNo: '10',
  question: '用不同的方法表示下图的面积（至少写出两种）。',
  // 照片上两行手写，OCR 实测一字不差。第一行把 b-d 写成了 b-a。
  studentWork: 'S = ad + (b-a)c\nS = bc - (b-a)(d-c)',
};

function buildFigureGateway(verifyRow) {
  const config = loadConfig({ AI_MODEL_CLIENT: 'mock' });
  const model = new MockModelClient({
    config,
    intercept: (callInfo) => {
      if (callInfo.schemaName === 'report_homework_check') {
        return {
          value: {
            score: 100,
            summary: '本次作业全部正确，代数式列写和图形面积计算都掌握得很好。',
            items: [],
            figureQuestions: [FIGURE_QUESTION],
          },
        };
      }
      if (callInfo.schemaName === 'report_figure_verify') {
        return {
          value: {
            results: [
              {
                question: FIGURE_QUESTION.question,
                knowledgePoint: '组合图形面积计算',
                variables: ['a', 'b', 'c', 'd'],
                preferredValues: { a: 4, b: 7, c: 2, d: 3 },
                ...verifyRow,
              },
            ],
          },
        };
      }
      return null;
    },
  });
  return buildGateway({}, { model });
}

test('图形题复核：学生式子算不平，就必须升格成错题（当时漏判的就是这道）', async () => {
  const { gateway } = buildFigureGateway({
    referenceExpressions: ['ad + c(b-d)', 'ab - (a-c)(b-d)'],
    studentExpressions: ['ad + (b-a)c', 'bc - (b-a)(d-c)'],
    verdict: 'correct',
    reason: '看起来成立。',
  });

  const result = await call(gateway, {
    path: '/ai/homework/check',
    body: { subject: '数学', title: '第三章 代数式 学法 P51', images: [IMAGE] },
  });

  assert.equal(result.status, 200);
  const data = result.json.data;
  assert.equal(data.items.length, 1, '两式都算不平，必须出现一条错题');
  assert.equal(data.items[0].questionNo, '10');
  assert.equal(data.items[0].knowledgePoint, '组合图形面积计算');
  assert.match(data.items[0].wrongReason, /18/, '错因里要有验算出来的数字');
  assert.match(data.items[0].wrongReason, /20/, '错因里要有正确结果');
  assert.notEqual(data.score, 100, '有错题就不能还是满分');
  assert.doesNotMatch(data.summary, /全部正确/, '摘要不能一边说全对一边挂着错题');
  assert.deepEqual(result.json.meta.figureVerify, { status: 'ok', checked: 1, added: 1 });
  assert.equal(
    gateway.model.calls.filter((c) => c.schemaName === 'report_figure_verify').length,
    1,
    '复核只该调一次（批量），不是每道题调一次',
  );
});

test('图形题复核：学生其实写对了，一条错题都不许加', async () => {
  // 同一道题，但这次学生写的是分割法的正确式子。
  const { gateway } = buildFigureGateway({
    referenceExpressions: ['ad + c(b-d)', 'ab - (a-c)(b-d)'],
    studentExpressions: ['ad + c(b-d)'],
    verdict: 'correct',
    reason: '分割法成立。',
  });

  const result = await call(gateway, {
    path: '/ai/homework/check',
    body: { subject: '数学', title: '第三章 代数式 学法 P51', images: [IMAGE] },
  });

  assert.equal(result.status, 200);
  assert.equal(result.json.data.items.length, 0);
  assert.equal(result.json.data.score, 100);
  assert.equal(result.json.meta.figureVerify.added, 0);
});

test('图形题复核：程序算不了时维持原判（复核模型说错也不算）', async () => {
  // 参考式用了求值器不支持的写法。此时「算不出来」≠「学生错了」：
  // 判成错题会把一个做对的学生塞进错题库，比漏判更糟。
  const { gateway } = buildFigureGateway({
    referenceExpressions: ['\\sqrt{a}'],
    studentExpressions: ['a'],
    verdict: 'wrong',
    reason: '两边不相等。',
  });

  const result = await call(gateway, {
    path: '/ai/homework/check',
    body: { subject: '数学', title: '第三章 代数式 学法 P51', images: [IMAGE] },
  });

  assert.equal(result.status, 200);
  assert.equal(result.json.data.items.length, 0, '算不出来就必须放行，不能凭空判错');
  assert.equal(result.json.meta.figureVerify.added, 0);
});

test('图形题复核：模型把学生的错式当成参考答案时，不许写进错题', async () => {
  // 2026-10-23 实测就是这个样子：references 的第一条 `ad+(b-a)c`
  // 正是学生写错的式子。不剔的话，错题库里会出现一条「参考答案：错式」——
  // 学生下次重做时对着一份错的答案看，比没有答案更糟。
  const { gateway } = buildFigureGateway({
    referenceExpressions: ['ad + (b-a)c', 'ab - (b-d)(a-c)'],
    studentExpressions: ['ad + (b-a)c', 'bc - (b-a)(d-c)'],
    verdict: 'correct',
    reason: '看起来成立。',
  });

  const result = await call(gateway, {
    path: '/ai/homework/check',
    body: { subject: '数学', title: '第三章 代数式 学法 P51', images: [IMAGE] },
  });

  assert.equal(result.status, 200);
  const item = result.json.data.items[0];
  assert.ok(item, '第二个式子确实算不平，必须报出来');
  assert.doesNotMatch(item.standardAnswer, /\(b-a\)c/, '学生写错的式子不许当参考答案');
  assert.match(item.standardAnswer, /ab - \(b-d\)\(a-c\)/);
  assert.doesNotMatch(item.wrongReason, /正确结果 ad \+ \(b-a\)c/, '错因不许把错式说成正确结果');
  assert.match(item.wrongReason, /20/, '正确结果要算出 20');
});

test('图形题复核：拿几何轮廓算面积，模型参考式写错也不会冤枉学生', async () => {
  // 真实复现（2026-10-23 第二次实测）：模型给的参考式是
  // `bc-(b-d)(a-c)`，代 a=5,b=8,c=3,d=4 算出 16；
  // 而轮廓画出来是 8×5 减掉 4×2，真实面积 32 —— 它把 ab 写成了 bc。
  //
  // 拿那个参考式当判据，一个写对了的学生也会被判错。所以只要模型
  // 交了轮廓点，就以鞋带公式算出的面积为准。
  const { gateway } = buildFigureGateway({
    referenceExpressions: ['bc - (b-d)(a-c)'],
    studentExpressions: ['ad+(b-a)c', 'bc-(b-a)(d-c)'],
    preferredValues: { a: 5, b: 8, c: 3, d: 4 },
    outline: [
      { x: 0, y: 0 }, { x: 8, y: 0 }, { x: 8, y: 3 },
      { x: 4, y: 3 }, { x: 4, y: 5 }, { x: 0, y: 5 },
    ],
    verdict: 'correct',
    reason: '看起来成立。',
  });

  const result = await call(gateway, {
    path: '/ai/homework/check',
    body: { subject: '数学', title: '第三章 代数式 学法 P51', images: [IMAGE] },
  });

  assert.equal(result.status, 200);
  const item = result.json.data.items[0];
  assert.ok(item, '两式都算不平，必须报出来');
  assert.match(item.wrongReason, /面积是 32/, '错因里的面积必须来自轮廓，不是模型算的 16');
  assert.equal(
    item.standardAnswer,
    '',
    '参考式算出来是 16、与面积 32 不符 —— 宁可不给答案，也不能给一个错的',
  );
});

test('图形题复核：轮廓算出的面积与学生式子一致时不升级', async () => {
  const { gateway } = buildFigureGateway({
    referenceExpressions: ['ad + c(b-d)'],
    studentExpressions: ['ad+c(b-d)'],
    preferredValues: { a: 5, b: 8, c: 3, d: 4 },
    outline: [
      { x: 0, y: 0 }, { x: 8, y: 0 }, { x: 8, y: 3 },
      { x: 4, y: 3 }, { x: 4, y: 5 }, { x: 0, y: 5 },
    ],
    verdict: 'correct',
    reason: '分割法成立。',
  });

  const result = await call(gateway, {
    path: '/ai/homework/check',
    body: { subject: '数学', title: '第三章 代数式 学法 P51', images: [IMAGE] },
  });

  assert.equal(result.status, 200);
  assert.equal(result.json.data.items.length, 0, '学生写的是正确式子，不能报成错题');
  assert.equal(result.json.data.score, 100);
});

test('不含图的作业不触发复核（每次批改都复核等于让费用翻倍）', async () => {
  const { gateway, model } = buildGatewayWithModel();

  await call(gateway, {
    path: '/ai/homework/check',
    body: { subject: '数学', title: '纯文字作业', images: [IMAGE] },
  });

  assert.equal(
    model.calls.filter((c) => c.schemaName === 'report_figure_verify').length,
    0,
  );
  assert.equal(model.calls.length, 1, '只有一次批改调用');
});

// ===== 缓存 =====

test('相同输入第二次直接命中缓存，不再调用模型', async () => {
  const { gateway } = buildGateway();
  const body = {
    studentAnswer: '11/12',
    referenceAnswer: '11/12',
    knowledgePoint: '分数计算',
  };

  const first = await call(gateway, { path: '/ai/review/judge', body });
  const callsAfterFirst = gateway.model.calls.length;

  const second = await call(gateway, { path: '/ai/review/judge', body });

  assert.equal(first.json.meta.cached, false);
  assert.equal(second.json.meta.cached, true);
  assert.deepEqual(second.json.data, first.json.data);
  assert.equal(gateway.model.calls.length, callsAfterFirst);
});

test('输入变了就不再命中缓存', async () => {
  const { gateway } = buildGateway();
  await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: '11/12', referenceAnswer: '11/12' },
  });
  await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: '10/12', referenceAnswer: '11/12' },
  });

  assert.equal(gateway.model.calls.length, 2);
});

test('缓存过期后重新调用模型', async () => {
  const { gateway, config, advance } = buildGateway();
  const body = { studentAnswer: '1', referenceAnswer: '1' };

  await call(gateway, { path: '/ai/review/judge', body });
  advance(config.cacheTtlMs + 1000);
  const result = await call(gateway, { path: '/ai/review/judge', body });

  assert.equal(result.json.meta.cached, false);
  assert.equal(gateway.model.calls.length, 2);
});

// ===== 配额（按成本权重） =====
//
// 这些用例把权重压成 1 或显式给一个小额度，让断言写的是「几次」而非「几个单位」——
// 单位本身的换算另有专门用例（见下）。

test('每分钟配额超限回 429 且标记可重试', async () => {
  const { gateway } = buildGateway({
    AI_WEIGHT_REASONING: '1',
    AI_QUOTA_UNITS_PER_MINUTE: '2',
  });

  await call(gateway, { path: '/ai/health', method: 'GET' });
  const first = await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: 'a', referenceAnswer: 'a' },
  });
  const second = await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: 'b', referenceAnswer: 'b' },
  });
  const third = await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: 'c', referenceAnswer: 'c' },
  });

  assert.equal(first.status, 200);
  assert.equal(second.status, 200);
  assert.equal(third.status, 429);
  assert.equal(third.json.error.code, 'rate_limited');
  assert.equal(third.json.error.retryable, true);
});

test('当日额度用完回 quota_exhausted，且明确不可重试', async () => {
  // 与限流分开是刻意的：限流等几十秒真能成，额度用完要等到明天。
  // 合成一个码的话，客户端会对一个当天不可能成功的请求反复退避重试。
  const { gateway } = buildGateway({
    AI_WEIGHT_REASONING: '1',
    AI_WEIGHT_VISION: '1',
    AI_QUOTA_UNITS_PER_DAY: '1',
  });

  const first = await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: 'a', referenceAnswer: 'a' },
  });
  const second = await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: 'b', referenceAnswer: 'b' },
  });

  assert.equal(first.status, 200);
  assert.equal(second.status, 429);
  assert.equal(second.json.error.code, 'quota_exhausted');
  assert.equal(second.json.error.retryable, false);
  // 报错要让用户看懂还剩什么可做，而不是抛一个「成本单位」给他。
  assert.match(second.json.error.message, /今天的 AI 额度用完了/);
  assert.equal(second.json.error.details.window, 'day');
});

test('按场景加权：同样一份额度，视觉能用的次数远少于判定', async () => {
  // 这是「按成本权重记账」的核心断言。按次数记账时，
  // 学生做 60 次文字解析就把额度用光，而拍照批改还剩着 —— 两头都错。
  const { gateway } = buildGateway({
    AI_QUOTA_UNITS_PER_MINUTE: '240',
    AI_QUOTA_UNITS_PER_DAY: '240',
    AI_WEIGHT_VISION: '8',
    AI_WEIGHT_REASONING: '2',
  });

  const quota = (await call(gateway, { path: '/ai/health', method: 'GET' })).json.data.quota;
  assert.equal(quota.dailyCalls.vision, 30);
  assert.equal(quota.dailyCalls.reasoning, 120);
  assert.deepEqual(quota.weights, { vision: 8, reasoning: 2, light: 1 });
});

test('缓存命中不扣额度（学生反复提交同一份作业不该把额度烧掉）', async () => {
  const { gateway } = buildGateway({
    AI_WEIGHT_REASONING: '1',
    AI_QUOTA_UNITS_PER_MINUTE: '1',
  });
  const body = { studentAnswer: 'a', referenceAnswer: 'a' };

  const first = await call(gateway, { path: '/ai/review/judge', body });
  // 第二次命中缓存：没有模型费用，额度应当退回去 ——
  // 不退的话它会被 429 挡住，而它一次模型调用都没触发。
  const second = await call(gateway, { path: '/ai/review/judge', body });

  assert.equal(first.status, 200);
  assert.equal(second.status, 200);
  assert.equal(second.json.meta.cached, true);
  assert.equal(second.json.meta.units, 0);
});

test('规则直接判定的调用不扣额度（空答案判定没有花钱）', async () => {
  const { gateway } = buildGateway({
    AI_WEIGHT_REASONING: '1',
    AI_QUOTA_UNITS_PER_MINUTE: '1',
  });

  // 不填答案 → 规则一句话定，不进模型。
  const ruleCall = await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: '', referenceAnswer: 'a' },
  });
  // 额度若被那次规则判定吃掉，这一次就会被 429 挡住。
  const modelCall = await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: 'b', referenceAnswer: 'b' },
  });

  assert.equal(ruleCall.status, 200);
  assert.equal(ruleCall.json.data.verdict, 'wrong');
  assert.equal(ruleCall.json.meta.model, 'rule');
  assert.equal(ruleCall.json.meta.units, 0);
  assert.equal(modelCall.status, 200);
});

test('参数不合法导致的失败不扣额度（没到模型就不该扣）', async () => {
  const { gateway } = buildGateway({
    AI_QUOTA_UNITS_PER_MINUTE: '8',
    AI_WEIGHT_VISION: '8',
  });

  // 不带照片的批改在参数层就被拒了，一次模型调用都没发生。
  const rejected = await call(gateway, {
    path: '/ai/homework/check',
    body: { subject: '数学', title: '口算', images: [] },
  });
  // 若那次拒绝也扣了额度，这次视觉调用（8 单位）就会撞上每分钟 8 单位的上限。
  const ok = await call(gateway, {
    path: '/ai/homework/check',
    body: { subject: '数学', title: '口算', images: [IMAGE] },
  });

  assert.equal(rejected.status, 400);
  assert.equal(ok.status, 200);
});

test('上传签名不占学生配额（否则传图会挤掉批改额度）', async () => {
  const { gateway } = buildGateway({
    AI_WEIGHT_REASONING: '1',
    AI_QUOTA_UNITS_PER_MINUTE: '1',
  });

  const sign1 = await call(gateway, {
    path: '/ai/uploads/sign',
    body: { files: [{ storageKey: 'a.jpg', contentType: 'image/jpeg' }] },
  });
  const sign2 = await call(gateway, {
    path: '/ai/uploads/sign',
    body: { files: [{ storageKey: 'b.jpg', contentType: 'image/jpeg' }] },
  });
  const judge = await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: 'x', referenceAnswer: 'x' },
  });

  assert.equal(sign1.status, 200);
  assert.equal(sign2.status, 200);
  assert.equal(judge.status, 200);
});

test('探活也不占配额', async () => {
  const { gateway } = buildGateway({
    AI_WEIGHT_REASONING: '1',
    AI_QUOTA_UNITS_PER_MINUTE: '1',
  });
  await call(gateway, { path: '/ai/health', method: 'GET' });
  await call(gateway, { path: '/ai/health', method: 'GET' });
  const result = await call(gateway, { path: '/ai/health', method: 'GET' });
  assert.equal(result.status, 200);
});

test('审计记录里带实际扣掉的额度（看板与日志同源）', async () => {
  const { gateway, audits } = buildGateway();
  await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: 'a', referenceAnswer: 'a' },
  });

  const judged = audits.find((record) => record.path === '/ai/review/judge' && record.ok);
  assert.equal(judged.capability, 'reasoning');
  assert.equal(judged.units, 2, '判定属于强推理档，权重 2');
});

// ===== 配置自检 =====

test('沿用已改名的旧配额变量时启动即失败，而不是静默用默认值', async () => {
  // 旧变量若是被忽略，部署方会以为配额生效了，实际跑在默认值上。
  // 语义又从「次数」变成了「成本单位」，直接映射会把额度放宽 8 倍。
  assert.throws(
    () => buildGateway({ AI_RATE_PER_STUDENT_PER_DAY: '200' }),
    /已改名为 AI_QUOTA_UNITS_PER_DAY/,
  );
});

test('日额度连一次最贵的调用都付不起时启动即失败', async () => {
  // 这种配置下视觉能力会永远回 429，症状和「模型没开通」很像。
  assert.throws(
    () => buildGateway({ AI_WEIGHT_VISION: '10', AI_QUOTA_UNITS_PER_DAY: '5' }),
    /该场景将永远不可用/,
  );
});

test('单价只配了一半时启动即失败（缺的那半会被算成 0，看板会少报）', async () => {
  assert.throws(
    () => buildGateway({ AI_PRICE_VISION_IN: '0.0008' }),
    /成本单价只配了一部分/,
  );
});

// ===== 批量参考答案 =====

test('批量取参考答案：一次往返拿回全部条目，且按 index 对齐而非按位置', async () => {
  const { gateway } = buildGateway();
  const result = await call(gateway, {
    path: '/ai/review/reference-batch',
    body: {
      items: [
        { subject: '数学', knowledgePoint: '分数加减' },
        { subject: '数学', knowledgePoint: '比例应用' },
        { subject: '语文', knowledgePoint: '病句修改' },
      ],
    },
  });

  assert.equal(result.status, 200);
  const answers = result.json.data.answers;
  assert.equal(answers.length, 3);

  // 契约的关键：index 是唯一的对齐依据。mock 刻意乱序返回，
  // 网关必须原样透传，由客户端按 index 装配 ——
  // 如果这里按位置返回，一次乱序就会让第 3 题的答案印到第 5 题上。
  assert.deepEqual(
    answers.map((item) => item.index).sort((a, b) => a - b),
    [0, 1, 2],
  );
  assert.deepEqual(
    answers.map((item) => item.index),
    [2, 1, 0],
    'mock 应乱序返回，用于证明链路不依赖数组顺序',
  );
  const byIndex = new Map(answers.map((item) => [item.index, item.referenceAnswer]));
  assert.match(byIndex.get(2), /病句修改/);
  assert.match(byIndex.get(0), /分数加减/);
});

test('批量取参考答案：逐条校验请求，非法条目直接 400', async () => {
  const { gateway } = buildGateway();

  const empty = await call(gateway, {
    path: '/ai/review/reference-batch',
    body: { items: [] },
  });
  assert.equal(empty.status, 400);
  assert.equal(empty.json.error.code, 'bad_request');

  const missing = await call(gateway, {
    path: '/ai/review/reference-batch',
    body: { items: [{ subject: '数学', knowledgePoint: '  ' }] },
  });
  assert.equal(missing.status, 400);
  assert.match(missing.json.error.message, /items\[0\]\.knowledgePoint/);

  const notObject = await call(gateway, {
    path: '/ai/review/reference-batch',
    body: { items: ['分数加减'] },
  });
  assert.equal(notObject.status, 400);
  assert.match(notObject.json.error.message, /items\[0\] 应为对象/);
});

test('批量取参考答案：超过上限时拒绝，且不消耗模型调用', async () => {
  const config = loadConfig({ AI_MODEL_CLIENT: 'mock', AI_MAX_REFERENCE_BATCH: '2' });
  const model = new MockModelClient({ config });
  const { gateway } = buildGateway({ AI_MAX_REFERENCE_BATCH: '2' }, { model });

  const result = await call(gateway, {
    path: '/ai/review/reference-batch',
    body: {
      items: [
        { subject: '数学', knowledgePoint: 'A' },
        { subject: '数学', knowledgePoint: 'B' },
        { subject: '数学', knowledgePoint: 'C' },
      ],
    },
  });

  assert.equal(result.status, 400);
  assert.match(result.json.error.message, /最多批量取 2 条/);
  assert.equal(model.calls.length, 0, '参数不合格就不该产生模型调用');
});

test('批量取参考答案：模型漏条目时原样返回，不替它编造答案', async () => {
  const config = loadConfig({ AI_MODEL_CLIENT: 'mock' });
  const model = new MockModelClient({
    config,
    // 三条请求只回一条。真实模型完全可能这样。
    intercept: () => ({ value: { answers: [{ index: 0, referenceAnswer: '先通分。' }] } }),
  });
  const { gateway } = buildGateway({}, { model });

  const result = await call(gateway, {
    path: '/ai/review/reference-batch',
    body: {
      items: [
        { subject: '数学', knowledgePoint: '分数加减' },
        { subject: '数学', knowledgePoint: '比例应用' },
        { subject: '语文', knowledgePoint: '病句修改' },
      ],
    },
  });

  assert.equal(result.status, 200);
  // 网关不补空、不复制、不猜 —— 缺的那几条由客户端按单条降级补齐，
  // 而不是拿一条编造的答案去糊弄判卷。
  assert.equal(result.json.data.answers.length, 1);
  assert.equal(result.json.data.answers[0].index, 0);
});

// ===== 模型输出违约 =====

test('模型输出不合契约时回 schema_violation 且可重试', async () => {
  const config = loadConfig({ AI_MODEL_CLIENT: 'mock' });
  const model = new MockModelClient({
    config,
    // 第二次调用时给一个缺 comment 的结果，模拟「模型改了字段名」。
    intercept: (callInfo) =>
      callInfo.index === 0
        ? { value: { verdict: 'correct', score: 100 } }
        : null,
  });
  const { gateway } = buildGateway({}, { model });

  const result = await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: '11/12', referenceAnswer: '11/12' },
  });

  assert.equal(result.status, 502);
  assert.equal(result.json.error.code, 'schema_violation');
  assert.equal(result.json.error.retryable, true);
  assert.match(result.json.error.message, /comment/);
});

test('模型侧报「能力未开通」时透传为不可重试', async () => {
  const config = loadConfig({ AI_MODEL_CLIENT: 'mock' });
  const { modelNotEnabled } = await import('../src/errors.js');
  const model = new MockModelClient({
    config,
    intercept: () => ({ error: modelNotEnabled('vision') }),
  });
  const { gateway } = buildGateway({}, { model });

  const result = await call(gateway, {
    path: '/ai/homework/check',
    body: { subject: '数学', title: '作业', images: [IMAGE] },
  });

  assert.equal(result.status, 503);
  assert.equal(result.json.error.code, 'model_not_enabled');
  assert.equal(result.json.error.retryable, false);
});

// ===== 审计 =====

test('成功与失败都留审计，且不记录学生答案与照片内容', async () => {
  const { gateway, audits } = buildGateway();
  await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: '11/12', referenceAnswer: '11/12' },
  });
  await call(gateway, { path: '/ai/homework/check', body: { subject: '数学' } });

  assert.equal(audits.length, 2);
  assert.equal(audits[0].ok, true);
  assert.equal(audits[1].ok, false);
  assert.equal(audits[1].code, 'bad_request');

  const serialized = JSON.stringify(audits);
  // 作业照片里有孩子的姓名、班级、住址；审计只需要回答「谁花了多少」。
  assert.equal(serialized.includes('11/12'), false);
  assert.equal(serialized.includes('aGVsbG8='), false);
  assert.ok(audits[0].studentId);
  assert.ok(audits[0].latencyMs !== null);
});

// ===== 图片上传链路 =====

test('上传链路：签名 → 直传 → 取图，签名不符与过期都拒绝', async () => {
  const { gateway } = buildGateway();

  const signed = await call(gateway, {
    path: '/ai/uploads/sign',
    body: { files: [{ storageKey: 'hw/1.jpg', contentType: 'image/jpeg' }] },
  });
  assert.equal(signed.status, 200);
  const upload = signed.json.data.uploads[0];
  assert.equal(upload.storageKey, 'hw/1.jpg');
  assert.match(upload.uploadUrl, /^https:\/\/gw\.test\/ai\/uploads\/put\?/);
  // 对象键按学生分目录，便于按人清理。
  assert.match(upload.objectUrl, /students%2Fstu_test%2F/);

  const putQuery = Object.fromEntries(
    new URL(upload.uploadUrl).searchParams,
  );
  const put = await call(gateway, {
    method: 'PUT',
    path: '/ai/uploads/put',
    query: putQuery,
    rawBody: Buffer.from('fake-jpeg-bytes'),
  });
  assert.equal(put.status, 200);
  assert.equal(put.json.data.byteSize, 15);

  const getQuery = Object.fromEntries(new URL(upload.objectUrl).searchParams);
  const got = await call(gateway, {
    method: 'GET',
    path: '/ai/files',
    query: getQuery,
  });
  assert.equal(got.status, 200);
  assert.equal(got.body.toString(), 'fake-jpeg-bytes');

  const tampered = await call(gateway, {
    method: 'GET',
    path: '/ai/files',
    query: { ...getQuery, sig: 'deadbeef' },
  });
  assert.equal(tampered.status, 400);

  const expired = await call(gateway, {
    method: 'GET',
    path: '/ai/files',
    // 过期时间必须**相对签发的 exp** 往前推，不能用 `Date.now()` 算。
    //
    // 这个网关用的是注入的假时钟（`now: () => fakeNow`，固定在某一天），
    // 而 `Date.now()` 是真实墙钟。两者一比，测试就成了「等真实时间走过
    // 假时钟那一刻就开始失败」—— 它会在某个下午突然变红，
    // 而看代码完全看不出哪里有时间依赖。
    query: { ...getQuery, exp: String(Number(getQuery.exp) - 3600_000) },
  });
  assert.equal(expired.status, 400);
  assert.match(expired.json.error.message, /过期/);
});

test('未配置上传密钥时如实报 upload_not_configured，而不是给个假 URL', async () => {
  const { gateway } = buildGateway({ AI_UPLOAD_SIGNING_SECRET: '' });
  const result = await call(gateway, {
    path: '/ai/uploads/sign',
    body: { files: [{ storageKey: 'a.jpg' }] },
  });

  assert.equal(result.status, 503);
  assert.equal(result.json.error.code, 'upload_not_configured');
});

// ===== 平台事件归一化 =====

test('API 网关的事件形状被正确归一化（含 stage 前缀与 base64 body）', () => {
  const request = toRequest({
    httpMethod: 'post',
    path: '/release/ai/review/judge',
    headers: { 'X-Student-Id': 'stu_1' },
    queryStringParameters: null,
    rawQueryString: 'a=1',
    body: Buffer.from(JSON.stringify({ studentAnswer: '1' })).toString('base64'),
    isBase64Encoded: true,
  });

  assert.equal(request.method, 'POST');
  // 网关通常会在路径前加一段 stage，不抹平的话线上会全是 404。
  assert.equal(request.path, '/ai/review/judge');
  assert.equal(request.headers['x-student-id'], 'stu_1');
  assert.deepEqual(request.query, { a: '1' });
  assert.deepEqual(request.body, { studentAnswer: '1' });
  assert.equal(request.bodyInvalid, false);
});

test('⚠️ 真事件用的是 queryParameters —— 网关这边同样丢过一次', () => {
  // 与数据服务同一条故障（见 shared/fc3-http-event.js 的文件头）：
  // 两个入口各写一份归一化，字段名一起猜错。
  // 网关的症状在 `/ai/uploads/put?key=…&sig=…` 这条路上 ——
  // 参数全丢，报出来是「缺少参数 key」，看着像调用方没带参数。
  const event = fc3HttpEvent({
    path: '/ai/uploads/put',
    method: 'PUT',
    query: { key: 'students/stu_1/a.png', sig: 'deadbeef', exp: '1780000000000' },
    body: '',
  });
  assertCapturedShape(assert, event);

  const asBuffer = toRequest(Buffer.from(JSON.stringify(event), 'utf8'));
  assert.deepEqual(
    asBuffer.query,
    { key: 'students/stu_1/a.png', sig: 'deadbeef', exp: '1780000000000' },
    '平台怎么发就该怎么读出来',
  );
  // 路径也要一起读对：它和 query 是同一份事件里的事，别只顾着修一半。
  assert.equal(asBuffer.path, '/ai/uploads/put');
  assert.deepEqual(toRequest(event).query, asBuffer.query);
  // 老来源不能因为换了新字段名就丢。
  assert.deepEqual(
    toRequest({ queryStringParameters: { key: 'k' }, rawQueryString: 'sig=s' }).query,
    { sig: 's', key: 'k' },
  );
});

test('⚠️ 平台把事件序列化成 Buffer 传进来时，必须还原成对象', () => {
  // 真事（2026-09-24 云上首跑）：阿里云 FC3 的 HTTP 触发器喂进来的 event 是 **Buffer**
  // （内容就是事件 JSON 的字节，实测 `isBuffer: true`、顶层键是 `0..593` 这种下标），
  // 不是对象。于是 toRequest 读的字段全部落空，**每个请求都回「未知端点 /」** ——
  // 症状看起来像路由表坏了，其实是事件没解开。
  //
  // ⚠️ 数据服务先撞上、先修好；网关这边**一模一样**，因为入口是两份独立实现。
  // 本地测试喂对象、线上传 Buffer，所以这个 bug **只有真部署才暴露**。
  // 这条判据就是为它立的：三种形态必须逐字段相同。
  //
  // 📌 形状不再手抄在测试里，改成 shared 里**实测抓到的**那一份：
  // 手抄的那版把 `queryParameters` 写成了空对象，于是字段名读错这件事
  // 在这里静默通过了（见文件头）。
  const realEvent = fc3HttpEvent({
    path: '/ai/review/judge',
    method: 'POST',
    body: '{"studentAnswer":"1"}',
    isBase64Encoded: false,
  });
  assertCapturedShape(assert, realEvent);

  const asObject = toRequest(realEvent);
  const asBuffer = toRequest(Buffer.from(JSON.stringify(realEvent), 'utf8'));
  const asString = toRequest(JSON.stringify(realEvent));

  assert.deepEqual(asBuffer, asObject, 'Buffer 形态必须与对象形态**逐字段相同**');
  assert.deepEqual(asString, asObject, '字符串形态必须与对象形态**逐字段相同**');
  // 再单独盯一眼两个**最容易丢**的字段：坏的那一版正是把它们都丢成默认值 '/'。
  assert.equal(asBuffer.path, '/ai/review/judge', 'path 不能丢成默认的 /');
  assert.deepEqual(asBuffer.body, { studentAnswer: '1' }, 'body 不能跟着一起丢');
});

test('⚠️ 事件是坏 JSON / 空值时不许抛异常（宁可 404，也不能 500）', () => {
  // 还原失败直接抛的话，表现是**每个请求 500**，而根因在「事件格式」上，
  // 排查方向会被彻底带偏。所以这里要求它退化成空对象。
  assert.deepEqual(toRequest(Buffer.from('{ 这不是 json', 'utf8')).body, null);
  assert.equal(toRequest(Buffer.from('', 'utf8')).path, '/');
  assert.equal(toRequest(null).path, '/');
  assert.equal(toRequest(undefined).path, '/');
});

// ===== 身份：占位符 vs 缺失 =====

test('学号是占位符「anonymous」时，错误文案要指向「未登录」', async () => {
  const { gateway, audits } = buildGateway();

  const result = await call(gateway, {
    path: '/ai/homework/ocr',
    headers: { 'x-student-id': 'anonymous' },
    body: { images: [] },
  });

  assert.equal(result.status, 400);
  assert.equal(result.json.error.code, 'bad_request');
  assert.equal(result.json.error.retryable, false);

  const message = result.json.error.message;
  // 现场真相是「头在、值没意义」。原先两种情形共用一句「缺少 X-Student-Id」，
  // 运维照那句话去查会一路往「客户端没带头」的方向找，永远找不到。
  assert.match(message, /占位符/);
  assert.match(message, /未登录/);
  assert.doesNotMatch(message, /缺少/);

  // 审计里要能一眼看出是谁发的 —— 占位符原样记下，别当成正常学号美化掉。
  assert.equal(audits.at(-1).studentId, 'anonymous');
  assert.equal(audits.at(-1).code, 'bad_request');
});

test('请求头真的缺失时，仍然报「缺少 X-Student-Id」', async () => {
  const { gateway } = buildGateway();

  const result = await call(gateway, {
    path: '/ai/homework/ocr',
    headers: { 'x-student-id': '' },
    body: { images: [] },
  });

  assert.equal(result.status, 400);
  assert.equal(result.json.error.code, 'bad_request');
  assert.match(result.json.error.message, /缺少 X-Student-Id/);
});

test('占位符不会消耗配额：请求在扣费之前就被拒了', async () => {
  const { gateway, audits } = buildGateway();

  await call(gateway, {
    path: '/ai/homework/check',
    headers: { 'x-student-id': 'anonymous' },
    body: { subject: '数学', title: '作业', images: [] },
  });

  // 被拒的请求一个成本单位都不该扣 —— 否则「未登录」会以消耗额度的方式
  // 惩罚一个根本没发生的调用。
  assert.equal(audits.at(-1).units, 0);
  assert.equal(audits.at(-1).model, null);
});

// ===== 短信验证码：预留端点（见 doc/auth-extension-seams.md）=====

test('预留的短信端点如实返回 501，且明确不可重试', async () => {
  const { gateway } = buildGateway();

  for (const path of [
    '/auth/sms/send',
    '/auth/sms/verify',
    '/auth/sms/reset',
  ]) {
    const result = await call(gateway, { path, body: { phone: '13800000001' } });

    assert.equal(result.status, 501, `${path} 应返回 501`);
    assert.equal(result.json.error.code, 'not_implemented', path);
    // retryable 必须是 false：可重试等于让客户端对一个永远不会成功的请求
    // 退避重试，把「功能没上线」表现成「偶发失败」。
    assert.equal(result.json.error.retryable, false, path);
    // 报文里要说清是「没接」而不是「坏了」，否则排查的人会去翻故障日志。
    assert.match(result.json.error.message, /尚未实现/, path);
  }
});

test('预留的短信端点不需要身份：验证码要发给还没登录的人', async () => {
  const { gateway, audits } = buildGateway();

  const result = await call(gateway, {
    path: '/auth/sms/send',
    // 故意不带身份。挂鉴权会把唯一需要它的那批用户挡在外面，
    // 而且报 401 看起来像「凭证过期」。
    headers: { 'x-student-id': '' },
    body: { phone: '13800000001' },
  });

  assert.equal(result.status, 501);
  assert.equal(result.json.error.code, 'not_implemented');
});

test('预留的短信端点不占 AI 配额', async () => {
  const { gateway, audits } = buildGateway();

  await call(gateway, {
    path: '/auth/sms/reset',
    headers: { 'x-student-id': 'stu_test' },
    body: { phone: '13800000001' },
  });

  // 短信的频控是另一套维度（按手机号），不能借 AI 的按学号额度。
  assert.equal(audits.at(-1).units, 0);
  assert.equal(audits.at(-1).model, null);
});

test('预留路径用错方法时报 405，而不是 404', async () => {
  const { gateway } = buildGateway();

  const result = await call(gateway, { method: 'GET', path: '/auth/sms/send' });

  assert.equal(result.status, 405);
  assert.equal(result.json.error.code, 'method_not_allowed');
});


// ===== 拍照作答（/ai/review/answer-ocr）=====
//
// 这条端点是「举一反三拍照作答」的服务端那一半：它**只负责把照片变成文字**，
// 不判定对错。下面几条判据都围着这个边界写 —— 因为最容易出的错
// 恰恰是「它越界去判了」（学生还没确认转录，系统已经给了结论）。

test('拍照作答：正常回一段转录文字与置信度', async () => {
  const { gateway, audits } = buildGateway();

  const result = await call(gateway, {
    path: '/ai/review/answer-ocr',
    body: {
      images: [IMAGE],
      questionContent: '3 + 4 = ?',
      knowledgePoint: '整数的加法',
    },
  });

  assert.equal(result.status, 200);
  assert.equal(typeof result.json.data.text, 'string');
  assert.ok(result.json.data.text.length > 0);
  assert.ok(result.json.data.confidence > 0);

  // ⚠️ 契约里**没有** verdict / score —— 端点越界判定会让「学生还没确认
  // 转录是否正确」这件事消失：系统替他做了结论，而他改都改不了。
  assert.equal(result.json.data.verdict, undefined);
  assert.equal(result.json.data.score, undefined);

  assert.equal(audits.at(-1).ok, true);
  assert.equal(audits.at(-1).capability, 'vision');
});

test('拍照作答：没有照片时明确报错，而不是让模型编一段答案', async () => {
  const { gateway, model } = buildGatewayWithModel();

  const result = await call(gateway, {
    path: '/ai/review/answer-ocr',
    body: { images: [], questionContent: '3 + 4 = ?' },
  });

  assert.equal(result.status, 400);
  assert.equal(result.json.error.code, 'bad_request');
  // 关键：**一次模型调用都不该发生**。这不是性能问题 —— 让模型在
  // 「没有照片」时自由发挥，它会回一段读起来完全正常的作答，
  // 那段文字会被填进学生的作答框并拿去判定对错。
  assert.equal(model.calls.length, 0);
});

test('拍照作答：按视觉档计配额（8 单位），不是按推理档', async () => {
  const { gateway, audits } = buildGateway();

  await call(gateway, {
    path: '/ai/review/answer-ocr',
    body: { images: [IMAGE] },
  });

  // 它确实要发一张图给视觉模型。若档位写错（比如落到 light 的 1），
  // 额度会少算 8 倍，而且不会有任何症状 —— 要等月底账单才看得出来。
  assert.equal(audits.at(-1).units, 8, '拍照作答属于视觉档，权重 8');
});

test('拍照作答：题干与知识点会进提示词，但两者都可以缺席', async () => {
  const { gateway, model } = buildGatewayWithModel();

  await call(gateway, {
    path: '/ai/review/answer-ocr',
    body: {
      images: [IMAGE],
      questionContent: '3 + 4 = ?',
      knowledgePoint: '整数的加法',
    },
  });
  const withContext = model.calls.at(-1).content[0].text;
  assert.match(withContext, /整数的加法/);
  assert.match(withContext, /3 \+ 4 = \?/);

  // 只带照片也要能走通：客户端可能只拍了一张图，
  // 拿不到题干时**不能编**，只能少给一点上下文。
  const { gateway: g2, model: m2 } = buildGatewayWithModel();
  const result = await call(g2, {
    path: '/ai/review/answer-ocr',
    body: { images: [IMAGE] },
  });
  assert.equal(result.status, 200);
  assert.doesNotMatch(m2.calls.at(-1).content[0].text, /这一题的题干/);
});

test('拍照作答：不认识 schema 的 mock 会大声失败，而不是回一个空壳', async () => {
  // 这条是给未来的人看的：新增端点时如果忘了同步 mock-model.js，
  // 必须立刻炸出来。静默返回一个形状不对的结果，会让排查方向
  // 落到「模型不听话」上，而真相是本地夹具没跟上。
  const { gateway } = buildGateway({}, {
    model: {
      capabilities: () => ({ vision: true, reasoning: true, light: true }),
      complete: async () => ({
        value: { text: 'x', confidence: 0.9 },
        model: 'fake',
        usage: {},
        finishReason: 'tool_calls',
      }),
    },
  });

  const result = await call(gateway, {
    path: '/ai/review/answer-ocr',
    body: { images: [IMAGE] },
  });
  assert.equal(result.status, 200);
  assert.equal(result.json.data.text, 'x');
});

test('拍照作答：没看到作答时返回空 text 是合法结果，不会被判违约', async () => {
  // 「照片里确实什么都没写」是一个**合法的业务状态**，不是契约违约。
  // 客户端就是按这个口径写的：`_parseAnswerRecognition` 用 `_requireString`
  // 而不是 `_requireNonEmptyString`，`isUsable` 对空串判假，走
  // 「这张照片里没看到手写作答，请重拍或直接输入」那一支。
  //
  // ⚠️ 反过来：schema 若在这里要求 text 非空，模型就只能回一句**占位文案**
  // （2026-09-25 之前提示词让它回「（未看到作答内容）」），而客户端的
  // `isUsable` 只看「非空 + 来自云端」⇒ 那句文案**被判为可用、填进学生的
  // 作答框**，学生一提交就凭空多出一道判错的题。
  //
  // ⚠️⚠️ 这条必须走 `MockModelClient.intercept`：schema 校验发生在模型的
  // `complete()` 内部（`mock-model.js` 的 `#finish`）。直接给网关塞一个
  // 自定义 model 会**绕过 validate** —— 那样加不加 minLength 都是绿的，
  // 一条什么都没测的用例。（本轮真踩过：第一版就是这么写的，证伪时
  // 加回 minLength 仍然 208/208 全绿。）
  const config = loadConfig({ AI_MODEL_CLIENT: 'mock' });
  const model = new MockModelClient({
    config,
    intercept: () => ({ value: { text: '', confidence: 0.2 } }),
  });
  const { gateway } = buildGateway({}, { model });

  const result = await call(gateway, {
    path: '/ai/review/answer-ocr',
    body: { images: [IMAGE] },
  });

  assert.equal(result.status, 200);
  assert.equal(
    result.json.data.text,
    '',
    '空 text 必须原样返回 —— 被 schema 拦下会走降级，'
      + '而客户端拿到的将是一句不是学生写的占位文字',
  );
  assert.equal(result.json.data.confidence, 0.2);
});

// ===== 错题录入的题目提取（/ai/review/extract-mistakes）=====
//
// 这条端点只回答「照片里写着什么」，**不判断对错**：学生提交的是他认定的
// 错题，模型再判一遍会造出一个他无法反驳的拒绝 —— 手上明明有张打了叉的卷子，
// 系统说「这题没错，不能录」。

test('题目提取：一张照片里的多道题逐条返回，且不带任何对错结论', async () => {
  const { gateway, audits } = buildGateway();

  const result = await call(gateway, {
    path: '/ai/review/extract-mistakes',
    body: { images: [IMAGE] },
  });

  assert.equal(result.status, 200);
  const questions = result.json.data.questions;
  assert.equal(questions.length, 2, '拍一整页时多道题要逐条给出');
  assert.ok(questions[0].questionBody.length > 0);

  // 提取不是判定。多一个 verdict 字段，客户端就可能拿它去拦学生。
  assert.equal(result.json.data.verdict, undefined);
  assert.equal(questions[0].verdict, undefined);
  assert.equal(questions[0].isWrong, undefined);

  assert.equal(audits.at(-1).capability, 'vision');
  assert.equal(audits.at(-1).units, 8, '要发图，按视觉档 8 单位计');
});

test('题目提取：没有照片时明确报错，且一次模型调用都不发生', async () => {
  const { gateway, model } = buildGatewayWithModel();

  const result = await call(gateway, {
    path: '/ai/review/extract-mistakes',
    body: { images: [] },
  });

  assert.equal(result.status, 400);
  assert.equal(result.json.error.code, 'bad_request');
  // 没有照片时的「提取结果」只能是编的，而编出来的题会进错题库、
  // 被组卷重做 —— 学生练的是一道不存在的题。
  assert.equal(model.calls.length, 0);
});

test('题目提取：hint 会进提示词，把范围收到某一道题上', async () => {
  const { gateway, model } = buildGatewayWithModel();

  const result = await call(gateway, {
    path: '/ai/review/extract-mistakes',
    body: { images: [IMAGE], hint: '第 3 题' },
  });

  assert.equal(result.status, 200);
  assert.match(model.calls.at(-1).content[0].text, /第 3 题/);
  assert.equal(result.json.data.questions.length, 1, '给了范围就只提一道');
});

test('题目提取：有照片没送达时必须告诉模型，不能让它假装看到了整页', async () => {
  const { gateway, model } = buildGatewayWithModel();

  await call(gateway, {
    path: '/ai/review/extract-mistakes',
    body: { images: [IMAGE], imagesSkipped: 2 },
  });

  const prompt = model.calls.at(-1).content[0].text;
  // 不说的话模型会对着半张卷子说「都在这里了」，学生以为整页都录进去了。
  assert.match(prompt, /2 张照片未能送达/);
});

test('题目提取：照片里没有题目时返回空数组是合法结果', async () => {
  // 「拍糊了 / 拍的是空白页」是常见业务状态，不是契约违约。schema 若给
  // questions 设 minItems，模型就只能编一道题来填满它 —— 而那道假题
  // 会被存进错题库，之后反复出现在这个学生的复习里。
  const config = loadConfig({ AI_MODEL_CLIENT: 'mock' });
  const model = new MockModelClient({
    config,
    intercept: () => ({ value: { questions: [], confidence: 0 } }),
  });
  const { gateway } = buildGateway({}, { model });

  const result = await call(gateway, {
    path: '/ai/review/extract-mistakes',
    body: { images: [IMAGE] },
  });

  assert.equal(result.status, 200);
  assert.deepEqual(result.json.data.questions, []);
});

test('题目提取：低把握候选可以带 uncertain，且不要求每条都有答案', async () => {
  const config = loadConfig({ AI_MODEL_CLIENT: 'mock' });
  const model = new MockModelClient({
    config,
    intercept: () => ({
      value: {
        questions: [
          {
            questionBody: '解方程：$2x+5=13$。',
            confidence: 0.55,
            uncertain: '系数像 2 又像 7',
          },
        ],
        confidence: 0.55,
      },
    }),
  });
  const { gateway } = buildGateway({}, { model });

  const result = await call(gateway, {
    path: '/ai/review/extract-mistakes',
    body: { images: [IMAGE] },
  });

  assert.equal(result.status, 200);
  const [question] = result.json.data.questions;
  // 没有答案就不该编一个：编出来的答案会被当成参考答案去判定学生做对做错。
  assert.equal(question.answerKey, undefined);
  assert.equal(question.uncertain, '系数像 2 又像 7');
});

// ===== 错题讲解：题干与标签分开（/ai/review/explain）=====
//
// `title` 存的是「作业标题 · 知识点」这样的**标签**，不是题目。
// 2026-10 之前讲解一直拿它当题干发给模型，于是讲解读起来很顺、
// 只是讲的是另一个东西 —— 而学生看不出哪里不对。这三条判据守的就是这件事。

test('错题讲解：有题干时只对着题干讲，标题降级成来源', async () => {
  const { gateway, model } = buildGatewayWithModel();

  const result = await call(gateway, {
    path: '/ai/review/explain',
    body: {
      subject: '数学',
      knowledgePoint: '分数加法',
      title: '十月月考 · 分数加法',
      questionBody: '计算：$\\frac{1}{2}+\\frac{1}{3}$ 等于多少？',
      wrongReason: '分母直接相加',
    },
  });

  assert.equal(result.status, 200);
  const prompt = model.calls.at(-1).content;
  assert.match(prompt, /题目原文/);
  assert.match(prompt, /\\frac\{1\}\{2\}/);
  assert.match(prompt, /来源：十月月考/);
  // 标签不能再出现在「题目：」那一行 —— 出现两次，模型很可能挑近的那条。
  assert.doesNotMatch(prompt, /^题目：十月月考/m);
});

test('错题讲解：没有题干时回落到 title（历史错题也要能讲）', async () => {
  const { gateway, model } = buildGatewayWithModel();

  await call(gateway, {
    path: '/ai/review/explain',
    body: {
      subject: '数学',
      knowledgePoint: '分数加法',
      title: '十月月考 · 分数加法',
      wrongReason: '分母直接相加',
    },
  });

  const prompt = model.calls.at(-1).content;
  // 没有题干就只能按标签讲 —— 质量差是事实，但至少不能凭空造题干。
  assert.match(prompt, /题目：十月月考 · 分数加法/);
  assert.doesNotMatch(prompt, /题目原文/);
});

test('错题讲解：题干进缓存指纹，换一道题不会命中上一道的讲解', async () => {
  const { gateway, model } = buildGatewayWithModel();

  const base = {
    subject: '数学',
    knowledgePoint: '分数加法',
    title: '十月月考 · 分数加法',
    wrongReason: '分母直接相加',
  };
  await call(gateway, {
    path: '/ai/review/explain',
    body: { ...base, questionBody: '计算：1/2 + 1/3' },
  });
  await call(gateway, {
    path: '/ai/review/explain',
    body: { ...base, questionBody: '计算：2/5 + 1/4' },
  });

  // 两道题共用同一个知识点与标题。题干不进指纹的话，第二道会命中
  // 第一道的讲解 —— 学生看到的是一份完全正确、但讲的是别的题的解法。
  assert.equal(model.calls.length, 2, '不同题干必须各自调用一次模型');
});

test('错题讲解：参考答案与孩子写的过程必须真的送进提示词', async () => {
  // 2026-10-23 的实情：这道错题在库里 answerKey / studentProcess 全空，
  // 讲解只能回「横向切 / 竖向切」这一套。库里有的必须送过去，
  // 而「发出去了」这件事只能从模型收到的内容上验 —— 看响应体分辨不出来。
  const { gateway, model } = buildGatewayWithModel();

  await call(gateway, {
    path: '/ai/review/explain',
    body: {
      subject: '数学',
      knowledgePoint: '组合图形面积计算',
      title: '第三章 代数式 学法 P51',
      wrongReason: '',
      questionBody: '用不同的方法表示下图的面积（至少写出两种）。',
      referenceAnswer: 'ad + c(b-d)',
      studentProcess: 'S = ad + (b-a)c',
    },
  });

  const prompt = String(model.calls[0].content);
  assert.match(prompt, /参考答案：ad \+ c\(b-d\)/);
  assert.match(prompt, /学生当时写的内容：[\s\S]*S = ad \+ \(b-a\)c/);
});

test('错题讲解：带照片走视觉档，不带照片仍走纯文本档', async () => {
  const { gateway, model } = buildGatewayWithModel();
  const base = {
    subject: '数学',
    knowledgePoint: '组合图形面积计算',
    title: '第三章 代数式 学法 P51',
    wrongReason: '',
    questionBody: '用不同的方法表示下图的面积（至少写出两种）。',
  };

  await call(gateway, { path: '/ai/review/explain', body: base });
  assert.equal(model.calls[0].capability, 'reasoning', '没图不该付视觉档的钱');

  await call(gateway, {
    path: '/ai/review/explain',
    body: { ...base, images: [IMAGE] },
  });
  assert.equal(model.calls[1].capability, 'vision', '带了图就必须让模型看得见');
  // 图片真的进了消息体：只看 capability 分辨不了「换了个模型但图没发」。
  assert.ok(
    Array.isArray(model.calls[1].content)
      && model.calls[1].content.some((part) => part.type === 'image_url'),
    '视觉档却没把图片放进消息里 —— 模型只是被换了，仍然看不见图',
  );
});
