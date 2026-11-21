// 量尺：**一个 N 字节的附件，走 App 实际那条路能不能取回来？**
//
// ══════════════════════════════════════════════════════════════════════════
// 为什么需要它（这是 `probe-media-e2e.mjs` 的一个洞）
// ══════════════════════════════════════════════════════════════════════════
//
// `probe-media-e2e.mjs` 的 ④ 是「用**服务端签名**从 OSS 读回」。它证明
// 「字节真进桶了」，但**不是 App 取字节的方式** —— App 走的是
//
//     GET /data/homework/images/file?id=<行 id>      ← 服务端函数把字节搬回来
//
// 而后者要经过一个**函数计算**。函数的响应体有上限，超了不会给你一个截断的
// 文件让你自己发现，而是直接失败。上传侧我们早就为此改了设计（大于 12MB 不走
// 函数请求体、改预签名直传），**读回侧却一直没人问过同一个问题**：
// 一个 11MB 的音频、一个 50MB 的视频，函数回得来吗？
//
// 所以：这是一把量尺，不是一个开关。给一个字节数，它跑完整条链路，
// 只回答一件事 —— **取回来的字节和放进去的到底一不一样**。
//
// ══════════════════════════════════════════════════════════════════════════
// 判据
// ══════════════════════════════════════════════════════════════════════════
//
//   ① 账号就绪
//   ② sign-upload 回签名
//   ③ PUT 回 2xx                     —— ⚠️ 2xx 不足以说明字节进去了
//   ④ 服务端签名读回逐字节一致        —— 「真进桶」的判据
//   ⑤ 写行拿到**服务端生成的 id**     —— 取字节的键是它，不是 storageKey
//   ⑥ **函数读回**：HTTP 200 + 长度一致 + sha256 一致   ← 发现 B32 的就是它
//   ⑦ **直读**（`sign-read` → 带签名头取对象存储）+ Range 分段 ← **客户端现在走的路**
//
// ⑥ 的 sha256 不是多余的：长度对得上、内容被换掉的情形（读到别的对象、
// 部分内容被缓冲截断后又补齐）长度判据看不见。
//
// ══════════════════════════════════════════════════════════════════════════
// ⚠️ ⑥ 与 ⑦ 的关系（2026-10-03 修 B32 之后）
// ══════════════════════════════════════════════════════════════════════════
//
// ⑥ 的上限是**平台给的**（32 MiB），不是配置项，所以超过它的尺寸**永远**会红 ——
// 那不是回归，是修法的依据。客户端从 2026-10-03 起对视频改走 ⑦：
// 服务端只签一个对象存储的位置，字节**不经过函数**，于是多大都行，
// 而且是流式（⑦ 里的 Range 那条就是「拖动进度」的判据）。
//
// 所以：**超过 32 MiB 时，⑥ 只作为说明打印，判据由 ⑦ 来下。**
// 把 ⑥ 也算进结论的话，一个「其实已经修好」的尺寸会被读成仍然坏的。
//
// 用法：
//   node serverless/data-service/scripts/probe-readback-ceiling.mjs --bytes 11500000
//   node serverless/data-service/scripts/probe-readback-ceiling.mjs --bytes 52428800 --mime video/mp4
//   node serverless/data-service/scripts/probe-readback-ceiling.mjs --bytes 100000 --keep
//
// ⚠️ 跑完账号要单独清（`build/_purge-account.mjs`），脚本会把命令打出来。
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const PROJECT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const envText = fs.readFileSync(path.join(PROJECT, '.env.prod'), 'utf8');
const pick = (k) => {
  const m = envText.match(new RegExp('^' + k + '=(.*)$', 'm'));
  return m ? m[1].trim() : '';
};

const argv = process.argv.slice(2);
const argOf = (name, dflt) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : dflt;
};
const SIZE = Number(argOf('--bytes', '11500000'));
const MIME = argOf('--mime', 'audio/mpeg');
const EXT = argOf('--ext', MIME.split('/')[1] === 'mpeg' ? 'mp3' : MIME.split('/')[1]);
const MAX_BYTES = Number(argOf('--max-bytes', String(Math.max(SIZE * 2, 20 * 1024 * 1024))));
const PHONE = argOf('--phone', '13900000098');
const PASSWORD = argOf('--password', 'e2e-abc123');
const KEEP = argv.includes('--keep');
const BASE = argOf('--base', process.env.E2E_BASE || pick('CLIENT_DATA_BASE_URL'));
if (!BASE) {
  console.error('✗ 拿不到服务地址：`.env.prod` 里没有 CLIENT_DATA_BASE_URL，也没给 --base');
  process.exit(2);
}

