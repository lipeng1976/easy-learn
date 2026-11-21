import test from 'node:test';
import assert from 'node:assert/strict';

import { getCheckinQuiz, listCheckinSummary } from '../src/routes/checkin.js';

/**
 * 学生端「已完成」按科目分组要用的两条能力：
 *  ① `GET /data/checkin/summary` —— 每科做了几份、最近一次几分；
 *  ② `GET /data/checkin/quiz?subject=数学` —— 只看这一科的记录。
 *
 * ## 为什么这两条必须有判据
 *
 * 分组页的数字是**首页直接显示的数**。用已加载的那一页自己去数，
 * 分页 10 条时「数学 12 份」会变成「数学 7 份」，而且页面不报错 ——
 * 这正是这个仓库里反复出现的「静默失败」。所以断言不能只断「接口返回 200」，
 * 要断**参数**与**分组结果**。
 *
 * 假 client 不执行 SQL：按科过滤那一条必须自己按参数过滤，
 * 只断「SQL 里出现过 subject」在过滤条件写反时照样绿。
 */

const CTX = {
  userId: 'stu_1',
  role: 'student',
  visibleStudents: ['stu_1'],
  students: ['stu_1'],
};

/** 汇总接口的假行（真库 group by 出来的形状）。 */
function summaryClient(rows) {
  const queries = [];
  return {
    queries,
    query(sql, params = []) {
      queries.push({ sql, params });
      assert.match(sql, /group by 1/, '汇总必须由库分组，不能把全部行拉回来自己数');
      assert.match(sql, /join checkin_result/, '只有交过卷的才算「已完成」');
      return Promise.resolve({ rowCount: rows.length, rows });
    },
  };
}

/** 列表接口的假 client：**按参数真的过滤**，再分页。 */
function listClient(rows) {
  const queries = [];
  return {
    queries,
    query(sql, params = []) {
      queries.push({ sql, params });
      // 从 SQL 反推 subject 参数的位置：它总是最后一个 where 条件，
      // 但前面可能还挂着 status 布尔（位置会变）。
      const hit = sql.match(/and q\.subject = \$(\d+)/);
      const subject = hit ? params[Number(hit[1]) - 1] : '';
      const statusHit = sql.match(/= \$(\d+)::boolean/);
      const wantDone = statusHit ? Boolean(params[Number(statusHit[1]) - 1]) : null;

      const filtered = rows.filter((row) => {
        if (subject && row.subject !== subject) return false;
        if (wantDone !== null && (row._done === true) !== wantDone) return false;
        return true;
      });

      if (/count\(\*\)::int as total/.test(sql)) {
        return Promise.resolve({ rowCount: 1, rows: [{ total: filtered.length }] });
      }
      const paged = sql.match(/limit \$(\d+) offset \$(\d+)/);
      const limit = paged ? Number(params[Number(paged[1]) - 1]) : 0;
      const offset = paged ? Number(params[Number(paged[2]) - 1]) : 0;
      const page = limit > 0 ? filtered.slice(offset, offset + limit) : filtered.slice(offset);
      return Promise.resolve({
        rowCount: page.length,
        rows: page.map((row) => ({
          id: row.id,
          student_id: row.student_id,
          quiz_date: row.quiz_date,
          subject: row.subject,
          difficulty: '',
          questions: [],
          status: row._done ? 'done' : 'pending',
          answers: row._done ? {} : null,
          score: row._done ? 3 : null,
          total: row._done ? 5 : null,
          submitted_at: row._done ? '2026-11-10T10:00:00Z' : null,
        })),
      });
    },
  };
}

