import assert from 'node:assert/strict';
import test from 'node:test';

import { loadConfig } from '../src/config.js';
import { normalizeImages } from '../src/media.js';
import { systemPromptFor } from '../src/prompts.js';
import { Schemas, toTool, validate } from '../src/schema.js';

const config = loadConfig({});

test('schema 校验：字段缺失会被点名到具体路径', () => {
  const problems = validate(Schemas.homeworkCheck, {
    score: 80,
    summary: '还行',
    items: [
      {
        question: '计算 $\\frac{1}{2}+\\frac{1}{3}$。',
        knowledgePoint: '分数计算',
        originalAnswer: '8/12',
      },
    ],
  });
  assert.equal(problems.length, 1);
  assert.match(problems[0], /items\[0\]\.wrongReason 缺失/);
});

/**
 * 批改条目必须带题干。
 *
 * 这是整条错题闭环的上游：批改是唯一同时看到「题目 + 作答」的时机。
 * 少了题干，错题库里的题只能拿「作业标题 · 知识点」当题目，
 * 讲解、重做、变式题全都在对着一句标签做事 —— 而且**没有任何报错**，
 * 只表现为「讲解讲得很空」。所以这条必须在契约层硬卡住。
 */
test('schema 校验：批改条目缺题干要被点名，且题干为空白也算缺', () => {
  const missing = validate(Schemas.homeworkCheck, {
    score: 80,
    summary: '还行',
    items: [
      {
        knowledgePoint: '分数计算',
        originalAnswer: '8/12',
        wrongReason: '通分时分母没有统一',
      },
    ],
  });
  assert.match(missing.join('；'), /items\[0\]\.question 缺失/);

  const blank = validate(Schemas.homeworkCheck, {
    score: 80,
    summary: '还行',
    items: [
      {
        question: '',
        knowledgePoint: '分数计算',
        originalAnswer: '8/12',
        wrongReason: '通分时分母没有统一',
      },
    ],
  });
  assert.equal(blank.length, 1, '空字符串等于没写题干');
  assert.match(blank[0], /items\[0\]\.question 不能为空/);
});

test('schema 校验：数值区间与整数性', () => {
  const tooBig = validate(Schemas.homeworkCheck, {
    score: 120,
    summary: 'x',
    items: [],
  });
  assert.match(tooBig.join('；'), /score 不能大于 100/);

  const fractional = validate(Schemas.homeworkCheck, {
    score: 88.5,
    summary: 'x',
    items: [],
  });
  assert.match(fractional.join('；'), /score 应为整数/);
});

test('schema 校验：全对时 items 为空数组是合法的', () => {
  const problems = validate(Schemas.homeworkCheck, {
    score: 100,
    summary: '全部正确',
    items: [],
  });
  assert.deepEqual(problems, []);
});

test('schema 校验：三态判定里出现未知取值必须判违约', () => {
  // 把未知取值默认成 wrong 会让「模型换了字段名」表现成「学生全错」，
  // 这是最难发现的一类线上事故，所以这里必须硬失败。
  const problems = validate(Schemas.reviewJudge, {
    verdict: 'partially_correct',
    score: 60,
    comment: '大致对',
  });
  assert.match(problems.join('；'), /不在允许范围/);
});

test('schema 校验：steps 为空数组要判违约', () => {
  const problems = validate(Schemas.reviewExplain, {
    knowledgePoint: '分数计算',
    position: '人教版五年级',
    whyWrong: '没有通分',
    steps: [],
    pitfalls: [],
    mnemonic: '先通分',
  });
  assert.match(problems.join('；'), /steps 至少要有 1 项/);
});

test('schema 校验：题目缺 answer 要判违约（没有答案无法判定对错）', () => {
  const problems = validate(Schemas.reviewPractice, {
    questions: [
      { type: 'solution', title: '变式1', content: '题干', difficulty: '基础' },
    ],
    referenceAnswer: '先统一单位',
  });
  assert.match(problems.join('；'), /questions\[0\]\.answer 缺失/);
});

/**
 * 题型是「本地判定」的开关。
 *
 * 没有 type 的时候，客户端只能把每道题都当解答题送模型 —— 那道
 * 「选择题提交、网关 0 次调用」的判据就成了空转的绿（永远走不到）。
 * 所以 type 必须**必填**，取值必须封闭。
 */
