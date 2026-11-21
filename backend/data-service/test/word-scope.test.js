import assert from 'node:assert/strict';
import test from 'node:test';

/**
 * 英语单词打卡 · 练习范围与成绩摘要判据（纯假 client，不碰真库）。
 *
 * 盯的是三类「静默不对」：
 *   ① 范围串到别的孩子 / 别人的书（§5.4.1）；
 *   ② 日期被 `::text` 比较或 JSON 时区转换偏一天（§7.2 项目踩过）；
 *   ③ 摘要不是幂等 upsert（断网重试刷出重复行）。
 */

const UNITS = ['Unit 1', 'Unit 2', 'Unit 3'];

function makeClient({ ownedBook = true, units = UNITS, scopeRow = null, dailyRows = [] } = {}) {
  const log = [];
  return {
    log,
    async query(sql, params = []) {
      log.push({ sql, params });
      if (/select id, title from word_book where id = \$1 and student_id = \$2/.test(sql)) {
        return ownedBook
          ? { rowCount: 1, rows: [{ id: params[0], title: '七上' }] }
          : { rowCount: 0, rows: [] };
      }
      if (/select unit from word_entry/.test(sql)) {
        return { rowCount: units.length, rows: units.map((unit) => ({ unit })) };
      }
      if (/select \* from word_scope where student_id = \$1/.test(sql)) {
        return scopeRow ? { rowCount: 1, rows: [scopeRow] } : { rowCount: 0, rows: [] };
      }
      if (/select title from word_book where id = \$1 and student_id = \$2/.test(sql)) {
        return { rowCount: 1, rows: [{ title: '七上' }] };
      }
      if (/insert into word_daily_result/.test(sql)) {
        return {
          rowCount: 1,
          rows: [{
            day: params[1], total: params[2], correct: params[3],
            streak: params[4], wrong_words: JSON.parse(params[5]),
          }],
        };
      }
      if (/from word_daily_result/.test(sql)) {
        return { rowCount: dailyRows.length, rows: dailyRows };
      }
      return { rowCount: 1, rows: [] };
    },
  };
}

function parentCtx() {
  return { userId: 'parent-1', role: 'parent', visibleStudents: ['s1', 's2'] };
}

test('四种 unitMode 都接受，其它值 400；learned 不被偷偷换成 all', async () => {
  const { putWordScope } = await import('../src/routes/word.js');
  for (const mode of ['current', 'learned', 'selected', 'all']) {
    const client = makeClient();
    await putWordScope(client, parentCtx(), {
      studentId: 's1', bookId: 'wb1', unitMode: mode,
      currentUnit: 'Unit 2', selectedUnits: mode === 'selected' ? ['Unit 1'] : [],
      dailyCount: 10,
    });
    const write = client.log.find((one) => /insert into word_scope/.test(one.sql));
    assert.equal(write.params[2], mode, `${mode} 必须原样落库`);
  }
  await assert.rejects(
    () => putWordScope(makeClient(), parentCtx(), {
      studentId: 's1', bookId: 'wb1', unitMode: 'whatever', dailyCount: 10,
    }),
    (e) => e.code === 'bad_request',
  );
});

test('currentUnit 不存在 → 400；selected 模式不选单元 → 400', async () => {
  const { putWordScope } = await import('../src/routes/word.js');
  await assert.rejects(
    () => putWordScope(makeClient(), parentCtx(), {
      studentId: 's1', bookId: 'wb1', unitMode: 'learned', currentUnit: 'Unit 99',
    }),
    (e) => e.code === 'bad_request',
  );
  await assert.rejects(
    () => putWordScope(makeClient(), parentCtx(), {
      studentId: 's1', bookId: 'wb1', unitMode: 'selected', currentUnit: 'Unit 1',
      selectedUnits: [],
    }),
    (e) => e.code === 'bad_request',
  );
  await assert.rejects(
    () => putWordScope(makeClient(), parentCtx(), {
      studentId: 's1', bookId: 'wb1', unitMode: 'selected', currentUnit: 'Unit 1',
      selectedUnits: ['别本书的单元'],
    }),
    (e) => e.code === 'bad_request',
  );
});

test('越界 bookId / 学生自己改范围 → 403，不靠 RLS 静默变空', async () => {
  const { putWordScope } = await import('../src/routes/word.js');
  await assert.rejects(
    () => putWordScope(makeClient({ ownedBook: false }), parentCtx(), {
      studentId: 's1', bookId: '别人的书', unitMode: 'learned',
    }),
    (e) => e.code === 'forbidden',
  );
  await assert.rejects(
    () => putWordScope(makeClient(), {
      userId: 's1', role: 'student', visibleStudents: ['s1'],
    }, { studentId: 's1', bookId: 'wb1', unitMode: 'all' }),
    (e) => e.code === 'forbidden',
  );
});

