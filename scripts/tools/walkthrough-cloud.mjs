// 云端演示走查：把**指向本机数据服务**的 Web 产物，用一个真浏览器点一遍
// （登录 → 学生首页 → 看得到种子作业 → 刷新仍在线 → **断网仍读得到缓存**
// → 恢复在线 → 换家长看到同一个孩子的作业 → 家长端「运行观察」真的读到网关）。
//
// ## 它和 `tools/walkthrough-web.mjs` 的关系
//
// 那一份走的是**本地模式**（数据落在 `localStorage` 的 web store 里），
// 断言全打在 `easy_learn_web_store_v5` 上。这一份走的是**云端模式**
// （`--dart-define=DATA_API_BASE_URL=...`），数据在服务端 —— 所以
// 「localStorage 里有没有那条作业」这个判据在这里**必然不成立**，
// 两份脚本不能互相代替。
//
// ## 它要证明的五件事
//
// 1. **浏览器真能连上本机服务**。这一条不显然：客户端是编译期常量、请求是跨源的、
//    而跨源失败在客户端被归类成「连不上」——`curl` 打得通完全不能说明浏览器打得通。
// 2. **换了设备还能看到同一份数据**。家长在**另一个会话**里读到孩子刚交的作业，
//    这是上云的全部意义；本地模式里「家长看得到」只是因为两方共用同一个库。
// 3. **刷新不会掉登录**（`SessionStore` 落盘 + `restoreSession()`）。掉了的症状是
//    「我昨天做的作业全没了」——其实数据在，只是身份没了、首页读了个空。
// 4. **断网时仍读得到缓存，并且看得出这是旧数据**（迁移计划 §7 方案 B）。
//    两条判据缺一不可：只验「还看得到作业」会把「旧数据被当成实时数据」漏掉，
//    而后者才是缓存引入的新风险。断网用 CDP 拦请求实现（不动后端编排），
//    并且**先把缓存做旧** —— 否则「这次命中算不算陈旧」只取决于机器跑得快不快。
//    随后恢复在线再跑一遍做对照：同一份做旧的缓存，网络通了就不该有横幅。
// 5. **客户端真的把会话票带给了 AI 网关**（`AI_REQUIRE_AUTH=true` 的前提）。
//    单元测试能证明「请求头里有 Authorization」，证明不了「网关认这张票」——
//    那取决于两个服务用的是不是同一把密钥。这里用家长端的「运行观察」页当探针：
//    它读 `/ai/metrics`（**要身份、不占学生配额**），成功时页面上会出现
//    「模型调用」「缓存命中」这些字段。构建时没带 `AI_BASE_URL` 就跳过这一条
//    （页面会明说「本机没有云端用量」），不判失败。
// 6. **首屏的业务读收敛到个位数**（P2-2 聚合预热）。改之前实测 18 次。
//    这一条只能是端到端的：它要的是真浏览器 + 两个控制器同时 `onInit` +
//    真的读缓存落盘 —— 单测里没有这三样。而它挡的恰恰是**静默退化**
//    （段名漂了 / 路径改一个字 / 键算错一个字符 → 首页悄悄变慢，界面完全正常，
//    而这台机器上 18 次往返只要几毫秒，肉眼看不出来）。
//
// ## 用法
//
// ```bash
// # 一条命令：起后端（含 AI 网关）、跑这份走查、收后端
// cd serverless/data-service && node scripts/dev-stack.mjs \
//   --run "node tools/walkthrough-cloud.mjs"
// ```
//
// 前置：Web 产物要**指向本机服务**构建（否则点进去走的是本地模式）：
//
// ```bash
// flutter build web --dart-define=DATA_API_BASE_URL=http://127.0.0.1:8788 \
//   --dart-define=AI_BASE_URL=http://127.0.0.1:8787
// ```
//
// 这条命令走的是**云端模式**，所以**不需要** `--dart-define=SEED_DEMO_DATA=true`：
// 客户端那份演示种子在云端模式下本来就是空操作（`DatabaseService.seedIfEmpty`
// 见到 `isCloud` 直接返回），数据由服务端 `seed-demo.mjs` 灌。
// 反过来，**纯本地模式**（不带 `DATA_API_BASE_URL`，也就是 README 里那条
// `flutter build web` + `tools/walkthrough-web.mjs` 的走法）必须带上它，
// 否则首屏列表是空的 —— 理由见 `lib/services/demo_seed.dart`。
//
// ⚠️ 别再加 `--no-ai`：那会跳过第 5 条。只验数据链路时加它更快，但那就
// **验不到鉴权**了 —— 而鉴权恰恰是「本机全绿、上线全 401」这类缺口唯一的发现处。
//
// 截图与断言日志落在 `build/demo-evidence/`。**有断言失败就以非 0 退出** ——
// 只会打印的走查脚本价值很低。
//
// ## 依赖
//
// CDP 驱动借用了随技能安装的那一份（`flutter-web-cdp-walkthrough`）：
// 那里面有一条条踩出来的防呆（语义树要显式启用、按视口建节点、按钮文字在
// textContent 里……），抄一份到这里就会与它各自漂。路径可用环境变量
// `CDP_DRIVER` 覆盖（换机器时改它，别改代码）。
//
// ⚠️ 这份脚本用到驱动里的 `addInitScript` / `blockUrls` / `netFailures`
// （2026-09 加进技能）。**换机器时要确认技能是新的那一版** —— 旧版没有这三个
// 方法，报出来的是 `d.addInitScript is not a function`，看起来像走查脚本坏了。
import { createServer } from 'node:http';
import { existsSync, mkdirSync, readFileSync, appendFileSync, writeFileSync } from 'node:fs';
import { dirname, extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..');
const WEB_ROOT = join(repoRoot, 'build', 'web');
const OUT_DIR = join(repoRoot, 'build', 'demo-evidence');
const LOG_FILE = join(OUT_DIR, 'assertions.log');

const PORT = Number(process.env.DEMO_PORT ?? 8088);
/**
 * 实际用的基地址。**不是常量**：`PORT` 被占时会换一个（见 `startStaticServer`），
 * 而 `reload()` 必须回到**真正在跑的那个**地址上 —— 写成常量的话，
 * 占用退让之后刷新会跳到一个没人监听的端口，现象是「刷新后白屏」。
 */
let base = `http://127.0.0.1:${PORT}`;
const DATA_BASE = process.env.CLOUD_LIVE_BASE ?? 'http://127.0.0.1:8788';
/**
 * 数据服务的端口，用来在「断网」那一步按 URL 拦请求。
 *
 * **从 `DATA_BASE` 里取而不是另写一个常量**：这两个值必须同源，
 * 否则改了其中一个（比如临时换到 9799）就会出现「拦的是 8788、
 * 客户端实际在打 9799」—— 断网没断成，判据五变成一条永远通过的假判据。
 */
const DATA_PORT = new URL(DATA_BASE).port || '80';

/**
 * AI 网关端口。第 5 步（家长端「运行观察」）用它做诊断。
 *
 * ⚠️ 与 `DATA_PORT` 不同，这里**没有**一个「客户端实际在打哪个端口」的来源可查：
 * `AI_BASE_URL` 是编译期常量，走查看不到它。所以只能靠默认值 + 构建约定
 * （`flutter build web --dart-define=AI_BASE_URL=http://127.0.0.1:8787`）。
 * 端口对不上时诊断里会显示「该端口一条请求都没有」—— 那份输出本身就能说明问题。
 */
const AI_PORT = process.env.AI_GATEWAY_PORT ?? '8787';

const STUDENT = { phone: '13800000001', name: '林小宇', role: '学生' };
const PARENT = { phone: '13800000002', name: '王老师', role: '家长' };
/** 种子里的那份作业。它的 `dueAt` 是「今天 23:00」，所以必然在列表里。 */
const SEED_HOMEWORK = '数学练习册 P32';

const CDP_DRIVER = process.env.CDP_DRIVER
  ?? 'C:\\Users\\lp_pr\\.workbuddy\\skills\\flutter-web-cdp-walkthrough\\scripts\\cdp-driver.mjs';

// ===== 静态托管 =====

/**
 * 产物的 MIME 表。
 *
 * ⚠️ 这张表**不是**为了修白屏。曾经的理由是「不写它 `.js`/`.wasm` 会被当成
 * `text/plain`，浏览器拒绝执行模块脚本，于是白屏」—— 这句话听起来很顺，但
 * 对本产物不成立，已实测（同一份产物三种托管方式，无头浏览器内装错误收集器）：
 *   正确 MIME / `.js`→text/plain / `.wasm`→text/plain  **三组都正常渲染，控制台 0 错误**。
 * 原因：`index.html` 用 `<script src="flutter_bootstrap.js">` 这种**经典脚本**
 * 加载入口，bootstrap 再 `createElement('script')` 注入 `main.dart.js`，同样没有
 * `type="module"` —— 而严格 MIME 检查只对模块脚本生效，所以根本没触发。
 * （顺带更正另一句：当前 Python 的 `http.server` 对 `.wasm` 是标对的。）
 *
 * 那就保留它，理由只剩「标对是对的，而且不要钱」。**页面白屏时不要往 MIME 查**，
 * 直接看控制台与网络响应，以及下面 `startStaticServer` 里那个端口被占的分支。
 *
 * `.bin` / `.symbols` 用 octet-stream：Flutter 不靠它们的 MIME。
 */
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.otf': 'font/otf',
  '.ttf': 'font/ttf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.bin': 'application/octet-stream',
};

