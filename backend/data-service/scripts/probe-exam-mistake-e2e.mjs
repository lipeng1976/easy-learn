#!/usr/bin/env node
/**
 * 「试卷错题 MD 导入」端到端探针 —— 真 PG + 真 ima 文件 + 真解析器。
 *
 * ## 为什么需要它
 *
 * `test/exam-mistake-import.test.js` 用假 client / 假 fetch，只能证明
 * 「SQL 发对了、解析逻辑对了」。列名写错、LaTeX 里的反斜杠被吃掉、
 * ima 真实返回结构与假的不一样 —— 这些假 client 全都测不出来。
 *
 * ## 零残留
 *
 * 整段包在 `BEGIN … ROLLBACK` 里，导入 / 重复导入 / 撤销都发生在事务内，
 * 跑完**一条真实错题都不写进库**。同时快照其它来源的错题数，
 * 确认 delete 没有越界删到作业 / 打卡 / 手录的错题。
 *
 * ## 判据
 *   1. 列表端点能连真 ima（目录没建时返回 folder_missing，不报错）
 *   2. 导入真 MD 得 4 条，题干 / 答案 / 知识点 / 题号 / 年级快照都对
 *   3. 其它来源的错题一条没少
 *   4. 重复导入仍是 4 条（幂等，不翻倍）
 *   5. 撤销后 0 条，其它来源仍一条没少
 *   6. ROLLBACK 后库里 0 残留
 *
 * ## 用法
 *   node scripts/probe-exam-mistake-e2e.mjs --env-file "D:/easy_learn_home/config/local.env"
 *
 * 需要 `IMA_CREDENTIAL_SECRET`（从 env 文件读）与能访问 ima.qq.com 的网络。
 */
import assert from 'node:assert/strict';

import pg from 'pg';

import { cloudHost, loadEnv, valueOf } from './lib/env-file.mjs';
import { EXAM_MISTAKE_SOURCE_TYPE } from '../src/exam_mistake_import.js';
import {
  importExamMistakes,
  listExamMistakeFiles,
  revokeExamMistakes,
} from '../src/routes/exam.js';

// ima `错题档案-数学-2026-11-15-七上期中卷.md`（家长手工整理的 4 条错题）。
// 导入端点按 mediaId 下载，不依赖它在哪个文件夹；正式使用应放到
// `教学资料/试卷错题/`（列表端点只列那个目录）。
const MEDIA_ID =
  'markdown_cls1_c5175c8baada37638b759fbb914c7aff_9e0bb1af615342df9434e8bdd7a79d6c7520663120139695';
const STUDENT_ID = '2654d216-ffd9-4b2a-aca4-01cdc83858f8';

const { env } = loadEnv(valueOf(process.argv.slice(2), '--env-file'));
if (env.IMA_CREDENTIAL_SECRET) {
  process.env.IMA_CREDENTIAL_SECRET = env.IMA_CREDENTIAL_SECRET;
}
assert.ok(process.env.IMA_CREDENTIAL_SECRET, 'env 文件里必须有 IMA_CREDENTIAL_SECRET');

const client = new pg.Client({
  host: cloudHost(env),
  port: Number(env.PGPORT ?? 5432),
  database: env.PGDATABASE ?? 'easy_learn',
  user: env.PG_OPS_USER || env.PGUSER,
  password: (env.PG_OPS_USER ? env.PG_OPS_PASSWORD : env.PGPASSWORD) ?? env.PGPASSWORD,
  ...(env.PGSSLMODE === 'require' ? { ssl: { rejectUnauthorized: false } } : {}),
});

const ctx = {
  userId: STUDENT_ID,
  role: 'student',
  visibleStudents: [STUDENT_ID],
  fetchImpl: globalThis.fetch,
};

let passed = 0;
const ok = (label, extra = '') => {
  passed += 1;
  console.log(`  ✓ ${label}${extra ? `  ${extra}` : ''}`);
};

const countImported = async () => {
  const r = await client.query(
    `select count(*)::int as n from review_mistake
      where student_id = $1 and source_type = $2 and source_ref = $3`,
    [STUDENT_ID, EXAM_MISTAKE_SOURCE_TYPE, MEDIA_ID],
  );
  return Number(r.rows[0]?.n ?? 0);
};

const countOthers = async () => {
  const r = await client.query(
    `select count(*)::int as n from review_mistake
      where student_id = $1 and source_type <> $2`,
    [STUDENT_ID, EXAM_MISTAKE_SOURCE_TYPE],
  );
  return Number(r.rows[0]?.n ?? 0);
};

