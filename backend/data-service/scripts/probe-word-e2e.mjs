#!/usr/bin/env node
/**
 * **英语单词打卡 · 端到端冒烟**（真 HTTP + 真数据库）。
 *
 * 单测用假 client，证明的是「SQL 发对了」；RLS 策略本身证明的是「拦得住」。
 * 两者都证明不了这七条端点拼起来能不能跑：登录拿票 → 家长配范围 →
 * 学生读词表 → 交卷摘要 → 家长读历史 → 越界 403 → 清理。
 * `day::text` / `$2::date` 这类只在真 PG 上才暴露的坑尤其要靠它盯。
 *
 * ## 用法
 *   node scripts/probe-word-e2e.mjs --env-file "D:/easy_learn_home/config/local.env"
 *
 * 需要一个**已启动的数据服务**（默认 http://127.0.0.1:8788，PROBE_BASE 可改）。
 * 自带清理：只碰手机号前缀 `199000001` 的三个冒烟账号与固定 id 的词表行。
 */
import assert from 'node:assert/strict';
import pg from 'pg';

import { cloudHost, loadEnv, valueOf } from './lib/env-file.mjs';

const BASE = (process.env.PROBE_BASE ?? 'http://127.0.0.1:8788').replace(/\/+$/, '');
const PASS = 'smoke123456';
const ACC = {
  parent: { phone: '19900000101', role: 'parent', name: '词表冒烟家长' },
  student: { phone: '19900000102', role: 'student', name: '词表冒烟学生' },
  loner: { phone: '19900000103', role: 'student', name: '词表冒烟路人' },
};
const BOOK_ID = 'probe_word_book_a';
const LONER_BOOK_ID = 'probe_word_book_b';
const DAY = '2026-11-11';

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
  const login = () => raw('POST', '/auth/login', {
    body: { phone: acc.phone, password: PASS },
  });
  let r = await login();
  if (r.status === 200 && r.data?.token) return r.data;
  r = await raw('POST', '/auth/register', {
    body: { phone: acc.phone, password: PASS, role: acc.role, name: acc.name },
  });
  if (r.status === 200 && r.data?.token) return r.data;
  assert(r.code === 'phone_taken' || r.status === 409,
    `注册失败：HTTP ${r.status} ${r.code ?? ''} ${r.json?.error?.message ?? ''}`);
  const again = await login();
  assert(again.data?.token, '手机号已占用但登录拿不到票');
  return again.data;
}

