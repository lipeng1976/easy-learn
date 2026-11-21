#!/usr/bin/env node
/**
 * **英文阅读的端到端冒烟** —— 真 HTTP + 真数据库 + 真 ima 下载。
 *
 * 单测（`reading-import` / `reading-progress`）证明的是「规则算对了」；
 * 它证明不了这条链路拼起来能跑：登录拿票 → 找 ima 目录 → 下载 3.4MB md →
 * 切 96 课 → 96 行入库 → 布置任务 → 打卡 → 读完自动收尾 → 家长看到。
 * 中间任何一环字段名对不上，单测全都照样绿。
 *
 * ## 怎么用真 ima 而不污染真实数据
 *
 * 探针账号是全新的（`199000000xx`），本身没连 ima。这里**把库里现成那条
 * 已激活凭证的密文复制**给探针家长，再把探针学生映射到同一个知识库 ——
 * 于是它能真的下载真书，而写操作（导入的书、任务、打卡）全落在自己的
 * student_id 名下，跑完按 id 删干净。**对真实家庭是只读的**。
 *
 * 没有可用凭证时这一组判据会「跳过」而不是失败 —— 那说明的是这台部署
 * 没连 ima，不是代码坏了。跳过**不计入通过**（见 `skip`）。
 *
 * ## 判据
 *
 *   1. 家长能看到 `教学资料/English` 下的 md 书
 *   2. 导入成功，切出 96 课、0 课被跳过
 *   3. 课目录 96 条，第 2 课标题/正文/译文都对
 *   4. 布置任务 → 0/96，下一篇 = 1
 *   5. 学生读到这份任务（跨账号可见）
 *   6. 读第 1 篇 → 1/96
 *   7. 重复读第 1 篇 → 不报错、进度不变（幂等）
 *   8. 跳读第 5 篇 → 400，且**进度不变**
 *   9. 读到第 96 篇 → 任务自动 `done`（不用等下一次查询）
 *  10. 路人学生看不到这份任务（RLS）
 *  11. 同一本书重复导入 → 幂等返回同一本，不新建
 *  12. 跑完数据库 0 残留
 *
 * ## 用法
 *
 *   node scripts/probe-reading-e2e.mjs --env-file "D:/easy_learn_home/config/local.env"
 *
 * 需要一个**已启动的数据服务**（默认 `http://127.0.0.1:8788`，可用 `PROBE_BASE` 改）。
 */
import pg from 'pg';

import { cloudHost, loadEnv, valueOf } from './lib/env-file.mjs';

const BASE = (process.env.PROBE_BASE ?? 'http://127.0.0.1:8788').replace(/\/+$/, '');
const PASS = 'smoke123456';

const ACC = {
  parent: { phone: '19900000001', role: 'parent', name: '冒烟家长' },
  student: { phone: '19900000002', role: 'student', name: '冒烟学生' },
  loner: { phone: '19900000003', role: 'student', name: '冒烟路人' },
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
let skipped = 0;
const failures = [];

function ok(label, extra = '') {
  passed += 1;
  console.log(`  ✓ ${label}${extra ? `  ${extra}` : ''}`);
}

function skip(label, reason) {
  skipped += 1;
  console.log(`  – ${label}  [跳过：${reason}]`);
}

function fail(label, detail) {
  failures.push(`${label} —— ${detail}`);
  console.log(`  ✗ ${label}`);
  console.log(`      ${detail}`);
}

async function check(label, fn) {
  try {
    const detail = await fn();
    ok(label, detail ?? '');
  } catch (e) {
    fail(label, e?.message ?? String(e));
  }
}

function assert(cond, message) {
  if (!cond) throw new Error(message);
}

function todayLocal() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

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
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    throw new Error(`${method} ${path} 返回的不是 JSON（HTTP ${res.status}）：${text.slice(0, 200)}`);
  }
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

async function ensureAccount(acc) {
  const login = async () =>
    call('POST', '/auth/login', { body: { phone: acc.phone, password: PASS } });
  try {
    return await login();
  } catch (e) {
    if (e.status !== 400 && e.status !== 401) throw e;
  }
  try {
    return await call('POST', '/auth/register', {
      body: { phone: acc.phone, password: PASS, role: acc.role, name: acc.name },
    });
  } catch (e) {
    if (e.code === 'phone_taken' || e.status === 409) return login();
    throw e;
  }
}

