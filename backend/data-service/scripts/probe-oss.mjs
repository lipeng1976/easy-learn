#!/usr/bin/env node

/**
 * OSS 接入探活：**用真凭证打一次真实请求**。
 *
 * ## 为什么非要有这一步
 *
 * `test/oss-imagestore.test.js` 已经把签名算法对齐到了官方文档给出的算例
 * （规范请求逐字节、以及「用文档的 SigningKey 能签出文档的 Signature」），
 * 理论上已经对了。但那是**纸上的一致**：
 *
 * - 文档那份算例的 AccessKeySecret 是脱敏的，所以 SigningKey 那一步
 *   只能靠「照抄官方 SDK + 用 Python 独立复算」来支持，**没法用真凭证证伪**；
 * - 签名之外的环节（桶的 ACL、RAM 权限、区域、内网/外网域名、时钟偏差）
 *   在本地一个都验不到。
 *
 * 而它们失败时给的是同一个东西：`SignatureDoesNotMatch` / `AccessDenied`
 * —— 看起来都像「AccessKey 填错了」，排查方向会先跑到控制台去重新生成密钥。
 *
 * 所以这个脚本只做一件事：**把「配好了」从推断变成事实**。
 *
 * ## 跑法
 *
 * ```bash
 * cd serverless/data-service
 * node --env-file=.env.oss scripts/probe-oss.mjs
 * ```
 *
 * `.env.oss` 里放（**不要入库**，确认被 gitignore）：
 *
 * ```
 * IMAGE_DRIVER=oss
 * OSS_BUCKET=...
 * OSS_REGION=cn-hangzhou
 * OSS_ENDPOINT=oss-cn-hangzhou.aliyuncs.com   # 可选；**本机跑要用外网域名**
 *   ⚠️ 内网域名（`oss-cn-<region>-internal.aliyuncs.com`）只能从**同区域的机器**访问：
 *      线上函数填它省流量费，但**本机跑这个脚本会超时**。两者不妨各填各的 ——
 *      本脚本存在的意义就是「从本机用真凭证验一次」，套用线上那份内网配置反而验不了。
 *   💡 填控制台「访问域名」那一栏的**原文**（带 https://）也行，代码会剥掉并说明。
 * OSS_ACCESS_KEY_ID=...
 * OSS_ACCESS_KEY_SECRET=...
 * OSS_PREFIX=dev                                        # 可选；避免和线上混在一个桶里
 * ```
 *
 * ## 它花多少钱
 *
 * 三次请求（探测 + 一次 PUT + 一次 GET）加一个几十字节的对象。
 * 计费精确到厘以下；**但那个对象会留在桶里**，脚本会把键打出来，
 * 想清理就照它删 —— 刻意不自动删：这里是照片桶，
 * 「脚本自己会删东西」不是个值得引入的属性。
 */

import { createOssImageStore } from '../src/ossimagestore.js';

/** 1×1 的透明 PNG —— 最小的合法图片，用来走完整条校验。 */
const TINY_PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  'base64',
);

const env = process.env;
const mask = (v) => (v ? `${String(v).slice(0, 8)}…（共 ${String(v).length} 字符）` : '(空)');

console.log('=== OSS 接入探活 ===');
console.log('');
console.log('  IMAGE_DRIVER          ', env.IMAGE_DRIVER || '(空 → 会当成 fs)');
console.log('  OSS_BUCKET            ', env.OSS_BUCKET || '(空)');
console.log('  OSS_REGION            ', env.OSS_REGION || '(空)');
console.log('  OSS_ENDPOINT          ', env.OSS_ENDPOINT || '(空 → 按区域推外网域名)');
console.log('  OSS_PREFIX            ', env.OSS_PREFIX || '(空)');
console.log('  OSS_ACCESS_KEY_ID     ', mask(env.OSS_ACCESS_KEY_ID));
console.log('  OSS_ACCESS_KEY_SECRET ', mask(env.OSS_ACCESS_KEY_SECRET));
console.log('');

const store = createOssImageStore({
  bucket: env.OSS_BUCKET,
  region: env.OSS_REGION,
  endpoint: env.OSS_ENDPOINT,
  accessKeyId: env.OSS_ACCESS_KEY_ID,
  accessKeySecret: env.OSS_ACCESS_KEY_SECRET,
  prefix: env.OSS_PREFIX ?? '',
});

if (!store.ready) {
  console.error('✗ 配置不全，无法探活。缺的变量会在下面这条信息里点名：');
  const r = await store.assertReady();
  console.error(`  ${r.reason}`);
  process.exit(1);
}

if (String(env.IMAGE_DRIVER ?? '').trim() !== 'oss') {
  console.warn('⚠️  IMAGE_DRIVER 不是 oss —— 本脚本自己会构造 OSS 后端，所以能跑；');
  console.warn('    但**服务本身**不会用它，上线前记得把这一项设上。');
  console.warn('');
}

// ── ① 启动自检：桶在不在、凭证对不对、签名写对没有 ──
// 探测方式是「GET 一个必然不存在的键，期望 404 NoSuchKey」——
// 拿到 NoSuchKey 就说明签名被接受了，而 SignatureDoesNotMatch 会当场现形。
const ready = await store.assertReady();
if (!ready.ok) {
  console.error('✗ 自检未通过：');
  console.error(`  ${ready.reason}`);
  console.error('');
  console.error('  对照一下：');
  console.error('    · 签名不匹配 → 先看 OSS_ACCESS_KEY_SECRET 有没有录错/带空格');
  console.error('    · 桶不存在   → OSS_BUCKET 拼写，以及 OSS_REGION 和桶所在区域是否一致');
  console.error('    · 权限不足   → 这个 AccessKey 有没有被授权访问该桶');
  console.error('    · 超时       → OSS_ENDPOINT 是否可达（内网域名只能从同区域的机器上访问）');
  process.exit(1);
}

console.log(`✓ 自检通过：${ready.root}`);
if (ready.note) console.log(`  （${ready.note}）`);
console.log('');

// ── ② 真写一次、真读一次，并**逐字节比对** ──
let savedKey = '';
try {
  const saved = await store.put({
    studentId: 'probe-student',
    bytes: TINY_PNG,
    mimeType: 'image/png',
  });
  savedKey = saved.storageKey;
  console.log(`✓ 上传成功：${saved.storageKey}（${saved.byteSize} 字节）`);

  const got = await store.get(savedKey);
  // 比「长度」更严：完整比一遍字节。整条链路上任何一处把 Buffer 当字符串
  // 都会静默损坏图片 —— 不报错，只得到一张打不开的图。
  if (!got.equals(TINY_PNG)) {
    console.error('✗ 读回来的字节与写进去的不一致 —— 链路上有地方损坏了内容');
    process.exit(1);
  }
  console.log(`✓ 读回成功，且字节逐字节相同（${got.length} 字节）`);
} catch (e) {
  console.error('✗ 上传/读回失败：');
  console.error(`  ${e.message}`);
  if (e.details?.reason) console.error(`  reason=${e.details.reason} ossCode=${e.details.ossCode ?? ''}`);
  process.exit(1);
}

console.log('');
console.log('=== 结论 ===');
console.log('照片的云存储链路是通的：鉴权、签名、写、读、以及字节完整性都验过了。');
console.log('');
console.log(`留下的探针对象（可手动删除）：${env.OSS_PREFIX ? `${env.OSS_PREFIX}/` : ''}${savedKey}`);
console.log('刻意不自动删 —— 这是照片桶，「脚本自己会删东西」不值得引入。');
