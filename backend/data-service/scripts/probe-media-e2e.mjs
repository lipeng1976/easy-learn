// 端到端复核：**大附件（音频 / 视频）走 OSS 直传**这条链路在真服务端上是通的。
//
// ══════════════════════════════════════════════════════════════════════════
// 它和 `probe-photo-e2e.mjs` 的分工（别重复造）
// ══════════════════════════════════════════════════════════════════════════
//
//   `probe-photo-e2e.mjs`  本地栈、照片走**函数请求体**、钉的是「服务端生成的 id
//                          被客户端扔掉」那个 bug。默认 `127.0.0.1:8788`。
//   本文件                 默认打**云端**、音视频走**预签名直传**、自带临时账号与
//                          清理。钉的是另一件事：**部署到位了没有**，以及
//                          「签名 → 直传 → 读回 → 写行」这四段能不能连起来。
//
// 为什么非要打云端：2026-10-03 的教训。代码写完、本地测试全绿、APK 也打了，
// 用户装上一点「上传视频」就报「未知端点」—— 因为**服务端压根没重新部署**。
// 那个错误只可能出现在真环境里，任何本地测试都看不见它。
//
// ══════════════════════════════════════════════════════════════════════════
// 判据（每条都配了反面，否则「通过」没有信息量）
// ══════════════════════════════════════════════════════════════════════════
//
//   ① 拿到 token 与学生 id
//   ② sign-upload 回签名        —— 反面：`application/zip` 必须被 **400 拒**
//   ③ PUT 到 OSS 回 2xx        —— ⚠️ 2xx **不足以**说明字节进去了
//   ④ 用**服务端**签名读回，逐字节一致  ← 这条才是「真进桶」的判据；
//                                      也顺带排除「读到桶里别的旧对象」
//   ⑤ 写行成功，回来那行的 mimeType 没被改（kind 判对了）
//
// ══════════════════════════════════════════════════════════════════════════
// 它会往生产库写什么、以及怎么清
// ══════════════════════════════════════════════════════════════════════════
//
//   一个临时学生账号（见 `--phone`）+ 两行 homework_image + 两个 OSS 对象。
//   ⚠️ 对象它自己删（**删后复读**确认 —— OSS 对不存在的键也回 204，光看状态码是假成功）；
//      账号要单独清：
//        node build/_purge-account.mjs 13900000099            # dry-run 看清楚
//        node build/_purge-account.mjs 13900000099 --confirm  # 真删
//
// ⚠️ 这条只证明**字节通路**。「视频能不能播」「音频有没有声音」要在真机上看，
//    别拿本脚本的成功去推断它们。
//
// 用法：
//   node serverless/data-service/scripts/probe-media-e2e.mjs
//   node serverless/data-service/scripts/probe-media-e2e.mjs --base http://127.0.0.1:8788
//   node serverless/data-service/scripts/probe-media-e2e.mjs --keep      # 不删对象
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// scripts/ → data-service/ → serverless/ → 项目根
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
const PHONE = argOf('--phone', '13900000099');
const PASSWORD = argOf('--password', 'e2e-abc123');
const KEEP = argv.includes('--keep');
const BASE = argOf('--base', process.env.E2E_BASE || pick('CLIENT_DATA_BASE_URL'));
if (!BASE) {
  console.error('✗ 拿不到服务地址：`.env.prod` 里没有 CLIENT_DATA_BASE_URL，也没给 --base');
  process.exit(2);
}

const results = [];
const say = (s) => console.log(s);
function check(label, ok, detail) {
  results.push({ label, ok });
  console.log(`  ${ok ? '✓' : '✗'} ${label}${detail ? '  —— ' + detail : ''}`);
  return ok;
}