const results = [];
/** 「只作说明、不进结论」的观察 —— 见文件头「⑥ 与 ⑦ 的关系」。 */
const notes = [];
const say = (s) => console.log(s);
function check(label, ok, detail) {
  results.push({ label, ok });
  console.log(`  ${ok ? '✓' : '✗'} ${label}${detail ? '  —— ' + detail : ''}`);
  return ok;
}
/** 记录但不计入结论（⑥ 在超限尺寸上的红是**预期**的，不是回归）。 */
function note(label, ok, detail) {
  notes.push({ label, ok });
  console.log(`  ${ok ? '✓' : '·'} ${label}${detail ? '  —— ' + detail : ''}`);
  return ok;
}

/**
 * 带一次重试的 fetch。
 *
 * ## 为什么需要（不是「顺手加个健壮性」）
 *
 * 这台机器到云端**偶发** `read ECONNRESET` / 连接超时（项目已知现象，
 * 原样重试即成功）。而本脚本是**量尺**：一次抖动会让它中断在中间，
 * 于是 ⑧ 的清理跑不到 —— **桶里留一个 50MB 的孤儿对象**，
 * 而它不会被任何东西回收（`ATTACHMENT` 的清理是手动的）。
 * 2026-10-03 实测：50MB 那一次就是这样留下的。
 *
 * ## 只重试**抛出来的**网络错误
 *
 * 非 2xx 是**量到的结果**（`ResponseTooLarge` 400 就是本脚本当初存在的理由）。
 * 对它重试等于把结论变成噪音。
 */
async function fetchRetry(url, init) {
  let last;
  for (let i = 1; i <= 2; i++) {
    try {
      return await fetch(url, init);
    } catch (e) {
      last = e;
      say(`    · 第 ${i} 次请求抛网络错（${e.cause?.code ?? e.code ?? e.message}），原样重试`);
    }
  }
  throw last;
}

async function apiJson(method, p, { token, body } = {}) {
  const res = await fetchRetry(BASE + p, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    /* 非 JSON 留着 text 报错用 */
  }
  return { status: res.status, json, text };
}

const mask = (s) =>
  String(s ?? '')
    .replace(/("(?:token|password)"\s*:\s*")[^"]*/g, '$1***MASKED***')
    .slice(0, 300);

const sha = (buf) => crypto.createHash('sha256').update(buf).digest('hex');

say(`\n附件读回量尺 → ${BASE}`);
say(`  目标：${SIZE} 字节 · ${MIME}`);

// ── ① 账号 ────────────────────────────────────────────────────────────────
let token = '';
let studentId = '';
{
  const reg = await apiJson('POST', '/auth/register', {
    body: { phone: PHONE, password: PASSWORD, role: 'student', name: '量尺临时' },
  });
  if (reg.status === 200) {
    token = reg.json?.data?.token ?? '';
    studentId = reg.json?.data?.user?.id ?? '';
    say('  注册成功（本次真的新建了账号）');
  } else {
    const login = await apiJson('POST', '/auth/login', {
      body: { phone: PHONE, password: PASSWORD },
    });
    token = login.json?.data?.token ?? '';
    studentId = login.json?.data?.user?.id ?? '';
    say(`  注册回 ${reg.status} → 改用登录：${login.status}`);
  }
  if (!check('① 拿到 token 与学生 id', Boolean(token && studentId), `studentId=${studentId}`)) {
    say(`  服务端回：${reg.status} ${mask(reg.text)}`);
    process.exit(1);
  }
}