test('汇总：按科目给出份数与最近一次成绩', async () => {
  const client = summaryClient([
    {
      subject: '数学',
      done: 12,
      last_submitted_at: '2026-11-11T09:00:00Z',
      last_score: 4,
      last_total: 5,
    },
    {
      subject: '语文',
      done: 3,
      last_submitted_at: '2026-11-09T09:00:00Z',
      last_score: 5,
      last_total: 5,
    },
  ]);

  const data = await listCheckinSummary(client, CTX, { studentId: 'stu_1' });

  assert.equal(data.subjects.length, 2);
  assert.deepEqual(data.subjects[0], {
    subject: '数学',
    done: 12,
    lastSubmittedAt: '2026-11-11T09:00:00Z',
    lastScore: 4,
    lastTotal: 5,
  });
  // 数字必须是 number：客户端要拿它做「> 0」判断，字符串 '12' 会让
  // `done > 0` 意外成立、`done + 1` 变成 '121'。
  assert.equal(typeof data.subjects[0].done, 'number');
  assert.equal(client.queries[0].params[0], 'stu_1');
});

test('汇总：从没交过卷 = 空列表（不是错误）', async () => {
  const client = summaryClient([]);
  const data = await listCheckinSummary(client, CTX, { studentId: 'stu_1' });
  assert.deepEqual(data.subjects, []);
});

test('汇总：成绩字段缺失时回 null，不编一个 0 分', async () => {
  // 0 分是「做过且全错」，null 是「没有这份数据」—— 混成 0 会让
  // 分组色块上写着「最近 0/5」，而家长以为孩子交了白卷。
  const client = summaryClient([
    {
      subject: '英语',
      done: 1,
      last_submitted_at: null,
      last_score: null,
      last_total: null,
    },
  ]);
  const data = await listCheckinSummary(client, CTX, { studentId: 'stu_1' });
  assert.equal(data.subjects[0].lastScore, null);
  assert.equal(data.subjects[0].lastTotal, null);
});

test('列表：带 subject 只回这一科，且参数里真的是它', async () => {
  const client = listClient([
    { id: 'q1', student_id: 'stu_1', quiz_date: '2026-11-10', subject: '数学', _done: true },
    { id: 'q2', student_id: 'stu_1', quiz_date: '2026-11-10', subject: '语文', _done: true },
    { id: 'q3', student_id: 'stu_1', quiz_date: '2026-11-11', subject: '数学', _done: true },
  ]);

  const page = await getCheckinQuiz(client, CTX, {
    studentId: 'stu_1',
    status: 'done',
    subject: '数学',
  });

  assert.equal(page.quizzes.length, 2);
  assert.deepEqual(
    page.quizzes.map((one) => one.quiz.id),
    ['q1', 'q3'],
  );
  assert.equal(page.total, 2, 'total 必须是过滤后的总数');
  // 参数级断言：SQL 里出现过 subject 不够，值传错照样绿。
  assert.ok(
    client.queries.some((one) => one.params.includes('数学')),
    'subject 必须以参数形式传进 SQL',
  );
});

test('列表：不带 subject 时不加过滤（老客户端行为不变）', async () => {
  const client = listClient([
    { id: 'q1', student_id: 'stu_1', quiz_date: '2026-11-10', subject: '数学', _done: true },
    { id: 'q2', student_id: 'stu_1', quiz_date: '2026-11-10', subject: '语文', _done: true },
  ]);

  const page = await getCheckinQuiz(client, CTX, { studentId: 'stu_1', status: 'done' });
  assert.equal(page.quizzes.length, 2);
  assert.ok(
    client.queries.every((one) => !/q\.subject = /.test(one.sql)),
    '没传 subject 就不该出现这一段 where',
  );
});

test('列表：subject 前后空格被裁掉（分组页传的是同一个词）', async () => {
  const client = listClient([
    { id: 'q1', student_id: 'stu_1', quiz_date: '2026-11-10', subject: '数学', _done: true },
  ]);
  const page = await getCheckinQuiz(client, CTX, {
    studentId: 'stu_1',
    status: 'done',
    subject: '  数学  ',
  });
  assert.equal(page.quizzes.length, 1);
  // ⚠️ 只断「回了一条」不够：过滤整段缺失时它也回一条（测试照样绿）。
  // 必须断参数里那个值是裁过的 —— 带空格传进 SQL 会一条都匹配不上。
  assert.ok(client.queries.some((one) => one.params.includes('数学')));
  assert.ok(
    client.queries.every((one) => !one.params.some(
      (value) => typeof value === 'string' && value.trim() !== value,
    )),
    '空格必须在进 SQL 前裁掉',
  );
});
