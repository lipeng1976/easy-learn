import { after, test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { buildRoutes, createApp } from '../src/app.js';
import { createUpdateRoutes } from '../src/routes/app_update.js';

/**
 * 本机版 App 更新的服务端判据。
 *
 * 这个端点**刻意不碰数据库**（登录前也要能检查更新），所以测试用假连接池即可：
 * 真跑的是「读 manifest → 回契约 → 回字节」这条链，而不是在测 PG。
 */

const dirs = [];
after(() => dirs.forEach((d) => rmSync(d, { recursive: true, force: true })));

function tempDir() {
  const d = mkdtempSync(join(tmpdir(), 'easylearn-update-'));
  dirs.push(d);
  return d;
}

function seed(dir, { apkBytes = Buffer.from('APK-BYTES-FOR-TEST'), override = {} } = {}) {
  const fileName = 'easy-learn-local-test.apk';
  writeFileSync(join(dir, fileName), apkBytes);
  const manifest = {
    versionCode: 20261123,
    versionName: '1.0.1 (20261123)',
    changelog: '修复更新检测',
    fileName,
    size: apkBytes.length,
    sha256: createHash('sha256').update(apkBytes).digest('hex'),
    publishedAt: '2026-11-23T09:15:00+08:00',
    // 故意多塞一个内部字段：客户端契约不该把它原样回出去。
    internalBuildPath: 'D:/secret/path',
    ...override,
  };
  writeFileSync(join(dir, 'manifest.json'), JSON.stringify(manifest));
  return { apkBytes, fileName };
}

test('未配置目录 / 目录为空 → available:false，不抛错（静默降级）', async () => {
  for (const dir of ['', tempDir()]) {
    const routes = createUpdateRoutes({ updatePackageDir: dir });
    assert.deepEqual(await routes.checkUpdate(), { available: false, latest: null });
  }
});

test('清单回契约字段，且不泄露内部字段与绝对路径', async () => {
  const dir = tempDir();
  const { apkBytes } = seed(dir);
  const routes = createUpdateRoutes({ updatePackageDir: dir });
  const result = await routes.checkUpdate();

  assert.equal(result.available, true);
  assert.equal(result.latest.versionCode, 20261123);
  assert.equal(result.latest.versionName, '1.0.1 (20261123)');
  assert.equal(result.latest.sha256.length, 64);
  assert.deepEqual(Object.keys(result.latest).sort(), [
    'changelog', 'fileName', 'publishedAt', 'sha256', 'size', 'versionCode', 'versionName',
  ]);
  assert.ok(!JSON.stringify(result).includes('internalBuildPath'));
  assert.ok(!JSON.stringify(result).includes(dir));
  assert.equal(result.latest.size, apkBytes.length);
});

test('清单不完整（sha256 非法 / versionCode=0）→ available:false，不让客户端反复弹', async () => {
  const dir = tempDir();
  const routes = createUpdateRoutes({ updatePackageDir: dir });
  for (const override of [{ sha256: 'abc' }, { versionCode: 0 }, { fileName: '' }]) {
    seed(dir, { override });
    assert.deepEqual(await routes.checkUpdate(), { available: false, latest: null });
  }
});

test('下载回原始字节 + APK content-type + content-length', async () => {
  const dir = tempDir();
  const { apkBytes } = seed(dir);
  const routes = createUpdateRoutes({ updatePackageDir: dir });

  const res = await routes.downloadApk();
  assert.equal(res.status, 200);
  assert.equal(res.headers['content-type'], 'application/vnd.android.package-archive');
  assert.equal(res.headers['content-length'], String(apkBytes.length));
  assert.deepEqual(res.body, apkBytes);
});

test('路径穿越被挡：fileName 带 ../ 时 404，不读文件', async () => {
  const dir = tempDir();
  seed(dir, { override: { fileName: '../outside.apk' } });
  const routes = createUpdateRoutes({ updatePackageDir: dir });
  await assert.rejects(() => routes.downloadApk(), (e) => e.code === 'not_found' && e.status === 404);
});

test('通过 createApp 走公开路由：清单包信封、下载是 raw 字节（不是信封）', async () => {
  const dir = tempDir();
  const { apkBytes } = seed(dir);
  // 公开分支会借一次鉴权连接开事务，但这个端点不查库 —— 假连接足够。
  const fakeAuthPool = {
    connect: async () => ({ query: async () => ({ rows: [] }), release() {} }),
  };
  const app = createApp({
    pool: null,
    authPool: fakeAuthPool,
    sessionSecret: 'test-secret-not-for-production',
    updatePackageDir: dir,
  });

  const info = await app({ method: 'GET', pathname: '/app/update', headers: {} });
  assert.equal(info.status, 200);
  const envelope = JSON.parse(info.body);
  assert.equal(envelope.ok, true);
  assert.equal(envelope.data.latest.versionCode, 20261123);

  const apk = await app({ method: 'GET', pathname: '/app/download', headers: {} });
  assert.equal(apk.status, 200);
  assert.ok(Buffer.isBuffer(apk.body), 'APK 必须是 Buffer，不能被塞进 JSON 信封');
  assert.deepEqual(apk.body, apkBytes);
});

test('路由表标记：两条都 public，下载额外 raw', () => {
  const routes = buildRoutes({ checkUpdate() {}, downloadApk() {} });
  const info = routes.find((r) => r.path === '/app/update');
  const apk = routes.find((r) => r.path === '/app/download');
  assert.equal(info.public, true);
  assert.equal(apk.public, true);
  assert.equal(apk.raw, true);
});
