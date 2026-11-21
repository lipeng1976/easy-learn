#!/usr/bin/env node
// ima 连接探针：把「家长点连接」这条链路上的每一次 ima 调用**原样**打出来。
//
// ## 为什么需要它
//
// 连接失败时，家长只看到一句中文，服务端日志只有 `[access] POST /data/ima/connect 502`，
// 真正的返回体（HTTP 状态 + body 原文）丢在中间那一跳里。而 ima 的失败有**两种表达**：
//
//   ① HTTP 4xx/5xx          —— 一眼能看出是凭证还是服务故障；
//   ② HTTP 200 + 非 0 业务码 —— 看着完全成功，只是 `data` 里没有你要的字段。
//
// 第二种是最坑的：在修掉之前，它会被读成「未返回 id」，与「字段名写错」长得一模一样。
// 所以探针的原则是 **既不解析、也不兜底**：状态码和 body 原文全打出来，
// 由人一眼判断该改参数还是改字段。
//
// ## 用法
//
// ```bash
// # 只读：搜索同名库，看返回结构（无副作用）
// node scripts/probe-ima-connect.mjs --clientid xxxx --apikey yyyy
//
// # 真建库（ima 建库不可逆！会在这个账号下留一个「伴学-探针-…」）
// node scripts/probe-ima-connect.mjs --clientid xxxx --apikey yyyy --create
// ```
//
// 也可以走环境变量：`IMA_CLIENTID` / `IMA_APIKEY`（命令行优先）。
//
// ## 安全
//
//   · 密钥只从命令行/环境变量读，**不写盘、不进日志、不回显**；
//   · 输出里的 clientid 只显示前 6 位，apikey 完全不显示；
//   · 不加 `--create` 时全程只读（一个 search + 一次 list）。

import { buildKbName, IMA_BASE_URL, IMA_FOLDER_NAMES } from '../src/ima_openapi.js';

const argv = process.argv.slice(2);
const opt = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};
const has = (name) => argv.includes(name);

const clientId = opt('--clientid') ?? process.env.IMA_CLIENTID ?? '';
const apiKey = opt('--apikey') ?? process.env.IMA_APIKEY ?? '';
const displayName = opt('--student') ?? '探针';
const studentId = opt('--student-id') ?? 'probe00000000';
const doCreate = has('--create');
const doFolders = has('--folders') || doCreate;

if (!clientId || !apiKey) {
  console.error('缺少凭证：--clientid / --apikey（或环境变量 IMA_CLIENTID / IMA_APIKEY）');
  process.exit(2);
}

const maskClient = (s) => (s.length <= 6 ? '***' : `${s.slice(0, 6)}…(${s.length} 字符)`);
const kbName = buildKbName(displayName, studentId);

console.log('════════════════════════════════════════════════════════════');
console.log(`  ima 连接探针  clientid=${maskClient(clientId)}  apikey=***`);
console.log(`  目标库名：${kbName}（${Buffer.byteLength(kbName, 'utf8')} 字节 / ${kbName.length} 字符）`);
console.log(`  模式：${doCreate ? '会真建库（不可逆）' : '只读'}`);
console.log('════════════════════════════════════════════════════════════');

let failures = 0;

