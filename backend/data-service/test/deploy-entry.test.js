import { test } from 'node:test';
import assert from 'node:assert/strict';

import { createApp } from '../src/app.js';
import { DEV_STACK_SECRET, isProduction, validateConfig } from '../src/config-check.js';
import { createPool, sslOption } from '../src/db.js';
import { SLOW_REQUEST_MS, logIfSlow, toRequest } from '../src/handler.js';
import { assertCapturedShape, fc3HttpEvent } from '../../shared/fc3-http-event.js';

/**
 * 线上入口：**配置自检**、**事件归一化**与**跨域预检**。
 *
 * 这三件事放在一个文件里，因为它们守的是同一个位置 —— 请求还没进业务路由时
 * 发生的事，而且三者都有同一种坏法：**本地全绿、线上才炸，且炸的形状不像自己**。
 *
 *   ① 配置自检：`AI_SESSION_SECRET` 为空 / 用的是仓库里公开的那把开发密钥。
 *      症状是「登录成功，但进去一片空」—— 排查会先走到数据同步与 RLS 上去。
 *   ② 事件归一化：API 网关会在路径前加一段（`/prod/data/...`），
 *      而路由表认的是**精确整串**。不切前缀的症状是「本地全绿、发上去全是 404」，
 *      而那个 404 的响应体就是本服务的标准信封，看起来完全正常。
 *   ③ 跨域预检：OPTIONS 落到「路径存在但方法不对」会回 405，而 405 不是 2xx
 *      ⇒ 浏览器判定预检失败、**实际请求根本不发**。症状是「浏览器里一句
 *      `Failed to fetch`、后端日志一条都没有」，一眼看不出是这里。
 *
 * 这个文件**不连数据库**（`toRequest` 是纯函数；`validateConfig` 只看环境变量；
 * 跨域预检那组给 `createApp` 喂的是假连接池 —— OPTIONS 在触库之前就返回了）。
 *
 * 跑法：`npm test`。
 */

// ===== ① 配置自检 =====

/** 一份「哪一项都没问题」的生产配置，用来做反面（它必须一条问题都不报）。 */
const GOOD_PROD = {
  NODE_ENV: 'production',
  AI_SESSION_SECRET: 'a'.repeat(64),
  PGPASSWORD: 'not-a-real-password',
  PGHOST: 'db.internal',
  PGDATABASE: 'easy_learn',
  // 云上部署的正确形态：照片走对象存储。
  // 函数计算没有持久磁盘，fs 后端那边会丢数据（启动自检会警告，见本文件末尾几条）。
  IMAGE_DRIVER: 'oss',
  OSS_BUCKET: 'xueban-photos',
  OSS_REGION: 'cn-beijing',
  OSS_ACCESS_KEY_ID: 'LTAI-probe',
  OSS_ACCESS_KEY_SECRET: 's'.repeat(32),
  CORS_ALLOW_ORIGIN: 'https://app.example.cn',
  BIND_HOST: '127.0.0.1',
  // 每日打卡的服务端出题要调 AI 网关。云上这两个服务是两个函数，
  // 所以这里必须是**公网 URL** —— 留空或写 127.0.0.1 都会让打卡出不了题
  // （见 config-check.js 里那条警告）。
  AI_GATEWAY_BASE_URL: 'https://ai-gateway.example.cn',
};

test('反面：一份齐备的生产配置不该报任何问题', () => {
  const { problems, warnings } = validateConfig(GOOD_PROD);
  assert.deepEqual(problems, [], '这份配置没有问题，却报错了');
  assert.deepEqual(warnings, [], `这份配置不该有警告，却有：${warnings.join('；')}`);
});

test('没配 AI 网关地址 → 只警告（服务起得来，只有打卡出题不可用）', () => {
  const { problems, warnings } = validateConfig({ ...GOOD_PROD, AI_GATEWAY_BASE_URL: '' });
  assert.deepEqual(problems, [], '一个可选能力不该把整个服务拖死');
  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /AI_GATEWAY_BASE_URL/);
  assert.match(warnings[0], /model_not_enabled/, '要说清那条路由会怎么表现，运维才知道去哪看');
});

