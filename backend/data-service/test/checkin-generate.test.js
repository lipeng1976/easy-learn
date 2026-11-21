import test from 'node:test';
import assert from 'node:assert/strict';

import { generateCheckin, listCheckinSeeds } from '../src/routes/checkin.js';
import { createAiGatewayClient } from '../src/ai_client.js';

/**
 * 服务端出题（`POST /data/checkin/generate`）。
 *
 * 这条路存在的理由是**链路短**：错题聚合 → 调模型 → 落库一次做完，
 * 客户端不用先有本地错题本。
 *
 * 题目是**带答案**下发的 —— 交卷时孩子那台设备要立刻判出对错，不等网络。
 * 「答题时看不到答案」由客户端渲染层负责，判据在
 * `test/checkin_question_card_test.dart`（这里测不到）。
 *
 * 所以本文件最硬的两条判据是：
 *   ① 下发的那份与入库那份**逐字一致**（不是各拼一份）；
 *   ② 网关的 `rejected` 不回传（那里有被拒坏题的原文，是调试信息不是题目）。
 *
 * ⚠️ 假 client 证明不了 RLS，也证明不了 SQL 能跑（`$2::date` 那个坑就是
 * 假 client 看不见的）。真库 + 真 HTTP 的判据在
 * `scripts/probe-checkin-e2e.mjs`。
 */

const CTX_BASE = {
  userId: 'stu_1',
  role: 'student',
  visibleStudents: ['stu_1'],
  students: ['stu_1'],
  authHeader: 'Bearer caller-token',
};

/** 网关**会**给的那种形状：带答案与解析。 */
const GATEWAY_QUESTIONS = [
  {
    type: 'choice',
    stem: '$1+1=?$',
    options: ['1', '2', '3', '4'],
    answer: 'B',
    knowledge: '有理数混合运算',
    analysis: '直接相加，1+1=2 所以选 B',
  },
  {
    type: 'judge',
    stem: '判断：$0.5=\\frac{1}{2}$',
    options: ['正确', '错误'],
    answer: 'T',
    knowledge: '分数的意义',
    analysis: '同一个数',
  },
];

const MISTAKES = [
  { knowledge_point: '解一元一次方程', wrong_count: 3, wrong_reason: '移项没变号' },
  { knowledge_point: '解一元一次方程', wrong_count: 2, wrong_reason: '移项忘记变号，左边减了右边没减' },
  { knowledge_point: '有理数混合运算', wrong_count: 1, wrong_reason: '先算加减后算乘除' },
  // `wrong_count` 为 0 的历史数据要按「错过一次」计，否则这个知识点永远排最后。
  { knowledge_point: '幂的运算', wrong_count: 0, wrong_reason: '' },
  // 空知识点要跳过（老数据的默认值就是空串）
  { knowledge_point: '   ', wrong_count: 9, wrong_reason: '不该出现' },
];

/**
 * 家长在「学科范围」里存下来的知识点（`subject_scope.points`）。
 *
 * 计划的内容**只能**来自教材或家长指定；学生自发起（不带 `knowledgePoints`）
 * 时服务端读的就是这一份。默认给四个点，让老用例等价于「家长已经配好范围」
 * —— 那正是线上大多数情形的起点。
 */
const SCOPE_POINTS = ['有理数混合运算', '分数的意义', '解一元一次方程', '幂的运算'];

