#!/usr/bin/env node
/**
 * 真库判据：`024_ima_coparent_read.sql` 的 RLS 到底放没放行「共管家长」。
 *
 * 单元测试里的假 client 证明不了 RLS —— 它是 SQL policy，只有真 PG 能回答。
 * 这个探针以非特权的 `app_rls` 身份在**一个事务内**临时插入一条 `relationship`
 * （孩子 S ↔ 另一位家长 B），用 `SET LOCAL` 设好身份，检查读写可见性，
 * 最后 **ROLLBACK**：真库一行数据都不会多。
 *
 * 检查四件事：
 *   ① 配置人 A 自己能读 S 的 KB 映射 + 自己的凭证状态（反面基线）；
 *   ② 共管家长 B 能读到**同一行**映射和 A 的凭证状态（024 的目的）；
 *   ③ 无关账号 C 一行都读不到（多家庭隔离没被放开）；
 *   ④ B 不能改 A 的凭证行（只放 SELECT，没放写）。
 *
 * 用法：
 *   node scripts/probe-ima-coparent.mjs --env-file D:/easy_learn_home/config/local.env
 *   npm run probe:ima-coparent -- --env-file <文件>
 *
 * 前置：`node scripts/migrate.mjs --env-file <文件> --yes`（把 024 应用上）。
 */
import assert from 'node:assert/strict';

import pg from 'pg';

import { sslOption } from '../src/db.js';
import { resolveMigrationTarget } from '../src/migrate.js';
import { cloudHost, loadEnv, valueOf } from './lib/env-file.mjs';

const args = process.argv.slice(2);
const { env } = loadEnv(valueOf(args, '--env-file'));
env.PGHOST = cloudHost(env);

// ⚠️ 必须走**应用连接**（PGUSER=app_rls）。运维账号是 BYPASSRLS，
// 用它查出来的「能读到」证明不了任何 policy；而 easylearn_admin 也不是
// 超级用户，没法在事务里 `SET LOCAL ROLE app_rls`（42501）。
// 用 app_rls 直接连，同一个事务里插临时关系 → 验 → 回滚，一行不落库。
const appConn = {
  host: env.PGHOST,
  port: Number(env.PGPORT ?? 5432),
  database: env.PGDATABASE,
  user: env.PGUSER,
  password: env.PGPASSWORD,
  ssl: sslOption(env.PGSSLMODE),
};
const pool = new pg.Pool({ ...appConn, max: 1 });