test('schema 校验：题型必填且取值封闭', () => {
  const missing = validate(Schemas.reviewPractice, {
    questions: [{ title: '变式1', content: '题干', answer: 'A', difficulty: '基础' }],
    referenceAnswer: '先统一单位',
  });
  assert.match(missing.join('；'), /questions\[0\]\.type 缺失/);

  const unknown = validate(Schemas.reviewPractice, {
    questions: [
      {
        type: 'essay',
        title: '变式1',
        content: '题干',
        answer: 'A',
        difficulty: '基础',
      },
    ],
    referenceAnswer: '先统一单位',
  });
  assert.match(unknown.join('；'), /questions\[0\]\.type 取值「essay」不在允许范围/);
});

test('schema 校验：一组合格的四型题能通过', () => {
  const problems = validate(Schemas.reviewPractice, {
    questions: [
      {
        type: 'choice',
        title: '选择',
        content: '下列方程中，解为 x=2 的是（ ）',
        options: ['2x+1=5', '3x-1=4', 'x/2=2', '4x=6'],
        answer: 'A',
        difficulty: '基础',
      },
      { type: 'fill', title: '填空', content: '1/2+1/3=____', answer: '5/6', difficulty: '基础' },
      { type: 'judge', title: '判断', content: '1/2+1/3=5/6', answer: '正确', difficulty: '基础' },
      { type: 'solution', title: '解答', content: '解方程 2x+1=5', answer: 'x=2', difficulty: '基础' },
    ],
    referenceAnswer: '先通分',
  });
  assert.deepEqual(problems, []);
});

test('出题提示词：四种题型都要写清，且不许把解答题改成选择题', () => {
  const prompt = systemPromptFor('reviewPractice');
  assert.match(prompt, /choice/);
  assert.match(prompt, /judge/);
  assert.match(prompt, /fill/);
  assert.match(prompt, /solution/);
  // 这条是「举一反三」的意义所在：换成更好批改的题型，练的就不是同一件事了。
  assert.match(prompt, /不要为了「好批改」把解答题改成选择题/);
  assert.match(prompt, /恰好 4 个/);
});

test('tool 定义：只带标准 JSON Schema 关键词，可直接交给方舟', () => {
  const tool = toTool(Schemas.reviewJudge);
  assert.equal(tool.type, 'function');
  assert.equal(tool.function.name, 'report_answer_judgement');
  assert.deepEqual(tool.function.parameters.required, [
    'verdict',
    'score',
    'comment',
  ]);
  assert.equal(tool.function.parameters.properties.verdict.type, 'string');
  assert.deepEqual(tool.function.parameters.properties.verdict.enum, [
    'correct',
    'wrong',
    'inconclusive',
  ]);
});

test('提示词：retryHint 会被拼进去，且只在有值时出现', () => {
  const plain = systemPromptFor('reviewExplain');
  assert.ok(!plain.includes('没有通过结构校验'));

  const retried = systemPromptFor('reviewExplain', {
    retryHint: 'steps 至少要有 1 项，实际 0 项',
  });
  assert.ok(retried.includes('没有通过结构校验'));
  assert.ok(retried.includes('steps 至少要有 1 项，实际 0 项'));
});

test('提示词：未知能力直接抛错，而不是返回一段空提示', () => {
  assert.throws(() => systemPromptFor('unknownCapability'), /没有为能力/);
});

test('图片归一：内联模式转成 data URI', () => {
  const result = normalizeImages(
    [{ base64: 'aGVsbG8=', mimeType: 'image/jpeg' }],
    config,
  );
  assert.equal(result.imageCount, 1);
  assert.equal(result.parts[0].type, 'image_url');
  assert.equal(
    result.parts[0].image_url.url,
    'data:image/jpeg;base64,aGVsbG8=',
  );
  assert.equal(result.totalBytes, 5);
});

test('图片归一：对象存储模式直接用 URL', () => {
  const result = normalizeImages(
    [{ url: 'https://tos-cn-beijing.volces.com/bucket/a.jpg', mimeType: 'image/png' }],
    config,
  );
  assert.equal(
    result.parts[0].image_url.url,
    'https://tos-cn-beijing.volces.com/bucket/a.jpg',
  );
});

test('图片归一：张数超限回 413 而不是让请求进模型', () => {
  const images = Array.from({ length: config.maxImages + 1 }, () => ({
    base64: 'aGVsbG8=',
    mimeType: 'image/jpeg',
  }));
  assert.throws(
    () => normalizeImages(images, config),
    (error) => error.code === 'payload_too_large' && error.status === 413,
  );
});

