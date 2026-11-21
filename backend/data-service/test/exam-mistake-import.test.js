import assert from 'node:assert/strict';
import test from 'node:test';

import { encryptCredential } from '../src/ima_repository.js';
import {
  EXAM_MISTAKE_FOLDER_PATH,
  EXAM_MISTAKE_SOURCE_TYPE,
  parseExamMistakes,
} from '../src/exam_mistake_import.js';
import {
  importExamMistakes,
  listExamMistakeFiles,
  revokeExamMistakes,
} from '../src/routes/exam.js';

/**
 * 试卷错题导入 · 判据。
 *
 * 盯的失败全是「不报错、只表现为功能安静地不对」：
 *   ① 把末尾「备查 / 复习建议」当错题 → 错题本多出一批不存在的题；
 *   ② 认了 App 自动推送的「错题档案」镜像 → 83 条旧错题整批重复灌回去；
 *   ③ 删旧行漏 `source_type` → 手工录入 / 作业批改 / 打卡回流的错题一起没；
 *   ④ 删旧行漏 `student_id` → 跨孩子删数据；
 *   ⑤ 没题干也收 → 组卷排出一道空白题；
 *   ⑥ 没连 ima 就弹红条 → 违反「可选能力缺失不许报错」。
 *
 * 真样本来自 ima `错题档案-数学-2026-11-15-七上期中卷.md`（4 条错题），
 * 用 String.raw 保留 LaTeX 的反斜杠。
 */

const SECRET = 'test-secret-0123456789abcdefghijklmn';

const REAL_MD = String.raw`# 错题档案 · 数学（2026年下学期七年级期中检测卷）

- 导出于：2026-11-15
- 学科：数学
- 来源试卷：2026年下学期七年级期中检测数学试卷（共4页，25题，满分120分）
- 本次归档错题数：4 条；涉及知识点：3 个
## 知识点总览

|知识点|条目数|累计错误次数|
|---|---|---|
|相反数|1|1|
|科学记数法|1|1|
|新定义运算|1|1|
|二维码二进制编码（实践题读图）|1|1|

## 知识点：相反数

### 七上期中检测卷 · 第1题 · 相反数

- 学科：数学
- 题干：2026 的相反数是（ ）
A. 2026 　 B. -2026 　 C. $\frac{1}{2026}$ 　 D. $-\frac{1}{2026}$
- 错因：把「相反数」与「倒数」混淆。相反数是仅符号不同的两个数，2026 的相反数是 -2026；学生勾选了 C（$\frac{1}{2026}$），该选项实际是 2026 的倒数。
- 正确答案：B
- 来源作业：2026年下学期七年级期中检测卷 第1题（第1页）
- 状态：待复习；错误次数：1；最近做错：2026-11-15
## 知识点：科学记数法

### 七上期中检测卷 · 第2题 · 科学记数法

- 学科：数学
- 题干：今年是中国工农红军长征胜利90周年。从1934年10月至1936年10月，红军长征历时两年多，总行程达65000余里。数据65000用科学记数法表示为（ ）
A. $6.5\times10^3$ 　 B. $65\times10^3$ 　 C. $6.5\times10^4$ 　 D. $0.65\times10^5$
- 错因：未掌握科学记数法「$a\times10^n$ 且 $1\le|a|<10$」的形式要求，误选了系数不符合该范围的 D 选项（$0.65\times10^5$）。而 $65000=6.5\times10^4$。
- 正确答案：C
- 来源作业：2026年下学期七年级期中检测卷 第2题（第1页）
- 状态：待复习；错误次数：1；最近做错：2026-11-15
## 知识点：新定义运算

### 七上期中检测卷 · 第23题(1) · 定义新运算 ⊗

- 学科：数学
- 题干：定义一种非零有理数运算「⊗」。观察：① $4\otimes2=+(4-2)=2$；② $(-4)\otimes(-2)=+(4-2)=2$；③ $2\otimes(-4)=-(4-2)=-2$；④ $(-2)\otimes4=-(4-2)=-2$。计算：$(-6)\otimes3$。
- 错因：未按示例归纳出运算规律（同号取正、异号取负，结果等于两数绝对值之差），误把「⊗」当作普通减法直接算成 $-6-3=-9$ 一类的减法，未处理符号规则，计算结果错误。
- 正确答案：根据规律 $(-6)\otimes3=-(6-3)=-3$
- 来源作业：2026年下学期七年级期中检测卷 第23题（第3页）
- 状态：待复习；错误次数：1；最近做错：2026-11-15
## 知识点：二维码二进制编码（实践题读图）

### 七上期中检测卷 · 第25题(1) · 二进制编码读图

- 学科：数学
- 题干：橘子洲头景区预约二维码中，每行5个方格，黑色格代表1、白色格代表0，每行构成一个二进制数，转换为十进制数后不足两位在前补0，五行拼接为10位预约码（前4位月日、第5-6位入园时段、第7-8位预约人数、末2位校验码）。图2为珍珍收到的二维码，要求写出第一、第二行代表的二进制数并求出预约日期。
- 错因：读图时黑白格的对应关系（黑=1、白=0）与实际图形不一致，且各行二进制的读取顺序出现偏差，导致第一、第二行的二进制数写错，进而使推算出的预约日期出错。
- 正确答案：应依据图2实际黑白格逐行读取并转十进制后拼接，得出正确的月、日
- 来源作业：2026年下学期七年级期中检测卷 第25题（第4页）
- 状态：待复习；错误次数：1；最近做错：2026-11-15
## 本次核对中判定为作答正确、不纳入错题的内容（备查）

- 选择题第3-10题：单项式系数与次数（3）、正负数表示（4）、代数式书写规范（5）、算筹正负术（6）、非负性求值（7）、有理数概念辨析（8）、数轴比较大小（9）、杠杆原理反比例关系（10）均正确。
- 填空题第11-16题：化简（11）、负数比较大小（12）、四舍五入（13）、积分多项式（14）、整体代入求值（15）、密码破译（16）均正确。
## 复习建议

- 概念辨析强化：相反数、倒数、绝对值等易混概念制作对比卡，明确「相反数=符号不同」、「倒数=乘积为1」。
- 科学记数法专项：牢记 $a\times10^n$ 中 $1\le|a|<10$ 的约束。
`;

