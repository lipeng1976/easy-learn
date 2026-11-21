import { test } from 'node:test';
import assert from 'node:assert/strict';

import { loadConfig, validateConfig } from '../src/config.js';
import { DEV_STACK_SECRET } from '../../shared/env.js';

/**
 * **生产档**的启动自检。
 *
 * ## 这个文件在防什么
 *
 * `validateConfig` 里原有的那些检查是**无条件**的（配错了任何环境都拦）。
 * 这一组不同：它们在开发环境是**常态**，只有生产才该拦 ——
 * 而恰恰是这种「有条件才拦」的判断最容易漏，因为本机怎么试都是绿的。
 *
 * 三条都是同一个形状的失败：**接口一切正常，而机制已经失效**。
 *
 *   · `AI_REQUIRE_AUTH` 没打开 → `studentId` 由请求头声明，可随意伪造；
 *     网关照常发请求、照常记账，从外部看不出和「鉴权正常工作」有任何区别。
 *   · `AI_MODEL_CLIENT=mock` → 识别 / 批改 / 讲解返回的是**写死的假数据**。
 *     这是本项目最危险的一种部署事故：学生拿到的分数看起来很正常。
 *   · `AI_KV_DRIVER=memory` → 配额计数落在每个实例各自的内存里，
 *     多实例下成倍放大，而症状只有账单。
 *
 * ## 反面同样重要
 *
 * 这一组里有一半是**反面**：开发环境不许被这些规则拦住。
 * 少了反面，「把生产规则无条件打开」也能让正面全绿 —— 而那会把
 * `npm run dev` 直接弄坏，代价是把一个安全改进变成一个不可用的仓库。
 *
 * 跑法：`npm test`（不需要网络、不需要 Key）。
 */

/** 一份按生产标准**什么毛病都没有**的配置。 */
const GOOD_PROD_ENV = {
  NODE_ENV: 'production',
  AI_REQUIRE_AUTH: 'true',
  AI_SESSION_SECRET: 'a'.repeat(64),
  AI_KV_DRIVER: 'http',
  AI_KV_URL: 'https://kv.internal/ai',
};

test('反面：一份齐备的生产配置不该报任何问题', () => {
  const problems = validateConfig(loadConfig(GOOD_PROD_ENV));
  assert.deepEqual(problems, [], `这份配置没有问题，却报错了：${problems.join('；')}`);
});

test('生产环境没开 AI_REQUIRE_AUTH → 拦下（否则 studentId 可随意伪造）', () => {
  const { AI_REQUIRE_AUTH, ...withoutAuth } = GOOD_PROD_ENV;
  const problems = validateConfig(loadConfig(withoutAuth));
  const hit = problems.find((t) => t.includes('AI_REQUIRE_AUTH'));
  assert.ok(hit, `没拦住，实际只报了：${JSON.stringify(problems)}`);
  assert.match(hit, /X-Student-Id/, '要说清「伪造」这件事具体怎么发生');
  assert.match(hit, /鉴权正常/, '要说清它为什么难发现');
});

test('反面：开发环境没开 AI_REQUIRE_AUTH 是正常的，不该被拦', () => {
  const { NODE_ENV, AI_REQUIRE_AUTH, ...devEnv } = GOOD_PROD_ENV;
  const problems = validateConfig(loadConfig(devEnv));
  assert.equal(
    problems.some((t) => t.includes('AI_REQUIRE_AUTH')),
    false,
    '本机开发默认就是不开鉴权的，拦下来等于把仓库弄坏',
  );
});

test('生产环境用 mock 模型客户端 → 拦下（AI 返回的全是假数据）', () => {
  const problems = validateConfig(loadConfig({ ...GOOD_PROD_ENV, AI_MODEL_CLIENT: 'mock' }));
  const hit = problems.find((t) => t.includes('AI_MODEL_CLIENT'));
  assert.ok(hit, `没拦住，实际只报了：${JSON.stringify(problems)}`);
  assert.match(hit, /假数据/);
});

test('生产环境配额落在进程内存里 → 拦下，并给出两条出路', () => {
  const { AI_KV_DRIVER, AI_KV_URL, ...noKv } = GOOD_PROD_ENV;
  const problems = validateConfig(loadConfig(noKv));
  const hit = problems.find((t) => t.includes('AI_KV_DRIVER'));
  assert.ok(hit, `没拦住，实际只报了：${JSON.stringify(problems)}`);
  assert.match(hit, /AI_KV_URL/, '要说清「想配共享 KV 该怎么配」');
  assert.match(hit, /AI_ALLOW_EPHEMERAL_KV=true/, '要说清「确实要单实例」怎么显式确认');
});

test('显式写了 AI_ALLOW_EPHEMERAL_KV=true 就不再拦（默认拦、要开就明说）', () => {
  const { AI_KV_DRIVER, AI_KV_URL, ...noKv } = GOOD_PROD_ENV;
  const problems = validateConfig(
    loadConfig({ ...noKv, AI_ALLOW_EPHEMERAL_KV: 'true' }),
  );
  assert.deepEqual(problems, [], `显式确认之后不该再报：${problems.join('；')}`);
});

