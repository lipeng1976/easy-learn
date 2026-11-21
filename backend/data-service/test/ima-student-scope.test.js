import assert from 'node:assert/strict';
import test from 'node:test';

import { encryptCredential } from '../src/ima_repository.js';

/**
 * 「ima 配置主体是学生」的服务端判据（2026-11-08 定稿，设计见
 * `doc/ima-integration-design.md` §2 / 落地清单 §11）。
 *
 * 三条要盯死的行为：
 *   ① 父母共管同一个孩子 → 读到**同一行配置、同一个 kb_id**，不新建库；
 *   ② 切孩子 → 状态跟着切，不许残留上一个孩子的 KB；
 *   ③ 交卷 / 阅读取配置一律按 `studentId`，不许按当前登录家长反推。
 *
 * 另有 11-07 的底线：没有 ima 时仍不报错。本文件用假 client + 假 fetch，
 * 不碰真库、不联网；RLS 策略本身由 `sql/024_ima_coparent_read.sql` 保证，
 * 真库验证另见 `scripts/probe-checkin-e2e.mjs` 一类端到端探针。
 */

const SECRET = 'test-secret-0123456789abcdefghijklmn';

const S1_KB = {
  student_id: 's1',
  kb_id: 'kb_s1',
  kb_name: '伴学-李雨霏-s1',
  owner_user_id: 'parent-1',
};
const S2_KB = {
  student_id: 's2',
  kb_id: 'kb_s2',
  kb_name: '伴学-李小明-s2',
  owner_user_id: 'parent-1',
};

/** 真密文：`syncStudentArchive` 会走解密，假串会直接 decrypt_failed 遮住判据。 */
function activeCred() {
  const enc = encryptCredential({ clientid: 'cid', apikey: 'akey' }, SECRET);
  return {
    clientid_enc: enc.clientidEnc,
    apikey_enc: enc.apikeyEnc,
    status: 'active',
    kb_owner_name: '伴学',
  };
}

/**
 * 按学生口径的假库。
 *  · kbs: studentId → 一行 ima_student_kb；creds: ownerUserId → 一行凭证
 *  · writes 记录所有写 SQL，用来断言「复用时一个字都不写」
 *  · boom 模拟 017/018/024 没迁移
 */
function makeDb({ kbs = {}, creds = {}, boom = false, fallbackKb = null } = {}) {
  const queries = [];
  const writes = [];
  return {
    queries,
    writes,
    async query(sql, params = []) {
      queries.push({ sql, params });
      if (boom) throw Object.assign(new Error('relation "ima_student_kb" does not exist'), { code: '42P01' });
      if (/^insert |^update /i.test(sql.trim())) writes.push({ sql, params });
      if (/from ima_student_kb where student_id/.test(sql)) {
        const kb = kbs[params[0]] ?? null;
        return kb
          ? { rowCount: 1, rows: [{ kb_id: kb.kb_id, kb_name: kb.kb_name, owner_user_id: kb.owner_user_id }] }
          : { rowCount: 0, rows: [] };
      }
      // 旧 reading 实现的「owner 名下第一个 KB」兜底。给它塞一个真库，
      // 才能证伪「没映射时回退到别人库」这条错路。
      if (/from ima_student_kb\s+where owner_user_id/.test(sql)) {
        return fallbackKb
          ? { rowCount: 1, rows: [{ kb_id: fallbackKb }] }
          : { rowCount: 0, rows: [] };
      }
      if (/from ima_credential where owner_user_id/.test(sql)) {
        const c = creds[params[0]] ?? null;
        return c ? { rowCount: 1, rows: [c] } : { rowCount: 0, rows: [] };
      }
      if (/from app_user where id/.test(sql)) {
        return { rowCount: 1, rows: [{ name: params[0] === 's1' ? '李雨霏' : '李小明' }] };
      }
      if (/select parent_id from relationship/.test(sql)) {
        // 父母共管：无排序的 `limit 1` 会取到没配置凭证的 parent-2。
        return { rowCount: 2, rows: [{ parent_id: 'parent-2' }, { parent_id: 'parent-1' }] };
      }
      return { rowCount: 0, rows: [] };
    },
  };
}