const { signRequest, iso8601Utc, createOssImageStore } = await import(
  `file:///${PROJECT}/serverless/data-service/src/ossimagestore.js`
);
const cfg = {
  bucket: pick('OSS_BUCKET'),
  region: pick('OSS_REGION'),
  endpoint: pick('OSS_ENDPOINT'),
  accessKeyId: pick('OSS_ACCESS_KEY_ID'),
  accessKeySecret: pick('OSS_ACCESS_KEY_SECRET'),
};
const store = createOssImageStore(cfg);

// ── 造载荷 ────────────────────────────────────────────────────────────────
// 有类型特征的随机字节：随机是为了让「内容被换掉」也能被 sha256 抓到；
// 头部写上容器魔数只是为了它躺在桶里时一眼看得出是什么。
const payload = crypto.randomBytes(SIZE);
if (MIME.startsWith('audio/')) payload.write('ID3', 0, 'ascii');
if (MIME.startsWith('video/')) {
  payload.writeUInt32BE(24, 0);
  payload.write('ftypisom', 4, 'ascii');
}
const payloadSha = sha(payload);

// ── ② 签名 ────────────────────────────────────────────────────────────────
say('\n② sign-upload');
const r = await apiJson('POST', '/data/homework/images/sign-upload', {
  token,
  body: { studentId, mimeType: MIME, maxBytes: MAX_BYTES },
});
const signed = r.json?.data ?? null;
if (!check('服务端回签名', r.status === 200 && !!signed?.uploadUrl, `HTTP ${r.status}`)) {
  say(`  服务端回：${mask(r.text)}`);
  process.exit(1);
}
say(`  storageKey = ${signed.storageKey}`);

// ── ③ 直传 ────────────────────────────────────────────────────────────────
say(`\n③ PUT 直传到 OSS（${payload.length} 字节）`);
const t0 = Date.now();
const put = await fetchRetry(signed.uploadUrl, { method: 'PUT', headers: signed.headers, body: payload });
const putMs = Date.now() - t0;
const putText = await put.text();
if (!check('PUT 回 2xx', put.ok, `HTTP ${put.status} · ${putMs}ms ${put.ok ? '' : putText.slice(0, 200)}`)) {
  process.exit(1);
}

// ── ④ 桶里核对 ────────────────────────────────────────────────────────────
say('\n④ 服务端签名读回（确认字节真在桶里）');
let inBucket = null;
try {
  inBucket = await store.get(signed.storageKey);
} catch (e) {
  say(`  读回抛错：${e.message}`);
}
check(`桶里 ${inBucket?.length ?? 0} 字节，sha256 一致`,
  inBucket != null && sha(inBucket) === payloadSha);

// ── ⑤ 写行拿 id ───────────────────────────────────────────────────────────
say('\n⑤ 写行（拿服务端生成的 id —— 读字节的键是它）');
let row = null;
try {
  const w = await apiJson('POST', '/data/homework/images', {
    token,
    body: {
      studentId,
      images: [{
        studentId,
        homeworkId: null,
        storageKey: signed.storageKey,
        fileName: `ceiling-probe.${EXT}`,
        fileSize: payload.length,
        mimeType: MIME,
        ocrStatus: 'pending',
        ocrText: '',
        batchId: 'e2e-ceiling',
        sortOrder: 0,
      }],
    },
  });
  row = w.json?.data?.items?.[0] ?? null;
  if (!check('写行成功且拿到 id', w.status === 200 && !!row?.id, `HTTP ${w.status} id=${row?.id ?? '（无）'}`)) {
    say(`  服务端回：${mask(w.text)}`);
    await bail('⑤ 写行没拿到 id：后面的 ⑥⑦ 无从谈起');
  }
} catch (e) {
  await bail(`⑤ 写行请求失败：${e.message}`);
}

// ── ⑥ 函数读回 ───────────────────────────────────────────────────────────
//
// ⚠️ 超过 32 MiB 时这里**必然**红，而且那是**预期**的（平台硬限制，见文件头）。
// 那些观察用 note() 记，不进结论 —— 结论由 ⑦ 下。
const FUNCTION_RESPONSE_LIMIT = 33554432; // 32 MiB
const overFunctionLimit = payload.length > FUNCTION_RESPONSE_LIMIT;
const see = overFunctionLimit ? note : check;