test('AI 网关地址不像 URL → 警告并点明（别等打卡失败才发现）', () => {
  const { problems, warnings } = validateConfig({
    ...GOOD_PROD, AI_GATEWAY_BASE_URL: 'ai-gateway:8787',
  });
  assert.deepEqual(problems, []);
  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /不像一个 URL/);
});

test('生产环境没有会话密钥 → 拦下（起不来），而不是只写日志', () => {
  const { problems } = validateConfig({ ...GOOD_PROD, AI_SESSION_SECRET: '' });
  assert.equal(problems.length, 1);
  assert.match(problems[0], /AI_SESSION_SECRET 为空/);
  assert.match(problems[0], /登录成功但进去一片空/, '报错要说清客户端看到的是什么');
});

test('同一个「没有密钥」在开发环境只是警告（本机只跑数据服务时是合理的）', () => {
  const { problems, warnings } = validateConfig({
    ...GOOD_PROD, NODE_ENV: 'development', AI_SESSION_SECRET: '',
  });
  assert.deepEqual(problems, [], '开发环境不该因为没密钥就起不来');
  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /AI_SESSION_SECRET 为空/);
});

test('生产环境用着开发栈那把公开密钥 → 拦下（任何人拿它就能签票）', () => {
  const { problems } = validateConfig({ ...GOOD_PROD, AI_SESSION_SECRET: DEV_STACK_SECRET });
  assert.equal(problems.length, 1);
  assert.match(problems[0], /公开密钥|dev-stack-secret-not-for-production/);
  assert.match(problems[0], /票据校验全过|不留痕/, '要说清它为什么比「没密钥」更坏');
});

test('密钥太短 → 警告（不拦，但它能被离线爆破）', () => {
  const { problems, warnings } = validateConfig({ ...GOOD_PROD, AI_SESSION_SECRET: 'short' });
  assert.deepEqual(problems, []);
  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /只有 5 个字符/);
});

test('生产环境没有 PGPASSWORD → 拦下（否则每个请求都 500）', () => {
  const { problems } = validateConfig({ ...GOOD_PROD, PGPASSWORD: '' });
  assert.equal(problems.length, 1);
  assert.match(problems[0], /没有 PGPASSWORD/);
});

test('照片存储没配 → 只警告，不许把服务拖死', () => {
  // 这一条的**反面**比正面重要：文件系统后端没配 `IMAGE_ROOT_DIR` 时，
  // 其余 40 多条路由本来好好的。如果这里返回 problem，
  // 一次「忘了挂盘」会变成整站不可用。
  const { problems, warnings } = validateConfig({
    ...GOOD_PROD,
    IMAGE_DRIVER: 'fs',
    IMAGE_ROOT_DIR: '',
  });
  assert.deepEqual(problems, [], '照片存储没配不该阻止服务启动');
  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /upload_not_configured/);
  assert.match(warnings[0], /持久卷/, '要提醒云上别用临时盘');
});

// ===== 照片存储后端的选择（IMAGE_DRIVER）=====

test('生产环境照片用文件系统后端 → 警告（函数计算上会丢数据），但**不**拦', () => {
  // 为什么只警告不拦：`fs` 在**有持久磁盘**的部署上完全正常
  // （ECS 挂载云盘/NAS 就是）。一律拦下等于让一种正当部署起不来 ——
  // 而那本身也是一种错误（把「可能有风险」当成了「一定错」）。
  const { problems, warnings } = validateConfig({
    ...GOOD_PROD,
    IMAGE_DRIVER: 'fs',
    IMAGE_ROOT_DIR: '/data/images',
  });
  assert.deepEqual(problems, []);
  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /函数计算/, '要说清风险出在哪种平台上');
  assert.match(warnings[0], /IMAGE_DRIVER=oss/, '要给出该改成什么');
});