function makeFakeClient({ mistakes = MISTAKES, textbook = null, scopePoints = SCOPE_POINTS } = {}) {
  const queries = [];
  return {
    queries,
    query(sql, params = []) {
      queries.push({ sql, params });
      // 教材取点（`resolveTextbookPoints`）与家长范围（`scopePointsOf`）都查
      // `subject_scope`，必须按 select 列分开匹配 —— 混成一条的话，
      // 「配了书」和「填了知识点」会互相顶掉，而两种情形在界面上长得一样。
      if (/select points from subject_scope/.test(sql)) {
        return Promise.resolve(
          scopePoints.length === 0
            ? { rowCount: 0, rows: [] }
            : { rowCount: 1, rows: [{ points: scopePoints }] },
        );
      }
      if (/select book_id, start_unit_no, units_per_day/.test(sql)) {
        return Promise.resolve({ rowCount: textbook ? 1 : 0, rows: textbook ? [textbook.scope] : [] });
      }
      if (/from subject_unit/.test(sql)) {
        return Promise.resolve({ rows: textbook?.units ?? [] });
      }
      if (/from review_mistake/.test(sql)) {
        return Promise.resolve({ rowCount: mistakes.length, rows: mistakes });
      }
      if (/delete from checkin_result/.test(sql)) {
        return Promise.resolve({ rowCount: 0, rows: [] });
      }
      if (/insert into checkin_quiz/.test(sql)) {
        return Promise.resolve({
          rowCount: 1,
          rows: [{
            id: params[0],
            student_id: params[1],
            quiz_date: params[3],
            subject: params[4],
            difficulty: params[5],
            questions: JSON.parse(params[6]),
            status: 'pending',
          }],
        });
      }
      return Promise.resolve({ rowCount: 1, rows: [] });
    },
  };
}

function makeGateway({ questions = GATEWAY_QUESTIONS, error = null } = {}) {
  const calls = [];
  return {
    calls,
    async postJson(path, opts) {
      calls.push({ path, opts });
      if (error) throw error;
      return {
        data: { questions },
        // 网关的 `rejected` 里有题干片段与**被拒的答案原文**，
        // 正好用来验证它不会漏给客户端。
        meta: { keptQuestions: questions.length, rejected: ['第 9 题：答案「C」不在选项范围内'] },
      };
    },
  };
}

function makeCtx(overrides = {}) {
  return { ...CTX_BASE, aiGateway: makeGateway(), ...overrides };
}

const BODY = { studentId: 'stu_1', quizDate: '2026-10-27', subject: '数学', count: 2 };

// 11-12 起十科都能出题（只出选择题/判断题）。出题模板本来就没有科目分支，
// 但「候选知识点按科过滤」和「subject 原样传给网关」两条得各自有判据 ——
// 漏了任一条，语文色块会出一份按数学知识点出的题，界面上看不出来。

test('出题：非数学科目也能出，subject 原样传给网关并原样入库', async () => {
  const client = makeFakeClient();
  const ctx = makeCtx();

  const result = await generateCheckin(client, ctx, { ...BODY, subject: '历史' });

  assert.equal(ctx.aiGateway.calls[0].opts.body.subject, '历史');
  assert.equal(result.quiz.subject, '历史', '入库的科目必须是选中的那一科');
});

test('候选知识点：带 subject 时只查这一科，不传保持旧行为', async () => {
  const client = makeFakeClient();
  const ctx = makeCtx();

  await listCheckinSeeds(client, ctx, { studentId: 'stu_1', subject: '历史' });
  const filtered = client.queries.find((q) => /from review_mistake/.test(q.sql));
  assert.match(filtered.sql, /and subject = \$2/, '切了学科就必须按科过滤');
  assert.deepEqual(filtered.params, ['stu_1', '历史']);

  // 老客户端不传 subject：全科合并（发起页默认数学时也走这条，保持兼容）。
  const legacyClient = makeFakeClient();
  await listCheckinSeeds(legacyClient, makeCtx(), { studentId: 'stu_1' });
  const legacy = legacyClient.queries.find((q) => /from review_mistake/.test(q.sql));
  assert.doesNotMatch(legacy.sql, /and subject =/);
  assert.deepEqual(legacy.params, ['stu_1']);
});

test('出题：下发的题目带答案与解析（孩子端交卷时要本机判分）', async () => {
  const client = makeFakeClient();
  const ctx = makeCtx();

  const result = await generateCheckin(client, ctx, BODY);

  assert.equal(result.quiz.questions.length, 2);
  for (const q of result.quiz.questions) {
    assert.ok('answer' in q, '答案必须随题下发 —— 交卷那一刻要在本机判对错');
    assert.ok('analysis' in q, '解析也跟着下发，复盘要用');
  }
  assert.equal(result.quiz.questions[0].answer, 'B');
  assert.equal(result.quiz.questions[1].answer, 'T');
  // 字段集合固定：多出来的字段会一路漂到界面上。
  assert.deepEqual(
    Object.keys(result.quiz.questions[0]).sort(),
    ['analysis', 'answer', 'knowledge', 'options', 'stem', 'type'],
  );
});

