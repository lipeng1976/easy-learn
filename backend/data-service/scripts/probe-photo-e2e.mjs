// 端到端复核：「提交作业后当前界面看不到照片」这个 bug，在**真服务端**上确实修好了。
//
// 单测钉的是客户端逻辑（假服务端）；这条钉的是**真链路**：
//   真 Postgres + 真文件系统 + 真 RLS + 真 handler。
//
// 复现的正是真机那条路径：
//   ① 上传字节  → POST /data/homework/images/upload
//   ② 写照片行  → POST /data/homework/images   ← 服务端**回它自己生成的行**
//   ③ 用返回行的 id 读回字节 → GET /data/homework/images/file?id=
//
// 反面（必须一起成立的对照）：
//   ④ 拿「上传时那个本地占位 id」去读 → **必须 404**
//      这一条是真机症状的成因；没有它，③ 通过也不能说明 id 有意义。
//
// 用法（栈要已在跑）：
//   node build/_probe-photo-e2e.mjs
import { readFileSync } from 'node:fs';

const BASE = process.env.E2E_BASE ?? 'http://127.0.0.1:8788';
const STUDENT_PHONE = '13800000001';
const PASSWORD = 'abc123';

let pass = 0;
let fail = 0;
function check(name, ok, detail = '') {
  if (ok) {
    pass++;
    console.log(`  ✓ ${name}`);
  } else {
    fail++;
    console.log(`  ✗ ${name}${detail ? `  —— ${detail}` : ''}`);
  }
}

async function json(path, { method = 'GET', body, token } = {}) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      ...(body ? { 'content-type': 'application/json' } : {}),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let parsed = null;
  try {
    parsed = JSON.parse(text);
  } catch {
    /* 非 JSON 就留 null */
  }
  return { status: res.status, json: parsed, text };
}

/** 走公开账号端点拿票（`/auth/*`，注意**无 `/data`**）。 */
async function login(phone) {
  const r = await json('/auth/login', {
    method: 'POST',
    body: { phone, password: PASSWORD },
  });
  const data = r.json?.data ?? r.json;
  const token = data?.token ?? data?.session?.token;
  if (!token) {
    throw new Error(`登录失败：HTTP ${r.status} ${r.text.slice(0, 300)}`);
  }
  return { token, data };
}

// 一张最小的合法 JPEG（够走完存储即可，内容不重要）。
const JPEG = Buffer.from(
  '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a' +
    'HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA' +
    'AAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==',
  'base64',
);

const stamp = Date.now();
const BATCH = `e2e-${stamp}`;

console.log(`端到端复核 → ${BASE}\n`);

const { token, data: session } = await login(STUDENT_PHONE);
const studentId = session?.user?.id ?? session?.user?.userId ?? session?.userId ?? session?.id;
if (!studentId) {
  throw new Error(`登录响应里找不到学生 id：${JSON.stringify(session).slice(0, 400)}`);
}
console.log(`已登录学生 ${STUDENT_PHONE}（id=${studentId}）\n`);

// ── 找一个可挂的作业（照片行要挂到真实作业上）────────────────────────
const hwList = await json('/data/homework', { token });
const homeworks = hwList.json?.data?.items ?? hwList.json?.items ?? [];
const homeworkId = homeworks[0]?.id ?? null;
console.log(`作业：${homeworkId ?? '（没有，照片将不挂作业）'}\n`);

// ── ① 上传字节（走 raw body，不是 JSON）──────────────────────────────
console.log('① 上传字节');
const upRes = await fetch(
  `${BASE}/data/homework/images/upload?studentId=${encodeURIComponent(studentId)}`
    + `&mimeType=image/jpeg&fileName=e2e.jpg`,
  {
    method: 'POST',
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'image/jpeg',
    },
    body: JPEG,
  },
);
const upText = await upRes.text();
let upJson = null;
try {
  upJson = JSON.parse(upText);
} catch {
  /* 略 */
}
const storageKey = upJson?.data?.storageKey ?? upJson?.storageKey;
check('上传返回 200 且带 storageKey', upRes.status === 200 && !!storageKey,
  `HTTP ${upRes.status} ${upText.slice(0, 200)}`);