/** App 自动推送的镜像：`## <知识点>`（没有「知识点：」前缀）。必须解析为 0 条。 */
const MIRROR_MD = String.raw`# 错题档案 · 数学（按知识点聚合）

- 导出于：2026-11-15
- 学科：数学
- 错题总数：83 条；知识点：34 个

## 知识点总览

| 知识点 | 条目数 | 累计错误次数 |
| --- | --- | --- |
| 有理数混合运算 | 15 | 15 |

## 有理数混合运算

### 第 1 题

- 学科：数学
- 题干：计算 $-3+5\times2$。
- 错因：运算顺序错。
`;

// ===== 1. 解析器 =====

test('真样本解析出恰好 4 条，末尾「备查/复习建议」不产生额外错题', () => {
  const out = parseExamMistakes(REAL_MD);
  assert.equal(out.items.length, 4);
  assert.equal(out.subject, '数学');
  assert.match(out.examTitle, /期中检测数学试卷/);
  assert.deepEqual(out.items.map((x) => x.knowledgePoint), [
    '相反数', '科学记数法', '新定义运算', '二维码二进制编码（实践题读图）',
  ]);
});

test('题干跨行续接且 LaTeX 原样保留（组卷/公式渲染靠它）', () => {
  const first = parseExamMistakes(REAL_MD).items[0];
  assert.match(first.questionBody, /^2026 的相反数是/);
  assert.match(first.questionBody, /A\. 2026/);
  assert.match(first.questionBody, /\$\\frac\{1\}\{2026\}\$/);
  assert.equal(first.answerKey, 'B');
  assert.match(first.wrongReason, /倒数/);
});