test('不认识的照片后端名 → 拦下（不许静默退回默认后端）', () => {
  // 静默退回 fs 的后果：照片写进函数实例的本地磁盘 —— 上传回 200、
  // 库里也有记录，文件却随实例回收消失，多实例之间还互相看不见。
  // 这是「上传成功但图没了」的成因，所以宁可起不来。
  const { problems } = validateConfig({ ...GOOD_PROD, IMAGE_DRIVER: 'Oss' });
  assert.equal(problems.length, 1);
  assert.match(problems[0], /IMAGE_DRIVER=Oss/);
  assert.match(problems[0], /fs \/ oss/, '要告诉人正确值有哪些');
});

test('IMAGE_DRIVER=oss 但缺变量 → 只警告，并**点名**缺哪几个', () => {
  const { problems, warnings } = validateConfig({
    ...GOOD_PROD,
    OSS_BUCKET: '',
    OSS_ACCESS_KEY_SECRET: '',
  });
  assert.deepEqual(problems, [], '照片存储没配好不该阻止服务启动');
  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /OSS_BUCKET/);
  assert.match(warnings[0], /OSS_ACCESS_KEY_SECRET/);
  assert.ok(!warnings[0].includes('OSS_REGION'), '配好了的不要列出来');
});

test('CORS 通配 → 警告，并说清它放开了什么', () => {
  const { problems, warnings } = validateConfig({ ...GOOD_PROD, CORS_ALLOW_ORIGIN: '*' });
  assert.deepEqual(problems, []);
  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /口令爆破/);
});

test('生产绑 0.0.0.0 → 警告（正常形态是放在 API 网关后面）', () => {
  const { problems, warnings } = validateConfig({ ...GOOD_PROD, BIND_HOST: '0.0.0.0' });
  assert.deepEqual(problems, []);
  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /API 网关/);
});

test('NODE_ENV 只有写对才是生产（大小写与前后空格都要认）', () => {
  assert.equal(isProduction({ NODE_ENV: 'production' }), true);
  assert.equal(isProduction({ NODE_ENV: 'Production' }), true);
  assert.equal(isProduction({ NODE_ENV: 'PRODUCTION' }), true);
  // 值来自平台控制台的输入框，粘出来带空格是常事。判错方向的代价是
  // 「生产按开发标准放行」—— 也就是该拦的一条都没拦。
  assert.equal(isProduction({ NODE_ENV: ' production ' }), true);
  assert.equal(isProduction({ NODE_ENV: 'dev' }), false);
  assert.equal(isProduction({ NODE_ENV: 'production-ish' }), false);
  assert.equal(isProduction({}), false);
});

// ===== ② 事件归一化 =====

test('抹掉 API 网关加的前缀：/prod/data/... 要切回 /data/...', () => {
  // 不切的话线上全是 404，而 404 的响应体就是标准信封，看着毫无异常。
  assert.equal(toRequest({ path: '/prod/data/homework' }).pathname, '/data/homework');
  assert.equal(toRequest({ path: '/release/api/data/points/ledger' }).pathname, '/data/points/ledger');
  assert.equal(toRequest({ path: '/prod/auth/login' }).pathname, '/auth/login');
});

test('已经是对的路径不许被改动（切多了会把 /data 切成空）', () => {
  assert.equal(toRequest({ path: '/data/homework' }).pathname, '/data/homework');
  assert.equal(toRequest({ path: '/auth/register' }).pathname, '/auth/register');
});

test('健康检查带前缀也要能被探到', () => {
  assert.equal(toRequest({ path: '/health' }).pathname, '/health');
  assert.equal(toRequest({ path: '/prod/health' }).pathname, '/health');
});

test('事件里的 method 三种写法都要认出来（不同平台字段名不同）', () => {
  assert.equal(toRequest({ httpMethod: 'get' }).method, 'GET');
  assert.equal(toRequest({ method: 'POST' }).method, 'POST');
  assert.equal(
    toRequest({ requestContext: { http: { method: 'put' } } }).method,
    'PUT',
  );
});

