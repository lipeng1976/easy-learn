#!/usr/bin/env node
/**
 * 把 OCR 端点**原始返回**摊开看的探针。
 *
 * 与 `measure-handwriting-ocr.mjs` 的分工：
 *   - 那个脚本打分（召回/多余/置信度），回答「识别得准不准」；
 *   - 这个脚本不打分，只把模型给的 `tasks` 原样打印出来，回答
 *     「**识别之后那段结构化输出长什么样**」—— 一条里有没有塞两件事、
 *     有没有带 estimatedMinutes、科目填的是什么。
 *
 * 为什么需要它：归一化的输入就是这段原始 JSON。只看归一化后的结果，
 * 没法区分「模型本来拆对了」和「模型塞了两件事、被归一化救回来」——
 * 而这两件事对提示词的评价完全不同。
 *
 * 用法：
 *   AI_BASE_URL=http://127.0.0.1:8787 node scripts/probe-ocr-tasks.mjs <图片路径> [学生ID]
 */

import { readFile } from 'node:fs/promises';
import path from 'node:path';

const BASE = process.env.AI_BASE_URL || 'http://127.0.0.1:8787';
const FILE = process.argv[2];
const STUDENT = process.argv[3] || 'stu_001';

if (!FILE) {
  console.error('用法：node scripts/probe-ocr-tasks.mjs <图片路径> [学生ID]');
  process.exit(2);
}

const bytes = await readFile(FILE);
const mime = path.extname(FILE).toLowerCase() === '.png'
  ? 'image/png'
  : 'image/jpeg';

const started = Date.now();
const res = await fetch(`${BASE}/ai/homework/ocr`, {
  method: 'POST',
  headers: {
    'content-type': 'application/json',
    'X-Student-Id': STUDENT,
  },
  body: JSON.stringify({
    fileName: path.basename(FILE),
    images: [
      { mimeType: mime, byteSize: bytes.length, base64: bytes.toString('base64') },
    ],
  }),
});
const latencyMs = Date.now() - started;
const body = await res.json();

console.log(`HTTP ${res.status}  耗时 ${(latencyMs / 1000).toFixed(1)}s`);
if (!body.ok) {
  console.log(JSON.stringify(body, null, 2));
  process.exit(1);
}

const data = body.data;
console.log(`\n== 整体 ==`);
console.log(`subject=${data.subject}  confidence=${data.confidence}`);

console.log(`\n== text（原样转录）==`);
console.log(data.text);

console.log(`\n== tasks（${data.tasks.length} 条）==`);
for (const [i, task] of data.tasks.entries()) {
  const flags = [];
  if (task.uncertain === true) flags.push('uncertain');
  if (typeof task.estimatedMinutes === 'number') {
    flags.push(`est=${task.estimatedMinutes}min`);
  } else {
    flags.push('est=—');
  }
  // 一条里出现多个序号是「没拆干净」的信号，单独标出来。
  const markers = (task.text.match(/(?:^|[\s，,、；;：:])(?:\d{1,2}\s*[.、)）]|[（(]\s*\d{1,2}\s*[)）]|[①-⑳])/g) || []);
  if (markers.length >= 2) flags.push(`⚠️未拆(${markers.length}个序号)`);
  console.log(
    `  [${i + 1}] ${task.subject.padEnd(6)} | ${task.text}   «${flags.join(' ')}»`,
  );
}

console.log(`\n== 原始 JSON ==`);
console.log(JSON.stringify(data.tasks, null, 2));
