// Web 端走查：用 CDP 驱动无头 Edge 把真实产物点一遍
// （登录 → 作业页 → 拍照识别 → 上传图片 → 等识别 → 截图确认对话框）。
//
// 存在的理由：`flutter test` 覆盖的是 widget 树，`flutter analyze` 覆盖的是
// 类型。两者都不会告诉你「真浏览器里点下去会不会崩」——比如
// `DropdownButtonFormField` 的 initialValue 不在 items 里时抛的断言，
// 静态检查是过的。这类问题只有把产物真跑一遍才看得见。
//
// 用法：
//   0) 先**带演示数据开关**构建产物（纯本地模式，不带 DATA_API_BASE_URL）：
//        flutter build web --release --no-tree-shake-icons --dart-define=SEED_DEMO_DATA=true
//      漏了这个 --dart-define，首屏是空的、脚本会在第 1 步就失败 ——
//      那不是数据坏了，是参数没带（理由见 lib/services/demo_seed.dart）。
//   1) 先起静态服务： cd build/web && python -m http.server 8088 --bind 127.0.0.1
//   2) 拍照识别那条路： node tools/walkthrough-web.mjs http://127.0.0.1:8088 13800000001 abc123 <图片路径>
//      「不需要批改」那条路： node tools/walkthrough-web.mjs http://127.0.0.1:8088 13800000001 abc123 submit-read
//   截图落在系统临时目录的 walkthrough/ 下。
//
// 登录那几步仍按坐标点（表单布局稳定，量一次能用很久）；进入业务页面之后
// 一律**按语义节点的文本找**（`clickLabel`），因为那些位置随演示数据变化，
// 硬编码坐标会安静地点到别的地方。
//
// 依赖：Node 22+（全局 WebSocket / fetch），本机 Edge。不装任何 npm 包。
//
// ⚠️ 坐标是按视口 1370x858 量出来的（--window-size=1400,1000）。改窗口尺寸
// 就要重新量，否则脚本会安静地点到别的地方 —— 所以下面有一个高度断言。
import { spawn, execSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const EDGE_CANDIDATES = [
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
];

const TARGET = process.argv[2] || 'http://127.0.0.1:8088';
const PHONE = process.argv[3] || '13800000001';
const PASSWORD = process.argv[4] || 'abc123';

// 第 5 个参数有三种含义：`ocr` 模式下是图片路径；写成 `submit-read` 走
// 「不需要批改的作业提交」；写成 `entry-default` 走「照老师原话录一条作业，
// 看批改开关的默认值对不对」；写成 `points` 走积分链路（后三条都不需要图片）。
const ARG5 = process.argv[5] || '';
const SUBMIT_READ = ARG5 === 'submit-read';
const ENTRY_DEFAULT = ARG5 === 'entry-default';
const POINTS = ARG5 === 'points';
const IMAGE = SUBMIT_READ || ENTRY_DEFAULT || POINTS ? '' : ARG5;
const OUT = join(tmpdir(), 'walkthrough');

// Web 端的数据落在 localStorage 里，键名见 `DatabaseService._webStoreCacheKey`。
// 写成一个常量，别在脚本里散着抄字面量 —— 键名一升级（v5 → v6），
// 只改一处的漏改会让断言安静地读不到数据。
const WEB_STORE_KEY = 'easy_learn_web_store_v5';

// 端口必须每次不同：上一次的无头实例可能还没退干净，
// 固定端口会让新脚本连到**旧浏览器**（旧 profile、已登录的状态），
// 报出来的现象是「语义节点 0 个」这类和代码无关的怪错误。
const PORT = 9300 + Math.floor(Math.random() * 400);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const edgePath = EDGE_CANDIDATES.find((p) => existsSync(p));
if (!edgePath) {
  console.error('找不到 Edge/Chrome，可执行文件路径要在 EDGE_CANDIDATES 里补');
  process.exit(1);
}

mkdirSync(OUT, { recursive: true });
const profile = mkdtempSync(join(tmpdir(), 'walkthrough-'));
const edge = spawn(edgePath, [
  '--headless=new', '--disable-gpu', '--no-sandbox', '--hide-scrollbars',
  '--window-size=1400,1000',
  `--remote-debugging-port=${PORT}`,
  `--user-data-dir=${profile}`,
  'about:blank',
], { stdio: 'ignore' });

let ws, seq = 0;
const pending = new Map();
let fileChooserNode = null;

/// 视口尺寸。`clickAt` 用它判断「这个点到底在不在窗口里」——
/// 后面在 main 里量到真实值再覆盖。默认值就是脚本注释里那个 1370x858。
let viewport = { w: 1370, h: 858 };

// 杀进程树：只 kill 顶层 proc 会留下渲染子进程，占着端口和内存。
function killEdge() {
  try { execSync(`taskkill /PID ${edge.pid} /T /F`, { stdio: 'ignore' }); } catch {}
}
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
async function clickAt(x, y, label = '') {
  // **找到了不等于点得到**：语义树里可能有落在视口外的节点（滚动之后
  // 屏外的卡片仍然会留在树里，坐标是 y>视口高），按那个坐标点下去
  // 落在窗口外面，什么都不会发生，而且不报错 —— 后面表现为「点了按钮
  // 但面板没出现」，方向就找错了。这里直接判死。
  if (x < 0 || y < 0 || x > viewport.w || y > viewport.h) {
    throw new Error(
      `要点「${label || '未知目标'}」的位置 (${Math.round(x)},${Math.round(y)}) `
        + `在视口 ${viewport.w}x${viewport.h} 之外 —— 先把它滚进视口再点`,
    );
  }
  const base = { x: Math.round(x), y: Math.round(y), button: 'left', clickCount: 1 };
  await send('Input.dispatchMouseEvent', { type: 'mouseMoved', ...base });
  await send('Input.dispatchMouseEvent', { type: 'mousePressed', ...base });
  await send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...base });
  console.log(`    点击 ${label} (${Math.round(x)},${Math.round(y)})`);
  await sleep(450);
}
const typeText = async (text) => { await send('Input.insertText', { text }); await sleep(400); };