test('出题：下发的那份与入库那份逐字一致（同一份快照，不另拼）', async () => {
  const client = makeFakeClient();
  const result = await generateCheckin(client, makeCtx(), BODY);

  const insert = client.queries.find((q) => /insert into checkin_quiz/.test(q.sql));
  assert.ok(insert, '必须落库');
  const stored = JSON.parse(insert.params[6]);
  assert.deepEqual(
    result.quiz.questions,
    stored,
    '两处各拼一份的话，库里判分和孩子看到的题迟早会不一样',
  );
});

test('出题：网关的 rejected 不回给客户端（那里有答案原文）', async () => {
  const result = await generateCheckin(makeFakeClient(), makeCtx(), BODY);

  assert.equal('rejected' in result, false);
  assert.equal(JSON.stringify(result).includes('不在选项范围内'), false);
  // 只回计数，够排查「这次出了几道题」。
  assert.equal(result.generated.kept, 2);
});

test('出题：转发调用者那张票，身份是同一个（不另签服务票）', async () => {
  const ctx = makeCtx();
  await generateCheckin(makeFakeClient(), ctx, BODY);

  const call = ctx.aiGateway.calls[0];
  assert.equal(call.path, '/ai/checkin/generate');
  assert.equal(call.opts.authHeader, 'Bearer caller-token');
  assert.equal(call.opts.studentId, 'stu_1', 'X-Student-Id 给没开强鉴权的本机栈用');
});

test('计划的范围只来自家长配置：错题本里错得再多也不会被拿来凑数', async () => {
  // 2026-11-12 划定的边界：**复习**从错题本出发，**计划**只从教材 /
  // 家长指定的知识点出发。以前没有范围时会静默回落到同科错题，
  // 于是历史（还没学过 ⇒ 必然没有错题）永远出不了题，而家长明明配了书。
  const many = [
    { knowledge_point: 'A', wrong_count: 1, wrong_reason: '' },
    { knowledge_point: 'B', wrong_count: 5, wrong_reason: '' },
    { knowledge_point: 'C', wrong_count: 2, wrong_reason: '' },
    { knowledge_point: 'D', wrong_count: 4, wrong_reason: '' },
    { knowledge_point: 'E', wrong_count: 3, wrong_reason: '' },
    { knowledge_point: 'F', wrong_count: 6, wrong_reason: '' },
    { knowledge_point: 'G', wrong_count: 7, wrong_reason: '' },
  ];
  const ctx = makeCtx();
  await generateCheckin(makeFakeClient({ mistakes: many }), ctx, BODY);

  const items = ctx.aiGateway.calls[0].opts.body.items;
  assert.deepEqual(
    items.map((i) => i.knowledge),
    SCOPE_POINTS,
    '错题本是复习的原料；让它出计划题等于把两条线的来源混在一起，界面看不出来',
  );
});

test('错题记录仍然跟着范围走：同一知识点的错次相加，错因留最长的那条', async () => {
  const ctx = makeCtx();
  await generateCheckin(makeFakeClient(), ctx, BODY);

  const items = ctx.aiGateway.calls[0].opts.body.items;
  const equation = items.find((i) => i.knowledge === '解一元一次方程');
  assert.equal(equation.wrongCount, 5, '3 + 2');
  assert.equal(equation.wrongReason, '移项忘记变号，左边减了右边没减', '最长的那条信息量最大');
  assert.equal(items.some((i) => i.knowledge.trim() === ''), false);
  // wrong_count = 0 的历史数据按「错过一次」算，否则永远轮不到它
  assert.equal(items.find((i) => i.knowledge === '幂的运算').wrongCount, 1);
});

// ===== 家长指定范围（方案 A 的核心）=====