test('⚠️ 平台把事件序列化成 Buffer 传进来时，必须还原成对象', () => {
  // 真事（2026-09-24 云上首跑，排查了一整轮）：
  // 阿里云 FC3 的 HTTP 触发器喂进来的 event 是 **Buffer**（内容就是事件 JSON 的字节），
  // 不是对象。于是 toRequest 读的四个字段全落空，**每个请求都回
  // 「未知端点：GET /」** —— 症状看起来像路由表坏了，其实是事件没解开。
  // 本地测试喂对象、线上传 Buffer，所以这个 bug **只有真部署才暴露**。
  // 这条判据就是为它立的：三种形态必须逐字段相同。
  const realEvent = {
    version: 'v1',
    rawPath: '/auth/login',
    headers: { Host: 'easy-learn-data-x.cn-hangzhou.fcapp.run', 'Content-Type': 'application/json' },
    queryParameters: {},
    body: '{"phone":"1"}',
    isBase64Encoded: true,
    requestContext: { http: { method: 'POST', path: '/auth/login' } },
  };

  const asObject = toRequest(realEvent);
  const asBuffer = toRequest(Buffer.from(JSON.stringify(realEvent), 'utf8'));
  const asString = toRequest(JSON.stringify(realEvent));

  assert.deepEqual(asBuffer, asObject, 'Buffer 形态必须与对象形态**逐字段相同**');
  assert.deepEqual(asString, asObject, '字符串形态必须与对象形态**逐字段相同**');
  // 再单独盯一眼两个**最容易丢**的字段：坏的那一版正是把它们都丢成 'GET' 和 '/'。
  assert.equal(asBuffer.method, 'POST', 'method 不能丢成默认的 GET');
  assert.equal(asBuffer.pathname, '/auth/login', 'path 不能丢成默认的 /');
});

test('⚠️ 事件是坏 JSON / 空值时不许抛异常（宁可 404，也不能 500）', () => {
  // 还原失败直接抛的话，表现是**每个请求 500**，而根因在「事件格式」上，
  // 排查方向会被彻底带偏。所以这里要求它退化成空对象。
  assert.deepEqual(toRequest(Buffer.from('{ 这不是 json', 'utf8')).body, {});
  assert.equal(toRequest(Buffer.from('', 'utf8')).pathname, '/');
  assert.equal(toRequest(null).pathname, '/');
  assert.equal(toRequest(undefined).pathname, '/');
});

test('照片上传：base64 的 body 必须解回**原始字节**', () => {
  // 少解一层 base64 的症状是「图存下来了但打不开」，且不报任何错。
  const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0xff, 0x00, 0xfe]);
  const r = toRequest({
    method: 'POST',
    path: '/data/homework/images/upload',
    headers: { 'content-type': 'image/png' },
    body: bytes.toString('base64'),
    isBase64Encoded: true,
  });
  assert.ok(Buffer.isBuffer(r.bytes), 'content-type 不是 json，就该走二进制那条路');
  assert.deepEqual([...r.bytes], [...bytes], '字节必须逐个相同（含 0xff / 0x00）');
  assert.deepEqual(r.body, {}, '二进制请求不该被当成 JSON 解析');
});

test('JSON 请求照常解析，坏的 JSON 不许伪装成「参数没填」', () => {
  const good = toRequest({
    method: 'POST',
    path: '/data/homework',
    headers: { 'content-type': 'application/json' },
    body: '{"studentId":"stu_1"}',
  });
  assert.deepEqual(good.body, { studentId: 'stu_1' });
  assert.equal(good.bytes, null);

  const bad = toRequest({
    method: 'POST',
    path: '/data/homework',
    headers: { 'content-type': 'application/json' },
    body: '{不是 json',
  });
  assert.equal(bad.body, null, '坏 JSON 要留成 null，让业务层报「请求体不是合法 JSON」');
});

test('空 content-type 当作 JSON（这条宽松规则与 dev-server 逐字相同）', () => {
  // 两条外壳对同一个请求必须做出同样的判断，否则就是
  // 「本机跑得好好的、发上去参数全丢」。
  const r = toRequest({ method: 'POST', path: '/data/homework', body: '{"a":1}' });
  assert.deepEqual(r.body, { a: 1 });
  assert.equal(r.bytes, null);
});