test('题号从 ### 标题取，第23题(1) 不能被吞成 23', () => {
  const items = parseExamMistakes(REAL_MD).items;
  assert.deepEqual(items.map((x) => x.questionNo), ['1', '2', '23(1)', '25(1)']);
  assert.match(items[2].sourceHomeworkTitle, /第23题/);
});

test('格式闸：自动生成的「错题档案」镜像解析为 0 条', () => {
  assert.equal(parseExamMistakes(MIRROR_MD).items.length, 0);
});

test('没有题干的段落跳过，不造一道不存在的题', () => {
  const md = [
    '# 错题档案 · 数学（模拟卷）',
    '- 学科：数学',
    '## 知识点：相反数',
    '### 第1题 · 相反数',
    '- 错因：概念混淆',
    '- 正确答案：B',
    '## 知识点：绝对值',
    '### 第2题 · 绝对值',
    '- 题干：|-3| = ?',
    '- 正确答案：3',
  ].join('\n');
  const out = parseExamMistakes(md);
  assert.equal(out.items.length, 1);
  assert.equal(out.items[0].knowledgePoint, '绝对值');
});

test('字段多行、错误次数、学科兜底', () => {
  const md = [
    '# 错题档案 · 物理（月考卷）',
    '- 来源试卷：第一次月考',
    '## 知识点：浮力',
    '### 第3题 · 浮力',
    '- 题干：一个物体浸没在水中',
    '  续行：求浮力大小',
    '- 状态：待复习；错误次数：3；最近做错：2026-11-15',
  ].join('\n');
  const item = parseExamMistakes(md).items[0];
  assert.equal(item.subject, '物理');
  assert.match(item.questionBody, /续行：求浮力大小/);
  assert.equal(item.wrongCount, 3);
  assert.equal(item.sourceHomeworkTitle, '第一次月考');
});

test('常量单点：目录与来源词不漂移', () => {
  assert.deepEqual(EXAM_MISTAKE_FOLDER_PATH, ['教学资料', '试卷错题']);
  assert.equal(EXAM_MISTAKE_SOURCE_TYPE, 'ima_exam');
});

// ===== 2. 路由（假 client + 假 ima 下载）=====

function fakeFetch(text) {
  return async (url) => {
    const one = String(url);
    if (one.includes('get_knowledge_list')) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({
          code: 0,
          data: {
            knowledge_list: [
              { media_id: 'folder_root', media_type: 99, title: '教学资料' },
              { media_id: 'folder_exam', media_type: 99, title: '试卷错题' },
              { media_id: 'm_exam_1', media_type: 7, title: '七上期中卷.md' },
            ],
            is_end: true,
            next_cursor: 'unused',
          },
        }),
      };
    }
    if (one.includes('get_media_info')) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({
          code: 0,
          data: { url_info: { url: 'https://cos.local/exam.md', headers: {} } },
        }),
      };
    }
    if (one.includes('cos.local')) {
      return {
        ok: true,
        status: 200,
        headers: { get: () => null },
        arrayBuffer: async () => Buffer.from(text, 'utf8'),
      };
    }
    throw new Error(`未预期的请求：${one}`);
  };
}

function makeClient({ md = REAL_MD, grade = '初一', term = '上', failIma = false } = {}) {
  const log = [];
  const enc = encryptCredential({ clientid: 'cid', apikey: 'akey' }, SECRET);
  return {
    log,
    async query(sql, params = []) {
      log.push({ sql: String(sql).replace(/\s+/g, ' ').trim(), params });
      if (/from ima_student_kb where student_id/.test(sql)) {
        return failIma
          ? { rowCount: 0, rows: [] }
          : { rowCount: 1, rows: [{ kb_id: 'kb1', owner_user_id: 'parent-1', kb_name: '伴学' }] };
      }
      if (/from ima_credential where owner_user_id/.test(sql)) {
        return {
          rowCount: 1,
          rows: [{
            clientid_enc: enc.clientidEnc,
            apikey_enc: enc.apikeyEnc,
            status: 'active',
            kb_owner_name: '伴学',
          }],
        };
      }
      if (/from app_user where id/.test(sql)) {
        return { rowCount: 1, rows: [{ grade, term }] };
      }
      if (/select source_ref, count/.test(sql)) {
        return { rowCount: 0, rows: [] };
      }
      return { rowCount: 4, rows: [] };
    },
  };
}

