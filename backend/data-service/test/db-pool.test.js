import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  isTransientConnectError,
  withAuthConnection,
  withRequestContext,
} from '../src/db.js';
import { UserRoles } from '../../shared/token.js';

/**
 * 连接池抖动：**瞬时故障要等到等不动，永久故障立刻报**。
 *
 * 这个文件不连数据库 —— 它测的是 `db.js` 在「借连接被拒」这个瞬间的行为。
 * 那是 2026-09-20 本机演示栈上真实翻过的一页，而且真相比一开始猜的更重：
 * PG 的一个后端崩掉 → 其余后端被连带终止 → postmaster 进**崩溃恢复**。
 * 那几秒里每一次借连接都被拒（`in recovery mode`），而它自己会好。
 * 固定「重试 2 次、间隔 150ms」等不到恢复完，于是家长端登录被拒 ——
 * **一次数据库崩溃的代价被记在了登录功能头上**。
 *
 * 四件事分开守：
 *   ① 瞬时抖动要能被吃掉；
 *   ② 吃掉抖动**不能没有痕迹**（静默重试会把「库真的在抖」藏起来）；
 *   ③ 永久的失败**不许重试**（口令错等下去永远不会好，
 *      重试只把它表现成「服务很慢」）；
 *   ④ 重试只发生在**借连接**这一步 —— 一旦连接到手，
 *      事务里的语句与异常必须原样走完。
 *
 * 跑法：`npm test`（不需要 PG；`db-pool.test.js` 排在最前面）。
 */

/** 一个只记录 SQL 的假客户端。 */
function fakeClient() {
  const calls = [];
  return {
    calls,
    async query(sql) {
      calls.push(sql);
      return { rows: [], rowCount: 0 };
    },
    release() {
      calls.push('release');
    },
  };
}

/**
 * 前 [failTimes] 次 connect 抛 [error]，之后返回 [client]。
 * [error] 传函数时可以按次数换（比如「先恢复中、后连上」）。
 */
function flakyPool({ failTimes = 0, error, client = fakeClient() } = {}) {
  const state = { connects: 0 };
  return {
    state,
    client,
    async connect() {
      state.connects += 1;
      if (state.connects <= failTimes) {
        throw typeof error === 'function' ? error(state.connects) : error;
      }
      return client;
    },
  };
}

const resetErr = () => {
  const e = new Error('Connection terminated unexpectedly');
  e.code = 'ECONNRESET';
  return e;
};

/** 收集 console.warn，用完还原（全局状态，串行跑）。 */
async function captureWarn(fn) {
  const lines = [];
  const original = console.warn;
  console.warn = (...args) => lines.push(args.join(' '));
  try {
    await fn();
  } finally {
    console.warn = original;
  }
  return lines;
}

/** 临时改重试预算。它是**调用时**读的 env —— 所以能在用例里改。 */
async function withBudget(ms, fn) {
  const key = 'PG_CONNECT_RETRY_BUDGET_MS';
  const prev = process.env[key];
  process.env[key] = String(ms);
  try {
    return await fn();
  } finally {
    if (prev === undefined) delete process.env[key];
    else process.env[key] = prev;
  }
}

const RETRY_HINT = /借连接失败/;

// ===== 分类：哪些值得等 =====

test('瞬时故障的判据：错误码与实测文案都要认', () => {
  const yes = [
    (() => { const e = new Error('boom'); e.code = '57P03'; return e; })(), // cannot_connect_now
    (() => { const e = new Error('boom'); e.code = 'ECONNREFUSED'; return e; })(),
    (() => { const e = new Error('boom'); e.code = 'EAI_AGAIN'; return e; })(), // 临时 DNS
    new Error('the database system is in recovery mode'),
    new Error('Connection terminated due to connection timeout'),
    new Error('could not open file "base/16384/2601": Permission denied'),
  ];
  for (const e of yes) {
    assert.equal(isTransientConnectError(e), true, `${e.code ?? ''} ${e.message} 应当是可等的`);
  }

  const no = [
    // 28P01 = 口令错。等一百年也还是错，重试只会把它糊成「服务慢」。
    (() => { const e = new Error('password authentication failed'); e.code = '28P01'; return e; })(),
    // ENOTFOUND = 主机名根本不存在。与 EAI_AGAIN（临时 DNS）刻意分开：
    // 合成一个的后果是「打错域名」要白等满整个预算。
    (() => { const e = new Error('getaddrinfo ENOTFOUND db'); e.code = 'ENOTFOUND'; return e; })(),
    new Error('database "easy_learn" does not exist'),
  ];
  for (const e of no) {
    assert.equal(isTransientConnectError(e), false, `${e.code ?? ''} ${e.message} 不该重试`);
  }
});

// ===== 借连接 =====

test('抖动一次（连接被掐断）：重试一次就成，调用方看不出区别', async () => {
  const pool = flakyPool({ failTimes: 1, error: resetErr() });

  const out = await captureWarn(async () => {
    const v = await withAuthConnection(pool, async () => 'ok');
    assert.equal(v, 'ok');
  });

  assert.equal(pool.state.connects, 2, '第一次撞上死连接，第二次应当成功');
  assert.equal(out.length, 1, '抖动被吃掉了，但要留下一条痕迹');
  assert.match(out[0], RETRY_HINT);
});

