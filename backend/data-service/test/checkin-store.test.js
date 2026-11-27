import test from 'node:test';
import assert from 'node:assert/strict';

import {
  getCheckinQuiz,
  listCheckinResults,
  saveCheckinQuiz,
  submitCheckin,
} from '../src/routes/checkin.js';

/**
 * 每日概念打卡的**存储与复算**（fake client，不碰真库）。
 *
 * 这里压的是三件在真机上很难发现的事：
 * 1. 只接受选择 / 判断（填空与解答在本地判分下必然误判）；
 * 2. 提交时的分数由服务端**按题目快照复算**，客户端传来的数字一律不采信；
 * 3. 时间窗 `from > to` 是 400，不是静默返回空列表。
 *
 * ⚠️ 它证明不了 RLS 语义（假 client 没有策略）。那一条在
 * `scripts/probe-checkin-rls.mjs` 里用真库、非超级用户量行数。
 */

const CTX_BASE = {
  userId: 'stu_1',
  role: 'student',
  visibleStudents: ['stu_1'],
  students: ['stu_1'],
};

/**
 * 构造一份**与真实 ctx 同构**的上下文。
 *
 * ⚠️ 刻意**不**塞 `client`：app.js 对受保护路由统一调用
 * `handler(client, ctx, input)`，而 `ctx`（db.js 的 `{userId, role, sessionId,
 * visibleStudents}`）上**没有** client 字段。
 *
 * 之前这里塞了一份 `client`，于是 `syncStudentArchive(ctx, ...)` 内部那个
 * `ctx.client.query` 在单测里一直是绿的、真机上直接
 * `TypeError: Cannot read properties of undefined (reading 'query')` → 500。
 * 现在需要 client 的函数一律**显式收参数**，测试也照此调用。
 */
function makeCtx() {
  return { ...CTX_BASE };
}

const QUESTIONS = [
  {
    type: 'choice',
    stem: '$1+1=?$',
    options: ['1', '2', '3', '4'],
    answer: 'B',
    knowledge: '有理数混合运算',
    analysis: '直接相加',
  },
  {
    type: 'judge',
    stem: '判断：$0.5=\\frac{1}{2}$',
    options: ['对', '错'],
    answer: '对',
    knowledge: '分数的意义',
    analysis: '同一个数',
  },
];

/**
 * 假 client 解析列表查询的意图（它不执行 SQL，只能照着 SQL 里的占位符还原）。
 *
 * 从 SQL **反推参数位置**而不是按 `params.length` 猜：`status` 过滤可选、
 * `limit` 也可选，长度组合有四种，按长度分支迟早错一位且不报错。
 */
function readListPlan(sql, params) {
  const hasStatus = /\$3::boolean/.test(sql);
  const paged = sql.match(/limit \$(\d+) offset \$(\d+)/);
  return {
    quizDate: params[1] ?? null,
    wantDone: hasStatus ? Boolean(params[2]) : null,
    limit: paged ? Number(params[Number(paged[1]) - 1]) : 0,
    offset: paged ? Number(params[Number(paged[2]) - 1]) : 0,
  };
}

/**
 * 这一行有没有成绩。
 *
 * 行上自带 `_result` 优先（一份卷一份成绩，混合 pending/done 的用例靠它）；
 * 没标记时才回落到全局 `resultRow`（老用例只造一份卷）。
 */
function rowResult(row, resultRow) {
  return Object.prototype.hasOwnProperty.call(row, '_result') ? row._result : resultRow;
}

function filterRows(rows, resultRow, sql, params) {
  const plan = readListPlan(sql, params);
  return rows.filter((row) => {
    if (plan.quizDate && row.quiz_date !== plan.quizDate) return false;
    if (plan.wantDone === null) return true;
    return (rowResult(row, resultRow) != null) === plan.wantDone;
  });
}

