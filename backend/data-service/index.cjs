/**
 * 函数计算（FC3）入口 —— CommonJS，云平台的 handler 约定。
 * 与本地 src/server.js **共用同一份 src/app.js**，避免两套行为分叉。
 *
 * 做法：把 FC3 event 转成一个 IncomingMessage-like 的可读流 + 一个收集响应的
 * res 对象，直接复用 createApp 的 (req, res) 处理器。不引入任何框架依赖。
 *
 * ⚠️ 未在函数计算真机验证过（见 docs/handover.md「未验证项」）。
 *    本地可用 `node -e "require('./index.cjs').handler({...})"` 做形状自检。
 */

'use strict';

const { Readable } = require('node:stream');

let handlerPromise = null;

async function getHandler() {
  if (!handlerPromise) {
    handlerPromise = (async () => {
      const [{ createApp }, { getConfig }] = await Promise.all([
        import('./src/app.js'),
        import('../shared/config.js'),
      ]);
      // 云上入口同样要确保存储根目录存在（本地盘挂载时）。
      const { ensureStorageRoot } = await import('../shared/paths.js');
      ensureStorageRoot();
      return createApp({ config: getConfig('data') });
    })();
  }
  return handlerPromise;
}

function toRequest(event) {
  const headers = {};
  for (const [key, value] of Object.entries(event.headers ?? {})) {
    headers[key.toLowerCase()] = Array.isArray(value) ? value.join(',') : String(value);
  }

  let body = Buffer.alloc(0);
  if (event.body !== undefined && event.body !== null) {
    body = event.isBase64Encoded
      ? Buffer.from(event.body, 'base64')
      : Buffer.from(String(event.body), 'utf8');
  }

  const req = Readable.from([body]);
  req.method = String(event.httpMethod ?? event.method ?? 'GET').toUpperCase();

  const query = event.queryStringParameters ?? event.query ?? {};
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(query)) {
    if (value !== undefined && value !== null) search.append(key, String(value));
  }
  const suffix = search.toString();
  const pathname = event.path ?? event.rawPath ?? '/';
  req.url = pathname + (suffix ? `?${suffix}` : '');
  req.headers = headers;
  return req;
}

function createResponse() {
  return {
    statusCode: 200,
    headers: {},
    chunks: [],
    writeHead(status, headers) {
      this.statusCode = status;
      this.headers = { ...this.headers, ...(headers ?? {}) };
      return this;
    },
    write(chunk) {
      if (chunk !== undefined && chunk !== null) {
        this.chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
      }
      return true;
    },
    end(chunk) {
      if (chunk !== undefined && chunk !== null) this.write(chunk);
      return this;
    },
  };
}

exports.initialize = async function initialize() {
  await getHandler();
};

exports.handler = async function handler(event) {
  try {
    const handle = await getHandler();
    const req = toRequest(event ?? {});
    const res = createResponse();
    await handle(req, res);
    const body = Buffer.concat(res.chunks);
    return {
      statusCode: res.statusCode,
      headers: res.headers,
      isBase64Encoded: true,
      body: body.toString('base64'),
    };
  } catch (err) {
    console.error('[fc3] handler failed', err);
    return {
      statusCode: 500,
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
      isBase64Encoded: false,
      body: JSON.stringify({
        error: { code: 'internal', message: '服务内部错误', retryable: false },
      }),
    };
  }
};
