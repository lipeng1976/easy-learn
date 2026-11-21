import assert from 'node:assert/strict';
import test from 'node:test';

import { loadConfig } from '../src/config.js';
import { createGateway } from '../src/handler.js';
import { MockModelClient } from '../src/mock-model.js';

/**
 * 错题库 → 知识点提示（`/ai/review/tips`）。
 *
 * 这里只压三件**会安静出错**的事：
 * 1. 知识点名必须原样回传（客户端靠它把提示挂回错题）；
 * 2. 同一知识点只能出现一次（否则「换一条」永远转到同一句）；
 * 3. 缓存必须按知识点集合区分（否则换了错题还显示上一批提示）。
 */
function build() {
  const config = loadConfig({
    AI_MODEL_CLIENT: 'mock',
    AI_UPLOAD_URL_BASE: 'https://gw.test',
    AI_UPLOAD_SIGNING_SECRET: 'test-secret',
  });
  const model = new MockModelClient({ config });
  const gateway = createGateway({ config, model });
  return { gateway, model };
}

async function call(gateway, body) {
  const response = await gateway.handle({
    method: 'POST',
    path: '/ai/review/tips',
    query: {},
    headers: { 'x-student-id': 'stu_tips' },
    body,
  });
  return {
    status: response.status,
    json: response.body === '' ? null : JSON.parse(response.body),
  };
}

const ITEMS = [
  { knowledgePoint: '一元二次方程', wrongCount: 3, wrongReason: '忘了先算判别式' },
  { knowledgePoint: '分式化简', wrongCount: 1 },
];

test('tips：知识点名原样回传，一条都没有时明确报 400', async () => {
  const { gateway } = build();

  const ok = await call(gateway, { subject: '数学', items: ITEMS });
  assert.equal(ok.status, 200);
  const tips = ok.json.data.tips;
  assert.ok(Array.isArray(tips) && tips.length > 0, 'tips 不能为空');
  for (const tip of tips) {
    assert.ok(
      ITEMS.some((item) => item.knowledgePoint === tip.knowledgePoint),
      `模型回了请求里没有的知识点「${tip.knowledgePoint}」—— 界面挂不回去`,
    );
    assert.ok(tip.text.trim() !== '', 'tip 文本不能为空');
  }

  const empty = await call(gateway, { subject: '数学', items: [] });
  assert.equal(empty.status, 400);
  assert.match(empty.json.error.message, /items/);
});

test('tips：同一知识点重复上报时，发给模型的只有一条', async () => {
  const { gateway, model } = build();

  const duplicated = [
    { knowledgePoint: '一元二次方程', wrongCount: 1 },
    { knowledgePoint: '一元二次方程', wrongCount: 5 },
    { knowledgePoint: '一元二次方程', wrongCount: 2 },
  ];
  const response = await call(gateway, { subject: '数学', items: duplicated });
  assert.equal(response.status, 200);

  const prompt = model.calls[0].content;
  const occurrences = prompt.split('知识点：一元二次方程').length - 1;
  assert.equal(
    occurrences,
    1,
    '重复的知识点被原样发给了模型 —— 它会重复写同一条提示，学生换一条永远看到同一句',
  );
  // 合并时保留「错得最多」的那条，不能留下 wrongCount=1 的那份。
  assert.match(prompt, /累计错 5 次/);
});

test('tips：知识点集合变了，缓存不能命中上一批', async () => {
  const { gateway } = build();

  const first = await call(gateway, { subject: '数学', items: ITEMS });
  const again = await call(gateway, { subject: '数学', items: ITEMS });
  assert.equal(first.json.meta.cached, false);
  assert.equal(again.json.meta.cached, true, '同样的输入应当命中缓存');

  const changed = await call(gateway, {
    subject: '数学',
    items: [...ITEMS, { knowledgePoint: '勾股定理', wrongCount: 2 }],
  });
  assert.equal(
    changed.json.meta.cached,
    false,
    '错题集合变了却命中了旧缓存 —— 学生会看到已经不在错题本里的知识点',
  );
});

test('tips：超过上限直接拒绝，不静默截断', async () => {
  const { gateway } = build();
  const items = Array.from({ length: 13 }, (_, index) => ({
    knowledgePoint: `知识点${index}`,
    wrongCount: 1,
  }));
  const response = await call(gateway, { subject: '数学', items });
  assert.equal(response.status, 400);
  assert.match(response.json.error.message, /12/);
});
