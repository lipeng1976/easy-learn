import test from 'node:test';
import assert from 'node:assert/strict';
import { encryptSecret, decryptSecret } from '../src/crypto.js';
import {
  encryptCredential,
  decryptCredential,
} from '../src/ima_repository.js';

// ===== 1. crypto.js 加解密往返 =====

test('encryptSecret/decryptSecret 往返还原明文', () => {
  const key = 'a-32-byte-secret-string-for-testing!!';
  const plain = 'ima-apikey-SECRET-123';
  const payload = encryptSecret(plain, key);
  assert.notEqual(payload, plain);
  assert.equal(decryptSecret(payload, key), plain);
});

test('用错密钥解密抛错（GCM 认证失败）', () => {
  const payload = encryptSecret('topsecret', 'key-one-0123456789abcdefghijklmno');
  assert.throws(() => decryptSecret(payload, 'key-two-0123456789abcdefghijklmno'));
});

test('损坏的密文格式抛错', () => {
  assert.throws(() => decryptSecret('not-a-valid-payload', 'any-key-0123456789abcdefghijk'));
});

// ===== 2. ima_repository 凭证加解密包装 =====

test('encryptCredential/decryptCredential 往返', () => {
  const secret = 'repo-secret-0123456789abcdefghijklmnop';
  const enc = encryptCredential({ clientid: 'cid-1', apikey: 'akey-1' }, secret);
  assert.notEqual(enc.clientidEnc, 'cid-1');
  const dec = decryptCredential(enc, secret);
  assert.deepEqual(dec, { clientId: 'cid-1', apiKey: 'akey-1' });
});

// ===== 3. connectIma 行为（fake client + fake fetch，不碰真网络/真库）=====

function makeFakeClient({ nameRows = {}, mistakeRows = [] } = {}) {
  const queries = [];
  // 极简的「库」：只记住写进去的凭证行，好让随后的 backfill（syncStudentArchive）
  // 能像真库那样读回 active 状态。不记的话 backfill 会以为没连过而静默跳过，
  // 于是「连接成功后到底推没推」这件事在测试里根本看不见。
  const state = { credential: null };
  return {
    queries,
    query(sql, params = []) {
      queries.push({ sql, params });
      if (/from app_user where id/.test(sql)) {
        return Promise.resolve({ rowCount: 1, rows: [{ name: nameRows[params[0]] ?? '学生' }] });
      }
      if (/from review_mistake/.test(sql)) {
        return Promise.resolve({ rowCount: mistakeRows.length, rows: mistakeRows });
      }
      if (/insert into ima_credential/.test(sql)) {
        state.credential = {
          clientid_enc: params[1],
          apikey_enc: params[2],
          status: params[3],
          kb_owner_name: params[4] ?? null,
        };
        return Promise.resolve({ rowCount: 1, rows: [] });
      }
      if (/select clientid_enc/.test(sql)) {
        return Promise.resolve(
          state.credential
            ? { rowCount: 1, rows: [state.credential] }
            : { rowCount: 0, rows: [] },
        );
      }
      // 打卡档案：这条链路里没有打卡数据，回空即可（有专门的打卡测试管它）。
      if (/from checkin_quiz/.test(sql)) {
        return Promise.resolve({ rowCount: 0, rows: [] });
      }
      // ⭐ 11-08：connectIma 先按 studentId 查「这个学生有没有已配好的 KB」。
      // 这个假库是「全新连接」场景，没有映射 → 返回 0 行，不能 rowCount:1 + rows:[]
      // （那样 getImaStudentKb 会拿 rows[0].kb_id 直接炸）。
      if (/from ima_student_kb where student_id/.test(sql)) {
        return Promise.resolve({ rowCount: 0, rows: [] });
      }
      // ima_student_kb 的 upsert：记录但返回 ok
      return Promise.resolve({ rowCount: 1, rows: [] });
    },
  };
}

function makeFetch(map = {}) {
  // map: path 子串 -> 响应对象
  return async (url, opts) => {
    const path = String(url).replace('https://ima.qq.com', '');
    const matched = Object.keys(map).find((k) => path.includes(k));
    const res = matched ? map[matched] : { ok: true, status: 200, text: async () => '{}' };
    return {
      ok: res.ok,
      status: res.status,
      text: async () => (typeof res.text === 'function' ? res.text() : res.text ?? '{}'),
    };
  };
}

