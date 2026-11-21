import http from 'node:http';

import { createGateway } from './handler.js';

/**
 * 本地开发服务器。
 *
 * 存在的意义是让「客户端 ↔ 网关」这条链路可以脱离云平台先跑通：
 * 把 Flutter 客户端的 `AI_BASE_URL` 指到 `http://127.0.0.1:8787`，
 * 就能在真机上验证内联图片、降级、缓存这些行为，而不必先申请好方舟的模型。
 *
 * ```bash
 * AI_MODEL_CLIENT=mock AI_UPLOAD_URL_BASE=http://127.0.0.1:8787 \
 * AI_UPLOAD_SIGNING_SECRET=dev-secret npm run dev
 * ```
 *
 * 注意：`AI_MODEL_CLIENT=mock` 只用于本地。它返回的 `meta.model` 是 `mock`，
 * 一眼能看出来 —— 不要把这个环境变量带上生产。
 */
const port = Number.parseInt(process.env.PORT ?? '8787', 10);
/**
 * 监听地址。默认**只绑回环**，要手机连才显式打开（`BIND_HOST=0.0.0.0`）。
 *
 * 这里比数据服务更需要收紧：网关持有方舟的 API Key，放出去等于把
 * 「谁都能花你的模型额度」这件事挂到局域网上。网关自己有 `AI_REQUIRE_AUTH`
 * 这道闸，但它是**另一层**——两层都要在，不能拿一层顶替另一层。
 */
const bindHost = process.env.BIND_HOST ?? '127.0.0.1';
const gateway = createGateway();

// 注意：**CORS 不在这里**。它在 `router.js` 里统一处理（含 OPTIONS 预检），
// 理由有两个：预检要在进业务逻辑之前就答完，而路由层同时被云函数入口复用 ——
// 各写一份的结果是两边略有不同、且只有一边被改。开发服务器只做 HTTP 搬运。
//
// （曾经在这里加过一份按来源放行的 CORS，结果同一条响应里出现两个
//  `Access-Control-Allow-Origin`（一个 `*`、一个回显的 origin）。浏览器对
//  重复的 ACAO 一律判 CORS 失败 —— 修一个不存在的问题，反而制造了一个真故障。）

const server = http.createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const rawBody = Buffer.concat(chunks);
  const url = new URL(req.url ?? '/', `http://127.0.0.1:${port}`);

  const method = (req.method ?? 'GET').toUpperCase();
  const headers = {};
  for (const [key, value] of Object.entries(req.headers)) {
    headers[key.toLowerCase()] = Array.isArray(value) ? value.join(',') : value;
  }

  let body = null;
  let bodyInvalid = false;
  if (method !== 'PUT' && method !== 'GET') {
    const text = rawBody.toString('utf8').trim();
    if (text !== '') {
      try {
        body = JSON.parse(text);
      } catch {
        bodyInvalid = true;
      }
    }
  }

  const result = await gateway.handle({
    method,
    path: url.pathname,
    query: Object.fromEntries(url.searchParams),
    headers,
    body,
    bodyInvalid,
    rawBody,
  });

  res.writeHead(result.status, result.headers);
  res.end(result.body);
});

server.listen(port, bindHost, () => {
  const config = gateway.config;
  const shown = bindHost === '0.0.0.0' ? '0.0.0.0（本机所有网卡，局域网可达）' : bindHost;
  console.log(`AI 网关开发服务器：http://${shown}:${port}`);
  if (bindHost === '0.0.0.0') {
    console.log('  ⚠️  已绑到所有网卡：同局域网的其他设备也能调这个网关（它会花你的模型额度）。');
    console.log('     只在需要手机/真机联调时这样起，用完退回默认（只绑回环）。');
  }
  console.log(`  模型客户端：${config.modelClient}`);
  console.log(`  区域：${config.ark.region}`);
  console.log(`  能力开关：${JSON.stringify(gateway.model.capabilities())}`);
  if (config.modelClient === 'mock') {
    console.log('  ⚠️  当前用 mock 模型，返回的是确定性假数据，仅供联调。');
  }
});