function makeFakeClient({
  quizRow = null,
  quizDayRows = [],
  resultRow = null,
  credential = null,
  studentKb = null,
  failMistakeInsert = false,
} = {}) {
  const queries = [];
  return {
    queries,
    query(sql, params = []) {
      queries.push({ sql, params });
      // 错题本写入失败（028 未迁移）不能拖垮交卷 —— 成绩比归档重要。
      // 这条开关专门用来验那条 savepoint 有没有起作用。
      if (failMistakeInsert && /insert into review_mistake/.test(sql)) {
        return Promise.reject(new Error('column "source_ref" does not exist'));
      }
      if (/delete from checkin_result/.test(sql)) {
        return Promise.resolve({ rowCount: 0, rows: [] });
      }
      // 🔴 必须放在下面那个 select 分支之前：删行的 SQL 也长得像
      // `from checkin_quiz where student_id = $1`，匹配错了会把 DELETE
      // 当成「当天没有题」的 SELECT 回给调用方。
      if (/delete from checkin_quiz/.test(sql)) {
        return Promise.resolve({ rowCount: 1, rows: [] });
      }
      if (/insert into checkin_quiz/.test(sql)) {
        return Promise.resolve({
          rowCount: 1,
          rows: [
            {
              id: params[0],
              student_id: params[1],
              quiz_date: params[3],
              subject: params[4],
              difficulty: params[5],
              questions: JSON.parse(params[6]),
              status: 'pending',
            },
          ],
        });
      }
      // 🔴 列表查询改成「一次 left join + 一次 count」之后，这两条必须排在
      // 旧的单表匹配之前：它们的 SQL 里同样有 `from checkin_quiz`。
      //
      // 假 client 不执行 SQL，所以这里必须**自己按参数过滤**（`$3` 是
      // `status === 'done'` 这个布尔）。把过滤写成「SQL 里出现过某个词就算过」
      // 的断言，在过滤条件写反时照样绿 —— 那正是这类用例最容易失效的方式。
      if (/count\(\*\)::int as total/.test(sql)) {
        return Promise.resolve({
          rowCount: 1,
          rows: [{ total: filterRows(quizDayRows, resultRow, sql, params).length }],
        });
      }
      if (/from checkin_quiz q\s+left join checkin_result/.test(sql)) {
        const plan = readListPlan(sql, params);
        const rows = filterRows(quizDayRows, resultRow, sql, params).map((row) => {
          const mine = rowResult(row, resultRow);
          return {
            ...row,
            answers: mine?.answers ?? null,
            score: mine?.score ?? null,
            total: mine?.total ?? null,
            submitted_at: mine?.submitted_at ?? null,
          };
        });
        const page =
          plan.limit > 0
            ? rows.slice(plan.offset, plan.offset + plan.limit)
            : rows.slice(plan.offset);
        return Promise.resolve({ rowCount: page.length, rows: page });
      }
      if (/from checkin_quiz\s+where student_id = \$1/.test(sql)) {
        return Promise.resolve({
          rowCount: quizDayRows.length,
          rows: quizDayRows,
        });
      }
      if (/select id, student_id, subject, quiz_date::text as quiz_date, questions/.test(sql)) {
        return Promise.resolve({
          rowCount: quizRow ? 1 : 0,
          rows: quizRow ? [quizRow] : [],
        });
      }
      if (/from checkin_result where quiz_id/.test(sql)) {
        return Promise.resolve({
          rowCount: resultRow ? 1 : 0,
          rows: resultRow ? [resultRow] : [],
        });
      }
      // ima 是可选同步：默认「没连」—— 提交不该因此失败。
      // 注意要回 `rowCount: 0`（不是 rows: [] + rowCount: 1）：
      // `getImaCredential` 用 rowCount 判断存在性，回错会让它去读 rows[0] 然后炸。
      if (/from relationship/.test(sql)) {
        return Promise.resolve({ rowCount: 0, rows: [] });
      }
      if (/from ima_credential/.test(sql)) {
        return Promise.resolve(
          credential ? { rowCount: 1, rows: [credential] } : { rowCount: 0, rows: [] },
        );
      }
      // ⭐ 11-08：按学生口径，推送前必须先查到「这个学生的 KB 映射」。
      // 没有映射就是没配置（no_owner），造数据时不能只给凭证行。
      if (/from ima_student_kb/.test(sql)) {
        return Promise.resolve(
          studentKb ? { rowCount: 1, rows: [studentKb] } : { rowCount: 0, rows: [] },
        );
      }
      if (/from checkin_quiz q\s+join checkin_result/.test(sql)) {
        return Promise.resolve({ rowCount: 0, rows: [] });
      }
      return Promise.resolve({ rowCount: 1, rows: [] });
    },
  };
}