test('学生自发起（不带知识点）：用范围页里存下来的那一份，而不是错题本', async () => {
  // 孩子点「出 5 道题」时客户端不带 knowledgePoints。服务端必须补上家长
  // 在范围页配的那份 —— 否则家长配的范围只对家长自己的入口生效，
  // 孩子那条路按别的来源出题，而两条路在界面上长得一模一样。
  const client = makeFakeClient({
    scopePoints: ['第 7 课 百家争鸣', '第 8 课 秦统一中国'],
  });
  const ctx = makeCtx({
    aiGateway: makeGateway({
      questions: [
        {
          type: 'choice',
          stem: '“百家争鸣”出现在哪个时期？',
          options: ['春秋战国', '秦汉', '隋唐', '明清'],
          answer: 'A',
          knowledge: '第 7 课 百家争鸣',
        },
        {
          type: 'judge',
          stem: '秦朝是中国历史上第一个统一的中央集权王朝。',
          options: ['正确', '错误'],
          answer: 'T',
          knowledge: '第 8 课 秦统一中国',
        },
      ],
    }),
  });

  const result = await generateCheckin(client, ctx, { ...BODY, subject: '历史' });

  assert.deepEqual(
    ctx.aiGateway.calls[0].opts.body.items.map((i) => i.knowledge),
    ['第 7 课 百家争鸣', '第 8 课 秦统一中国'],
  );
  assert.equal(result.quiz.questions.length, 2);
  assert.equal(
    client.queries.some((q) => /select points from subject_scope/.test(q.sql)),
    true,
    '没有显式知识点时必须去读家长存下来的范围',
  );
});


test('家长指定知识点：按给定顺序出题，错题本里没有的也保留', async () => {
  const client = makeFakeClient();
  const ctx = makeCtx();

  const result = await generateCheckin(client, ctx, {
    ...BODY,
    knowledgePoints: ['幂的运算', '下周要考的分式方程', '有理数混合运算'],
  });

  const items = ctx.aiGateway.calls[0].opts.body.items;
  assert.deepEqual(
    items.map((i) => i.knowledge),
    ['幂的运算', '下周要考的分式方程', '有理数混合运算'],
    '顺序就是优先级 —— 家长把哪个放前面，就先考哪个',
  );
  assert.equal(items[0].wrongCount, 1, '错题本里有的仍然带上累计错次');
  assert.equal(
    items[1].wrongCount,
    0,
    '错题本没有这个知识点：如实给 0（家长是在让孩子提前练）',
  );
  assert.equal(result.generated.mode, 'manual');
  assert.equal(result.generated.seeds, 3);
});

test('家长指定知识点时，错题本为空也能出题', async () => {
  // 这一条是「家长按学生学习情况出题」的关键：错题本只能反映已经错过什么，
  // 而家长可能想练一个还没考过的知识点。此时不该报 no_seed。
  const client = makeFakeClient({ mistakes: [] });
  const ctx = makeCtx({
    aiGateway: makeGateway({
      questions: [
        {
          type: 'choice',
          stem: '$(-2)^3$ 等于？',
          options: ['-8', '8', '-6', '6'],
          answer: 'A',
          knowledge: '负数乘方',
          analysis: '负数的奇次幂还是负数',
        },
      ],
    }),
  });

  const result = await generateCheckin(client, ctx, {
    ...BODY,
    knowledgePoints: ['负数乘方'],
  });

  assert.equal(result.quiz.questions.length, 1);
  assert.equal(ctx.aiGateway.calls[0].opts.body.items[0].knowledge, '负数乘方');
  assert.equal(result.quiz.questions[0].knowledge, '负数乘方');
});

test('家长重复勾同一个知识点只算一个，空串被忽略', async () => {
  const ctx = makeCtx();
  await generateCheckin(makeFakeClient(), ctx, {
    ...BODY,
    knowledgePoints: ['幂的运算', '幂的运算', '  ', '有理数混合运算'],
  });

  const items = ctx.aiGateway.calls[0].opts.body.items;
  assert.deepEqual(items.map((i) => i.knowledge), ['幂的运算', '有理数混合运算']);
});

test('家长指定范围时，模型多出来的范围外题目被丢掉', async () => {
  // 模型偶尔会「顺手」多出一道相关但没被要求的题。放行它等于静默违背
  // 家长的意思，而那道题本身看起来完全合理 —— 界面上发现不了。
  const ctx = makeCtx({
    aiGateway: makeGateway({
      questions: [
        { type: 'choice', stem: '范围内的题', options: ['1', '2'], answer: 'A', knowledge: '幂的运算' },
        { type: 'choice', stem: '范围外的题', options: ['1', '2'], answer: 'A', knowledge: '三角形面积' },
      ],
    }),
  });

  const result = await generateCheckin(makeFakeClient(), ctx, {
    ...BODY,
    knowledgePoints: ['幂的运算'],
  });

  assert.equal(result.quiz.questions.length, 1);
  assert.equal(result.quiz.questions[0].stem, '范围内的题');
  assert.equal(result.generated.kept, 1);
});