test('图片归一：总体积超限回 413', () => {
  // 每张 1 字节，用 3 张凑不出超限，直接构造一张超大的。
  const huge = 'A'.repeat(Math.ceil((config.maxImageBytes + 1024) / 3) * 4);
  assert.throws(
    () => normalizeImages([{ base64: huge, mimeType: 'image/jpeg' }], config),
    (error) => error.code === 'payload_too_large',
  );
});

test('图片归一：类型白名单外直接拒绝', () => {
  assert.throws(
    () => normalizeImages([{ base64: 'aGVsbG8=', mimeType: 'image/svg+xml' }], config),
    (error) => error.code === 'bad_request' && /mimeType 不支持/.test(error.message),
  );
});

test('图片归一：内网 URL 被拒（防止把网关当内网探测跳板）', () => {
  for (const url of [
    'http://tos.example.com/a.jpg',
    'https://127.0.0.1/a.jpg',
    'https://10.0.0.8/a.jpg',
    'https://192.168.1.5/a.jpg',
    'https://localhost/a.jpg',
  ]) {
    assert.throws(
      () => normalizeImages([{ url, mimeType: 'image/jpeg' }], config),
      (error) => error.code === 'bad_request',
      `应拒绝 ${url}`,
    );
  }
});

test('图片归一：既无 url 也无 base64 明确报错', () => {
  assert.throws(
    () => normalizeImages([{ mimeType: 'image/jpeg' }], config),
    (error) => error.code === 'bad_request' && /既没有 url 也没有 base64/.test(error.message),
  );
});

test('图片归一：未传 images 视为空，不报错', () => {
  const result = normalizeImages(undefined, config);
  assert.deepEqual(result.parts, []);
});

// --- 手写识别：uncertain 标记 ------------------------------------------------
//
// 这一组守的是一个具体的事故形状：手写体把「静夜思」认成「静在恩」，
// 转录读起来通顺、置信度也照样 0.9，于是没人会去核对。
// 能提示学生的只有模型自报的 uncertain 标记 —— 所以它必须
// 「可选但不能是错的」，两头都不能松。

test('OCR schema：不带 uncertain 的条目仍然合法', () => {
  const problems = validate(Schemas.homeworkOcr, {
    text: '语文：背诵《静夜思》',
    subject: '语文',
    confidence: 0.9,
    // 老版本模型不返回这个字段，不该因此判违约 ——
    // 判违约会触发重试，再失败就整条降级成本地模拟，
    // 用一次可用的识别结果去换一个空结果。
    tasks: [{ subject: '语文', text: '背诵《静夜思》' }],
  });
  assert.deepEqual(problems, []);
});

test('OCR schema：uncertain 为 true 合法', () => {
  const problems = validate(Schemas.homeworkOcr, {
    text: '语文：背诵《静在恩》',
    subject: '语文',
    confidence: 0.9,
    tasks: [{ subject: '语文', text: '背诵《静在恩》', uncertain: true }],
  });
  assert.deepEqual(problems, []);
});

test('OCR schema：uncertain 不是布尔值要被拦下', () => {
  // 模型很自然会写 "是" / "true" / 1。放过去的话客户端 `== true` 为假，
  // 标记静默丢失，界面不会提示，而这一条照样落库。
  const problems = validate(Schemas.homeworkOcr, {
    text: '语文：背诵《静在恩》',
    subject: '语文',
    confidence: 0.9,
    tasks: [{ subject: '语文', text: '背诵《静在恩》', uncertain: '是' }],
  });
  assert.equal(problems.length, 1);
  assert.match(problems[0], /tasks\[0\]\.uncertain 应为布尔值/);
});

test('OCR 提示词：保留「不许编造」与「标出认不准的字」两条约束', () => {
  const prompt = systemPromptFor('homeworkOcr');
  // 只断言这两条存在，不断言措辞 —— 提示词会持续调整，
  // 但这两条一旦被删掉，手写识别就会退化回「认错得看不出来」。
  assert.match(prompt, /手抄/);
  assert.match(prompt, /uncertain/);
  assert.match(prompt, /（？）/);
  assert.match(prompt, /不要换成一个读起来通顺的词/);
});

// --- 手写识别：一条只放一件事 + 耗时估读 --------------------------------------
//
// 这一组守的是「识别之后的整理」。识别对了但整理错了，症状同样看不出来：
// 一条里塞两件事 → 学生漏做后面那件；耗时给个假精准的数 → 学生不敢改。