test('打卡：填空题被拒（本地判不了），错误里说清是第几题', async () => {
  const client = makeFakeClient();

  await assert.rejects(
    () =>
      saveCheckinQuiz(client, makeCtx(), {
        id: 'q_1',
        studentId: 'stu_1',
        quizDate: '2026-10-27',
        questions: [
          { type: 'fill', stem: 'x=?', options: [], answer: '3', knowledge: '方程' },
        ],
      }),
    (error) => {
      assert.equal(error.code, 'bad_request');
      assert.match(error.message, /第 1 题/);
      assert.match(error.message, /choice \/ judge/);
      return true;
    },
  );
});

test('打卡：答案字母越界被拒（那道题永远做不对）', async () => {
  const client = makeFakeClient();

  await assert.rejects(
    () =>
      saveCheckinQuiz(client, makeCtx(), {
        id: 'q_1',
        studentId: 'stu_1',
        quizDate: '2026-10-27',
        questions: [
          {
            type: 'choice',
            stem: '四选一',
            options: ['1', '2', '3', '4'],
            answer: 'E',
            knowledge: '有理数',
          },
        ],
      }),
    (error) => {
      assert.equal(error.code, 'bad_request');
      assert.match(error.message, /超出选项数/);
      return true;
    },
  );
});

test('打卡：保存时判断题的选项与答案被归一（不信客户端措辞）', async () => {
  const client = makeFakeClient();

  const saved = await saveCheckinQuiz(client, makeCtx(), {
    id: 'q_1',
    studentId: 'stu_1',
    quizDate: '2026-10-27',
    subject: '数学',
    questions: QUESTIONS,
  });

  assert.equal(saved.quiz.id, 'q_1');
  assert.equal(saved.quiz.status, 'pending');

  const judge = saved.quiz.questions[1];
  assert.deepEqual(judge.options, ['正确', '错误'], '选项必须被覆盖成固定两项');
  assert.equal(judge.answer, 'T', '「对」必须归一成 T');

  // 🔴 2026-10-27 起「同日同科目只留一份」的覆盖语义已废除（022 迁移删掉了
  // 唯一键）。存题**只插不删** —— 这里断言「一条 delete 都没有」，
  // 否则家长多出一套就把孩子正在做的那套连同成绩删掉了。
  const deleted = client.queries.filter((q) => /delete from checkin_/.test(q.sql));
  assert.deepEqual(deleted, [], '存题不得删除任何旧卷或旧结果（一次出题=一份独立试卷）');

  const inserted = client.queries.find((q) => /insert into checkin_quiz/.test(q.sql));
  assert.ok(inserted, '必须把这份试卷插进去');
});

test('打卡：同一天同科目多次出题 = 多份独立试卷（不删旧卷）', async () => {
  const client = makeFakeClient();

  const first = await saveCheckinQuiz(client, makeCtx(), {
    id: 'q_first',
    studentId: 'stu_1',
    quizDate: '2026-10-27',
    subject: '数学',
    questions: QUESTIONS,
  });
  const second = await saveCheckinQuiz(client, makeCtx(), {
    id: 'q_second',
    studentId: 'stu_1',
    quizDate: '2026-10-27',
    subject: '数学',
    questions: QUESTIONS,
  });

  // 家长随便出几套：两套都是独立行，各自返回自己的 id（R2）。
  assert.equal(first.quiz.id, 'q_first');
  assert.equal(second.quiz.id, 'q_second', '第二套必须返回这次自己的 id');

  const inserts = client.queries.filter((q) => /insert into checkin_quiz/.test(q.sql));
  assert.equal(inserts.length, 2, '两次出题必须产生两条 INSERT');
  assert.deepEqual(
    inserts.map((q) => q.params[0]),
    ['q_first', 'q_second'],
    '两条 INSERT 的主键必须各自独立',
  );

  // 🔴 防回归：再也不能出现任何按 (student_id, quiz_date, subject) 的删除 ——
  // 那会让「多出一套」等于「抹掉上一套的成绩」。
  const deletes = client.queries.filter((q) => /^\s*delete\b/i.test(q.sql.trim()));
  assert.deepEqual(deletes, [], '多份并存语义下不允许删除旧卷');
});

