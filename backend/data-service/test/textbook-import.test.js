import test from 'node:test';
import assert from 'node:assert/strict';

import {
  TEXTBOOK_FORMAT_HINT,
  parseTextbookSkeleton,
  splitPoints,
} from '../src/textbook_import.js';
import { advanceUnitCursor, resolveTextbookPoints } from '../src/routes/textbook.js';

/**
 * 教材：骨架 MD 解析 + 出题时取哪几节。
 *
 * ## 为什么这两件事要有判据
 *
 * ① 解析器决定的不是「显示」，而是**出题范围**。少认一节 = 那章永远考不到；
 *    把 `###` 当成节 = 范围里混进一句小标题，模型出的题跑题 —— 两者都不报错。
 * ② `resolveTextbookPoints` 是**可选能力的入口**：它在「没配教材 / 027 未迁移 /
 *    书被删了」时必须安静地回 null，让出题退回错题本；抛错的话家长看到的
 *    是「出不了题」，而真正的原因在一张他没配过的表上。
 */

const STOCK = `# 人教版七年级上册 数学

## 第1章 有理数 | p1
考点：正数、负数、数轴、相反数、绝对值

## 第2章 整式的加减 | p23
考点：单项式、多项式、同类项
`;

test('解析：书名、章标题、页码、考点都认；章号按出现顺序而不是标题里的数字', () => {
  const parsed = parseTextbookSkeleton(STOCK);
  assert.equal(parsed.title, '人教版七年级上册 数学');
  assert.equal(parsed.units.length, 2);
  assert.deepEqual(
    parsed.units.map((u) => u.unitNo),
    [1, 2],
    '章号必须是文档顺序 —— 从标题解析「第1章」遇到 Unit/一、就断',
  );
  assert.equal(parsed.units[0].title, '第1章 有理数');
  assert.equal(parsed.units[0].pageHint, '1');
  assert.equal(parsed.units[0].summary, '正数、负数、数轴、相反数、绝对值');
  assert.equal(parsed.units[1].pageHint, '23');
});

test('解析：模型包的 ```markdown 围栏、CRLF、全角竖线都能吃', () => {
  const text = '```markdown\r\n# 八上 物理\r\n\r\n## 第1章 机械运动 ｜ p3\r\n考点: 长度测量、速度\r\n```\r\n';
  const parsed = parseTextbookSkeleton(text);
  assert.equal(parsed.title, '八上 物理');
  assert.equal(parsed.units.length, 1);
  assert.equal(parsed.units[0].title, '第1章 机械运动', '全角 ｜ 也要能当分隔符');
  assert.equal(parsed.units[0].pageHint, '3');
  assert.equal(parsed.units[0].summary, '长度测量、速度', '半角冒号同样是考点行');
});

test('解析：`###` 不是新的一节（模型多打一个 # 不该多出半节）', () => {
  const parsed = parseTextbookSkeleton(
    ['## 第1章 有理数', '### 1.1 正数和负数', '考点：正数'].join('\n'),
  );
  assert.equal(parsed.units.length, 1);
  assert.equal(parsed.units[0].summary, '正数');
});

test('解析：没有 `##` 就是 0 节 —— 调用方据此拒收，不存空书', () => {
  const parsed = parseTextbookSkeleton('# 人教版七上\n\n这是一本教材的简介。\n');
  assert.equal(parsed.units.length, 0);
  assert.ok(TEXTBOOK_FORMAT_HINT.includes('##'), '格式说明必须写出正确结构');
});

test('解析：书名缺失时用文件名兜底（ima 文件标题不是书名的常见情况）', () => {
  const parsed = parseTextbookSkeleton('## 第1章 有理数\n考点：数轴', { title: '七上数学' });
  assert.equal(parsed.title, '七上数学');
});

test('考点切分：中英文逗号、顿号、分号都当分隔；超过上限就截断', () => {
  assert.deepEqual(splitPoints('正数、负数, 数轴；相反数'), ['正数', '负数', '数轴', '相反数']);
  assert.deepEqual(splitPoints('a、b、c、d', 2), ['a', 'b'], '上限必须真截断');
  assert.deepEqual(splitPoints(''), []);
  assert.deepEqual(splitPoints('数轴、数轴'), ['数轴'], '重复考点只留一个');
});

