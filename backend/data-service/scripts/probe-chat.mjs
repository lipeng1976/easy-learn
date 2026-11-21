#!/usr/bin/env node
/**
 * 聊天链路的**真 HTTP 走查**：对着已经跑起来的演示栈，把「学生发 → 家长在
 * 另一个会话读到」这条链连同四条反面判据全部打一遍。
 *
 *     node scripts/probe-chat.mjs                    # 打 127.0.0.1:8788
 *     node scripts/probe-chat.mjs --base http://192.168.3.80:8788
 *
 * ## 为什么不并进 `npm test`
 *
 * 契约测试（`test/chat.test.js`）打在**函数**上：它验的是路由自己的逻辑，
 * 不需要有人把服务起起来。而这个脚本打的是**网络边界**：登录取票 → 带票请求 →
 * 解析响应。这两层坏掉的方式完全不同 —— 实测踩过一次「函数全绿、界面上就是发不出去」，
 * 根因在客户端那一侧（路由压根没注册 / 客户端把响应行丢了）。
 * 所以两者都留着：一个验逻辑，一个验「真的连得上、真的存得进、别人真的看得见」。
 *
 * ## 为什么每条反面都要有
 *
 * 只测「学生发了、家长看到了」，一条**永远 200** 的假实现也能全过。
 * 所以每条正面都必须配一条反面：不带票 → 401、非成员 → 404、
 * 不存在的 id → **与前面同一个 404**（否则可以拿它探测 id 是否存在）。
 */
import { LOCAL_PG } from '../src/pg-local.js';
import { DEMO } from './seed-demo.mjs';

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] !== undefined ? args[i + 1] : fallback;
};
const BASE = opt('base', process.env.DATA_BASE_URL ?? `http://127.0.0.1:${process.env.PORT ?? 8788}`);

let pass = 0;
let fail = 0;
const ok = (cond, label, extra = '') => {
  if (cond) { pass += 1; process.stdout.write(`  ✓ ${label}${extra ? `  ${extra}` : ''}\n`); }
  else { fail += 1; process.stdout.write(`  ✗ ${label}${extra ? `  ${extra}` : ''}\n`); }
};

