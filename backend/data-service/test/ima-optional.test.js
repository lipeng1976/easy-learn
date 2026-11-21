import test from 'node:test';
import assert from 'node:assert/strict';
import { encryptCredential } from '../src/ima_repository.js';

/**
 * 「不是所有人都有 ima」的服务端判据（2026-11-07 定）。
 *
 * 硬规矩：ima 是可选能力。没开通 / 没配密钥 / 表没迁移 / 凭证失效 /
 * 网络不通 —— 功能可以不出现，但**绝不能报错**：
 *   · 状态查询、书库列表这些「页面加载自动打」的请求必须恒 2xx；
 *   · 交卷后的可选同步必须永不抛错（否则判完分的交卷整体 500）；
 *   · 只有用户主动点「连接 / 导入」才允许回一句温和的 4xx。
 *
 * 这里全部用假 client / 假 fetch，不碰真库也不联网。
 */

const SECRET = 'test-secret-0123456789abcdefghijklmn';

function pgMissingTable() {
  return Object.assign(new Error('relation "ima_credential" does not exist'), { code: '42P01' });
}

/**
 * 假库。
 *  · cred = null / 'active' / 'expired' 决定有没有凭证行；
 *  · kbId 决定有没有学生 KB 映射；
 *  · boom = true 模拟 017/018 迁移没跑（所有查询抛 42P01）。
 */
function makeClient({ cred = null, kbId = '', boom = false, encrypted = false } = {}) {
  return {
    async query(sql) {
      if (boom) throw pgMissingTable();
      if (/from ima_credential where owner_user_id/.test(sql)) {
        if (!cred) return { rowCount: 0, rows: [] };
        const enc = encrypted
          ? encryptCredential({ clientid: 'cid', apikey: 'akey' }, SECRET)
          : { clientidEnc: 'x', apikeyEnc: 'y' };
        return {
          rowCount: 1,
          rows: [{
            clientid_enc: enc.clientidEnc,
            apikey_enc: enc.apikeyEnc,
            status: cred,
            kb_owner_name: 'kb',
          }],
        };
      }
      if (/from ima_student_kb where student_id/.test(sql)) {
        return kbId
          ? { rowCount: 1, rows: [{ kb_id: kbId, owner_user_id: 'parent-1', kb_name: '伴学' }] }
          : { rowCount: 0, rows: [] };
      }
      if (/from ima_student_kb\s+where owner_user_id/.test(sql)) {
        return { rowCount: 0, rows: [] };
      }
      if (/from reading_book/.test(sql)) return { rowCount: 0, rows: [] };
      return { rowCount: 0, rows: [] };
    },
  };
}

function parentCtx(fetchImpl) {
  return {
    userId: 'parent-1',
    role: 'parent',
    visibleStudents: ['s1'],
    fetchImpl: fetchImpl ?? (async () => {
      throw new Error('本组用例不该打到 ima 网络');
    }),
  };
}

/** 每个用例独立管 env，结束时还原，避免串味。 */
async function withSecret(value, fn) {
  const saved = process.env.IMA_CREDENTIAL_SECRET;
  if (value == null) delete process.env.IMA_CREDENTIAL_SECRET;
  else process.env.IMA_CREDENTIAL_SECRET = value;
  try {
    await fn();
  } finally {
    if (saved == null) delete process.env.IMA_CREDENTIAL_SECRET;
    else process.env.IMA_CREDENTIAL_SECRET = saved;
  }
}

// ===== 1. 状态查询：页面加载就打，必须恒 2xx =====

test('没配 IMA_CREDENTIAL_SECRET → status 恒 2xx 且 available:false', async () => {
  await withSecret(null, async () => {
    const { getImaStatus } = await import('../src/routes/ima.js');
    const res = await getImaStatus(makeClient(), parentCtx());
    assert.equal(res.status, 'unconnected');
    assert.deepEqual(res.kbs, []);
    assert.equal(res.available, false, '客户端据此把 ima 入口整体藏起来');
  });
});

test('017/018 表没建 → 状态查询不抛错，按未开通返回', async () => {
  await withSecret(SECRET, async () => {
    const { getImaStatus } = await import('../src/routes/ima.js');
    const res = await getImaStatus(makeClient({ boom: true }), parentCtx());
    assert.equal(res.status, 'unconnected');
    assert.deepEqual(res.kbs, []);
  });
});