test('打卡：作答数与题数不符 → quiz_version_conflict（不静默裁剪）', async () => {
  const client = makeFakeClient({
    quizRow: { id: 'q_1', student_id: 'stu_1', questions: QUESTIONS },
  });

  await assert.rejects(
    () =>
      submitCheckin(client, makeCtx(), {
        quizId: 'q_1',
        // 两道题只交一份 —— 现实里唯一来源是「手里的卷不是这一份」
        answers: [{ index: 0, picked: 'B' }],
      }),
    (error) => {
      assert.equal(error.code, 'quiz_version_conflict');
      return true;
    },
  );
});

test('打卡：作答 index 越界 → quiz_version_conflict（以前是静默丢弃）', async () => {
  const client = makeFakeClient({
    quizRow: { id: 'q_1', student_id: 'stu_1', questions: QUESTIONS },
  });

  await assert.rejects(
    () =>
      submitCheckin(client, makeCtx(), {
        quizId: 'q_1',
        answers: [
          { index: 0, picked: 'B' },
          { index: 1, picked: 'T' },
          // 第 3 份：8 题的卷交到 2 题的行上就是这个形状
          { index: 2, picked: 'A' },
        ],
      }),
    (error) => {
      assert.equal(error.code, 'quiz_version_conflict');
      return true;
    },
  );
});

test('打卡：提交分数由服务端复算，客户端传的 score 一律不采信', async () => {
  const client = makeFakeClient({
    quizRow: { id: 'q_1', student_id: 'stu_1', questions: QUESTIONS },
  });

  const result = await submitCheckin(client, makeCtx(), {
    quizId: 'q_1',
    // 第 1 题对（B）、第 2 题错（应 T，给 F）
    answers: [
      { index: 0, picked: 'B' },
      { index: 1, picked: 'F' },
    ],
    // 故意塞一个假分数：服务端不该读它
    score: 99,
    total: 99,
  });

  assert.equal(result.total, 2);
  assert.equal(result.score, 1, '只对了一道，分数必须是 1');
  assert.deepEqual(
    result.items.map((item) => item.correct),
    [true, false],
  );

  const inserted = client.queries.find((q) => /insert into checkin_result/.test(q.sql));
  assert.ok(inserted, '必须写入结果行');
  assert.deepEqual(
    inserted.params.slice(-2),
    [1, 2],
    '入库的 score/total 必须来自复算结果，不是请求体',
  );

  const updated = client.queries.find((q) => /update checkin_quiz set status/.test(q.sql));
  assert.ok(updated, '提交后必须把状态置为 done');

  // ima 归档改成提交后后台跑：响应里必须如实说「还没同步、已排队」，
  // 不能冒充已同步，也不能什么都不说。少这条断言，把 defer 那行删掉
  // 其余断言照样全绿。
  assert.equal(result.ima.synced, false);
  assert.equal(result.ima.reason, 'queued');
});

// ===== 计划 → 复习：打卡做错的题进错题本 =====
//
// 2026-11-12 定的边界：复习只从错题本出发；计划只从教材 / 家长范围出发，
// 但**计划里做错的题必须回到错题本**，否则孩子在打卡里错的东西
// 永远不会出现在复习队列里 —— 而他以为系统记住了。

const QUIZ_ROW = {
  id: 'ck_1',
  student_id: 'stu_1',
  subject: '历史',
  quiz_date: '2026-11-12',
  questions: QUESTIONS,
};

