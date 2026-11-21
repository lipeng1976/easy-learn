/**
 * 函数计算（FC3）入口 —— CommonJS。与本地 src/server.js 共用 src/app.js。
 * 网关不持有附件存储，因此不需要 ensureStorageRoot。
 *
 * ⚠️ 未在函数计算真机验证过（见 docs/handover.md「未验证项」）。
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
      return createApp({ config: getConfig('ai') });
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