// ── ② 写照片行：客户端**带一个本地占位 id**，服务端必须无视它 ─────────
console.log('\n② 写照片行（客户端带的 id 是本地占位）');
const PLACEHOLDER = `img_${stamp}_0`;
const saveRes = await json('/data/homework/images', {
  method: 'POST',
  token,
  body: {
    studentId,
    images: [
      {
        id: PLACEHOLDER, // ← 关键：这就是客户端内存里那个占位 id
        homeworkId,
        storageKey,
        fileName: 'e2e.jpg',
        fileSize: JPEG.length,
        mimeType: 'image/jpeg',
        ocrStatus: 'pending',
        ocrText: '',
        batchId: BATCH,
        sortOrder: 0,
      },
    ],
  },
});
const savedRows = saveRes.json?.data?.items ?? saveRes.json?.items ?? [];
const savedRow = savedRows[0];
check('写行返回 200 且回了一行', !!savedRow, `HTTP ${saveRes.status} ${saveRes.text.slice(0, 300)}`);

const serverId = savedRow?.id;
check('服务端**没有**沿用客户端那个占位 id（它自己发 id）',
  !!serverId && serverId !== PLACEHOLDER,
  `server=${serverId} placeholder=${PLACEHOLDER}`);

// ── ③ 用服务端返回的 id 读回字节（这是修好之后客户端会做的事）────────
console.log('\n③ 用服务端返回的 id 读回字节');
const okRes = await fetch(
  `${BASE}/data/homework/images/file?id=${encodeURIComponent(serverId ?? '')}`,
  { headers: { authorization: `Bearer ${token}` } },
);
const okBytes = Buffer.from(await okRes.arrayBuffer());
check('按服务端 id 读 → 200 且字节一致',
  okRes.status === 200 && okBytes.length === JPEG.length,
  `HTTP ${okRes.status} len=${okBytes.length} 期望=${JPEG.length}`);

// ── ④ 对照：按占位 id 读 → 必须 404（真机症状的成因）────────────────
console.log('\n④ 对照：按上传时那个占位 id 读');
const badRes = await fetch(
  `${BASE}/data/homework/images/file?id=${encodeURIComponent(PLACEHOLDER)}`,
  { headers: { authorization: `Bearer ${token}` } },
);
check('按占位 id 读 → 404（这正是「界面一片空白」的成因）',
  badRes.status === 404,
  `HTTP ${badRes.status}（若这里是 200，说明对照失效，③ 的通过便无从判断）`);

// ── ⑤ 复核：重登（重走列表读）拿到的行，id 与写行时返回的一致 ────────
console.log('\n⑤ 复核：重新读列表，行 id 应与 ② 返回的一致');
const { token: token2 } = await login(STUDENT_PHONE);
const listRes = await json(
  `/data/homework/images?homeworkId=${encodeURIComponent(homeworkId ?? '')}`,
  { token: token2 },
);
const listed = listRes.json?.data?.items ?? listRes.json?.items ?? [];
const sameRow = listed.find((r) => r.id === serverId);
check('列表里能找到 id 相同的那一行', !!sameRow,
  `列表 ${listed.length} 行，id 为 ${listed.map((r) => r.id).slice(0, 5).join(',')}`);

// 顺带确认「重登才好」的机制描述没错：列表里的 id 就是服务端 id
// （占位 id 在服务端根本不存在 → 那条「重登就好」的路与这条一致）。
const placeholderInList = listed.some((r) => r.id === PLACEHOLDER);
check('列表里**没有**占位 id（证明占位 id 从未落库）', !placeholderInList);

console.log(`\n结果：${pass} 通过 / ${fail} 失败`);
process.exit(fail === 0 ? 0 : 1);
