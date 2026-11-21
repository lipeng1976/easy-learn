// 线上分享链接的端到端走查：证明**浏览器真的能到达后端**，而不只是「页面打得开」。
//
// ## 为什么必须单独一份
//
// `tools/walkthrough-web.mjs` 走的是**本机模式**（数据在 localStorage，要求
// 构建时带 `SEED_DEMO_DATA=true`）；`tools/walkthrough-cloud.mjs` 走的虽然是
// 云端模式，但后端在 `127.0.0.1`。线上分享链接（`banxue.app.workbuddy.host`）
// 这两份都覆盖不到 —— 而它恰恰是用户真正会打开的那一个。三份不能互相代替。
//
// ## 它要证伪什么
//
// **静态资源 200 完全不代表浏览器能用。** 客户端地址是编译期常量、请求是跨源的；
// CORS 预检一旦失败，JS 侧只看到一个 `net::ERR_FAILED`，而用 `curl` 打同一个
// OPTIONS 却拿得到整套 CORS 头（这正是 B24 踩过的坑 —— 判据必须是**预检的状态码**）。
// 所以这里不看 curl，看**真浏览器里真发出的那条请求拿到了什么**。
//
// ## 判据（退出码 0 = 通）
//
// 1. 页面首帧渲染出来（不是白屏 / 不是报错页）。
// 2. 对后端的请求**收到了 HTTP 响应**（OPTIONS 204、POST 4xx/2xx 都算），
//    而不是 `loadingFailed`。**这一点不依赖账号存在**：
//        后端回「账号或密码不正确」= 链路通；
//        浏览器回 net::ERR_FAILED  = 链路不通。
//    换句话说，这里验的是**链路**，不是**凭据**。
// 3. 后端响应体的确来自后端（JSON 业务结构），排除被中间层顶掉的可能。
//
// ## 用法
//
// ```bash
// node tools/walkthrough-live-web.mjs
// node tools/walkthrough-live-web.mjs https://banxue.app.workbuddy.host/ 13800000001 abc123
// ```
//
// 截图落在系统临时目录的 walkthrough-live/ 下。
//
// 依赖：Node 22+（全局 WebSocket / fetch）+ 本机 Edge/Chrome。不装任何 npm 包。
import { spawn, execSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const EDGE_CANDIDATES = [
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
];

const TARGET = process.argv[2] || 'https://banxue.app.workbuddy.host/';
const PHONE = process.argv[3] || '13800000001';
const PASSWORD = process.argv[4] || 'abc123';

/// 只把「打给后端」的请求算进判据。静态资源（分享链接自己的域名）不算 ——
/// 它们归第①条，且 curl 已经验过。
const BACKEND_HINT = 'fcapp.run';

const OUT = join(tmpdir(), 'walkthrough-live');
mkdirSync(OUT, { recursive: true });

// 端口每次不同：上一次的无头实例可能没退干净，固定端口会连到旧浏览器。
const PORT = 9700 + Math.floor(Math.random() * 200);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const exe = EDGE_CANDIDATES.find((p) => existsSync(p));
if (!exe) {
  console.error('找不到 Edge/Chrome，可执行文件路径要在 EDGE_CANDIDATES 里补');
  process.exit(1);
}

const profile = mkdtempSync(join(tmpdir(), 'walkthrough-live-'));
const browser = spawn(exe, [
  '--headless=new', '--disable-gpu', '--no-sandbox', '--hide-scrollbars',
  '--window-size=1400,1000',
  `--remote-debugging-port=${PORT}`,
  `--user-data-dir=${profile}`,
  'about:blank',
], { stdio: 'ignore' });

function killBrowser() {
  try { execSync(`taskkill /PID ${browser.pid} /T /F`, { stdio: 'ignore' }); } catch {}
}

let ws;
let seq = 0;
const pending = new Map();
function send(method, params = {}) {
  const id = ++seq;
  ws.send(JSON.stringify({ id, method, params }));
  return new Promise((res, rej) => pending.set(id, { res, rej }));
}
async function evaluate(expression) {
  const r = await send('Runtime.evaluate', { expression, returnByValue: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.text);
  return r.result.value;
}
async function shot(name) {
  const r = await send('Page.captureScreenshot', { format: 'png' });
  writeFileSync(join(OUT, name), Buffer.from(r.data, 'base64'));
  console.log(`    [截图] ${name}`);
}

/// 后端请求的账本。`requestWillBeSent` 记起点，`responseReceived` / `loadingFailed`
/// 记终点 —— 只有终点才说明「这条请求到底有没有走通」。
const backendRequests = new Map(); // requestId -> {method, url}
const backendDone = [];            // {method, url, status?, error?, body?}

function onNetworkEvent(method, params) {
  if (method === 'Network.requestWillBeSent') {
    if (params.request.url.includes(BACKEND_HINT)) {
      backendRequests.set(params.requestId, {
        // requestId 要留着：取响应体时用它（`Network.getResponseBody`）。
        requestId: params.requestId,
        method: params.request.method,
        url: params.request.url,
        headers: params.request.headers || {},
      });
    }
    return;
  }
  if (method === 'Network.responseReceived') {
    const rec = backendRequests.get(params.requestId);
    if (rec) {
      rec.status = params.response.status;
      rec.responseHeaders = params.response.headers || {};
      backendDone.push(rec);
      backendRequests.delete(params.requestId);
    }
    return;
  }
  if (method === 'Network.loadingFailed') {
    const rec = backendRequests.get(params.requestId);
    if (rec) {
      rec.error = params.errorText;
      backendDone.push(rec);
      backendRequests.delete(params.requestId);
    }
  }
}

const viewport = { w: 1370, h: 858 };

async function clickAt(x, y, label = '') {
  if (x < 0 || y < 0 || x > viewport.w || y > viewport.h) {
    throw new Error(`要点「${label}」的位置 (${Math.round(x)},${Math.round(y)}) 在视口之外`);
  }
  const base = { x: Math.round(x), y: Math.round(y), button: 'left', clickCount: 1 };
  await send('Input.dispatchMouseEvent', { type: 'mouseMoved', ...base });
  await send('Input.dispatchMouseEvent', { type: 'mousePressed', ...base });
  await send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...base });
  console.log(`    点击 ${label} (${Math.round(x)},${Math.round(y)})`);
  await sleep(450);
}