test('模型出的题全在范围外 → 502，不存一份违背家长意图的打卡', async () => {
  const client = makeFakeClient();
  const ctx = makeCtx({
    aiGateway: makeGateway({
      questions: [
        { type: 'choice', stem: '跑偏', options: ['1', '2'], answer: 'A', knowledge: '三角形面积' },
      ],
    }),
  });

  await assert.rejects(
    () => generateCheckin(client, ctx, { ...BODY, knowledgePoints: ['幂的运算'] }),
    (e) => {
      assert.equal(e.code, 'schema_violation');
      assert.equal(e.status, 502);
      return true;
    },
  );
  assert.equal(client.queries.some((q) => /insert into checkin_quiz/.test(q.sql)), false);
});

test('知识点超过 6 个直接 400，不悄悄砍掉几个', async () => {
  const ctx = makeCtx();
  await assert.rejects(
    () =>
      generateCheckin(makeFakeClient(), ctx, {
        ...BODY,
        knowledgePoints: ['1', '2', '3', '4', '5', '6', '7'],
      }),
    (e) => {
      assert.equal(e.code, 'bad_request');
      // 静默截断的话，家长以为 7 个都考了，而实际只有 6 个 —— 且不会报错。
      assert.match(e.message, /最多 6 个/);
      return true;
    },
  );
  assert.equal(ctx.aiGateway.calls.length, 0);
});

// ===== 难度 =====

test('难度：写进网关请求、落库、并随打卡返回', async () => {
  const client = makeFakeClient();
  const ctx = makeCtx();

  const result = await generateCheckin(client, ctx, { ...BODY, difficulty: '提高' });

  assert.equal(ctx.aiGateway.calls[0].opts.body.difficulty, '提高');
  const insert = client.queries.find((q) => /insert into checkin_quiz/.test(q.sql));
  assert.equal(insert.params[5], '提高', '难度是出题参数，事后从题目反推不出来');
  assert.equal(result.quiz.difficulty, '提高');
});

test('难度只认三个词，其余 400（别让模型自己猜「中等」）', async () => {
  const ctx = makeCtx();
  await assert.rejects(
    () => generateCheckin(makeFakeClient(), ctx, { ...BODY, difficulty: '中等' }),
    (e) => {
      assert.equal(e.code, 'bad_request');
      assert.match(e.message, /基础 \/ 提高 \/ 挑战/);
      return true;
    },
  );
  assert.equal(ctx.aiGateway.calls.length, 0);
});

test('不指定难度时传空串，不硬塞一个「基础」', async () => {
  const ctx = makeCtx();
  const result = await generateCheckin(makeFakeClient(), ctx, BODY);

  assert.equal(ctx.aiGateway.calls[0].opts.body.difficulty, '');
  assert.equal(result.quiz.difficulty, '');
});

// ===== 教材范围（历史/政治这类「还没学过、不可能有错题」的科目）=====

