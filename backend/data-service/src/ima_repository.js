import { encryptSecret, decryptSecret } from './crypto.js';

/**
 * ima 凭证与「学生→KB」映射的持久层。
 *
 * 两张表：`ima_credential`（配置人级，存加密后的 clientid/apikey + 同步状态）、
 * `ima_student_kb`（每个学生一个独立 KB 的映射）。所有函数接收 pg `client`，
 * 跟随调用方的请求事务 —— 要么整段提交，要么整段回滚，避免出现
 * 「凭证写进去了但 KB 没建」这类半截状态。
 *
 * ⚠️ 归属口径（2026-11-08 定稿，见 `doc/ima-integration-design.md` §2）：
 * **配置主体是学生**。`ima_student_kb.student_id` 是唯一入口，
 * `owner_user_id` 只是「谁填的密钥」这一审计事实。所有读取都必须走
 * `studentId → 映射行 → 配置人凭证`，**不许**从当前登录用户反推家长
 * （父母共管时 `limit 1` 会取到没配的那位，档案静默不推）。
 *
 * 加密/解密集中在这里：明文 clientid/apikey 只在内存里存在（用于调 ima 的那一瞬间），
 * 落库的全是 `iv:tag:ct` 密文。密钥来自 `IMA_CREDENTIAL_SECRET`，绝不进库。
 */

/** 取某 owner 的 ima 凭证（密文）。无则返回 null。 */
export async function getImaCredential(client, ownerUserId) {
  const r = await client.query(
    `select clientid_enc, apikey_enc, status, kb_owner_name
       from ima_credential where owner_user_id = $1`,
    [ownerUserId],
  );
  if (r.rowCount === 0) return null;
  const row = r.rows[0];
  return {
    clientidEnc: row.clientid_enc,
    apikeyEnc: row.apikey_enc,
    status: row.status,
    kbOwnerName: row.kb_owner_name,
  };
}

/** 写入（或更新）某 owner 的 ima 凭证。on conflict 覆盖（重连时替换密钥）。 */
export async function upsertImaCredential(
  client,
  { ownerUserId, clientidEnc, apikeyEnc, status, kbOwnerName },
) {
  await client.query(
    `insert into ima_credential (owner_user_id, clientid_enc, apikey_enc, status, kb_owner_name, updated_at)
     values ($1, $2, $3, $4, $5, now())
     on conflict (owner_user_id) do update set
       clientid_enc = excluded.clientid_enc,
       apikey_enc = excluded.apikey_enc,
       status = excluded.status,
       kb_owner_name = excluded.kb_owner_name,
       updated_at = now()`,
    [ownerUserId, clientidEnc, apikeyEnc, status, kbOwnerName ?? null],
  );
}

/** 只改同步状态（断开 / 标记失效）。 */
export async function setImaCredentialStatus(client, ownerUserId, status) {
  await client.query(
    `update ima_credential set status = $2, updated_at = now() where owner_user_id = $1`,
    [ownerUserId, status],
  );
}

/** 取某学生的 KB 映射（含 owner）。无则返回 null。 */
export async function getImaStudentKb(client, studentId) {
  const r = await client.query(
    `select kb_id, owner_user_id, kb_name from ima_student_kb where student_id = $1`,
    [studentId],
  );
  if (r.rowCount === 0) return null;
  const row = r.rows[0];
  return { kbId: row.kb_id, ownerUserId: row.owner_user_id, kbName: row.kb_name };
}

/** 写入（或更新）某学生的 KB 映射。 */
export async function upsertImaStudentKb(client, { studentId, ownerUserId, kbId, kbName }) {
  await client.query(
    `insert into ima_student_kb (student_id, owner_user_id, kb_id, kb_name, created_at)
     values ($1, $2, $3, $4, now())
     on conflict (student_id) do update set
       owner_user_id = excluded.owner_user_id,
       kb_id = excluded.kb_id,
       kb_name = excluded.kb_name`,
    [studentId, ownerUserId, kbId, kbName],
  );
}

/**
 * 取「某个学生的完整 ima 配置」：KB 映射 + 配置人的凭证状态。
 *
 * 这是按学生口径的**唯一读入口**。父母共管时，两位家长用各自身份查同一个
 * `studentId`，拿到的都是同一行映射、同一个 kb_id、同一份凭证状态 ——
 * 不会各建一个库，也不会因为 `limit 1` 取错家长。
 *
 * 拆成两条查询而不是 JOIN，是为了让「没有映射」与「映射在、凭证行不在」
 * 两种状态都能被上层区分（后者仍应回传 kb_name，供家长看到库名）。
 * 两次查询都在同一请求事务里，RLS 身份一致。
 *
 * @returns {{kbId:string, kbName:string, ownerUserId:string,
 *            status:string, clientidEnc:string, apikeyEnc:string}|null}
 */
export async function getStudentImaConfig(client, studentId) {
  const kb = await getImaStudentKb(client, studentId);
  if (!kb) return null;
  const cred = await getImaCredential(client, kb.ownerUserId);
  return {
    ...kb,
    status: cred?.status ?? IMA_UNCONNECTED,
    clientidEnc: cred?.clientidEnc ?? '',
    apikeyEnc: cred?.apikeyEnc ?? '',
  };
}

/** 未连接状态字面的唯一定义点（与 `ima_openapi.IMA_STATUS` 同源，避免循环依赖）。 */
const IMA_UNCONNECTED = 'unconnected';

/** 列出某 owner 名下所有学生的 KB 映射（运维/对账用，业务读请走 [getStudentImaConfig]）。 */
export async function listImaStudentKbs(client, ownerUserId) {
  const r = await client.query(
    `select student_id, kb_id, kb_name from ima_student_kb
      where owner_user_id = $1 order by student_id`,
    [ownerUserId],
  );
  return r.rows.map((x) => ({ studentId: x.student_id, kbId: x.kb_id, kbName: x.kb_name }));
}

/**
 * 把密文凭证还原成明文（仅用于调 ima 的那一瞬）。
 * @param {{clientidEnc:string, apikeyEnc:string}} enc
 * @param {string} secret IMA_CREDENTIAL_SECRET
 */
export function decryptCredential(enc, secret) {
  return {
    clientId: decryptSecret(enc.clientidEnc, secret),
    apiKey: decryptSecret(enc.apikeyEnc, secret),
  };
}

/**
 * 加密一对明文凭证。集中在这里，调用方不必关心格式。
 * @param {{clientid:string, apikey:string}} plain
 * @param {string} secret
 */
export function encryptCredential(plain, secret) {
  return {
    clientidEnc: encryptSecret(plain.clientid, secret),
    apikeyEnc: encryptSecret(plain.apikey, secret),
  };
}