async function api(method, p, { token, body } = {}) {
  const res = await fetch(BASE + p, {
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
    /* 非 JSON 就留着 text 给报错用 */
  }
  return { status: res.status, json, text };
}

/** 打码后再落日志：成功响应里带**会话 token**，而探针输出常被粘进对话/工单。 */
const mask = (s) =>
  String(s ?? '')
    .replace(/("(?:token|password)"\s*:\s*")[^"]*/g, '$1***MASKED***')
    .slice(0, 300);

// 两种大附件各跑一遍：它们的上限、超时、配额是**分开的**，
// 只测视频会漏掉音频那一支（反过来也一样）。
const KINDS = [
  {
    kind: 'video',
    mime: 'video/mp4',
    ext: 'mp4',
    maxBytes: 50 * 1024 * 1024,
    bytes: 300 * 1024,
  },
  {
    kind: 'audio',
    mime: 'audio/mpeg',
    ext: 'mp3',
    maxBytes: 20 * 1024 * 1024,
    bytes: 120 * 1024,
  },
];

/** 造一段有类型特征的字节。**不**声称它是能播的媒体 —— 这条判据只问字节能不能过去。 */
function makePayload(spec) {
  const buf = Buffer.alloc(spec.bytes, 0);
  if (spec.kind === 'video') {
    buf.writeUInt32BE(24, 0);
    buf.write('ftypisom', 4, 'ascii');
    buf.writeUInt32BE(0x200, 8);
    buf.write('isomiso2avc1mp41', 12, 'ascii');
  } else {
    buf.writeUInt32BE(0x7ffb90, 0); // MPEG-1 Layer III 帧头形状，纯占位
    buf.write('ID3', 4, 'ascii');
  }
  return buf;
}

say(`\n大附件直传端到端 → ${BASE}`);
say(`\n▸ 临时账号 ${PHONE}`);

let token = '';
let studentId = '';
{
  // ① 账号：优先注册（真的走一遍注册），已存在就登录。
  //    判据是「能不能传附件」，不是「注册成功」—— 上次跑剩的账号不该让它变红。
  const reg = await api('POST', '/auth/register', {
    body: { phone: PHONE, password: PASSWORD, role: 'student', name: 'E2E临时' },
  });
  if (reg.status === 200) {
    // ⚠️ 成功响应外面包着 `{ok:true,data:…}`；直接读 `.token` 会拿到 undefined，
    // 症状是「注册成功却说没拿到 token」（第一次跑就撞了）。
    token = reg.json?.data?.token ?? '';
    studentId = reg.json?.data?.user?.id ?? '';
    say('  注册成功（本次真的新建了一个账号）');
  } else {
    const login = await api('POST', '/auth/login', {
      body: { phone: PHONE, password: PASSWORD },
    });
    token = login.json?.data?.token ?? '';
    studentId = login.json?.data?.user?.id ?? '';
    say(`  注册回 ${reg.status}（${reg.json?.error?.code ?? '?'}）→ 改用登录：${login.status}`);
  }
  if (!check('拿到 token 与学生 id', Boolean(token && studentId), `studentId=${studentId}`)) {
    say(`  服务端回：${reg.status} ${mask(reg.text)}`);
    process.exit(1);
  }
}

// 负对照：不支持的 mime **必须**被拒。
// 少了这条，「sign-upload 回签名」可能只是因为服务端对任何 mime 都回签名。
say('\n②-b 负对照：application/zip 必须被拒');
{
  const r = await api('POST', '/data/homework/images/sign-upload', {
    token,
    body: { studentId, mimeType: 'application/zip', maxBytes: 50 * 1024 * 1024 },
  });
  check('不支持的 mime 被拒（非 200）', r.status !== 200,
    `HTTP ${r.status} ${r.json?.error?.code ?? ''}`);
}

let cfg = null;
let signRequest = null;
let iso8601Utc = null;
let store = null;
{
  const oss = await import(`file:///${PROJECT}/serverless/data-service/src/ossimagestore.js`);
  signRequest = oss.signRequest;
  iso8601Utc = oss.iso8601Utc;
  cfg = {
    bucket: pick('OSS_BUCKET'),
    region: pick('OSS_REGION'),
    endpoint: pick('OSS_ENDPOINT'),
    accessKeyId: pick('OSS_ACCESS_KEY_ID'),
    accessKeySecret: pick('OSS_ACCESS_KEY_SECRET'),
  };
  store = oss.createOssImageStore(cfg);
}

const rows = [];
/** 传上去的对象，全部留到最后再删 —— 先删对象会让刚写的行指向一个不存在的键。 */
const keys = [];
for (const spec of KINDS) {
  const payload = makePayload(spec);
  say(`\n② sign-upload（${spec.mime}）`);
  const r = await api('POST', '/data/homework/images/sign-upload', {
    token,
    body: { studentId, mimeType: spec.mime, maxBytes: spec.maxBytes },
  });
  const signed = r.json?.data ?? null;
  if (!check(`服务端回签名（200 + uploadUrl + storageKey）`, r.status === 200 && !!signed?.uploadUrl && !!signed?.storageKey,
    `HTTP ${r.status}`)) {
    say(`  服务端回：${mask(r.text)}`);
    continue;
  }
  say(`  storageKey = ${signed.storageKey}`);
  say(`  签名头     = ${Object.keys(signed.headers ?? {}).join(', ')}`);

  say(`③ PUT 直传到 OSS（${payload.length} 字节）`);
  const put = await fetch(signed.uploadUrl, {
    method: 'PUT',
    headers: signed.headers, // 整份照发：V4 把 content-type / x-oss-* 全纳入签名
    body: payload,
  });
  const putText = await put.text();
  if (!check('PUT 回 2xx', put.ok, `HTTP ${put.status} ${put.ok ? '' : putText.slice(0, 300)}`)) {
    continue;
  }

  say('④ 用服务端签名读回（这条才说明字节真进桶了）');
  let got = null;
  try {
    got = await store.get(signed.storageKey);
  } catch (e) {
    say(`  读回抛错：${e.message}`);
  }
  if (got === null) {
    check('对象真在桶里', false, '读不回来 —— PUT 回了 2xx 但对象不在');
  } else {
    check(`字节数一致（${got.length}）`, got.length === payload.length);
    check('内容逐字节相同（排除读到桶里别的旧对象）', Buffer.compare(got, payload) === 0);
  }

  keys.push({ storageKey: signed.storageKey, uploadUrl: signed.uploadUrl });

  rows.push({
    studentId,
    homeworkId: null, // 附件不挂具体作业也要能存
    storageKey: signed.storageKey,
    fileName: `e2e-probe.${spec.ext}`,
    fileSize: payload.length,
    mimeType: spec.mime,
    ocrStatus: 'pending',
    ocrText: '',
    batchId: 'e2e-media',
    sortOrder: rows.length,
  });
}

// ── ⑥ 写行 ────────────────────────────────────────────────────────────────
say('\n⑥ 写行（POST /data/homework/images）');
if (rows.length === 0) {
  check('写行', false, '前面没有任何一种附件传成功，无从写行');
} else {
  const w = await api('POST', '/data/homework/images', {
    token,
    body: { studentId, images: rows },
  });
  const stored = Array.isArray(w.json?.data?.items) ? w.json.data.items : [];
  check('写行成功且行数一致', w.status === 200 && stored.length === rows.length,
    `HTTP ${w.status} 回 ${stored.length} 行 / 送 ${rows.length} 行`);
  if (w.status !== 200) {
    say(`  服务端回：${mask(w.text)}`);
  } else {
    for (const want of rows) {
      const got = stored.find((x) => x.storageKey === want.storageKey);
      check(`回来的 ${want.mimeType} 那行 mimeType 没被改（kind 判对）`,
        got?.mimeType === want.mimeType, `实际 ${got?.mimeType ?? '（没这行）'}`);
    }
  }
}

// ── ⑦ 清理对象（账号由 `_purge-account.mjs` 清）─────────────────────────────
say('\n⑦ 清理 OSS 对象');
if (KEEP) {
  say(`  --keep：保留 ${keys.length} 个对象（记得自己删）`);
  keys.forEach((k) => say(`    ${k.storageKey}`));
} else {
  for (const k of keys) {
    // ⚠️ key 必须从 **URL 的路径**取。桶名同时出现在**子域**上
    // （`https://<bucket>.<host>/<key>`），用 `indexOf(bucket)` 会切出带域名的假 key；
    // 而 OSS 对**不存在的键**做 DELETE 回 **204** ⇒ 那个错误**不报错**，
    // 脚本照样打印「已清理」而对象还在桶里。2026-10-03 实测撞上过。
    const key = decodeURIComponent(new URL(k.uploadUrl).pathname.replace(/^\/+/, ''));
    const signedDel = signRequest({
      method: 'DELETE',
      bucket: cfg.bucket,
      key,
      headers: {},
      region: cfg.region,
      accessKeyId: cfg.accessKeyId,
      accessKeySecret: cfg.accessKeySecret,
      timestamp: iso8601Utc(Date.now()),
    });
    const dr = await fetch(`${new URL(k.uploadUrl).origin}/${key}`, {
      method: 'DELETE',
      headers: signedDel.headers,
    });
    // 204 不算证据 —— 所以「已删」只能由「删完之后读不回来」支撑。
    let gone = false;
    try {
      await store.get(k.storageKey);
      gone = false;
    } catch {
      gone = true;
    }
    check(`已删 ${key.split('/').pop()}（DELETE ${dr.status} + 删后读不回）`, gone);
  }
}

// ── 汇总 ──────────────────────────────────────────────────────────────────
const bad = results.filter((x) => !x.ok);
say('\n' + '─'.repeat(62));
say(`  ${results.length - bad.length}/${results.length} 条判据通过`);
if (bad.length) {
  say('  失败：');
  bad.forEach((b) => say(`    · ${b.label}`));
}
say(bad.length === 0
  ? '✅ 云端大附件链路打通：签名 → 直传 → 读回 → 写行'
  : '❌ 见上');
say('  ⚠️ 只证明**字节通路**；能不能播要在真机上看。');
say(`  ⚠️ 账号 ${PHONE} 还在（含 ${rows.length} 行 homework_image）—— 清理：\n`
  + `       node build/_purge-account.mjs ${PHONE}\n`
  + `       node build/_purge-account.mjs ${PHONE} --confirm`);
process.exit(bad.length ? 1 : 0);