/**
 * 起静态服务，返回真正落在哪个端口上。
 *
 * ## 为什么要允许换端口
 *
 * 8088 是这份脚本默认用的口，而它也是**别人**默认会用的一口 ——
 * 上一次走查留下没退干净的静态服务、另一个项目的预览、编辑器自带的
 * 预览插件，都会占着它。撞上就直接失败的话，报出来的是一句
 * `EADDRINUSE`，排查方向是「脚本坏了」，而事实是「机器上还有别的东西」。
 * 真撞过：一条**两天前**留下的 `python -m http.server 8088 --bind 127.0.0.1`
 * 还在正常应答 200，肉眼完全看不出来，只有 `netstat -ano | grep :8088` 能揪出来。
 *
 * 所以这里退让一次：优先用 `PORT`，被占就让系统随便给一个。**不退让到
 * 别的固定端口**（比如 8099）—— 那只是把同一个问题推给下一个占用者，
 * 而「随便给一个」是唯一绝对不冲突的那个。
 */
function startStaticServer() {
  const server = createServer((req, res) => {
    const url = new URL(req.url ?? '/', base);
    let rel = decodeURIComponent(url.pathname);
    if (rel.endsWith('/')) rel += 'index.html';
    // 目录穿越防护：`normalize` 之后仍以 `..` 开头的一律拒掉。
    const safe = normalize(rel).replace(/^[\\/]+/, '');
    if (safe.startsWith('..')) {
      res.writeHead(403).end('forbidden');
      return;
    }
    const file = join(WEB_ROOT, safe);
    if (!existsSync(file)) {
      res.writeHead(404).end('not found');
      return;
    }
    res.writeHead(200, {
      'content-type': MIME[extname(file).toLowerCase()] ?? 'application/octet-stream',
      // 每次都重新取：走查要看到的是**刚构建**的那一份，不是缓存里的那一份。
      'cache-control': 'no-store',
    });
    res.end(readFileSync(file));
  });

  const listen = (port) => new Promise((ok, bad) => {
    const onError = (e) => {
      server.removeListener('listening', onListening);
      bad(e);
    };
    const onListening = () => {
      server.removeListener('error', onError);
      ok(server.address().port);
    };
    server.once('error', onError);
    server.once('listening', onListening);
    server.listen(port, '127.0.0.1');
  });

  return (async () => {
    try {
      return { server, port: await listen(PORT) };
    } catch (e) {
      if (e.code !== 'EADDRINUSE') throw e;
      log(`端口 ${PORT} 被占（多半是上一次走查留下的静态服务），换一个端口`);
      return { server, port: await listen(0) };
    }
  })();
}

// ===== 断言与日志 =====

function log(line) {
  process.stdout.write(`  ${line}\n`);
  try {
    appendFileSync(LOG_FILE, `${new Date().toISOString()}  ${line}\n`);
  } catch {
    // 日志写不进去不该让走查失败
  }
}

const failures = [];
function assert(ok, what, detail = '') {
  log(`${ok ? '✓' : '✗'} ${what}${detail ? ` —— ${detail}` : ''}`);
  if (!ok) failures.push(`${what}${detail ? `（${detail}）` : ''}`);
  return ok;
}

// ===== 主流程 =====

