#!/usr/bin/env node
/**
 * 核对一串文本**到底进没进构建产物**（默认查 APK 里的 `lib/arm64-v8a/libapp.so`）。
 *
 * ## 为什么值得有个工具
 *
 * 本项目已经**三次**在「改动进没进包」上判断错，每次都是**判据本身**有毛病：
 *
 * 1. 拿中文去 `grep` 产物 → 恒为 0，看起来像「改动没进包」。
 *    真相：**Dart AOT 里中文字面量存的是 UTF-16LE**，只有 ASCII 才是 UTF-8。
 *    本工具**两种编码都试**，所以不必记这条。
 * 2. 拿「命名参数」去搜（`useProxyForRequestHeaders:` 这种）→ 搜不到。
 *    真相：命名参数在 AOT 里会被**消除**，那是**假阴性**。
 *    ⇒ 请用**新增的函数名**（`writeTempAttachment`）或字符串字面量。
 * 3. 忘了**反面**：一条永远找不到的串。没有它，「全都找得到」也可能只是
 *    判据写错了（读到空文件、读错条目）。本工具**自动补一条随机反面**。
 *
 * ## 用法
 *
 *   node tools/apk-contains.mjs <apk 或 libapp.so> <串1> [<串2> ...]
 *
 *   node tools/apk-contains.mjs build/app/outputs/flutter-apk/app-release.apk \
 *        本地文件 直读 "（自测 HTTP "
 *
 * ⚠️ **中文与以 `/` 开头的串，建议写进一个 UTF-8 文件再用 `--from`**：
 *    Git Bash（MSYS）会把命令行里的 `/data/...` 改写成 `C:/.../data/...`，
 *    也可能吃掉中文 —— 判据就此变瞎，而输出看起来只是「找不到」。
 *    这正是本工具存在的理由，所以它自己也踩不得。
 *
 *   node tools/apk-contains.mjs <apk> --from needles.txt   # 一行一个串
 *
 * 不依赖 `unzip`（自带 zip 读取），所以在 PowerShell 里也能跑。
 */
import { readFileSync } from 'node:fs';
import { inflateRawSync } from 'node:zlib';

const DEFAULT_ENTRY = 'lib/arm64-v8a/libapp.so';

/** 从 zip 里取出一个条目（支持 stored 与 deflate）。不依赖外部命令。 */
function readZipEntry(zip, wanted) {
  let eocd = -1;
  const floor = Math.max(0, zip.length - 22 - 0xffff);
  for (let i = zip.length - 22; i >= floor; i--) {
    if (zip.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error('这不是一个 zip（找不到 EOCD）');
  const count = zip.readUInt16LE(eocd + 10);
  let p = zip.readUInt32LE(eocd + 16);
  for (let n = 0; n < count; n++) {
    if (zip.readUInt32LE(p) !== 0x02014b50) throw new Error('中央目录损坏');
    const method = zip.readUInt16LE(p + 10);
    const compSize = zip.readUInt32LE(p + 20);
    const nameLen = zip.readUInt16LE(p + 28);
    const extraLen = zip.readUInt16LE(p + 30);
    const commentLen = zip.readUInt16LE(p + 32);
    const localOff = zip.readUInt32LE(p + 42);
    const name = zip.toString('utf8', p + 46, p + 46 + nameLen);
    if (name === wanted) {
      if (zip.readUInt32LE(localOff) !== 0x04034b50) throw new Error('本地头损坏');
      const start = localOff + 30
        + zip.readUInt16LE(localOff + 26) + zip.readUInt16LE(localOff + 28);
      const raw = zip.subarray(start, start + compSize);
      return method === 0 ? raw : inflateRawSync(raw);
    }
    p += 46 + nameLen + extraLen + commentLen;
  }
  const hint = wanted === DEFAULT_ENTRY
    ? '（这个包可能没打 arm64-v8a —— 用 `--entry lib/<别的 ABI>/libapp.so` 换一个）'
    : '';
  throw new Error(`包里没有 ${wanted} ${hint}`);
}

const [target, ...rest] = process.argv.slice(2);
if (!target || rest.length === 0) {
  console.error('用法：node tools/apk-contains.mjs <apk 或 libapp.so> <串1> [<串2> ...]');
  console.error('  --entry <包内路径>   默认 lib/arm64-v8a/libapp.so');
  console.error('  --from  <文本文件>   一行一个串（UTF-8）—— 中文/含 / 的串建议走这个');
  process.exit(2);
}

/** 取走一个「后跟一个值」的选项，返回它的值（没给就返回 null）。 */
function takeOption(name) {
  const i = rest.indexOf(name);
  if (i < 0) return null;
  const value = rest[i + 1];
  rest.splice(i, 2);
  return value;
}

const entry = takeOption('--entry') ?? DEFAULT_ENTRY;
const fromFile = takeOption('--from');
const needles = fromFile
  ? readFileSync(fromFile, 'utf8').split(/\r?\n/).map((s) => s.trim()).filter(Boolean)
  : [...rest];
if (needles.length === 0) {
  console.error('没有要查的串。');
  process.exit(2);
}

const raw = readFileSync(target);
const buf = target.toLowerCase().endsWith('.apk') ? readZipEntry(raw, entry) : raw;
console.log(`▸ ${target}${target.toLowerCase().endsWith('.apk') ? ` → ${entry}` : ''}`
  + `  （${buf.length} 字节）\n`);

const hasUtf8 = (s) => buf.includes(Buffer.from(s, 'utf8'));
const hasU16 = (s) => buf.includes(Buffer.from(s, 'utf16le'));

let allFound = true;
for (const s of needles) {
  const utf8 = hasUtf8(s);
  const utf16 = hasU16(s);
  const found = utf8 || utf16;
  if (!found) allFound = false;
  const which = utf8 && utf16 ? 'UTF-8 + UTF-16LE' : utf8 ? 'UTF-8' : utf16 ? 'UTF-16LE' : '—';
  console.log(`${found ? '✓' : '✗'}  ${JSON.stringify(s)}   [${which}]`);
}

// 反面：没有它，「全都找得到」可能只是判据写错了。
const control = `XQZ-${Math.random().toString(36).slice(2, 10)}-not-here`;
const controlFound = hasUtf8(control) || hasU16(control);
console.log(`${controlFound ? '⚠️' : '✓'}  反面对照 ${control}  → ${controlFound ? '**居然找到了，判据不可信**' : '找不到（符合预期）'}`);

process.exit(allFound && !controlFound ? 0 : 1);
