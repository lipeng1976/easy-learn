import { badRequest, forbidden } from '../../../shared/errors.js';
import { requireVisibleStudent } from '../auth.js';
import { newId, rowToApi, rowsToApi } from '../mapper.js';
import { toBool, requireInt } from '../coerce.js';

/**
 * 积分账本：S1 的第三条契约路径 —— **重试幂等返回原结果**。
 *
 * ## 为什么这条最值得在骨架阶段就验
 *
 * 发分的防重靠的是数据库的部分唯一索引（不是 Dart 侧「先查再插」——
 * 查与插之间永远有缝）。SQLite 时代这就够了，因为进程和库在同一台设备上。
 *
 * 上云后多出一个 SQLite 时代**不存在**的问题：**网络超时后的重试**。
 *   客户端发了请求，服务端写成功了，响应在路上丢了 → 客户端重试。
 *   这时如果服务端回 409「重复」是**错的**：用户看到一个错误，
 *   却不知道到底成没成，而钱其实已经记上了。
 *
 * 正确做法：`ON CONFLICT DO NOTHING` + 回查，**把原结果返回给客户端**。
 * 重试于是变成幂等的，客户端不需要知道「第一次到底成没成」。
 *
 * ## 一个实测出来的实现级陷阱
 *
 * `ON CONFLICT (idempotency_key) DO NOTHING` 会直接报 **42P10**，
 * 因为部分唯一索引（带 WHERE 的那个）**不能被无谓词的冲突推断匹配到**。
 * 必须把索引谓词原样带上：
 *
 *     ON CONFLICT (idempotency_key)
 *       WHERE idempotency_key <> '' AND reversed_at IS NULL
 *       DO NOTHING
 *
 * 这条已在本机 PG 17.10 上实测确认（迁移计划 §R5）。
 */

/**
 * 「余额」的统一口径 —— **两个减法都要做，少一个都会算错**。
 *
 *   ① `reversed_at is null` —— 排除被撤销的那笔原记录；
 *   ② `reversal_of = ''` —— 排除**冲正笔本身**。
 *
 * 只写 ① 的后果：撤销后原记录不再参与求和，而冲正笔（它是 `reversed_at is null`
 * 的！）把负数也算进来 → **同一笔撤销被减了两次**。
 * 症状是「撤销 +5 之后余额少了 10」，而它不报错、只表现为数字不对。
 *
 * 与本地口径逐字对齐（`PointAccount.fromLedger`：
 * `if (entry.isReversed || entry.isReversal) continue;`）。
 */
const ALIVE = `reversed_at is null and reversal_of = ''`;

/** 同一口径，带别名前缀（子查询里两张表都叫 point_ledger，必须限定）。 */
const ALIVE_OF = (alias) => `${alias}.reversed_at is null and ${alias}.reversal_of = ''`;

/** 账本查询：用来验证「写入后能读到」以及「重试没有多出一条」。 */
export async function queryLedger(client, ctx, query) {
  const limit = Math.min(Number(query?.limit ?? 50) || 50, 200);
  const r = await client.query(
    `select id, student_id, action, points, reason, idempotency_key,
            reversal_of, ref_type, ref_id, created_at, created_by, reversed_at,
            -- 余额永远由这张表求和得来，不另存字段
            (select coalesce(sum(points), 0)::int from point_ledger p2
              where p2.student_id = p1.student_id and ${ALIVE_OF('p2')}
            ) as balance
       from point_ledger p1
      where student_id = any($1::text[])
      order by created_at desc nulls last, id
      limit $2`,
    [ctx.students, limit],
  );
  return { items: rowsToApi(r.rows) };
}

/**
 * 入账（幂等）。
 *
 * 返回值里的 `created` 是给测试和排查用的：
 * 第一次 true、重试 false，但**两次返回的 entry 是同一笔**。
 */
