import { badRequest, forbidden } from '../../../shared/errors.js';
import { requireText, toText } from '../coerce.js';
import { pick, rowToApi, rowsToApi } from '../mapper.js';
import { buildUpdate } from '../patch.js';

/**
 * 用户与档案（`UserRepository`）。
 *
 * ## 这一组是 S3 的收尾，不是新功能
 *
 * 迁移计划 §4.3 的表里给 `users` 列了 `saveUser` 与 `bootstrap` 两条，
 * 而 S3 落地时**一条都没建** —— 理由是 §4.5 ④：聚合读端点（`bootstrap` /
 * `home/*` / `review/board`）推迟到 S4。`users` 组被一起推迟了，
 * 于是客户端切过来时「读一个档案」「把孩子 id 解析成姓名」两件事无处可去。
 *
 * 所以这里只补**契约真正需要**的两条，并把 `bootstrap` 那种聚合留给 S4：
 *
 *   · `GET  /data/users`          读一行或一批（`?userId=` / `?ids=a,b`）
 *   · `POST /data/users/profile`  改档案（只改传进来的字段）
 *
 * ## 为什么档案列就在 `app_user` 上
 *
 * 客户端那边 `user_profile` 是一张单独的表；PG 里没有，也不需要 ——
 * `gender / grade / hobbies / bio` 四列本来就在 `app_user` 的 DDL 里
 * （`sql/001_schema.sql:35`）。再拆一张表会多一条 policy、多一次 JOIN，
 * 换来的只是「与客户端表结构长得一样」，而客户端表结构不是这里的约束对象。
 *
 * ## 越权面：这一组**没有一行权限代码**
 *
 * `app_user` 的 policy 是 S2 按命令拆开的（`sql/004_credential.sql`）：
 *   · `user_read`       —— 自己 + 可见学生（`student_id = any(visible_students)`）；
 *   · `user_write_self` —— **只有自己那一行**。
 *
 * 于是「家长读孩子档案」可行、「家长改孩子档案」在数据库层就不成立，
 * 而这里一句都没有写。这正是 R5 想要的状态：边界不是约定，是机制。
 * 代价是调用方拿不到「为什么改不了」—— `rowCount = 0` 后面跟着一个
 * `forbidden`，文案里两个原因都提一句（见下）。
 */
const PROFILE_COLUMNS = 'id, name, phone, role, avatar, gender, grade, term, hobbies, bio';

/** 一次最多取几行。家长端解析孩子姓名用不到更多，而这是给枚举面加闸。 */
const MAX_IDS = 100;

/**
 * `hobbies` 在客户端是一个**逗号串**（`UserProfileModel.toMap` 里
 * `hobbies.join(',')`），所以它在库里是一列 TEXT 而不是数组 ——
 * 尊重现状，不在这里做「更规范的」拆分：那会让客户端要改一次解析，
 * 而这件事与上云无关。
 */
const PROFILE_SPEC = {
  name: (v) => requireText(v, 'name'),
  gender: (v) => toText(v) ?? '',
  grade: (v) => toText(v) ?? '',
  // 学期：`上` / `下` / 空串（未填写）。与 grade 分开存，
  // 升学期只改这一个字段，历史错题的年级学期快照不受影响。
  term: (v) => toText(v) ?? '',
  hobbies: (v) => toText(v) ?? '',
  bio: (v) => toText(v) ?? '',
};

/**
 * 取用户行。
 *
 * 两个读法合成一个端点，差别只是 where 的一个条件 —— 与
 * `listHomeworkImages` 合并 `studentId` / `homeworkId` 是同一个判断：
 * 客户端那两个方法（`queryUserProfile` / `queryUsersByIds`）取的是**同一个东西**
 * （`app_user` 的一行），只有形状不同。
 *
 * ⚠️ **一个都没传时不报错，而是取自己。** 「我是谁」在服务端由 token 决定，
 * 而客户端确实有「读我自己的档案」这条路径 —— 让它必须显式传自己的 id，
 * 等于要求客户端相信自己（而它只能相信自己手里的那份缓存）。
 */
export async function listUsers(client, ctx, query) {
  const userId = query?.userId ? String(query.userId).trim() : '';
  const ids = String(query?.ids ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s !== '');

  let wanted;
  if (userId !== '') wanted = [userId];
  else if (ids.length > 0) wanted = ids;
  else wanted = [ctx.userId];

  if (wanted.length > MAX_IDS) {
    throw badRequest(`一次最多取 ${MAX_IDS} 个用户（收到 ${wanted.length} 个）`);
  }

  const r = await client.query(
    `select ${PROFILE_COLUMNS}
       from app_user
      where id = any($1::text[])
      order by name, id`,
    [wanted],
  );
  // **取不到的 id 直接不出现**，不报错 —— 与本地实现同语义
  // （`queryUsersByIds` 也是「查到几行返回几行」）。为「有一个 id 看不见」
  // 报错会让家长端在一个已解绑的孩子身上整页失败，而正确行为是少一行。
  return { items: rowsToApi(r.rows) };
}

/**
 * 改档案。**只改传进来的字段**（`buildUpdate` 的掩码语义）。
 *
 * 不做整行 replace 的理由与心愿那份一样：家长端与孩子端可能各改一部分，
 * 整行覆盖会让后写的那次把先写的抹掉，而且不报错。
 */
export async function saveProfile(client, ctx, body) {
  const targetId = body?.userId ? requireText(body.userId, 'userId') : ctx.userId;
  const fields = pick(body ?? {}, Object.keys(PROFILE_SPEC));

  const update = buildUpdate({
    table: 'app_user',
    spec: PROFILE_SPEC,
    body: fields,
    // 作用域只写 id：**能改谁**由 `user_write_self` 那条 policy 说了算。
    // 在这里再写一遍 `and id = ctx.userId` 是重复的，而重复的边界
    // 最容易漂 —— 一处改了另一处没改，看起来还是「有两道防线」。
    where: 'id = $1',
    whereValues: [targetId],
  });
  if (!update) return { updated: false, id: targetId };

  const r = await client.query(update.text, update.values);
  if (r.rowCount === 0) {
    // 两种可能：这个 id 不存在，或者它不是你自己（policy 挡掉了）。
    // 对调用方是同一件事：这次改不了。文案把两个原因都提一句，
    // 否则「家长想改孩子档案」会表现成「用户不存在」——
    // 一个会把人带去查错方向的文案。
    throw forbidden('找不到这个用户，或它不是你自己（档案只能本人修改）');
  }
  return { updated: true, item: rowToApi(r.rows[0]) };
}