async function main() {
  console.log('═══════════════════════════════════════════════════════════════');
  console.log('  英文阅读 · 端到端冒烟（真 HTTP + 真库 + 真 ima 下载）');
  console.log('═══════════════════════════════════════════════════════════════\n');
  console.log(`  服务：${BASE}`);
  console.log(`  库  ：${dbConfig.host}:${dbConfig.port}/${dbConfig.database}\n`);

  const pool = new pg.Pool({ ...dbConfig, max: 2 });

  const parent = await ensureAccount(ACC.parent);
  const student = await ensureAccount(ACC.student);
  const loner = await ensureAccount(ACC.loner);
  console.log(`  家长 ${parent.user.id}`);
  console.log(`  学生 ${student.user.id}`);
  console.log(`  路人 ${loner.user.id}\n`);

  /**
   * 清数据（**不删账号**）。
   *
   * 为什么分开：跑之前也要清一次残留（上次中途崩了会留下任务和书），
   * 而那时账号刚被 `ensureAccount` 建出来、token 正拿在手里 ——
   * 一起删掉的话，后面每个请求都会 401，报错看起来像「鉴权坏了」。
   */
  const cleanupData = async () => {
    await pool.query('delete from reading_log where student_id = $1', [student.user.id]);
    await pool.query('delete from reading_task where student_id = $1', [student.user.id]);
    await pool.query('delete from reading_lesson where student_id = $1', [student.user.id]);
    await pool.query('delete from reading_book where student_id = $1', [student.user.id]);
    await pool.query('delete from ima_student_kb where student_id = $1', [student.user.id]);
    await pool.query('delete from ima_credential where owner_user_id = $1', [parent.user.id]);
    await pool.query(
      'delete from relationship where student_id = any($1::text[]) or parent_id = $2',
      [[student.user.id, loner.user.id], parent.user.id],
    );
  };

  /** 清账号（跑完最后一步）。单独删，原因见 [cleanupData]。 */
  const cleanupAccounts = async () => {
    await pool.query('delete from app_user where id = any($1::text[])', [
      [parent.user.id, student.user.id, loner.user.id],
    ]);
  };

  try {
    // 先清上次残留（账号刚建好，不能连账号一起删）。
    await cleanupData();

    await pool.query(
      `insert into relationship (id, student_id, parent_id, sender_id, status)
       values ($1, $2, $3, $3, 'active')
       on conflict (student_id, parent_id) do update set status = 'active'`,
      [`probe_rel_reading_p_s`, student.user.id, parent.user.id],
    );
    await pool.query(
      `insert into relationship (id, student_id, parent_id, sender_id, status)
       values ($1, $2, $3, $3, 'removed')
       on conflict (student_id, parent_id) do update set status = 'removed'`,
      [`probe_rel_reading_p_l`, loner.user.id, parent.user.id],
    );

    // ── 准备：把现成的 ima 凭证复制给探针家长（只读共享知识库）──
    const source = await pool.query(
      `select c.owner_user_id, c.clientid_enc, c.apikey_enc, k.kb_id
         from ima_credential c
         join ima_student_kb k on k.owner_user_id = c.owner_user_id
        where c.status = 'active'
        order by c.updated_at desc nulls last
        limit 1`,
    );

    let hasIma = source.rowCount > 0;
    if (hasIma) {
      const row = source.rows[0];
      await pool.query(
        `insert into ima_credential (owner_user_id, clientid_enc, apikey_enc, status)
         values ($1, $2, $3, 'active')
         on conflict (owner_user_id) do update set
           clientid_enc = excluded.clientid_enc,
           apikey_enc = excluded.apikey_enc,
           status = 'active'`,
        [parent.user.id, row.clientid_enc, row.apikey_enc],
      );
      await pool.query(
        `insert into ima_student_kb (student_id, owner_user_id, kb_id, kb_name)
         values ($1, $2, $3, 'probe-kb')
         on conflict (student_id) do update set kb_id = excluded.kb_id`,
        [student.user.id, parent.user.id, row.kb_id],
      );
    }

    const day = todayLocal();
    let book = null;
    let task = null;

    // ── 1. 可导入的书 ──
    console.log('  ── 选书 ──');
    if (!hasIma) {
      skip('列出 ima 里可导入的书', '这台库没有已连接的 ima 凭证');
    } else {
      await check('家长能看到教学资料/English 下至少有 1 本 md', async () => {
        const data = await call('GET', `/data/reading/books/available?studentId=${student.user.id}`, {
          token: parent.token,
        });
        assert(data.folderPath === '教学资料/English', `目录路径是 ${data.folderPath}`);
        assert(Array.isArray(data.books) && data.books.length > 0, '一本书都没读到');
        return `${data.books.length} 本，首本《${data.books[0].title}》`;
      });
    }

    // ── 2. 导入 ──
    if (hasIma) {
      const available = await call(
        'GET',
        `/data/reading/books/available?studentId=${student.user.id}`,
        { token: parent.token },
      );
      const pick = available.books[0];

      await check('导入成功，切出 96 课、0 课被跳过', async () => {
        const t0 = Date.now();
        const res = await call('POST', '/data/reading/books/import', {
          token: parent.token,
          body: {
            studentId: student.user.id,
            mediaId: pick.mediaId,
            fileName: pick.fileName,
            title: pick.title,
          },
        });
        book = res.book;
        const ms = Date.now() - t0;
        assert(res.imported === true, '首次导入返回 imported=false');
        assert(res.book.lessonCount === 96, `切出 ${res.book.lessonCount} 课（应为 96）`);
        assert(res.skipped.length === 0, `有 ${res.skipped.length} 课没正文：${res.skipped.slice(0, 8)}`);
        return `《${res.book.title}》96 课，耗时 ${ms}ms`;
      });

      await check('同一本书再导一次 → 幂等，返回同一本、不新建', async () => {
        const res = await call('POST', '/data/reading/books/import', {
          token: parent.token,
          body: { studentId: student.user.id, mediaId: pick.mediaId, fileName: pick.fileName },
        });
        assert(res.imported === false, '第二次导入仍然报了 imported=true');
        assert(res.book.id === book.id, '返回的是另一本书（id 变了）');
        const n = await pool.query('select count(*)::int as n from reading_book where student_id = $1', [
          student.user.id,
        ]);
        assert(n.rows[0].n === 1, `库里现在有 ${n.rows[0].n} 本`);
        return `id=${res.book.id}`;
      });

      // ── 3. 课目录与单课 ──
      console.log('\n  ── 课文 ──');
      await check('课目录 96 条，课号 1..96 连续', async () => {
        const data = await call(
          'GET',
          `/data/reading/lessons?bookId=${book.id}&studentId=${student.user.id}`,
          { token: student.token },
        );
        assert(data.lessons.length === 96, `拿到 ${data.lessons.length} 条`);
        const nos = data.lessons.map((l) => l.lessonNo);
        for (let i = 1; i < nos.length; i += 1) {
          assert(nos[i] === nos[i - 1] + 1, `课号不连续：${nos[i - 1]} 之后是 ${nos[i]}`);
        }
        return '96 条';
      });

      await check('第 2 课：标题 / 正文 / 译文 / 生词都对', async () => {
        const data = await call(
          'GET',
          `/data/reading/lesson?bookId=${book.id}&lessonNo=2&studentId=${student.user.id}`,
          { token: student.token },
        );
        const l = data.lesson;
        assert(l.title === 'Three Fish Brothers in Shallow Water', `标题是「${l.title}」`);
        assert(l.body.startsWith('Three fish lived in the sea'), '正文开头不对');
        assert(l.translation.includes('浅水里的鱼兄弟') || l.translation.includes('有三条鱼'), '译文不对');
        assert(l.vocabulary.length === 4, `生词 ${l.vocabulary.length} 个（应为 4）`);
        assert(l.vocabulary[0].word === 'young', `第一个词是 ${l.vocabulary[0].word}`);
        return `${l.charCount} 字符 · 生词 ${l.vocabulary.length}`;
      });

      // ── 4. 布置任务 ──
      console.log('\n  ── 任务 ──');
      await check('家长布置任务 → 0/96，下一篇是第 1 课', async () => {
        const res = await call('POST', '/data/reading/tasks', {
          token: parent.token,
          body: { studentId: student.user.id, bookId: book.id },
        });
        task = res.task;
        assert(res.created === true, '首次布置返回 created=false');
        assert(task.doneLessons === 0 && task.totalLessons === 96, `进度 ${task.doneLessons}/${task.totalLessons}`);
        assert(task.nextLessonNo === 1, `下一篇是 ${task.nextLessonNo}`);
        assert(task.finished === false, '一上来就 finished');
        return `task=${task.id}`;
      });

      await check('学生读到自己这份任务（跨账号可见）', async () => {
        const data = await call('GET', '/data/reading/tasks', { token: student.token });
        const hit = data.tasks.find((t) => t.id === task.id);
        assert(hit, '学生的任务列表里没有它');
        assert(hit.isActive !== false && hit.nextLessonNo === 1, '进度不对');
        return `${data.tasks.length} 份`;
      });

      // ── 5. 打卡：正常 / 幂等 / 跳读 ──
      console.log('\n  ── 打卡 ──');
      await check('读第 1 篇 → 1/96，下一篇 2', async () => {
        const res = await call('POST', '/data/reading/tasks/read', {
          token: student.token,
          body: { taskId: task.id, lessonNo: 1, day, studentId: student.user.id },
        });
        assert(res.already === false, '第一次就报 already');
        assert(res.task.doneLessons === 1, `进度 ${res.task.doneLessons}`);
        assert(res.task.nextLessonNo === 2, `下一篇 ${res.task.nextLessonNo}`);
        return '1/96';
      });

      await check('重复读第 1 篇 → 不报错、进度不变（幂等）', async () => {
        const res = await call('POST', '/data/reading/tasks/read', {
          token: student.token,
          body: { taskId: task.id, lessonNo: 1, day, studentId: student.user.id },
        });
        assert(res.already === true, '没有报 already');
        assert(res.task.doneLessons === 1, `进度变成 ${res.task.doneLessons}`);
        return 'still 1/96';
      });

      await check('跳读第 5 篇 → 400，且进度不变', async () => {
        let code = null;
        try {
          await call('POST', '/data/reading/tasks/read', {
            token: student.token,
            body: { taskId: task.id, lessonNo: 5, day, studentId: student.user.id },
          });
        } catch (e) {
          code = e.code;
          assert(e.message.includes('下一篇是第 2 课'), `错误消息没说下一篇：${e.message}`);
        }
        assert(code === 'bad_request', `返回码是 ${code}`);
        const data = await call('GET', '/data/reading/tasks', { token: student.token });
        const hit = data.tasks.find((t) => t.id === task.id);
        assert(hit.doneLessons === 1, `进度被跳读改成了 ${hit.doneLessons}`);
        return 'bad_request · 仍 1/96';
      });

      await check('路人学生看不到这份任务（越权 403）', async () => {
        let status = null;
        try {
          await call('GET', `/data/reading/tasks?studentId=${student.user.id}`, {
            token: loner.token,
          });
        } catch (e) {
          status = e.status;
        }
        assert(status === 403, `返回 HTTP ${status}`);
        return '403';
      });

      // ── 6. 读完最后一篇 ──
      await check('读到第 96 篇 → 任务自动 done（同一次请求里收尾）', async () => {
        const t0 = Date.now();
        let last = null;
        for (let no = 2; no <= 96; no += 1) {
          last = await call('POST', '/data/reading/tasks/read', {
            token: student.token,
            body: { taskId: task.id, lessonNo: no, day, studentId: student.user.id },
          });
        }
        assert(last.task.doneLessons === 96, `最后是 ${last.task.doneLessons}/96`);
        assert(last.taskDone === true, 'taskDone 不是 true');
        assert(last.task.status === 'done', `status 还是 ${last.task.status}`);
        assert(last.task.nextLessonNo === null, `读完了还有下一篇 ${last.task.nextLessonNo}`);
        assert(last.task.finished === true, 'finished 不是 true');
        return `95 次打卡 ${Date.now() - t0}ms`;
      });

      await check('家长看到「已读完」，而不是还挂着进度', async () => {
        const data = await call('GET', `/data/reading/tasks?studentId=${student.user.id}`, {
          token: parent.token,
        });
        const hit = data.tasks.find((t) => t.id === task.id);
        assert(hit.finished === true, 'finished 不是 true');
        assert(hit.doneLessons === 96, `进度 ${hit.doneLessons}`);
        return '96/96 done';
      });

      await check('读完后再布置同一本书 → 开一份**新**任务（进度从 0 开始）', async () => {
        const res = await call('POST', '/data/reading/tasks', {
          token: parent.token,
          body: { studentId: student.user.id, bookId: book.id },
        });
        assert(res.created === true, '没开新任务');
        assert(res.task.doneLessons === 0, `新任务进度 ${res.task.doneLessons}`);
        assert(res.task.id !== task.id, '返回的还是旧任务');
        return `重读任务 ${res.task.id}`;
      });
    } else {
      for (const label of [
        '导入一本书',
        '课目录 96 条',
        '第 2 课内容正确',
        '布置任务',
        '学生读到任务',
        '读一篇打卡',
        '重复打卡幂等',
        '跳读被拒',
        '路人越权 403',
        '读完自动收尾',
      ]) {
        skip(label, '无 ima 凭证（下载那一环跑不起来）');
      }
    }

    // ── 7. 权限：学生不能布置 ──
    console.log('\n  ── 权限 ──');
    await check('学生不能布置任务（403）', async () => {
      let status = null;
      try {
        await call('POST', '/data/reading/tasks', {
          token: student.token,
          body: { studentId: student.user.id, bookId: 'rb_whatever' },
        });
      } catch (e) {
        status = e.status;
      }
      assert(status === 403, `返回 HTTP ${status}`);
      return '403';
    });

    // ── 收尾 ──
    await cleanupData();
    const left = await pool.query(
      `select
         (select count(*) from reading_book where student_id = $1) as books,
         (select count(*) from reading_task where student_id = $1) as tasks,
         (select count(*) from reading_log where student_id = $1) as logs,
         (select count(*) from reading_lesson where student_id = $1) as lessons`,
      [student.user.id],
    );
    await check('跑完阅读数据 0 残留', async () => {
      const r = left.rows[0];
      assert(Number(r.books) === 0, `还剩 ${r.books} 本书`);
      assert(Number(r.tasks) === 0, `还剩 ${r.tasks} 份任务`);
      assert(Number(r.logs) === 0, `还剩 ${r.logs} 条打卡`);
      assert(Number(r.lessons) === 0, `还剩 ${r.lessons} 课`);
      return 'books=0 lessons=0 tasks=0 logs=0';
    });

    await cleanupAccounts();
    const usersLeft = await pool.query('select count(*)::int as n from app_user where phone = any($1::text[])', [
      [ACC.parent.phone, ACC.student.phone, ACC.loner.phone],
    ]);
    await check('跑完探针账号也清掉了', async () => {
      assert(usersLeft.rows[0].n === 0, `还剩 ${usersLeft.rows[0].n} 个账号`);
      return 'users=0';
    });
  } catch (e) {
    // 中途崩了也要清理，否则下次跑会撞上残留账号。
    try {
      await cleanupData();
      await cleanupAccounts();
    } catch (cleanupError) {
      console.error(`  清理失败：${cleanupError?.message ?? cleanupError}`);
    }
    throw e;
  } finally {
    await pool.end();
  }

  console.log('\n───────────────────────────────────────────────────────────────');
  if (failures.length === 0) {
    console.log(
      `  全部通过：${passed} 条判据${skipped > 0 ? `（另有 ${skipped} 条跳过，见上）` : ''}`,
    );
    console.log('───────────────────────────────────────────────────────────────\n');
    process.exit(0);
  }
  console.log(`  通过 ${passed} 条，失败 ${failures.length} 条${skipped > 0 ? `，跳过 ${skipped} 条` : ''}：`);
  for (const f of failures) console.log(`    · ${f}`);
  console.log('───────────────────────────────────────────────────────────────\n');
  process.exit(1);
}

main().catch((e) => {
  console.error(`\n探针异常中止：${e?.stack ?? e}\n`);
  process.exit(2);
});