/** 所有 ima 响应都回这个「字段齐全」的对象，够 ensureStudentKb 走完。 */
function makeFetch() {
  const calls = [];
  const impl = async (url) => {
    calls.push(String(url));
    return {
      ok: true,
      status: 200,
      text: async () => JSON.stringify({
        code: 0,
        data: {
          info_list: [],
          knowledge_list: [],
          knowledge_base_list: [],
          knowledge_base_id: 'kb_new',
          id: 'kb_new',
          media_id: 'folder_new',
          is_end: true,
          next_cursor: '',
        },
      }),
    };
  };
  return { calls, impl };
}

function parentCtx(userId, visibleStudents, fetchImpl) {
  return { userId, role: 'parent', visibleStudents, fetchImpl };
}

function studentCtx(userId, fetchImpl) {
  return { userId, role: 'student', visibleStudents: [userId], fetchImpl };
}

async function withSecret(fn) {
  const saved = process.env.IMA_CREDENTIAL_SECRET;
  process.env.IMA_CREDENTIAL_SECRET = SECRET;
  try {
    return await fn();
  } finally {
    if (saved == null) delete process.env.IMA_CREDENTIAL_SECRET;
    else process.env.IMA_CREDENTIAL_SECRET = saved;
  }
}

// ===== 1. 父母共管：同一份配置，不冲突 =====

test('母亲选中同一个孩子 → 读到父亲配好的 active 状态和同一个 kb_id', () => withSecret(async () => {
  const { getImaStatus } = await import('../src/routes/ima.js');
  const db = makeDb({ kbs: { s1: S1_KB }, creds: { 'parent-1': activeCred() } });
  const res = await getImaStatus(db, parentCtx('parent-2', ['s1'], null), { studentId: 's1' });
  assert.equal(res.status, 'active');
  assert.equal(res.ownerUserId, 'parent-1');
  assert.equal(res.studentId, 's1');
  assert.equal(res.kbs.length, 1);
  assert.equal(res.kbs[0].kbId, 'kb_s1');
  // 证伪点：旧实现按 ctx.userId 读 parent-2 的凭证 → unconnected，
  // 于是母亲端永远显示「未开启」，还会冒出连接表单。
  const credQuery = db.queries.find((q) => /from ima_credential where owner_user_id/.test(q.sql));
  assert.equal(credQuery.params[0], 'parent-1', '凭证必须按映射行的 owner 读，不是按登录人');
}));

test('另一位家长再点连接 → 复用现有配置：不联网、不写库、不建第二个 KB', () => withSecret(async () => {
  const { connectIma } = await import('../src/routes/ima.js');
  const db = makeDb({ kbs: { s1: S1_KB }, creds: { 'parent-1': activeCred() } });
  const fetch = { calls: [], impl: async () => { throw new Error('复用分支不许联网'); } };
  const res = await connectIma(
    db,
    parentCtx('parent-2', ['s1'], fetch.impl),
    { studentId: 's1', clientid: 'another', apikey: 'another' },
  );
  assert.equal(res.reused, true);
  assert.equal(res.kbs[0].kbId, 'kb_s1');
  assert.deepEqual(fetch.calls, []);
  assert.deepEqual(db.writes, [], '一个字都不写，才谈得上「不冲突」');
  // 证伪点：旧实现遍历 visibleStudents 建库，再用
  // on conflict(student_id) do update 把 owner 覆盖成 parent-2。
}));