const OK_FETCH = makeFetch({
  search_knowledge_base: { ok: true, status: 200, text: async () => JSON.stringify({ data: { info_list: [] } }) },
  create_knowledge_base: { ok: true, status: 200, text: async () => JSON.stringify({ data: { id: 'kb_test' } }) },
  get_knowledge_list: { ok: true, status: 200, text: async () => JSON.stringify({ data: { info_list: [] } }) },
  create_folder: { ok: true, status: 200, text: async () => JSON.stringify({ data: { media_id: 'folder_x' } }) },
});

test('无 IMA_CREDENTIAL_SECRET 时 connectIma 抛 server_config_missing', async () => {
  const saved = process.env.IMA_CREDENTIAL_SECRET;
  delete process.env.IMA_CREDENTIAL_SECRET;
  const { connectIma } = await import('../src/routes/ima.js');
  const client = makeFakeClient();
  const ctx = {
    userId: 'parent-1',
    role: 'parent',
    visibleStudents: ['s1'],
    fetchImpl: OK_FETCH,
  };
  await assert.rejects(
    () => connectIma(client, ctx, { clientid: 'cid', apikey: 'akey' }),
    (e) => e.code === 'server_config_missing',
  );
  process.env.IMA_CREDENTIAL_SECRET = saved;
});

test('connectIma 成功：写 active 凭证 + KB 映射，错题空则不推送', async () => {
  process.env.IMA_CREDENTIAL_SECRET = 'test-secret-0123456789abcdefghijklmn';
  const { connectIma } = await import('../src/routes/ima.js');
  const client = makeFakeClient({ nameRows: { s1: '李雨霏' } });
  const ctx = {
    userId: 'parent-1',
    role: 'parent',
    visibleStudents: ['s1'],
    fetchImpl: OK_FETCH,
  };
  const res = await connectIma(client, ctx, { clientid: 'cid', apikey: 'akey' });
  assert.equal(res.status, 'active');
  assert.equal(res.kbs.length, 1);
  assert.equal(res.kbs[0].kbId, 'kb_test');

  const upsertCred = client.queries.find((q) => /insert into ima_credential/.test(q.sql));
  assert.ok(upsertCred, '应当写入 ima_credential');
  // 落库的是密文，不是明文
  assert.notEqual(upsertCred.params[1], 'cid');
  const upsertKb = client.queries.find((q) => /insert into ima_student_kb/.test(q.sql));
  assert.ok(upsertKb, '应当写入 ima_student_kb');
  delete process.env.IMA_CREDENTIAL_SECRET;
});

test('connectIma 密钥错误（ima 401）：抛 imaAuthFailed 且不写 active 凭证', async () => {
  process.env.IMA_CREDENTIAL_SECRET = 'test-secret-0123456789abcdefghijklmn';
  const { connectIma } = await import('../src/routes/ima.js');
  const badFetch = makeFetch({
    search_knowledge_base: { ok: true, status: 200, text: async () => JSON.stringify({ data: { info_list: [] } }) },
    // create_knowledge_base 返回 401 → ensureStudentKb 抛 imaAuthFailed
    create_knowledge_base: { ok: false, status: 401, text: async () => 'unauthorized' },
  });
  const client = makeFakeClient({ nameRows: { s1: '李雨霏' } });
  const ctx = {
    userId: 'parent-1',
    role: 'parent',
    visibleStudents: ['s1'],
    fetchImpl: badFetch,
  };
  await assert.rejects(
    () => connectIma(client, ctx, { clientid: 'wrong', apikey: 'wrong' }),
    (e) => e.code === 'ima_auth_failed',
  );
  // 关键：绝不能留下 half-baked 的 active 凭证
  const wroteCred = client.queries.some((q) => /insert into ima_credential/.test(q.sql));
  assert.equal(wroteCred, false, '密钥错误时不应写入任何 ima_credential 行');
  delete process.env.IMA_CREDENTIAL_SECRET;
});

// ===== 4. 角色守卫：只有家长能连接 / 断开 =====

test('connectIma 学生调用 → 抛 forbidden', async () => {
  process.env.IMA_CREDENTIAL_SECRET = 'test-secret-0123456789abcdefghijklmn';
  const { connectIma } = await import('../src/routes/ima.js');
  const client = makeFakeClient();
  const ctx = {
    userId: 's1',
    role: 'student',
    visibleStudents: ['s1'],
    fetchImpl: OK_FETCH,
  };
  await assert.rejects(
    () => connectIma(client, ctx, { clientid: 'c', apikey: 'a' }),
    (e) => e.code === 'forbidden',
  );
  delete process.env.IMA_CREDENTIAL_SECRET;
});

