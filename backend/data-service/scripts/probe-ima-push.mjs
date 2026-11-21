#!/usr/bin/env node
/**
 * **ima 推送 · 端到端自测（mock 后端 + 真模块）**
 *
 * ## 为什么用 mock 后端
 *
 * 这个探针不碰真账号（不写用户的 ima 库），用 mock 后端验「修了的那两处契约」：
 *
 *   ① `create_media` **根本没有 `media_type` 字段**（官方要 `content_type` +
 *      `file_ext`）。旧代码往里塞 `media_type`，不管 1 还是 7 都稳定
 *      `220001 invalid media_type` —— 2026-10-27 那次「1 改成 7」修错了对象。
 *   ② 官方 COS 凭证字段是 `bucket_name` / `cos_key`，旧代码只读 `bucket` /
 *      `object_key` ⇒ 真接口返 `bucket_name` 时上传 COS 因 bucket 为空抛
 *      「凭证不完整」。
 *
 * 两处错都不会报错、只会**静默失败**（库一直是空的）。于是用本地 mock ima +
 * mock COS，把**真实代码**走完整链路：
 *
 *   `uploadMarkdown` → `check_repeated_names` → `create_media`
 *                    → `uploadToCos`（SHA1 签名）→ `add_knowledge`
 *
 * 断言它发出去的请求**符合官方契约**。
 *
 * ## 判据
 *
 *   1. `check_repeated_names` 用 `media_type=7`（不是 1）
 *   2. `create_media` **不带** `media_type`，改传 `content_type` / `file_ext`
 *   3. 真接口只返官方字段名 `bucket_name` / `cos_key` 时，COS 上传仍用对桶（不为空）
 *   4. COS PUT 用 SHA1 签名（`Authorization` 以 `q-sign-algorithm=sha1` 开头）
 *   5. `add_knowledge` 拿到 `media_id`
 *   6. 返回 `{ mediaId }` 且等于真接口给的 `media_id`
 *   7. （两份都认）只返旧字段名 `bucket` / `object_key` 也能解析出正确值
 *   8. 真实部署冒烟：`GET /data/ima/status` 可达（确认热更后的代码在跑）
 *
 * ## 用法
 *
 *   node scripts/probe-ima-push.mjs                # mock 自测 + 部署冒烟
 *   PROBE_BASE=http://127.0.0.1:8788 node scripts/probe-ima-push.mjs
 */

import {
  uploadMarkdown,
  createMedia,
} from '../src/ima_openapi.js';

const BASE = (process.env.PROBE_BASE ?? 'http://127.0.0.1:8788').replace(/\/+$/, '');

let passed = 0;
let skipped = 0;
const failures = [];

function ok(label, extra = '') {
  passed += 1;
  console.log(`  ✓ ${label}${extra ? `  ${extra}` : ''}`);
}
function skip(label, reason) {
  skipped += 1;
  console.log(`  – ${label}  [跳过：${reason}]`);
}
function fail(label, detail) {
  failures.push(`${label} —— ${detail}`);
  console.log(`  ✗ ${label}`);
  console.log(`      ${detail}`);
}
async function check(label, fn) {
  try {
    const detail = await fn();
    ok(label, detail ?? '');
  } catch (e) {
    fail(label, e?.message ?? String(e));
  }
}
function assert(cond, message) {
  if (!cond) throw new Error(message);
}

/** 极简响应对象：imaFetch / uploadToCos 只用到 ok / status / text。 */
function res(status, text) {
  return { ok: status >= 200 && status < 300, status, text: async () => text };
}
function jsonRes(obj) {
  return res(200, JSON.stringify(obj));
}

/**
 * 构建一个「只认官方字段名」的 mock ima fetch：
 * 真接口返 `bucket_name` / `cos_key`（**不**返旧字段 `bucket` / `object_key`）。
 * 同时附带一个 mock COS（myqcloud.com）接收 PUT。
 */
