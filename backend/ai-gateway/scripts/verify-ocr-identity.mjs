/**
 * 端到端验收：拍照识别的身份链路。
 *
 * 起因是一次真实故障 —— 学生拍照上传，界面说「没能认出作业内容」，
 * 还建议「光线太暗、拍歪了」。实际上**模型一次都没被调用**：
 * 客户端在未登录状态下装配 AI 运行时，把占位符 `anonymous` 当学号发了上来，
 * 网关按「无身份」拒收（配额与审计没法归到任何学生），客户端再降级成本地模拟。
 *
 * 这个脚本把四种情形一次性跑出来，好回答「到底是模型的问题还是代码的问题」：
 *   1. 占位符学号        → 期望被拒，且文案指向「未登录」
 *   2. 完全不带学号      → 期望被拒，文案指向「缺失」（与 1 必须能区分）
 *   3. 真实学号 + 真 PNG → 期望**真的识别成功**（模型真的跑了一遍）
 *   4. 真实学号 + 假声明 → 观察：声明 jpeg 而字节是 png，本地网关是否放行
 *
 * 用法：node scripts/verify-ocr-identity.mjs <图片目录> [学号]
 */
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const BASE = process.env.GATEWAY_BASE ?? 'http://127.0.0.1:8787';
const DIR = process.argv[2] ?? '.';
const STUDENT_ID = process.argv[3] ?? 'stu_001';
const IMAGE = '作业清单_今日作业.png';

async function loadImage() {
  const bytes = await readFile(path.join(DIR, IMAGE));
  return { bytes, base64: bytes.toString('base64'), size: bytes.length };
}

/** 与客户端 `imageMimeTypeOf` 同口径：先看魔数，认不出才看扩展名。 */
function sniffMime(bytes, fileName) {
  if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50) return 'image/png';
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8) return 'image/jpeg';
  if (String(fileName).toLowerCase().endsWith('.png')) return 'image/png';
  return 'image/jpeg';
}

async function post(label, { studentId, mimeType, includeImage, expect }, img) {
  const headers = { 'Content-Type': 'application/json' };
  if (studentId !== null) headers['X-Student-Id'] = studentId;

  const body = includeImage
    ? {
        fileName: IMAGE,
        images: [{ mimeType, byteSize: img.size, base64: img.base64 }],
      }
    : { fileName: IMAGE, images: [] };

  const started = Date.now();
  const res = await fetch(`${BASE}/ai/homework/ocr`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });
  const text = await res.text();
  const ms = Date.now() - started;

  let parsed = null;
  try {
    parsed = JSON.parse(text);
  } catch {
    /* 非 JSON 原样打印 */
  }

  console.log(`\n── ${label}`);
  console.log(`   HTTP ${res.status}  (${ms}ms)`);

  if (parsed === null) {
    console.log(`   非 JSON：${text.slice(0, 200)}`);
    return false;
  }
  if (parsed.ok === false) {
    console.log(`   ok=false  code=${parsed.error.code}  retryable=${parsed.error.retryable}`);
    console.log(`   message：${parsed.error.message}`);
  } else {
    const d = parsed.data ?? {};
    const tasks = d.tasks ?? [];
    console.log(`   ok=true  subject=${d.subject}  confidence=${d.confidence}  tasks=${tasks.length}`);
    for (const task of tasks.slice(0, 6)) {
      console.log(`     · [${task.subject}] ${task.text}`);
    }
    console.log(`   text 前 100 字：${String(d.text ?? '').slice(0, 100).replace(/\n/g, ' / ')}`);
  }

  const verdict = expect(parsed, { status: res.status });
  console.log(`   判定：${verdict.ok ? '✅ 符合预期' : '❌ 不符合预期'}${verdict.note ? ` —— ${verdict.note}` : ''}`);
  return verdict.ok;
}

const img = await loadImage();
console.log(`网关：${BASE}`);
console.log(`图片：${IMAGE}（${img.size} 字节，魔数判定为 ${sniffMime(img.bytes, IMAGE)}）`);
console.log(`学号：${STUDENT_ID}`);

const results = [];

results.push(
  await post(
    '1｜占位符学号 anonymous（旧客户端的行为）',
    {
      studentId: 'anonymous',
      includeImage: true,
      expect: (json) =>
        json?.ok === false &&
        json.error.code === 'bad_request' &&
        /占位符/.test(json.error.message) &&
        /未登录/.test(json.error.message)
          ? { ok: true, note: '拒绝正确，且文案指向「未登录」' }
          : { ok: false, note: `实际 message=${json?.error?.message}` },
    },
    img,
  ),
);

results.push(
  await post(
    '2｜完全不带 X-Student-Id',
    {
      studentId: null,
      includeImage: true,
      expect: (json) =>
        json?.ok === false && /缺少 X-Student-Id/.test(json.error.message)
          ? { ok: true, note: '与情形 1 的文案不同，可区分' }
          : { ok: false, note: `实际 message=${json?.error?.message}` },
    },
    img,
  ),
);

results.push(
  await post(
    `3｜真实学号 ${STUDENT_ID} + PNG（按字节声明类型）`,
    {
      studentId: STUDENT_ID,
      mimeType: sniffMime(img.bytes, IMAGE),
      includeImage: true,
      expect: (json) =>
        json?.ok === true && (json.data?.tasks ?? []).length > 0
          ? { ok: true, note: `识别出 ${(json.data.tasks ?? []).length} 条任务` }
          : { ok: false, note: `实际 ok=${json?.ok} code=${json?.error?.code}` },
    },
    img,
  ),
);

results.push(
  await post(
    '4｜真实学号 + PNG 字节但声明 image/jpeg（旧客户端的 mime 硬编码）',
    {
      studentId: STUDENT_ID,
      mimeType: 'image/jpeg',
      includeImage: true,
      expect: (json) =>
        json?.ok === true
          ? { ok: true, note: '本地网关只按声明值过白名单 —— 所以这个错配能过，但接方舟后会被厂商侧拒绝' }
          : { ok: false, note: `实际 code=${json?.error?.code}` },
    },
    img,
  ),
);

const passed = results.filter(Boolean).length;
console.log(`\n${'='.repeat(60)}`);
console.log(`通过 ${passed}/${results.length}`);
if (passed !== results.length) process.exitCode = 1;