async function call(method, pathname, { token, body, query } = {}) {
  const url = new URL(pathname, BASE);
  for (const [k, v] of Object.entries(query ?? {})) url.searchParams.set(k, String(v));
  const res = await fetch(url, {
    method,
    headers: {
      ...(body === undefined ? {} : { 'content-type': 'application/json' }),
      ...(token === undefined ? {} : { authorization: `Bearer ${token}` }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  return { status: res.status, json, data: json.data ?? {}, error: json.error };
}

const login = async (phone) => {
  const r = await call('POST', '/auth/login', { body: { phone, password: DEMO.password } });
  if (!r.data.token) throw new Error(`登录失败 ${phone}：${r.error?.code ?? r.status}`);
  return r.data.token;
};

process.stdout.write(`聊天链路走查 ← ${BASE}\n\n`);

const student = await login(DEMO.student.phone);
const student2 = await login(DEMO.student2.phone);
const parent = await login(DEMO.parent.phone);
const relRes = await call('GET', '/data/relationship', { token: student });
const rel = (relRes.data.items ?? [])[0];
if (!rel) throw new Error('学生名下没有任何结伴 —— 先跑 `npm run seed:demo`');
if (rel.status !== 'active') throw new Error(`结伴状态是 ${rel.status}，不是 active —— 聊天不该放行`);
const RID = rel.id;
process.stdout.write(`会话 ${RID}（${rel.studentName} ↔ ${rel.parentName}，status=${rel.status}）\n\n`);

process.stdout.write('① 正面链路\n');
const content = `走查 ${new Date().toISOString()}`;
const sent = await call('POST', '/data/chat/messages', {
  token: student,
  body: { relationshipId: RID, content },
});
ok(sent.status === 200 && sent.data.message, '学生发消息返回 200 且带消息行', `status=${sent.status}`);
const row = sent.data.message ?? {};
ok(typeof row.id === 'string' && row.id.length > 0, '返回的行有服务端 id', `id=${row.id}`);
ok(row.createdAt !== undefined && row.createdAt !== null, '返回的行有服务端 createdAt', `createdAt=${row.createdAt}`);
ok(row.senderId === rel.studentId, 'senderId 是发消息的人', `senderId=${row.senderId}`);
ok(row.receiverId === rel.parentId, 'receiverId 由服务端从结伴推导', `receiverId=${row.receiverId}`);

// 关键判据：**换一个账号、换一个会话**再读 —— 同一进程里读回自己写的不算数。
const parentRead = await call('GET', '/data/chat/messages', { token: parent, query: { relationshipId: RID } });
const items = parentRead.data.items ?? [];
ok(items.length > 0, '家长在**另一个会话**里读到了消息', `条数=${items.length}`);
ok(items.some((m) => m.id === row.id && m.content === content), '读到的正是刚发的那一条（按 id + 正文核对）');
ok(items.every((m) => m.relationshipId === RID), '返回的每一条都属于这个会话（没有串号）');

// 排序：同一毫秒连发两条也不能乱序（单键排序会让它随机重排）。
await call('POST', '/data/chat/messages', { token: student, body: { relationshipId: RID, content: '排序探针 A' } });
await call('POST', '/data/chat/messages', { token: student, body: { relationshipId: RID, content: '排序探针 B' } });
const sorted = (await call('GET', '/data/chat/messages', { token: parent, query: { relationshipId: RID } })).data.items ?? [];
const idxA = sorted.findIndex((m) => m.content === '排序探针 A');
const idxB = sorted.findIndex((m) => m.content === '排序探针 B');
ok(idxA >= 0 && idxB >= 0 && idxA < idxB, '连发两条保持写入顺序', `A@${idxA} B@${idxB}`);

process.stdout.write('\n② 反面判据（少一条，「永远 200」的假实现也能全绿）\n');
const noToken = await call('POST', '/data/chat/messages', { body: { relationshipId: RID, content: 'x' } });
ok(noToken.status === 401, '不带票 → 401', `status=${noToken.status}`);

const stranger = await call('POST', '/data/chat/messages', {
  token: student2, body: { relationshipId: RID, content: '我不该发得出去' },
});
ok(stranger.status === 404 && stranger.error?.code === 'not_found', '非成员 → 404 not_found', `status=${stranger.status} code=${stranger.error?.code}`);

const ghost = await call('POST', '/data/chat/messages', {
  token: student, body: { relationshipId: '00000000-0000-4000-8000-000000000000', content: 'x' },
});
ok(
  ghost.status === stranger.status && ghost.error?.code === stranger.error?.code && ghost.error?.message === stranger.error?.message,
  '不存在的 id 与「非成员」返回**逐字相同**的 404（id 不可探测）',
  `status=${ghost.status}`,
);

const forge = await call('POST', '/data/chat/messages', {
  token: student,
  body: { relationshipId: RID, content: '塞了假 receiverId', receiverId: '00000000-0000-4000-8000-000000000000' },
});
ok(forge.data.message?.receiverId === rel.parentId, '客户端自塞的 receiverId 被忽略（不给别人发件）', `receiverId=${forge.data.message?.receiverId}`);

const empty = await call('POST', '/data/chat/messages', { token: student, body: { relationshipId: RID, content: '   ' } });
ok(empty.status === 400 && empty.error?.code === 'bad_request', '空内容 → 400 bad_request', `code=${empty.error?.code}`);

const tooLong = await call('POST', '/data/chat/messages', { token: student, body: { relationshipId: RID, content: '啊'.repeat(2001) } });
ok(tooLong.status === 400 && tooLong.error?.code === 'bad_request', '超长（>2000 字）→ 400 bad_request', `code=${tooLong.error?.code}`);

// 反向的可见性判据：把别人会话的 id 拿给无关学生读，也必须 404。
const strangerRead = await call('GET', '/data/chat/messages', { token: student2, query: { relationshipId: RID } });
ok(strangerRead.status === 404, '非成员**读**会话也是 404（不是空列表）', `status=${strangerRead.status}`);

process.stdout.write(`\n${fail === 0 ? '✓ 全部通过' : '✗ 有失败项'}：${pass} 通过 / ${fail} 失败\n`);
process.stdout.write(`（PG ${LOCAL_PG.port} · 数据服务 ${BASE}）\n`);
process.exit(fail === 0 ? 0 : 1);