test('OCR 提示词：要求一条只放一件事', () => {
  const prompt = systemPromptFor('homeworkOcr');
  assert.match(prompt, /一条只放一件事/);
  // 反过来也要说清：不能为了拆而拆，把「做1、2、3题」切成三条。
  assert.match(prompt, /不要硬拆|本来就带多个小问/);
});

test('OCR schema：不带 estimatedMinutes 的条目仍然合法', () => {
  // 拿不准时宁可空着，客户端会按标题退回类型默认值。
  // 把必填加上的话，模型必须给一个数 —— 那它就一定会猜一个。
  const problems = validate(Schemas.homeworkOcr, {
    text: '数学：练习册P12',
    subject: '数学',
    confidence: 0.9,
    tasks: [{ subject: '数学', text: '练习册P12' }],
  });
  assert.deepEqual(problems, []);
});

test('OCR schema：estimatedMinutes 合理范围合法', () => {
  const problems = validate(Schemas.homeworkOcr, {
    text: '数学：练习册P12',
    subject: '数学',
    confidence: 0.9,
    tasks: [{ subject: '数学', text: '练习册P12', estimatedMinutes: 40 }],
  });
  assert.deepEqual(problems, []);
});

test('OCR schema：estimatedMinutes 越界要被拦下', () => {
  const tooBig = validate(Schemas.homeworkOcr, {
    text: '数学：练习册P12',
    subject: '数学',
    confidence: 0.9,
    tasks: [{ subject: '数学', text: '练习册P12', estimatedMinutes: 9999 }],
  });
  assert.equal(tooBig.length, 1);
  assert.match(tooBig[0], /tasks\[0\]\.estimatedMinutes 不能大于 120/);

  const tooSmall = validate(Schemas.homeworkOcr, {
    text: '数学：练习册P12',
    subject: '数学',
    confidence: 0.9,
    tasks: [{ subject: '数学', text: '练习册P12', estimatedMinutes: 0 }],
  });
  assert.equal(tooSmall.length, 1);
  assert.match(tooSmall[0], /tasks\[0\]\.estimatedMinutes 不能小于 5/);
});

test('OCR schema：estimatedMinutes 必须是整数', () => {
  const problems = validate(Schemas.homeworkOcr, {
    text: '数学：练习册P12',
    subject: '数学',
    confidence: 0.9,
    tasks: [{ subject: '数学', text: '练习册P12', estimatedMinutes: 12.5 }],
  });
  assert.equal(problems.length, 1);
  assert.match(problems[0], /tasks\[0\]\.estimatedMinutes 应为整数/);
});

// --- 作业批改：答案错 vs 书写不规范 -------------------------------------------
//
// 这一组守的是一个**已经实测发生过**的事故：一份答案全对的卷子，
// 模型报了 5 条错题，其中 3 条是「没写单位」这类纯格式挑剔；有一条的错因里
// 甚至写着「此处计算无误，经复核该题学生解答正确，不应判错」——
// 它自己认为这题是对的，却仍然把这条放进了错题数组。
//
// 代价是双向的：错题库被格式问题灌满 → 学生反复重做本来就会的题；
// score 也被这些条目拉低 → 全对的卷子只拿 60~80 分。
// 所以契约上必须把两类问题分开放，并且把 items 的定义写死。

test('批改 schema：书写规范问题放 formatIssues 合法', () => {
  const problems = validate(Schemas.homeworkCheck, {
    score: 100,
    summary: '计算全对，注意补单位',
    items: [],
    formatIssues: [
      { knowledgePoint: '小数除法', detail: '第 4 题算对了但没写单位「元」' },
    ],
  });
  assert.deepEqual(problems, []);
});

test('批改 schema：formatIssues 必须真的定义在契约里', () => {
  // ⚠️ 这一条是**证伪逼出来的**：上面那条「传进去合法」在 formatIssues
  // 被删掉之后**依然是绿的** —— 因为 `validate` 不执行 `additionalProperties`，
  // 未定义的多余字段根本不会被拦（见下面那条「已知缺口」）。
  // 所以光靠「传进去不报错」证明不了这个字段存在，必须直接盯结构。
  const check = Schemas.homeworkCheck;
  const formatIssues = check.properties.formatIssues;
  assert.ok(formatIssues, 'formatIssues 必须定义在 homeworkCheck 里');
  assert.equal(formatIssues.type, 'array');
  assert.deepEqual(formatIssues.items.required, ['knowledgePoint', 'detail']);
  // 反过来也要盯住：它**不能**是必填。没有这类问题时就该缺席，
  // 设成必填会逼模型为了填满字段硬凑两条出来。
  assert.ok(
    !check.required.includes('formatIssues'),
    'formatIssues 不能进 required',
  );
});

