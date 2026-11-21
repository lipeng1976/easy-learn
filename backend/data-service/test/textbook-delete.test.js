import assert from 'node:assert/strict';
import test from 'node:test';

import { deleteTextbook } from '../src/routes/textbook.js';

/**
 * 删除已导入教材 · 判据（纯假 client，不碰真库）。
 *
 * 盯的失败全是「不报错但功能安静地不对」：
 *   ① 只删书不清 `subject_scope` → 界面还显示教材、出题却退回手填范围；
 *   ② delete 不带 `student_id` → 家长可见集合里另一个孩子的同名书一起没；
 *   ③ `update subject_scope` 两个参数写反 → 清掉的是别人的范围；
 *   ④ 书不存在却回成功 → 家长看见书消失了，刷新一下又回来；
 *   ⑤ 中途失败不抛出 → 「章节删了、书还在」或反过来，外层事务也白搭。
 *
 * 外层 `withRequestContext` 已经开事务，所以这里只按顺序发 SQL；
 * 任何一条失败都必须**抛出去**让外层 rollback。
 */

function makeClient({ found = true, scopeRowCount = 1, failOn = '' } = {}) {
  const log = [];
  return {
    log,
    async query(sql, params = []) {
      log.push({ sql: String(sql).replace(/\s+/g, ' ').trim(), params });
      if (/select id, title from subject_book/.test(sql)) {
        return found
          ? { rowCount: 1, rows: [{ id: params[0], title: '旧英语教材' }] }
          : { rowCount: 0, rows: [] };
      }
      if (/delete from subject_unit/.test(sql)) {
        if (failOn === 'unit') throw new Error('subject_unit 删除失败');
        return { rowCount: 27, rows: [] };
      }
      if (/delete from subject_book/.test(sql)) {
        if (failOn === 'book') throw new Error('subject_book 删除失败');
        return { rowCount: 1, rows: [] };
      }
      if (/update subject_scope/.test(sql)) {
        return { rowCount: scopeRowCount, rows: [] };
      }
      return { rowCount: 0, rows: [] };
    },
  };
}

const parentCtx = () => ({ userId: 'p1', role: 'parent', visibleStudents: ['s1', 's2'] });

test('删书 = 章节 + 书 + 清掉指向它的范围，三条都限定 student_id', async () => {
  const client = makeClient();
  const out = await deleteTextbook(client, parentCtx(), { studentId: 's1', bookId: 'tb_old' });

  assert.equal(out.bookId, 'tb_old');
  assert.equal(out.title, '旧英语教材');
  assert.equal(out.scopeCleared, true);

  const deletes = client.log.filter((one) => /^(delete from|update subject_scope)/.test(one.sql));
  assert.equal(deletes.length, 3, '章节、书、范围清理，一条都不能少');
  assert.match(deletes[0].sql, /delete from subject_unit/);
  assert.match(deletes[1].sql, /delete from subject_book/);
  assert.match(deletes[2].sql, /update subject_scope/);

  for (const one of deletes) {
    assert.match(one.sql, /student_id = \$[12]/, '少了学生限定就是跨孩子删数据');
    assert.ok(one.params.includes('s1'), `这条 SQL 没带上目标学生：${one.sql}`);
    assert.ok(one.params.includes('tb_old'), `这条 SQL 没带上目标书：${one.sql}`);
  }
  // 顺序容易写反：update 的两个参数是 (studentId, bookId)，两条 delete 是反的。
  assert.deepEqual(deletes[0].params, ['tb_old', 's1']);
  assert.deepEqual(deletes[1].params, ['tb_old', 's1']);
  assert.deepEqual(deletes[2].params, ['s1', 'tb_old']);
});

test('范围清理必须清 book_id 且把起始节归 1（换书后旧章号没有意义）', async () => {
  const client = makeClient();
  await deleteTextbook(client, parentCtx(), { studentId: 's1', bookId: 'tb_old' });
  const sql = client.log.find((one) => /update subject_scope/.test(one.sql))?.sql ?? '';
  assert.match(sql, /book_id = null/);
  assert.match(sql, /start_unit_no = 1/);
  assert.match(sql, /where student_id = \$1 and book_id = \$2/);
});

test('删的是没在用的书：scopeCleared=false，但仍要执行范围清理语句', async () => {
  const client = makeClient({ scopeRowCount: 0 });
  const out = await deleteTextbook(client, parentCtx(), { studentId: 's1', bookId: 'tb_old' });
  assert.equal(out.scopeCleared, false);
  assert.ok(client.log.some((one) => /update subject_scope/.test(one.sql)));
});

test('书不存在 → 404，且一条删除都不能发', async () => {
  const client = makeClient({ found: false });
  await assert.rejects(
    () => deleteTextbook(client, parentCtx(), { studentId: 's1', bookId: 'tb_gone' }),
    (e) => e.code === 'not_found',
  );
  assert.equal(client.log.length, 1, '查不到还继续删 = 假装成功');
});

test('越界学生 403 / 缺 bookId 400，都不触发任何删除', async () => {
  const out = makeClient();
  await assert.rejects(
    () => deleteTextbook(out, parentCtx(), { studentId: 's3', bookId: 'tb_old' }),
    (e) => e.code === 'forbidden',
  );
  assert.equal(out.log.length, 0);

  const missing = makeClient();
  await assert.rejects(
    () => deleteTextbook(missing, parentCtx(), { studentId: 's1' }),
    (e) => e.code === 'bad_request',
  );
  assert.equal(missing.log.length, 0);
});

test('中途失败必须抛出去（外层事务才能 rollback），不能吞掉继续删', async () => {
  const unitFail = makeClient({ failOn: 'unit' });
  await assert.rejects(
    () => deleteTextbook(unitFail, parentCtx(), { studentId: 's1', bookId: 'tb_old' }),
    /subject_unit 删除失败/,
  );
  assert.equal(
    unitFail.log.some((one) => /delete from subject_book/.test(one.sql)),
    false,
  );

  const bookFail = makeClient({ failOn: 'book' });
  await assert.rejects(
    () => deleteTextbook(bookFail, parentCtx(), { studentId: 's1', bookId: 'tb_old' }),
    /subject_book 删除失败/,
  );
  assert.equal(
    bookFail.log.some((one) => /update subject_scope/.test(one.sql)),
    false,
    '书都没删掉就清范围，等于白清一次',
  );
});
