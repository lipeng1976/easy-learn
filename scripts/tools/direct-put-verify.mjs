/**
 * 直传探针 **第 3 步**：读回 Dart 刚 PUT 上去的对象，然后删掉它。
 *
 * 读回走的是**服务端**那条已验证的路径（`store.get`）—— 它与 PUT 是两条
 * 独立的签名，所以「读得回来」这件事本身也是一条判据：它证明那个对象
 * 真的落进了桶里，而不是被 OSS 静默丢弃后回了一个 200。
 *
 * 清理是必须的：探针写过的东西不能留在生产桶里（哪怕只有 100 字节）。
 */
import fs from 'node:fs';
import path from 'node:path';

const PROJECT = 'D:/workbuddy-project/projects/easy_learn_db';
const SIGNED = 'C:/Users/lp_pr/WorkBuddy/2026-09-14-16-29-22/_signed_put.json';

const { createOssImageStore, signRequest, iso8601Utc } = await import(
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

const signed = JSON.parse(fs.readFileSync(SIGNED, 'utf8'));
const store = createOssImageStore(cfg);

// ⚠️ key 必须从 **URL 的路径**取，不能用「桶名在字符串里的位置」推。
//
// 桶名同时出现在**子域**上（`https://<bucket>.<host>/<key>`），所以
// `indexOf(bucket)` 命中的是子域那一处，切出来的 key 会带上
// `oss-cn-hangzhou.aliyuncs.com/` 一截。
//
// 而 OSS 对**不存在的键**做 DELETE 回的是 **204**（幂等删除）——
// 于是这个错误**不会报错**：脚本照样打印「已清理」，对象还躺在桶里。
// 一个判据、且它对这种错误不敏感 = 假成功。2026-10-03 实测撞上。
const key = decodeURIComponent(
  new URL(signed.uploadUrl).pathname.replace(/^\/+/, ''),
);
console.log('实际键 :', key);

// ② 读回 —— 对象真的在桶里吗
let got = null;
try {
  got = await store.get(signed.storageKey);
} catch (e) {
  console.log('② 读回失败：', e.message);
}
if (got === null) {
  console.log('❌ 读不回来 —— PUT 虽然回了 200，对象却不在。直传这条路**不能用**。');
  process.exit(1);
}
const text = got.toString('utf8');
console.log(`② 读回 → ${got.length} 字节`);
console.log(`   内容片段：${text.slice(0, 80)}`);
console.log(`   是 Dart 写的那份：${text.startsWith('easylearn dart direct-put probe')}`);

// ③ DELETE 清理
const delSigned = signRequest({
  method: 'DELETE',
  bucket: cfg.bucket,
  key,
  headers: {},
  region: cfg.region,
  accessKeyId: cfg.accessKeyId,
  accessKeySecret: cfg.accessKeySecret,
  timestamp: iso8601Utc(Date.now()),
});
const delRes = await fetch(`${signed.origin}/${key}`, {
  method: 'DELETE',
  headers: delSigned.headers,
});
console.log(`③ DELETE → HTTP ${delRes.status}`);

// ⚠️ 204 **不足以**说明删掉了 —— 对不存在的键 OSS 也回 204。
// 所以「已清理」这句话只能由「删完之后真的读不回来」来支撑。
// 只报状态码的话，删错键的实现会一路绿着把垃圾留在生产桶里。
let removed = false;
try {
  await store.get(signed.storageKey);
  removed = false;
} catch {
  removed = true;
}
console.log(`   删后读回：${removed ? '已不存在（确认清理）' : '**仍然在**（清理没生效）'}`);

const ok = removed && text.startsWith('easylearn dart direct-put probe');
console.log('');
console.log(
  ok
    ? '✅ Dart 客户端直传验证通过：签名被接受、对象在桶里、字节正确、已清理'
    : '⚠️ 见上',
);
process.exit(ok ? 0 : 1);