function parentCtx(fetchImpl) {
  return {
    userId: 'parent-1',
    role: 'parent',
    visibleStudents: ['s1'],
    fetchImpl,
  };
}

async function withSecret(fn) {
  const saved = process.env.IMA_CREDENTIAL_SECRET;
  process.env.IMA_CREDENTIAL_SECRET = SECRET;
  try { await fn(); } finally {
    if (saved == null) delete process.env.IMA_CREDENTIAL_SECRET;
    else process.env.IMA_CREDENTIAL_SECRET = saved;
  }
}

test('导入 = 4 条 INSERT，且先按三条件删旧行（幂等），不碰 homework_id', async () => {
  await withSecret(async () => {
    const client = makeClient();
    const out = await importExamMistakes(client, parentCtx(fakeFetch(REAL_MD)), {
      studentId: 's1', mediaId: 'm_exam_1',
    });
    assert.equal(out.imported, 4);
    assert.equal(out.subject, '数学');

    const del = client.log.find((one) => /^delete from review_mistake/.test(one.sql));
    assert.ok(del, '幂等靠这条 delete');
    assert.match(del.sql, /student_id = \$1/);
    assert.match(del.sql, /source_type = \$2/);
    assert.match(del.sql, /source_ref = \$3/);
    assert.deepEqual(del.params, ['s1', EXAM_MISTAKE_SOURCE_TYPE, 'm_exam_1']);
    assert.ok(client.log.indexOf(del) < client.log.findIndex((one) => /insert into review_mistake/.test(one.sql)));

    const inserts = client.log.filter((one) => /insert into review_mistake/.test(one.sql));
    assert.equal(inserts.length, 4);
    for (const one of inserts) {
      assert.doesNotMatch(one.sql, /homework_id/, 'mediaId 塞进 homework_id 会让作业详情页查一个不存在的行');
      assert.equal(one.params[1], 's1');
      assert.equal(one.params[16], 'm_exam_1', 'source_ref 必须是 mediaId');
      assert.equal(one.params[13], EXAM_MISTAKE_SOURCE_TYPE);
    }
    assert.equal(inserts[0].params[3], '七上期中检测卷 · 第1题 · 相反数');
    assert.match(inserts[0].params[4], /2026 的相反数是/);
    assert.equal(inserts[0].params[7], 'B');
    assert.equal(inserts[0].params[10], '相反数');
    assert.equal(inserts[0].params[14], '初一', '错题快照记学生当前年级');
    assert.equal(inserts[0].params[15], '上');
  });
});

test('重复导入同一 mediaId：每次都先删旧行，不叠加', async () => {
  await withSecret(async () => {
    const client = makeClient();
    const ctx = parentCtx(fakeFetch(REAL_MD));
    await importExamMistakes(client, ctx, { studentId: 's1', mediaId: 'm_exam_1' });
    const second = await importExamMistakes(client, ctx, { studentId: 's1', mediaId: 'm_exam_1' });
    assert.equal(second.removed, 4);
    const dels = client.log.filter((one) => /^delete from review_mistake/.test(one.sql));
    assert.equal(dels.length, 2);
    assert.equal(client.log.filter((one) => /insert into review_mistake/.test(one.sql)).length, 8);
  });
});

