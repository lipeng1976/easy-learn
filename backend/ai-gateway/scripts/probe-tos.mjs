#!/usr/bin/env node

/**
 * TOS 直传签名的**真凭证验证**工具。
 *
 * ## 为什么需要它
 *
 * 火山引擎官方文档给出的两个签名示例互相矛盾（同一份示例里区域串一会儿是
 * `ap-southeast-1`、一会儿是 `tos-ap-southeast-1`，日期也从 `20220101`
 * 与 `20220322` 混用），拿不到可信的测试向量。
 *
 * 于是这里不写「看起来对」的单元断言 —— 那种断言只会让人误以为验过。
 * 签名对不对只有一件事能证明：**拿真凭证传一个文件上去**。
 * 所以把验证做成这条命令。
 *
 * 用法：
 *
 * ```bash
 * TOS_BUCKET=my-bucket TOS_REGION=cn-beijing \
 * TOS_ACCESS_KEY_ID=xxx TOS_ACCESS_KEY_SECRET=yyy \
 * node scripts/probe-tos.mjs put ./probe.txt
 * ```
 *
 * 退出码 0 = 201 或 200（签名正确）；非 0 = 失败，报告会指出是哪一步。
 */

import { readFileSync } from 'node:fs';

import { buildPresignedUrl, tosReady } from '../src/tos.js';

const SIGNER_TTL_SECONDS = 600;

function configFromEnv() {
  return {
    bucket: process.env.TOS_BUCKET ?? '',
    region: process.env.TOS_REGION ?? 'cn-beijing',
    endpoint: process.env.TOS_ENDPOINT ?? '',
    accessKeyId: process.env.TOS_ACCESS_KEY_ID ?? '',
    accessKeySecret: process.env.TOS_ACCESS_KEY_SECRET ?? '',
    objectUrlBase: process.env.TOS_OBJECT_URL_BASE ?? '',
  };
}

function presign(method, objectKey) {
  const config = configFromEnv();
  if (!tosReady(config)) {
    console.error('缺少 TOS 配置：需要 TOS_BUCKET / TOS_ACCESS_KEY_ID / TOS_ACCESS_KEY_SECRET。');
    process.exit(2);
  }
  return buildPresignedUrl({
    method,
    bucket: config.bucket,
    region: config.region,
    endpoint: config.endpoint || undefined,
    objectKey,
    accessKeyId: config.accessKeyId,
    accessKeySecret: config.accessKeySecret,
    expiresSeconds: SIGNER_TTL_SECONDS,
  });
}

async function main() {
  const [action, target] = process.argv.slice(2);
  const objectKey = `probe/${Date.now()}-probe.txt`;

  if (action === 'url') {
    // 只打印 URL，用来肉眼核对或交给 curl。
    console.log(presign('PUT', objectKey).url);
    return;
  }

  if (action !== 'put') {
    console.error('用法：node scripts/probe-tos.mjs url | put <本地文件>');
    process.exit(2);
  }

  const body = readFileSync(target);
  const signed = presign('PUT', objectKey);
  console.log(`PUT ${signed.host}${signed.url.split(signed.host)[1]}`);

  const response = await fetch(signed.url, { method: 'PUT', body });
  if (response.status !== 200 && response.status !== 201) {
    console.error(`\n签名验证失败：HTTP ${response.status}`);
    console.error(await response.text().catch(() => '(无法读取响应体)'));
    // 403 SignatureDoesNotMatch 是唯一需要真凭证才能发现的那类错误：
    // 它在本地无论怎么测都测不出来。
    if (response.status === 403) {
      console.error(
        '\n403 说明签名串对不上。按这个顺序查：\n'
          + '  1. TOS_REGION 是不是 TOS 的 region（不要带 tos- 前缀）\n'
          + '  2. 系统时间是否准确（X-Tos-Date 偏差超过 15 分钟会被拒）\n'
          + '  3. CanonicalRequest 的分隔符与字段顺序（最常见错处）',
      );
    }
    process.exit(1);
  }

  console.log(`\n签名正确：上传成功（HTTP ${response.status}）。`);

  // 再验一下 GET：模型读图走的就是这条路。
  const readable = presign('GET', objectKey);
  const readBack = await fetch(readable.url);
  if (!readBack.ok) {
    console.error(`读回失败：HTTP ${readBack.status}（模型将无法读取这张图）`);
    process.exit(1);
  }
  console.log('读回成功：模型侧可以通过该 URL 取到图片。');
}

await main();