test('disconnectIma 学生调用 → 抛 forbidden', async () => {
  const { disconnectIma } = await import('../src/routes/ima.js');
  const client = makeFakeClient();
  const ctx = {
    userId: 's1',
    role: 'student',
    visibleStudents: ['s1'],
  };
  await assert.rejects(() => disconnectIma(client, ctx), (e) => e.code === 'forbidden');
});

// ===== 5. getImaStatus：家长 / 学生（家庭对端）两种视角 =====

/**
 * ⭐ 11-08：状态假库按**学生**造数据，不再按 owner 列 KB 列表。
 * `studentKb` 是 `ima_student_kb` 里 student_id 那一行（含 owner_user_id），
 * `credStatus` 是那一行 owner 的凭证状态。
 */
function makeStatusClient({ studentKb = null, credStatus = null } = {}) {
  return {
    query(sql) {
      if (/from ima_student_kb where student_id/.test(sql)) {
        return Promise.resolve(
          studentKb ? { rowCount: 1, rows: [studentKb] } : { rowCount: 0, rows: [] },
        );
      }
      if (/from ima_credential where owner_user_id/.test(sql)) {
        return Promise.resolve({
          rowCount: credStatus ? 1 : 0,
          rows: credStatus
            ? [{ clientid_enc: 'x', apikey_enc: 'y', status: credStatus, kb_owner_name: 'kb' }]
            : [],
        });
      }
      return Promise.resolve({ rowCount: 0, rows: [] });
    },
  };
}

const S1_KB = {
  student_id: 's1',
  kb_id: 'kb1',
  kb_name: '伴学-李雨霏-s1',
  owner_user_id: 'parent-1',
};

/**
 * 状态查询在「服务端没配 IMA_CREDENTIAL_SECRET」时直接按未开通返回（不碰库），
 * 所以这几条测的是**已开通部署**下按学生读配置的行为，必须把 env 造对。
 * 原来的用例没设 env 也能绿，是因为旧实现只把 available 当返回字段、没短路。
 */
async function withSecretOn(fn) {
  const saved = process.env.IMA_CREDENTIAL_SECRET;
  process.env.IMA_CREDENTIAL_SECRET = 'test-secret-0123456789abcdefghijklmn';
  try {
    return await fn();
  } finally {
    if (saved == null) delete process.env.IMA_CREDENTIAL_SECRET;
    else process.env.IMA_CREDENTIAL_SECRET = saved;
  }
}

test('getImaStatus 家长视角：按当前伴学学生读同一行映射', () => withSecretOn(async () => {
  const { getImaStatus } = await import('../src/routes/ima.js');
  const client = makeStatusClient({ studentKb: S1_KB, credStatus: 'active' });
  const ctx = { userId: 'parent-1', role: 'parent', visibleStudents: ['s1'] };
  const res = await getImaStatus(client, ctx, { studentId: 's1' });
  assert.equal(res.status, 'active');
  assert.equal(res.ownerUserId, 'parent-1');
  assert.equal(res.studentId, 's1');
  assert.equal(res.kbs.length, 1);
  assert.equal(res.kbs[0].kbId, 'kb1');
}));

test('getImaStatus 学生视角：只读自己的配置，不再靠 relationship limit 1 猜家长', () => withSecretOn(async () => {
  const { getImaStatus } = await import('../src/routes/ima.js');
  const client = makeStatusClient({ studentKb: S1_KB, credStatus: 'active' });
  const ctx = { userId: 's1', role: 'student', visibleStudents: ['s1'] };
  const res = await getImaStatus(client, ctx);
  assert.equal(res.status, 'active');
  assert.equal(res.ownerUserId, 'parent-1', '配置人是谁由映射行决定，与学生有几个家长无关');
  assert.equal(res.kbs.length, 1);
}));

test('getImaStatus 学生视角：没有 KB 映射 → 视为未连接', () => withSecretOn(async () => {
  const { getImaStatus } = await import('../src/routes/ima.js');
  const client = makeStatusClient({ studentKb: null });
  const ctx = { userId: 's1', role: 'student', visibleStudents: ['s1'] };
  const res = await getImaStatus(client, ctx);
  assert.equal(res.status, 'unconnected');
  assert.equal(res.ownerUserId, null);
}));

test('getImaStatus 映射在但凭证行不在 → unconnected，但 owner 仍可解析', () => withSecretOn(async () => {
  const { getImaStatus } = await import('../src/routes/ima.js');
  const client = makeStatusClient({ studentKb: S1_KB, credStatus: null });
  const ctx = { userId: 's1', role: 'student', visibleStudents: ['s1'] };
  const res = await getImaStatus(client, ctx);
  assert.equal(res.status, 'unconnected');
  assert.equal(res.ownerUserId, 'parent-1');
}));
