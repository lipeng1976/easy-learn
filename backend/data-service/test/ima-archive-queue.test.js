import assert from 'node:assert/strict';
import test from 'node:test';

import { issueSessionToken, UserRoles } from '../../shared/token.js';
import { createApp } from '../src/app.js';
import { createImaArchiveQueue } from '../src/routes/ima.js';

const SECRET = 'test-secret-0123456789abcdefghijklmnop';

/**
 * 交卷后的 ima 归档队列判据。
 *
 * 它挡的是一类**静默串号**：把 `syncStudentArchive` 直接挂在请求 client 上
 * 做 fire-and-forget，请求一结束连接就归还池里，后台查询会带着别人的
 * 事务身份继续跑。单请求测试全绿，真机上表现为「偶尔推错孩子 / 偶尔报错」。
 *
 * 所以这里盯三件事：独立连接、每个任务自带 SET LOCAL 身份、故障不外冒。
 */
function makePool({ delayMs = 0, fail = false } = {}) {
  const clients = [];
  const errors = [];
  const pool = {
    async connect() {
      if (fail) throw new Error('pool down');
      const sqls = [];
      const client = {
        sqls,
        async query(sql, params) {
          sqls.push({ sql, params });
          if (delayMs > 0 && /^begin/i.test(sql)) {
            await new Promise((r) => setTimeout(r, delayMs));
          }
          return { rows: [], rowCount: 0 };
        },
        release() { client.released = true; },
      };
      clients.push(client);
      return client;
    },
  };
  return { pool, clients, errors, logger: { error: (m) => errors.push(m) } };
}

function guc(client, key) {
  const hit = client.sqls.find(
    (q) => /set_config/.test(q.sql) && q.params?.[0] === key,
  );
  return hit?.params?.[1];
}

test('归档任务各用独立连接，各自带自己的身份，跑完就释放', async () => {
  const { pool, clients, logger } = makePool();
  const queue = createImaArchiveQueue({ pool, logger });

  queue.schedule({ studentId: 's1', identity: { userId: 's1', role: 'student' } });
  queue.schedule({ studentId: 's2', identity: { userId: 's2', role: 'student' } });
  await queue.drain();

  assert.equal(clients.length, 2, '两个学生必须是两条独立连接，不能复用请求连接');
  assert.deepEqual(
    clients.map((c) => guc(c, 'app.user_id')).sort(),
    ['s1', 's2'],
    '身份必须逐任务 SET LOCAL，否则会串号',
  );
  for (const c of clients) {
    assert.ok(c.sqls.some((q) => /^begin/i.test(q.sql)));
    assert.ok(c.sqls.some((q) => /^commit/i.test(q.sql)));
    assert.equal(c.released, true, '连接必须归还，否则连接池会被可选同步耗光');
  }
});

test('排空是同一个 promise：schedule 已启动的那一轮，await drain 等得到', async () => {
  const { pool, clients, logger } = makePool({ delayMs: 30 });
  const queue = createImaArchiveQueue({ pool, logger });

  const started = Date.now();
  queue.schedule({ studentId: 's1', identity: { userId: 's1', role: 'student' } });
  const scheduleMs = Date.now() - started;
  assert.ok(scheduleMs < 20, `schedule 不许等网络，实际 ${scheduleMs}ms`);

  await queue.drain();
  assert.equal(clients.length, 1);
  assert.ok(Date.now() - started >= 25, 'drain 必须等那一轮真跑完');
});

test('借不到连接只记日志，不把 rejection 冒到进程级', async () => {
  const { pool, errors, logger } = makePool({ fail: true });
  const queue = createImaArchiveQueue({ pool, logger });

  queue.schedule({ studentId: 's1', identity: { userId: 's1', role: 'student' } });
  await queue.drain();

  assert.equal(errors.length, 1, '失败要留痕，不能静默消失');
  // db.js 会把底层借连接失败翻成统一的「数据库暂时无法连接」，
  // 所以这里盯「谁失败了 + 有日志」，不盯底层异常原文。
  assert.match(errors[0], /后台归档失败 student=s1/);
  assert.equal(queue.pendingCount, 0);
});

/**
 * 接线判据：上面只证明队列本身对，还得证明**交卷真的接上了它**。
 *
 * 漏掉 app.js 里那句 schedule，前三条测试照样全绿，而用户看到的仍是
 * 「29–65s 才返回 + 客户端误报没存上」。所以这里走一遍真路由，
 * 盯「commit 之后才 schedule」，且身份取验签结果而不是请求体。
 */
test('POST /data/checkin/submit：事务提交后才排队，身份取验签那份', async () => {
  const timeline = [];
  const questions = [
    {
      type: 'choice',
      stem: '1+1=?',
      options: ['1', '2'],
      answer: 'B',
      knowledge: '加法',
    },
  ];

  const authPool = {
    async connect() {
      return {
        async query() {
          return {
            rowCount: 1,
            rows: [{
              id: 'ses_1',
              user_id: 'stu_1',
              expires_at: new Date(Date.now() + 3600_000),
              revoked_at: null,
              revoke_reason: null,
            }],
          };
        },
        release() {},
      };
    },
  };
  const appPool = {
    async connect() {
      return {
        async query(sql, params) {
          if (/^begin/i.test(sql)) { timeline.push('begin'); return { rows: [], rowCount: 0 }; }
          if (/^commit/i.test(sql)) { timeline.push('commit'); return { rows: [], rowCount: 0 }; }
          if (/from checkin_quiz/.test(sql)) {
            return {
              rowCount: 1,
              rows: [{
                id: 'q_1',
                student_id: 'stu_1',
                subject: '英语',
                quiz_date: '2026-11-27',
                questions,
              }],
            };
          }
          return { rows: [], rowCount: 0 };
        },
        release() {},
      };
    },
  };

  const scheduled = [];
  const app = createApp({
    pool: appPool,
    authPool,
    sessionSecret: SECRET,
    imaArchiveQueue: {
      schedule: (job) => { timeline.push('schedule'); scheduled.push(job); },
    },
  });
  const token = issueSessionToken({
    secret: SECRET,
    subject: 'stu_1',
    role: UserRoles.student,
    sessionId: 'ses_1',
  });

  const res = await app({
    method: 'POST',
    pathname: '/data/checkin/submit',
    headers: { authorization: `Bearer ${token}` },
    body: { quizId: 'q_1', answers: [{ index: 0, picked: 'B' }] },
  });

  assert.equal(res.status, 200, res.body);
  assert.equal(JSON.parse(res.body).data.ima.reason, 'queued');
  assert.equal(scheduled.length, 1);
  assert.equal(scheduled[0].studentId, 'stu_1');
  assert.equal(scheduled[0].identity.userId, 'stu_1', '身份必须来自 token');
  assert.ok(
    timeline.indexOf('commit') < timeline.indexOf('schedule'),
    `归档必须在事务提交后排队，实际时间线：${timeline.join(' → ')}`,
  );
});
