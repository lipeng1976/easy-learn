#!/usr/bin/env node
/**
 * 对账脚本的**服务端链路一侧**：起本机 PG → 跑迁移 → 清业务表 → 造身份 →
 * 读同一份 `scenario.json` → 打 HTTP 端点执行 → dump 成 JSON。
 *
 * ## 它和 Dart 侧执行器是什么关系
 *
 * 两侧读**同一个序列文件**，各自把自己那套调用映射上去。序列因此是唯一真相；
 * 若两侧各写一份序列，它们会漂，而漂了的对账脚本比没有更坏 —— 它会给出「一致」的假结论。
 *
 * ## 为什么走 `app()` 而不是起真 HTTP server
 *
 * `app({method, pathname, headers, body})` 走的是**完整的路由 + 鉴权 + 事务链路**
 * （也就是 `npm test` 用的那条），只是少了网络栈。真 HTTP 信封由 `npm run smoke:http`
 * 单独覆盖 —— 对账要验的是「落库结果」，不是信封。
 *
 * ## 与 Dart 侧的起点对齐
 *
 * 两侧都**先清空业务表再执行**。因为种子不同源（本地走 `seedIfEmpty()`，
 * 这里直接写 SQL），「比对种子」既无意义也不可能通过。对账的对象是
 * 「同一串操作产生的行」。
 *
 * 跑法：`npm run reconcile:server`（或直接 node 本文件）
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { LOCAL_PG, withMigratedDatabase } from '../../src/pg-local.js';
import { createPool } from '../../src/db.js';
import { createApp } from '../../src/app.js';
import { issueSessionToken } from '../../../shared/token.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const serviceRoot = path.resolve(here, '..', '..');

const SCENARIO = path.join(here, 'scenario.json');
const OUT = process.env.RECONCILE_SERVER_OUT
  ?? path.join(serviceRoot, 'out', 'server-dump.json');

const SECRET = 'reconcile-secret-not-for-production';

/**
 * 进度日志：**同步追加到文件**，而不是只写 stderr。
 *
 * 这是被一次实测逼出来的：那次运行在收尾阶段挂住（起 PG 的命令被重定向到文件，
 * 于是 postgres 也继承了那个句柄），事后看到的状态是「进程还在、输出 0 字节」——
 * 完全看不出它跑到哪一步。同步追加不受重定向与缓冲影响。
 */
const PROGRESS = process.env.RECONCILE_PROGRESS
  ?? path.join(serviceRoot, 'out', 'server-run.progress.log');

const log = (...p) => process.stderr.write(`[reconcile/server] ${p.join(' ')}\n`);

function progress(msg) {
  const line = `${new Date().toISOString()}  ${msg}\n`;
  try {
    fs.appendFileSync(PROGRESS, line);
  } catch {
    // 进度日志写不进去不该让对账失败
  }
  process.stderr.write(line);
}

/**
 * 账号。只有这些是「起点」，业务表由 dump 列表负责清空。
 *
 * ⚠️ **手机号必须给**：结伴邀请走的是「按手机号找人」（`ctx.lookupUserByPhone`），
 * 没手机号的账号邀请不出来。而邀请是 `relationship` 那一行**唯一**的产生方式 ——
 * 它 2026-09-21 从「种子起点」改成了序列里的第 1~2 步（见 `scenario.json` 的 note）：
 * 摆在起点上时它只被**间接**验证，状态词写错的表现是后面某一步 403，
 * 而不是对账里一条看得懂的差异。
 *
 * 相应地这里**不再插关系行**了：`relationship` 已经在 dump 列表里，
 * `truncate` 会把它连同这个种子一起清掉 —— 留着的唯一效果是让人以为它还有用。
 */
const SEED = `
  insert into app_user (id, name, role, avatar, phone) values
    ('stu_001', '林小宇', 'student', 'fox', '13800000001'),
    ('par_001', '王老师', 'parent', 'teacher', '13800000002')
  on conflict (id) do nothing;
`;

const IDENT = /^[A-Za-z_][A-Za-z0-9_]*$/;

/** `$alias` 的形态。整串引用与内嵌引用都用它认。 */
const ALIAS_REF = /\$[A-Za-z_][A-Za-z0-9_]*/g;

function lookup(ref, aliases) {
  const key = ref.slice(1);
  if (!(key in aliases)) {
    throw new Error(
      `序列引用了不存在的别名 \`${ref}\` —— `
      + '要么它出现在被引用步骤之后，要么那一步的执行器没有登记别名。',
    );
  }
  return aliases[key];
}

