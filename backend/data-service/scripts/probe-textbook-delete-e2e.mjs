#!/usr/bin/env node
/**
 * 「删除已导入教材」端到端探针 —— 真 HTTP + 真 PG + 真 RLS。
 *
 * ## 为什么需要它
 *
 * `test/textbook-delete.test.js` 用假 client，只能证明「SQL 发对了」：
 * 列名写错、RLS 写策略不放行、事务里某条语句报错，假 client 全都测不出来。
 * 这条链路以前栽过（`date >= $2` 写成 `$2::text` → 42883），所以新增写端点
 * 必须有一次走真库的冒烟。
 *
 * ## 判据
 *   1. 冒烟学生登录后能在书列表里看到自己那本临时教材（RLS 可见）
 *   2. `POST /data/textbook/delete` 200，且 `scopeCleared=true`（真的清了范围）
 *   3. 库里书 / 章节都没了，`subject_scope.book_id` 为 null、起始节归 1
 *   4. 再删同一个 id → 404 `not_found`，不是假装成功
 *   5. 书列表里不再有那本
 *   6. 跑完数据库 0 残留（临时账号、临时 scope 都清掉）
 *
 * ## 用法
 *   node scripts/probe-textbook-delete-e2e.mjs --env-file "D:/easy_learn_home/config/local.env"
 *
 * 需要一个**已启动的数据服务**（默认 http://127.0.0.1:8788，可用 PROBE_BASE 改）。
 * 只碰手机号 `19900000088` 这一个冒烟账号，自带清理。
 */
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

import pg from 'pg';

import { cloudHost, loadEnv, valueOf } from './lib/env-file.mjs';

const BASE = (process.env.PROBE_BASE ?? 'http://127.0.0.1:8788').replace(/\/+$/, '');
const PASS = 'smoke123456';
const PHONE = '19900000088';
const BOOK_ID = `tb_probe_${randomUUID().replace(/-/g, '').slice(0, 12)}`;

const { env } = loadEnv(valueOf(process.argv.slice(2), '--env-file'));
const pool = new pg.Pool({
  host: cloudHost(env),
  port: Number(env.PGPORT ?? 5432),
  database: env.PGDATABASE ?? 'easy_learn',
  user: env.PG_OPS_USER || env.PGUSER,
  password: (env.PG_OPS_USER ? env.PG_OPS_PASSWORD : env.PGPASSWORD) ?? env.PGPASSWORD,
  ...(env.PGSSLMODE === 'require' ? { ssl: { rejectUnauthorized: false } } : {}),
});

async function call(method, path, { token, body } = {}) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await res.text();
  const json = text ? JSON.parse(text) : null;
  if (!res.ok || json?.ok === false) {
    const err = new Error(
      `${method} ${path} → HTTP ${res.status} ${json?.error?.code ?? ''} ${json?.error?.message ?? ''}`,
    );
    err.code = json?.error?.code;
    err.status = res.status;
    throw err;
  }
  return json?.data;
}

async function ensureStudent() {
  const login = () => call('POST', '/auth/login', { body: { phone: PHONE, password: PASS } });
  try {
    return await login();
  } catch (e) {
    if (e.status !== 400 && e.status !== 401) throw e;
  }
  try {
    return await call('POST', '/auth/register', {
      body: { phone: PHONE, password: PASS, role: 'student', name: '教材删除探针' },
    });
  } catch (e) {
    if (e.code === 'phone_taken' || e.status === 409) return login();
    throw e;
  }
}

let studentId = '';
let passed = 0;
const ok = (label, extra = '') => {
  passed += 1;
  console.log(`  ✓ ${label}${extra ? `  ${extra}` : ''}`);
};

