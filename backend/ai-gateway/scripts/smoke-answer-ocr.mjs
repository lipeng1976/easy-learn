/**
 * 端到端冒烟：把「拍照作答」这条端点真发一次。
 *
 * 与单测的区别：单测直接调 `gateway.handle`，这里走 `toRequest(Buffer)`
 * —— 也就是阿里云 FC3 真正喂进来的那个形状。
 * （FC3 把事件序列化成 Buffer 传进来，本地单测喂对象是发现不了的：
 *  顶层的 `path` / `queryParameters` 全部落空，症状看起来像「路由表坏了」。）
 *
 * 用法：
 *   node scripts/smoke-answer-ocr.mjs [图片路径]
 */
import { readFile } from 'node:fs/promises';

import { loadConfig } from '../src/config.js';
import { createGateway, toRequest } from '../src/handler.js';

const imagePath = process.argv[2]
  ?? 'C:/Users/lp_pr/AppData/Local/Temp/hw_test/answer_handwriting.png';

const bytes = await readFile(imagePath);
const config = loadConfig({ AI_MODEL_CLIENT: 'mock' });
const gateway = createGateway({ config });

const eventBody = (images) => JSON.stringify({
  questionContent: '9 × 3 = ?',
  knowledgePoint: '乘法口诀',
  images,
});

const event = {
  httpMethod: 'POST',
  path: '/ai/review/answer-ocr',
  headers: { 'x-student-id': 'stu_smoke', 'content-type': 'application/json' },
  queryParameters: {},
  isBase64Encoded: false,
  body: eventBody([{ mimeType: 'image/png', base64: bytes.toString('base64') }]),
};

// ⚠️ 喂 Buffer —— 模拟 FC3 的真实形状。
const response = await gateway.handle(toRequest(Buffer.from(JSON.stringify(event), 'utf8')));
const body = JSON.parse(response.body);
console.log('[正面] status =', response.status, ' ok =', body.ok);
console.log('       data  =', JSON.stringify(body.data));
console.log('       meta  = model:', body.meta?.model, ' units:', body.meta?.units);

// 反面一：没有照片必须 400，且**一次模型调用都不该发生**。
const noImages = await gateway.handle(toRequest(Buffer.from(JSON.stringify({
  ...event,
  body: eventBody([]),
}), 'utf8')));
const noImagesBody = JSON.parse(noImages.body);
console.log('\n[反面·无照片] status =', noImages.status, ' code =', noImagesBody.error?.code);

// 反面二：给一个不存在的路径，必须是 404 而不是 200 ——
// 这条是用来证明「上面那个 200 不是因为路由把所有请求都接住了」。
const wrongPath = await gateway.handle(toRequest(Buffer.from(JSON.stringify({
  ...event,
  path: '/ai/review/answer-ocr-typo',
}), 'utf8')));
const wrongPathBody = JSON.parse(wrongPath.body);
console.log('[反面·错路径] status =', wrongPath.status, ' code =', wrongPathBody.error?.code);
