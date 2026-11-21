/**
 * CommonJS 入口垫片（与 `serverless/ai-gateway/index.cjs` 同一个理由）。
 *
 * 有些 Serverless 平台（部分版本的 veFaaS / SCF）只认 CommonJS 的
 * `exports.handler`，而本服务的源码是 ESM。与其让部署的人临时改代码或加构建
 * 步骤，这里备一个五行垫片：平台入口指向本文件即可。
 *
 * ⚠️ **入口指错不会报「找不到入口」那种好查的错。** 平台多半会回一个
 * 502/500 或不带响应体的错误，而 curl 打上去看起来像「服务没起来」——
 * 于是排查方向会落到连接串、白名单、端口上。**部署清单里这一条要逐字核对。**
 *
 * ESM 的实现在 `src/handler.js`，那里才是真正要读的代码。
 */
exports.handler = async function handler(event, context) {
  const module = await import('./src/handler.js');
  return module.handler(event, context);
};