async function main() {
  mkdirSync(OUT_DIR, { recursive: true });

  if (!existsSync(join(WEB_ROOT, 'index.html'))) {
    throw new Error(`没有 ${WEB_ROOT}/index.html —— 先跑 flutter build web`);
  }
  if (!existsSync(CDP_DRIVER)) {
    throw new Error(
      `找不到 CDP 驱动：${CDP_DRIVER}\n`
        + '  它是随技能 flutter-web-cdp-walkthrough 安装的；换机器时用 '
        + 'CDP_DRIVER=<路径> 指过去。',
    );
  }

  const { server, port } = await startStaticServer();
  base = `http://127.0.0.1:${port}`;
  log(`静态托管 ${base} ← ${WEB_ROOT}`);

  const { launchDriver } = await import(pathToFileURL(CDP_DRIVER).href);
  const d = await launchDriver({ url: base, outDir: OUT_DIR });
  const shot = (n) => d.shot(n);

  /** 读取落盘的会话。**这是本脚本最硬的一条判据**：它不依赖语义树。 */
  const session = () => d.evaluate(`(() => {
    const raw = localStorage.getItem('easy_learn_session_v1');
    return raw || '';
  })()`);

  /**
   * 以某个角色登录。
   *
   * 两个输入框走 **DOM 里的真 `<input>`**，不走坐标：坐标是按某一版登录页的
   * 布局量的，而「手机号/密码」这两个框的位置恰恰是每加一行提示就会变的地方。
   * 复选框与登录按钮仍用坐标 —— 它们的几何位置稳定，且语义树里
   * 「手机号」这个词同时出现在输入框和「手机号登录」按钮上，按文本找会歧义。
   */
  async function login({ phone, role }) {
    await d.setViewport(1370, 858);
    await d.enableSemantics();

    // 角色标签必须先切对：登录页默认停在「学生」，拿家长账号去登会失败，
    // 而失败的现象是「家长端缺了某个元素」，方向全错。
    const tab = await d.clickText(role, { timeoutMs: 6000 });
    if (!tab) log(`⚠️ 没找到「${role}」标签，按当前角色继续`);

    const fields = JSON.parse(await d.evaluate(`JSON.stringify(
      [...document.querySelectorAll('input, textarea')]
        .map((e) => {
          const r = e.getBoundingClientRect();
          return { x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width, h: r.height };
        })
        .filter((n) => n.w > 60 && n.h > 12)
    )`));
    if (fields.length < 2) {
      throw new Error(`登录页只找到 ${fields.length} 个输入框，应该有手机号和密码两个`);
    }
    await d.clickAt(fields[0].x, fields[0].y, '手机号');
    await d.clearFocusedInput();
    await d.typeText(phone);
    await d.clickAt(fields[1].x, fields[1].y, '密码');
    await d.clearFocusedInput();
    await d.typeText('abc123');

    await d.clickAt(525, 514, '同意协议');
    await d.clickAt(685, 568, '手机号登录');
    await new Promise((r) => setTimeout(r, 7000));
  }

  /** 真·重载（`about:blank` 中转，见驱动里 `reload` 的说明）。 */
  async function hardReload() {
    await d.setViewport(1370, 858);
    return d.reload(base);
  }

  /**
   * 在页面里装一层 XHR / fetch 记录器，记下每个请求**是怎么结束的**。
   *
   * 为什么需要它：客户端把「连不上」与「被拒绝」分得很开 —— 前者要降级到缓存
   * 并弹横幅，后者是业务错误、原样抛给调用方。而这两者在界面上可能长成同一个
   * 样子（都读到了缓存）。所以「有没有横幅」这个观察结果反推不出失败形态，
   * 必须直接把 `status` / 事件类型记下来。
   *
   * 用 `Page.addScriptToEvaluateOnNewDocument` 装，而不是在页面里 `evaluate`：
   * Flutter 的启动是在首帧之后，而 `evaluate` 装的钩子会被**下一次导航冲掉** ——
   * 那正是我们要观察的那一次加载。
   *
   * （`fetch` 也顺手包一层：Flutter 引擎取 canvaskit 走 fetch，
   *  而 `package:http` 在 Web 上走 XHR，两条路都要看得见。）
   */
  const NET_PROBE = `(() => {
    window.__netProbe = 'installed';
    window.__netLog = [];
    // URL **原样**记下来（含 origin+端口）。第一版在这里把 origin 剥掉了，
    // 于是诊断那边按端口过滤时一条都筛不到 —— 明明记到了，看起来却像
    // 「请求没走 XHR / fetch」。诊断脚本自己骗自己是最难发现的一种错。
    const rec = (kind, method, url) => {
      const r = { k: kind, m: method, u: String(url) };
      window.__netLog.push(r);
      return r;
    };
    const O = XMLHttpRequest.prototype.open;
    const S = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (m, u, ...rest) {
      this.__m = m; this.__u = u;
      return O.call(this, m, u, ...rest);
    };
    XMLHttpRequest.prototype.send = function (...a) {
      const r = rec('xhr', this.__m, this.__u);
      for (const ev of ['error', 'load', 'timeout', 'abort']) {
        this.addEventListener(ev, () => { r.ev = ev; r.st = this.status; });
      }
      this.addEventListener('loadend', () => { if (!r.ev) r.ev = 'loadend'; });
      return S.apply(this, a);
    };
    const F = window.fetch;
    if (F) {
      window.fetch = function (input, init) {
        const r = rec('fetch', (init && init.method) || 'GET', (input && input.url) || input);
        return F.apply(this, arguments).then(
          (res) => { r.ev = 'load'; r.st = res.status; return res; },
          (e) => { r.ev = 'error'; r.msg = String(e).slice(0, 60); throw e; },
        );
      };
    }
  })()`;

  /**
   * 把网络钩子装进**当前**文档。
   *
   * [1] 打开产物之后就装，而不是等到断网那一步：这两处装的时机不一样，
   * 要防的病也不一样 ——
   *  - 这里（evaluate）只为**当前**文档服务，导航一次就没了；
   *  - [3b] 那里用 `Page.addScriptToEvaluateOnNewDocument`，是为了让钩子
   *    挺过那次刷新（用 evaluate 装的会在导航时被冲掉）。
   * 提前装的理由是「学生登录后拿不到数据」这一步也会间歇失败，而它发生在
   * 断网之前 —— 不提前装，那次失败就只剩一句「语义树里没找到」可看。
   *
   * 先查 `__netProbe` 再去装：重复包装会让每个请求记两条，
   * 而「记了两条」看起来很像「请求发了两次」。
   */
  const installNetProbe = async () => {
    const already = await d.evaluate(`window.__netProbe || ''`);
    if (already === 'installed') return false;
    await d.evaluate(NET_PROBE);
    return true;
  };


  /**
   * 数据没到时，把「为什么」一并问出来。
   *
   * 一句「没有横幅」/「没找到作业」把三种完全不同的故障混成了一种，
   * 而它们的排查方向相反：
   *   - 压根没发过请求（读永远命中新鲜缓存）→ 是**缓存新鲜期太宽**，不是界面坏了；
   *   - 发了请求但没被记成离线（拿到 4xx 而不是连不上）→ 分类问题；
   *   - 记了事件但没渲染 → 接线问题。
   * 所以失败时必须把这些证据一起打出来，否则下次还要重走一遍今天这一趟。
   *
   * 名字不叫 `diagnoseNoBanner`：它描述的是**这条数据链路为什么没走通**，
   * 断网那一处和「登录后拿不到数据」那一处都会用它。
   *
   * [port] 默认是数据服务。第 5 步要诊断的是**另一条链路**（AI 网关），
   * 两条链路的端口不同，混着看会把「AI 没打通」误读成「数据服务没打通」。
   */
  const diagnoseStall = async (port = DATA_PORT) => {
    // 每个请求**怎么结束的**：`ev` = error/load/timeout，`st` = 状态码。
    // 这一列是这份诊断里最值钱的东西 —— 它把「连不上」与「被拒绝」分开。
    //
    // ⚠️ 聚合**不能截断**：上一版只打前 6 条，而要找的那一条恰好排在更后面 ——
    // 诊断把证据自己藏起来了（2026-09-20 查「家长端读不到看板」时就是这么被坑的，
    // 绕了好几轮才发现少看了一条请求）。按**路径**聚合天然有界（端点就那么多），
    // 所以这里全额打印。
    //
    // `ev` 是 `?` 表示**这个请求到现在还没结束** —— 它就是「卡住」本身。
    // 只看状态码会把「一直挂着」和「压根没发」读成同一件事。
    const net = await d.evaluate(`(() => {
      const all = window.__netLog || [];
      const log = all.filter((r) => String(r.u).includes(':${port}'));
      const seen = new Map();
      for (const r of log) {
        let p = String(r.u);
        try { p = new URL(p).pathname; } catch (_) { /* 不是合法 URL 就原样留 */ }
        const k = p + '|' + (r.ev || '?') + '|' + (r.st ?? '-');
        seen.set(k, (seen.get(k) || 0) + 1);
      }
      // 钩子装没装上，和「装上了但没记到」是两件事，必须分开报：
      // 前者说明 CDP 那段没生效，后者说明请求根本没走 XHR / fetch。
      const head = all.slice(0, 5).map((r) => r.k + ' ' + (r.ev || '?') + ' ' + r.u);
      return JSON.stringify({
        钩子: window.__netProbe || '未安装',
        共记录: all.length,
        路径: [...seen.entries()].map(([k, n]) => (n > 1 ? n + 'x ' : '') + k),
        前几条: head,
      });
    })()`);
    const reqs = await d.evaluate(`(() => {
      const rs = performance.getEntriesByType('resource')
        .filter((r) => r.name.includes(':${port}'));
      return JSON.stringify(rs.length);
    })()`);
    // **浏览器层面**看到的失败：被 `blockUrls` 拦下的请求根本走不到 JS 层，
    // 页面里的 XHR/fetch 钩子记不到它们。少了这一列，「断网那步到底拦没拦住」
    // 只能靠猜 —— 而拦错的后果是「假判据永远通过」，不是失败。
    const blocked = d.netFailures({ match: `:${port}` });
    // 顺带把**最上面那几行**打出来：横幅若渲染了，它必然在顶部。
    // 只看「有没有含关键词的标签」会漏掉一种情况——文案换了而关键词没跟上，
    // 那时数组是空的，看起来和「压根没渲染」一模一样。
    const top = await d.evaluate(`(() => {
      const ns = [...document.querySelectorAll('flt-semantics')]
        .map((e) => {
          const r = e.getBoundingClientRect();
          return {
            t: ((e.getAttribute('aria-label') || '') || (e.textContent || ''))
              .replace(/\\s+/g, ' ').trim(),
            y: Math.round(r.y),
          };
        })
        .filter((n) => n.t && n.y >= 0)
        .sort((a, b) => a.y - b.y);
      return JSON.stringify(ns.slice(0, 8).map((n) => n.y + ':' + n.t.slice(0, 24)));
    })()`);
    return `本次对 ${port} 的请求数 ${reqs}；**结束方式** ${net}；`
      + `**浏览器层面失败** ${blocked.length} 条 `
      + `${JSON.stringify(blocked.slice(-3))}；顶部节点 ${top}`;
  };


  /**
   * 横幅文字的**语义节点几何**。
   *
   * `probe` 找不到它，可能有两种完全不同的原因：**节点不存在**（没渲染），
   * 或者**节点存在但高/宽是 0**（渲染了但没占地方，等于看不见）。
   * 而 `probe` 内部那两处 `n.w > 0 && n.h > 0` 过滤恰好会把第二种丢掉，
   * 于是两者在调用方看来一模一样。这里故意**不加**尺寸过滤，把几何原样报出来。
   */
  const bannerGeometry = async () => d.evaluate(`(() => {
    const ns = [...document.querySelectorAll('flt-semantics')]
      .filter((e) => ((e.getAttribute('aria-label') || '') + (e.textContent || ''))
        .includes('同步'))
      .map((e) => {
        const r = e.getBoundingClientRect();
        return {
          t: ((e.getAttribute('aria-label') || '') || (e.textContent || ''))
            .replace(/\\s+/g, ' ').trim().slice(0, 18),
          xywh: [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)],
        };
      });
    return JSON.stringify(ns.slice(0, 6));
  })()`);


  /**
   * 「缓存真的落进 localStorage 了」的正面证据：数一下有几条。
   *
   * 这一步和后面的「做旧」分开，因为它们证明的是两件事，而失败时的处置
   * 完全不同：一条都没有 = 上面的读压根没写进缓存（缓存链路坏了）；
   * 有若干条 = 缓存是好的（那后面出问题就在别处）。
   */
  const cacheEntryCount = async () => d.evaluate(`(() => {
    const raw = localStorage.getItem('easy_learn_read_cache_v1');
    if (!raw) return 0;
    let payload;
    try { payload = JSON.parse(raw); } catch (e) { return -1; }
    const entries = payload && payload.entries;
    return entries && typeof entries === 'object' ? Object.keys(entries).length : 0;
  })()`);

  /**
   * 冷启动到首屏，向数据服务发了几次**业务读**，按路径分组。
   *
   * 这个数字是 P2-2（聚合读端点）的判据，也是它唯一的防反弹装置：首页的读
   * 散在控制器、三个种子门面、积分账本、通知好几处，每加一个模块就多一次往返 ——
   * 而多几次在**本机**（往返 0.2ms）完全看不出来。把它写成一条判据，
   * 才有人会在加第六次读的时候停下来想一眼。
   *
   * ⚠️ **必须从 `__netLog` 里数，不能读代码猜**。逐个 grep 出来的清单会漏掉
   * 「某个 controller 在 `onInit` 里顺手又读了一次」这种 —— 而这恰好是这类
   * 数字真正会涨的原因。数出来的才是真的。
   *
   * 认证端点（`/auth/*`）单独分桶：那是**登录本身**的成本，聚合端点省不掉，
   * 混在一起会让这个数字随「换了哪种登录方式」浮动，看起来像首屏变慢了。
   *
   * 同时报一个**浏览器层面的独立计数**（`performance` 资源计时）：钩子漏记
   * （某处走了 `img` / `sendBeacon` / 原生 XHR 绕开包装）时两个数字会对不上。
   * 少了这一列，「钩子没记到」和「压根没发请求」在读数上长得一模一样 ——
   * 而判据自己骗自己是最难发现的一类错。
   */
  const firstScreenRequests = async () => d.evaluate(`(() => {
    const all = (window.__netLog || []).filter((r) => String(r.u).includes(':${DATA_PORT}'));
    const data = all.filter((r) => String(r.u).includes('/data/'));
    const byPath = new Map();
    for (const r of data) {
      let p = String(r.u);
      try {
        const u = new URL(p);
        p = u.pathname + (u.search || '');
      } catch (_) { /* 不是合法 URL 就原样留 */ }
      byPath.set(p, (byPath.get(p) || 0) + 1);
    }
    const rt = performance.getEntriesByType('resource')
      .filter((r) => r.name.includes(':${DATA_PORT}') && r.name.includes('/data/')).length;
    return JSON.stringify({
      业务读: data.length,
      认证: all.length - data.length,
      资源计时独立计数: rt,
      按路径: [...byPath.entries()]
        .sort((a, b) => b[1] - a[1])
        .map(([k, n]) => (n > 1 ? n + 'x ' : '') + k),
    });
  })()`);

  /**
   * 把读缓存**做旧**的脚本 —— 交给 `Page.addScriptToEvaluateOnNewDocument`，
   * 在新文档里**跑在 Flutter 之前**。这件事必须发生在那个时机，理由很硬：
   *
   * 用 `evaluate` 当场改 localStorage 是一个**竞态**，而且输多赢少。
   * 客户端把整份缓存常驻在内存里，任何一次落盘都会用**它自己那份带新鲜
   * `storedAt` 的快照**整份覆盖 localStorage —— 页面正处在卸载流程里时，
   * 它照样会写。于是「我明明改成 1 小时前了」，新文档读到的却是几十秒前
   * （实测：断言打印的缓存现状是 48–54s，而那一步改的是 3600s）。
   * 后果不是「缓存旧了」而是**反向**的：新文档认定缓存新鲜 → 直接命中、
   * 连网络都不打 → 没有失败、没有陈旧读、横幅永远不出现。
   *
   * 在新文档启动前改，就不存在第二份副本：那一刻只有 localStorage 一份数据。
   *
   * 为什么非做旧不可：「断网后还看得到作业」有两个层次，而它们要的证据不同 ——
   *   1. 缓存被命中了（还读得到东西）；
   *   2. 这次命中**算陈旧**（横幅该出现）。
   * 第 2 层取决于 TTL（15s），而「登录 → 刷新 → 断网刷新」在本机只要几秒，
   * 于是缓存还新鲜，有没有横幅变成了「机器跑得快不快」。
   *
   * 键与客户端一致（`easy_learn_read_cache_v1`，见 `read_cache_html.dart`）。
   */
  const cacheAgeSource = (seconds) => `(() => {
    const KEY = 'easy_learn_read_cache_v1';
    const raw = localStorage.getItem(KEY);
    if (!raw) return;
    let payload;
    try { payload = JSON.parse(raw); } catch (e) { return; }
    const entries = payload && payload.entries;
    if (!entries || typeof entries !== 'object') return;
    const stamp = new Date(Date.now() - ${seconds} * 1000).toISOString();
    for (const k of Object.keys(entries)) {
      if (entries[k] && typeof entries[k] === 'object') entries[k].storedAt = stamp;
    }
    localStorage.setItem(KEY, JSON.stringify(payload));
  })()`;

  /**
   * 缓存现状（只用于诊断）：几条、各自多旧。
   *
   * 只在断言失败时被打印 —— 那种时刻最需要区分的是「一条都没有」（没写进去）
   * 与「有但还新鲜」（TTL 没等够）：前者是缓存坏了，后者是这个判据本身没构造好。
   */
  const cacheAges = async () => d.evaluate(`(() => {
    const raw = localStorage.getItem('easy_learn_read_cache_v1');
    if (!raw) return '无缓存';
    let payload;
    try { payload = JSON.parse(raw); } catch (e) { return '缓存解析失败（payload 坏了）'; }
    const entries = (payload && payload.entries) || {};
    const now = Date.now();
    const rows = Object.keys(entries).map((k) => {
      const t = Date.parse(entries[k] && entries[k].storedAt);
      const age = Number.isFinite(t) ? Math.round((now - t) / 1000) + 's' : '?';
      return k.split('/').pop() + '=' + age;
    });
    return rows.length + ' 条 [' + rows.join(', ') + ']';
  })()`);


  /**
   * 点底部导航里的一项。
   *
   * 按**精确文本**匹配并且取**最靠下**的那个：页面上还散着「录入作业」
   * 这类按钮，用 `includes` 会点错；而底部导航永远在窗口最下面，
   * 所以 `y` 最大的那一个就是它。
   */
  async function tapNav(label) {
    const nodes = (await d.dumpButtons()).filter((n) => n.label.trim() === label);
    if (!nodes.length) return null;
    nodes.sort((a, b) => b.y - a.y);
    await d.clickAt(nodes[0].x, nodes[0].y, `底部导航「${label}」`);
    return nodes[0];
  }

  /**
   * 断言「已经进了登录后的主界面」。
   *
   * 用**两个**判据，因为任一个单独用都会骗人：
   *  - 只看「登录页的按钮不见了」→ 白屏也算通过；
   *  - 只看「出现了底部导航」→ 登录页上恰好长得像的文案也能蒙过去。
   *
   * 底部导航的标签是从截图里读出来的（`作业 / 运动 / 复习 / 计划 / 心愿`）——
   * 注意**没有「首页」这一项**，一开始按它去探只会白等一轮超时。
   */
  async function assertMainShell(what) {
    const nav = (await d.probe('作业', 8000))
      ?? (await d.probe('心愿', 8000))
      ?? (await d.probe('复习', 8000));
    assert(nav !== null, `${what}：底部导航已出现`);
    const loginForm = await d.probe('手机号登录', 1500);
    assert(loginForm === null, `${what}：没有停在登录页`);
  }

  /**
   * 在当前页（必要时切到「作业」页）找那份种子作业。
   *
   * 先看当前页、再切「作业」页：首页的「今天的学习任务」只列**待办**，
   * 而种子那份作业在演示数据里已经批改完成了（86 分）—— 它不会出现在
   * 待办里，只会在作业列表里。把断言只压在首页上会得到一次假阴性。
   */
  async function findSeedHomework(timeoutMs = 8000) {
    const onHome = await d.probe(SEED_HOMEWORK, timeoutMs);
    if (onHome) return { node: onHome, where: '当前页' };
    await tapNav('作业');
    await new Promise((r) => setTimeout(r, 2500));
    const onList = await d.probe(SEED_HOMEWORK, timeoutMs);
    return onList ? { node: onList, where: '作业列表' } : null;
  }

  try {
    log('[1] 打开产物');
    const secs = await d.goto(base);
    log(`    首帧 ${secs}s`);
    // 钩子从这一刻就装上：后面每一步都可能因为「请求没走通」而失败，
    // 而等到断网那一步才装，之前所有失败就只剩一句「语义树里没找到」。
    await installNetProbe();
    // 控制台也从这一刻开始收。**发布版构建里它是唯一的错误出口**：
    // 未处理的异步异常不弹界面、不进网络日志，只会安静地消失，
    // 而现象往往长得像「网络问题」（服务端一条请求都没收到）。
    await d.enableConsole();
    await shot('01_login.png');

    log('[2] 以学生身份登录（数据服务 ' + DATA_BASE + '）');
    await login({ phone: STUDENT.phone, role: STUDENT.role });
    await shot('02_after_login.png');

    // ---- 判据一：登录态真的来自服务端 ----
    //
    // 为什么读 localStorage 而不是看界面：界面上「登录成功」可以由很多种
    // 假象拼出来（缓存里的旧数据、本地模式的种子），而**服务端签发的 id
    // 是一个 uuid**，本地模式那套是 `user_1712…` 拼出来的。前缀对不上，
    // 就说明这次登录确实走了 HTTP。
    const raw = await session();
    if (!assert(raw !== '', '登录后会话已落盘（localStorage）')) {
      await shot('99_no_session.png');
      return;
    }
    const sess = JSON.parse(raw);
    const token = sess.token ?? '';
    const uid = sess.user?.id ?? '';
    assert(token.length > 20, 'token 非空', `长度 ${token.length}`);
    assert(
      uid !== '' && !uid.startsWith('user_'),
      '用户 id 是服务端签发的 uuid（不是本地拼的 id）',
      uid,
    );
    assert(
      sess.user?.name === STUDENT.name,
      `登录者是 ${STUDENT.name}`,
      String(sess.user?.name),
    );

    // ---- 判据二：主界面读到了服务端的数据 ----
    await d.setViewport(1370, 1500);
    await d.enableSemantics();
    await assertMainShell('学生登录后');
    await shot('03_student_home.png');

    const hw = await findSeedHomework();
    assert(
      hw !== null,
      `学生端看得到服务端的种子作业「${SEED_HOMEWORK}」`,
      hw
        ? `${hw.where} (${Math.round(hw.node.x)},${Math.round(hw.node.y)})`
        // 这一步会间歇失败（首页与作业列表都没有），而它的两种可能原因方向
        // 完全相反：**数据没到**（请求超时/失败）还是**到了但没渲染**。
        // 只写「语义树里没找到」等于把这两件事混成一件，所以失败时把这一趟
        // 请求各自的结束方式一起打出来 —— 那也是它第一次失败时最缺的东西。
        : `语义树里没找到 —— ${await diagnoseStall()}`,
    );
    await shot('04_student_homework.png');

    // ---- P2-2 判据：首屏往返数 ----
    //
    // 这个数字**只在这里能拿到**：它不是任何单测能覆盖的（单测里没有真浏览器、
    // 没有真的两个控制器同时 onInit、也没有真的读缓存落盘）。而它又是
    // 「聚合预热有没有真的生效」的唯一证据。
    //
    // 改之前量到的基线是 **18 次**（见 `build/demo-evidence/first-screen-requests.json`
    // 的历史与 `doc/需求规格说明书.md` 的 P2-2）。这个判据挡的是**静默退化**：
    // 段名漂了、路径改了一个字、键算错一个字符 —— 现象全是「首页变慢」，
    // 界面完全正常，而这台机器上 18 次往返只要几毫秒，肉眼永远看不出来。
    //
    // 阈值给 3 而不是 1：聚合之外的零散读是**允许存在**的（不在段表里的端点，
    // 例如家长端按 id 取孩子姓名 —— 那个查询按参数取值，天然没法预聚合）。
    // 但它必须停在个位数：18 与 3 之间没有「看起来差不多」的中间态。
    //
    // 等 1.5s 再数：`_checkWishReminders` 那条读是在 `loadData` 之后**异步**
    // 发的，数早了会漏掉它 —— 而漏掉的那一次恰好是最容易被忘、也最该被数到的
    // 那种（「首页顺手的第二次读」）。
    await new Promise((r) => setTimeout(r, 1500));
    const rq = JSON.parse(await firstScreenRequests());
    log(`    首屏往返：业务读 ${rq.业务读} 次 / 认证 ${rq.认证} 次（资源计时独立计数 ${rq.资源计时独立计数}）`);
    for (const line of rq.按路径) log(`      ${line}`);
    writeFileSync(
      join(OUT_DIR, 'first-screen-requests.json'),
      `${JSON.stringify(rq, null, 2)}\n`,
    );

    const bootstrapHits = rq.按路径.filter((p) => p.includes('/data/bootstrap')).length;
    assert(
      bootstrapHits >= 1,
      '首屏真的拉过一次聚合（`/data/bootstrap`）',
      bootstrapHits >= 1
        ? `${bootstrapHits} 次`
        : '一次都没有 —— 产物可能没带 `DATA_API_BASE_URL`（本地模式），'
            + '或者装配点没打开 `bootstrapPrefetch`',
    );
    assert(
      rq.业务读 <= 3,
      '首屏的业务读**收敛到个位数**（聚合把 18 次压成 1 次）',
      `实际 ${rq.业务读} 次` + (rq.业务读 <= 3 ? '' : ' —— 聚合没有覆盖到的读：'
          + rq.按路径.filter((p) => !p.includes('/data/bootstrap')).join('、')),
    );

    // ---- 判据三：刷新不掉登录 ----
    log('[3] 真·刷新（冷启动）：应当仍在主界面，不该回到登录页');
    await hardReload();
    await d.setViewport(1370, 1500);
    await d.enableSemantics();
    await assertMainShell('刷新后');
    await shot('05_after_reload.png');

    // ---- 判据五：断网时仍读得到缓存，而且**看得出这是旧数据** ----
    //
    // 「读缓存优先」（迁移计划 §7 方案 B）的全部价值就压在这一步上：
    // 网络全断之后界面必须仍拿得出上次同步到的内容。纯在线方案（A）在这里
    // 的表现是**空列表** —— 学生一睁眼以为昨天的作业都没了。
    //
    // 而缓存本身又制造了一个更隐蔽的错：旧数据和实时数据长得一模一样。
    // 所以这里用**两条**判据，缺一不可 —— 只验「看得到作业」会漏掉
    // 最该防的那种情况（家长看着一份旧数据做判断，且不会回来核对）。
    //
    // 断网用 CDP 拦请求，不是停数据服务：停服务要动 dev-stack 的编排
    // （超出这个脚本的边界，也会把后面判据四一起搞坏），拦请求是浏览器级、
    // 可逆、只作用于这一个页面。
    log(`[3b] 断网（拦掉 ${DATA_BASE} 的全部请求）后刷新：应仍读得到缓存且横幅可见`);
    // 先把缓存做旧（1 小时，远超 15s 的新鲜窗口），否则这次命中算不算「陈旧」
    // 计数与做旧是两件事，先分开取证据：一条都没有说明没写进缓存，
    // 有若干条说明缓存是好的 —— 那时若判据仍然不过，问题就在别处。
    const cachedCount = await cacheEntryCount();
    assert(
      typeof cachedCount === 'number' && cachedCount > 0,
      '读缓存已落盘（上面那些读真的写进 localStorage 了）',
      `${cachedCount} 条`,
    );
    await d.blockUrls([
      `*://127.0.0.1:${DATA_PORT}/*`,
      `*://localhost:${DATA_PORT}/*`,
    ]);
    // 清一次资源计时，好让「刚才到底发过哪些请求」只反映**断网这一次**加载。
    // 不清的话里面混着登录那一轮的请求，恰好把最想看的那个淹掉。
    await d.evaluate(`performance.clearResourceTimings()`);
    // 两个「新文档启动前」脚本，都必须打在这次导航**之前**：
    //  · 做旧的 —— 用 evaluate 当场改会有竞态，理由见 `cacheAgeSource`；
    //  · 网络钩子 —— 用 evaluate 装的那种会在导航时被冲掉。
    //
    // 做旧脚本**故意不撤**：[3c] 的对照因此变成「同一份做旧了的缓存，
    // 网络一恢复就不该有横幅」—— 比在对照里换一份新鲜缓存强得多，
    // 后者通过是因为缓存新鲜，不是因为恢复在线。
    await d.addInitScript(cacheAgeSource(3600), { label: '把读缓存做旧 1 小时' });
    await d.addInitScript(NET_PROBE, { label: '网络钩子（挺过导航）' });
    await hardReload();
    await d.setViewport(1370, 1500);
    await d.enableSemantics();
    await assertMainShell('断网刷新后');
    await shot('06_offline_reload.png');

    // ⚠️ 横幅必须**先**探，再去找作业 —— 顺序反了这个判据就时好时坏。
    //
    // 横幅有 20s 自动隐藏，而找作业那一步最长会等 10s（首页探不到还要切到
    // 「作业」页再等一轮），加上中间几次截图/语义树 dump 的开销，等回过头来
    // 探横幅时窗口已经关上。实测就是这个现象：`06_offline_reload.png` 里
    // 横幅清清楚楚（还带着「已 19 次」），15 秒后去探它却什么都不剩，
    // 失败的看起来像「功能没做」，其实是判据自己来晚了。
    const staleBanner = await d.probe('正在显示上次同步的内容', 8000);
    assert(
      staleBanner !== null,
      '缓存过期又连不上时，回落是**可见**的（不是无声地把旧数据当实时数据）',
      staleBanner ? '横幅已出现' : `**没有横幅** —— ${await diagnoseStall()}；**几何** ${await bannerGeometry()}；缓存现状 ${await cacheAges()}`,
    );
    await shot('07_offline_banner.png');

    const offHw = await findSeedHomework(10000);
    assert(
      offHw !== null,
      `断网时仍能看到缓存里的「${SEED_HOMEWORK}」`,
      offHw ? offHw.where : '语义树里没有 —— 缓存没读出来，退回成了 A 方案的空列表',
    );

    // 对照：恢复在线后横幅必须消失。
    //
    // 没有这一步的话，「横幅压根没渲染过」和「横幅出现过又按预期消失」
    // 产出的是同一个观察结果（都没有横幅），负向断言就这样变成一句废话。
    log('[3c] 恢复在线后刷新：横幅应消失（对照）');
    await d.blockUrls([]); // 空数组 = 恢复（只作用于这个页面）
    await hardReload();
    await d.setViewport(1370, 1500);
    await d.enableSemantics();
    await assertMainShell('恢复在线后');
    const bannerGone = await d.probe('正在显示上次同步的内容', 3000);
    assert(bannerGone === null, '恢复在线后不再显示陈旧横幅（对照）');
    const backHw = await findSeedHomework(8000);
    assert(backHw !== null, '恢复在线后那条作业仍在');
    await shot('08_online_again.png');

    // ---- 判据四：家长在另一个会话里看到同一个孩子 ----
    log('[4] 换家长账号（先清本机会话，以便回到登录页）');
    // 清 localStorage 而不是点「退出登录」：菜单层级随版本变，点菜单是走查里
    // 最容易失效的一环。登出链路本身由 `test/cloud_live_test.dart` 覆盖
    // （它验的是「登出后旧 token 立刻失效」）。
    await d.evaluate(`localStorage.removeItem('easy_learn_session_v1')`);
    await hardReload();
    await login({ phone: PARENT.phone, role: PARENT.role });
    await shot('09_parent_after_login.png');

    const parentRaw = await session();
    const parentSess = parentRaw ? JSON.parse(parentRaw) : {};
    assert(
      parentSess.user?.role === 'parent',
      '登录者是家长角色',
      String(parentSess.user?.role),
    );
    assert(
      parentSess.user?.id !== uid,
      '家长是**另一个**会话（token 与 id 都与学生不同）',
      String(parentSess.user?.id),
    );

    await d.setViewport(1370, 1500);
    await d.enableSemantics();
    await assertMainShell('家长登录后');

    const childHw = await findSeedHomework(10000);
    assert(
      childHw !== null,
      `家长端看得到孩子的作业「${SEED_HOMEWORK}」（第二条链路成立）`,
      childHw
        ? `${childHw.where} (${Math.round(childHw.node.x)},${Math.round(childHw.node.y)})`
        : '语义树里没找到',
    );
    await shot('10_parent_sees_child.png');

    // ---- 判据五：客户端真的把会话票带给了 AI 网关 ----
    //
    // 上面那条走的是数据服务，它和 AI 网关是**两个服务、两套校验**。
    // 「客户端带了票」由单元测试证明（`test/ai_identity_session_test.dart`），
    // 而「网关认这张票」只有真跑才知道：取决于两边是不是同一把
    // `AI_SESSION_SECRET`。对不上的症状是所有 AI 调用 401，而数据链路全绿 ——
    // 看起来像「AI 服务挂了」。
    //
    // 探针选「运行观察」页：它读 `/ai/metrics`，**要身份但不占学生配额**。
    // 拿模型端点来验鉴权会顺手烧掉孩子的批改额度。
    log('[5] 家长端「运行观察」：读一次网关看板（要身份、不占配额）');
    await d.setViewport(1370, 1500);
    let entry = await d.probe('运行观察', 6000);
    if (!entry) {
      // 入口在概览页偏下的位置，视口里放不下就不会进语义树。
      await d.wheel(0, 500);
      entry = await d.probe('运行观察', 6000);
    }

    if (!entry) {
      assert(false, '家长端有「运行观察」入口', '语义树里没找到（滚过一屏也没有）');
    } else {
      await d.clickText('运行观察');
      // 等**只在成功时才会出现**的字段名。等「运行观察」本身没有用 ——
      // 那是上一页的入口文案，点完了它还在语义树里。
      const ready = await d.probe('缓存命中', 15000);
      if (ready) {
        assert(true, '家长端读到了网关看板 —— 会话票被网关认下', '缓存命中');
      } else if (await d.probe('本机没有云端用量', 3000)) {
        // 产物是没带 `AI_BASE_URL` 构建的。这不是失败，但也**什么都没验到**，
        // 所以要说出来 —— 静默跳过会让人以为鉴权验过了。
        log('· 产物没带 AI_BASE_URL，这一条什么都没验到（不算失败）');
      } else {
        const err = await d.probe('取不到云端用量', 3000);
        // 「什么都没出现」有三种原因，必须分开报，否则下次还要重走一趟：
        //  ① 请求压根没发 —— 本机那块**抛了异常或者悬住了**，云端那步就没执行，
        //     卡片会永远停在 loading（诊断里该端口 0 条请求）。
        //     两者的区别要另看一眼：**抛了异常**时本机卡片上会写着原因
        //     （`localError`），而**悬住**时本机那两块显示的是**初值**
        //     （「暂无样本」「本次启动以来没有降级」）—— 初值和「跑完了但没数据」
        //     长得一模一样，这是 2026-09-20 那次排查绕远的主要原因；
        //  ② 发出去了但被浏览器拦下 —— 浏览器层面有失败记录，JS 钩子也可能看不到；
        //  ③ 发出去了、网关也答了，但界面没渲染 —— 请求数与状态码都在，界面还是转圈。
        // 少了这份诊断，这三种都只会显示成「既没有成功字段，也没有失败提示」。
        // 两个端口都要报：① 那种情况（`_loadLocal()` 先抛）在**数据端口**才看得见，
        // 只报 AI 端口会把「数据侧先挂了」误读成「AI 没打通」。
        assert(false, '家长端读到了网关看板 —— 会话票被网关认下',
          err
            ? `页面报错：${err.label}`
            : `AI 端口 ${await diagnoseStall(AI_PORT)}；数据端口 ${await diagnoseStall(DATA_PORT)}`
              // 最后这两份是**发布版构建里唯一的错误出口**：未处理的异常不弹界面，
              // 只会安静地消失，而现象长得像网络问题。异常为空也是有信息的结论 ——
              // 说明问题不在「抛错」，而在「压根没走到那一步」。
              + `；未捕获异常 ${JSON.stringify(d.pageErrors({ limit: 3 }))}`
              + `；控制台 ${JSON.stringify(d.consoleLogs({ limit: 6 }))}`);
      }
      await shot('11_parent_ai_observe.png');
    }
  } finally {
    log(`截图与日志：${OUT_DIR}`);
    d.close();
    server.close();
  }
}

main()
  .then(() => {
    if (failures.length) {
      process.stdout.write(`\n失败 ${failures.length} 条：\n`);
      for (const f of failures) process.stdout.write(`  - ${f}\n`);
      process.exit(1);
    }
    process.stdout.write('\n全部判据通过。\n');
    process.exit(0);
  })
  .catch((e) => {
    process.stderr.write(`走查中断: ${e.message}\n`);
    process.exit(1);
  });