test('打卡做错的题进错题本：来源、题干、答案都带上', async () => {
  const client = makeFakeClient({ quizRow: QUIZ_ROW });
  const result = await submitCheckin(client, makeCtx(), {
    quizId: 'ck_1',
    answers: [
      { index: 0, picked: 'A' }, // 错（应 B）
      { index: 1, picked: '对' }, // 对
    ],
  });

  assert.equal(result.score, 1);
  assert.deepEqual(result.mistakes, { added: 1, failed: false });

  const inserts = client.queries.filter((q) => /insert into review_mistake/.test(q.sql));
  assert.equal(inserts.length, 1, '只写做错的那道');
  const p = inserts[0].params;
  assert.equal(p[0], 'rm_ck_1_0', 'id 由「哪份卷、第几题」决定，重复交卷不会多一行');
  assert.equal(p[2], '历史');
  assert.match(String(p[4]), /A\. 1/, '题干必须带选项 —— 只有 stem 的话这道题没法重做');
  assert.equal(p[5], 'B. 2', '正确答案写选项原文，不是一个字母');
  assert.equal(p[6], 'A. 1', '选的也要能读懂');
  assert.equal(p[8], '有理数混合运算', '知识点是组卷 / 举一反三的驱动键');
  assert.equal(p[12], 'ck_1', 'source_ref 记着这份卷，重复交卷才清得掉旧行');

  const del = client.queries.find((q) => /delete from review_mistake/.test(q.sql));
  assert.ok(del, '写之前先清掉这份卷上一次产出的错题');
  assert.deepEqual(del.params, ['stu_1', 'ck_1']);
});

test('打卡全对：不碰错题本，连事务边界都不用开', async () => {
  const client = makeFakeClient({ quizRow: QUIZ_ROW });
  const result = await submitCheckin(client, makeCtx(), {
    quizId: 'ck_1',
    answers: [
      { index: 0, picked: 'B' },
      { index: 1, picked: '对' },
    ],
  });

  assert.equal(result.score, 2);
  assert.deepEqual(result.mistakes, { added: 0, failed: false });
  assert.equal(
    client.queries.some((q) => /insert into review_mistake/.test(q.sql)),
    false,
  );
});

test('错题本写失败时交卷仍然成功，并如实报告「没记上」', async () => {
  // 028 没迁移 / RLS 配错时，丢的是归档，不该连成绩一起丢。
  // 但也不能静默：客户端要能说「错题没记上」，否则孩子以为复习里会有。
  const client = makeFakeClient({ quizRow: QUIZ_ROW, failMistakeInsert: true });
  const result = await submitCheckin(client, makeCtx(), {
    quizId: 'ck_1',
    answers: [
      { index: 0, picked: 'A' },
      { index: 1, picked: '对' },
    ],
  });

  assert.equal(result.score, 1, '成绩照常保存');
  assert.deepEqual(result.mistakes, { added: 0, failed: true });
  assert.ok(
    client.queries.some((q) => /insert into checkin_result/.test(q.sql)),
    '成绩行必须已经写了',
  );
  assert.ok(
    client.queries.some((q) => /rollback to savepoint/.test(q.sql)),
    '不回滚到 savepoint 的话，事务仍是 aborted —— 后续任何查询都会失败',
  );
});

test('打卡：提交不存在的 quizId 是 404，不是「成功但没存」', async () => {
  const client = makeFakeClient({ quizRow: null });

  await assert.rejects(
    () => submitCheckin(client, makeCtx(), { quizId: 'q_missing', answers: [] }),
    (error) => {
      assert.equal(error.code, 'not_found');
      return true;
    },
  );
});