/**
 * `$alias` → 真实 id。递归处理 map / list，与 Dart 侧 `_resolve` 同语义。
 *
 * ## 为什么是「字符串内替换」而不是「整串相等才算引用」
 *
 * 因为幂等键**一定含真实 id**，而且是嵌在中间的形态
 * （`PointController.planKey` = `plan:$planId:$dateKey`）。若只认整串，
 * 场景就只能把键写成常量，于是「键里带的是哪张计划」这件事对不上 ——
 * 而键错了的后果是静默的：第二天的分会被前一天的键吞掉，不报错。
 *
 * ⚠️ 代价：**字符串里出现的 `$xxx` 一律按引用解析，解析不到就抛**。
 * 这是刻意的 fail-fast —— 场景里没有「文案里恰好有个 $」这种需求，
 * 真出现了就写成 `\$` 之外的形式，别让一个引用悄悄变成字面量。
 */
function resolve(node, aliases) {
  if (typeof node === 'string') {
    if (!node.includes('$')) return node;
    return node.replace(ALIAS_REF, (m) => lookup(m, aliases));
  }
  if (Array.isArray(node)) return node.map((x) => resolve(x, aliases));
  if (node && typeof node === 'object') {
    return Object.fromEntries(
      Object.entries(node).map(([k, v]) => [k, resolve(v, aliases)]),
    );
  }
  return node;
}

/**
 * DATE 列 → `YYYY-MM-DD`，按**本地时区**取年月日。
 *
 * 2026-09-19 实测：PG 的 `date` 经 node-pg 出来是「**本地时区**午夜的 `Date`」，
 * 于是 `2026-09-18` 变成了 `2026-09-17T16:00:00.000Z`（Asia/Shanghai）。
 * 直接 `toISOString()` 会把这个日子说成前一天 —— 而这一列的全部意义就是
 * 「打卡记到了哪一天」，把它挪走一天正好是这条数据最要紧的那个错。
 *
 * 本地 SQLite 存的就是 `YYYY-MM-DD` 字符串（`StudyPlanCheckin.toMap`），
 * 所以服务端也按这个形状 dump —— 两侧才是同一个东西，而不是两种表达。
 */
function localDateString(v) {
  if (v === null || v === undefined) return null;
  if (!(v instanceof Date)) return String(v);
  const two = (n) => String(n).padStart(2, '0');
  return `${v.getFullYear()}-${two(v.getMonth() + 1)}-${two(v.getDate())}`;
}

function norm(v) {
  if (v === null) return null;
  const t = typeof v;
  if (t === 'number' || t === 'string' || t === 'boolean') return v;
  // PG 的 timestamptz 会以 Date 出来、int8 以 string 出来（node-pg 的取舍）。
  // 不归一化的话两侧的 JSON 会在这两处呈现出「格式差异」而不是「行为差异」。
  if (v instanceof Date) return v.toISOString();
  return String(v);
}

/**
 * 断言服务端**原样存下了客户端带的 id**。
 *
 * ## 为什么这条只能硬断言，对账本身看不见
 *
 * `workout_plan` / `workout_record` 是 R2（「id 由服务端生成」）**唯一一处刻意的例外**
 * ——理由是 id 同时是幂等键：换掉它，「重试」就从「还是那一行」变成「每试一次多一条」，
 * 而重试在移动网络下是常态。
 *
 * 但对账**测不出这件事**：别名是从**响应**登记的，响应里给什么、dump 里就是什么。
 * 把 id 换成服务端生成的，两侧的 dump 依旧逐行一致。所以这里必须直白地比一次。
 */
function assertClientIdKept(item, sentId, label) {
  if (item?.id !== sentId) {
    throw new Error(
      `${label}的 id 被服务端改写了：客户端带的是 ${sentId}，回显的是 ${item?.id}。`
      + '它是幂等键（R2 例外），被改写等于「重试插出第二条」——见 src/routes/workout.js 的文件头。',
    );
  }
}