test('生产环境用着仓库里那把公开的开发密钥 → 拦下（谁都能签票）', () => {
  const problems = validateConfig(
    loadConfig({ ...GOOD_PROD_ENV, AI_SESSION_SECRET: DEV_STACK_SECRET }),
  );
  const hit = problems.find((t) => t.includes('AI_SESSION_SECRET'));
  assert.ok(hit, `没拦住，实际只报了：${JSON.stringify(problems)}`);
  assert.match(hit, /签一张有效的会话票/, '要说清后果是「别人能花你的额度」');
});

test('NODE_ENV 这个值从控制台粘出来带空格，也照样按生产判', () => {
  // 判错方向的代价是「生产按开发标准放行」—— 上面那几条一条都不会报。
  const problems = validateConfig(
    loadConfig({ ...GOOD_PROD_ENV, NODE_ENV: ' production ', AI_REQUIRE_AUTH: 'false' }),
  );
  assert.ok(
    problems.some((t) => t.includes('AI_REQUIRE_AUTH')),
    '带空格的生产环境没被认出来，等于所有生产规则都失效',
  );
});

// ── 单价：必须区分「没配」与「配了但读不出数字」 ─────────────────────
//
// `floatOf` 对这两种输入**都**返回 null，而 `pricingState` 只看得到 null。
// 于是「六个单价全填了、但格式都不对」会被判成「一个都没配」→ **放行**：
// 部署成功、看板显示「未配置模型单价」，可 `.env.prod` 里明明填了 ——
// 用户只会一遍遍重填，因为没有任何地方说过问题在**格式**不在值。
// 最常见的触发方式就是从控制台抄价格时带上了货币符号。
const GOOD_PRICES = {
  AI_PRICE_VISION_IN: '0.008',
  AI_PRICE_VISION_OUT: '0.032',
  AI_PRICE_REASONING_IN: '0.004',
  AI_PRICE_REASONING_OUT: '0.012',
  AI_PRICE_LIGHT_IN: '0.0003',
  AI_PRICE_LIGHT_OUT: '0.0006',
};

const priceProblems = (env) => validateConfig(loadConfig({ ...GOOD_PROD_ENV, ...env }))
  .filter((t) => t.includes('单价'));

test('单价填了但带货币符号、读不出数字 → 拦下（否则会被当成「没配」而放行）', () => {
  const withYuan = Object.fromEntries(
    Object.entries(GOOD_PRICES).map(([k, v]) => [k, `¥${v}`]),
  );
  const hit = priceProblems(withYuan).find((t) => t.includes('读不出数字'));
  assert.ok(
    hit,
    '没拦住 —— 这正是「看板说没配、而 .env.prod 里明明填了」那个查不出的状态',
  );
  assert.match(hit, /AI_PRICE_VISION_IN=¥0\.008/, '要点名是哪一个变量、原值长什么样');
  assert.match(hit, /AI_PRICE_VISION_IN=0\.008/, '要给出正确写法，否则用户不知道改成什么');
});

test('反面：只有一个单价带货币符号也要报（不能只在「全错」时才拦）', () => {
  const hit = priceProblems({ ...GOOD_PRICES, AI_PRICE_LIGHT_OUT: '￥0.0006' })
    .find((t) => t.includes('读不出数字'));
  assert.ok(hit, '单个变量格式不对同样要报');
  assert.match(hit, /AI_PRICE_LIGHT_OUT=￥0\.0006/, '要点名是它');
});

test('反面：纯数字与「尾随单位」都能读出来，不该被误拦', () => {
  // parseFloat 容忍**尾随**垃圾（0.008元 → 0.008），只对**前导**符号无能为力。
  // 这条钉住「不是见到非数字就拦」—— 否则合法写法会被挡在部署之外。
  assert.deepEqual(priceProblems(GOOD_PRICES), [], '纯数字单价不该报错');
  const withSuffix = Object.fromEntries(
    Object.entries(GOOD_PRICES).map(([k, v]) => [k, `${v}元`]),
  );
  assert.deepEqual(priceProblems(withSuffix), [], '尾随「元」能读出数字，不该报错');
});

test('反面：只配了一部分 → 报的是「配了一半」，不冒充「读不出数字」', () => {
  const half = { AI_PRICE_VISION_IN: '0.008', AI_PRICE_VISION_OUT: '0.032' };
  const hits = priceProblems(half);
  assert.ok(
    hits.some((t) => t.includes('只配了一部分')),
    '配了一半就该报「配了一半」',
  );
  assert.equal(
    hits.some((t) => t.includes('读不出数字')),
    false,
    '这两个错因不同、处置也不同（一个去补值、一个去改格式），不许互相冒充',
  );
});

test('反面：六个单价全空是合法配置，不该被这两条拦下', () => {
  // 「全空」是**刻意的默认值**（价格会变，宁可显示「未知」也不报一个错数字）。
  // 少了这条反面，把新规则写成「见到 null 就拦」也能让上面几条全绿。
  assert.deepEqual(priceProblems({}), [], '全空是合法配置');
});
