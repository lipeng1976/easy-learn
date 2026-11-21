import assert from 'node:assert/strict';
import test from 'node:test';

import { SUBJECTS } from '../src/routes/subject.js';

/**
 * 学科范围 · 判据（纯假 client，不碰真库）。
 *
 * 盯四类「静默不对」：
 *   ① 科目白名单与客户端漂开 —— 客户端能选「物理」，服务端 400，表现为
 *      「配置页保存没成功」而代码看着都对；
 *   ② 题量 / 难度 / 条数越界被悄悄改成默认值（家长以为保存了，其实没生效）；
 *   ③ 学生能改自己的范围（应当只有家长能改）；
 *   ④ `026` 未迁移时读端点抛错，把整页拖垮（可选能力规矩：能缺、不能错）。
 */

function makeClient({ rows = [], failOnRead = false, failOnWrite = false } = {}) {
  const log = [];
  return {
    log,
    async query(sql, params = []) {
      log.push({ sql, params });
      if (/from subject_scope where student_id = \$1/.test(sql)) {
        if (failOnRead) throw new Error('relation "subject_scope" does not exist');
        return { rowCount: rows.length, rows };
      }
      if (/insert into subject_scope/.test(sql)) {
        if (failOnWrite) throw new Error('relation "subject_scope" does not exist');
        return {
          rowCount: 1,
          rows: [{
            student_id: params[0],
            subject: params[1],
            daily_count: params[2],
            difficulty: params[3],
            points: JSON.parse(params[4]),
            updated_at: '2026-11-12T00:00:00.000Z',
          }],
        };
      }
      return { rowCount: 0, rows: [] };
    },
  };
}

const parentCtx = () => ({ userId: 'p1', role: 'parent', visibleStudents: ['s1', 's2'] });
const studentCtx = () => ({ userId: 's1', role: 'student', visibleStudents: ['s1'] });

test('十科白名单与客户端 HomeworkItemNormalizer.subjectNames 逐字一致', () => {
  assert.deepEqual(SUBJECTS, [
    '语文', '数学', '英语', '物理', '化学', '生物', '历史', '地理', '政治', '其他',
  ], '两边漂开的症状是「客户端能选、服务端 400」');
});

test('十科都能保存范围；不认识的科目 400', async () => {
  const { putSubjectScope } = await import('../src/routes/subject.js');
  for (const subject of SUBJECTS) {
    const client = makeClient();
    const out = await putSubjectScope(client, parentCtx(), {
      studentId: 's1', subject, dailyCount: 5, difficulty: '基础', points: ['甲'],
    });
    assert.equal(out.scope.subject, subject);
    assert.equal(out.scope.configured, true);
  }
  await assert.rejects(
    () => putSubjectScope(makeClient(), parentCtx(), {
      studentId: 's1', subject: '体育', dailyCount: 5, difficulty: '基础', points: [],
    }),
    (e) => e.code === 'bad_request',
  );
});

test('题量 / 难度 / 条数越界一律 400，不悄悄改默认值', async () => {
  const { putSubjectScope } = await import('../src/routes/subject.js');
  const base = { studentId: 's1', subject: '数学', dailyCount: 5, difficulty: '基础', points: [] };

  await assert.rejects(
    () => putSubjectScope(makeClient(), parentCtx(), { ...base, dailyCount: 9 }),
    (e) => e.code === 'bad_request',
    '9 题不在 3/5/8 档位上，改默认值等于家长以为保存了',
  );
  await assert.rejects(
    () => putSubjectScope(makeClient(), parentCtx(), { ...base, difficulty: '地狱' }),
    (e) => e.code === 'bad_request',
  );
  await assert.rejects(
    () => putSubjectScope(makeClient(), parentCtx(), {
      ...base, points: ['1', '2', '3', '4', '5', '6', '7'],
    }),
    (e) => e.code === 'bad_request',
    '超过 6 条必须响亮失败：静默截断会让家长以为第 7 条也在练',
  );
  await assert.rejects(
    () => putSubjectScope(makeClient(), parentCtx(), { ...base, points: ['长'.repeat(61)] }),
    (e) => e.code === 'bad_request',
  );
});

test('范围条目去重保序（顺序即优先级），空白条目不落库', async () => {
  const { putSubjectScope } = await import('../src/routes/subject.js');
  const client = makeClient();
  const out = await putSubjectScope(client, parentCtx(), {
    studentId: 's1', subject: '历史', dailyCount: 3, difficulty: '提高',
    points: ['1840 鸦片战争', '  ', '1840 鸦片战争', '1911 辛亥革命'],
  });
  assert.deepEqual(out.scope.points, ['1840 鸦片战争', '1911 辛亥革命']);
  assert.equal(out.scope.dailyCount, 3);
  assert.equal(out.scope.difficulty, '提高');
});