/// 清空当前聚焦的输入框（全选 + 退格）。
///
/// Flutter Web 的文本编辑由一个隐藏的 `<input>` 承载，**直接改 DOM 的 value
/// 不会同步回 Flutter 的状态**，所以只能走键盘。切换账号登录时如果框里
/// 还留着上一个号，`Input.insertText` 会**追加**而不是替换 ——
/// 结果是 `138000000011380000002` 这种永远登录不上的号码，
/// 而现象看着像「家长端缺了某个 tab」。
async function clearFocusedInput() {
  const key = (type, keyName, keyCode, code, modifiers = 0) =>
    send('Input.dispatchKeyEvent', {
      type,
      modifiers,
      key: keyName,
      code,
      windowsVirtualKeyCode: keyCode,
      nativeVirtualKeyCode: keyCode,
    });
  // modifiers=2 是 Ctrl
  await key('keyDown', 'a', 65, 'KeyA', 2);
  await key('keyUp', 'a', 65, 'KeyA', 2);
  await sleep(150);
  await key('keyDown', 'Backspace', 8, 'Backspace');
  await key('keyUp', 'Backspace', 8, 'Backspace');
  await sleep(250);
}

/// 把视口调高，让整个列表一次落进初始视口。
///
/// **为什么必须调**：Flutter Web 的语义节点是**按初始视口**建的，滚动之后
/// 新露出来的卡片不会再补节点。实测过三种表现，全指向同一件事：
/// ①树里只有视口内那几张卡片，怎么滚都不出现；
/// ②树里有屏外的卡片（y=964 > 视口高 858），那种情况下反而能查到；
/// ③滚动后**位置**会更新，但**新的**节点不建。
/// 所以「靠滚动来找屏外内容」这条路在无头环境下不可靠 —— 而脚本报出来的
/// 现象是「这条数据不存在」，会把环境问题指成产品问题。
///
/// 调高视口之后所有卡片都在初始视口里，语义树一次建全。
/// **必须在登录之后调**：登录那几步的坐标是按视口高 858 量的，先调高会让
/// 表单跟着重排，点到别的地方去。
async function enlargeViewport(height = 1500) {
  await send('Emulation.setDeviceMetricsOverride', {
    width: viewport.w,
    height,
    deviceScaleFactor: 1,
    mobile: false,
  });
  viewport = { w: viewport.w, h: height };
  await sleep(2500);
}

/// 打开 Flutter Web 的语义树，并等它长到「够用」。
///
/// Flutter **默认不建**语义树（有性能代价），只在判断「用户需要辅助功能」
/// 时才建，判据就是那个 1x1 的 `flt-semantics-placeholder`
/// （aria-label 是 "Enable accessibility"）被点了一下。
/// 不先点它，整页语义节点就只剩它自己 —— 现象是「按文本找什么都找不到」。
///
/// 用 DOM 的 `el.click()` 而不是 CDP 鼠标事件：这个 placeholder 是 1x1 且贴在
/// (0,0)，按坐标点会打到别的元素上。
///
/// 「够用」要单独等：**建树是分步的**，点完之后可能只建出当前视口那一小块就
/// 停住（实测见过只剩 3 个节点，而且之后滚动也不会再补）。这时后面按文本找
/// 一定失败，而失败位置离真正的原因（树没建起来）很远。所以这里等节点数
/// 稳定下来，不够就再点一次。
async function enableSemantics(minNodes = 8, timeoutMs = 20000) {
  const click = () => evaluate(`(() => {
    const el = document.querySelector('flt-semantics-placeholder')
      || [...document.querySelectorAll('[aria-label]')]
           .find((e) => e.getAttribute('aria-label') === 'Enable accessibility');
    if (!el) return false;
    el.click();
    return true;
  })()`);

  let clicked = await click();
  console.log(`    语义树：${clicked ? '已点 placeholder，等它建起来' : '没找到 placeholder'}`);

  const deadline = Date.now() + timeoutMs;
  let count = 0;
  for (;;) {
    await sleep(1200);
    count = (await dumpDom()).length;
    if (count >= minNodes) break;
    if (Date.now() > deadline) {
      // 再点一次：偶尔第一次点下去只建了视口那一小块。
      clicked = await click();
      await sleep(1500);
      count = (await dumpDom()).length;
      break;
    }
  }
  console.log(`    语义节点 ${count} 个${count < minNodes ? '（偏少，后面按文本找可能失败）' : ''}`);
  return count;
}

/// 当前页面的语义节点。
///
/// Flutter Web 把可访问性节点渲染成带 `aria-label` 的 DOM 元素，
/// 位置也在上面。**按文本找比按坐标找稳得多** —— 那些硬编码坐标是按
/// 某一版演示数据量出来的，演示数据一变（比如多了一条作业）就会
/// 安静地点到别的地方去；而按文本找失败时会明确说「没找到哪个文本」。
///
/// ⚠️ 这个函数**只读 `aria-label`**，两类东西查不到：
/// - **按钮的文字**在 `textContent` 里（`button` 角色的叶子节点，kids=0），
///   只读 aria-label 会让「确认提交」「拍照」这类按钮全都看不见；
/// - **纯文本**（例如开关下面那行「默认按作业内容判断：…」）甚至可能
///   没有对应节点，而截图里它清清楚楚 —— 实测踩过。
///
/// 两者的现象都是「界面上明明有、语义树里没有」。要跟它们打交道时用
/// [dumpButtons]（带 textContent 兜底）或 [probe]（aria-label → 叶子 →
/// 全文，三级兜底）。**容器不能当常规查找源**：它的 textContent 会把整棵
/// 子树的文字拼在一起，一个容器能匹配上任何文字。
async function dumpLabels() {
  return JSON.parse(await evaluate(`JSON.stringify(
    [...document.querySelectorAll('[aria-label]')]
      .map((e) => {
        const r = e.getBoundingClientRect();
        return {
          label: (e.getAttribute('aria-label') || '').trim(),
          x: r.x + r.width / 2,
          y: r.y + r.height / 2,
          w: r.width,
          h: r.height,
        };
      })
      .filter((n) => n.label && n.w > 0 && n.h > 0)
  )`));
}

/// 同上，但把**没有 aria-label 的按钮**也当节点找出来。
///
/// 单独一个函数而不是改 `dumpLabels`：`dumpLabels` 的结果被
/// `scrollForLabel` 之类反复轮询，多出来的节点会让「按文本找」
/// 匹配到语义相近但位置不对的东西。要跟按钮打交道时用这个。
async function dumpButtons() {
  return JSON.parse(await evaluate(`JSON.stringify(
    [...document.querySelectorAll('flt-semantics')]
      .filter((e) => e.children.length === 0)
      .map((e) => {
        const r = e.getBoundingClientRect();
        return {
          role: e.getAttribute('role') || '',
          label: ((e.getAttribute('aria-label') || '') || (e.textContent || ''))
            .replace(/\\s+/g, ' ').trim(),
          x: r.x + r.width / 2,
          y: r.y + r.height / 2,
          w: r.width,
          h: r.height,
        };
      })
      .filter((n) => n.label && n.w > 0 && n.h > 0)
  )`));
}

