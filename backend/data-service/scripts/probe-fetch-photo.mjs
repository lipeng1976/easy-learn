#!/usr/bin/env node
/**
 * 【临时只读探针】按 storage key 把一张作业照片取到本地 —— 给「批改矩阵」备料。
 *
 * 用法：node scripts/probe-fetch-photo.mjs <storageKey> <outPath>
 *
 * 复用生产自己的 `createImageStoreFor(env)`（V4 签名那套），所以取到的东西
 * 与客户端上传、家长端查看走的是**同一条路径**。只读。
 */
import { writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { createImageStoreFor } from '../src/image-store-factory.js';
import { loadEnv } from './lib/env-file.mjs';

const ROOT = resolve(import.meta.dirname, '../../..');
const { env } = loadEnv(resolve(ROOT, process.env.ENV_FILE || '.env.prod'));

const [key, out] = process.argv.slice(2);
if (!key || !out) {
  console.error('用法：node scripts/probe-fetch-photo.mjs <storageKey> <outPath>');
  process.exit(2);
}

const store = createImageStoreFor(env);
console.log(`驱动 root=${store.root}  ready=${store.ready}`);
const ready = await store.assertReady();
console.log('自检：', JSON.stringify(ready));

const bytes = await store.get(key);
console.log(`取到 ${bytes.length} 字节`);
writeFileSync(out, bytes);
console.log(`已写入 ${out}`);
