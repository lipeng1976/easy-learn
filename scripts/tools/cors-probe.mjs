// 跨源探针：用**真浏览器**访问云上两个服务，回答「Web 版到底能不能用」。
//
// ══════════════════════════════════════════════════════════════════════════
// 为什么必须是真浏览器（2026-09-26 实测吃了这个亏才写的）
// ══════════════════════════════════════════════════════════════════════════
//
//   · `curl -X OPTIONS` 只能看到「网关回了什么」，而浏览器对预检的判定
//     （状态码必须 2xx、`Allow-Methods` 必须含请求方法……）是**在浏览器
//     内部**做的，curl 这一步看不到；
//   · Node 的 `fetch` **不做 CORS 检查**，所以它也说不出结论；
//   · 只有真浏览器能回答「这个请求到底发得出去吗」。
//
// 实测里最误导人的一件事：**云上那条路的响应头看起来是配好的** ——
// `Access-Control-Allow-Origin` 会按请求回显、`Allow-Credentials: true`
// 也在（那是 FC 的 Default CORS 行为），但预检本身的**状态码是 405**。
// 光看响应头会得出「已经配好了」的错误结论。
//
// ══════════════════════════════════════════════════════════════════════════
// 判据：拿得到状态码 = 通了
// ══════════════════════════════════════════════════════════════════════════
//
//   · 拿到**任何** HTTP 状态码（200 / 401 / 400 …）⇒ 请求真的发出去了 ⇒ CORS 通
//   · `Failed to fetch` ⇒ 浏览器把它拦下了 ⇒ 预检没过（或网络不通）
//
// ⚠️ 所以判据是「拿得到状态码」，**不是**「状态码是 200」：`/auth/login` 用假
// 账号本来就该回 401 —— 那恰恰证明请求到达了服务端。这一点很容易写错判据。
//
// 用法：
//   node tools/cors-probe.mjs                       # 域名从 .env.prod 读
//   node tools/cors-probe.mjs --data <url> --ai <url>
//   node tools/cors-probe.mjs --page https://your-site.example   # 用真实站点当来源
//
// 退出码：0 = 浏览器能访问线上系统；1 = 有请求被拦（并打印是哪些）。

import { createServer } from 'node:http';
import { execSync, spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── 参数 ────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const out = { data: '', ai: '', page: '', envFile: '.env.prod' };
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i].replace(/^--/, '');
    if (key in out) out[key] = argv[(i += 1)];
  }
  return out;
}
const args = parseArgs(process.argv.slice(2));

/** 从 `.env.prod` 读键值（域名不在别处再抄一份 —— 一个语义只许一处定义）。 */
function readEnvFile(file) {
  const p = resolve(ROOT, file);
  if (!existsSync(p)) return {};
  const env = {};
  for (const line of readFileSync(p, 'utf8').split('\n')) {
    const m = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim());
    if (m) env[m[1]] = m[2].trim();
  }
  return env;
}
const envFile = readEnvFile(args.envFile);
const DATA = args.data || envFile.CLIENT_DATA_BASE_URL || '';
const AI = args.ai || envFile.CLIENT_AI_BASE_URL || '';
if (!DATA) {
  console.error(`✗ 拿不到数据服务地址：既没给 --data，${args.envFile} 里也没有 CLIENT_DATA_BASE_URL`);
  process.exit(2);
}

// ── 跨源页面 ────────────────────────────────────────────────────────────────
// 探针必须**从另一个源**发请求，否则浏览器压根不执行 CORS 规则，测了个寂寞。
const PORT = 8099;
let server = null;
let pageUrl = args.page;
if (!pageUrl) {
  server = createServer((_req, res) => {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end('<!doctype html><meta charset="utf-8"><title>cors probe</title><h1>cors probe</h1>');
  });
  await new Promise((r) => server.listen(PORT, '127.0.0.1', r));
  pageUrl = `http://127.0.0.1:${PORT}`;
}

// ── 起浏览器 ────────────────────────────────────────────────────────────────
const CANDIDATES = [
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/usr/bin/google-chrome',
];
const exe = CANDIDATES.find((p) => existsSync(p));
if (!exe) {
  console.error('✗ 找不到 Edge / Chrome');
  process.exit(2);
}

// ⚠️ 端口每次不同：上一次的实例可能还没退干净，固定端口会连到**旧浏览器**。
const port = 9300 + Math.floor(Math.random() * 400);
const profile = mkdtempSync(join(tmpdir(), 'cors-probe-'));
const proc = spawn(exe, [
  '--headless=new', '--disable-gpu', '--no-sandbox', '--hide-scrollbars',
  `--window-size=${1400},1000`, `--remote-debugging-port=${port}`,
  `--user-data-dir=${profile}`, 'about:blank',
], { stdio: 'ignore' });

// 只杀顶层会留下渲染子进程继续占端口和内存，所以要杀进程树。
function cleanup() {
  try { execSync(`taskkill /PID ${proc.pid} /T /F`, { stdio: 'ignore' }); } catch {}
  try { proc.kill('SIGKILL'); } catch {}
  if (server) server.close();
}
process.on('exit', cleanup);

let target = null;
for (let i = 0; i < 60 && !target; i += 1) {
  try {
    const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    target = list.find((t) => t.type === 'page');
  } catch { /* devtools 还没起来 */ }
  if (!target) await sleep(500);
}
if (!target) {
  console.error('✗ devtools 端口没起来（浏览器启动失败？）');
  process.exit(2);
}