test('query 两种来源都要能读到', () => {
  assert.deepEqual(
    toRequest({ queryStringParameters: { scope: 'public' } }).query,
    { scope: 'public' },
  );
  assert.deepEqual(
    toRequest({ rawQueryString: 'studentId=stu_1&scope=created' }).query,
    { studentId: 'stu_1', scope: 'created' },
  );
});

// ===== ①-2 查询参数：字段名（2026-09-24 线上故障的真因）=====

test('⚠️ 真事件用的是 queryParameters —— 读错字段名 = 所有 query 参数静默全丢', () => {
  // 现场（2026-09-24 真机反馈）：学生端「拍照识别」「上传作业图片」都报
  // **缺少 studentId**，而同一个 studentId 放进 JSON body 一切正常
  // —— 也就是「带 query 的请求全部在丢参数」。
  //
  // 真因：FC3 的字段名是 `queryParameters`，而这里原先读的是
  // `queryStringParameters ?? rawQueryString`（借用 API 网关 / Lambda 的名字），
  // 两者都不存在 → `??` 一路落到空字符串 → `query = {}`。**不报错**。
  //
  // ⚠️ 为什么本地一直发现不了：本机 dev-server 走 node:http 的 req，
  // query 由 Node 自己解析，根本不经过这一层；而单测喂的事件是
  // **照着我们以为的字段名**造的 —— 造不出「字段名不对但请求看着正常」。
  // 所以下面这条必须用**实测抓到的**事件，而且要用它真实到达的形态（Buffer）。
  const event = fc3HttpEvent({
    path: '/data/homework/images/upload',
    method: 'POST',
    query: { studentId: 'stu_1', fileName: '作业.png', mimeType: 'image/png' },
  });
  assertCapturedShape(assert, event);

  const asBuffer = toRequest(Buffer.from(JSON.stringify(event), 'utf8'));
  assert.deepEqual(
    asBuffer.query,
    { studentId: 'stu_1', fileName: '作业.png', mimeType: 'image/png' },
    '平台怎么发就该怎么读出来 —— 丢在这里的表现是路由回「缺少 studentId」',
  );
  // 对象形态、以及老字段名都要照样能读（多读一个不存在的键成本是零）。
  assert.deepEqual(toRequest(event).query, asBuffer.query);
  assert.deepEqual(
    toRequest({ queryStringParameters: { a: '1' } }).query,
    { a: '1' },
    '不能为了新字段名把旧来源丢掉',
  );
});

test('查询参数的取值规则：原文优先、映射补齐、空值不进结果', () => {
  const merged = toRequest({
    rawQueryString: 'a=1&b=hello%20world',
    queryParameters: { a: 'ignored', c: '3' },
  }).query;
  assert.deepEqual(merged, { a: '1', b: 'hello world', c: '3' });

  // 重复键取第一个：`URLSearchParams` 会按出现顺序给全量，我们只留首个非空。
  assert.deepEqual(toRequest({ rawQueryString: 'a=first&a=second' }).query, { a: 'first' });

  // 数组形态（有的外壳把重复键给成数组）：取第一项，并统一成字符串。
  assert.deepEqual(toRequest({ queryParameters: { a: ['1', '2'] } }).query, { a: '1' });
  // 数字也要变成字符串，业务层只处理一种类型。
  assert.deepEqual(toRequest({ queryParameters: { n: 3 } }).query, { n: '3' });

  // 空值 / 空串 / 缺键：一律不出现在结果里（不能造出 `studentId: ''` 这种「有键但没值」）。
  assert.deepEqual(toRequest({ queryParameters: { a: '', b: null, c: undefined } }).query, {});
  assert.deepEqual(toRequest({}).query, {});
  // 坏查询串不该让整条请求挂掉。`URLSearchParams` 很宽容（能解出什么算什么），
  // 所以这里断言的是**不抛**，而不是某个具体结果 ——
  // 它防的是将来有人换成一个会抛的解析器。
  assert.doesNotThrow(() => toRequest({ rawQueryString: '%zz=%' }));
});

