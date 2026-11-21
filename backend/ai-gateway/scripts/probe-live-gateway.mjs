#!/usr/bin/env node
/**
 * 一次性探针：打**线上**网关一次**真模型调用**。
 *
 * ## 为什么非要有它
 *
 * 刚配好 logConfig 时，只打 `/ai/health` 能证明的东西**不够**：
 * 那条请求只会产生 FC 的**框架日志**（`FC Invoke Start/End RequestId`），
 * 而「日志服务配好了没有」真正要证明的是**我们自己 `console.log` 的那行能进 logstore**
 * —— 网关里唯一那行业务日志是 `handler.js:auditLogger` 的 `ai_call` 审计，
 * 它**只在真的调用模型时才打**。
 *
 * 所以：打一次真调用 → 去 `s logs` 里找 `ai_call`。
 * 找不到就是没配好，跟「探针没跑」无关。
 *
 * ## 用法
 *
 *     node build/probe-live-ai-log.mjs [图片路径]
 *
 * 读 `.env.prod` 的两个地址（不写死到这里，避免第二份真值）：
 * 见下方 CLI_DATA_URL / CLI_AI_URL 环境变量。
 */
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';

const DATA = process.env.CLI_DATA_URL;
const AI = process.env.CLI_AI_URL;
if (!DATA || !AI) {
  console.error('✗ 缺 CLI_DATA_URL / CLI_AI_URL（从 .env.prod 的 CLIENT_DATA_BASE_URL / CLIENT_AI_BASE_URL 来）');
  process.exit(2);
}

const PHONE = process.env.CLI_PHONE ?? '13800000001';
const PASSWORD = process.env.CLI_PASSWORD ?? 'abc123';
/** 位置参数：⚠️ 必须滤掉 `--xxx`，否则 `--content=…` 会被当成图片路径。 */
const positional = process.argv.slice(2).filter((a) => !a.startsWith('--'));
const IMG = positional[0] ?? 'C:/Users/lp_pr/AppData/Local/Temp/hw_test/answer_handwriting.png';

/**
 * 题干。⚠️ **复跑必须换它。**
 *
 * 网关按 payload 缓存 10 分钟，同一个 body 第二次调用会**直接命中缓存**
 * （`units:0` / `model:cache`），而且**不会产生 `ai_call` 日志行** ——
 * 于是「去日志里找证据」会找不到，看起来像日志没配好。
 *
 *     node .../probe-live-gateway.mjs --content="9 × 3 = ?（第二轮）"
 */
const CONTENT = (process.argv.find((a) => a.startsWith('--content=')) ?? '').slice('--content='.length)
  || '9 × 3 = ?';

async function call(base, path, { method = 'POST', body, token } = {}) {
  const res = await fetch(base + path, {
    method,
    headers: {
      'content-type': 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let parsed;
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text.slice(0, 300) }; }
  return { status: res.status, body: parsed };
}

const hhmmss = () => new Date().toTimeString().slice(0, 8);

// ── ① 登录取票 ────────────────────────────────────────────────────────────
const login = await call(DATA, '/auth/login', { body: { phone: PHONE, password: PASSWORD } });
console.log(`[1] 登录取票（${PHONE}）  status=${login.status}  ${hhmmss()}`);
if (login.status !== 200 || !login.body?.data?.token) {
  console.log('    🔴 失败：', JSON.stringify(login.body).slice(0, 300));
  console.log('    提示：生产库里可能没有这个演示账号 —— 换成真实存在的账号再试。');
  process.exit(1);
}
const token = login.body.data.token;
console.log(`    ✅ 拿到票（前 12 位 ${token.slice(0, 12)}…，其余不打印）`);

// ── ② 读图 ───────────────────────────────────────────────────────────────
if (!existsSync(IMG)) {
  console.log(`    🔴 找不到图片：${IMG}`);
  process.exit(1);
}
const bytes = await readFile(IMG);
console.log(`[2] 图片 ${IMG.split('/').pop()} = ${bytes.length} bytes  ${hhmmss()}`);

// ── ③ 真模型调用 ─────────────────────────────────────────────────────────
console.log(`[3] POST ${AI}/ai/review/answer-ocr  ${hhmmss()}`);
const t0 = Date.now();
const r = await call(AI, '/ai/review/answer-ocr', {
  token,
  body: {
    questionContent: CONTENT,
    knowledgePoint: '乘法口诀',
    images: [{ mimeType: 'image/png', base64: bytes.toString('base64') }],
  },
});
const secs = ((Date.now() - t0) / 1000).toFixed(2);
console.log(`    status=${r.status}  耗时 ${secs}s  ${hhmmss()}`);
console.log(`    ok   = ${r.body.ok}`);
console.log(`    data = ${JSON.stringify(r.body.data)}`);
console.log(`    meta = model:${r.body.meta?.model}  units:${r.body.meta?.units}  cached:${r.body.meta?.cached}`);
if (!r.body.ok) console.log(`    error = ${JSON.stringify(r.body.error)}`);

// ⚠️ 缓存命中 = **这次什么都没测到模型**。
//    网关按 payload 缓存 10 分钟，同一个 body 复跑会拿到 `units:0` / `model:cache`，
//    而输出看起来「一切正常」（HTTP 200、data 有值）—— 这个项目反复踩过这个坑。
//    更隐蔽的是：**缓存命中不会产生 `ai_call` 日志行**，于是去日志里找证据时
//    会误判成「日志没配好」。所以这里必须喊出来。
if (r.body.meta?.cached) {
  console.log('\n⚠️ 这次是**缓存命中**（`units:0` / `model:cache`）—— 网关按 payload 缓存 10 分钟，');
  console.log('   所以**没有真的调模型**，日志里也**不会有**这条的 `ai_call` 行（别误判成「日志没配好」）。');
  console.log('   要真测：换一下 `questionContent`（或等缓存过期）再跑。');
}

console.log('\n下一步：');
console.log(`  s logs -s "<上面时刻 -1min>" -e "<上面时刻 +3min>"   # 找 ai_call 那一行`);