say('\n⑥ 函数读回 —— 修 B32 之前 App 就是这样做（GET /data/homework/images/file?id=）');
{
  const url = `${BASE}/data/homework/images/file?id=${encodeURIComponent(row.id)}`;
  const t1 = Date.now();
  let res = null;
  let err = null;
  try {
    res = await fetchRetry(url, {
      // 与客户端 `downloadBytes` 逐字一致：它也带 accept: image/*。
      // 服务端今天不看这个头，但量尺要量的是**真实那条请求**。
      headers: { accept: 'image/*', authorization: `Bearer ${token}` },
    });
  } catch (e) {
    err = e;
  }
  const ms = Date.now() - t1;

  if (err) {
    see('函数读回', false, `${ms}ms 抛错：${err.message}`);
  } else {
    const ab = await res.arrayBuffer();
    const got = Buffer.from(ab);
    see('HTTP 200', res.status === 200,
      `${res.status} · ${ms}ms · content-type=${res.headers.get('content-type')} `
      + `content-length=${res.headers.get('content-length')} 实收=${got.length}`);
    see(`长度一致（期望 ${payload.length}，实收 ${got.length}）`, got.length === payload.length);
    see('sha256 一致（长度对但内容被换掉也抓得到）', sha(got) === payloadSha,
      got.length === payload.length ? '' : `实收前 8 字节 sha=${sha(got).slice(0, 12)}`);
    if (res.status !== 200) {
      say(`  响应体前 300 字节：${got.toString('utf8', 0, 300)}`);
      if (overFunctionLimit) {
        say(`  ↳ 这是**预期**的：函数响应体上限 ${FUNCTION_RESPONSE_LIMIT} 字节（32 MiB），`
          + '而这个尺寸超过了它 —— 所以客户端走 ⑦。');
      }
    }
  }
}

// ── ⑦ 直读（客户端从 2026-10-03 起走的就是这条）───────────────────────────
//
// 判的是**客户端真用的那条路**：签一个对象存储的位置，带上服务端签好的头去取。
// ⚠️ 这里**不带会话 token** —— 这条路的鉴权来自 OSS 签名，与我们的 JWT 无关。
// 带上 token 就把「OSS 收不收这份签名」这个唯一的判据糊掉了。
say('\n⑦ 直读 —— 客户端对大附件走的那条（sign-read → 直接取对象存储）');
try {
  const sr = await apiJson('GET', `/data/homework/images/sign-read?id=${encodeURIComponent(row.id)}`, { token });
  const direct = sr.json?.data ?? null;
  if (!check('sign-read 回 readUrl + headers', sr.status === 200 && Boolean(direct?.readUrl),
    `HTTP ${sr.status}${sr.status === 200 ? '' : ' · ' + mask(sr.text)}`)) {
    say('  ↳ 没有这一条，超过 32 MiB 的附件就**永远取不回来**（B32 就是它）。');
  } else {
    // 签名按**空** CanonicalQueryString 算（见 buildCanonicalRequest）——
    // 地址上多一个参数就 SignatureDoesNotMatch，而那个错误看着像 AccessKey 填错。
    check('地址不带查询串', new URL(direct.readUrl).search === '', new URL(direct.readUrl).search || '（无）');

    const t2 = Date.now();
    const res = await fetchRetry(direct.readUrl, { headers: direct.headers });
    const ms2 = Date.now() - t2;
    const got = Buffer.from(await res.arrayBuffer());
    check('HTTP 200（不带会话 token，只有 OSS 签名）', res.status === 200,
      `${res.status} · ${ms2}ms · 实收=${got.length}`);
    check(`长度一致（期望 ${payload.length}，实收 ${got.length}）`, got.length === payload.length);
    check('sha256 一致', sha(got) === payloadSha);
    if (res.status !== 200) say(`  响应体前 300 字节：${got.toString('utf8', 0, 300)}`);

    // Range：播放器边下边播与拖动进度都靠它。`Range` **不在签名头里**，
    // 所以同一份 authorization 对分段请求照样有效 —— 这一条就是
    // 「视频能流式播放」的判据，缺了它，「能取回整段」与「能流式播」是两回事。
    const rng = await fetchRetry(direct.readUrl, {
      headers: { ...direct.headers, Range: 'bytes=0-1023' },
    });
    const rbuf = Buffer.from(await rng.arrayBuffer());
    check('Range 分段返回 206 + 1024 字节', rng.status === 206 && rbuf.length === 1024,
      `HTTP ${rng.status} · ${rbuf.length} 字节 · content-range=${rng.headers.get('content-range')}`);
    if (rng.status === 206) {
      check('分段内容与原字节逐字节一致', Buffer.compare(rbuf, payload.subarray(0, 1024)) === 0);
    }
  }
} catch (e) {
  // 走到这里 = 两次重试都失败了（网络/超时），不是 4xx。**先清理再退**：
  // 崩在这里而不管的话，桶里会留一个 50MB 的孤儿（2026-10-03 真的留下过）。
  await bail(`⑦ 直读中断：${e.cause?.code ?? e.name}: ${e.message}`);
}