test('打卡：ima 归档不进交卷请求，只登记学生 id（慢网络不再拖住提交）', async () => {
  process.env.IMA_CREDENTIAL_SECRET = 'test-secret-0123456789abcdefghijklmn';
  const { encryptCredential } = await import('../src/ima_repository.js');
  const enc = encryptCredential(
    { clientid: 'cid', apikey: 'akey' },
    process.env.IMA_CREDENTIAL_SECRET,
  );

  const client = makeFakeClient({
    quizRow: { id: 'q_1', student_id: 'stu_1', questions: QUESTIONS },
    studentKb: {
      student_id: 'stu_1',
      kb_id: 'kb_stu_1',
      kb_name: '伴学-学生-stu_1',
      owner_user_id: 'par_1',
    },
    credential: {
      clientid_enc: enc.clientidEnc,
      apikey_enc: enc.apikeyEnc,
      status: 'active',
      kb_owner_name: '伴学-学生-stu_1',
    },
  });

  const deferred = [];
  // 家长身份：凭证挂在他名下，学生是可见的孩子。
  const ctx = {
    ...makeCtx(),
    userId: 'par_1',
    role: 'parent',
    visibleStudents: ['stu_1'],
    // 网络坏掉：旧实现在这里 await ima，提交会跟着慢/失败。
    fetchImpl: async () => {
      throw new Error('network down');
    },
    deferImaArchive: (id) => deferred.push(id),
  };

  const started = Date.now();
  const result = await submitCheckin(client, ctx, {
    quizId: 'q_1',
    // ⚠️ 两道题必须交齐两份作答：交卷的硬不变量是「每题恰好一份」。
    answers: [
      { index: 0, picked: 'B' },
      { index: 1, picked: 'T' },
    ],
  });

  assert.equal(result.total, 2, '提交本身必须成功');
  assert.equal(result.score, 1);
  assert.equal(result.ima.synced, false, '交卷那一刻还没归档，不许冒充已同步');
  assert.equal(result.ima.reason, 'queued');
  assert.deepEqual(deferred, ['stu_1'], '只登记归档谁；身份由 app.js 用验签过的那份');
  assert.ok(
    !client.queries.some((q) => /from ima_credential|from ima_student_kb/.test(q.sql)),
    'ima 的查询绝不能出现在交卷事务里',
  );
  assert.ok(Date.now() - started < 500, '坏网络不能拖住交卷');

  delete process.env.IMA_CREDENTIAL_SECRET;
});

test('打卡：from > to 直接 400，不静默回空列表', async () => {
  const client = makeFakeClient();

  await assert.rejects(
    () => listCheckinResults(client, makeCtx(), { from: '2026-10-27', to: '2026-10-01' }),
    (error) => {
      assert.equal(error.code, 'bad_request');
      assert.match(error.message, /from 不能晚于 to/);
      return true;
    },
  );
});

test('打卡：取当天没有记录时返回空数组（不是抛错）', async () => {
  const client = makeFakeClient();

  const got = await getCheckinQuiz(client, makeCtx(), {
    studentId: 'stu_1',
    quizDate: '2026-10-27',
  });
  assert.deepEqual(got.quizzes, []);
});

/** 一条「当天有题」的库行（供读题接口用）。 */
const QUIZ_DAY_ROW = {
  id: 'quiz_1',
  student_id: 'stu_1',
  quiz_date: '2026-10-27',
  subject: '数学',
  // 库里存的是**归一化后**的快照（入库时 `normalizeQuestions` 已把「对」
  // 收敛成 T）—— 读题时原样下发，孩子端要用它判分。
  questions: [QUESTIONS[0], { ...QUESTIONS[1], answer: 'T' }],
  status: 'pending',
};

test('打卡：没交卷时也带答案（交卷那一刻要在本机判对错）', async () => {
  const client = makeFakeClient({ quizDayRows: [QUIZ_DAY_ROW], resultRow: null });

  const got = await getCheckinQuiz(client, makeCtx(), {
    studentId: 'stu_1',
    quizDate: '2026-10-27',
  });

  assert.equal(got.quizzes.length, 1);
  assert.equal(got.quizzes[0].result, null);
  const quiz = got.quizzes[0].quiz;
  assert.equal(quiz.questions.length, QUESTIONS.length);
  for (const [i, q] of quiz.questions.entries()) {
    // 答案必须随题下发：孩子交卷后不等网络就能看到对错。
    // 「答题时看不到」由客户端渲染层保证（见 checkin_question_card_test.dart）。
    assert.ok('answer' in q, `第 ${i + 1} 题没有答案 —— 本机判分会把它判成错`);
    assert.ok('analysis' in q, `第 ${i + 1} 题没有解析`);
  }

  // 题目本身要完整：只下发答案却把题剥成空壳，孩子连题都看不到，
  // 而接口仍然「成功」。
  assert.equal(quiz.questions[0].stem, QUESTIONS[0].stem);
  assert.deepEqual(quiz.questions[0].options, QUESTIONS[0].options);
  assert.equal(quiz.questions[0].knowledge, QUESTIONS[0].knowledge);
  assert.equal(quiz.questions[1].type, 'judge');
});