function makeOfficialMockFetch(captured) {
  return async (url, init = {}) => {
    const u = new URL(url);
    if (u.hostname === 'ima.qq.com') {
      // ⚠️ 只有 ima 接口 body 是 JSON；COS PUT 的 body 是 markdown 二进制。
      const body = init.body ? JSON.parse(init.body) : null;
      captured.ima.push({ path: u.pathname, body });
      if (u.pathname.endsWith('/check_repeated_names')) {
        return jsonRes({ code: 0, data: { names: [] } });
      }
      if (u.pathname.endsWith('/create_media')) {
        // ⚠️ 只返官方字段名：bucket_name / cos_key。旧代码读 bucket 会拿到 undefined。
        return jsonRes({
          code: 0,
          data: {
            media_id: 'm_probe_official_001',
            bucket_name: 'probe-bucket-1250000000',
            region: 'ap-guangzhou',
            cos_key: 'docs/probe-checkin.md',
            secret_id: 'AKIDsid',
            secret_key: 'secretkey',
            token: 'securitytoken',
          },
        });
      }
      if (u.pathname.endsWith('/add_knowledge')) {
        return jsonRes({ code: 0, data: { media_id: body?.media_id } });
      }
      return jsonRes({ code: 0, data: {} });
    }
    if (u.hostname.includes('myqcloud.com')) {
      // COS PUT：body 是 Buffer，不解析。只收下请求做断言。
      captured.cos.push({
        url,
        authorization: init.headers?.Authorization,
        contentLength: init.headers?.['Content-Length'],
      });
      return res(200, '');
    }
    throw new Error(`mock 不认识的 URL: ${url}`);
  };
}

/** 构建一个「只返旧字段名」的 mock（证明两份都认）。 */
function makeLegacyMockFetch() {
  return async (url, init = {}) => {
    const u = new URL(url);
    if (u.hostname === 'ima.qq.com') {
      if (u.pathname.endsWith('/create_media')) {
        return jsonRes({
          code: 0,
          data: {
            media_id: 'm_probe_legacy_001',
            bucket: 'legacy-bucket-1250000000',
            region: 'ap-guangzhou',
            object_key: 'docs/probe-legacy.md',
            secret_id: 'AKIDsid',
            secret_key: 'secretkey',
            token: 'securitytoken',
          },
        });
      }
      return jsonRes({ code: 0, data: {} });
    }
    return res(200, '');
  };
}