test('学生只能读自己的、不能改；家长改别人孩子 403', async () => {
  const { putSubjectScope } = await import('../src/routes/subject.js');
  await assert.rejects(
    () => putSubjectScope(makeClient(), studentCtx(), {
      studentId: 's1', subject: '数学', dailyCount: 5, difficulty: '基础', points: [],
    }),
    (e) => e.code === 'forbidden',
    '学生能改自己的范围 = 孩子可以给自己减题',
  );
  await assert.rejects(
    () => putSubjectScope(makeClient(), parentCtx(), {
      studentId: 's9', subject: '数学', dailyCount: 5, difficulty: '基础', points: [],
    }),
    (e) => e.code === 'forbidden',
  );
});

test('026 未迁移：读端点降级为「未配置」，写端点响亮失败', async () => {
  const { listSubjectScopes, getSubjectScope, putSubjectScope } =
    await import('../src/routes/subject.js');

  const list = await listSubjectScopes(makeClient({ failOnRead: true }), parentCtx(), {
    studentId: 's1',
  });
  assert.deepEqual(list.scopes, [], '读不到表按空列表降级，页面照常渲染');

  const one = await getSubjectScope(makeClient({ failOnRead: true }), parentCtx(), {
    studentId: 's1', subject: '数学',
  });
  assert.equal(one.scope.configured, false);
  assert.equal(one.scope.dailyCount, 5);
  assert.deepEqual(one.scope.points, []);

  await assert.rejects(
    () => putSubjectScope(makeClient({ failOnWrite: true }), parentCtx(), {
      studentId: 's1', subject: '数学', dailyCount: 5, difficulty: '基础', points: [],
    }),
    '写失败必须报错：家长点了保存正在等结果',
  );
});

test('读单科：有行按行回，没行回未配置（不返回 null）', async () => {  const { getSubjectScope } = await import('../src/routes/subject.js');
  const row = {
    student_id: 's1', subject: '数学', daily_count: 8,
    difficulty: '挑战', points: ['整式化简'], updated_at: '2026-11-11T00:00:00.000Z',
  };
  const hit = await getSubjectScope(makeClient({ rows: [row] }), parentCtx(), {
    studentId: 's1', subject: '数学',
  });
  assert.equal(hit.scope.configured, true);
  assert.deepEqual(hit.scope.points, ['整式化简']);
  assert.equal(hit.scope.difficulty, '挑战');

  const miss = await getSubjectScope(makeClient({ rows: [] }), parentCtx(), {
    studentId: 's1', subject: '英语',
  });
  assert.equal(miss.scope.configured, false);
  assert.equal(miss.scope.subject, '英语');
});

test('配置页候选只取这一科：SQL 带 subject 过滤，上限 30 条', async () => {
  const { listSubjectSeeds } = await import('../src/routes/subject.js');

  const seen = [];
  const client = {
    async query(sql, params = []) {
      seen.push({ sql, params });
      return {
        rowCount: 2,
        rows: [
          { knowledge_point: '《观沧海》默写', wrong_count: 2, wrong_reason: '' },
          { knowledge_point: '文言实词：之', wrong_count: 1, wrong_reason: '' },
        ],
      };
    },
  };
  const out = await listSubjectSeeds(client, parentCtx(), {
    studentId: 's1', subject: '语文',
  });
  assert.deepEqual(out.seeds.map((one) => one.knowledge), ['《观沧海》默写', '文言实词：之']);
  assert.match(seen[0].sql, /and subject = \$2/,
    '不加科目过滤的症状：语文配置页列出「整式化简」');
  assert.deepEqual(seen[0].params, ['s1', '语文']);

  await assert.rejects(
    () => listSubjectSeeds(client, parentCtx(), { studentId: 's1', subject: '体育' }),
    (e) => e.code === 'bad_request',
  );

  const many = {
    async query() {
      return {
        rowCount: 40,
        rows: Array.from({ length: 40 }, (_, i) => ({
          knowledge_point: `点${i}`, wrong_count: 1, wrong_reason: '',
        })),
      };
    },
  };
  const capped = await listSubjectSeeds(many, parentCtx(), { studentId: 's1', subject: '历史' });
  assert.equal(capped.seeds.length, 30, '候选项上限由 checkin 那边同一个常量决定');
});