test('历史教材只有章节标题、错题本为空时照样能出题', async () => {
  // 真实事故（11-12）：中国历史 22 节的骨架 MD 只写了 `## 第N课 标题`，
  // 一行「考点：」都没有。旧实现把整本书判成「没配考点」→ 退回错题本 →
  // 历史没有错题 → 点一次报一次「错题本还是空的」。书明明配好了，从没生效。
  const client = makeFakeClient({
    mistakes: [],
    textbook: {
      scope: { book_id: 'tb_his', start_unit_no: 7, units_per_day: 1 },
      units: [{ unit_no: 7, title: '第 7 课 百家争鸣', summary: '' }],
    },
  });
  const ctx = makeCtx({
    aiGateway: makeGateway({
      questions: [{
        type: 'choice',
        stem: '“百家争鸣”出现在哪个时期？',
        options: ['春秋战国', '秦汉', '隋唐', '明清'],
        answer: 'A',
        knowledge: '第 7 课 百家争鸣',
      }],
    }),
  });

  const result = await generateCheckin(client, ctx, { ...BODY, subject: '历史', count: 3 });

  assert.deepEqual(
    ctx.aiGateway.calls[0].opts.body.items.map((i) => i.knowledge),
    ['第 7 课 百家争鸣'],
    '章节标题本身就是范围 —— 没有「考点：」行不等于没有内容',
  );
  assert.equal(result.quiz.questions.length, 1);
  assert.equal(
    client.queries.some((q) => /from review_mistake/.test(q.sql) && q.params.length > 1),
    true,
    '错题本仍在按科查，只是它为空不再挡路',
  );

  const update = client.queries.find((q) => /update subject_scope/.test(q.sql));
  assert.equal(update.params[2], 8, '出完题游标必须推到下一课，否则天天考同一节');
});

test('范围比较忽略空白：模型把「第 7 课」写成「第7课」仍算范围内', async () => {
  const ctx = makeCtx({
    aiGateway: makeGateway({
      questions: [{
        type: 'judge',
        stem: '百家争鸣发生在春秋战国时期。',
        options: ['正确', '错误'],
        answer: 'T',
        knowledge: '第7课百家争鸣',
      }],
    }),
  });

  const result = await generateCheckin(makeFakeClient(), ctx, {
    ...BODY,
    subject: '历史',
    knowledgePoints: ['第 7 课 百家争鸣'],
  });

  assert.equal(result.quiz.questions.length, 1, '只是空格不同就整单丢掉，家长只会看到「模型没给合格题目」');
  assert.equal(
    result.quiz.questions[0].knowledge,
    '第 7 课 百家争鸣',
    '必须存回请求里的原文：客户端与错题归档都按这个字符串关联',
  );
});

// ===== 候选列表 =====

test('候选列表返回全部错题知识点（家长要从更大的集合里挑）', async () => {
  const many = Array.from({ length: 10 }, (_, i) => ({
    knowledge_point: `知识点${i + 1}`,
    wrong_count: i + 1,
    wrong_reason: '',
  }));

  const out = await listCheckinSeeds(makeFakeClient({ mistakes: many }), makeCtx(), {
    studentId: 'stu_1',
  });

  // 出题时截到 6 个；候选不能也截 —— 只给 6 个再让人从中挑 6 个等于没得选。
  assert.equal(out.seeds.length, 10);
  assert.equal(out.total, 10);
  assert.equal(out.seeds[0].knowledge, '知识点10', '按累计错次降序');
  assert.equal(out.seeds[0].wrongCount, 10);
});

test('出题：一条范围都没有时不调网关、不落库，并且按科目说清下一步', async () => {
  // 教材、家长范围、临时勾选全都没有 ⇒ 不编题。错题本里有没有都不算范围。
  const client = makeFakeClient({ mistakes: [], scopePoints: [] });
  const ctx = makeCtx();
  await assert.rejects(
    () => generateCheckin(client, ctx, { ...BODY, subject: '历史' }),
    (e) => {
      assert.equal(e.code, 'bad_request');
      assert.equal(e.details?.reason, 'no_seed');
      assert.equal(e.details?.subject, '历史', '客户端要按科目给引导');
      // ⚠️ 不能说「先录几道错题」：历史这种还没学过的科目**本来就没有错题**，
      // 那条路对它不存在。家长照着做只会继续卡住 —— 报错要指向真能做的事。
      assert.match(e.message, /历史还没有出题范围/);
      assert.match(e.message, /教材/);
      assert.doesNotMatch(e.message, /错题本还是空的/);
      return true;
    },
  );
  assert.equal(ctx.aiGateway.calls.length, 0, '没有知识点就没有出题的锚点');
  assert.equal(client.queries.some((q) => /insert into checkin_quiz/.test(q.sql)), false);
});

test('出题：网关失败原样透传错误码，且不落库（不留半截打卡）', async () => {
  const client = makeFakeClient();
  const ctx = makeCtx({
    aiGateway: makeGateway({
      error: Object.assign(new Error('模型超时'), { code: 'model_timeout', retryable: true, status: 504 }),
    }),
  });

  await assert.rejects(
    () => generateCheckin(client, ctx, BODY),
    (e) => {
      assert.equal(e.code, 'model_timeout');
      return true;
    },
  );
  assert.equal(client.queries.some((q) => /insert into checkin_quiz/.test(q.sql)), false);
});

