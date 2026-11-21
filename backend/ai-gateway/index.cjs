/**
 * CommonJS 入口垫片。
 *
 * 方舟的 API Key 只存在于本服务的环境变量里 —— 这是整个架构的前提。
 * 有些 Serverless 平台（部分版本的 veFaaS / SCF）只认 CommonJS 的
 * `exports.handler`，而本服务的源码是 ESM。
 * 与其让部署的人临时去改代码或加构建步骤，这里直接备一个五行垫片：
 * 平台入口指向本文件即可。
 *
 * ESM 的实现在 src/handler.js，那里才是真正要读的代码。
 */
exports.handler = async function handler(event, context) {
  const module = await import('./src/handler.js');
  return module.handler(event, context);
};