// ── ⑧ 清理（抽成函数：⑤–⑦ 中途失败时也要能调到它）────────────────────────
//
// ⚠️ 这一条不是「顺手封装」。2026-10-03 实测：⑦ 的 Range 那一步撞上一次
// 连接超时，脚本**直接崩掉**，于是这个 50MB 的孤儿对象留在桶里 ——
// 而桶里没有任何东西会回收它（附件对象是手工清的）。
// 判据跑不完可以接受，**留下的字节不行**。
async function cleanupOss() {
  if (KEEP) {
    say(`  --keep：保留 ${signed.storageKey}`);
    return;
  }
  const key = decodeURIComponent(new URL(signed.uploadUrl).pathname.replace(/^\/+/, ''));
  const del = signRequest({
    method: 'DELETE',
    bucket: cfg.bucket,
    key,
    headers: {},
    region: cfg.region,
    accessKeyId: cfg.accessKeyId,
    accessKeySecret: cfg.accessKeySecret,
    timestamp: iso8601Utc(Date.now()),
  });
  const dr = await fetchRetry(`${new URL(signed.uploadUrl).origin}/${key}`, {
    method: 'DELETE',
    headers: del.headers,
  });
  // OSS 对**不存在的键**也回 204 —— 所以「删掉了」只能由「删后读不回」支撑。
  let gone = false;
  try {
    await store.get(signed.storageKey);
  } catch {
    gone = true;
  }
  check(`已删（DELETE ${dr.status} + 删后读不回）`, gone);
}

/** 中途出师不利：**先清理再退出**。 */
async function bail(message) {
  check(message, false);
  say('\n⑧ 清理 OSS 对象（因为 ⑤–⑦ 中断，这一步是必须的）');
  try {
    await cleanupOss();
  } catch (e) {
    say(`  ✗ 清理也失败了：${e.message}\n     请手工删 ${signed.storageKey}`);
  }
  say(`  ⚠️ 账号 ${PHONE} 还在（含 1 行 homework_image）—— 清理：\n`
    + `       node build/_purge-account.mjs ${PHONE} --confirm`);
  process.exit(1);
}

say('\n⑧ 清理 OSS 对象');
await cleanupOss();

const bad = results.filter((x) => !x.ok);
say('\n' + '─'.repeat(62));
say(`  ${results.length - bad.length}/${results.length} 条判据通过  ·  ${SIZE} 字节 · ${MIME}`);
if (overFunctionLimit) {
  // ⑥ 那几条不进结论，但**必须打出来** —— 不打的话，「函数那条路仍然是红的」
  // 这件事就不见了，读的人会以为它也好用了。
  const n = notes.filter((x) => !x.ok).length;
  say(`  （另 ${notes.length} 条只作说明：⑥ 函数读回 ${n ? `${n} 条红 —— 平台 32 MiB 上限，预期` : '也通过了'}）`);
}
if (bad.length) bad.forEach((b) => say(`    · ${b.label}`));
say(bad.length === 0
  ? '✅ 这个尺寸能完整取回来'
  : '❌ 这个尺寸取不回来（见上）');
say(`  ⚠️ 账号 ${PHONE} 还在（含 1 行 homework_image）—— 清理：\n`
  + `       node build/_purge-account.mjs ${PHONE} --confirm`);
process.exit(bad.length ? 1 : 0);