test('撤销只删本来源本学生的行，重复撤销幂等不报错', async () => {
  const client = makeClient();
  const first = await revokeExamMistakes(client, parentCtx(), { studentId: 's1', mediaId: 'm_exam_1' });
  assert.equal(first.removed, 4);
  const sql = client.log[0].sql;
  assert.match(sql, /student_id = \$1/);
  assert.match(sql, /source_type = \$2/);
  assert.match(sql, /source_ref = \$3/);
  assert.deepEqual(client.log[0].params, ['s1', EXAM_MISTAKE_SOURCE_TYPE, 'm_exam_1']);

  const empty = makeClient();
  empty.query = async (sqlText, params) => {
    empty.log.push({ sql: sqlText, params });
    return { rowCount: 0, rows: [] };
  };
  const second = await revokeExamMistakes(empty, parentCtx(), { studentId: 's1', mediaId: 'm_new' });
  assert.equal(second.removed, 0);
});

test('0 道错题（误选自动镜像）→ 响亮 400，且一条删除/插入都不发', async () => {
  await withSecret(async () => {
    const client = makeClient();
    await assert.rejects(
      () => importExamMistakes(client, parentCtx(fakeFetch(MIRROR_MD)), {
        studentId: 's1', mediaId: 'm_mirror',
      }),
      (e) => e.code === 'bad_request',
    );
    const sql = client.log.map((one) => one.sql).join('\n');
    assert.doesNotMatch(sql, /delete from review_mistake/);
    assert.doesNotMatch(sql, /insert into review_mistake/);
  });
});

test('没连 ima → 列表恒 2xx connected:false，导入给温和 400', async () => {
  await withSecret(async () => {
    const client = makeClient({ failIma: true });
    const list = await listExamMistakeFiles(client, parentCtx(), { studentId: 's1' });
    assert.equal(list.connected, false);
    assert.equal(list.reason, 'ima_unavailable');
    assert.deepEqual(list.files, []);
    await assert.rejects(
      () => importExamMistakes(client, parentCtx(), { studentId: 's1', mediaId: 'm_exam_1' }),
      (e) => e.code === 'bad_request',
    );
  });
});

test('越界学生 → 拒绝，且不发任何写 SQL', async () => {
  await withSecret(async () => {
    const client = makeClient();
    await assert.rejects(
      () => importExamMistakes(client, parentCtx(fakeFetch(REAL_MD)), {
        studentId: 's_other', mediaId: 'm_exam_1',
      }),
    );
    assert.doesNotMatch(client.log.map((one) => one.sql).join('\n'), /insert into review_mistake/);
    await assert.rejects(
      () => revokeExamMistakes(client, parentCtx(), { studentId: 's_other', mediaId: 'm_exam_1' }),
    );
  });
});

test('列表标出已导入条数，且只按本来源统计', async () => {
  await withSecret(async () => {
    const client = makeClient();
    client.query = async (sql, params) => {
      client.log.push({ sql: String(sql).replace(/\s+/g, ' ').trim(), params });
      if (/from ima_student_kb where student_id/.test(sql)) {
        return { rowCount: 1, rows: [{ kb_id: 'kb1', owner_user_id: 'parent-1', kb_name: '伴学' }] };
      }
      if (/from ima_credential where owner_user_id/.test(sql)) {
        const enc = encryptCredential({ clientid: 'cid', apikey: 'akey' }, SECRET);
        return {
          rowCount: 1,
          rows: [{
            clientid_enc: enc.clientidEnc,
            apikey_enc: enc.apikeyEnc,
            status: 'active',
          }],
        };
      }
      if (/select source_ref, count/.test(sql)) {
        assert.match(sql, /source_type = \$2/);
        assert.equal(params[1], EXAM_MISTAKE_SOURCE_TYPE);
        return { rowCount: 1, rows: [{ source_ref: 'm_exam_1', n: 4 }] };
      }
      return { rowCount: 0, rows: [] };
    };
    const out = await listExamMistakeFiles(client, parentCtx(fakeFetch(REAL_MD)), { studentId: 's1' });
    assert.equal(out.connected, true);
    assert.equal(out.files.length, 1);
    assert.equal(out.files[0].importedCount, 4);
    assert.equal(out.folderPath, '教学资料/试卷错题');
  });
});
