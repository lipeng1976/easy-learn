#!/usr/bin/env node
/**
 * 开通「FC 访问 VPC 用的服务角色」—— 开通是一次性动作，但**这个脚本必须可重复跑**。
 *
 * ── 它解决的是什么 ──────────────────────────────────────────────────────────
 *
 * 只要函数配了 `vpcConfig`，FC 就必须有一把角色替它在 VPC 里创建弹性网卡（ENI）。
 * 不配会当场失败（2026-09-24 实测）：
 *     InvalidArgument: code: 400, Role is required for accessing VPC
 *
 * 角色绑的策略**必须是** `AliyunECSNetworkInterfaceManagementAccess`。
 *
 * ⚠️ **不要**改用 s 的 `role: auto` 来「顺便」把角色建出来：它建的是
 *    `AliyunFcDefaultRole` 绑 `AliyunFCDefaultRolePolicy`（**给触发器用的那套**），
 *    里面没有建 ENI 的权限 —— 而失败形态**不是报错**，是「部署成功、函数起得来、
 *    就是连不上数据库」。本项目最怕的就是这种安静的错误。
 *
 * ── 幂等性 ──────────────────────────────────────────────────────────────────
 *
 * 每一步都先问一句再动手，所以**跑第二次不会报错、也不会重复建**：
 *   ① GetRole            角色在不在     → 在就跳过创建
 *   ② ListPoliciesForRole 策略绑没绑    → 绑了就跳过
 * 这样它既是「首次开通」也是「体检」：出问题时再跑一次就能看出哪一步没成。
 *
 * ── 用法 ────────────────────────────────────────────────────────────────────
 *
 *     ALIYUN_AK=xxx ALIYUN_SK=xxx node serverless/scripts/provision-fc-vpc-role.mjs
 *
 * 角色名从 `.env.prod` 的 `FC_ROLE_NAME` 读（s.yaml 引用的就是它，**一处真值**）。
 *
 * ⚠️ 凭证**只认环境变量**：`~/.s/access.yaml` 里存的是密文，借不出来
 *    （原因见 aliyun-rpc.mjs 顶部那段）。所以这条命令必须带上 ALIYUN_AK/ALIYUN_SK。
 *
 * ⚠️ 这个脚本需要 **RAM 写权限**（CreateRole / AttachPolicyToRole）。
 *    用一把临时的、事后会轮换的凭证跑它 —— 别把它接到长期凭证上。
 */
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { rpcCall } from './aliyun-rpc.mjs';
import { loadEnv } from '../data-service/scripts/lib/env-file.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '../..');

/** 唯一需要被授予的系统策略：「管弹性网卡」。 */
const POLICY_NAME = 'AliyunECSNetworkInterfaceManagementAccess';

/** 信任策略：只允许**函数计算**扮演这把角色（别的服务都拿不到它）。 */
const TRUST_POLICY = JSON.stringify(
  {
    Statement: [
      {
        Action: 'sts:AssumeRole',
        Effect: 'Allow',
        Principal: { Service: ['fc.aliyuncs.com'] },
      },
    ],
    Version: '1',
  },
  null,
  2,
);

const ROLE_DESC = '学习小助手：供 FC 在 VPC 内创建弹性网卡（ENI）用的服务角色';

function die(msg, ...hints) {
  console.error(`\n✗ ${msg}`);
  for (const h of hints) console.error(`  ${h}`);
  process.exit(1);
}

const ak = process.env.ALIYUN_AK;
const sk = process.env.ALIYUN_SK;
if (!ak || !sk) {
  die(
    '没给凭证。本脚本只认环境变量（access.yaml 里是密文，借不出来）。',
    '用法：ALIYUN_AK=xxx ALIYUN_SK=xxx node serverless/scripts/provision-fc-vpc-role.mjs',
  );
}

const envPath = resolve(ROOT, '.env.prod');
let roleName;
try {
  roleName = loadEnv(envPath).env.FC_ROLE_NAME;
} catch (e) {
  die(`读不了 ${envPath}：${e.message}`);
}
if (!roleName) {
  die(
    '.env.prod 里没有 FC_ROLE_NAME —— 它是 s.yaml 里 `${env(\'FC_ROLE_NAME\')}` 的取值来源。',
    '补上那行（例：FC_ROLE_NAME=EasyLearnFCRole）再跑。',
  );
}