const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let seq = 0;
const pending = new Map();
ws.onmessage = (ev) => {
  const msg = JSON.parse(ev.data);
  const p = pending.get(msg.id);
  if (p) { pending.delete(msg.id); p(msg); }
};
const send = (method, params) => new Promise((res) => {
  const id = (seq += 1);
  pending.set(id, res);
  ws.send(JSON.stringify({ id, method, params }));
});

await send('Page.enable');
await send('Runtime.enable');

// ⚠️ 这里**不能**用「等 Flutter 首帧」那套（`walkthrough-web.mjs` 的 `goto`）：
// 探针页是普通 HTML，没有 `flutter-view` / `canvas`，那套会一直等到超时才报错。
await send('Page.navigate', { url: pageUrl });
await sleep(2500);

// ── 探针 ────────────────────────────────────────────────────────────────────
// 请求形状**照搬** `DataApiClient._send`（lib/services/data_api_client.dart:697）：
//   {accept: 'application/json', if(body) 'content-type': 'application/json',
//    if(token) 'authorization': 'Bearer ...'}
// 其中 `content-type: application/json` 与 `authorization` **都不在 CORS 简单
// 请求的白名单里** ⇒ Web 版**每一个**业务请求（含登录本身）都要先过预检。
const script = `(async () => {
  const out = [];
  async function probe(name, url, opts) {
    const t0 = Date.now();
    try {
      const r = await fetch(url, opts);
      out.push({ name, status: r.status, ms: Date.now() - t0 });
    } catch (e) {
      out.push({ name, failed: String((e && e.message) || e), ms: Date.now() - t0 });
    }
  }
  const DATA = ${JSON.stringify(DATA)};
  const AI = ${JSON.stringify(AI)};
  const J = { 'content-type': 'application/json' };
  await probe('数据服务 · 简单 GET（不触发预检）', DATA + '/health');
  await probe('数据服务 · 真实客户端 GET（带 accept）', DATA + '/health', { headers: { accept: 'application/json' } });
  await probe('数据服务 · 登录后形状（带 authorization）', DATA + '/data/bootstrap',
    { headers: { accept: 'application/json', authorization: 'Bearer probe' } });
  await probe('★数据服务 · 登录本身（POST JSON）', DATA + '/auth/login',
    { method: 'POST', headers: { ...J, accept: 'application/json' },
      body: JSON.stringify({ phone: '13800000000', password: 'probe' }) });
${AI ? `  await probe('AI 网关 · 简单 GET', AI + '/ai/health');
  await probe('AI 网关 · 带 authorization（对照）', AI + '/ai/health',
    { headers: { accept: 'application/json', authorization: 'Bearer probe' } });` : ''}
  return JSON.stringify({ origin: location.origin, results: out });
})()`;

// ⚠️ 这里的 `send` 返回的是**整条 CDP 消息**，值在 `msg.result.result.value` ——
// 两层 `result`：外层是消息信封，内层才是 `Runtime.evaluate` 的返回值。
// 少取一层会得到 `undefined`，而 JSON.parse(undefined) 的报错长得像「页面没执行」。
const msg = await send('Runtime.evaluate', {
  expression: script, awaitPromise: true, returnByValue: true,
});
const cd = msg.result ?? {};
if (cd.exceptionDetails) {
  console.error('✗ 页面里执行探针失败：', JSON.stringify(cd.exceptionDetails));
  process.exit(2);
}
const raw = cd.result?.value;
if (typeof raw !== 'string') {
  console.error('✗ 探针没有返回值：', JSON.stringify(msg).slice(0, 500));
  process.exit(2);
}
const { origin, results } = JSON.parse(raw);

// ── 报告 ────────────────────────────────────────────────────────────────────
console.log(`来源页：${origin}`);
console.log(`数据服务：${DATA}`);
if (AI) console.log(`AI 网关：${AI}`);
console.log('');
let blocked = 0;
for (const x of results) {
  const ok = x.status !== undefined;
  const verdict = ok ? `HTTP ${x.status}` : '被浏览器拦下';
  if (!ok) blocked += 1;
  console.log(`  ${ok ? '✅' : '❌'} ${x.name.padEnd(42)} ${verdict.padEnd(14)} (${x.ms}ms)`);
  if (!ok) console.log(`       ${x.failed}`);
}
console.log('');

if (blocked === 0) {
  console.log('✓ 全部请求都拿到了状态码 ⇒ 浏览器**能**访问线上系统。');
  console.log('  （状态码是 401/400 也算通：那证明请求到达了服务端，只是凭证不对。）');
} else {
  console.log(`✗ ${blocked} 条被浏览器拦下 ⇒ Web 版连不上。`);
  console.log('  ⚠️ 先看「简单 GET」那一条：它要是也失败，问题在网络/DNS，不在 CORS。');
  console.log('  ⚠️ 它要是成功、而触发预检的都失败 ⇒ 就是预检那一次 OPTIONS 的状态码不是 2xx。');
  console.log('     云上 FC 的 Default CORS 只处理**简单请求**；带自定义头的请求要先过预检，');
  console.log('     而预检会被转发给函数 —— 函数不处理 OPTIONS 就会回 405（非 2xx ⇒ 判定失败）。');
  console.log('     修法见 serverless/data-service/src/app.js 里的 OPTIONS 短路。');
}
cleanup();
process.exit(blocked === 0 ? 0 : 1);
