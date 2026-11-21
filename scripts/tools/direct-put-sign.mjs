/**
 * 直传探针 **第 1 步**：用真凭证签一个可用的直传位置，导出成 JSON。
 *
 * ## 为什么要把「签」与「PUT」拆成两个进程
 *
 * 服务端的签名算法已经有 node 侧的端到端验证（`oss_direct_put_probe.mjs`：
 * PUT 200 / 读回逐字节相同 / DELETE 204）。**没有验证过的是客户端**：
 * Dart 的 `package:http` 会不会把服务端给的那几个头**原样**发出去 ——
 * 尤其是 `host`。V4 把 host 纳入签名，而 Dart 的 IO 层对 Host 有自己的
 * 处理；一旦它被改写或丢掉，回的是 `SignatureDoesNotMatch`，那个错误
 * 看起来像「AccessKey 配错了」，能把人带偏到控制台去查半天。
 *
 * 所以：本脚本只负责签（与生产用同一条 `signDirectPut`），
 * 把结果交给 Dart 去发。两边用同一份签名，才谈得上「验的是客户端」。
 *
 * ⚠️ 不打印任何长期密钥。导出的 JSON 里只有**一次性的** V4 签名头
 * （15 分钟窗口内有效），且只写到工作区、不进仓库。
 */
import fs from 'node:fs';
import path from 'node:path';

const PROJECT = 'D:/workbuddy-project/projects/easy_learn_db';
const OUT = 'C:/Users/lp_pr/WorkBuddy/2026-09-14-16-29-22/_signed_put.json';

const { createOssImageStore } = await import(
  `file:///${PROJECT}/serverless/data-service/src/ossimagestore.js`
);

const envText = fs.readFileSync(path.join(PROJECT, '.env.prod'), 'utf8');
const pick = (k) => {
  const m = envText.match(new RegExp('^' + k + '=(.*)$', 'm'));
  return m ? m[1].trim() : '';
};

const cfg = {
  bucket: pick('OSS_BUCKET'),
  region: pick('OSS_REGION'),
  endpoint: pick('OSS_ENDPOINT'),
  accessKeyId: pick('OSS_ACCESS_KEY_ID'),
  accessKeySecret: pick('OSS_ACCESS_KEY_SECRET'),
};
for (const [k, v] of Object.entries(cfg)) {
  if (v === '') throw new Error(`.env.prod 里缺 ${k}`);
}

const store = createOssImageStore(cfg);
if (!store.ready) throw new Error('存储未就绪（配置不全）');

const signed = store.signDirectPut({
  studentId: '__dart_put_probe__',
  mimeType: 'video/mp4',
  maxBytes: 50 * 1024 * 1024,
});
if (signed === null) throw new Error('signDirectPut 返回 null');

fs.writeFileSync(
  OUT,
  JSON.stringify(
    {
      uploadUrl: signed.uploadUrl,
      headers: signed.headers,
      storageKey: signed.storageKey,
      origin: new URL(signed.uploadUrl).origin,
      // key 只能从 **URL 路径**取 —— 桶名同时出现在子域上，用
      // `indexOf(bucket)` 切出来的 key 会带上主机名一截。
      // 那个错误不报错（OSS 对不存在的键 DELETE 也回 204），
      // 详见 `direct-put-verify.mjs` 的说明。
      key: decodeURIComponent(
        new URL(signed.uploadUrl).pathname.replace(/^\/+/, ''),
      ),
    },
    null,
    2,
  ),
  'utf8',
);

console.log('签名已导出 →', OUT);
console.log('storageKey :', signed.storageKey);
console.log('uploadUrl  :', signed.uploadUrl);
console.log('header 名单:', Object.keys(signed.headers).join(', '));