/** 打一次 ima 调用，返回解析后的 body（失败时返回 null，但**不让整个探针中断**）。 */
async function call(path, body, label) {
  console.log(`\n── ${label} ──`);
  console.log(`POST ${path}`);
  console.log(`body: ${JSON.stringify(body)}`);
  let res;
  let text = '';
  try {
    res = await fetch(`${IMA_BASE_URL}${path}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'ima-openapi-clientid': clientId,
        'ima-openapi-apikey': apiKey,
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(15000),
    });
    text = await res.text();
  } catch (err) {
    failures += 1;
    console.log(`  ✗ 请求没发出去/超时：${err.message}`);
    return null;
  }

  console.log(`  HTTP ${res.status}`);

  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    console.log(`  ✗ 不是 JSON：${text.slice(0, 400)}`);
    failures += 1;
    return null;
  }

  // 原文照打（截断 1200 字，够看清结构又不刷屏）
  const pretty = JSON.stringify(json, null, 2);
  console.log(`  body: ${pretty.length > 1200 ? `${pretty.slice(0, 1200)}\n  …（已截断）` : pretty}`);

  const bizCode = json?.code ?? json?.retcode;
  if (!res.ok) {
    failures += 1;
    console.log(`  ✗ HTTP 失败（${res.status}）—— 这一层服务端会映射成 ima_auth_failed / ima_request_failed`);
    return json;
  }
  if (bizCode !== undefined && bizCode !== null && String(bizCode) !== '0') {
    failures += 1;
    console.log(`  ✗ 业务失败：code=${bizCode} ${json.errmsg ?? json.message ?? ''}`);
    console.log('     ↑ 这就是「HTTP 200 看着成功」的那一类；修复前会被读成「未返回 id」');
    return json;
  }

  console.log('  ✓ 成功（HTTP 200 且业务码为 0/缺省）');
  return json;
}

// ── 1. 搜索同名库（只读）──
const found = await call(
  '/openapi/wiki/v1/search_knowledge_base',
  { query: kbName, query_user: true, cursor: '', limit: 20 },
  '1. search_knowledge_base（只读）',
);
const infoList = found?.data?.info_list ?? found?.data?.knowledge_base_list ?? [];
console.log(`\n  info_list 共 ${infoList.length} 条`);
if (infoList.length > 0) {
  const first = infoList[0];
  console.log(`  第一条的键：${Object.keys(first).join(' / ')}`);
  const kbId = first.kb_id ?? first.id ?? first.knowledge_base_id;
  console.log(`  能取到 id 吗：${kbId ? `✓ ${kbId}` : '✗ 取不到（这就是「未返回 id」的另一种来源）'}`);
  if (!kbId) failures += 1;
}

// ── 2. 建库（不可逆，需 --create）──
let kbId = infoList.find((x) => (x?.kb_name ?? x?.name) === kbName);
kbId = kbId ? (kbId.kb_id ?? kbId.id ?? kbId.knowledge_base_id) : undefined;

if (!kbId && doCreate) {
  const made = await call(
    '/openapi/wiki/v1/create_knowledge_base',
    { name: kbName, description: '伴学连接探针（可删）', type: 1001 },
    '2. create_knowledge_base（会真建库）',
  );
  const data = made?.data ?? made;
  kbId = data?.knowledge_base_id ?? data?.kb_id ?? data?.id;
  console.log(`\n  从返回里取到的 id：${kbId ? `✓ ${kbId}` : '✗ 取不到'}`);
  console.log(`  返回的键：${data && typeof data === 'object' ? Object.keys(data).join(' / ') : '（无 data）'}`);
  if (!kbId) failures += 1;
} else if (!doCreate) {
  console.log('\n  （跳过建库：没有 --create，且没有已存在的同名库）');
}

// ── 3. 列根目录 + 建文件夹 ──
if (kbId && doFolders) {
  const list = await call(
    '/openapi/wiki/v1/get_knowledge_list',
    { knowledge_base_id: kbId, cursor: '', limit: 50 },
    '3. get_knowledge_list（列根目录）',
  );
  const entries = list?.data?.knowledge_list ?? list?.data?.info_list ?? list?.data?.list ?? [];
  console.log(`\n  条目 ${entries.length} 条；data 的键：${
    list?.data && typeof list.data === 'object' ? Object.keys(list.data).join(' / ') : '（无 data）'
  }`);
  console.log('  ↑ 若这里是 `knowledge_list` 而服务端读的是 `info_list`，就会每次重建文件夹');

  for (const [key, name] of Object.entries(IMA_FOLDER_NAMES)) {
    const existed = entries.find((e) => (e?.title ?? e?.name) === name);
    if (existed) {
      console.log(`\n── 文件夹「${name}」已存在，跳过（${existed.media_id ?? existed.folder_id ?? existed.id}）──`);
      continue;
    }
    const made = await call(
      '/openapi/wiki/v1/create_folder',
      { knowledge_base_id: kbId, name },
      `4. create_folder（${key}）`,
    );
    const data = made?.data ?? made;
    const folderId = data?.media_id ?? data?.folder_id ?? data?.id;
    console.log(`\n  从返回里取到的文件夹 id：${folderId ? `✓ ${folderId}` : '✗ 取不到'}`);
    console.log(`  返回的键：${data && typeof data === 'object' ? Object.keys(data).join(' / ') : '（无 data）'}`);
  }
}

console.log('\n════════════════════════════════════════════════════════════');
if (failures === 0) {
  console.log('  全部成功。若 App 里仍连不上，问题在 App↔服务的这一段，不在这里。');
} else {
  console.log(`  有 ${failures} 处失败 —— 上面带 ✗ 的那几行就是 ima 的原始说法。`);
}
console.log('════════════════════════════════════════════════════════════\n');
process.exit(failures === 0 ? 0 : 1);