test('批改 schema：未知字段目前不会被拦（已知缺口，不是期望行为）', () => {
  // 这条用例不是在描述「应该如此」，而是把一个**已知缺口**摆到明处：
  // `additionalProperties: false` 只经由 toTool 交给模型（厂商层约束），
  // `validate` 并不执行它 —— 服务端对「模型多返回一个字段」是不设防的。
  //
  // 留着的价值：一旦哪天校验器补上这一条，这里会立刻变红，
  // 那时应当把它改成反向断言（并评估收紧后会不会误伤线上模型）。
  const problems = validate(Schemas.homeworkCheck, {
    score: 90,
    summary: '还行',
    items: [],
    未定义的字段: '模型偶尔会多给一个',
  });
  assert.deepEqual(problems, []);
});

test('批改 schema：不带 formatIssues 仍然合法（没有这类问题就该缺席）', () => {
  // 设成必填会逼模型为了填满字段硬找两条出来 —— 那正是要避免的事。
  const problems = validate(Schemas.homeworkCheck, {
    score: 95,
    summary: '基本正确',
    items: [],
  });
  assert.deepEqual(problems, []);
});

test('批改 schema：formatIssues 缺 detail 要被拦下', () => {
  const problems = validate(Schemas.homeworkCheck, {
    score: 90,
    summary: '还行',
    items: [],
    formatIssues: [{ knowledgePoint: '小数除法' }],
  });
  assert.equal(problems.length, 1);
  assert.match(problems[0], /formatIssues\[0\]\.detail 缺失/);
});

test('批改提示词：必须写清「跳步 / 有风险」都不算做错', () => {
  const prompt = systemPromptFor('homeworkCheck');
  // 只断言这几条约束在，不断言措辞 —— 提示词会持续调整。
  // 但少了任何一条，格式问题就会重新回流进错题库，而且是静默回流。
  //
  // ⚠️ 2026-09-26 口径变更（虫子定）：原先这里是「答案对的题一条都不许放」。
  // 新口径是「结果对了、但中间某一步本身写错/算错」**也要进 items**
  //   —— 那句旧断言已经不成立，故换成下面这组边界。
  // 「跳步」是「某一步没写出来、但写出来的都对」；「算错」是「写出来的某一步本身错了」。
  assert.match(prompt, /跳步 ≠ 算错/);
  assert.match(prompt, /有风险不是错误/);
  assert.match(prompt, /中间某一步本身写错/);
  assert.match(prompt, /做错了没有/);
  assert.match(prompt, /formatIssues/);
  // 已经出现过的那条错法要被点名：先放进 items，再在错因里解释「其实是对的」。
  assert.match(prompt, /拿不准就不要报/);
  // 题干必须抄下来，且公式要用 LaTeX —— 否则错题只能存一句标签，
  // 讲解会退化、重做更是无从谈起（而且全程没有任何报错）。
  assert.match(prompt, /question（题干原文）/);
  assert.match(prompt, /LaTeX/);
  assert.match(prompt, /不要带学生的作答/);
});

test('批改口径：漏答一问算错，和「没写答句」必须被分开写清', () => {
  // 2026-09-26 定性：判据是「该写的内容有没有写对」，不是「写得规不规范」。
  //
  // 为什么单独盯这一对：它们是这条线上的两端，也最容易被合流 ——
  // 把「漏答一问」当成 formatIssues ⇒ 学生**永远不会重做**那道他没做完的题，
  // 而错题库里少一道他真不会的题，这种漏是静默的；
  // 把「没写答句」当成 items ⇒ 学生反复重做他本来就会的题。
  const prompt = systemPromptFor('homeworkCheck');
  assert.match(prompt, /只答了其中一部分/);
  assert.match(prompt, /答案不完整/);
  // ⚠️ 对照句必须还在。光有前两条，模型仍可能把两者当成一件事。
  assert.match(prompt, /别把这条和「没写答句」混为一谈/);

  // score 的口径要跟着走，否则会出现「算错、但不扣分」的自相矛盾。
  const check = Schemas.homeworkCheck;
  assert.match(check.properties.items.description, /漏答了题目要求的一部分/);
  assert.match(check.properties.score.description, /漏答/);
});
