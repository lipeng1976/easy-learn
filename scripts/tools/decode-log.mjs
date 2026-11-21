// 还原被 shell 改坏的日志文件（中文变 `鈺愨晲` / 满屏方块）。
//
// ## 为什么会有这个工具
//
// Windows PowerShell 5.1 下把原生命令的输出存进文件，会叠上**两个独立的坑**：
//
//   ① **二次编码**：`flutter` / `node` 写的是 UTF-8 字节，PowerShell 管道却按
//      **CP936(GBK)** 解码成字符串，再按 `-Encoding utf8` 重写。于是文件是
//      「合法的 UTF-8，但内容是 GBK 误读 UTF-8 的产物」——中文长这样：
//      `鈺愨晲` `鏁版嵁搴撹縼绉?` `锛?`。
//   ② **UTF-16LE**：`Tee-Object -FilePath` 默认写 UTF-16LE（文件头 `ff fe`）。
//      记事本打开"看着正常"，但 grep / ripgrep / 大多数工具读到的是方块。
//
// 两者可以同时出现（2026-09-26 的构建日志就是 `ff fe` + 二次编码）。
//
// ⚠️ 判据：这个工具**不猜**。它只在「还原后坏字符（U+FFFD / C1 控制符）不增加」
//    时才采用还原结果；否则原样输出。所以对本来正常的日志是安全的空操作。
//
// ## 用法
//
// ```bash
// node tools/decode-log.mjs build/_logs/build1.txt
// node tools/decode-log.mjs build/_logs/fl6.txt --out build/_logs/fl6.u8.txt
// ```
import { readFileSync, writeFileSync } from 'node:fs';
import { basename } from 'node:path';

const argv = process.argv.slice(2);
const src = argv.find((a) => !a.startsWith('--'));
const outAt = argv.indexOf('--out');
const out = outAt >= 0 ? argv[outAt + 1] : null;

if (!src) {
  console.error('用法: node tools/decode-log.mjs <乱码日志> [--out <输出文件>]');
  process.exit(2);
}

// ⚠️ **绝不要**给 `--out` 传 `/dev/null` 之类的 Unix 路径。
//    2026-09-26 我这么干了一次，结果在项目根上留下一个叫 `nul` 的目录项，
//    而 Windows 把它当**保留设备名**：safe-delete 转 trash 失败、`rm` EPERM、
//    `git clean` Permission denied、`Remove-Item` 静默无效、cmd 与 Add-Type
//    又被安全策略挡着 —— 折腾六轮也没删掉，只能靠 .gitignore 把它藏起来。
//
//    注意链路：**Git Bash(MSYS) 会把 `/dev/null` 自动翻译成 `nul`**，
//    所以 Node 收到的 argv 就已经是保留名了（从日志里打印出 `nul` 而非
//    `/dev/null` 可以看出来）。要丢弃输出就**别传 `--out`**（默认只打印到 stdout）。
if (out !== null) {
  const asPosix = out.replace(/\\/g, '/');
  const name = basename(asPosix).toLowerCase().split('.')[0];
  const reserved = /^(nul|con|aux|prn|com[1-9]|lpt[1-9])$/.test(name);
  const devNull = /\/dev\/null$/i.test(asPosix);
  if (reserved || devNull) {
    console.error('✗ --out 指向了 Windows 设备名：' + out);
    console.error('  它不会写进文件，只会在磁盘上留一个**删不掉**的目录项。');
    console.error('  想丢弃输出就别传 --out（默认只打印到 stdout）。');
    process.exit(2);
  }
}