/// 轮询等一个含指定文字的节点出现。
///
/// 语义树是 Flutter 首帧之后才建的，而且要先有一次**真实鼠标事件**
/// 才会启用（这也解释了为什么登录那几下点击不能省）。
async function waitForLabel(text, timeoutMs = 10000, accept = () => true) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const hit = (await dumpLabels()).filter(
      (n) => n.label.includes(text) && accept(n),
    );
    if (hit.length) return hit[0];
    if (Date.now() > deadline) return null;
    await sleep(500);
  }
}

/// 找到含指定文字的节点并点它。找不到返回 null，由调用方决定
/// 是「这条路走不通」还是「真的坏了」。
async function clickLabel(text, { timeoutMs = 10000, accept } = {}) {
  const node = await waitForLabel(text, timeoutMs, accept);
  if (!node) return null;
  await clickAt(node.x, node.y, `「${node.label}」`);
  return node;
}

/// 节点中心是否落在 `region`（另一个节点）的矩形里。
function inRegion(node, region) {
  return (
    node.x >= region.x - region.w / 2
    && node.x <= region.x + region.w / 2
    && node.y >= region.y - region.h / 2
    && node.y <= region.y + region.h / 2
  );
}

/// 找按钮（含没有 aria-label 的），单次查询。
async function findButton(text, within) {
  const hit = (await dumpButtons()).filter(
    (n) => n.label.includes(text) && (!within || inRegion(n, within)),
  );
  return hit.length ? hit[0] : null;
}

/// 找按钮并点它。走 `dumpButtons`，所以**没有 aria-label 的按钮也能找到**
/// ——「确认提交」就是这种。可选 `within` 限定在某张卡片里，
/// 因为列表上「提交作业」会有好几个，不限定就会点到第一张去。
async function clickButton(text, { timeoutMs = 8000, within } = {}) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const hit = await findButton(text, within);
    if (hit) {
      await clickAt(hit.x, hit.y, `「${hit.label}」`);
      return hit;
    }
    if (Date.now() > deadline) return null;
    await sleep(400);
  }
}

/// 在所有语义节点的**全文**里找（包括只有 `textContent` 的容器）。
///
/// 什么时候需要它：语义树是**分步补建**的。滚动之后，一张卡片的外壳节点
/// 会先出现，带 `aria-label` 的内层节点要晚一步 —— 这段窗口期里只查
/// `aria-label` 会判「查不到」，可它明明已经画在屏幕上了。
/// （实测抓到过：`朗读课文第5课` 的卡片只有外壳节点、没有内层，
/// 而截图里那张卡片完整可见。）
///
/// **容器不能当常规查找源**：它的 `textContent` 会把整棵子树的文字拼在一起，
/// 一个容器能匹配上任何文字。所以只在明确的兜底路径里用。
async function findAnyText(text) {
  return JSON.parse(await evaluate(`JSON.stringify(
    [...document.querySelectorAll('flt-semantics')]
      .filter((e) => (e.textContent || '').includes(${JSON.stringify(text)}))
      .map((e) => {
        const r = e.getBoundingClientRect();
        return {
          role: e.getAttribute('role') || '',
          label: (e.getAttribute('aria-label') || e.textContent || '')
            .replace(/\\s+/g, ' ').trim(),
          x: r.x + r.width / 2,
          y: r.y + r.height / 2,
          w: r.width,
          h: r.height,
        };
      })
      .filter((n) => n.w > 0 && n.h > 0)
      // **紧的排前面**：这个查询会连根容器一起命中（它的 textContent 含有整页
      // 文字），而拿根容器的坐标去「滚到视口中间」等于没滚。
      // 按面积从小到大排，取到的就是刚好装下这句话的那个元素。
      .sort((a, b) => a.w * a.h - b.w * b.h)
  )`));
}

/// 找节点的统一入口：先查 `aria-label`，再查叶子按钮，最后才退到全文。
///
/// 三个来源是**精确度递减**的：`aria-label` 给的是语义边界（卡片、
/// 开关），叶子按钮给的是可点的东西，全文兜底只能证明「文字在页面上」。
/// 顺序不能反 —— 反了会把整页的容器都变成候选。
async function probe(text, timeoutMs = 1400) {
  const direct = (await waitForLabel(text, timeoutMs))
    ?? (await findButton(text));
  if (direct) return direct;
  // ⚠️ `findAnyText` 返回的是**数组**，而空数组是真值 —— 直接 `??` 返回它，
  // 调用方拿到的就是 `[]`，接着 `.label` 是 undefined、`.replace` 当场崩。
  // 这个洞原先看不出来：唯一的调用方 `bringIntoView` 只读 `.y`，
  // 而 `[].y` 是 undefined，比较一律为假，表现为「一直滚、找不到」。
  const loose = await findAnyText(text);
  return loose.length ? loose[0] : null;
}

async function wheel(deltaY) {
  // 先 mouseMoved 再 mouseWheel。Flutter Web 把滚轮派发给**指针当前所在**的
  // 可滚动容器，只发 wheel 不带 hover 时偶发不生效 —— 现象是「滚了但列表没动」，
  // 而脚本下一句会报成「这条数据不存在」。
  const at = { x: 685, y: 620, button: 'none' };
  await send('Input.dispatchMouseEvent', { type: 'mouseMoved', ...at });
  await send('Input.dispatchMouseEvent', {
    ...at,
    type: 'mouseWheel',
    deltaX: 0,
    deltaY,
  });
  await sleep(900);
}

/// 把某个文本对应的节点滚到视口**中间**，然后返回它。找不到返回 null。
///
/// 中间而不是「刚露头」：贴着上下边缘的节点虽然坐标在视口内，但它周围的
/// 兄弟（比如卡片底部那个按钮）还在外面，按几何位置推出来的点会落到窗口外。
///
/// 注意「找」和「挪」是两件事，必须写在同一个循环里：
/// 第一轮先往下滚着找（列表进来时在顶部），找到之后再按它的位置往中间挪。
/// 如果没找到就不往下走 —— 那会漏掉所有需要滚动才露面的目标，
/// 而且现象和「这条数据不存在」一模一样。
async function bringIntoView(text, { top, bottom, steps = 14 } = {}) {
  // 上下界跟着**当前视口**走，不写死：视口被 `enlargeViewport` 调高之后，
  // 还按 858 高来判定「太靠下」就会去做一次没必要的滚动 —— 而滚动恰恰是
  // 无头环境下语义树不补节点的那件事。
  const lo = top ?? 150;
  const hi = bottom ?? viewport.h - 120;
  for (let pass = 0; pass < 2; pass++) {
    if (pass > 0) {
      // 第一轮从上往下没找到，说明它在上面（页面可能停在上次滚过的位置）。
      // 滚回顶部再来一遍，别让脚本栽在「上次留下的滚动位置」上。
      for (let i = 0; i < 12; i++) await wheel(-400);
    }
    for (let i = 0; i <= steps; i++) {
      const node = await probe(text);
      if (node && node.y >= lo && node.y <= hi) return node;
      if (i === steps) break;
      // 找到了但位置偏 → 往视口中间挪；还没找到 → 继续往下找。
      await wheel(node ? (node.y > hi ? 240 : -240) : 260);
    }
  }
  return null;
}