test('母亲要断开 → 明确告知该由配置人操作，不是静默失败', () => withSecret(async () => {
  const { disconnectIma } = await import('../src/routes/ima.js');
  const db = makeDb({ kbs: { s1: S1_KB }, creds: { 'parent-1': activeCred() } });
  await assert.rejects(
    () => disconnectIma(db, parentCtx('parent-2', ['s1'], null), { studentId: 's1' }),
    (e) => e.code === 'forbidden',
  );
  assert.deepEqual(db.writes, [], 'RLS 也只允许配置人改那行凭证');
}));

// ===== 2. 切孩子：状态跟着切 =====

test('切到没配过的孩子 → unconnected 且 kbs 为空，不残留上一个孩子的库', () => withSecret(async () => {
  const { getImaStatus } = await import('../src/routes/ima.js');
  const db = makeDb({ kbs: { s1: S1_KB }, creds: { 'parent-1': activeCred() } });
  const res = await getImaStatus(db, parentCtx('parent-1', ['s1', 's2'], null), { studentId: 's2' });
  assert.equal(res.status, 'unconnected');
  assert.deepEqual(res.kbs, []);
  assert.equal(res.studentId, 's2');
  // 证伪点：旧实现 listImaStudentKbs(owner) 把 s1 的库一起列出来，
  // 页面显示「李雨霏的库」却让人以为正在配李小明。
}));

test('两个孩子各自配置 → 各回各的 kb_id', () => withSecret(async () => {
  const { getImaStatus } = await import('../src/routes/ima.js');
  const db = makeDb({ kbs: { s1: S1_KB, s2: S2_KB }, creds: { 'parent-1': activeCred() } });
  const ctx = parentCtx('parent-1', ['s1', 's2'], null);
  const a = await getImaStatus(db, ctx, { studentId: 's1' });
  const b = await getImaStatus(db, ctx, { studentId: 's2' });
  assert.equal(a.kbs[0].kbId, 'kb_s1');
  assert.equal(b.kbs[0].kbId, 'kb_s2');
}));

// ===== 3. 连接只针对请求里那一个学生 =====

test('connect 带 studentId=s2 → 只建 s2 一个库、只写一行映射', () => withSecret(async () => {
  const { connectIma } = await import('../src/routes/ima.js');
  const db = makeDb();
  const fetch = makeFetch();
  const res = await connectIma(
    db,
    parentCtx('parent-1', ['s1', 's2'], fetch.impl),
    { studentId: 's2', clientid: 'cid', apikey: 'akey' },
  );
  assert.equal(res.status, 'active');
  assert.equal(res.studentId, 's2');
  assert.equal(res.kbs.length, 1);
  const created = fetch.calls.filter((u) => u.includes('create_knowledge_base'));
  assert.equal(created.length, 1, '旧实现会给 visibleStudents 里每个孩子各建一个');
  const kbWrites = db.writes.filter((q) => /insert into ima_student_kb/.test(q.sql));
  assert.equal(kbWrites.length, 1);
  assert.equal(kbWrites[0].params[0], 's2');
}));

// ⚠️ 真实 HTTP 里 app.js 的 `narrowToVisible` 会**先**对 query.studentId 抛 403
// （所有 /data/* 路由统一做，实测 2026-11-08）。这条测的是 handler 自己的
// 第二道防线：即使请求绕过了装配层，只读状态也不该因为一个可选功能抛错。
test('越界 studentId：写操作 403，只读 handler 不抛错（可选功能不能红）', () => withSecret(async () => {
  const { connectIma, getImaStatus } = await import('../src/routes/ima.js');
  const db = makeDb({ kbs: { s1: S1_KB }, creds: { 'parent-1': activeCred() } });
  const ctx = parentCtx('parent-1', ['s1'], null);
  await assert.rejects(
    () => connectIma(db, ctx, { studentId: 'other', clientid: 'c', apikey: 'a' }),
    (e) => e.code === 'forbidden',
  );
  const res = await getImaStatus(db, ctx, { studentId: 'other' });
  assert.equal(res.status, 'unconnected');
  assert.deepEqual(res.kbs, []);
}));

