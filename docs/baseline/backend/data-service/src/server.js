/**
 * 本地开发入口。云函数入口是同级的 index.cjs，两者共用 src/app.js。
 */

import http from 'node:http';
import { getConfig } from '../../shared/config.js';
import { ensureStorageRoot } from '../../shared/paths.js';
import { closePool } from '../../shared/db.js';
import { createApp } from './app.js';

const config = getConfig('data');
ensureStorageRoot();

const server = http.createServer(createApp({ config }));

server.listen(config.dataServicePort, () => {
  console.log(`[data-service] http://127.0.0.1:${config.dataServicePort}`);
  console.log(`[data-service] NODE_ENV=${config.nodeEnv} auth=${config.requireAuth ? 'required' : 'dev-bypass'}`);
  console.log(`[data-service] storage driver=${config.imageDriver}（根目录已在 STORAGE_ROOT 配置）`);
});

async function shutdown(signal) {
  console.log(`[data-service] ${signal} → 关闭中`);
  server.close(async () => {
    await closePool();
    process.exit(0);
  });
}

process.on('SIGINT', () => void shutdown('SIGINT'));
process.on('SIGTERM', () => void shutdown('SIGTERM'));