/// 点卡片底部那条通栏按钮（「提交作业」/「更正后重新提交」）。
///
/// 为什么不 `clickLabel('提交作业')`：**整张卡片在语义树里是一个合并节点** ——
/// 标题、状态标签、科目、截止时间、预计时长、按钮文字全在一个 aria-label 里，
/// 单独找按钮文本永远匹配不到。所以只能拿到卡片节点之后再按几何位置点：
/// 按钮是卡片底部那条通栏，取离卡片底边 45px 的位置（按 1338x198 的卡片量得，
/// 居中且占满宽度，所以横向取卡片中线就够）。
async function clickCardAction(card, { aboveBottom = 45 } = {}) {
  const y = card.y + card.h / 2 - aboveBottom;
  await clickAt(card.x, y, '卡片底部按钮');
  return y;
}

/// 连没有 `aria-label` 的节点一起打出来。
///
/// `dumpLabels` 只认 `aria-label`，而 Flutter Web 里有相当一部分节点
/// （按钮、容器、图片位）的 `aria-label` 是**空的**，文字在子元素里 ——
/// 现象是「界面上明明看得见这个按钮，语义树里就是没有」。
/// 排查这类问题要看裸 DOM，别在 `waitForLabel` 上反复试。
async function dumpDom() {
  return JSON.parse(await evaluate(`JSON.stringify(
    [...document.querySelectorAll('flt-semantics')].map((e) => {
      const r = e.getBoundingClientRect();
      return {
        role: e.getAttribute('role') || '',
        label: (e.getAttribute('aria-label') || '').trim(),
        text: (e.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 50),
        kids: e.children.length,
        x: Math.round(r.x + r.width / 2),
        y: Math.round(r.y + r.height / 2),
        w: Math.round(r.width),
        h: Math.round(r.height),
      };
    })
  )`));
}

async function printDom(indent = '      ') {
  for (const n of await dumpDom()) {
    console.log(
      `${indent}${(n.role || '-').padEnd(9)} 「${n.label || n.text || ''}」`
        + ` kids=${n.kids} (${n.x},${n.y}) ${n.w}x${n.h}`,
    );
  }
}

/// 打印当前页面上所有语义节点。找不到东西时用它，比猜坐标快得多。
async function printLabels(indent = '      ') {
  for (const n of await dumpLabels()) {
    console.log(
      `${indent}「${n.label}」 (${Math.round(n.x)},${Math.round(n.y)}) ` +
        `${Math.round(n.w)}x${Math.round(n.h)}`,
    );
  }
}

/// 「不需要批改」那条路：打开朗读作业的提交面板，确认开关默认是关的，
/// 提交之后回到列表看卡片怎么描述这件事。
async function runSubmitRead() {
  console.log('[4b] 把视口调高，让整个列表进入初始视口（语义树才建得全）');
  await enlargeViewport();
  await enableSemantics();
  await shot('04_tall_list.png');

  console.log('[5] 找演示数据里的朗读作业');
  const title = await bringIntoView('朗读课文第5课');
  if (!title) {
    console.log('    没找到。当前页面上的语义节点：');
    await printLabels();
    throw new Error(
      '语义树里没有「朗读课文第5课」—— 演示数据没带上 hw_004，'
        + '或者它被筛掉了（作业列表按截止日期筛「当天」，'
        + '种子里的 dueAt 必须落在今天）。也可能只是语义树没建全，'
        + '看 04_tall_list.png 那张截图。',
    );
  }
  console.log(`    标题在 (${Math.round(title.x)},${Math.round(title.y)})`);
  await shot('10_list.png');

  console.log('[6] 点这张卡片底部的按钮');
  // 先按文字在卡片范围内找；找不到再退回几何位置。
  const btn = (await clickButton('提交作业', { within: title }))
    ?? (await clickButton('重新提交', { within: title }));
  if (!btn) {
    console.log('    卡片里没找到按钮节点，按卡片底部通栏的几何位置点');
    await clickCardAction(title);
  }
  await sleep(2000);
  await shot('11_submit_sheet.png');

  // 点完之后**先确认面板真的开了**，再往下走。否则后面「找不到确认提交」
  // 会被当成面板内的按钮问题，而真实原因可能是这一步没点开。
  const sw = (await dumpLabels()).filter((n) => n.label.includes('需要批改'));
  console.log(`[7] 面板上的「需要批改」节点 ${sw.length} 个：`);
  for (const n of sw) {
    console.log(`      「${n.label.replace(/\n/g, ' / ')}」 (${Math.round(n.x)},${Math.round(n.y)})`);
  }
  if (!sw.length) {
    console.log('    面板没打开。当前页面上的语义节点：');
    await printLabels();
    throw new Error('点了卡片底部按钮，但提交面板没出现');
  }

  console.log('[8] 点「确认提交」');
  const submit = (await clickButton('确认提交'))
    ?? (await clickButton('提交并开始'));
  if (!submit) {
    console.log('    没找到。当前语义节点：');
    await printLabels();
    console.log('    连没有 aria-label 的裸节点一起看：');
    await printDom();
    throw new Error('找不到「确认提交」按钮');
  }
  await sleep(4500);
  await shot('12_after_submit.png');

  console.log('[9] 提交成功后面板该自己关掉');
  const stillOpen = await findButton('确认提交');
  if (stillOpen) {
    throw new Error(
      '提交成功但面板没关 —— 学生会以为没交上，再点一次会把同一批照片重复入库',
    );
  }
  console.log('    已关闭 ✓');

  console.log('[10] 读回落库的那条记录（这条判据不依赖语义树，最硬）');
  // 为什么要有这一步：语义树是 Flutter 按需补建的，滚动之后可能长时间不更新
  // （实测见过登录后只建到第一张卡片就停住），拿它当唯一判据会把环境问题
  // 误报成产品问题。而「不需要批改的作业不许留下批改结果」是这个功能的
  // 核心不变量，直接读库最直接。
  const stored = JSON.parse(await evaluate(`(() => {
    const raw = localStorage.getItem('${WEB_STORE_KEY}');
    if (!raw) return 'null';
    const store = JSON.parse(raw);
    const hw = (store.homework || []).find((h) => h.id === 'hw_004');
    return JSON.stringify(hw || null);
  })()`));

  if (!stored) {
    throw new Error(
      'localStorage 里找不到 hw_004 —— 演示数据没落库，或者存储键名变了'
        + '（看 DatabaseService._webStoreCacheKey）',
    );
  }
  console.log(`      状态=${stored.status} 需要批改=${stored.needsGrading} `
    + `批改时间=${stored.checkedAt ?? 'null'} 得分=${stored.score ?? 'null'} `
    + `评语=${JSON.stringify(stored.summary ?? '')}`);

  const problems = [];
  if (stored.status !== 'finished') {
    problems.push(`状态是 ${stored.status}，应该是 finished（无需批改的作业交上来就算完成）`);
  }
  if (stored.needsGrading) {
    problems.push('needsGrading 还是真 —— 学生在面板上关掉的开关没有落库');
  }
  // 下面这三条是**核心不变量**：不批改就不能留下批改痕迹。
  // 一旦写了 checkedAt，`hasResult` 就会变成真，家长端会显示一个
  // 写着「AI 批改结果」却没有任何内容的面板。
  if (stored.checkedAt != null) problems.push('checkedAt 不该有值（没批改，就不该记批改时间）');
  if (stored.score != null) problems.push('score 不该有值');
  if ((stored.summary ?? '') !== '') problems.push('summary 不该有内容');

  if (problems.length) {
    throw new Error('落库的这条记录不对：\n      - ' + problems.join('\n      - '));
  }
  console.log('      不变量成立：已提交、无批改结果 ✓');

  console.log('[11] 顺带看一眼界面上那张卡片（语义树可能是滞后的，失败只警告）');
  await sleep(1500);
  const noGrade = await bringIntoView('不需要批改');
  await shot('13_after_submit_card.png');
  if (noGrade) {
    console.log(`      「${noGrade.label.replace(/\n/g, ' / ')}」`);
  } else {
    console.log(
      '      ⚠️ 语义树里没查到这句话（Flutter 的语义树补建滞后，'
        + '不代表产品有问题）—— 请直接看 13_after_submit_card.png',
    );
  }
}