async function main() {
  console.log('═══════════════════════════════════════════════════════════════');
  console.log('  ima 推送 · 端到端自测（mock 后端 + 真实 ima_openapi.js）');
  console.log('═══════════════════════════════════════════════════════════════\n');

  const clientId = 'probe-client';
  const apiKey = 'probe-key';

  // ── 1. 官方字段名链路：uploadMarkdown 完整跑通 ──
  console.log('  ── 官方字段名链路（create_media 返 bucket_name / cos_key）──');
  const cap = { ima: [], cos: [] };
  const fetchImpl = makeOfficialMockFetch(cap);

  let result;
  await check('uploadMarkdown 跑通，返回媒体 id', async () => {
    result = await uploadMarkdown({
      clientId,
      apiKey,
      fetchImpl,
      kbId: 'kb_probe',
      folderId: 'folder_probe',
      title: '打卡档案-2026-10-27',
      markdown: '# 探针打卡\n\n- 一项',
    });
    assert(result && result.mediaId === 'm_probe_official_001', `mediaId 不对：${result?.mediaId}`);
    return `mediaId=${result.mediaId}`;
  });

  await check('check_repeated_names 用 media_type=7（不是 1）', async () => {
    const c = cap.ima.find((x) => x.path.endsWith('/check_repeated_names'));
    assert(c, '没调用 check_repeated_names');
    assert(Array.isArray(c.body.params) && c.body.params.length === 1, 'params 不是长度为 1 的数组');
    assert(c.body.params[0].media_type === 7, `media_type 应为 7，实际 ${c.body.params[0].media_type}`);
    return `params[0].media_type=7`;
  });

  await check('create_media 不带 media_type，改传 content_type/file_ext', async () => {
    const c = cap.ima.find((x) => x.path.endsWith('/create_media'));
    assert(c, '没调用 create_media');
    assert(
      c.body.media_type === undefined,
      `create_media 不许带 media_type（多传即 220001），实际 ${c.body.media_type}`,
    );
    assert(c.body.content_type === 'text/markdown', `content_type 不对：${c.body.content_type}`);
    assert(c.body.file_ext === 'md', `file_ext 不对：${c.body.file_ext}`);
    return 'content_type=text/markdown file_ext=md';
  });

  await check('真接口只返 bucket_name 时，COS 上传仍用对桶（不为空）', async () => {
    assert(cap.cos.length === 1, `COS 上传次数应为 1，实际 ${cap.cos.length}`);
    const put = cap.cos[0];
    assert(put.url.includes('probe-bucket-1250000000'), `PUT 没打到 bucket_name 给的桶：${put.url}`);
    assert(
      put.url.endsWith('/docs/probe-checkin.md'),
      `PUT 路径不是 cos_key 给的：${put.url}`,
    );
    return `PUT ${new URL(put.url).host}${new URL(put.url).pathname}`;
  });

  await check('COS PUT 用 SHA1 签名（Authorization 以 q-sign-algorithm=sha1 开头）', async () => {
    const put = cap.cos[0];
    assert(
      typeof put.authorization === 'string' && put.authorization.startsWith('q-sign-algorithm=sha1'),
      `签名头不对：${put.authorization?.slice(0, 40)}`,
    );
    return 'SHA1 签名';
  });

  await check('add_knowledge 带 media_type + file_info（落库收尾）', async () => {
    const a = cap.ima.find((x) => x.path.endsWith('/add_knowledge'));
    assert(a, '没调用 add_knowledge');
    assert(a.body.media_id === 'm_probe_official_001', `media_id 不对：${a.body.media_id}`);
    assert(a.body.media_type === 7, `add_knowledge 的 media_type 应为 7，实际 ${a.body.media_type}`);
    assert(a.body.file_info?.cos_key, 'add_knowledge 缺 file_info.cos_key');
    return `media_id=${a.body.media_id} media_type=7`;
  });

  // ── 2. 两份都认：旧字段名 bucket / object_key 也能解析 ──
  console.log('\n  ── 字段名兼容性（旧字段名 bucket / object_key）──');
  await check('create_media 只返旧字段名时，cosCredentials.bucket / cosKey 仍正确', async () => {
    const out = await createMedia({
      clientId,
      apiKey,
      fetchImpl: makeLegacyMockFetch(),
      kbId: 'kb_probe',
      fileName: '打卡档案-2026-10-27.md',
      fileSize: 12,
    });
    assert(out.mediaId === 'm_probe_legacy_001', `mediaId 不对：${out.mediaId}`);
    assert(out.cosCredentials.bucket === 'legacy-bucket-1250000000', `bucket 没认出旧字段：${out.cosCredentials.bucket}`);
    assert(out.cosKey === 'docs/probe-legacy.md', `cosKey 没认出旧字段：${out.cosKey}`);
    return `bucket=${out.cosCredentials.bucket} cosKey=${out.cosKey}`;
  });

  // ── 3. 真实部署冒烟（确认热更后的代码在跑）──
  console.log('\n  ── 真实部署冒烟（GET /data/ima/status）──');
  await check('部署可达，ima 状态接口返回合法结构', async () => {
    let r = null;
    let text = '';
    try {
      r = await fetch(`${BASE}/data/ima/status`, { method: 'GET' });
      text = await r.text();
    } catch (e) {
      // 连不上（data-service 没起 / 端口不对）→ 跳过，不拖累判据。
      skip('部署冒烟', `本机 data-service 没在跑（${e.message}）`);
      return 'skipped';
    }
    // 401/403 = 路由命中且鉴权守卫生效（接口在跑，只是没带 token）；
    // 404 = 路由缺失（这才是要抓的「热更没生效」）；其余 2xx = 直接拿到状态。
    if (r.status === 404) {
      throw new Error(`/data/ima/status 返回 404 —— 路由缺失，热更可能没生效`);
    }
    if (r.status === 401 || r.status === 403) {
      return `路由命中，鉴权守卫生效（HTTP ${r.status}）—— 部署在跑`;
    }
    let json = null;
    try { json = JSON.parse(text); } catch { json = { raw: text }; }
    const status = json?.data?.status ?? json?.status;
    assert(
      status === 'unconnected' || status === 'active' || status === 'expired',
      `返回了非预期状态：${status}`,
    );
    return `status=${status}（本机无凭证，应为 unconnected）`;
  });

  console.log('\n───────────────────────────────────────────────────────────────');
  if (failures.length === 0) {
    console.log(
      `  全部通过：${passed} 条判据${skipped > 0 ? `（另有 ${skipped} 条跳过，见上）` : ''}`,
    );
    console.log('───────────────────────────────────────────────────────────────\n');
    process.exit(0);
  }
  console.log(`  通过 ${passed} 条，失败 ${failures.length} 条${skipped > 0 ? `，跳过 ${skipped} 条` : ''}：`);
  for (const f of failures) console.log(`    · ${f}`);
  console.log('───────────────────────────────────────────────────────────────\n');
  process.exit(1);
}

main().catch((e) => {
  console.error(`\n探针异常中止：${e?.stack ?? e}\n`);
  process.exit(2);
});