try {
  await client.connect();
  await client.query('begin');

  // 1. 列表端点：真凭证 + 真 ima。目录还没建时应当温和回 folder_missing。
  const list = await listExamMistakeFiles(client, ctx, { studentId: STUDENT_ID });
  assert.equal(list.connected, true, '凭证可用，应该连上 ima');
  assert.ok(
    list.reason === 'folder_missing' || list.files.length >= 0,
    '读 ima 不该抛异常',
  );
  ok(
    '列表端点连真 ima',
    list.reason === 'folder_missing'
      ? '目录「教学资料/试卷错题」还没建（待家长手动建）'
      : `找到 ${list.files.length} 份 MD`,
  );

  const othersBefore = await countOthers();
  assert.equal(await countImported(), 0, '探针开始前不该有这个 mediaId 的行');

  // 2. 导入真实 MD。
  const first = await importExamMistakes(client, ctx, {
    studentId: STUDENT_ID,
    mediaId: MEDIA_ID,
  });
  assert.equal(first.imported, 4);
  ok('导入真 MD', `imported=${first.imported} subject=${first.subject}`);

  const rows = (
    await client.query(
      `select subject, title, question_body, answer_key, knowledge_point,
              question_no, source_ref, source_type, state, grade, term
         from review_mistake
        where student_id = $1 and source_type = $2 and source_ref = $3
        order by question_no`,
      [STUDENT_ID, EXAM_MISTAKE_SOURCE_TYPE, MEDIA_ID],
    )
  ).rows;
  assert.equal(rows.length, 4);
  assert.equal(rows[0].subject, '数学');
  assert.match(rows[0].question_body, /2026 的相反数是/);
  assert.match(rows[0].question_body, /\\frac\{1\}\{2026\}/, 'LaTeX 反斜杠不能被吃掉');
  assert.equal(rows[0].answer_key, 'B');
  assert.equal(rows[0].knowledge_point, '相反数');
  assert.equal(rows[0].state, 'pending');
  assert.equal(rows[0].source_type, EXAM_MISTAKE_SOURCE_TYPE);
  assert.ok(rows[0].grade !== '' && rows[0].term !== '', '年级学期快照不能空');
  const numbers = rows.map((r) => r.question_no).sort();
  assert.ok(numbers.includes('23(1)'), '第23题(1) 的小问号不能丢');
  assert.ok(numbers.includes('25(1)'));
  ok('4 行字段核对', `题号 ${numbers.join('/')} · 年级 ${rows[0].grade}${rows[0].term}`);

  assert.equal(await countOthers(), othersBefore, '导入不能动其它来源的错题');
  ok('其它来源错题数不变', `${othersBefore} 条`);

  // 3. 重复导入：先删旧行再写，总量不变。
  const second = await importExamMistakes(client, ctx, {
    studentId: STUDENT_ID,
    mediaId: MEDIA_ID,
  });
  assert.equal(second.removed, 4);
  assert.equal(await countImported(), 4, '重复导入不翻倍');
  ok('重复导入幂等', `removed=${second.removed}, 仍 4 条`);

  // 4. 撤销。
  const revoked = await revokeExamMistakes(client, ctx, {
    studentId: STUDENT_ID,
    mediaId: MEDIA_ID,
  });
  assert.equal(revoked.removed, 4);
  assert.equal(await countImported(), 0);
  assert.equal(await countOthers(), othersBefore, '撤销绝不能删到其它来源');
  ok('撤销 0 残留且其它来源不变', `${othersBefore} 条`);
} finally {
  // 整段回滚：真库里一条都不留。
  try {
    await client.query('rollback');
    console.log('  ✓ ROLLBACK：真库零写入');
    passed += 1;
  } catch (e) {
    console.log(`  ! ROLLBACK 失败：${e?.message ?? e}`);
  }
  await client.end();
}

// 再开一条独立连接确认库里确实没有探针产物。
const verify = new pg.Client({
  host: cloudHost(env),
  port: Number(env.PGPORT ?? 5432),
  database: env.PGDATABASE ?? 'easy_learn',
  user: env.PG_OPS_USER || env.PGUSER,
  password: (env.PG_OPS_USER ? env.PG_OPS_PASSWORD : env.PGPASSWORD) ?? env.PGPASSWORD,
  ...(env.PGSSLMODE === 'require' ? { ssl: { rejectUnauthorized: false } } : {}),
});
await verify.connect();
const left = await verify.query(
  `select count(*)::int as n from review_mistake
    where student_id = $1 and source_type = $2 and source_ref = $3`,
  [STUDENT_ID, EXAM_MISTAKE_SOURCE_TYPE, MEDIA_ID],
);
await verify.end();
assert.equal(Number(left.rows[0]?.n ?? 0), 0, 'ROLLBACK 后不该有残留');
ok('独立连接复核 0 残留');

console.log(`\nPROBE OK · ${passed} 条通过 · 0 残留`);