test('PG 崩溃恢复中：等它起来，而不是把这次崩溃记在登录功能头上', async () => {
  // 前两次「恢复中」，第三次好了 —— 这正是原样重现的那条时间线。
  const recovery = new Error('the database system is in recovery mode');
  const pool = flakyPool({ failTimes: 2, error: recovery });

  const out = await captureWarn(async () => {
    const v = await withAuthConnection(pool, async () => 'ok');
    assert.equal(v, 'ok');
  });

  assert.equal(pool.state.connects, 3);
  assert.equal(out.length, 2);
});

test('连接一次就借到：不许重试', async () => {
  const pool = flakyPool();

  const out = await captureWarn(() => withAuthConnection(pool, async () => 'ok'));

  assert.equal(pool.state.connects, 1, '顺利的时候多重试一次就是白加一次往返');
  assert.deepEqual(out, [], '没抖就不该有警告');
});

test('永久故障（口令错）：立刻报，且**不许**说成「暂时无法连接」', async () => {
  const e = new Error('password authentication failed for user "app_rls"');
  e.code = '28P01';
  const pool = flakyPool({ failTimes: 99, error: e });

  const out = await captureWarn(async () => {
    await assert.rejects(
      () => withAuthConnection(pool, async () => 'never'),
      (err) => {
        assert.equal(err.code, 'internal');
        assert.equal(err.status, 500);
        // 「暂时」的代价很具体：运维看到它就会等它自己好 —— 而口令配错永远不会。
        assert.equal(err.retryable, false, '配置问题不该被客户端反复重试');
        assert.match(err.message, /配置问题/);
        assert.equal(err.cause?.code, '28P01', '真实原因不能丢');
        return true;
      },
    );
  });

  assert.equal(pool.state.connects, 1, '等下去不会变好 —— 重试只会把配置错误表现成「服务很慢」');
  assert.deepEqual(out, []);
});

test('一直借不到：到预算就放弃，如实报可重试的 503', async () => {
  const pool = flakyPool({ failTimes: 99, error: resetErr() });

  const out = await withBudget(250, () => captureWarn(async () => {
    await assert.rejects(
      () => withAuthConnection(pool, async () => 'never'),
      (err) => {
        assert.equal(err.code, 'db_unavailable');
        assert.equal(err.status, 503);
        // 可重试是**协议的一部分**：客户端据此决定退避后再来，
        // 而不是把一次抖动当成终局错误直接弹「操作失败」。
        assert.equal(err.retryable, true);
        assert.equal(err.message, '数据库暂时无法连接');
        // 原始 cause 必须带出来。丢掉它的代价是排查时只剩一句中文，
        // 看不出到底是 ECONNRESET 还是恢复中。
        assert.equal(err.cause?.code, 'ECONNRESET');
        return true;
      },
    );
  }));

  assert.ok(pool.state.connects >= 2, '预算内至少要再试一次');
  assert.equal(out.length, pool.state.connects - 1, '每次重试各留一条痕迹');
});

test('连接到手之后，处理函数抛错**不重试** —— 那不是连接的问题', async () => {
  const pool = flakyPool();

  await assert.rejects(
    () => withAuthConnection(pool, async () => {
      throw new Error('手机号或密码不正确');
    }),
    /手机号或密码不正确/,
  );

  // 这条断言是「重试边界」的守卫：一旦有人把重试挂到更外层，
  // 登录失败（一次真实业务结果）会被重跑 —— 而重跑写库的那类路径就是重复下单。
  assert.equal(pool.state.connects, 1);
});

// ===== 业务事务 =====

test('业务事务：借连接抖一下之后，事务该走的步骤一步不少', async () => {
  const pool = flakyPool({ failTimes: 1, error: resetErr() });
  const identity = { userId: 'u-1', role: UserRoles.student, sessionId: 's-1' };

  const seen = await captureWarn(() => withRequestContext(pool, identity, async (client) => {
    await client.query('select 1');
    return 'done';
  }));

  const sqls = pool.client.calls;
  assert.equal(pool.state.connects, 2);
  assert.equal(seen.length, 1);
  assert.equal(sqls[0], 'begin', '第一条必须是 begin —— 身份只活在事务里');
  assert.equal(sqls.at(-1), 'release', '借了必须还');
  assert.equal(sqls.at(-2), 'commit', '处理函数跑完之后才提交');
  assert.equal(sqls.at(-3), 'select 1', '处理函数真的跑了');
  // 身份要写三句：user_id、visible_students（先清空再算）、算完的可见集合。
  // 漏掉最后一句的症状是「家长看得到孩子的账号但看不到任何数据」。
  assert.equal(
    sqls.filter((s) => s.startsWith('select set_config')).length,
    3,
    '重试不能把事务跳过，也不能把它做两遍',
  );
});

test('业务事务里抛错：先回滚再抛出，连接照还不误', async () => {
  const pool = flakyPool();
  const identity = { userId: 'u-1', role: UserRoles.student, sessionId: 's-1' };

  await assert.rejects(
    () => withRequestContext(pool, identity, async () => {
      throw new Error('该学生不在你的可见范围内');
    }),
    /不在你的可见范围/,
  );

  assert.ok(pool.client.calls.includes('rollback'));
  assert.equal(pool.client.calls.at(-1), 'release');
});