// ── GBK 反向表 ──────────────────────────────────────────────────────
// Node 只有 GBK **解码**（`TextDecoder('gbk')`），没有 GBK **编码**
// （`TextEncoder` 只认 utf-8）。所以遍历所有合法双字节序列，用解码结果
// 反查出一张「字符 → 原始字节」的表。
function buildGbkTable() {
  const dec = new TextDecoder('gbk', { fatal: false });
  const map = new Map();
  const buf = new Uint8Array(2);
  for (let lead = 0x81; lead <= 0xfe; lead += 1) {
    buf[0] = lead;
    for (let trail = 0x40; trail <= 0xfe; trail += 1) {
      if (trail === 0x7f) continue; // 0x7F 不是合法尾字节
      buf[1] = trail;
      const s = dec.decode(buf);
      if (s.length === 1 && s !== '\ufffd' && !map.has(s)) map.set(s, [lead, trail]);
    }
  }
  const euro = dec.decode(new Uint8Array([0x80])); // CP936 里 0x80 = €
  if (euro.length === 1 && !map.has(euro)) map.set(euro, [0x80]);
  return map;
}

const GBK = buildGbkTable();
const gbkDec = new TextDecoder('gbk', { fatal: false });
const utf8Dec = new TextDecoder('utf-8', { fatal: false });

/** 字符串 → GBK 字节。编不出的字符用 `?`(0x3F) 占位并计入 `lost`。 */
function gbkEncode(s) {
  const bytes = [];
  let lost = 0;
  for (const ch of s) {
    const cp = ch.codePointAt(0);
    if (cp < 0x80) {
      bytes.push(cp);
      continue;
    }
    const b = GBK.get(ch);
    if (b) {
      bytes.push(b[0], b[1]);
    } else {
      bytes.push(0x3f);
      lost += 1;
    }
  }
  return { bytes: Buffer.from(bytes), lost };
}

/** 「坏字符」计数：替换符 + C1 控制区（误码后最常见的残留）。越低越干净。 */
function damage(s) {
  let bad = 0;
  for (const ch of s) {
    const cp = ch.codePointAt(0);
    if (cp === 0xfffd || (cp >= 0x80 && cp <= 0x9f)) bad += 1;
  }
  return bad;
}

function countChar(s, c) {
  let n = 0;
  for (const ch of s) if (ch === c) n += 1;
  return n;
}

function countNonAscii(s) {
  let n = 0;
  for (const ch of s) if (ch.codePointAt(0) >= 0x80) n += 1;
  return n;
}

/**
 * 把「GBK 误读 UTF-8」的字符串还原回原文；判定不该还原时返回 null。
 *
 * ⚠️ 判据写成什么样，是**实测调出来的**，两次都错在了尺度上：
 *
 *   - 第一版 `damage(text) <= damage(s)`：太严。上游 PowerShell 遇到解不出的
 *     字节会写 `?`，**那个字节是真丢了**，后续字节对不齐，还原时必然多出几个
 *     U+FFFD。那是「信息已损坏」，不是「这条路不对」。
 *   - 第二版「`?` 个数 + 3」：还是太严。一个 emoji 是 4 字节 UTF-8，丢掉它会
 *     产生 **2 个**坏字符（不止 1 个）——实测 build1 日志 dS=0 → dT=44，
 *     而 `?` 只有 29 个，额度 32 差一点点，于是**真·二次编码被拒**。
 *
 *   现在的额度 = 非 ASCII 字符数的 15%（下限 3）。依据是两类文本的**量级差**：
 *
 *   | 输入 | 还原后坏字符 | 额度 | 结果 |
 *   |---|---|---|---|
 *   | 真·二次编码（build1） | 44 | 363×15% = 54 | 放行 ✅ |
 *   | 本来正常的中文 | ≈ 非ASCII×1~2（每字炸 1~2 个） | 同左×15% | 拦住 ✅ |
 *
 *   关键是「坏字符的**量级**」，不是「有没有坏字符」。
 */
function repair(s) {
  const { bytes, lost } = gbkEncode(s);
  const text = utf8Dec.decode(bytes);
  const budget = Math.max(3, Math.floor(countNonAscii(s) * 0.15));
  if (damage(text) > damage(s) + budget) return null;
  if (lost > budget) return null; // 大量字符根本编不出来 ⇒ 不是二次编码
  return text;
}

