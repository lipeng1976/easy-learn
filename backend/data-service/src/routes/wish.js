import { badRequest, forbidden } from '../../../shared/errors.js';
import { requireVisibleStudent } from '../auth.js';
import { rowToApi, rowsToApi } from '../mapper.js';
import { buildInsert } from '../insert.js';
import { buildUpdate, emptyPatchResult } from '../patch.js';
import { toBool, toInt, toTs, requireText } from '../coerce.js';
import { notifyBoundPartners, NotificationTypes } from './notify.js';

/**
 * 心愿。
 *
 * ## 这个文件里最要紧的一件事：把「客户端自报的角色」换成「token 里的角色」
 *
 * 接口注释点名了同一处问题：本接口有 4 个读方法带 `userRole` 参数，而当前实现
 * 直接拿它当 SQL 条件（`where: 'userRole = ?'`）。单机单库下没问题 ——
 * 库里只有这一台设备的数据。上云后两件事同时变质：
 *   · `userRole` 由客户端给 → 改个包写成对方的角色，就能读到对方的心愿；
 *   · 按 `studentId` 挑「我结对的孩子」是**先取全表、再内存过滤**（陷阱⑥）。
 *
 * 服务端的做法：**参数留在线上（客户端还在传），但一概不读** ——
 * 角色取 `ctx.role`，范围取 `ctx.visibleStudents`。于是「传了什么」不再重要，
 * 而客户端不需要为这件事改一行代码（S4 时它们自然会被删掉）。
 *
 * ⚠️ `wish.user_role` 这一列仍然写，但值**由服务端写**（`ctx.role`），
 * 不再采信请求体。这一列是「谁发起的心愿」（学生自己许的 / 家长替孩子许的），
 * 是一个业务事实，不是权限声明 —— 但让客户端自报它就是在给自己发权限。
 */

const WISH_SPEC = {
  title: (v) => (v === null || v === undefined ? null : String(v)),
  description: (v) => (v === null || v === undefined ? null : String(v)),
  isPublic: (v, f) => toBool(v, f) ?? false,
  parentConfirmed: (v, f) => toBool(v, f) ?? false,
  studentConfirmed: (v, f) => toBool(v, f) ?? false,
  isArchived: (v, f) => toBool(v, f) ?? false,
  expectedDate: (v, f) => toTs(v, f),
  pointCost: (v, f) => toInt(v, f) ?? 0,
  redeemRequestedAt: (v, f) => toTs(v, f),
  redeemedAt: (v, f) => toTs(v, f),
  redeemRejectedAt: (v, f) => toTs(v, f),
};

const CONFIRM_SPEC = {
  parentConfirmed: (v, f) => toBool(v, f),
  studentConfirmed: (v, f) => toBool(v, f),
};

/**
 * 心愿列表。
 *
 * 本地有四个读方法（`queryWishes(role)` / `queryPublicWishes()` /
 * `queryPublicWishesByStudent(id)` / `queryUnfulfilledWishes()`），
 * 差别只在「按什么筛」——服务端用一个 `scope` 参数表达，**范围永远来自 token**。
 *
 *   scope=created     我这一侧发起的心愿（学生许的 / 家长替孩子许的）
 *   scope=public      可见学生的公开心愿（+ studentId 挑一个孩子）
 *   scope=unfulfilled 未闭环的（没归档、且双方没都确认）
 */
export async function listWishes(client, ctx, query) {
  const scope = String(query?.scope ?? 'created');
  const studentId = query?.studentId ? String(query.studentId) : null;

  // 未闭环 = 没归档 且 不是「双方都确认」。
  // ⚠️ 这个定义**不等于「没兑现」**：`isArchived` 与两个 confirmed 是独立的两组
  // 字段，本方法只按它们组合判断。改口径会同时影响学生端与家长端的待办提醒。
  //
  // ⚠️ 片段与**它自己的参数**放在一起（`params`），不要只在外面拼 SQL 片段、
  // 参数写成一个固定长度的数组 —— 那样只要有一个口径不需要占位符，
  // 参数个数就和占位符对不上，报出来的是 postgres 的
  // `bind message supplies 3 parameters, but prepared statement requires 2`，
  // 而它指的是「另一条分支」坏了。真实撞到过：`public` 口径是家长首页要用的那条。
  const extra = {
    created: { sql: 'and user_role = $3', params: [ctx.role] },
    public: { sql: 'and is_public = true', params: [] },
    unfulfilled: {
      sql: 'and not is_archived and not (parent_confirmed and student_confirmed)',
      params: [],
    },
  }[scope];
  if (!extra) throw badRequest('scope 只能是 created / public / unfulfilled 之一');

  // `$3` 只在 created 口径下存在，所以它必须是**最后一个**参数。
  const r = await client.query(
    `select * from wish
      where student_id = any($1::text[])
        and ($2::text is null or student_id = $2)
        ${extra.sql}
      order by expected_date nulls last, id`,
    [ctx.students, studentId, ...extra.params],
  );
  return { items: rowsToApi(r.rows) };
}

/**
 * 新建心愿。
 *
 * `user_role` 由服务端写（见文件头）。`id` 也由服务端生成（R2）。
 */
export async function insertWish(client, ctx, body) {
  const studentId = requireVisibleStudent(ctx.visibleStudents, body.studentId);
  const ins = buildInsert({
    table: 'wish',
    spec: WISH_SPEC,
    body,
    extras: [
      { column: 'id', value: globalThis.crypto.randomUUID() },
      { column: 'student_id', value: studentId },
      { column: 'user_role', value: ctx.role },
    ],
  });
  const r = await client.query(ins.text, ins.values);
  return { item: rowToApi(r.rows[0]) };
}

