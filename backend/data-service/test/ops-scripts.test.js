import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { cloudHost } from '../scripts/lib/env-file.mjs';

/**
 * 运维脚本「取库地址」的守门人。
 *
 * ## 这个文件在守什么
 *
 * 2026-09-24 换 RDS **内网地址**时暴露的问题：生产库有**两个端点**，
 * 而它们是**两个不同的域名**（实例 ID 尾部只差两个字符，看起来像复制被截断）：
 *
 *   · `PGHOST`          —— 内网地址，**函数侧**用它（走 VPC 的 ENI）；
 *   · `PGHOST_EXTERNAL` —— 外网地址，**只在 VPC 外的本机**跑脚本时用。
 *
 * 内网地址从公网**能解析、但连不上**（实测本机解析到 `172.21.26.125`，
 * TCP 6.1s 超时；同实例的外网名 322ms 连上）。所以本机脚本要是直读 `env.PGHOST`，
 * 换地址那天会**集体静默失效** —— 报的是「连不上库」，看起来像白名单没放行或库挂了，
 * 真因只是解析到了私网 IP。**方向完全错，而且四个脚本会同时错。**
 *
 * 守两件事：
 *   ① 凡是在 `scripts/` 下**建 pg 连接**的脚本，都必须用 `cloudHost()` 取 host
 *      —— 用「建连接」这个**结构事实**筛，不在这里另抄一份脚本名单
 *      （抄一份的后果：新加的脚本永远不在名单里，而它恰恰最可能踩这个坑）；
 *   ② `cloudHost()` 自己的**回落顺序**：配了外网键就用外网键，没配才回落 `PGHOST`。
 *
 * 跑法：`npm test`（不需要 PG，也不需要网络）。
 */

const SCRIPTS = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'scripts');

/** 递归列出 `scripts/` 下的所有 `.mjs`（跳过 node_modules）。 */
function listScripts(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules') continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...listScripts(p));
    else if (name.endsWith('.mjs')) out.push(p);
  }
  return out;
}

test('⚠️ 凡是在 scripts/ 下建 pg 连接的脚本，都必须用 cloudHost() 取 host', () => {
  // 两个写法都算：`new pg.Client(` 与 `new Client(`（后者从 'pg' 里具名 import）。
  // ⚠️ 一开始只写了 `new Client(`，于是漏掉了四个用 `new pg.Client(` 的脚本 ——
  //    而「漏掉」的表现是这条判据看起来**全绿**。
  const BUILDS_CONNECTION = /new\s+(?:pg\.)?Client\s*\(/;

  // 豁免：**纯本机脚本**（`host` 写死环回地址，**且**不读环境变量文件）。
  // 典型是 `list-accounts.mjs` / `report-storage.mjs` —— 它们只连本机开发栈，
  // 压根不涉及「内网 vs 外网端点」这件事。豁免条件必须是**两条同时成立**：
  // 只判 `127.0.0.1` 会放过「本机默认值 + 可被 env 覆盖」的那种脚本，而那正是要防的。
  const isLocalOnly = (src) => /host:\s*['"]127\.0\.0\.1['"]/.test(src) && !/lib\/env-file/.test(src);

  const offenders = [];
  for (const file of listScripts(SCRIPTS)) {
    const src = readFileSync(file, 'utf8');
    if (!BUILDS_CONNECTION.test(src)) continue;
    if (/\bcloudHost\b/.test(src)) continue;
    if (isLocalOnly(src)) continue;
    offenders.push(relative(SCRIPTS, file));
  }

  assert.deepEqual(
    offenders,
    [],
    '这些脚本在 VPC 外跑，却没用 cloudHost() 取 host → 换内网地址后会静默连不上库：\n'
      + offenders.map((f) => `  · scripts/${f}`).join('\n')
      + '\n  改法：import { cloudHost } from \'./lib/env-file.mjs\'，然后 host: cloudHost(env)。',
  );
});

test('cloudHost()：配了 PGHOST_EXTERNAL 就用它（本机走外网端点）', () => {
  assert.equal(
    cloudHost({ PGHOST: 'internal.example', PGHOST_EXTERNAL: 'external.example' }),
    'external.example',
  );
});

test('cloudHost()：没配 PGHOST_EXTERNAL 时回落 PGHOST（本机开发栈 / 单端点）', () => {
  assert.equal(cloudHost({ PGHOST: 'internal.example' }), 'internal.example');
  assert.equal(
    cloudHost({ PGHOST_EXTERNAL: '', PGHOST: 'internal.example' }),
    'internal.example',
    'PGHOST_EXTERNAL 留空**不该**盖掉 PGHOST —— `.env.prod` 里显式留空很常见',
  );
});

test('cloudHost()：两个都没配时才回落到 127.0.0.1', () => {
  assert.equal(cloudHost({}), '127.0.0.1');
  assert.equal(cloudHost({ PGHOST: '', PGHOST_EXTERNAL: '' }), '127.0.0.1');
});
