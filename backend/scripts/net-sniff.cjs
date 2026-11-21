/**
 * 出站请求嗅探器（诊断用，不参与部署）。
 *
 * 起因：`s deploy` 只回一句 `Request failed with status code 400`，
 * **不打印响应体**，`--debug` 也不打；`~/.s/logs/*` 里的 error.json 同样只有
 * 那一句话。于是「400 到底是谁回的、说什么」成了盲区。
 *
 * 做法：在进程启动时（`NODE_OPTIONS=--require 本文件`）把 `http/https.request`
 * 换掉，在**响应结束时**把状态码 ≥400 的 URL 与响应体打到 stderr。
 * 必须在 s 的代码之前加载，否则 axios / follow-redirects 可能已经解构走了原函数。
 *
 * 只打印，不改写任何请求或响应 —— 对部署过程零影响。
 */
'use strict';

const http = require('http');
const https = require('https');

function describe(args, proto) {
  try {
    const a = args[0];
    if (typeof a === 'string') return a;
    if (a && typeof a === 'object') {
      const host = a.host || a.hostname || '';
      return `${proto}//${host}${a.path || ''}`;
    }
  } catch (_) { /* 描述失败不影响主流程 */ }
  return '(url 未知)';
}

function wrap(orig, proto) {
  return function wrapped(...args) {
    const req = orig.apply(this, args);
    const url = describe(args, proto);
    req.on('response', (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        if (res.statusCode < 400) return;
        let body;
        try { body = Buffer.concat(chunks).toString('utf8').slice(0, 3000); } catch (_) { body = '(读不出)'; }
        process.stderr.write(`\n[SNIFF ${res.statusCode}] ${url}\n  BODY: ${body}\n`);
      });
    });
    req.on('error', (err) => {
      process.stderr.write(`\n[SNIFF ERR] ${url}\n  ${err.message}\n`);
    });
    return req;
  };
}

http.request = wrap(http.request.bind(http), 'http:');
https.request = wrap(https.request.bind(https), 'https:');
process.stderr.write('[sniff] 已挂上出站请求嗅探（只看 ≥400）\n');
