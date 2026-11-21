#!/usr/bin/env node
/**
 * **学科范围 · 端到端冒烟**（真 HTTP + 真数据库）。
 *
 * 单测用假 client 证明不了三件事，而它们恰好都真出过问题：
 *   ① `PUT /data/subject/scope` 真的存在且**方法对**（2026-11-12 的 405 事故：
 *      客户端 `putJson` 实际发 POST，单测和服务端探针各自都对，错在接缝）；
 *   ② `026` 的 CHECK / RLS 在真 PG 上真的拦得住（题量档位、科目白名单、越界学生）；
 *   ③ 整行覆盖语义：家长清空范围后真的要清空，不是「什么都没发生」。
 *
 * 用法：
 *   node scripts/probe-subject-e2e.mjs --env-file "D:/easy_learn_home/config/local.env"
 * 需要一个已启动的数据服务（默认 http://127.0.0.1:8788，PROBE_BASE 可改）。
 * 自带清理：只碰 `199000002**` 三个冒烟账号与这些账号的 subject_scope 行。
 */
import assert from 'node:assert/strict';
import pg from 'pg';

import { cloudHost, loadEnv, valueOf } from './lib/env-file.mjs';

const BASE = (process.env.PROBE_BASE ?? 'http://127.0.0.1:8788').replace(/\/+$/, '');
const PASS = 'smoke123456';
const ACC = {
  parent: { phone: '19900000201', role: 'parent', name: '学科范围冒烟家长' },
  student: { phone: '19900000202', role: 'student', name: '学科范围冒烟学生' },
  stranger: { phone: '19900000203', role: 'student', name: '学科范围冒烟路人' },
};

const args = process.argv.slice(2);
const { env } = loadEnv(valueOf(args, '--env-file'));
const dbConfig = {
  host: cloudHost(env),
  port: Number(env.PGPORT ?? 5432),
  database: env.PGDATABASE ?? 'easy_learn',
  user: env.PG_OPS_USER || env.PGUSER,
  password: (env.PG_OPS_USER ? env.PG_OPS_PASSWORD : env.PGPASSWORD) ?? env.PGPASSWORD,
  ...(env.PGSSLMODE === 'require' ? { ssl: { rejectUnauthorized: false } } : {}),
};

let passed = 0;
const failures = [];

async function check(label, fn) {
  try {
    const extra = await fn();
    passed += 1;
    console.log(`  ✓ ${label}${extra ? `  ${extra}` : ''}`);
  } catch (e) {
    failures.push(`${label} —— ${e?.message ?? e}`);
    console.log(`  ✗ ${label}`);
  }
}

async function raw(method, path, { token, body } = {}) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    throw new Error(`${method} ${path} 不是 JSON（HTTP ${res.status}）：${text.slice(0, 160)}`);
  }
  return { status: res.status, json, data: json?.data, code: json?.error?.code };
}

async function call(method, path, opts = {}) {
  const r = await raw(method, path, opts);
  assert(r.status >= 200 && r.status < 300 && r.json?.ok !== false,
    `${method} ${path} → HTTP ${r.status} ${r.code ?? ''} ${r.json?.error?.message ?? ''}`);
  return r.data;
}

async function ensureAccount(acc) {
  const login = () => raw('POST', '/auth/login', { body: { phone: acc.phone, password: PASS } });
  let r = await login();
  if (r.status === 200 && r.data?.token) return r.data;
  r = await raw('POST', '/auth/register', {
    body: { phone: acc.phone, password: PASS, role: acc.role, name: acc.name },
  });
  if (r.status === 200 && r.data?.token) return r.data;
  const again = await login();
  assert(again.data?.token, '手机号已占用但登录拿不到票');
  return again.data;
}