async function main() {
  console.log('═══════════════════════════════════════════════════════════════');
  console.log('  英语单词打卡 · 端到端冒烟（真 HTTP + 真数据库）');
  console.log('═══════════════════════════════════════════════════════════════\n');
  console.log(`  服务：${BASE}`);
  console.log(`  库  ：${dbConfig.host}:${dbConfig.port}/${dbConfig.database}\n`);

  const pool = new pg.Pool({ ...dbConfig, max: 2 });
  const parent = await ensureAccount(ACC.parent);
  const student = await ensureAccount(ACC.student);
  const loner = await ensureAccount(ACC.loner);
  const ids = [parent.user.id, student.user.id, loner.user.id];

  try {
    // ── 准备：结伴 + 两本词表（一本孩子的，一本路人的）──
    await pool.query(
      `insert into relationship (id, student_id, parent_id, sender_id, status)
       values ($1, $2, $3, $3, 'active')
       on conflict (student_id, parent_id) do update set status = 'active'`,
      ['probe_word_rel', student.user.id, parent.user.id],
    );
    for (const [bookId, owner] of [[BOOK_ID, student.user.id], [LONER_BOOK_ID, loner.user.id]]) {
      await pool.query(
        `insert into word_book (id, student_id, owner_user_id, title, source_media_id,
                                unit_count, word_count)
         values ($1, $2, $2, '冒烟词表', $3, 2, 4)
         on conflict (id) do update set title = excluded.title`,
        [bookId, owner, `media_${bookId}`],
      );
      const words = [
        ['Unit 1', 1, 'hello', '你好'],
        ['Unit 1', 1, 'name', '名字'],
        ['Unit 2', 2, 'book', '书'],
        ['Unit 2', 2, 'pen', '钢笔'],
      ];
      for (let i = 0; i < words.length; i += 1) {
        const [unit, order, word, meaning] = words[i];
        await pool.query(
          `insert into word_entry (id, book_id, student_id, unit, unit_order, word,
                                   meaning, primary_meaning, normalized_word, sort_no)
           values ($1, $2, $3, $4, $5, $6, $7, $7, $8, $9)
           on conflict (id) do nothing`,
          [`probe_word_${bookId}_${i}`, bookId, owner, unit, order, word,
           meaning, word.toLowerCase(), i + 1],
        );
      }
    }

    const q = (token, studentId) => `?studentId=${encodeURIComponent(studentId)}&${token}`;

    await check('books：没连 ima 也恒 2xx，且已导入的书照样列出', async () => {
      const out = await call('GET', `/data/word/books${q('', student.user.id)}`,
        { token: parent.token });
      assert(out.connected === false, `connected 应为 false，实际 ${out.connected}`);
      assert(out.imported.some((b) => b.id === BOOK_ID), '导入过的书没列出来');
      return `connected=false imported=${out.imported.length}`;
    });

    await check('scope GET：没配置过按「未配置」降级，不抛错', async () => {
      const out = await call('GET', `/data/word/scope${q('', student.user.id)}`,
        { token: student.token });
      assert(out.configured === false, `configured 应为 false，实际 ${out.configured}`);
      return `unitMode=${out.unitMode} dailyCount=${out.dailyCount}`;
    });

    await check('scope PUT：家长配一次，learned 不被偷偷换成 all', async () => {
      const out = await call('PUT', '/data/word/scope', {
        token: parent.token,
        body: {
          studentId: student.user.id,
          bookId: BOOK_ID,
          unitMode: 'learned',
          currentUnit: 'Unit 1',
          selectedUnits: [],
          dailyCount: 10,
        },
      });
      assert(out.configured === true, '写完之后 configured 应为 true');
      assert(out.unitMode === 'learned', `unitMode=${out.unitMode}`);
      assert.deepEqual(out.units, ['Unit 1', 'Unit 2'], `单元顺序=${JSON.stringify(out.units)}`);
      return `units=${out.units.join('/')} currentUnit=${out.currentUnit}`;
    });

    await check('scope PUT：学生不能改自己的范围（403）', async () => {
      const r = await raw('PUT', '/data/word/scope', {
        token: student.token,
        body: {
          studentId: student.user.id, bookId: BOOK_ID,
          unitMode: 'all', currentUnit: 'Unit 2', dailyCount: 15,
        },
      });
      assert(r.status === 403, `实际 HTTP ${r.status} ${r.code ?? ''}`);
      return `HTTP ${r.status} ${r.code}`;
    });

    await check('scope PUT：越界 bookId 响亮 403，不靠 RLS 静默变空', async () => {
      const r = await raw('PUT', '/data/word/scope', {
        token: parent.token,
        body: {
          studentId: student.user.id, bookId: LONER_BOOK_ID,
          unitMode: 'all', currentUnit: 'Unit 1', dailyCount: 10,
        },
      });
      assert(r.status === 403, `实际 HTTP ${r.status} ${r.code ?? ''}`);
      return `HTTP ${r.status} ${r.code}`;
    });

    await check('entries：下发该书词表，含首义与单元顺序', async () => {
      const out = await call('GET',
        `/data/word/entries?studentId=${encodeURIComponent(student.user.id)}&bookId=${BOOK_ID}`,
        { token: student.token });
      assert(out.entries.length === 4, `词条数=${out.entries.length}`);
      assert(out.entries.every((e) => e.primaryMeaning), '有词条缺 primaryMeaning');
      return `entries=${out.entries.length}`;
    });

    await check('daily POST：day::text 回的是当天，不被时区偏一天', async () => {
      const out = await call('POST', '/data/word/daily', {
        token: student.token,
        body: {
          studentId: student.user.id, day: DAY,
          total: 4, correct: 3, streak: 2,
          wrongWords: [{ word: 'pen', count: 1 }],
        },
      });
      assert(out.result.day === DAY, `day=${out.result.day}`);
      return `day=${out.result.day} correct=${out.result.correct}`;
    });

    await check('daily POST：同一天再传是幂等 upsert，不是新增一行', async () => {
      await call('POST', '/data/word/daily', {
        token: student.token,
        body: {
          studentId: student.user.id, day: DAY,
          total: 4, correct: 4, streak: 3, wrongWords: [],
        },
      });
      const r = await pool.query(
        'select day::text as day, correct, streak from word_daily_result where student_id = $1 and day = $2::date',
        [student.user.id, DAY],
      );
      assert(r.rowCount === 1, `行数=${r.rowCount}`);
      assert(r.rows[0].day === DAY, `day=${r.rows[0].day}`);
      assert(Number(r.rows[0].correct) === 4, '第二次的值没覆盖');
      return `rows=1 day=${r.rows[0].day} correct=4`;
    });

    await check('daily GET：家长看得到孩子的成绩摘要，日期不偏一天', async () => {
      const out = await call('GET',
        `/data/word/daily${q(`from=${DAY}&to=${DAY}`, student.user.id)}`,
        { token: parent.token });
      assert(out.results.length === 1, `条数=${out.results.length}`);
      assert(out.results[0].day === DAY, `day=${out.results[0].day}`);
      return `day=${out.results[0].day} ${out.results[0].correct}/${out.results[0].total}`;
    });

    await check('daily GET：无关账号看不到（403，不是空列表）', async () => {
      const r = await raw('GET', `/data/word/daily${q('', student.user.id)}`,
        { token: loner.token });
      assert(r.status === 403, `实际 HTTP ${r.status} ${r.code ?? ''}`);
      return `HTTP ${r.status} ${r.code}`;
    });
  } finally {
    // ── 清理：只删自己造的行，单事务 ──
    const c = await pool.connect();
    try {
      await c.query('begin');
      await c.query('delete from word_entry where book_id = any($1::text[])',
        [[BOOK_ID, LONER_BOOK_ID]]);
      await c.query('delete from word_scope where student_id = any($1::text[])', [ids]);
      await c.query('delete from word_daily_result where student_id = any($1::text[])', [ids]);
      await c.query('delete from word_book where id = any($1::text[])',
        [[BOOK_ID, LONER_BOOK_ID]]);
      await c.query('delete from relationship where parent_id = any($1::text[]) or student_id = any($1::text[])', [ids]);
      await c.query('delete from app_user_credential where user_id = any($1::text[])', [ids]);
      try { await c.query('delete from user_session where user_id = any($1::text[])', [ids]); }
      catch { /* 没这张表就跳过 */ }
      await c.query('delete from app_user where id = any($1::text[])', [ids]);
      await c.query('commit');
    } catch (e) {
      await c.query('rollback').catch(() => {});
      throw e;
    } finally {
      c.release();
    }
    const left = await pool.query(
      `select (select count(*) from app_user where phone = any($1::text[])) as users,
              (select count(*) from word_book where id = any($2::text[])) as books`,
      [Object.values(ACC).map((a) => a.phone), [BOOK_ID, LONER_BOOK_ID]],
    );
    console.log(`\n  清理：残留账号=${left.rows[0].users} 残留词表=${left.rows[0].books}`);
    await pool.end();
  }

  console.log('\n───────────────────────────────────────────────────────────────');
  if (failures.length === 0) {
    console.log(`  全部通过：${passed} 条判据`);
    console.log('───────────────────────────────────────────────────────────────\n');
    process.exit(0);
  }
  console.log(`  通过 ${passed} 条，失败 ${failures.length} 条：`);
  for (const f of failures) console.log(`    · ${f}`);
  console.log('───────────────────────────────────────────────────────────────\n');
  process.exit(1);
}

main().catch((e) => {
  console.error('探针异常：', e);
  process.exit(2);
});