/// 找到录入对话框里那个输入框，返回可点的中心点。
///
/// 不按文本找：Flutter Web 的输入框在语义树里是个真 `<input>`，
/// 它的标签可能挂在旁边一个节点上。直接问 DOM 最准 —— 顺便把页面上
/// 每个输入框的位置和标签都打出来，万一对话框里多了个框，
/// 日志里看得见到底点的是哪一个。
async function findTitleInput() {
  const list = JSON.parse(await evaluate(`JSON.stringify(
    [...document.querySelectorAll('input, textarea')]
      .map((e, i) => {
        const r = e.getBoundingClientRect();
        return {
          i,
          label: (e.getAttribute('aria-label') || e.getAttribute('placeholder') || '').trim(),
          x: r.x + r.width / 2,
          y: r.y + r.height / 2,
          w: Math.round(r.width),
          h: Math.round(r.height),
        };
      })
      .filter((n) => n.w > 40 && n.h > 8)
  )`));
  console.log(`    页面上有 ${list.length} 个输入框：`);
  for (const n of list) {
    console.log(`      [${n.i}] 「${n.label || '(无标签)'}」 (${Math.round(n.x)},${Math.round(n.y)}) ${n.w}x${n.h}`);
  }
  return list.find((n) => n.label.includes('作业内容')) ?? list[0] ?? null;
}

/// 在录入对话框里敲一个标题，读回「需要批改」开关的**默认表述**。
///
/// 判据用开关下面那行副标题 —— `NeedsGradingSwitch` 里它是由 `value` 现算的，
/// 而且正是学生真正读到的东西：读到「只上传照片留档」就是关，
/// 读到「提交后由 AI 检查对错」就是开。
async function probeTitleDefault(title) {
  const field = await findTitleInput();
  if (!field) throw new Error('录入对话框里找不到输入框');
  await clickAt(field.x, field.y, '作业内容输入框');
  await sleep(500);

  // 全选再敲。不清掉上一个的话，测出来的是两次输入**拼起来**的标题，
  // 而那个标题在真实使用中永远不会出现（「默写英语单词Unit3字帖一页」）。
  for (const type of ['keyDown', 'keyUp']) {
    await send('Input.dispatchKeyEvent', {
      type,
      modifiers: 2,
      windowsVirtualKeyCode: 65,
      key: 'a',
      code: 'KeyA',
    });
  }
  await sleep(300);
  await typeText(title);
  await sleep(1500);

  const nodes = await dumpLabels();
  const on = nodes.find((n) => n.label.includes('提交后由 AI 检查对错'));
  const off = nodes.find((n) => n.label.includes('只上传照片留档'));
  // 那行「默认按作业内容判断…」是个**纯文本节点**：它既没有 aria-label、
  // 也不是按钮，`dumpLabels` 查不到它（实测就是这样 —— 截图里清清楚楚，
  // 语义节点里没有）。所以这里走 `probe` 的三级兜底，含全文查找。
  const note = await probe('默认按作业内容判断');
  console.log(`    「${title}」→ 开关${on ? '开（要批改）' : off ? '关（不批改）' : '**状态读不到**'}`);
  console.log(`      开关那行：「${(on ?? off)?.label.replace(/\n/g, ' / ') ?? '(没找到)'}」`);
  console.log(`      默认值说明：「${note?.label.replace(/\n/g, ' / ') ?? '(没找到)'}」`);
  return { on: !!on, off: !!off, note: note?.label ?? '' };
}