test('请求头统一小写，业务代码只认一种写法', () => {
  const r = toRequest({ headers: { Authorization: 'Bearer x', 'Content-Type': 'application/json' } });
  assert.equal(r.headers.authorization, 'Bearer x');
  assert.equal(r.headers['content-type'], 'application/json');
});

// ===== ③ 云数据库的 TLS 连接 =====
//
// 这一段**只验配置层**：`PGSSLMODE` 有没有变成 pg 认的那个 ssl 选项。
// **真 TLS 握手没有验过**（本机没有一台强制加密的 PG）——
// 所以别把这里全绿读成「云上一定能连上」，它只保证「配了 require 就会真的带上 ssl」。
//
// 反面同样重要：`verify-full` 这类**没实现**的取值必须炸，不能当成 `require` 放过。

test('PGSSLMODE 不配 / disable → 不带 ssl（本机开发行为不变）', () => {
  assert.equal(sslOption(undefined), undefined);
  assert.equal(sslOption(''), undefined);
  assert.equal(sslOption('disable'), undefined);

  const pool = createPool({ host: '127.0.0.1', user: 'x', database: 'y', password: 'z' });
  assert.equal(pool.options.ssl, undefined, '默认不该给连接加 ssl');
  return pool.end();
});

test('PGSSLMODE=require → 带上 ssl，且不校验证书链（云厂商自签 CA 的形态）', () => {
  const option = sslOption('require');
  assert.deepEqual(option, { rejectUnauthorized: false });

  // 大小写与两侧空格都要容忍：这个值是从平台控制台的输入框里粘出来的。
  assert.deepEqual(sslOption('  REQUIRE '), { rejectUnauthorized: false });

  const pool = createPool({
    host: '127.0.0.1', user: 'x', database: 'y', password: 'z', ssl: sslOption('require'),
  });
  assert.deepEqual(pool.options.ssl, { rejectUnauthorized: false });
  return pool.end();
});

test('PGSSLMODE 写了没实现的取值 → 直接抛错，不当成 require 悄悄放过', () => {
  for (const mode of ['verify-full', 'verify-ca', 'prefer', 'allow']) {
    assert.throws(
      () => sslOption(mode),
      /不支持/,
      `${mode} 没实现，必须炸；当成 require 放过会得到「配置写着要校验、实际没校验」`,
    );
  }
});

// ===== ③ 慢请求日志（2026-09-24 真机「10 秒没有响应」逼出来的）=====
//
// 这一段守的**不是功能**，而是**可判性**。原来的形状是：客户端报
// 「数据服务 10 秒没有响应」，而服务端这一层一条日志都没有 ——
// 于是「服务端在处理、只是慢」与「请求压根没交到函数」在日志里**一模一样**
// （都是空的），而这两件事的处置完全相反。
//
// 所以判据本身必须钉住两件事：
//   ① **阈值必须小于客户端的预算**（否则这条日志永远追不上用户看到的失败）；
//   ② **没到阈值不许打**（每个请求一行会把真信号淹掉 —— `errorResponse`
//      刻意不记 4xx 就是同一条理由）。

test('慢请求阈值必须小于客户端的请求预算 —— 否则日志永远追不上用户看到的失败', async () => {
  // ⚠️ 客户端的那个数**不抄在这里**：抄一份的话，改客户端的人不会想到还有第二处。
  // 直接从 Dart 源码里读出来（`DataConfig.requestTimeout` 的默认值）。
  const { readFileSync } = await import('node:fs');
  const { fileURLToPath } = await import('node:url');
  const { join } = await import('node:path');
  const dartPath = join(
    fileURLToPath(import.meta.url), '..', '..', '..', '..',
    'lib', 'services', 'data_config.dart',
  );
  const dart = readFileSync(dartPath, 'utf8');
  const m = dart.match(/requestTimeout\s*=\s*const Duration\(seconds:\s*(\d+)\)/);
  assert.ok(m, `没能从 ${dartPath} 里读到 requestTimeout 的默认值 —— 别把这条测试改成跳过：`
    + '它守的是「服务端日志的阈值 < 客户端放弃的时机」这个不变式。改法见 data_config.dart 的 DataConfig 构造函数。');

  const clientBudgetMs = Number(m[1]) * 1000;
  assert.ok(
    SLOW_REQUEST_MS < clientBudgetMs,
    `阈值 ${SLOW_REQUEST_MS}ms 必须小于客户端的 ${clientBudgetMs}ms —— `
    + '等于或大于它，这条日志就永远只在客户端已经放弃之后才可能出现。',
  );
});