try {
  const account = await ensureStudent();
  const token = account.token;
  studentId = account.user.id;
  assert.ok(token && studentId, '登录必须拿到票和学生 id');
  ok('冒烟学生登录');

  // 造一本临时教材 + 指向它的范围。用运维身份写，绕开 RLS —— 这是探针的「夹具」，
  // 被测的是后面那条 HTTP 删除链路（它走 app_rls + visible_students）。
  await pool.query(
    `insert into subject_book (id, student_id, subject, title, source_media_id, unit_count)
     values ($1, $2, '数学', '探针临时教材', '', 2)`,
    [BOOK_ID, studentId],
  );
  await pool.query(
    `insert into subject_unit (id, book_id, student_id, unit_no, title, summary)
     values ($1, $2, $3, 1, '第1节', '数轴'), ($4, $2, $3, 2, '第2节', '整式')`,
    [`tu_p1_${BOOK_ID}`, BOOK_ID, studentId, `tu_p2_${BOOK_ID}`],
  );
  await pool.query(
    `insert into subject_scope (student_id, subject, book_id, start_unit_no)
     values ($1, '数学', $2, 7)
     on conflict (student_id, subject) do update
       set book_id = excluded.book_id, start_unit_no = excluded.start_unit_no`,
    [studentId, BOOK_ID],
  );

  const before = await call(
    'GET',
    `/data/textbook/books?studentId=${encodeURIComponent(studentId)}&subject=${encodeURIComponent('数学')}`,
    { token },
  );
  assert.ok(before.books.some((b) => b.id === BOOK_ID), '临时书必须对这个学生可见');
  ok('书列表能读到临时教材（RLS 可见）');

  const out = await call('POST', '/data/textbook/delete', {
    token,
    body: { studentId, bookId: BOOK_ID },
  });
  assert.equal(out.bookId, BOOK_ID);
  assert.equal(out.scopeCleared, true, '范围没清 = 界面还显示教材、出题静默退回手填');
  ok('HTTP 删除 200 且 scopeCleared=true');

  const after = await pool.query(
    `select
       (select count(*) from subject_book where id = $1) as books,
       (select count(*) from subject_unit where book_id = $1) as units,
       (select book_id from subject_scope where student_id = $2 and subject = '数学') as scope_book,
       (select start_unit_no from subject_scope where student_id = $2 and subject = '数学') as start_no`,
    [BOOK_ID, studentId],
  );
  const row = after.rows[0];
  assert.equal(Number(row.books), 0);
  assert.equal(Number(row.units), 0);
  assert.equal(row.scope_book, null);
  assert.equal(Number(row.start_no), 1);
  ok('真库：书 / 章节已删，范围清空且起始节归 1');

  let secondCode = '';
  try {
    await call('POST', '/data/textbook/delete', {
      token,
      body: { studentId, bookId: BOOK_ID },
    });
  } catch (e) {
    secondCode = e.code ?? '';
  }
  assert.equal(secondCode, 'not_found', '删不到还回成功 = 刷新后书又回来');
  ok('重复删除回 404 not_found');

  const listAfter = await call(
    'GET',
    `/data/textbook/books?studentId=${encodeURIComponent(studentId)}&subject=${encodeURIComponent('数学')}`,
    { token },
  );
  assert.ok(!listAfter.books.some((b) => b.id === BOOK_ID));
  ok('书列表里不再有那本');
} finally {
  // ── 清理：不留账号、不留 scope 行 ──
  const cleanup = await pool.connect();
  try {
    await cleanup.query('begin');
    await cleanup.query('delete from subject_unit where book_id = $1', [BOOK_ID]);
    await cleanup.query('delete from subject_book where id = $1', [BOOK_ID]);
    if (studentId) {
      await cleanup.query('delete from subject_scope where student_id = $1', [studentId]);
      await cleanup.query('delete from app_user_credential where user_id = $1', [studentId]);
      try {
        await cleanup.query('delete from user_session where user_id = $1', [studentId]);
      } catch { /* 表不存在不算失败 */ }
      await cleanup.query('delete from app_user where id = $1', [studentId]);
    }
    await cleanup.query('commit');
  } catch (e) {
    await cleanup.query('rollback').catch(() => {});
    throw e;
  } finally {
    cleanup.release();
  }

  const left = await pool.query(
    `select
       (select count(*) from app_user where phone = $1) as users,
       (select count(*) from subject_book where id = $2) as books`,
    [PHONE, BOOK_ID],
  );
  assert.equal(Number(left.rows[0].users), 0);
  assert.equal(Number(left.rows[0].books), 0);
  ok('跑完数据库 0 残留');
  await pool.end();
}

console.log(`\n教材删除端到端探针：${passed} 条通过`);