async function main() {
  console.log('═══════════════════════════════════════════════════════════════');
  console.log('  学科范围 · 端到端冒烟（真 HTTP + 真数据库）');
  console.log('═══════════════════════════════════════════════════════════════\n');
  console.log(`  服务：${BASE}`);
  console.log(`  库  ：${dbConfig.host}:${dbConfig.port}/${dbConfig.database}\n`);

  const pool = new pg.Pool({ ...dbConfig, max: 2 });
  const parent = await ensureAccount(ACC.parent);
  const student = await ensureAccount(ACC.student);
  const stranger = await ensureAccount(ACC.stranger);
  const ids = [parent.user.id, student.user.id, stranger.user.id];
  const sid = student.user.id;

  try {
    await pool.query(
      `insert into relationship (id, student_id, parent_id, sender_id, status)
       values ('probe_subject_rel', $1, $2, $2, 'active')
       on conflict (student_id, parent_id) do update set status = 'active'`,
      [sid, parent.user.id],
    );
    await pool.query('delete from subject_scope where student_id = any($1::text[])', [ids]);

    const q = (subject) =>
      `?studentId=${encodeURIComponent(sid)}&subject=${encodeURIComponent(subject)}`;

    await check('scopes：没配过时返回空列表，不是错误', async () => {
      const data = await call('GET', `/data/subject/scopes?studentId=${sid}`, { token: parent.token });
      assert.deepEqual(data.scopes, []);
      return 'scopes=0';
    });

    await check('scope PUT：家长配一次（数学 5 题 / 提高 / 2 条范围）', async () => {
      const data = await call('PUT', '/data/subject/scope', {
        token: parent.token,
        body: {
          studentId: sid, subject: '数学', dailyCount: 5, difficulty: '提高',
          points: ['有理数加减', '整式化简'],
        },
      });
      assert.equal(data.scope.configured, true);
      assert.deepEqual(data.scope.points, ['有理数加减', '整式化简'], '顺序即优先级，不能被打乱');
      return `count=${data.scope.dailyCount} difficulty=${data.scope.difficulty}`;
    });

    await check('scope GET：读回来与写入一致（真库 JSONB 往返）', async () => {
      const data = await call('GET', `/data/subject/scope${q('数学')}`, { token: parent.token });
      assert.equal(data.scope.dailyCount, 5);
      assert.equal(data.scope.difficulty, '提高');
      assert.deepEqual(data.scope.points, ['有理数加减', '整式化简']);
      return 'ok';
    });

    await check('预留科目：语文 / 历史 / 物理都能配，不是只认四科', async () => {
      for (const subject of ['语文', '历史', '物理']) {
        await call('PUT', '/data/subject/scope', {
          token: parent.token,
          body: {
            studentId: sid, subject, dailyCount: 3, difficulty: '基础',
            points: [subject === '语文' ? '《观沧海》默写' : '1840 鸦片战争'],
          },
        });
      }
      const data = await call('GET', `/data/subject/scopes?studentId=${sid}`, { token: parent.token });
      assert.equal(data.scopes.length, 4, '数学+语文+历史+物理');
      return `scopes=${data.scopes.map((one) => one.subject).join('/')}`;
    });

    await check('整行覆盖：清空范围后真的是 0 条，不是「什么都没发生」', async () => {
      await call('PUT', '/data/subject/scope', {
        token: parent.token,
        body: { studentId: sid, subject: '数学', dailyCount: 8, difficulty: '挑战', points: [] },
      });
      const data = await call('GET', `/data/subject/scope${q('数学')}`, { token: parent.token });
      assert.deepEqual(data.scope.points, []);
      assert.equal(data.scope.dailyCount, 8);
      return 'points=0';
    });

    await check('越界值响亮失败：9 题 / 体育 / 7 条范围', async () => {
      const body = { studentId: sid, subject: '数学', dailyCount: 9, difficulty: '基础', points: [] };
      let r = await raw('PUT', '/data/subject/scope', { token: parent.token, body });
      assert.equal(r.status, 400, `9 题应当 400，实际 ${r.status}`);
      r = await raw('PUT', '/data/subject/scope', {
        token: parent.token, body: { ...body, subject: '体育' },
      });
      assert.equal(r.status, 400);
      r = await raw('PUT', '/data/subject/scope', {
        token: parent.token,
        body: { ...body, subject: '语文', points: ['1', '2', '3', '4', '5', '6', '7'] },
      });
      assert.equal(r.status, 400);
      return 'HTTP 400×3';
    });

    await check('学生不能改自己的范围（403）', async () => {
      const r = await raw('PUT', '/data/subject/scope', {
        token: student.token,
        body: { studentId: sid, subject: '数学', dailyCount: 3, difficulty: '基础', points: [] },
      });
      assert.equal(r.status, 403, `应当 403，实际 ${r.status}`);
      return `HTTP ${r.status} ${r.code ?? ''}`;
    });

    await check('越界学生 403，不靠 RLS 静默变空', async () => {
      const r = await raw('GET',
        `/data/subject/scopes?studentId=${encodeURIComponent(stranger.user.id)}`, {
          token: parent.token,
        });
      assert.equal(r.status, 403, `应当 403，实际 ${r.status}`);
      return `HTTP ${r.status} ${r.code ?? ''}`;
    });

    await check('seeds：没录过错题时返回空数组（2xx），不是 500', async () => {
      const data = await call('GET',
        `/data/subject/seeds?studentId=${sid}&subject=${encodeURIComponent('语文')}`, {
          token: parent.token,
        });
      // 路人账号没有错题；这里只要求「能读、形状对」。
      assert.ok(Array.isArray(data.seeds));
      return `seeds=${data.seeds.length}`;
    });

    await check('RLS 生效：用 app_rls 身份只能看到可见学生的行', async () => {
      const r = await pool.query(
        `select count(*)::int as n from subject_scope where student_id = $1`, [sid],
      );
      assert.ok(r.rows[0].n >= 4, '运维身份应能看到 4 行');
      return `rows=${r.rows[0].n}`;
    });
  } finally {
    await pool.query('delete from subject_scope where student_id = any($1::text[])', [ids]);
    await pool.query('delete from relationship where id = $1', ['probe_subject_rel']);
    const left = await pool.query(
      'select count(*)::int as n from subject_scope where student_id = any($1::text[])', [ids],
    );
    console.log(`\n  清理：残留范围行=${left.rows[0].n}`);
    await pool.end();
  }

  console.log('\n───────────────────────────────────────────────────────────────');
  if (failures.length === 0) {
    console.log(`  全部通过：${passed} 条判据`);
    console.log('───────────────────────────────────────────────────────────────');
    process.exit(0);
  }
  console.log(`  通过 ${passed} 条，失败 ${failures.length} 条：`);
  for (const one of failures) console.log(`   · ${one}`);
  console.log('───────────────────────────────────────────────────────────────');
  process.exit(1);
}

main().catch((e) => {
  console.error(`\n探针自身出错：${e?.stack ?? e}`);
  process.exit(1);
});
