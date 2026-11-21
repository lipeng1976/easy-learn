/**
 * 本地开发入口。云函数入口是同级的 index.cjs，两者共用 src/app.js。
 * 用 getConfig('ai')：网关不需要 DATABASE_URL / STORAGE_ROOT，
 * 但仍需要 AI_SESSION_SECRET（与数据服务同一把）来验票。
 */

import http from 'node:http';
import { getConfig } from '../../shared/config.js';
import { createApp } from './app.js';

const config = getConfig('ai');
const server = http.createServer(createApp({ config }));

server.listen(config.aiGatewayPort, () => {
  console.log(`[ai-gateway] http://127.0.0.1:${config.aiGatewayPort}`);
  console.log(`[ai-gateway] NODE_ENV=${config.nodeEnv} auth=${config.requireAuth ? 'required' : 'dev-bypass'}`);
  console.log(`[ai-gateway] provider=${config.aiModelProvider}`);
});

function shutdown(signal) {
  console.log(`[ai-gateway] ${signal} → 关闭中`);
  server.close(() => process.exit(0));
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