export async function earnPoints(client, ctx, body) {
  const studentId = requireVisibleStudent(ctx.visibleStudents, body.studentId);

  const action = String(body.action ?? '').trim();
  if (action === '') throw badRequest('缺少 action');

  const points = Number(body.points ?? 0);
  if (!Number.isInteger(points)) throw badRequest('points 必须是整数');
  if (points === 0) throw badRequest('points 不能为 0（无意义的账目）');

  // 没有幂等键时：不参与防重（空串不在部分索引的谓词范围内），
  // 所以同一次操作的多笔都能写进去。这是刻意的，见 DDL 注释。
  const idempotencyKey = String(body.idempotencyKey ?? '').trim();

  const inserted = await client.query(
    `insert into point_ledger (
       id, student_id, action, points, reason, idempotency_key,
       ref_type, ref_id, created_at, created_by
     ) values (
       $1, $2, $3, $4, $5, $6, $7, $8, now(), $9
     )
     on conflict (idempotency_key)
       where idempotency_key <> '' and reversed_at is null
       do nothing
     returning *`,
    [
      newId(),
      studentId,
      action,
      points,
      String(body.reason ?? ''),
      idempotencyKey,
      String(body.refType ?? ''),
      String(body.refId ?? ''),
      ctx.userId,
    ],
  );

  if (inserted.rowCount > 0) {
    return { created: true, entry: rowToApi(inserted.rows[0]) };
  }

  // 走到这里说明幂等键命中了「还活着」的记录 —— 即这次是重放。
  // 回查时**不加 student_id 条件**：让 RLS 去决定这条记录我看不看得到。
  const existing = await client.query(
    `select * from point_ledger
      where idempotency_key = $1
        and idempotency_key <> ''
        and reversed_at is null
      order by created_at desc
      limit 1`,
    [idempotencyKey],
  );

  if (existing.rowCount === 0) {
    // 只有一种情况能到这里：这个 key 已被**别的学生**用过。
    // 不回 internal 而是回 forbidden —— 前者会让人去查数据一致性，
    // 而实际上数据是一致的，是这次调用越了界。
    throw forbidden('该幂等键已被占用（同一个键不能代表两个学生的入账）');
  }

  return { created: false, entry: rowToApi(existing.rows[0]) };
}

/**
 * 撤销一笔发分 —— **标记原记录 + 补一笔相反数**，两步一次事务。
 *
 * ## 为什么必须是两步（S1 的骨架只做了第一步）
 *
 * 账本是 append-only 的。只把 `reversed_at` 置上，等于让「撤销」这件事
 * **只留下一个状态位、不留痕迹**：谁撤的、什么时候撤的、撤的是多少，全都查不到。
 * 而账本的用途之一就是回答「这 5 分为什么没了」。
 *
 * 补的那笔冲正记录**不带幂等键**：带上就会和原记录去抢同一个部分唯一索引，
 * 于是撤销这一步自己失败（`ON CONFLICT` 命中），症状是「点撤销没反应」。
 * 它的身份由 `reversal_of` 说明，不靠幂等键。
 *
 * ## 并发下的正确性
 *
 * 两个请求同时撤同一笔时，`update … where reversed_at is null` 只有一个会
 * 命中（`rowCount = 1`），另一个拿到 0 → 回 `already_reversed`，**不补第二笔冲正**。
 * 这条守卫必须写在 UPDATE 的 WHERE 里，不能写成「先查再判断」——
 * 查与判之间那条缝正是重复冲正的入口。
 *
 * 入参两种形态（客户端两处调用点各有各的方便）：
 *   · `{entryId}` —— 已经拿到这笔流水的 id（明细页上的撤销按钮）；
 *   · `{studentId, idempotencyKey}` —— 只知道业务键（打卡后撤销打卡）。
 */
