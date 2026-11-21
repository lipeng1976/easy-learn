import assert from 'node:assert/strict';
import test from 'node:test';

import { loadConfig } from '../src/config.js';
import { createGateway } from '../src/handler.js';
import { MockModelClient } from '../src/mock-model.js';

/**
 * 每日概念打卡出题（`/ai/checkin/generate`）。
 *
 * 这里只压**会安静出错**的四件事 —— 每一条错了都不会报错，只会让
 * 「学生做对了却被判错」或者「题目根本不存在」：
 *
 * 1. 题型只能是 choice / judge（填空与解答在本地判分下必然误判）；
 * 2. 选择题答案必须是**存在的**选项字母（`E` 落在四选一里 = 永远选不对）；
 * 3. 判断题的 options 由服务端覆盖成 ["正确","错误"]，不信模型措辞；
 * 4. 单条坏题只丢自己，全坏才报错（422/502），不能静默退回「今天没题」。
 */
function build({ intercept } = {}) {
  const config = loadConfig({
    AI_MODEL_CLIENT: 'mock',
    AI_UPLOAD_URL_BASE: 'https://gw.test',
    AI_UPLOAD_SIGNING_SECRET: 'test-secret',
  });
  const model = new MockModelClient({ config, intercept });
  const gateway = createGateway({ config, model });
  return { gateway, model };
}

async function call(gateway, body) {
  const response = await gateway.handle({
    method: 'POST',
    path: '/ai/checkin/generate',
    query: {},
    headers: { 'x-student-id': 'stu_checkin' },
    body,
  });
  return {
    status: response.status,
    json: response.body === '' ? null : JSON.parse(response.body),
  };
}

const ITEMS = [
  { knowledge: '有理数混合运算', wrongCount: 3, wrongReason: '符号写错' },
  { knowledge: '解一元一次方程', wrongCount: 1 },
];

test('checkin：要 4 道就回 4 道，题型交替，答案能被本地判分', async () => {
  const { gateway } = build();

  const res = await call(gateway, { subject: '数学', items: ITEMS, count: 4 });
  assert.equal(res.status, 200);

  const questions = res.json.data.questions;
  assert.equal(questions.length, 4, '题量必须与请求一致');

  const known = new Set(ITEMS.map((item) => item.knowledge));
  for (const q of questions) {
    assert.ok(
      q.type === 'choice' || q.type === 'judge',
      `出了本地判不了的题型：${q.type}`,
    );
    assert.ok(q.stem.trim() !== '', '题干不能为空');
    assert.ok(known.has(q.knowledge), `knowledge 被改写了：${q.knowledge}`);

    if (q.type === 'choice') {
      const letters = ['A', 'B', 'C', 'D', 'E', 'F'];
      const index = letters.indexOf(q.answer);
      assert.ok(index >= 0, `答案不是字母：${q.answer}`);
      assert.ok(
        index < q.options.length,
        `答案 ${q.answer} 超出选项数 ${q.options.length} —— 这道题永远做不对`,
      );
    } else {
      assert.deepEqual(
        q.options,
        ['正确', '错误'],
        '判断题选项必须由服务端固定，不能跟着模型措辞走',
      );
      assert.ok(q.answer === 'T' || q.answer === 'F', `判断题答案应为 T/F：${q.answer}`);
    }
  }

  // 两种题型都出现过才说明「交替出题」真的覆盖到了两条渲染/判分路径。
  const types = new Set(questions.map((q) => q.type));
  assert.equal(types.size, 2, `四种题里只出现了 ${[...types].join('/')}，另一条分支没被走到`);
});

test('checkin：答案字母越界的那道被丢掉，其余保留（不是整批失败）', async () => {
  const { gateway } = build({
    intercept: () => ({
      value: {
        questions: [
          {
            type: 'choice',
            stem: '四个选项，答案却是 E',
            options: ['1', '2', '3', '4'],
            answer: 'E',
            knowledge: '有理数混合运算',
          },
          {
            type: 'judge',
            stem: '这道是好的',
            options: ['正确', '错误'],
            answer: 'T',
            knowledge: '解一元一次方程',
          },
        ],
      },
    }),
  });

  const res = await call(gateway, { items: ITEMS });
  assert.equal(res.status, 200);
  assert.equal(res.json.data.questions.length, 1, '坏题应被丢弃，好题保留');
  assert.equal(res.json.data.questions[0].stem, '这道是好的');
  assert.ok(
    res.json.meta.rejected.some((line) => line.includes('超出选项数')),
    '被丢弃的原因要说出来，否则排查时看不到模型在乱给',
  );
});

test('checkin：判断题的答案是「对」也能归一成 T，options 被覆盖', async () => {
  const { gateway } = build({
    intercept: () => ({
      value: {
        questions: [
          {
            type: 'judge',
            stem: '判断：$0.5=\\frac{1}{2}$',
            // 模型常见的两种走样：选项写成「对/错」、答案写成「对」
            options: ['对', '错', '不一定'],
            answer: '对',
            knowledge: '分数的意义',
          },
        ],
      },
    }),
  });

  const res = await call(gateway, { items: ITEMS });
  assert.equal(res.status, 200);
  const q = res.json.data.questions[0];
  assert.equal(q.answer, 'T');
  assert.deepEqual(q.options, ['正确', '错误']);
});

test('checkin：一条都判不了的时候必须报错，不能静默回空', async () => {
  const { gateway } = build({
    intercept: () => ({
      value: {
        questions: [
          {
            // 本地判不了：既不是 choice 也不是 judge
            type: 'choice',
            stem: '答案字母在选项之外',
            options: ['1', '2'],
            answer: 'D',
            knowledge: '有理数混合运算',
          },
        ],
      },
    }),
  });

  const res = await call(gateway, { items: ITEMS });
  assert.equal(res.status, 502, '全坏应当 502（模型违约），不能 200 + 空数组');
  assert.equal(res.json.error.code, 'schema_violation');
  assert.ok(
    Array.isArray(res.json.error.details?.problems) &&
      res.json.error.details.problems.length > 0,
    '要带上具体被丢掉的原因',
  );
});

test('checkin：items 缺失 / 超量都是 400，且提示说清是哪一条', async () => {
  const { gateway } = build();

  const empty = await call(gateway, { items: [] });
  assert.equal(empty.status, 400);
  assert.match(empty.json.error.message, /items/);

  const noKnowledge = await call(gateway, { items: [{ wrongCount: 2 }] });
  assert.equal(noKnowledge.status, 400);
  assert.match(noKnowledge.json.error.message, /knowledge/);

  const tooMany = await call(gateway, {
    items: Array.from({ length: 7 }, (_, i) => ({ knowledge: `知识点${i}` })),
  });
  assert.equal(tooMany.status, 400);
  assert.match(tooMany.json.error.message, /知识点/);
});

test('checkin：题量被夹在 1..10，模型只收到夹过的数字', async () => {
  const { gateway, model } = build();

  await call(gateway, { items: ITEMS, count: 999 });
  await call(gateway, { items: ITEMS, count: 0 });

  const prompts = model.calls.map((c) => String(c.content));
  assert.ok(
    prompts.some((p) => p.includes('题量：10')),
    'count 999 必须夹成 10 再发给模型',
  );
  assert.ok(
    prompts.some((p) => p.includes('题量：1')),
    'count 0 必须夹成 1（0 道题的打卡没有意义）',
  );
});