// ===== resolveTextbookPoints =====

/** 按 SQL 特征回数据的假 client（不执行 SQL）。 */
function fakeClient({ scope, units, failOn = null }) {
  const queries = [];
  return {
    queries,
    query(sql, params = []) {
      queries.push({ sql, params });
      if (failOn && sql.includes(failOn)) return Promise.reject(Object.assign(new Error('42703'), { code: '42703' }));
      // ⚠️ 先判 `max(unit_no)`：那条 SQL 里也含 `from subject_scope`
      // （`book_id = (select ... from subject_scope ...)`），顺序反了会拿错假数据，
      // 而症状恰好是「游标钳制失效」—— 假 client 先匹配哪个条件，测的就是哪条路。
      if (sql.includes('max(unit_no)')) {
        return Promise.resolve({ rows: [{ last: units.length }] });
      }
      if (sql.includes('from subject_scope')) {
        return Promise.resolve({ rowCount: scope ? 1 : 0, rows: scope ? [scope] : [] });
      }
      if (sql.includes('from subject_unit')) {
        return Promise.resolve({ rows: units });
      }
      return Promise.resolve({ rowCount: 0, rows: [] });
    },
  };
}

test('取范围：按 start_unit_no 起、取 units_per_day 节，考点摊平后截到上限', async () => {
  const client = fakeClient({
    scope: { book_id: 'tb_1', start_unit_no: 2, units_per_day: 2 },
    units: [
      { unit_no: 2, title: '第2章 整式', summary: '单项式、多项式' },
      { unit_no: 3, title: '第3章 方程', summary: '一元一次方程、移项' },
    ],
  });

  const hit = await resolveTextbookPoints(client, 'stu_1', '数学', 6);

  assert.ok(hit);
  assert.deepEqual(hit.points, ['单项式', '多项式', '一元一次方程', '移项']);
  assert.deepEqual(hit.unitTitles, ['第2章 整式', '第3章 方程']);
  assert.equal(hit.nextStart, 4, '游标 = 起点 + 覆盖节数');

  const q = client.queries.find((one) => one.sql.includes('from subject_unit') && one.sql.includes('limit'));
  assert.ok(q.params.includes(2), '起始节必须下到 SQL，不能在内存里筛（那会把整本书拉回来）');
});

test('取范围：上限按**整次**算，不是每节各 6 个', async () => {
  const client = fakeClient({
    scope: { book_id: 'tb_1', start_unit_no: 1, units_per_day: 3 },
    units: [
      { unit_no: 1, title: 'a', summary: '1、2、3' },
      { unit_no: 2, title: 'b', summary: '4、5、6' },
      { unit_no: 3, title: 'c', summary: '7、8、9' },
    ],
  });
  const hit = await resolveTextbookPoints(client, 'stu_1', '数学', 6);
  assert.equal(hit.points.length, 6,
    '每节各截 6 个的话，三节就是 18 个知识点，等于没设范围');
});

test('取范围：没配教材 / 027 未迁移 —— 安静回 null', async () => {
  const noBook = await resolveTextbookPoints(
    fakeClient({ scope: { book_id: null }, units: [] }), 'stu_1', '数学', 6,
  );
  assert.equal(noBook, null, '没配教材是最正常的情况');

  const notMigrated = await resolveTextbookPoints(
    fakeClient({ scope: null, units: [], failOn: 'book_id' }), 'stu_1', '数学', 6,
  );
  assert.equal(notMigrated, null, '表没迁移不能让出题整条挂掉');
});

test('取范围：章节没写考点时用**标题**当知识点（历史/政治骨架的常态）', async () => {
  // 真实数据：中国历史 22 节全部只有 `## 第N课 标题`，一行「考点：」都没有。
  // 旧实现把这种书整体判成 null → 退回错题本 → 历史没学过、没错题 →
  // 每点一次都报「错题本还是空的」，而家长明明配好了教材。
  const hit = await resolveTextbookPoints(
    fakeClient({
      scope: { book_id: 'tb_1', start_unit_no: 7, units_per_day: 1 },
      units: [{ unit_no: 7, title: '第7课 百家争鸣', summary: '' }],
    }),
    'stu_1',
    '历史',
    6,
  );
  assert.ok(hit, '只有标题的教材必须能出题');
  assert.deepEqual(hit.points, ['第7课 百家争鸣']);
  assert.deepEqual(hit.titleOnlyPoints, ['第7课 百家争鸣'],
    '要能分辨「这点是标题顶的」，出题提示词据此补教材语境');
  assert.equal(hit.nextStart, 8, '照样推进游标，否则每天都在考同一节');
});

