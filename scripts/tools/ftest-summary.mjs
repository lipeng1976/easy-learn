#!/usr/bin/env node
/**
 * 汇总 `flutter test --reporter=json` 的输出。
 *
 * ## 为什么需要它
 *
 * 默认的 compact 输出**一旦重定向到文件就会折叠**（进度行被覆盖掉），
 * 所以「到底跑了哪些用例、几条红」在日志里是看不到的 —— 只剩最后一行。
 * 数测试只认 json reporter，这个脚本负责把那串 JSONL 变成三件东西：
 *
 * 1. **通过 / 失败条数**（`testDone` 里 `hidden` 的那些是分组与加载占位，不算）；
 * 2. **失败用例的名字 + 报错**（重定向之后 dart 本来就不打了）；
 * 3. ⭐ **跑到的测试文件清单**，并与 `test/*_test.dart` 对账 ——
 *    「文件写了但没进 runner」是踩过的坑（`doc/open-items.md` B33：
 *    `attachments.test.js` 18 条一次都没跑过，而全绿）。漏掉的文件**必须报红**。
 *
 * 用法：
 *   flutter test --reporter=json > build/_ftest.json
 *   node tools/ftest-summary.mjs build/_ftest.json
 */
import fs from 'node:fs';

const file = process.argv[2] ?? 'build/_ftest.json';
if (!fs.existsSync(file)) {
  console.error(`找不到 ${file}；先跑 flutter test --reporter=json > ${file}`);
  process.exit(2);
}

const raw = fs.readFileSync(file, 'utf8');

// 输出里可能混进非 JSON 的行（flutter 自己的告警、崩溃报告），逐行 try。
const events = [];
let skipped = 0;
for (const line of raw.split(/\r?\n/)) {
  const text = line.trim();
  if (!text.startsWith('{')) {
    if (text !== '') skipped++;
    continue;
  }
  try {
    events.push(JSON.parse(text));
  } catch {
    skipped++;
  }
}

const names = new Map();
const suites = new Map(); // suiteID → 文件名（suite.path 是 runner 认定的真实文件）
const testSuite = new Map(); // testID → suiteID
const files = new Set();
let passed = 0;
let failed = 0;
const failures = [];

for (const event of events) {
  if (event.type === 'suite') {
    // ⭐ 文件归属只认 suite.path（B36 教训）：testWidgets 用例的 test.url
    // 指向 package:flutter_test/src/widget_tester.dart 这类框架文件，
    // 按 url 归属会把整批 widget 用例算丢 —— 2026-10-06 的假警报就是这么来的。
    const p = event.suite?.path;
    if (p) suites.set(event.suite.id, p.replaceAll('\\', '/').split('/').pop());
  } else if (event.type === 'testStart') {
    const id = event.test?.id;
    if (id != null) {
      names.set(id, event.test?.name ?? '(无名)');
      if (event.test?.suiteID != null) testSuite.set(id, event.test.suiteID);
    }
  } else if (event.type === 'testDone') {
    if (event.hidden) continue;
    // 文件「跑到了」的定义 = 至少一条非隐藏用例跑完（在 testDone 上归属，
    // 而不是 testStart）：只加载、零用例的文件照旧判 missing —— 那是 B33 的形态。
    const file = suites.get(testSuite.get(event.testID));
    if (file) files.add(file);
    if (event.result === 'success') {
      passed++;
    } else {
      failed++;
      failures.push(names.get(event.testID) ?? `#${event.testID}`);
    }
  } else if (event.type === 'error') {
    // 绑定到具体用例的错误信息（stack trace 的第一行通常就够定位）。
    const name = names.get(event.testID) ?? `#${event.testID}`;
    const message = String(event.error ?? '').split('\n')[0];
    failures.push(`  ↳ ${name}: ${message}`);
  }
}

// 与磁盘上的测试文件对账 —— 这一条是本脚本存在的主要理由。
const testDir = 'test';
const onDisk = fs.existsSync(testDir)
  ? fs
      .readdirSync(testDir)
      .filter((name) => name.endsWith('_test.dart'))
      .sort()
  : [];
const missing = onDisk.filter((name) => !files.has(name));

// 只保留失败明细里那些「↳」开头的行（它们带原因），其余去重。
const failureLines = [...new Set(failures)];

console.log(`测试文件：跑了 ${files.size} / 磁盘上 ${onDisk.length}`);
console.log(`用例：通过 ${passed} · 失败 ${failed}`);
if (missing.length > 0) {
  console.log(`⚠️ 下列测试文件一次都没跑：${missing.join('、')}`);
}
if (skipped > 0) console.log(`（另有 ${skipped} 行非 JSON 输出被跳过）`);
if (failureLines.length > 0) {
  console.log('');
  console.log('失败明细：');
  for (const line of failureLines) console.log(line);
}

// 退出码：红就是红。runner 漏掉文件也按失败处理 —— 那正是 B33 的形态。
process.exit(failed === 0 && missing.length === 0 ? 0 : 1);