test('范围按 student_id 隔离：切孩子查的是另一行，不串书 / 单元 / 题量', async () => {
  const { getWordScope } = await import('../src/routes/word.js');
  const client = makeClient({
    scopeRow: {
      book_id: 'wb_s1', unit_mode: 'current', current_unit: 'Unit 3',
      selected_units: [], daily_count: 5,
    },
  });
  const a = await getWordScope(client, parentCtx(), { studentId: 's1' });
  const b = await getWordScope(client, parentCtx(), { studentId: 's2' });
  assert.equal(a.studentId, 's1');
  assert.equal(b.studentId, 's2');
  const params = client.log
    .filter((one) => /select \* from word_scope/.test(one.sql))
    .map((one) => one.params[0]);
  assert.deepEqual(params, ['s1', 's2'], '两个孩子必须各自按自己的 id 查');
});

test('没配置 / 025 未迁移 → getWordScope 按「未配置」返回，绝不抛错', async () => {
  const { getWordScope } = await import('../src/routes/word.js');
  const empty = await getWordScope(makeClient(), parentCtx(), { studentId: 's1' });
  assert.equal(empty.configured, false);
  assert.equal(empty.unitMode, 'learned', '默认已学区间');
  assert.equal(empty.dailyCount, 10);
  const boom = {
    async query() { throw Object.assign(new Error('42P01'), { code: '42P01' }); },
  };
  const degraded = await getWordScope(boom, parentCtx(), { studentId: 's1' });
  assert.equal(degraded.configured, false);
  assert.deepEqual(degraded.units, []);
});

test('daily POST：幂等 upsert，wrongWords 截断 Top5，day 用 ::date', async () => {
  const { postWordDaily } = await import('../src/routes/word.js');
  const client = makeClient();
  const res = await postWordDaily(client, parentCtx(), {
    studentId: 's1', day: '2026-11-11', total: 10, correct: 8, streak: 3,
    wrongWords: Array.from({ length: 8 }, (_, i) => ({ word: `w${i}`, count: 8 - i })),
  });
  const sql = client.log.map((one) => one.sql).join('\n');
  assert.match(sql, /on conflict \(student_id, day\) do update/);
  assert.match(sql, /\$2::date/, '写成 ::text 会 42883 date>=text');
  assert.match(sql, /returning day::text as day/);
  assert.equal(res.result.day, '2026-11-11');
  assert.equal(res.result.wrong_words.length, 5);
});

test('daily POST：correct > total / 非法日期 → 400', async () => {
  const { postWordDaily } = await import('../src/routes/word.js');
  await assert.rejects(
    () => postWordDaily(makeClient(), parentCtx(), {
      studentId: 's1', day: '2026-11-11', total: 5, correct: 6,
    }),
    (e) => e.code === 'bad_request',
  );
  await assert.rejects(
    () => postWordDaily(makeClient(), parentCtx(), {
      studentId: 's1', day: '2026-02-31', total: 5, correct: 1,
    }),
    (e) => e.code === 'bad_request',
  );
});

test('daily GET：day::text 输出、无时间窗不打默认、from>to 400', async () => {
  const { listWordDaily } = await import('../src/routes/word.js');
  const client = makeClient({ dailyRows: [{ day: '2026-11-11', total: 10, correct: 8, streak: 3, wrong_words: [] }] });
  const res = await listWordDaily(client, parentCtx(), { studentId: 's1' });
  assert.equal(res.results[0].day, '2026-11-11');
  const sql = client.log.find((one) => /from word_daily_result/.test(one.sql)).sql;
  assert.match(sql, /day::text as day/);
  assert.doesNotMatch(sql, /day >=/, '不给时间窗不能偷偷塞默认窗口');
  await assert.rejects(
    () => listWordDaily(makeClient(), parentCtx(), {
      studentId: 's1', from: '2026-11-12', to: '2026-11-11',
    }),
    (e) => e.code === 'bad_request',
  );
});

test('daily GET：给了时间窗用 ::date 而不是 ::text；hasMore 由多取一条判断', async () => {
  const { listWordDaily } = await import('../src/routes/word.js');
  const client = makeClient({ dailyRows: Array.from({ length: 3 }, () => ({ day: '2026-11-11', total: 1, correct: 1, streak: 1, wrong_words: [] })) });
  const res = await listWordDaily(client, parentCtx(), {
    studentId: 's1', from: '2026-11-01', to: '2026-11-30', limit: 2,
  });
  assert.equal(res.hasMore, true);
  assert.equal(res.results.length, 2);
  const one = client.log.find((x) => /from word_daily_result/.test(x.sql));
  assert.match(one.sql, /::date/);
  assert.doesNotMatch(one.sql, /day >= \$2::text/);
});

test('daily GET：025 未迁移 → 返回空而非 500（可选功能不弹红条）', async () => {
  const { listWordDaily } = await import('../src/routes/word.js');
  const boom = { async query() { throw new Error('42P01'); } };
  const res = await listWordDaily(boom, parentCtx(), { studentId: 's1' });
  assert.deepEqual(res.results, []);
  assert.equal(res.reason, 'word_tables_unavailable');
});