// ── 外层解码：先判断文件当初是怎么被写出来的 ──────────────────────
const raw = readFileSync(src);
const outer = [];

if (raw.length >= 2 && raw[0] === 0xff && raw[1] === 0xfe) {
  outer.push(['utf-16le', raw.subarray(2).toString('utf16le')]);
} else if (raw.length >= 2 && raw[0] === 0xfe && raw[1] === 0xff) {
  const body = Buffer.from(raw.subarray(2));
  if (body.length % 2 === 1) body.subarray(0, body.length - 1);
  outer.push(['utf-16be', body.swap16().toString('utf16le')]);
} else if (raw.length >= 3 && raw[0] === 0xef && raw[1] === 0xbb && raw[2] === 0xbf) {
  // ⚠️ BOM 是**强证据**：文件当初就是按 UTF-8 写的，不该再去猜 GBK。
  //    不加这一支的话，一个完全正常的 UTF-8 日志会凭空多出一条 GBK 路径，
  //    而那条路径**看起来**也能"还原"（实测 fl_analyze6 就被它骗到了）。
  outer.push(['utf-8(BOM)', raw.subarray(3).toString('utf8')]);
} else {
  let strict = null;
  try {
    strict = new TextDecoder('utf-8', { fatal: true }).decode(raw);
  } catch {
    strict = null;
  }
  // ⚠️ 这里必须是 **if/else**，不能两个都塞进候选：
  //    无 BOM 时先验 UTF-8 有效性，失败才当 GBK。
  if (strict !== null) outer.push(['utf-8', strict]);
  else outer.push(['gbk', gbkDec.decode(raw)]);
}

// 每个外层候选都产出「原样」与「还原后」两个版本
const cands = [];
for (const [how, s] of outer) {
  cands.push([how, s, false]);
  const fixed = repair(s);
  if (fixed !== null && fixed !== s) cands.push([how + ' + gbk→utf8 还原', fixed, true]);
}

// ⚠️ 排序的**第一优先级**是「这个候选声称自己还原过」，不是坏字符多少。
//    原样版的坏字符天然更少（它根本没去解释那些乱码字），拿它跟还原版比
//    `damage` 等于让「不解释」永远赢 —— 我第一版就是这么写的，
//    后果是真·二次编码**永远**被原样版压住，工具看起来"什么也没做"。
const rank = ([, s, fixed]) => (fixed ? 0 : 1e6) + damage(s);
cands.sort((a, b) => rank(a) - rank(b));

const [how, text, fixed] = cands[0];

if (out) {
  writeFileSync(out, text, 'utf8');
  console.log('已写出 ' + out + '  (UTF-8, ' + Buffer.byteLength(text, 'utf8') + ' bytes)');
} else {
  process.stdout.write(text);
}

console.error(
  '\n[decode-log] 判定：' + how +
    ' ｜ 坏字符 ' + damage(text) +
    ' ｜ ' + (fixed ? '已还原二次编码' : '原样输出'),
);
if (argv.includes('--explain')) {
  console.error('  候选（按优先序）：');
  for (const [h, s, f] of cands) {
    console.error('    - ' + h + '：坏字符 ' + damage(s) + '，`?` ' +
      countChar(s, '?') + ' 个' + (f ? '（还原版）' : ''));
  }
  // ⚠️ 无条件试一次还原，把 dS→dT 真实数值打出来。
  //    「判据说不行」和「还原出来是垃圾」是两件事，混在一起就永远调不准。
  console.error('  试还原（不看判据）：');
  for (const [h, s] of outer) {
    const t = utf8Dec.decode(gbkEncode(s).bytes);
    console.error('    - ' + h + '：坏字符 ' + damage(s) + ' → ' + damage(t) +
      '，`?` ' + countChar(s, '?') + ' 个 ｜ 样例: ' +
      JSON.stringify([...t].slice(0, 30).join('')));
  }
}