test('打卡：下发的那份与库里那份一致（同一个快照，不另拼）', async () => {
  const client = makeFakeClient({ quizDayRows: [QUIZ_DAY_ROW], resultRow: null });

  const got = await getCheckinQuiz(client, makeCtx(), {
    studentId: 'stu_1',
    quizDate: '2026-10-27',
  });

  assert.deepEqual(
    got.quizzes[0].quiz.questions,
    QUIZ_DAY_ROW.questions,
    '两处各拼一份的话，库里判分和孩子看到的题迟早会不一样',
  );
});

test('打卡：一天多份（分科目）全部返回，按发起顺序', async () => {
  const client = makeFakeClient({
    quizDayRows: [
      QUIZ_DAY_ROW,
      { ...QUIZ_DAY_ROW, id: 'quiz_2', subject: '英语' },
    ],
  });

  const got = await getCheckinQuiz(client, makeCtx(), {
    studentId: 'stu_1',
    quizDate: '2026-10-27',
  });

  assert.equal(got.quizzes.length, 2, '一天可以多份（家长分科目出题），必须全部返回');
  assert.equal(got.quizzes[0].quiz.subject, '数学');
  assert.equal(got.quizzes[1].quiz.subject, '英语');
});

test('打卡：交卷后读题带答案（复盘要看对错）', async () => {
  const client = makeFakeClient({
    quizDayRows: [{ ...QUIZ_DAY_ROW, status: 'done' }],
    resultRow: {
      answers: [{ index: 0, picked: 'B' }],
      score: 2,
      total: 2,
      submitted_at: '2026-10-27T01:00:00.000Z',
    },
  });

  const got = await getCheckinQuiz(client, makeCtx(), {
    studentId: 'stu_1',
    quizDate: '2026-10-27',
  });

  const entry = got.quizzes[0];
  assert.equal(entry.quiz.questions[0].answer, 'B');
  assert.equal(entry.quiz.questions[0].analysis, '直接相加');
  assert.equal(entry.result.score, 2);

  // 🔴 逐题明细必须从存档派生回传（2026-10-27 用户报的：重开页面只剩
  // 一句汇总，看不到是哪个题错）。第 1 题选了 B（对）、第 2 题没交
  // （按规则恒为错）。
  assert.equal(entry.result.items.length, 2);
  assert.equal(entry.result.items[0].picked, 'B');
  assert.equal(entry.result.items[0].correct, true);
  assert.equal(entry.result.items[1].picked, '');
  assert.equal(entry.result.items[1].correct, false);
  assert.equal(entry.result.items[1].answer, 'T', '正确答案要随明细给出，不然复盘无从谈起');
  assert.equal(entry.result.items[0].knowledge, '有理数混合运算');
});

// ===== 跨天列表 / 未完成与已完成 / 分页 =====
//
// 2026-10-29 用户报：「家长头天出的题，孩子第二天打开看不到，只有一个
// 自己出题」——根因是查询按 `quizDate = 今天` 过滤死了。下面这几条盯的是
// 新口径：不传日期就是**全部**，传了才按那一天过滤。

/** 一份「已交卷」的行：行上带 `_result`，假 client 据此判 done。 */
const DONE_RESULT = {
  answers: [{ index: 0, picked: 'B' }],
  score: 1,
  total: 2,
  submitted_at: '2026-10-28T12:00:00.000Z',
};

const doneRow = (id, date) => ({
  ...QUIZ_DAY_ROW,
  id,
  quiz_date: date,
  status: 'done',
  _result: DONE_RESULT,
});