test('配了密钥且已连接 → available:true，功能照常出现', async () => {
  await withSecret(SECRET, async () => {
    const { getImaStatus } = await import('../src/routes/ima.js');
    // ⭐ 11-08：状态按学生算，光有凭证行不够 —— 必须该学生有 KB 映射。
    const res = await getImaStatus(
      makeClient({ cred: 'active', kbId: 'kb1' }),
      parentCtx(),
      { studentId: 's1' },
    );
    assert.equal(res.status, 'active');
    assert.equal(res.available, true, '反面：不能把已开通的家庭也一起降级');
  });
});

// ===== 2. 交卷后的可选同步：永不抛错 =====

test('交卷时 ima 表缺失 → syncStudentArchive 不抛，返回 synced:false', async () => {
  await withSecret(SECRET, async () => {
    const { syncStudentArchive } = await import('../src/routes/ima.js');
    const res = await syncStudentArchive(makeClient({ boom: true }), parentCtx(), 's1');
    assert.equal(res.synced, false);
    assert.equal(res.reason, 'ima_error');
  });
  // 证伪点：改回「只兜住 ima 网络调用」后，42P01 会从这里冒出去，
  // POST /data/checkin/submit 整体 500 —— 分数已经判出来了却显示提交失败。
});

test('交卷时根本没连 ima → 不联网、不抛错', async () => {
  await withSecret(null, async () => {
    const { syncStudentArchive } = await import('../src/routes/ima.js');
    const res = await syncStudentArchive(makeClient(), parentCtx(), 's1');
    assert.equal(res.synced, false);
    // 没有该学生的 KB 映射时按 `no_owner` 返回，同样是「没推、没报错」。
    assert.match(String(res.reason), /ima_status=unconnected|no_secret|no_owner/);
  });
});

// ===== 3. 书库列表：没开通不是错误 =====

test('没连 ima → books/available 回 2xx + connected:false，不抛 400', async () => {
  await withSecret(SECRET, async () => {
    const { listAvailableBooks } = await import('../src/routes/reading.js');
    const res = await listAvailableBooks(makeClient(), parentCtx(), { studentId: 's1' });
    assert.equal(res.connected, false);
    assert.deepEqual(res.books, []);
    assert.equal(res.reason, 'ima_unavailable');
  });
});

test('连过 ima 但服务端没配密钥 → 仍是 connected:false，不是 500', async () => {
  await withSecret(null, async () => {
    const { listAvailableBooks } = await import('../src/routes/reading.js');
    const res = await listAvailableBooks(
      makeClient({ cred: 'active', kbId: 'kb1' }),
      parentCtx(),
      { studentId: 's1' },
    );
    assert.equal(res.connected, false, '旧实现在这里抛 server_config_missing(500)');
    assert.deepEqual(res.books, []);
  });
});

test('ima 表缺失 → 书库列表也静默降级，不把整页变成 500', async () => {
  await withSecret(SECRET, async () => {
    const { listAvailableBooks } = await import('../src/routes/reading.js');
    const res = await listAvailableBooks(makeClient({ boom: true }), parentCtx(), { studentId: 's1' });
    assert.equal(res.connected, false);
    assert.deepEqual(res.books, []);
  });
});

test('反面：已开通但 ima 临时抖动 → connected:true 保留入口给家长刷新', async () => {
  await withSecret(SECRET, async () => {
    const { listAvailableBooks } = await import('../src/routes/reading.js');
    const ctx = parentCtx(async () => { throw new Error('ima 503'); });
    const res = await listAvailableBooks(
      makeClient({ cred: 'active', kbId: 'kb1', encrypted: true }),
      ctx,
      { studentId: 's1' },
    );
    assert.equal(res.connected, true, '临时故障不能伪装成「没开通」，否则刷新按钮也没了');
    assert.deepEqual(res.books, []);
    assert.equal(res.reason, 'ima_read_error');
  });
});

// ===== 4. 导入：主动动作才允许反馈，且不可以是 500 =====

test('连过 ima 但没配密钥时点导入 → 温和的 bad_request，不是 500', async () => {
  // 证伪点：旧实现在这里抛 ApiError('server_config_missing', {status:500})，
  // 本判据的 e.code 断言会红。可选功能不可用不是服务端故障。
  await withSecret(null, async () => {
    const { importBook } = await import('../src/routes/reading.js');
    await assert.rejects(
      () => importBook(
        makeClient({ cred: 'active', kbId: 'kb1' }),
        parentCtx(),
        { studentId: 's1', mediaId: 'm1' },
      ),
      (e) => e.code === 'bad_request',
    );
  });
});