test('出题：网关给了不合格的题 → 502 schema_violation，不是 400', async () => {
  const client = makeFakeClient();
  const ctx = makeCtx({
    aiGateway: makeGateway({
      questions: [{
        type: 'choice',
        stem: '没有答案这一题',
        options: ['1', '2'],
        answer: '',
        knowledge: 'x',
      }],
    }),
  });

  await assert.rejects(
    () => generateCheckin(client, ctx, BODY),
    (e) => {
      // 400 会让客户端以为是自己请求写错了，而其实是模型/网关的问题
      assert.equal(e.code, 'schema_violation');
      assert.equal(e.status, 502);
      return true;
    },
  );
  assert.equal(client.queries.some((q) => /insert into checkin_quiz/.test(q.sql)), false);
});

test('出题：这台部署没接上网关时明确报 model_not_enabled', async () => {
  await assert.rejects(
    () => generateCheckin(makeFakeClient(), makeCtx({ aiGateway: null }), BODY),
    (e) => {
      assert.equal(e.code, 'model_not_enabled');
      assert.equal(e.details?.configMissing, 'AI_GATEWAY_BASE_URL');
      return true;
    },
  );
});

test('出题：越权的 studentId 是 403，连网关都不该被调到', async () => {
  const ctx = makeCtx();
  await assert.rejects(
    () => generateCheckin(makeFakeClient(), ctx, { ...BODY, studentId: 'someone_else' }),
    (e) => {
      assert.equal(e.code, 'forbidden');
      return true;
    },
  );
  assert.equal(ctx.aiGateway.calls.length, 0);
});

test('网关客户端：没配基址时报配置缺失，不去猜一个地址', async () => {
  const gateway = createAiGatewayClient({ baseUrl: '', fetchImpl: async () => {
    throw new Error('不该发起请求');
  } });
  await assert.rejects(
    () => gateway.postJson('/ai/checkin/generate', {}),
    (e) => {
      assert.equal(e.code, 'model_not_enabled');
      assert.equal(e.details?.configMissing, 'AI_GATEWAY_BASE_URL');
      return true;
    },
  );
});

test('网关客户端：超时归成 model_timeout（可重试），不是笼统的网络错误', async () => {
  const gateway = createAiGatewayClient({
    baseUrl: 'http://127.0.0.1:1',
    timeoutMs: 5,
    fetchImpl: async () => {
      const e = new Error('timed out');
      e.name = 'TimeoutError';
      throw e;
    },
  });
  await assert.rejects(
    () => gateway.postJson('/ai/checkin/generate', {}),
    (e) => {
      assert.equal(e.code, 'model_timeout');
      assert.equal(e.retryable, true);
      return true;
    },
  );
});

test('网关客户端：网关回 401 时归成 model_auth_failed（重登录没用，只能运维）', async () => {
  const gateway = createAiGatewayClient({
    baseUrl: 'http://127.0.0.1:1',
    fetchImpl: async () => ({
      ok: false,
      status: 401,
      json: async () => ({ ok: false, error: { code: 'unauthorized', message: '票无效' } }),
    }),
  });
  await assert.rejects(
    () => gateway.postJson('/ai/checkin/generate', {}),
    (e) => {
      assert.equal(e.code, 'model_auth_failed');
      assert.equal(e.retryable, false, '让用户去重新登录只会白折腾');
      return true;
    },
  );
});

test('网关客户端：5xx 归成 model_unavailable（可重试）', async () => {
  const gateway = createAiGatewayClient({
    baseUrl: 'http://127.0.0.1:1',
    fetchImpl: async () => ({
      ok: false,
      status: 503,
      json: async () => { throw new Error('不是 JSON'); },
    }),
  });
  await assert.rejects(
    () => gateway.postJson('/ai/checkin/generate', {}),
    (e) => {
      assert.equal(e.code, 'model_unavailable');
      assert.equal(e.retryable, true);
      return true;
    },
  );
});