async function main() {
  const scenario = JSON.parse(fs.readFileSync(SCENARIO, 'utf8'));
  const tables = scenario.dump;
  // 只有服务端有的表（本地 schema 里没有这张表，所以本地执行器不会 dump 它）。
  // 目前只有 `app_notification_read` —— 见 scenario 的 behaviorDiff。
  const serverOnlyTables = scenario.dumpServerOnly ?? [];
  const allTables = [...tables, ...serverOnlyTables];
  for (const t of allTables) {
    if (!IDENT.test(t)) throw new Error(`dump 列表里有不合法的表名：${t}`);
  }

  // 先删掉自己上一轮的产物。
  //
  // 理由不是「省空间」，是**防止旧 dump 冒充新结论**：执行器在写文件之前就
  // 失败（起库失败、某一步报错）时，上一轮那份 dump 会留在原地，而比对器
  // 只认路径不认时间 —— 于是它会对着一份从未发生过的运行宣布「一致」。
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.rmSync(OUT, { force: true });
  fs.writeFileSync(PROGRESS, '');
  progress(`场景 ${scenario.scenario}：${scenario.steps.length} 步 / ${allTables.length} 张表待 dump`);

  let payload;

  await withMigratedDatabase(
    async (_client, { port, database }) => {
      progress(`PG 就绪（port=${port} db=${database}）`);
      const mk = (user, password, max) => createPool({
        host: '127.0.0.1', port, database, user, password, max,
      });

      const admin = mk(LOCAL_PG.admin.user, LOCAL_PG.admin.password, 2);
      const appPool = mk(LOCAL_PG.app.user, LOCAL_PG.app.password, 4);
      const authPool = mk(LOCAL_PG.auth.user, LOCAL_PG.auth.password, 4);

      try {
        await admin.query(SEED);
        progress('账号与关系就绪');

        // 起点：业务表清空。用 truncate + cascade 而不是逐张 delete ——
        // 表之间有外键（`homework_image` → `homework`），delete 的顺序会变成
        // 一个必须维护的隐性约定，而 cascade 让它消失。
        await admin.query(`truncate ${allTables.join(', ')} cascade`);
        progress(`业务表已清空：${allTables.join(', ')}`);

        const app = createApp({ pool: appPool, authPool, sessionSecret: SECRET });

        const call = async (method, pathname, { token, body } = {}) => {
          const res = await app({
            method,
            pathname,
            query: {},
            headers: token === undefined ? {} : { authorization: `Bearer ${token}` },
            body: body ?? {},
          });
          const json = JSON.parse(res.body);
          if (res.status < 200 || res.status >= 300) {
            throw new Error(
              `${method} ${pathname} → ${res.status}：${JSON.stringify(json)}`
              + '（对账执行器不允许静默跳过失败步骤 —— 跳过会让「差异为 0」变成假结论）',
            );
          }
          return json.data;
        };

        const sessionFor = async (userId, role) => {
          const sid = `sess_rec_${userId}`;
          await admin.query(
            `insert into user_session (id, user_id, issued_at, expires_at)
             values ($1, $2, now(), now() + interval '1 hour')
             on conflict (id) do nothing`,
            [sid, userId],
          );
          return issueSessionToken({ secret: SECRET, subject: userId, role, sessionId: sid });
        };

        const studentToken = await sessionFor(
          scenario.actor.student, 'student',
        );
        // 家长 token 同样是**真会话**（`user_session` 里有一行），不是伪造的
        // 声明。序列里带 `identity: "parent"` 的步骤走它 —— 心愿的定价与兑现
        // 本来就是家长的动作，用学生的身份去跑会掩盖「谁有权限改这一列」。
        const parentToken = await sessionFor(
          scenario.actor.parent, 'parent',
        );
        const tokenFor = (identity) =>
          (identity === 'parent' ? parentToken : studentToken);

        const aliases = {
          student: scenario.actor.student,
          parent: scenario.actor.parent,
        };
        const executed = [];

        for (const step of scenario.steps) {
          // `sides` 缺省 = 两侧都跑。这一步写在序列里而不是散在执行器里 ——
          // 「只有一侧能跑」必须是一次**声明**（并且进 executed 日志），
          // 否则它就退化成一次静默跳过，而静默跳过正是对账最坏的失败方式。
          if (step.sides && !step.sides.includes('server')) {
            executed.push({ step: step.step, ok: false, skipped: 'sides 声明了这一步只在本地侧执行' });
            progress(`· 跳过（序列声明只在一侧执行）：${step.step}`);
            continue;
          }

          const key = `${step.repo}.${step.method}`;
          const args = resolve(step.args, aliases);
          const alias = step.as;
          const token = tokenFor(step.identity);

          let data;
          switch (key) {
            case 'homework.insertHomework':
              // 不带 id：R2 说 ID 由服务端生成。status 也不带 —— 服务端一律从
              // pending 开始（`createHomework` 显式忽略它），带上去只会让
              // 「两侧起点不同」这件事看起来像是序列的责任。
              data = await call('POST', '/data/homework', {
                token,
                body: {
                  studentId: args.studentId,
                  title: args.title,
                  subject: args.subject,
                  imageUrl: args.imageUrl,
                  dueAt: args.dueAt,
                  estimatedMinutes: args.estimatedMinutes,
                  aiEnabled: args.aiEnabled,
                  needsGrading: args.needsGrading,
                },
              });
              aliases[alias] = data.item.id;
              break;

            case 'homework.updateHomework':
              data = await call('POST', '/data/homework/update', {
                token,
                body: { id: args.id, ...args.mask },
              });
              break;

            case 'homework.saveHomeworkImages':
              data = await call('POST', '/data/homework/images', {
                token,
                body: { studentId: args.studentId, images: args.images },
              });
              (data.items ?? []).forEach((x, i) => { aliases[`${alias}_${i}`] = x.id; });
              break;

            case 'review.insertReviewMistakes':
              data = await call('POST', '/data/review/mistakes/insert', {
                token,
                body: { studentId: args.studentId, items: args.items },
              });
              (data.items ?? []).forEach((x, i) => { aliases[`${alias}_${i}`] = x.id; });
              break;

            case 'review.insertReviewPaperWithItems':
              // 卷 id 由服务端生成（R2），题目 id 也是 —— 一次性原子写入。
              // 序列里**不出现 paperId**：它在一侧是 uuid、另一侧是执行器自己拼的
              // 本地 id，两边都只能靠这一个响应把别名接上。
              data = await call('POST', '/data/review/papers/create', {
                token,
                body: {
                  studentId: args.studentId,
                  paper: args.paper,
                  items: args.items,
                },
              });
              aliases[alias] = data.paper.id;
              (data.items ?? []).forEach((x, i) => { aliases[`${alias}_${i}`] = x.id; });
              break;

            case 'review.updateReviewPaper':
              data = await call('POST', '/data/review/papers/update', {
                token,
                body: { id: args.id, ...args.mask },
              });
              break;

            case 'review.insertReviewAttempts':
              data = await call('POST', '/data/review/attempts/insert', {
                token,
                body: { studentId: args.studentId, items: args.items },
              });
              (data.items ?? []).forEach((x, i) => { aliases[`${alias}_${i}`] = x.id; });
              break;

            case 'review.updateReviewMistakeState':
              // 服务端的 `updateMistakeState` 读的就是 body 顶层的字段
              // （`buildUpdate` 按 spec 取键），所以展开即可。
              data = await call('POST', '/data/review/mistakes/state', {
                token,
                body: { ...args },
              });
              break;

            case 'review.insertReviewSummary':
              // id 由服务端**确定性地**拼（`sum_{studentId}_{scope}_{scopeKey}`），
              // 与本地那个 `sum_{studentId}_{scopeKey}` 拼法不同 —— 别名把它们接上。
              data = await call('POST', '/data/review/summaries/upsert', {
                token,
                body: { ...args },
              });
              aliases[alias] = data.item.id;
              break;

            // ===== 打卡 / 积分 / 心愿（第三段）=====

            case 'studyPlan.insertStudyPlan':
              data = await call('POST', '/data/study-plans', {
                token,
                body: { ...args },
              });
              aliases[alias] = data.item.id;
              break;

            case 'studyPlan.insertStudyPlanCheckin':
              // 重复打卡时服务端回的是**已有那一行**（`created: false`），id 不变 ——
              // 与本地 `ConflictAlgorithm.replace` 的取舍一致（原地替换）。
              // 两侧若一个换 id、一个不换，症状是「打卡数翻倍」这类安静的数据错。
              data = await call('POST', '/data/study-plans/checkin', {
                token,
                body: {
                  studentId: args.studentId,
                  planId: args.planId,
                  date: args.date,
                },
              });
              aliases[alias] = data.item.id;
              break;

            case 'points.earnPoints':
              data = await call('POST', '/data/points/earn', {
                token,
                body: { ...args },
              });
              aliases[alias] = data.entry.id;
              break;

            case 'points.revokePoints':
              data = await call('POST', '/data/points/reverse', {
                token,
                body: { ...args },
              });
              // 冲正笔也是一行，而且它的 id 两侧都是新生成的 —— 不登记别名的话
              // 比对器只能说「两侧各多一行」，说不清那是不是同一笔。
              if (data.reversal) aliases[`${alias}_reversal`] = data.reversal.id;
              break;

            case 'wish.insertWish':
              data = await call('POST', '/data/wishes', {
                token,
                body: { ...args },
              });
              aliases[alias] = data.item.id;
              break;

            case 'wish.updateWishRedeemState':
              // 三步都用这一个端点（定价 / 申请 / 兑现），差别只在传了哪个键 ——
              // 这正是「传什么改什么」的掩码语义，与本地 `updateWishRedeemState` 同形。
              data = await call('POST', '/data/wishes/redeem', {
                token,
                body: { ...args },
              });
              break;

            // ===== 运动 / 点评 / 结伴（第四段）=====

            case 'workout.insertPlan': {
              data = await call('POST', '/data/workouts/plans', {
                token,
                // `args` 里就带着 `id`，原样转发 —— 服务端接受客户端自带的 id
                // （R2 的唯一例外，见 `routes/workout.js` 的文件头）。
                body: { ...args },
              });
              assertClientIdKept(data.item, args.id, '运动计划');
              aliases[alias] = data.item.id;
              break;
            }

            case 'workout.setPlanActive':
              data = await call('POST', '/data/workouts/plans/active', {
                token,
                body: { ...args },
              });
              break;

            case 'workout.insertRecord': {
              data = await call('POST', '/data/workouts/records', {
                token,
                body: { ...args },
              });
              assertClientIdKept(data.item, args.id, '运动记录');
              aliases[alias] = data.item.id;
              break;
            }

            case 'relationship.invite':
              // 只上行 `targetPhone`：发起方是 token 里的那个人，客户端传什么
              // `senderId` 都不算数。序列里那个 `senderId` 是给**本地执行器**用的
              // —— 本地那侧身份是参数、不是 token，这正是两侧的差别本身。
              data = await call('POST', '/data/relationship/invite', {
                token,
                body: { targetPhone: args.targetPhone },
              });
              aliases[alias] = data.relationship.id;
              break;

            case 'relationship.updateStatus':
              data = await call('POST', '/data/relationship/status', {
                token,
                body: { id: args.id, status: args.status },
              });
              break;

            case 'comment.insertDailyComment':
              // 只上行 `rating` / `content` / `studentId`：`id` 由服务端生成、
              // `createdAt` 是记录时间（R3，服务端 `now()` 说了算）——
              // 代传这两个会得到一次 400。与 `HttpNotificationRepository` 同形。
              data = await call('POST', '/data/daily-comments', {
                token,
                body: {
                  rating: args.rating,
                  content: args.content,
                  studentId: args.studentId,
                },
              });
              aliases[alias] = data.item.id;
              break;

            case 'notification.markFirstRead': {
              // 序列里唯一只在一侧执行的步骤（`sides: ["server"]`）。
              // 取自己可见的第一条通知标记已读 —— 客户端真实路径就是「列表里点一个」。
              const list = await call('GET', '/data/notifications', { token });
              const first = (list.items ?? [])[0];
              if (!first) throw new Error('通知列表是空的，没有可标记的对象');
              data = await call('POST', '/data/notifications/read', {
                token,
                body: { id: first.id },
              });
              break;
            }

            default:
              throw new Error(
                `执行器不认识这一步：${key} —— 序列里加了新动作时，两侧执行器都要补，`
                + '**不能只补一边**（只补一边的后果是那一步在另一侧静默不执行，对账却仍然「通过」）。',
              );
          }

          executed.push({ step: step.step, ok: true });
          progress(`✔ ${step.step}`);
        }

        // ===== dump =====
        //
        // 列名走 information_schema 而不是「从结果行里推」—— 空表的 `select *`
        // 给不出列名，而「某张表一行都没有」恰恰是最需要被看见的状态。
        const dump = {};
        for (const t of allTables) {
          // 顺带取 `data_type`：DATE 列不能用「转成 ISO 时刻」表达
          // （理由见 localDateString）。这是唯一一处需要列类型信息的地方。
          const cols = await admin.query(
            `select column_name, data_type from information_schema.columns
              where table_schema = 'public' and table_name = $1
              order by ordinal_position`,
            [t],
          );
          const dateCols = new Set(
            cols.rows.filter((c) => c.data_type === 'date').map((c) => c.column_name),
          );
          const rows = await admin.query(`select * from ${t}`);
          dump[t] = {
            columns: cols.rows.map((r) => r.column_name),
            rows: rows.rows.map(
              (row) => Object.fromEntries(
                Object.entries(row).map(([k, v]) => [
                  k,
                  dateCols.has(k) ? localDateString(v) : norm(v),
                ]),
              ),
            ),
          };
        }

        payload = {
          side: 'server',
          scenario: scenario.scenario,
          aliases,
          executed,
          tables: dump,
        };
        progress('dump 完成');

        // ⚠️ **在回调里就落盘**，不要等 `withMigratedDatabase` 返回。
        //
        // 收尾（强杀 postgres + 删数据目录）是这台机器上最容易挂住的一段 ——
        // 实测出现过「所有步骤都跑完、收尾挂住、输出 0 字节」：因为写文件
        // 曾被放在收尾之后，于是挂住把一次**成功**的运行变成了什么都没有。
        writeDump(payload);
        progress(`已写出 ${OUT}`);
      } finally {
        await appPool.end().catch(() => {});
        await authPool.end().catch(() => {});
        await admin.end().catch(() => {});
      }
    },
    // 端口交给 wrapper 选（与 `run-tests.mjs` 一致）：写死会让对账与测试
    // 在同时运行时抢同一个端口，症状是「起库失败」这种看不出原因的错误。
    //
    // 数据目录名与测试（`.pgdata-test`）**刻意分开**：两者若共用，一次被中断
    // 的对账会留下「initdb 做了一半」的目录，下一次起库时 `removeDirWithRetry`
    // 有 4 秒预算、删不掉就放弃，随后 initdb 面对一个非空目录直接拒绝 ——
    // 现象是**无任何输出地卡住**（本机实测过一次）。
    // 端口与数据目录都必须**与演示栈、测试三方错开**。
    //
    // ⚠️ 原先这里只给了 `databaseDir`、没给端口 —— 于是落回 `LOCAL_PG.port`
    // （55433），也就是**演示栈的端口**。演示栈开着时（本机实测就是如此），
    // 症状是「对账跑到一半、退出码 1、什么原因都没说」：postgres 日志里那句
    // `could not bind ... address already in use` 被默认的空 `onLog` 吃掉了。
    // 下面那句注释当时写的是「端口交给 wrapper 选」—— **意图是对的，代码没有**。
    { databaseDir: path.join(serviceRoot, '.pgdata-rec'), port: LOCAL_PG.reconcilePort },
    {
      // ⚠️ 这两个回调**不能留空**。`withLocalPostgres` 的默认值是 `() => {}`，
      // 而 PG 自己的崩溃**不抛异常** —— 它只体现在 PG 的日志里。
      //
      // 这台机器上实测过：`could not open file "global/pg_control": Permission denied`
      // → 进程被 `0xC0000409` 结束 → 「the database system is in recovery mode」。
      // 默认的空回调把这些线索一条不剩地吃掉，现象就是
      // 「对账跑到一半、退出码 1、什么原因都没说」（2026-09-21 第一次跑就是这样）。
      // 只放行 FATAL/PANIC/ERROR，正常启动的几百行日志照旧不看。
      onLog: (m) => {
        const line = String(m).trim();
        if (/FATAL|PANIC|ERROR/.test(line)) progress(`pg: ${line}`);
      },
      onError: (e) => progress(`pg(onError): ${e?.message ?? String(e)}`),
    },
  );
  progress('收尾完成');

  const counts = allTables
    .map((t) => `${t}=${payload.tables[t].rows.length}`)
    .join(' / ');
  log(`${counts} → ${OUT}`);
}

/** 把 dump 写到 OUT。**只在这里**，且允许被调用两次（幂等）。 */
function writeDump(payload) {
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, `${JSON.stringify(payload, null, 2)}\n`);
}

main().then(
  () => process.exit(0),
  (e) => {
    // 失败也要进进度日志：那条日志是唯一能在「进程被外部杀掉、stderr 没落盘」
    // 时还看得出发生过什么的东西。
    //
    // ⚠️ 这里**不能**直接写 `e.message`。2026-09-21 实测遇到过一次
    // 「拒绝原因是 `undefined`」（起库阶段子进程相关的失败），`e.message`
    // 把错误处理自己炸成了 TypeError —— 日志里只剩下那句 TypeError，
    // **真正的失败原因一个字都没留下**，只能重跑一遍才看得到。
    // 错误处理的失败形态比错误本身更难查，所以它对 `e` 必须完全免疫。
    const detail = e instanceof Error
      ? (e.stack ?? e.message)
      : `（拒绝原因不是 Error，而是 ${String(e)}）`;
    progress(`失败：${detail}`);
    log('失败：', detail);
    process.exit(1);
  },
);