/// 走查「照老师原话录一条作业」时那个开关的默认值。
///
/// 这是这次改动的核心那一环：默认值不是写死的，是按标题的**类型**推出来的
/// （判据：答案在不在照片里）。单测能证明推导规则，但证明不了
/// 「界面上真按它渲染了」—— 而这个项目已经吃过几次「代码和单测都对、
/// 真控件树里是坏的」的亏（水波纹断言、下拉框断言、提交面板不关）。
///
/// 三个样例里有一个是**反例**（练习册，应该开着）：只测「关」的话，
/// 「开关压根没渲染出来」也会被读成「关」，两者要分得开。
async function runEntryDefault() {
  await enlargeViewport(1100);
  await enableSemantics();
  await shot('20_after_login.png');

  console.log('[5] 点「录入作业」打开录入对话框');
  const open = (await clickButton('录入作业')) ?? (await clickLabel('录入作业'));
  if (!open) {
    console.log('    没找到。当前语义节点：');
    await printLabels();
    throw new Error('找不到「录入作业」按钮');
  }
  await sleep(2000);
  await shot('21_entry_dialog.png');

  console.log('[6] 敲三个标题，看开关的默认值');
  const cases = [
    { title: '默写英语单词Unit3', want: false, why: '默写：题干（词表）不在照片里' },
    { title: '字帖一页', want: false, why: '字帖：照着写，没有对错要判' },
    { title: '完成练习册P12', want: true, why: '书面：题目和答案在同一张纸上' },
  ];

  const problems = [];
  let index = 0;
  for (const c of cases) {
    const got = await probeTitleDefault(c.title);
    await shot(`22_${++index}_entry_${c.want ? 'on' : 'off'}.png`);
    if (got.on === got.off) {
      problems.push(
        `「${c.title}」的开关状态读不到 —— 副标题两句都没出现，`
          + '既不能算开也不能算关（通常是对话框没打开，或语义树没建起来）',
      );
      continue;
    }
    if (got.on !== c.want) {
      problems.push(
        `「${c.title}」的默认值错了：期望${c.want ? '开' : '关'}，`
          + `实际${got.on ? '开' : '关'}（${c.why}）`,
      );
    }
    // 顺带确认「为什么默认是这样」那行还在：一个没有理由的默认值，
    // 学生会先去把它改掉，然后再去想要不要改。
    if (!got.note.includes('默认按作业内容判断')) {
      problems.push(`「${c.title}」下面少了「默认按作业内容判断：…」那行说明`);
    }
  }

  console.log('[7] 点「取消」关掉对话框（不该留下任何作业）');
  const cancel = await clickButton('取消');
  await sleep(1500);
  await shot('23_after_cancel.png');
  if (!cancel) problems.push('找不到「取消」按钮 —— 对话框关不掉');

  if (problems.length) {
    throw new Error('录入默认值不对：\n      - ' + problems.join('\n      - '));
  }
  console.log('    三个样例的默认值都对 ✓');
}

