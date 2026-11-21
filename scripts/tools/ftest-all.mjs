#!/usr/bin/env node
/**
 * 全量跑 flutter test，对账「磁盘上的文件 vs 实际跑到用例的文件」，
 * 对零用例文件自动补跑。
 *
 * ## B36 定案（2026-10-06）：别重蹈「假警报」
 *
 * 最初建这个工具，是因为按 test.url 归属时 7 个 widget 测试文件看似被
 * 「静默跳过」。后来用 suiteID 归属重查：**那些用例全跑了、全绿 ——
 * 是对账工具自己的 bug**（testWidgets 用例的 test.url 指向
 * package:flutter_test/src/widget_tester.dart 这类框架文件）。
 * flutter test 本机丢文件并无实证。教训：**看见对账红，第一嫌疑人是工具自己**。
 *
 * 保留此工具作兜底：一旦 runner 真漏了文件（B33 那种「文件没进 runner」），
 * 对账会红，自动补跑把结果补齐，缺一个文件仍 exit 1。
 * 文件归属一律 `test.suiteID → suite.path`，**禁止按 test.url 归属**。
 *
 * ## 姿势
 *
 * 1. 先正常跑一遍全量；
 * 2. 对账（磁盘上 *_test.dart vs 至少一条用例跑完的文件）；
 * 3. 对「零用例」的文件补跑一批；补跑后仍缺的，逐个单独跑（最后手段）；
 * 4. 合并计数、最终对账，缺一个文件就 exit 1。
 *
 * 用法：`node tools/ftest-all.mjs`（要求 PATH 里有 flutter）
 */

import { spawnSync } from 'node:child_process';
import { readdirSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';

const OUT_DIR = 'build';
const isDartTest = (name) => name.endsWith('_test.dart');

/** 跑一批测试文件（空数组 = 无参全量），返回解析好的统计。 */
function runBatch(files, tag) {
  const jsonPath = join(OUT_DIR, `_ftest-all-${tag}.json`);
  const args = ['test', '--reporter=json', ...files];
  const result = spawnSync('flutter', args, {
    encoding: 'utf8',
    maxBuffer: 512 * 1024 * 1024,
    shell: process.platform === 'win32',
  });
  writeFileSync(jsonPath, result.stdout ?? '');
  if (result.status !== 0) {
    // 失败也要继续分析 json（失败明细在里面），退出码最后统一算。
    console.log(`（flutter 退出码 ${result.status}，明细见 ${jsonPath}）`);
  }

  const perFile = new Map(); // 文件名 → 用例数（按 suiteID 归属，见文件头）
  let passed = 0;
  let failed = 0;
  const failures = [];
  const names = new Map();
  const suites = new Map(); // suiteID → 文件名
  const testSuite = new Map(); // testID → suiteID
  for (const line of (result.stdout ?? '').split('\n')) {
    if (!line.startsWith('{')) continue;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }
    if (event.type === 'suite') {
      const p = event.suite?.path;
      if (p) suites.set(event.suite.id, p.replaceAll('\\', '/').split('/').pop());
    } else if (event.type === 'testStart') {
      const id = event.test?.id;
      if (id != null) {
        if (event.test?.name) names.set(id, event.test.name);
        if (event.test?.suiteID != null) testSuite.set(id, event.test.suiteID);
      }
    } else if (event.type === 'testDone' && !event.hidden) {
      // 归属在 testDone 上做：至少一条用例跑完才算「跑到了」。
      const file = suites.get(testSuite.get(event.testID));
      if (file) perFile.set(file, (perFile.get(file) ?? 0) + 1);
      if (event.result === 'success') passed++;
      else {
        failed++;
        failures.push(names.get(event.testID) ?? `#${event.testID}`);
      }
    } else if (event.type === 'error') {
      const name = names.get(event.testID) ?? `#${event.testID}`;
      failures.push(`  ↳ ${name}: ${String(event.error ?? '').split('\n')[0]}`);
    }
  }
  return { perFile, passed, failed, failures, jsonPath };
}

const onDisk = readdirSync('test').filter(isDartTest).sort();

// ── 第一段：全量 ──────────────────────────────────────────────
console.log(`▶ 全量（磁盘上 ${onDisk.length} 个测试文件）…`);
const first = runBatch([], 'main');
const ran = new Set(first.perFile.keys());
let missing = onDisk.filter((name) => !ran.has(name));
console.log(
  `  跑到 ${ran.size}/${onDisk.length} 个文件 · 通过 ${first.passed} · 失败 ${first.failed}`,
);

let passed = first.passed;
let failed = first.failed;
const allFailures = [...first.failures];

// ── 第二段：被跳文件一批补跑 ──────────────────────────────────
if (missing.length > 0) {
  console.log(`▶ ${missing.length} 个文件零用例，补跑一批（兜底：万一 runner 真漏了）…`);
  // ⚠️ 补跑必须传相对项目根的路径（test/xxx_test.dart）：裸文件名会被
  // flutter test 当成不存在的路径，7 条假失败（10-06 栽过）。
  const second = runBatch(
    missing.map((name) => `test/${name}`),
    'retry',
  );
  const ran2 = new Set(second.perFile.keys());
  passed += second.passed;
  failed += second.failed;
  allFailures.push(...second.failures);
  missing = missing.filter((name) => !ran2.has(name));
  console.log(`  补跑跑到 ${ran2.size} 个 · 通过 ${second.passed} · 失败 ${second.failed}`);
}

// ── 第三段：残余逐个跑（最后手段） ────────────────────────────
for (const file of missing) {
  console.log(`▶ 仍缺 ${file}，单独跑…`);
  const third = runBatch([`test/${file}`], `single-${file}`);
  passed += third.passed;
  failed += third.failed;
  allFailures.push(...third.failures);
  if (third.perFile.has(file)) missing = missing.filter((m) => m !== file);
}

// ── 汇总 ──────────────────────────────────────────────────────
console.log('');
console.log(`合计：通过 ${passed} · 失败 ${failed}`);
if (missing.length > 0) {
  console.log(`⚠️ 以下文件两段补跑后仍零用例：${missing.join('、')}`);
}
const failureLines = [...new Set(allFailures)];
if (failureLines.length > 0) {
  console.log('失败明细：');
  for (const line of failureLines) console.log(line);
}
process.exit(failed === 0 && missing.length === 0 ? 0 : 1);