// 盘点阶段用运维连接（要跨用户看全表）；真正验 RLS 的那一段才用 app_rls。
// ⚠️ 别把两件事混在一根连接上：app_rls 没设身份时连自己的盘点都读不到，
// 症状是「真库明明有映射，探针却说没有」。
const { identity: _identity, ...opsConn } = resolveMigrationTarget(env);
const opsPool = new pg.Pool({ ...opsConn, ssl: sslOption(env.PGSSLMODE), max: 1 });
const ops = await opsPool.connect();
const client = await pool.connect();
try {
  const me = await client.query(
    'select current_user as name, r.rolbypassrls, r.rolsuper from pg_roles r where r.rolname = current_user',
  );
  assert.equal(me.rows[0]?.rolbypassrls, false, '应用连接不能带 BYPASSRLS，否则下面的可见性全绿是假的');
  assert.equal(me.rows[0]?.rolsuper, false, '超级用户会静默绕过 RLS');
  const applied = await ops.query(
    "select 1 from schema_migrations where name = '024_ima_coparent_read.sql'",
  );
  assert.equal(applied.rowCount, 1, '024 还没应用：先跑 migrate.mjs --yes');

  const policies = await ops.query(
    `select tablename, policyname from pg_policies
      where schemaname = 'public' and tablename in ('ima_credential','ima_student_kb')
        and policyname like '%coparent_read%' order by tablename`,
  );
  assert.equal(policies.rowCount, 2, '两条 coparent_read 策略必须都在');

  // 找一行真实的学生 KB 映射；没有的话这个探针无法验证（不造业务数据）。
  const kb = (await ops.query(
    'select student_id, owner_user_id, kb_id from ima_student_kb order by created_at limit 1',
  )).rows[0];
  assert.ok(kb, '真库还没有学生 KB 映射，先完成一次 ima 连接再跑');
  const studentId = kb.student_id;
  const ownerId = kb.owner_user_id;

  // 另一位 active 家长 B：不是配置人，且目前还不是这个孩子的家长。
  const parents = (await ops.query(
    "select distinct parent_id from relationship where status = 'active' and parent_id <> $1",
    [ownerId],
  )).rows.map((r) => r.parent_id);
  const bound = new Set((await ops.query(
    'select parent_id from relationship where student_id = $1',
    [studentId],
  )).rows.map((r) => r.parent_id));
  const coParentId = parents.find((id) => !bound.has(id));
  assert.ok(coParentId, '真库没有第二位可用于共管验证的家长');

  // 无关账号 C：另一个家庭的学生（必须与配置人 A 没有任何 active 关系）。
  // 不能随便挑一个学生：018 放行「配置人的 active 学生读家庭 KB」，
  // 若 C 恰好也是 A 的孩子，他本来就读得到，拿他当反面会误报。
  const outsider = (await ops.query(
    `select r.student_id from relationship r
      where r.status = 'active' and r.student_id <> $1
        and not exists (
          select 1 from relationship x
           where x.student_id = r.student_id and x.parent_id = $2 and x.status = 'active'
        ) limit 1`,
    [studentId, ownerId],
  )).rows[0]?.student_id ?? 'probe_no_such_user';

  async function visibility(userId, visibleStudent) {
    await client.query('select set_config($1, $2, true)', ['app.user_id', userId]);
    await client.query('select set_config($1, $2, true)', ['app.visible_students', visibleStudent]);
    const kbs = await client.query(
      'select student_id, kb_id, owner_user_id from ima_student_kb where student_id = $1',
      [studentId],
    );
    const creds = await client.query(
      'select owner_user_id, status from ima_credential where owner_user_id = $1',
      [ownerId],
    );
    return { kbs: kbs.rows, creds: creds.rows };
  }

  let result;
  await client.query('begin');
  try {
    // 插入临时共管关系：relationship 的 own_rows policy 允许
    // `parent_id = app.user_id` 的行，所以以 B 的身份插得进去。
    await client.query('select set_config($1, $2, true)', ['app.user_id', coParentId]);
    await client.query('select set_config($1, $2, true)', ['app.visible_students', studentId]);
    await client.query(
      `insert into relationship (id, student_id, parent_id, sender_id, status)
       values ($1, $2, $3, $3, 'active')`,
      [`probe_coparent_${Date.now()}`, studentId, coParentId],
    );

    const owner = await visibility(ownerId, studentId);
    assert.equal(owner.kbs.length, 1, '配置人自己应当读得到映射');
    assert.equal(owner.creds.length, 1, '配置人自己应当读得到凭证状态');

    const coParent = await visibility(coParentId, studentId);
    assert.equal(coParent.kbs.length, 1, '共管家长必须读到同一行映射（024 的目的）');
    assert.equal(coParent.kbs[0].kb_id, kb.kb_id, '两个人必须看到同一个 kb_id');
    assert.equal(coParent.creds.length, 1, '共管家长必须读到配置人的凭证状态');

    const unrelated = await visibility(outsider, outsider);
    assert.equal(unrelated.kbs.length, 0, '无关账号绝不能读到这个学生的 KB');
    assert.equal(unrelated.creds.length, 0, '无关账号绝不能读到别人家的凭证');

    // 只放行 SELECT：B 改 A 的凭证行应当影响 0 行，而不是「改成功了」。
    await client.query('select set_config($1, $2, true)', ['app.user_id', coParentId]);
    const write = await client.query(
      "update ima_credential set status = 'expired' where owner_user_id = $1",
      [ownerId],
    );
    assert.equal(write.rowCount, 0, '另一位家长不该能改配置人的凭证行');

    result = {
      studentId,
      ownerId,
      coParentId,
      kbId: kb.kb_id,
      sharedStatus: coParent.creds[0].status,
    };
  } finally {
    // 无论断言成不成立，测试数据一律不落库。
    await client.query('rollback');
  }

  console.log('✓ 024 共管家长 RLS 判据通过');
  console.log(`  学生=${result.studentId} 配置人=${result.ownerId} 共管家长=${result.coParentId}`);
  console.log(`  两边读到同一个 KB：${result.kbId}（状态 ${result.sharedStatus}）`);
  console.log('  反面：无关账号 0 行；共管家长写凭证 0 行；测试数据已回滚');
} finally {
  client.release();
  ops.release();
  await pool.end();
  await opsPool.end();
}