test('取范围：有考点的节不用标题顶，两种混着也行', async () => {
  const hit = await resolveTextbookPoints(
    fakeClient({
      scope: { book_id: 'tb_1', start_unit_no: 1, units_per_day: 2 },
      units: [
        { unit_no: 1, title: '第1课 鸦片战争', summary: '虎门销烟、南京条约' },
        { unit_no: 2, title: '第2课 第二次鸦片战争', summary: '' },
      ],
    }),
    'stu_1',
    '历史',
    6,
  );
  assert.deepEqual(hit.points, ['虎门销烟', '南京条约', '第2课 第二次鸦片战争']);
  assert.deepEqual(hit.titleOnlyPoints, ['第2课 第二次鸦片战争'],
    '只有没写考点的那些才算标题顶的');
});

test('取范围：语文的「阅读」板块名被跳过，取到正文那一课', async () => {
  // 真实数据：语文目录是 `阅读` → `1 春` → `2 济南的冬天`。拿「阅读」当知识点，
  // 模型会出「阅读方法」这类与课文无关的通识题 —— 题本身通顺，界面上看不出跑偏。
  const client = fakeClient({
    scope: { book_id: 'tb_yw', start_unit_no: 1, units_per_day: 1 },
    units: [
      { unit_no: 1, title: '阅读', summary: '' },
      { unit_no: 2, title: '1 春', summary: '' },
      { unit_no: 3, title: '2 济南的冬天', summary: '' },
    ],
  });

  const hit = await resolveTextbookPoints(client, 'stu_1', '语文', 6);

  assert.deepEqual(hit.points, ['1 春'], '板块名不是内容，正文那一课才是');
  assert.deepEqual(hit.unitNos, [2]);
  assert.equal(hit.nextStart, 3, '游标要落在被采用的那一节之后，不能按配置步长盲推');
});

test('取范围：连续几个板块名也只取正文，不能被「每天 1 节」卡在第 1 个板块', async () => {
  const hit = await resolveTextbookPoints(
    fakeClient({
      scope: { book_id: 'tb_yw', start_unit_no: 1, units_per_day: 2 },
      units: [
        { unit_no: 1, title: '写作', summary: '' },
        { unit_no: 2, title: '综合性学习', summary: '' },
        { unit_no: 3, title: '5 秋天的怀念', summary: '' },
        { unit_no: 4, title: '6 散步', summary: '' },
      ],
    }),
    'stu_1',
    '语文',
    6,
  );
  assert.deepEqual(hit.points, ['5 秋天的怀念', '6 散步']);
  assert.equal(hit.nextStart, 5);
});

test('取范围：标题和考点都空的节 —— 整次都没点才回 null', async () => {
  const hit = await resolveTextbookPoints(
    fakeClient({
      scope: { book_id: 'tb_1', start_unit_no: 1, units_per_day: 1 },
      units: [{ unit_no: 1, title: '   ', summary: '' }],
    }),
    'stu_1',
    '数学',
    6,
  );
  assert.equal(hit, null, '连标题都没有，退回错题本而不是拿空字符串去出题');
});

// ===== advanceUnitCursor =====

test('推游标：越过最后一节就停在最后一节（不回绕）', async () => {
  const client = fakeClient({
    scope: { book_id: 'tb_1', start_unit_no: 9, units_per_day: 2 },
    units: [{}, {}, {}],
  });
  await advanceUnitCursor(client, 'stu_1', '数学', 11);
  const q = client.queries.find((one) => one.sql.includes('update subject_scope'));
  assert.equal(q.params[2], 3, '共有 3 节，推到 11 节会跳到不存在的范围；必须钳到 3');
});

test('推游标：推进失败不抛（下次还考这一节，比这次出题失败好）', async () => {
  const client = {
    query() {
      return Promise.reject(new Error('boom'));
    },
  };
  await assert.doesNotReject(() => advanceUnitCursor(client, 'stu_1', '数学', 2));
});