test('慢请求日志：真的慢才打，且要能看出「哪个请求、query 到了没、有没有出结果」', () => {
  const calls = [];
  const original = console.warn;
  console.warn = (...args) => calls.push(args.join(' '));
  try {
    // 反面：没到阈值，一行都不许打。
    logIfSlow({ method: 'GET', pathname: '/data/homework', query: {} }, SLOW_REQUEST_MS - 1, 200);
    assert.equal(calls.length, 0, '没到阈值就打日志，真信号会被淹没');

    // 正面：确实慢，且**卡到没出结果**（status=0 = 在客户端超时前还没回来）。
    logIfSlow(
      { method: 'POST', pathname: '/data/chat/messages', query: { relationshipId: 'rel_1' } },
      9_800,
      0,
    );
    assert.equal(calls.length, 1);
    assert.match(calls[0], /9800ms/, '耗时必须在日志里 —— 它是「慢」与「没到」的唯一分界');
    assert.match(calls[0], /POST \/data\/chat\/messages/, '要能看出是哪个请求');
    assert.match(
      calls[0],
      /relationshipId/,
      'query 键必须打出来：它是「参数有没有到达应用」的判据（studentId 那场事故就是靠它定位的）',
    );
    assert.match(calls[0], /未出结果/, 'status=0 要能看出来 —— 那正是用户看到的「没有响应」');
  } finally {
    console.warn = original;
  }
});

test('日志函数自己绝不能炸 —— 它挂在 finally 里，炸了会顶掉真正的错误', () => {
  const original = console.warn;
  const calls = [];
  console.warn = (...args) => calls.push(args.join(' '));
  try {
    // 三种畸形输入都要活下来：事件归一化失败时 `request` 可能是空的，
    // 而那时**正是最需要看到原始错误**的时刻 —— 日志再抛一次，现场就只剩日志的错了。
    assert.doesNotThrow(() => logIfSlow(undefined, 5_000, 0));
    assert.doesNotThrow(() => logIfSlow({}, 5_000, 0));
    assert.doesNotThrow(() => logIfSlow({ method: 'GET', pathname: '/x', query: null }, 5_000, 500));
    assert.equal(calls.length, 3, '三次都该打出日志（都超过阈值），而不是被吃掉');
  } finally {
    console.warn = original;
  }
});

// ===== ③ 跨域预检（Web 版能不能用浏览器访问，取决于这一段）=====

/**
 * 为什么这条属于本文件：它和上面两件事守的是**同一个位置** —— 请求还没进业务
 * 路由时发生的事；坏法也是同一种：**本地全绿、线上才炸，且炸的形状不像自己**。
 *
 * 2026-09-26 真浏览器实测的完整对照（同一个跨源页面、同一台浏览器、同一时刻，
 * 页面在 `http://127.0.0.1:8099`，目标是云上两个服务）：
 *
 *   | 请求                                        | 结果            |
 *   |---------------------------------------------|-----------------|
 *   | 数据服务 · 简单 GET（不触发预检）              | 200             |
 *   | 数据服务 · 带 Authorization（触发预检）        | Failed to fetch |
 *   | 数据服务 · POST JSON（真实写操作的形状）        | Failed to fetch |
 *   | ★ POST /auth/login（**登录本身**就是这种）     | Failed to fetch |
 *   | 数据服务 · POST 纯文本（简单请求，不触发预检）   | 401 ← 请求到了服务端 |
 *   | AI 网关 · 带 Authorization（它自己有 204 处理） | 200             |
 *
 * 同一个域名下「简单请求拿得到 401、一触发预检就 Failed to fetch」⇒ 不是网络、
 * 不是域名解析、不是服务挂了，**唯一变量就是那一次 OPTIONS 的状态码**。
 *
 * ⚠️ 没有这段代码时的症状（实测记录，极难查）：
 *   · 浏览器侧只有一句 `Failed to fetch`，**37ms 就返回** —— 不是超时；
 *   · **后端日志里一条都没有**，因为请求压根没发出来；
 *   · 而 `curl -X OPTIONS` 能拿到 405 **外加一整套 CORS 头**，看着像已经配好了；
 *   · 原生 App 不发 `Origin`，完全不受影响 ⇒ 症状是「手机上好好的、浏览器里全挂」。
 */