export async function revokePoints(client, ctx, body) {
  const entryId = String(body.entryId ?? '').trim();

  let target = null;
  if (entryId !== '') {
    // 不给 student_id 条件：这条记录能不能看见由 RLS 决定。
    // 别人的流水在这里表现为「查不到」→ 下面回 not_found，不泄露它是否存在。
    const r = await client.query(
      `select * from point_ledger where id = $1 and reversed_at is null`,
      [entryId],
    );
    target = r.rows[0] ?? null;
  } else {
    const studentId = requireVisibleStudent(ctx.visibleStudents, body.studentId);
    const key = String(body.idempotencyKey ?? '').trim();
    if (key === '') throw badRequest('缺少 entryId 或 (studentId + idempotencyKey)');
    const r = await client.query(
      `select * from point_ledger
        where student_id = $1 and idempotency_key = $2 and reversed_at is null
        order by created_at desc
        limit 1`,
      [studentId, key],
    );
    target = r.rows[0] ?? null;
  }

  // 找不到 = 本来就没发过分（例：家长事后才把这项分值关掉）。
  // **不是错误** —— 本地实现同样返回 false 而不抛。撤一个不存在的东西
  // 报 404 只会让调用方去查数据一致性，而数据是一致的。
  if (!target) return { revoked: false, reason: 'not_found' };

  const marked = await client.query(
    `update point_ledger
        set reversed_at = now()
      where id = $1 and reversed_at is null
      returning *`,
    [target.id],
  );
  if (marked.rowCount === 0) return { revoked: false, reason: 'already_reversed' };

  const original = marked.rows[0];
  const reversed = await client.query(
    `insert into point_ledger (
       id, student_id, action, points, reason, idempotency_key,
       reversal_of, ref_type, ref_id, created_at, created_by
     ) values (
       $1, $2, $3, $4, $5, '', $6, $7, $8, now(), $9
     )
     returning *`,
    [
      newId(),
      original.student_id,
      original.action,
      -original.points,
      String(body.reason ?? '').trim() === '' ? `撤销：${original.reason}` : String(body.reason).trim(),
      original.id,
      original.ref_type,
      original.ref_id,
      ctx.userId,
    ],
  );

  return {
    revoked: true,
    entry: rowToApi(original),
    reversal: rowToApi(reversed.rows[0]),
  };
}

/**
 * 求余额。余额永远由账本求和得来，不另存字段。
 *
 * ⚠️ 第三个参数是 **query 对象**（不是 studentId 字符串）——GET 路由统一把 query 传给 handler。
 * 这里踩过一次：签名写成 `studentId` 后收到的是 `{studentId:'…'}`，
 * `requireVisibleStudent` 拿一个对象去比对可见集合，于是一律 403。
 */
export async function balanceOf(client, ctx, query) {
  // 没显式指定时，可见集合里只有一个学生就直接用它（学生查自己的余额是常态）。
  const requested = query?.studentId
    ?? (ctx.students.length === 1 ? ctx.students[0] : undefined);
  const one = requireVisibleStudent(ctx.visibleStudents, requested);
  const r = await client.query(
    `select coalesce(sum(points), 0)::int as balance
       from point_ledger
      where student_id = $1 and ${ALIVE}`,
    [one],
  );
  return { studentId: one, balance: r.rows[0].balance };
}

/**
 * 家长配过的分值。
 *
 * 「没配过的动作在这里没有行」是刻意的：默认值属于业务规则（L1），
 * 服务端不预生成一堆行 —— 那样默认值就有两个来源，改一个忘一个。
 */
export async function listRules(client, ctx, query) {
  const r = await client.query(
    `select * from point_rule
      where student_id = any($1::text[])
      order by student_id, action`,
    [ctx.students],
  );
  return { items: rowsToApi(r.rows) };
}

/**
 * 覆盖式写入一条规则（复合键 `(studentId, action)` 唯一）。
 *
 * 用 `ON CONFLICT … DO UPDATE` 而不是先删后插：后者在并发下会留下
 * 「删了但没插上」的一小段窗口，而那段时间里计分回退到默认值 ——
 * 学生恰好在那时打卡，就按默认分值记了分。
 */
export async function upsertRule(client, ctx, body) {
  const studentId = requireVisibleStudent(ctx.visibleStudents, body.studentId);
  const action = String(body.action ?? '').trim();
  if (action === '') throw badRequest('缺少 action');
  const points = requireInt(body.points, 'points');
  const enabled = toBool(body.enabled, 'enabled') ?? true;

  const r = await client.query(
    `insert into point_rule (student_id, action, points, enabled, updated_at)
     values ($1, $2, $3, $4, now())
     on conflict (student_id, action) do update
       set points = excluded.points,
           enabled = excluded.enabled,
           updated_at = now()
     returning *`,
    [studentId, action, points, enabled],
  );
  return { rule: rowToApi(r.rows[0]) };
}
