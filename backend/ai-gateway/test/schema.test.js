import assert from 'node:assert/strict';
import test from 'node:test';

import { Schemas, repairStringifiedStructures, validate } from '../src/schema.js';

/**
 * `repairStringifiedStructures` —— 修「传输层双编码」。
 *
 * ## 为什么这块值得单独测
 *
 * 它是一个**放宽**的动作，而放宽最危险的失败形态是「放得太宽」：
 * 把一个本该判违规的结果放过去，于是错的数据进了错题库、被组卷、被打印。
 * 所以这里的用例成对写：**该修的修好** ＋ **不该碰的一个字节都不动**。
 *
 * 实测来源见 `config.js` 的 `stringifiesStructuredArgs` 与
 * `schema.js` 里这个函数的注释：百炼的兼容端点会把嵌套数组序列化成字符串
 * （`qwen3-vl-plus` / `qwen3-vl-flash` 各两次，4/4 一致），
 * 而 OpenAI 的结构化输出开关 `strict: true` 被接受却不起作用。
 */

/** 一个最小的「有嵌套结构的」schema，形态与 `homeworkOcr` 同族。 */
const SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['text', 'tasks'],
  properties: {
    text: { type: 'string', minLength: 1 },
    tasks: {
      type: 'array',
      minItems: 1,
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['subject'],
        properties: {
          subject: { type: 'string', minLength: 1 },
          meta: {
            type: 'object',
            additionalProperties: false,
            required: ['level'],
            properties: { level: { type: 'string' } },
          },
        },
      },
    },
  },
};

test('修·数组：被序列化成字符串的数组解回来，且校验通过', () => {
  const bad = {
    text: '今日作业',
    // ← 实测就是这个形态：换行 + 转义引号包着的数组
    tasks: '\n[{"subject": "语文"}, {"subject": "数学"}]\n',
  };

  const fixed = repairStringifiedStructures(SCHEMA, bad);

  assert.ok(Array.isArray(fixed.tasks), 'tasks 该被解成真数组');
  assert.equal(fixed.tasks.length, 2);
  assert.equal(fixed.tasks[0].subject, '语文');
  // 修完必须能过同一份校验 —— 否则这个修复只是把错误换了个说法。
  assert.deepEqual(validate(SCHEMA, fixed), []);
});

test('修·深层：数组里每一项的对象也能被解回来（只解一层会换个地方报错）', () => {
  const bad = {
    text: '昨日作业',
    tasks: [{ subject: '英语', meta: '{"level": "基础"}' }],
  };

  const fixed = repairStringifiedStructures(SCHEMA, bad);

  assert.deepEqual(fixed.tasks[0].meta, { level: '基础' });
  assert.deepEqual(validate(SCHEMA, fixed), []);
});

test('不碰·字符串字段：内容长得像 JSON 也一个字都不动', () => {
  // 学生作文、数学答案里出现 `[1,2,3]` 是完全正常的。
  // 按内容猜类型是这类「宽容」最常见的走火方式。
  const value = { text: '[1,2,3] 是他的答案', tasks: [{ subject: '数学' }] };

  const fixed = repairStringifiedStructures(SCHEMA, value);

  assert.equal(fixed, value, '没有可修的东西时必须返回同一个引用（便于调用方判断）');
  assert.equal(fixed.text, '[1,2,3] 是他的答案');
});

test('不碰·解出来类型不对：原样留着，交给 validate 报那句准确的违规', () => {
  // 字符串里装的是个对象，而 schema 要数组 → **不能**当数组用。
  const value = { text: 'x', tasks: '{"subject": "语文"}' };

  const fixed = repairStringifiedStructures(SCHEMA, value);

  assert.equal(fixed.tasks, '{"subject": "语文"}');
  assert.deepEqual(validate(SCHEMA, fixed), ['tasks 应为数组']);
});

test('不碰·根本不是 JSON：原样留着', () => {
  const value = { text: 'x', tasks: '语文、数学' };

  const fixed = repairStringifiedStructures(SCHEMA, value);

  assert.equal(fixed.tasks, '语文、数学');
  assert.deepEqual(validate(SCHEMA, fixed), ['tasks 应为数组']);
});