const PREFLIGHT_APP = () => createApp({
  pool: {},
  authPool: {},
  sessionSecret: 'test-secret-not-for-production',
});

test('跨域预检：OPTIONS 必须回 2xx，而不是落进「路径存在但方法不对」的 405', async () => {
  const res = await PREFLIGHT_APP()(
    toRequest(fc3HttpEvent({ method: 'OPTIONS', path: '/data/bootstrap' })),
  );

  // 先钉住「不是 405」：那是修之前的**实际**行为 —— 实测响应体写着
  // 「/data/bootstrap 支持 GET，收到 OPTIONS」，而 405 不是 2xx，
  // 浏览器据此判定预检失败，**实际请求根本不发**。
  assert.notEqual(res.status, 405, '405 不是 2xx ⇒ 浏览器判定预检失败 ⇒ 实际请求根本不发');
  assert.equal(res.status, 204);
  assert.equal(res.body, '', '预检没有响应体（OPTIONS 也不该带请求体）');
});

test('⚠️ 预检要按**平台真实事件形状**同样成立（Buffer 形态）', async () => {
  // 线上 FC3 是把事件序列化成 **Buffer** 传进来的（2026-09-24 那次
  // 「所有 query 参数静默全丢」就是它）。只喂对象形状的话，
  // 「本地全绿、线上才炸」会再演一次。
  const event = fc3HttpEvent({ method: 'OPTIONS', path: '/data/bootstrap' });
  const asObject = await PREFLIGHT_APP()(toRequest(event));
  const asBuffer = await PREFLIGHT_APP()(toRequest(Buffer.from(JSON.stringify(event), 'utf8')));

  assert.equal(asObject.status, 204);
  assert.deepEqual(asBuffer, asObject, 'Buffer 形态必须与对象形态**逐字段相同**');
});

test('预检与具体路径无关：不要求那条路径先在路由表里存在', async () => {
  // 浏览器只对它「即将要发的那一个请求」问一句允不允许，预检自己不带业务语义。
  // 按路径分情况处理，会让「某一条端点上的 Web 请求」单独挂掉 —— 极难查。
  for (const path of ['/data/bootstrap', '/auth/login', '/data/homework', '/health', '/nope']) {
    const res = await PREFLIGHT_APP()(toRequest(fc3HttpEvent({ method: 'OPTIONS', path })));
    assert.equal(res.status, 204, `${path} 的预检应当是 204`);
  }
});

test('预检响应**不许自带 CORS 头**：重复的 Allow-Origin 是浏览器直接报错的形态', async () => {
  const res = await PREFLIGHT_APP()(
    toRequest(fc3HttpEvent({ method: 'OPTIONS', path: '/data/bootstrap' })),
  );

  // 云上 FC 的 Default CORS 会按请求回显这几个头；函数再给一份就**重复**了，
  // 而规范只允许一个 —— 浏览器会直接报错。所以来源该由网关统一决定，
  // 不该由业务代码各自决定（`doc/release-guide.md` §1.6）。
  assert.deepEqual(
    Object.keys(res.headers).filter((k) => k.toLowerCase().startsWith('access-control')),
    [],
    '函数不该自己决定跨域来源',
  );
});