// ===== 4. 学生 / 交卷 / 阅读：一律按 studentId 取配置 =====

test('学生端只读：两个家长时也按映射定位配置人，不走 relationship limit 1', () => withSecret(async () => {
  const { getImaStatus } = await import('../src/routes/ima.js');
  const db = makeDb({ kbs: { s1: S1_KB }, creds: { 'parent-1': activeCred() } });
  const res = await getImaStatus(db, studentCtx('s1', null));
  assert.equal(res.status, 'active');
  assert.equal(res.ownerUserId, 'parent-1');
  assert.equal(
    db.queries.some((q) => /select parent_id from relationship/.test(q.sql)),
    false,
    '旧实现的 limit 1 在这里会取到没配凭证的 parent-2',
  );
}));

test('交卷推送：母亲身份提交，也按 quiz.student_id 找到父亲的配置', () => withSecret(async () => {
  const { syncStudentArchive } = await import('../src/routes/ima.js');
  const db = makeDb({ kbs: { s1: S1_KB }, creds: { 'parent-1': activeCred() } });
  // ima 网络故障，但只要「配置解析对了」就该走到 ima_error，而不是 no_owner。
  const fetchImpl = async () => { throw new Error('ima down'); };
  const res = await syncStudentArchive(db, parentCtx('parent-2', ['s1'], fetchImpl), 's1');
  assert.notEqual(res.reason, 'no_owner', '旧实现按 ctx.userId 读 parent-2 的凭证 → 静默不推');
  assert.equal(res.reason, 'ima_error');
  const credQuery = db.queries.find((q) => /from ima_credential where owner_user_id/.test(q.sql));
  assert.equal(credQuery.params[0], 'parent-1');
}));

test('阅读书库：孩子没有自己的 KB 时绝不回退到 owner 名下第一个库', () => withSecret(async () => {
  const { listAvailableBooks } = await import('../src/routes/reading.js');
  const db = makeDb({
    kbs: { s1: S1_KB },
    creds: { 'parent-1': activeCred() },
    fallbackKb: 'kb_s1', // 旧兜底能查到 → 用错库的症状
  });
  const res = await listAvailableBooks(
    db,
    parentCtx('parent-1', ['s1', 's2'], async () => { throw new Error('不该联网'); }),
    { studentId: 's2' },
  );
  assert.equal(res.connected, false);
  assert.deepEqual(res.books, []);
  // 证伪点：旧实现用 `order by created_at limit 1` 拿到 kb_s1 去查书，
  // 家长给老二传的书会出现在老大的库里。
}));

// ===== 5. 11-07 底线：没有 ima 依旧不报错 =====

test('表没迁移 + 切孩子 + 越界 → 状态查询恒 2xx 且不抛', () => withSecret(async () => {
  const { getImaStatus } = await import('../src/routes/ima.js');
  const db = makeDb({ boom: true });
  const res = await getImaStatus(db, parentCtx('parent-1', ['s1', 's2'], null), { studentId: 's2' });
  assert.equal(res.status, 'unconnected');
  assert.deepEqual(res.kbs, []);
  assert.equal(res.available, true);
}));

test('整个部署没开通 ima → 不碰库就回 unconnected + available:false', async () => {
  const saved = process.env.IMA_CREDENTIAL_SECRET;
  delete process.env.IMA_CREDENTIAL_SECRET;
  try {
    const { getImaStatus } = await import('../src/routes/ima.js');
    const db = makeDb();
    const res = await getImaStatus(db, parentCtx('parent-1', ['s1'], null), { studentId: 's1' });
    assert.equal(res.status, 'unconnected');
    assert.equal(res.available, false);
    assert.deepEqual(db.queries, [], '连库都不该碰');
  } finally {
    if (saved != null) process.env.IMA_CREDENTIAL_SECRET = saved;
  }
});