/**
 * 改确认状态（`updateWishConfirmation`）。
 *
 * 两个参数都是 `null` 时**静默返回**（不是错误、不抛异常）——
 * 调用方不必先判断再调用。服务端用「键出现即写」的掩码表达同一件事：
 * 两个键都没出现 → 空掩码 → 返回 `{updated:false}`。
 */
export async function confirmWish(client, ctx, body) {
  const id = requireText(body.id, 'id');
  const update = buildUpdate({
    table: 'wish',
    spec: CONFIRM_SPEC,
    body,
    where: 'id = $1 and student_id = any($2::text[])',
    whereValues: [id, ctx.students],
  });
  if (!update) return { ...emptyPatchResult(), id };
  const r = await client.query(update.text, update.values);
  if (r.rowCount === 0) throw forbidden('找不到这个心愿（或无权修改）');
  return { updated: true, item: rowToApi(r.rows[0]) };
}

/** 归档 / 取消归档。传的是**目标值**，不是「切换」（重复调用结果相同）。 */
export async function archiveWish(client, ctx, body) {
  const id = requireText(body.id, 'id');
  const isArchived = toBool(body.isArchived, 'isArchived');
  if (isArchived === null) throw badRequest('缺少 isArchived');

  const r = await client.query(
    `update wish set is_archived = $3
      where id = $1 and student_id = any($2::text[])
      returning *`,
    [id, ctx.students, isArchived],
  );
  if (r.rowCount === 0) throw forbidden('找不到这个心愿（或无权修改）');
  return { item: rowToApi(r.rows[0]) };
}

/**
 * 兑换状态：定价 / 申请 / 兑现 / 拒绝（`updateWishRedeemState`）。
 *
 * ## 清空用**显式的 clear 标志**，不许用 `null`
 *
 * 这是接口注释里定好的契约，也是本项目踩过的那个坑的正面解：
 * `{"a": null}` 与「`a` 键不存在」在**构造 Map 的写法**里会被混成一个东西，
 * 于是「清空」这个意图会在序列化时被静默抹掉。
 * 所以：想清空 → 传 `clearRedeemRequest: true`；不想动 → 不传这个键。
 *
 * ⚠️ `redeemedAt` **只能设、不能清**（没有对应的 clear 标志）。
 * 所以「传了 null」在这里是**报错**而不是清空 —— 让它在网络边界上失败，
 * 比让一个「撤销兑现」的模糊意图静默生效安全：那个动作会动余额。
 * 将来真要做「撤销兑现」，请补一个 `clearRedeemed`，不要改成用 null 表达清空。
 *
 * ## 也刻意不做整体覆盖
 *
 * 学生撤回申请和家长同时点兑现，两边各拿一份 `WishModel` 去写，
 * 整体覆盖会让后写的把先写的整段抹掉。只写自己关心的那几列，冲突面小得多。
 */
export async function redeemWish(client, ctx, body) {
  const id = requireText(body.id, 'id');

  if ('redeemedAt' in body && body.redeemedAt === null) {
    throw badRequest(
      'redeemedAt 不能用 null 表达「清空」——那会把「撤销兑现」混进一次普通更新。'
        + '要清空请先补一个 clearRedeemed 标志（见 WishRepository.updateWishRedeemState 的说明）。',
    );
  }

  const sets = [];
  const values = [id, ctx.students];
  const push = (column, value) => {
    values.push(value);
    sets.push(`${column} = $${values.length}`);
  };

  if ('pointCost' in body) push('point_cost', toInt(body.pointCost, 'pointCost') ?? 0);

  // clear 标志**优先于**同名的值字段 —— 这正是本地实现里的顺序语义
  // （`if (clearRedeemRequest) … else if (redeemRequestedAt != null) …`）。
  if (body.clearRedeemRequest === true) {
    push('redeem_requested_at', null);
  } else if ('redeemRequestedAt' in body) {
    push('redeem_requested_at', toTs(body.redeemRequestedAt, 'redeemRequestedAt'));
  }

  if (body.clearRedeemRejected === true) {
    push('redeem_rejected_at', null);
  } else if ('redeemRejectedAt' in body) {
    push('redeem_rejected_at', toTs(body.redeemRejectedAt, 'redeemRejectedAt'));
  }

  if ('redeemedAt' in body) push('redeemed_at', toTs(body.redeemedAt, 'redeemedAt'));

  if (sets.length === 0) return { ...emptyPatchResult(), id };

  const r = await client.query(
    `update wish set ${sets.join(', ')}
      where id = $1 and student_id = any($2::text[])
      returning *`,
    values,
  );
  if (r.rowCount === 0) throw forbidden('找不到这个心愿（或无权修改）');

  const item = r.rows[0];
  // 事件 → 通知：申请兑现要告诉家长，兑现/拒绝要告诉学生（陷阱⑦的服务端落点）。
  if ('redeemRequestedAt' in body && body.redeemRequestedAt !== null) {
    await notifyBoundPartners(client, ctx, {
      title: '孩子想兑换心愿',
      body: `《${item.title}》申请兑现，需要 ${item.point_cost} 分`,
      type: NotificationTypes.wish,
      relatedBizId: item.id,
    });
  } else if ('redeemedAt' in body && body.redeemedAt !== null) {
    await notifyBoundPartners(client, ctx, {
      title: '心愿已兑现',
      body: `《${item.title}》已经兑现啦`,
      type: NotificationTypes.wish,
      relatedBizId: item.id,
    });
  } else if (body.clearRedeemRequest === true) {
    await notifyBoundPartners(client, ctx, {
      title: '心愿申请已撤回',
      body: `《${item.title}》的兑现申请被撤回了`,
      type: NotificationTypes.wish,
      relatedBizId: item.id,
    });
  }

  return { updated: true, item: rowToApi(item) };
}