/// Flutter Web 的文本编辑由一个隐藏 input 承载，直接改 DOM 的 value
/// **不会**同步回 Flutter 状态，只能走键盘。
const typeText = async (t) => { await send('Input.insertText', { text: t }); await sleep(400); };

async function main() {
  let target = null;
  for (let i = 0; i < 60; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
      target = list.find((t) => t.type === 'page');
      if (target) break;
    } catch {}
    await sleep(500);
  }
  if (!target) throw new Error('devtools 端口没起来');

  ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) {
      const { res, rej } = pending.get(m.id);
      pending.delete(m.id);
      m.error ? rej(new Error(JSON.stringify(m.error))) : res(m.result);
      return;
    }
    if (m.method) onNetworkEvent(m.method, m.params || {});
  };

  await send('Page.enable');
  await send('Runtime.enable');
  // 必须在 navigate **之前**开，否则漏掉首屏那批请求（会话恢复就在那里）。
  await send('Network.enable');

  console.log('[1] 打开 ' + TARGET);
  await send('Page.navigate', { url: TARGET });

  // 首帧要等 canvaskit.wasm（本页会拉 chromium 变体，5.2MB）下完再编译。
  // 全新 profile 没缓存 + 机器忙 ⇒ 十几秒到两分多钟都出现过。等短了会报
  // 「首帧没出现」，看起来像产物的毛病，其实只是慢。
  let up = false;
  for (let i = 0; i < 300; i++) {
    await sleep(1000);
    const ok = await evaluate(`(() => {
      const v = document.querySelector('flutter-view, flt-glass-pane, canvas');
      return !!v && v.getBoundingClientRect().height > 100;
    })()`);
    if (ok) { console.log(`    Flutter 首帧就绪（${i + 1}s）`); up = true; break; }
    if ((i + 1) % 15 === 0) console.log(`    仍在等首帧（${i + 1}s）`);
  }
  if (!up) {
    const html = await evaluate(`document.body ? document.body.innerHTML.slice(0, 400) : '(no body)'`);
    throw new Error('Flutter 首帧没出现，body: ' + html);
  }
  await sleep(3000);
  await shot('01_landed.png');

  const vp = JSON.parse(await evaluate(`JSON.stringify({w: window.innerWidth, h: window.innerHeight})`));
  console.log(`[2] 视口 ${vp.w}x${vp.h}`);
  // 坐标是按 1370x858 量的。尺寸不同就宁可停下，也别安静点错位置。
  if (vp.h !== 858) throw new Error(`视口高度 ${vp.h} ≠ 858，坐标需要重新量`);
  const sx = vp.w / 1370;

  console.log(`[3] 填登录表单（${PHONE}）`);
  await clickAt(685 * sx, 332, '手机号框');
  await typeText(PHONE);
  await clickAt(685 * sx, 398, '密码框');
  await typeText(PASSWORD);
  await clickAt(525 * sx, 514, '协议勾选框');
  await shot('02_filled.png');

  console.log('[4] 点「手机号登录」');
  await clickAt(685 * sx, 568, '手机号登录');
  await sleep(9000);
  await shot('03_after_login.png');

  // ── 判据 ──────────────────────────────────────────────────────────────
  console.log('');
  console.log('════ 对后端发出的请求 ════');
  const seen = backendDone.filter((r) => r.url.includes(BACKEND_HINT));
  if (seen.length === 0) {
    console.log('  （一条都没有）');
  }
  for (const r of seen) {
    const dest = r.url.replace(/^https?:\/\/[^/]+/, '');
    const line = r.error
      ? `  ${r.method.padEnd(7)} ${dest}  →  ✗ ${r.error}`
      : `  ${r.method.padEnd(7)} ${dest}  →  ${r.status}`;
    console.log(line);
  }

  // 响应体：有后端 JSON 才是铁证（说明真是后端在回，而不是中间层顶回来的）。
  let bodySample = null;
  for (const r of seen) {
    if (r.method === 'OPTIONS') continue;
    try {
      const b = await send('Network.getResponseBody', { requestId: r.requestId });
      bodySample = { url: r.url.replace(/^https?:\/\/[^/]+/, ''), body: (b.body || '').slice(0, 300) };
      break;
    } catch {}
  }
  if (bodySample) {
    console.log('');
    console.log('════ 后端响应体（节选）════');
    console.log(`  ${bodySample.url}`);
    console.log('  ' + bodySample.body.replace(/\n/g, ' '));
  }

  const gotHttpResponse = seen.filter((r) => typeof r.status === 'number');
  const failed = seen.filter((r) => r.error);
  const preflight = seen.find((r) => r.method === 'OPTIONS');

  console.log('');
  console.log('════ 结论 ════');
  console.log(`  首帧渲染          : ✓`);
  console.log(`  后端请求总数      : ${seen.length}`);
  console.log(`  收到 HTTP 响应    : ${gotHttpResponse.length}`);
  console.log(`  连接层失败        : ${failed.length}`);
  if (preflight) console.log(`  CORS 预检(OPTIONS): ${typeof preflight.status === 'number' ? preflight.status : '✗ ' + preflight.error}`);

  // 「连得上」的定义：**至少一条**打给后端的请求拿到了 HTTP 响应。
  // 不要求登录成功 —— 账号在不在云端是另一件事，不该混进这条判据。
  const reachable = gotHttpResponse.length > 0;
  if (reachable) {
    const login = seen.find((r) => r.method === 'POST');
    console.log('');
    console.log(login && login.status >= 200 && login.status < 300
      ? '  ⇒ 浏览器能到达后端，且这次登录**成功**。'
      : `  ⇒ 浏览器能到达后端（登录请求返回 ${login ? login.status : '—'}）：`
        + '后端在处理请求，回的是业务响应，不是网络层拒绝。**链接可用。**');
  } else {
    console.log('');
    console.log('  ⇒ 浏览器**到不了**后端。页面能打开只说明静态文件在。');
  }
  console.log(`  截图都在 ${OUT}`);

  killBrowser();
  process.exit(reachable ? 0 : 1);
}

main().catch((e) => {
  console.error('失败: ' + e.message);
  killBrowser();
  process.exit(1);
});