test('打卡：不传 quizDate 时跨天返回（头天出的题第二天还在）', async () => {
  const client = makeFakeClient({
    quizDayRows: [
      { ...QUIZ_DAY_ROW, id: 'q_1028', quiz_date: '2026-10-28' },
      { ...QUIZ_DAY_ROW, id: 'q_1029', quiz_date: '2026-10-29' },
    ],
  });

  const got = await getCheckinQuiz(client, makeCtx(), { studentId: 'stu_1' });

  assert.deepEqual(
    got.quizzes.map((one) => one.quiz.id),
    ['q_1028', 'q_1029'],
    '跨天不返回的话，家长昨天出的题孩子今天就再也做不到了',
  );
  assert.equal(got.total, 2);
});

test('打卡：传了 quizDate 仍然只回那一天（老客户端行为不变）', async () => {
  const client = makeFakeClient({
    quizDayRows: [
      { ...QUIZ_DAY_ROW, id: 'q_1028', quiz_date: '2026-10-28' },
      { ...QUIZ_DAY_ROW, id: 'q_1029', quiz_date: '2026-10-29' },
    ],
  });

  const got = await getCheckinQuiz(client, makeCtx(), {
    studentId: 'stu_1',
    quizDate: '2026-10-29',
  });

  assert.deepEqual(got.quizzes.map((one) => one.quiz.id), ['q_1029']);
  assert.equal(got.total, 1);
});

test('打卡：status=pending / done 各自只回对应那一半', async () => {
  const rows = [
    { ...QUIZ_DAY_ROW, id: 'q_pending', quiz_date: '2026-10-28' },
    doneRow('q_done', '2026-10-28'),
  ];

  const pending = await getCheckinQuiz(makeFakeClient({ quizDayRows: rows }), makeCtx(), {
    studentId: 'stu_1',
    status: 'pending',
  });
  assert.deepEqual(pending.quizzes.map((one) => one.quiz.id), ['q_pending']);
  assert.equal(pending.total, 1, 'total 必须是**过滤后**的数，否则分页永远算不准');

  const done = await getCheckinQuiz(makeFakeClient({ quizDayRows: rows }), makeCtx(), {
    studentId: 'stu_1',
    status: 'done',
  });
  assert.deepEqual(done.quizzes.map((one) => one.quiz.id), ['q_done']);
  assert.equal(done.total, 1);
  // 已完成的那份要带成绩，否则列表里显示不出得分。
  assert.equal(done.quizzes[0].result?.score, 1);
});

test('打卡：limit/offset 翻页，hasMore 按 total 算', async () => {
  const rows = Array.from({ length: 12 }, (_, i) => doneRow(`q_${i}`, '2026-10-28'));

  const first = await getCheckinQuiz(makeFakeClient({ quizDayRows: rows }), makeCtx(), {
    studentId: 'stu_1',
    status: 'done',
    limit: 10,
    offset: 0,
  });
  assert.equal(first.quizzes.length, 10);
  assert.equal(first.total, 12);
  assert.equal(first.hasMore, true, '还有 2 条没取，客户端必须知道');

  const second = await getCheckinQuiz(makeFakeClient({ quizDayRows: rows }), makeCtx(), {
    studentId: 'stu_1',
    status: 'done',
    limit: 10,
    offset: 10,
  });
  assert.equal(second.quizzes.length, 2);
  assert.equal(second.hasMore, false);
});

test('打卡：limit=0 = 不限（未完成那份要一次拿全）', async () => {
  const client = makeFakeClient({
    quizDayRows: Array.from({ length: 8 }, (_, i) => ({
      ...QUIZ_DAY_ROW,
      id: `q_${i}`,
    })),
  });

  const got = await getCheckinQuiz(client, makeCtx(), {
    studentId: 'stu_1',
    status: 'pending',
    limit: 0,
  });

  assert.equal(got.quizzes.length, 8);
  assert.equal(got.hasMore, false, '不限量时不存在"下一页"');
});

test('打卡：limit 超过上限直接 400（不静默截断）', async () => {
  await assert.rejects(
    () => getCheckinQuiz(makeFakeClient(), makeCtx(), { studentId: 'stu_1', limit: 999 }),
    (error) => {
      assert.equal(error.code, 'bad_request');
      assert.match(error.message, /limit/);
      return true;
    },
  );
});