const call = (action, params, method = 'GET') =>
  rpcCall({ action, params, ak, sk, endpoint: 'ram.aliyuncs.com', version: '2015-05-01', method });

/** 把服务端的错误说清楚，而不是把整个 JSON 糊上去。 */
function why(res) {
  const code = res.body?.Code || '';
  const msg = res.body?.Message || res.raw?.slice(0, 200) || '';
  return `HTTP ${res.status}${code ? ` ${code}` : ''}${msg ? ` — ${msg}` : ''}`;
}

/** 权限不够时，给出「要去点哪里」而不是让用户自己猜。 */
function checkPerm(res, action) {
  if (res.status === 403) {
    die(
      `没有 RAM 权限（${action} 被拒）。这台机器的 AK 目前只是普通 RAM 用户。`,
      '去 RAM 控制台：用户 → 找到这把 AK 对应的用户 → 权限管理 → 新增授权 →',
      '选 `AliyunRAMFullAccess`，然后重跑本脚本。',
      '（跑完可以把这个授权撤掉 —— 加了角色之后就不再需要 RAM 权限了。）',
    );
  }
}

console.log(`▸ 角色名：${roleName}（来自 ${envPath}）`);
console.log(`▸ 目标策略：${POLICY_NAME}\n`);

// ── ① 角色存在吗 ────────────────────────────────────────────────────────────
const got = await call('GetRole', { RoleName: roleName });
checkPerm(got, 'ram:GetRole');

let roleArn;
if (got.status === 200) {
  roleArn = got.body?.Role?.Arn;
  console.log(`① 角色已存在 —— 跳过创建\n     ARN: ${roleArn}`);
} else if (got.status === 404 && /EntityNotExist/i.test(got.body?.Code || '')) {
  console.log('① 角色不存在 —— 创建中…');
  const created = await call(
    'CreateRole',
    {
      RoleName: roleName,
      Description: ROLE_DESC,
      AssumeRolePolicyDocument: TRUST_POLICY,
    },
    'POST', // 信任策略是一段 JSON，走 body 比塞进 URL 稳
  );
  checkPerm(created, 'ram:CreateRole');
  if (created.status !== 200) die(`创建角色失败：${why(created)}`);
  roleArn = created.body?.Role?.Arn;
  console.log(`   ✓ 已创建：${roleArn}`);
  console.log('     信任策略：只允许 fc.aliyuncs.com 扮演（别的服务拿不到它）');
} else {
  die(`查角色时得到一个没预料到的结果：${why(got)}`);
}

// ── ② 策略绑了吗 ────────────────────────────────────────────────────────────
const listed = await call('ListPoliciesForRole', { RoleName: roleName });
checkPerm(listed, 'ram:ListPoliciesForRole');
if (listed.status !== 200) die(`列角色策略失败：${why(listed)}`);

const policies = listed.body?.Policies?.Policy || [];
const has = policies.some((p) => p.PolicyName === POLICY_NAME);
if (has) {
  console.log(`② 策略已绑定 —— 跳过\n     ${POLICY_NAME}`);
} else {
  console.log(`② 未绑定 —— 授权中…`);
  const attached = await call('AttachPolicyToRole', {
    PolicyType: 'System',
    PolicyName: POLICY_NAME,
    RoleName: roleName,
  });
  checkPerm(attached, 'ram:AttachPolicyToRole');
  if (attached.status !== 200) die(`绑定策略失败：${why(attached)}`);
  console.log(`   ✓ 已绑定：${POLICY_NAME}`);
}

console.log(`\n✅ 角色就绪：${roleArn}`);
console.log('   它在 s.yaml 里是这样被用的：role: ${env(\'FC_ROLE_NAME\')}');
console.log('   （s 会自动把角色名补成完整 ARN，不必手写 acs:ram::...）');
console.log('\n   下一步：node serverless/scripts/run-s.mjs deploy');