test('不碰·类型本来就对：返回同一个引用，不做无谓的深拷贝', () => {
  const value = { text: 'x', tasks: [{ subject: '语文' }] };

  assert.equal(repairStringifiedStructures(SCHEMA, value), value);
});

test('不碰·根不是对象：不能抛，也不能瞎改', () => {
  for (const value of [null, undefined, '一个字符串', 42, ['数组']]) {
    assert.equal(repairStringifiedStructures(SCHEMA, value), value);
  }
});

test('不碰·真错的东西照样是错的：修形态不等于放行内容', () => {
  // 这是这个修复的**边界**：tasks 解出来了（形态对了），
  // 但里面缺 required 的 subject → 仍然判违规。
  const value = { text: 'x', tasks: '[{"meta": {"level": "基础"}}]' };

  const fixed = repairStringifiedStructures(SCHEMA, value);

  assert.ok(Array.isArray(fixed.tasks), '形态该被修好');
  assert.deepEqual(validate(SCHEMA, fixed), ['tasks[0].subject 缺失']);
});

test('真实 schema 上也成立：homeworkOcr 的 tasks（就是实测跑飞的那一处）', () => {
  const value = {
    text: '今日作业',
    subject: '语文',
    confidence: 0.95,
    tasks: '[{"subject": "语文", "text": "抄写生字"}]',
  };

  const fixed = repairStringifiedStructures(Schemas.homeworkOcr, value);

  assert.ok(Array.isArray(fixed.tasks));
  assert.deepEqual(validate(Schemas.homeworkOcr, fixed), []);
});

// ── LaTeX 转义保护（latex-guard.js）────────────────────────────────────
// 事故：2026-10-21，家长端复习资料印出 `rac{2}{5}`、`\imes4`。
// 根因：模型把 items 序列化成字符串时对 LaTeX 少转义一层（`\frac` 而非
// `\\frac`），JSON.parse 把 `\f` 静默吃成换页符、`\t` 吃成制表符 ——
// 不报错、只坏内容，hex 里是 `0c`。判据必须对着控制字符断言。

test('修·少转义的 LaTeX：字符串化数组里的 \\frac / \\times 不被吃成控制字符', () => {
  // JS 源码里 '\\frac' 是「反斜杠 + frac」六个字符 —— 即模型少转义的原样。
  const bad = {
    text: '错因',
    tasks: '[{"subject": "$-\\frac{2}{5}$ 应化为 $\\times$"}]',
  };

  const fixed = repairStringifiedStructures(SCHEMA, bad);

  assert.ok(Array.isArray(fixed.tasks));
  const subject = fixed.tasks[0].subject;
  assert.equal(subject, '$-\\frac{2}{5}$ 应化为 $\\times$');
  assert.ok(!subject.includes('\f'), '不许出现换页符');
  assert.ok(!subject.includes('\t'), '不许出现制表符');
  assert.deepEqual(validate(SCHEMA, fixed), []);
});

test('修·\\underbrace 这类少转义（\\u 后面不是十六进制）也不崩', () => {
  const bad = {
    text: 'x',
    tasks: '[{"subject": "$\\underbrace{x}$"}]',
  };

  const fixed = repairStringifiedStructures(SCHEMA, bad);

  assert.equal(fixed.tasks[0].subject, '$\\underbrace{x}$');
});

test('不碰·正常转义的数据一个字节都不变（\\frac 保持 \\frac）', () => {
  // 反面对照：模型老实写成 `\\frac` 时，修复必须什么都不做 ——
  // 否则就是「为救一条路把另一条路弄坏」。
  const good = {
    text: 'x',
    tasks: '[{"subject": "$-\\\\frac{2}{5}$"}]',
  };

  const fixed = repairStringifiedStructures(SCHEMA, good);

  assert.equal(fixed.tasks[0].subject, '$-\\frac{2}{5}$');
  assert.ok(!fixed.tasks[0].subject.includes('\\\\'), '不许多出反斜杠');
});

test('不碰·真正的制表符转义（后面不是字母）原样通过', () => {
  const value = { text: 'a\tb\nc', tasks: [{ subject: '数学' }] };

  const fixed = repairStringifiedStructures(SCHEMA, value);

  assert.equal(fixed.text, 'a\tb\nc');
  assert.equal(fixed, value);
});