async function runPoints() {
  const studentPhone = process.argv[3] || '13800000001';
  const parentPhone = process.argv[6] || '13800000002';
  const sx = viewport.w / 1370;

  /// 重新载入页面并以指定账号登录。
  ///
  /// 用「重载」而不是「点退出登录」来切角色：Flutter Web 重载之后
  /// `AuthController` 是全新的，必然停在登录页，不需要去点某个菜单 ——
  /// 机器人点菜单是最容易随版本失效的一环。演示数据在 localStorage 里，重载不丢。
  ///
  /// ⚠️ **必须先用 about:blank 中转**。直接 navigate 回 `TARGET` 不可靠：
  /// Flutter 会把地址写成 `TARGET/#/student-home`，而 `TARGET` 与它只差一个
  /// hash —— 浏览器把这当成**同文档导航**，页面根本不重载，于是登录页上
  /// 还留着上一个角色的手机号，新输入被**追加**在后面
  /// （实测 `13800000001` + `13800000002`），登录必然失败，
  /// 而现象看起来像「家长端没有积分 tab」。先跳到空白页再回来，
  /// 才是真的重新加载。
  async function relogin(phone, label, role) {
    console.log(`    [${label}] 重新载入并以 ${phone} 登录（角色：${role}）`);
    await send('Emulation.clearDeviceMetricsOverride');
    viewport = { w: 1370, h: 858 };
    await sleep(600);
    await send('Page.navigate', { url: 'about:blank' });
    await sleep(800);
    await send('Page.navigate', { url: TARGET });

    let up = false;
    for (let i = 0; i < 180; i++) {
      await sleep(1000);
      up = await evaluate(`!!(document.querySelector('flutter-view') || document.querySelector('canvas'))`);
      if (up) { console.log(`      首帧就绪（${i + 1}s）`); break; }
      if ((i + 1) % 30 === 0) console.log(`      仍在等首帧（${i + 1}s）`);
    }
    if (!up) throw new Error('重新登录时首帧没出现');
    await sleep(2500);

    // **角色标签必须先切对**。登录页默认停在「学生」，拿家长账号去登就成了
    // 「学生身份登家长号」→ 登录失败、页面停在原地，而后面所有断言都会报
    // 「没看到某个元素」—— 现象看着像家长端缺了 tab，其实压根没登进去。
    // 反过来（学生账号 + 「家长」标签）同样登不进去。
    // 用语义树点（自己算坐标），别硬编码。
    await enableSemantics(4);
    const roleTab = await clickButton(role, { timeoutMs: 5000 });
    console.log(
      roleTab ? `      已切到「${role}」角色` : `      ⚠️ 没找到「${role}」标签`,
    );
    await sleep(800);

    const sx2 = viewport.w / 1370;
    await clickAt(685 * sx2, 332, '手机号框');
    await clearFocusedInput();
    await typeText(phone);
    await clickAt(685 * sx2, 398, '密码框');
    await clearFocusedInput();
    await typeText(PASSWORD);
    await clickAt(525 * sx2, 514, '协议勾选框');
    await clickAt(685 * sx2, 568, '手机号登录');
    await sleep(6000);

    // 登录之后立刻确认进了首页。不确认的话，落回登录页会在很后面
    // 才以「找不到某个元素」的形式暴露，方向全错。
    await enlargeViewport(1500);
    await enableSemantics();
    const nav = (await probe('首页', 5000)) || (await probe('作业', 5000));
    if (!nav) throw new Error(`以 ${phone} 登录后没进到首页`);
    console.log('      已进入首页');
  }

  /// 断言页面上找得到某段文字，找不到就抛错。
  ///
  /// 走查脚本最怕「安静地什么都没检查」：截图拍了一堆，结论却是人眼看图。
  /// 所以每一步都写死要看到的文字。
  async function expectText(text, what) {
    const hit = await probe(text, 6000);
    if (!hit) throw new Error(`没看到「${text}」（${what}）`);
    console.log(`      ✓ ${what}：出现了「${text}」`);
    return hit;
  }

  /// 读回 Web 端落库的积分流水。
  ///
  /// **比断言界面文字可靠得多**：余额卡上的「累计获得」和数字是两个
  /// 独立文本节点，拼成一句 `累计获得 5` 在语义树里根本不存在 ——
  /// `probe` 必然找不到，而那种失败看起来像「奖励没发出去」，
  /// 实际发得好好的（截图里余额都已经变了）。这类「界面正常、断言挑刺」
  /// 的假阳性最耗时间。
  ///
  /// 只读**原始事实**（动作、分值、撤销标记），不在脚本里重算余额 ——
  /// 把业务算法抄一份到脚本里，两处就会一起错。
  async function readLedgerEntries(studentId) {
    const raw = await evaluate(`localStorage.getItem('${WEB_STORE_KEY}')`);
    if (!raw) throw new Error('localStorage 里没有 Web 端数据，前面是不是没登录成功？');
    const store = JSON.parse(raw);
    return (store['point_ledger'] || []).filter(
      (row) => row['studentId'] === studentId,
    );
  }

  /// 断言存在某个动作的流水，且分值符合预期。
  async function expectEntry(studentId, action, points, what) {
    const entries = await readLedgerEntries(studentId);
    const hit = entries.find((row) => row['action'] === action);
    if (!hit) {
      throw new Error(
        `账本里没有 ${action} 的记录（${what}），现有：`
          + JSON.stringify(entries.map((e) => `${e.action}:${e.points}`)),
      );
    }
    if (hit['points'] !== points) {
      throw new Error(
        `${action} 的分值是 ${hit['points']}，应为 ${points}（${what}）`,
      );
    }
    const signed = points > 0 ? `+${points}` : `${points}`;
    console.log(`      ✓ ${what}：账本里有 ${action} ${signed}`);
    return hit;
  }

  /// 断言某个动作的流水**只有一条**。
  ///
  /// 用来在真机上验证防重键生效：家长连点两次「同意并扣 5 分」是很容易
  /// 发生的手误，账本上必须是同一笔（幂等键撞上就被丢掉），不是两笔。
  async function expectEntryCount(studentId, action, count, what) {
    const entries = await readLedgerEntries(studentId);
    const n = entries.filter((row) => row['action'] === action).length;
    if (n !== count) {
      throw new Error(
        `${action} 的流水有 ${n} 条，应为 ${count} 条（${what}）`,
      );
    }
    console.log(`      ✓ ${what}：${action} 共 ${n} 条`);
  }

  console.log('[P1] 学生端 → 心愿：余额卡与新页面');
  await clickButton('心愿');
  await sleep(1500);
  await shot('P1_student_wish.png');
  await expectText('我的积分', '学生心愿页的积分卡');

  console.log('[P2] 学生端 → 个人信息：积分显示');
  await clickButton('作业');
  await sleep(1200);
  await clickButton('个人信息');
  await sleep(2000);
  await shot('P2_student_profile.png');
  await expectText('我的积分', '个人信息页的积分卡');

  console.log('[P3] 家长端 → 积分 tab：分值设置');
  await relogin(parentPhone, '家长', '家长');
  await shot('P3_parent_home.png');
  await clickButton('积分');
  await sleep(1800);
  await shot('P4_parent_points.png');
  await expectText('每个动作值多少分', '分值设置标题');
  // 7 项里挑两项跨类别确认：作业类、复习类
  await expectText('提交作业（需批改）', '作业类分值项');
  await expectText('完成一轮复习', '复习类分值项');
  await expectText('奖励积分', '奖励分段');

  console.log('[P4] 家长端 → 发一笔奖励');
  const rewardBtn = await findButton('奖励积分');
  if (!rewardBtn) throw new Error('找不到「奖励积分」分段按钮');
  await clickAt(rewardBtn.x, rewardBtn.y, '「奖励积分」分段');
  await sleep(1200);
  await shot('P5_parent_reward_form.png');
  await expectText('额外奖励', '奖励表单');

  console.log('[P5] 家长端 → 心愿 tab：能看到孩子余额');
  await clickButton('心愿');
  await sleep(1500);
  await shot('P6_parent_wish.png');
  await expectText('孩子有', '家长心愿页的余额提示');

  // ---- 兑换闭环：定价 → 攒够 → 申请 → 兑现 ----
  //
  // 标价特意定成 5 分（不是 20），为的是**不用改奖励表单里的默认值**：
  // 那一步要先点「奖励积分」分段、再点同名的输入框，两个节点的文本一样，
  // 按文本找必然分不清。用默认的 5 分就把这个歧义整个绕开了。

  console.log('[P6] 家长给心愿定价 5 分');
  const costBtn = await clickButton('设置积分');
  if (!costBtn) throw new Error('心愿卡上没有「设置积分」按钮');
  await sleep(1200);
  await shot('P7_cost_dialog.png');
  await clickButton('需要的积分');
  await clearFocusedInput();
  await typeText('5');
  await sleep(400);
  await clickButton('保存');
  await sleep(1500);
  await shot('P8_cost_saved.png');
  await expectText('兑现需要 5 积分', '定价已经落到心愿上');

  console.log('[P7] 学生端看到的还是「还差 5 分」');
  await relogin(studentPhone, '学生', '学生');
  await clickButton('心愿');
  await sleep(1500);
  await shot('P9_student_not_enough.png');
  await expectText('还差 5 分', '余额不够时的提示');
  // 余额不够时不该给出可点的申请按钮 —— 让孩子点进一个必然失败的操作，
  // 不如把「还差多少」摆在眼前。
  if (await findButton('申请兑换')) {
    throw new Error('余额不够却出现了「申请兑换」按钮');
  }
  console.log('      ✓ 余额不够时没有「申请兑换」按钮');

  console.log('[P8] 家长奖励 5 分（用表单默认值）');
  await relogin(parentPhone, '家长', '家长');
  await clickButton('积分');
  await sleep(1500);
  await clickButton('奖励积分');
  await sleep(1200);
  const grantBtn = await clickButton('发放奖励');
  if (!grantBtn) throw new Error('找不到「发放奖励」按钮');
  await sleep(2500);
  await shot('P10_after_reward.png');
  await expectEntry('stu_001', 'parentReward', 5, '奖励已经进账');
  await expectText('累计获得', '余额卡上的累计项');

  console.log('[P9] 学生端：积分够了，可以申请');
  await relogin(studentPhone, '学生', '学生');
  await clickButton('心愿');
  await sleep(1500);
  await shot('P11_student_enough.png');
  await expectText('积分已够', '攒够之后的提示');
  const applyBtn = await clickButton('申请兑换');
  if (!applyBtn) throw new Error('积分够了却没看到「申请兑换」按钮');
  await sleep(1800);
  await shot('P12_student_applied.png');
  await expectText('已申请兑换', '申请已经登记，等家长确认');

  console.log('[P10] 家长确认兑现：这一刻才扣分');
  await relogin(parentPhone, '家长', '家长');
  await clickButton('心愿');
  await sleep(1500);
  await shot('P13_parent_pending.png');
  await expectText('孩子申请兑现', '家长看到待处理的申请');
  const approveBtn = await clickButton('同意并扣');
  if (!approveBtn) throw new Error('找不到「同意并扣 N 分」按钮');
  await sleep(2500);
  await shot('P14_parent_redeemed.png');
  await expectText('已兑现', '兑现完成');

  console.log('[P11] 学生端：已兑现，余额归零');
  await relogin(studentPhone, '学生', '学生');
  await clickButton('心愿');
  await sleep(1500);
  await shot('P15_student_redeemed.png');
  await expectText('已兑现', '学生看到兑现结果');
  // 断言账本，**不要**去拼界面上的「累计兑换 5」：余额卡里标签和数字是
  // `_Stat` 里两个独立的 Text，各自是一个语义节点，拼出来的整句在语义树
  // 里不存在，`probe` 必然找不到 —— 那种失败看起来像「兑现没扣分」，
  // 实际扣得好好的。
  await expectEntry('stu_001', 'wishRedeem', -5, '兑现扣分已经记账');
  await expectEntryCount('stu_001', 'wishRedeem', 1, '同一心愿只扣了一次');
  await expectText('累计兑换', '余额卡上的累计兑换项');

  console.log(`[P12] 截图都在 ${OUT}`);
}

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
    if (m.method === 'Page.fileChooserOpened') {
      fileChooserNode = m.params.backendNodeId;
      console.log(`    [事件] 文件选择器被打开 backendNodeId=${fileChooserNode}`);
    }
  };
  await send('Page.enable');
  await send('Runtime.enable');
  await send('DOM.enable');
  // 拦下文件选择器：无头模式下它弹不出来，但拦下之后可以直接把文件
  // 塞给那个 input，等价于用户选了文件。
  await send('Page.setInterceptFileChooserDialog', { enabled: true });

  console.log('[1] 打开 ' + TARGET);
  await send('Page.navigate', { url: TARGET });
  // 等 Flutter 首帧。注意 flt-glass-pane 在 shadow root 里，
  // document.querySelector 查不到它 —— 用 flutter-view / canvas 判断。
  //
  // 给到 300s：canvaskit.wasm 有十几 MB，要在无头浏览器里下完再编译，
  // 而每次走查都是**全新 profile**（没有缓存）。机器一忙，十几秒到两分多钟
  // 都出现过（实测 136s 才起来）、甚至直接卡死不冒首帧 —— 等短了会报
  // 「首帧没出现」，看起来像产物的毛病，其实只是慢。
  // 真要卡死，重新跑一次就好；这不是产物的信号。
  let up = false;
  for (let i = 0; i < 300; i++) {
    await sleep(1000);
    up = await evaluate(`!!(document.querySelector('flutter-view') || document.querySelector('canvas'))`);
    if (up) { console.log(`    Flutter 首帧就绪（${i + 1}s）`); break; }
    if ((i + 1) % 30 === 0) console.log(`    仍在等首帧（${i + 1}s）`);
  }
  if (!up) {
    const html = await evaluate(`document.body ? document.body.innerHTML.slice(0, 500) : '(no body)'`);
    throw new Error('Flutter 首帧没出现，body: ' + html);
  }
  await sleep(2500);

  const vp = JSON.parse(await evaluate(`JSON.stringify({w: window.innerWidth, h: window.innerHeight})`));
  console.log(`[2] 视口 ${vp.w}x${vp.h}`);
  viewport = vp;
  // 坐标是按 1370x858 量的。尺寸不同就宁可停下，也别安静点错位置。
  if (vp.h !== 858) throw new Error(`视口高度 ${vp.h} ≠ 858，坐标需要重新量`);
  const sx = vp.w / 1370, sy = 1;
  await shot('01_login.png');

  console.log('[3] 填登录表单');
  await clickAt(685 * sx, 332 * sy, '手机号框');
  await typeText(PHONE);
  await clickAt(685 * sx, 398 * sy, '密码框');
  await typeText(PASSWORD);
  await clickAt(525 * sx, 514 * sy, '协议勾选框');
  await shot('02_filled.png');

  console.log('[4] 登录');
  await clickAt(685 * sx, 568 * sy, '手机号登录');
  await sleep(6000);
  await shot('03_home.png');

  if (SUBMIT_READ) {
    await runSubmitRead();
    console.log(`[10] 截图都在 ${OUT}`);
    killEdge();
    process.exit(0);
  }

  if (ENTRY_DEFAULT) {
    await runEntryDefault();
    console.log(`[8] 截图都在 ${OUT}`);
    killEdge();
    process.exit(0);
  }

  if (POINTS) {
    // 积分链路的每个页面都在列表深处，先把视口放大、语义树建全，
    // 否则「按文本找」会一律失败，而失败现象看起来像页面缺元素。
    await enlargeViewport(1500);
    await enableSemantics();
    await runPoints();
    console.log(`[P13] 积分链路走查完成，截图都在 ${OUT}`);
    killEdge();
    process.exit(0);
  }

  console.log('[5] 点「拍照识别」打开来源面板');  await clickAt(1014 * sx, 598 * sy, '拍照识别');
  await sleep(1800);
  await shot('04_source_sheet.png');

  if (!IMAGE) {
    console.log('[6] 没给图片路径，到这一步为止');
    killEdge();
    process.exit(0);
  }

  console.log('[6] 点「从相册多选识别」（面板第二项；拍照那项走摄像头）');
  fileChooserNode = null;
  await clickAt(685 * sx, 833 * sy, '从相册多选识别');
  for (let i = 0; i < 20 && fileChooserNode === null; i++) await sleep(500);

  if (fileChooserNode === null) {
    // 兜底：Flutter 直接在 DOM 里建了 input[type=file] 而没走 chooser 事件
    const probe = await send('Runtime.evaluate', { expression: `document.querySelector('input[type=file]')` });
    if (!probe.result?.objectId) {
      console.log('[7] 既没有 chooser 事件也没有 file input，放弃上传');
      killEdge();
      process.exit(0);
    }
    await send('DOM.setFileInputFiles', { files: [IMAGE], objectId: probe.result.objectId });
  } else {
    await send('DOM.setFileInputFiles', { files: [IMAGE], backendNodeId: fileChooserNode });
  }
  await sleep(2000);
  await shot('05_after_upload.png');

  console.log('[7] 等识别（本机 26B 冷启动可能 1-2 分钟），每 6s 留一张截图');
  for (let i = 1; i <= 30; i++) {
    await sleep(6000);
    await shot(`06_wait_${String(i).padStart(2, '0')}.png`);
  }
  console.log(`[8] 截图都在 ${OUT}`);
  killEdge();
  process.exit(0);
}

main().catch((e) => {
  console.error('失败: ' + e.message);
  killEdge();
  process.exit(1);
});
