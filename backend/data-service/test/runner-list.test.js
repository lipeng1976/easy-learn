import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

/**
 * 「写了测试但没跑」的守门人。
 *
 * ## 为什么要有一条测试来管测试清单
 *
 * `scripts/run-tests.mjs` 用**显式文件名**启动 `node --test`（本机 Node 不认目录）。
 * 于是新增一个 `test/xxx.test.js` 而不去改那一行，结果是：
 *
 *   · `npm test` 全绿；
 *   · 那条新判据一次都没执行；
 *   · 它挡的 bug 因此可以照样上线。
 *
 * 这不是假设。2026-10-26 的 ima 单测、10-27 的打卡单测都踩过 ——
 * 都是「文件写好了、手动跑绿了、`npm test` 里根本没有它」。两次都靠人偶然发现。
 *
 * 所以清单本身需要一个判据：**磁盘上的每个测试文件，都必须在清单里出现**。
 */

const here = dirname(fileURLToPath(import.meta.url));
const serviceRoot = join(here, '..');
const runnerPath = join(serviceRoot, 'scripts', 'run-tests.mjs');

test('run-tests.mjs 覆盖 test/ 下每一个 *.test.js', () => {
  const runner = readFileSync(runnerPath, 'utf8');
  const listed = new Set(
    [...runner.matchAll(/'(test\/[A-Za-z0-9._-]+\.test\.js)'/g)].map((m) => m[1]),
  );

  const onDisk = readdirSync(here)
    .filter((name) => name.endsWith('.test.js'))
    .map((name) => `test/${name}`);

  const missing = onDisk.filter((file) => !listed.has(file));
  assert.deepEqual(
    missing,
    [],
    `这些测试文件在磁盘上有、但 run-tests.mjs 的清单里没有，\`npm test\` 不会执行它们：\n  ${missing.join('\n  ')}`,
  );
});

test('清单里列的文件都真实存在（改名后要同步，否则 node --test 会报错）', () => {
  const runner = readFileSync(runnerPath, 'utf8');
  const listed = [...runner.matchAll(/'(test\/[A-Za-z0-9._-]+\.test\.js)'/g)].map((m) => m[1]);
  const missingFiles = listed.filter((file) => !existsSync(join(serviceRoot, file)));
  assert.deepEqual(
    missingFiles,
    [],
    `清单里这些文件不存在（改名/删除后忘了同步）：\n  ${missingFiles.join('\n  ')}`,
  );
});
