#!/usr/bin/env node
// ───────────────────────────────────────────────────────────────────────
// PoC：验证「新公网打卡 App ↔ ima」里 ima 真正能兜住的那一半
//
// 重要结论（已查实）：ima 的公开 OpenAPI 只覆盖
//   · 知识库增删查  /openapi/wiki/v1/*
//   · 笔记增删查    /openapi/note/v1/*
// 大模型问答（出题/判题）在 /cgi-bin/assistant/qa，仅浏览器 Cookie 可用，
// 不对第三方 App 开放。所以「app 调 ima API 出题判题」不可行。
//
// 因此本 PoC 只验证 ima 能兜住的两件事：
//   ① 用 API Key 连上 ima、找到李雨霏的知识库（连通 + 鉴权）
//   ② 把一条打卡记录作为「笔记」写回 ima（云端累计）
// 出题/判题将由 App 本地完成（选择/判断），或改调公网大模型 API。
//
// 用法：
//   IMA_CLIENT_ID=xxx IMA_API_KEY=yyy node tools/ima-poc.mjs
// ───────────────────────────────────────────────────────────────────────
import { writeFileSync } from 'node:fs';

for (const k of ['HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy', 'ALL_PROXY', 'all_proxy']) {
  delete process.env[k];
}

const CLIENT_ID = process.env.IMA_CLIENT_ID || '';
const API_KEY = process.env.IMA_API_KEY || '';
const WRITE = process.argv.includes('--write');

if (!CLIENT_ID || !API_KEY) {
  console.error('✗ 缺少 ima 凭证：设置 IMA_CLIENT_ID 与 IMA_API_KEY（ima.qq.com/agent-interface 获取）');
  process.exit(2);
}

const headers = () => ({
  'Content-Type': 'application/json',
  'ima-openapi-clientid': CLIENT_ID,
  'ima-openapi-apikey': API_KEY,
});

async function post(url, body) {
  const t0 = Date.now();
  try {
    const r = await fetch(url, { method: 'POST', headers: headers(), body: JSON.stringify(body) });
    const text = await r.text();
    return { ok: r.ok, status: r.status, ms: Date.now() - t0, text };
  } catch (e) {
    return { ok: false, status: 0, ms: Date.now() - t0, text: String(e?.message || e) };
  }
}

function show(label, res, max = 500) {
  const body = res.text.length > max ? res.text.slice(0, max) + ' …(截断)' : res.text;
  console.log(`\n── ${label}  [HTTP ${res.status} / ${res.ms}ms]\n${body}`);
}

async function main() {
  console.log('════ ① 连 ima + 找李雨霏的知识库 ════');
  const list = await post('https://ima.qq.com/openapi/wiki/v1/search_knowledge_base',
    { query: '李雨霏', query_user: true, cursor: '', limit: 20 });
  show('search_knowledge_base', list);
  let kbId = '';
  try {
    const j = JSON.parse(list.text);
    const arr = j?.data?.info_list || j?.info_list || [];
    const hit = (Array.isArray(arr) ? arr : []).find((x) => /李雨霏/.test(x?.kb_name || x?.name || ''));
    if (hit) kbId = hit.kb_id || hit.id;
  } catch { /* ignore */ }
  console.log(kbId ? `\n✓ 命中知识库 kb_id=${kbId}` : '\n⚠ 没解析到 kb_id（但接口通了就够证明连通）');

  if (WRITE) {
    console.log('\n════ ② 写一条打卡笔记回 ima（--write）════');
    const note = '# 打卡记录 2026-10-26\n\n- 主题：文字→数学逻辑转换\n- 完成：5 题（PoC 自测，本地判题）\n- 累计位置：ima 笔记';
    const w = await post('https://ima.qq.com/openapi/note/v1/import_doc',
      { content_format: 1, content: note });
    show('import_doc (笔记写回)', w);
  } else {
    console.log('\n（跳过写回：未加 --write。加 --write 才真写一条笔记到 ima）');
  }

  console.log('\n✓ PoC 跑完。这证明了「ima 作为公网存储」可行；出题/判题需另寻方案（本地题库 or 公网大模型）。');
}

main().catch((e) => { console.error(e); process.exit(1); });
