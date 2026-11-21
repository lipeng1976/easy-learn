#!/usr/bin/env node
/**
 * 提示词探针：拿一份**外部给的** prompt（用户手写的、别家产品的）
 * 在真实作业照片上跑一遍，看看它到底返回什么。
 *
 * 存在的理由：prompt 是能"看起来更好"的东西 —— 多要几个字段很容易，
 * 但这些字段是真从图上读出来的，还是模型脑补的，只能拿真实照片对。
 * 所以这个脚本只负责**原样发出去、原样存回来**，不做任何清洗，
 * 好让调用方自己对着照片核。
 *
 * 用法：
 *   node tools/prompt-probe.mjs --image <照片> --prompt <prompt.txt> [--out <json>]
 */
import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
const argOf = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : '';
};

const imagePath = argOf('--image');
const promptPath = argOf('--prompt');
const outPath = argOf('--out');
if (!imagePath || !promptPath) {
  console.error(
    '用法：node tools/prompt-probe.mjs --image <照片> --prompt <prompt.txt> [--out <json>]',
  );
  process.exit(2);
}

const ENV_FILE = 'D:/easy_learn_home/config/ai.env';
const env = Object.fromEntries(
  fs
    .readFileSync(ENV_FILE, 'utf8')
    .split(/\r?\n/)
    .filter((line) => line && !line.startsWith('#') && line.includes('='))
    .map((line) => {
      const i = line.indexOf('=');
      return [line.slice(0, i).trim(), line.slice(i + 1).trim()];
    }),
);

const provider = String(
  argOf('--provider') || env.AI_MODEL_PROVIDER || 'ark',
).toLowerCase();
const isBailian = provider.includes('bailian') || provider.includes('dashscope');
const apiKey = isBailian ? env.BAILIAN_API_KEY : env.ARK_API_KEY;
const model = isBailian ? env.BAILIAN_MODEL_VISION : env.ARK_MODEL_VISION;
const baseUrl = isBailian
  ? env.BAILIAN_BASE_URL || 'https://dashscope.aliyuncs.com/compatible-mode/v1'
  : env.ARK_BASE_URL ||
    `https://ark.${env.ARK_REGION || 'cn-beijing'}.volces.com/api/v3`;

const prompt = fs.readFileSync(promptPath, 'utf8');
const imageBytes = fs.readFileSync(imagePath);
const mime = imagePath.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
const dataUrl = `data:${mime};base64,${imageBytes.toString('base64')}`;

const started = Date.now();
const response = await fetch(`${baseUrl}/chat/completions`, {
  method: 'POST',
  headers: {
    'content-type': 'application/json',
    authorization: `Bearer ${apiKey}`,
  },
  body: JSON.stringify({
    model,
    messages: [
      {
        role: 'user',
        content: [
          { type: 'image_url', image_url: { url: dataUrl } },
          { type: 'text', text: prompt },
        ],
      },
    ],
    temperature: 0,
  }),
});

const text = await response.text();
if (!response.ok) {
  console.error(`HTTP ${response.status}：${text.slice(0, 600)}`);
  process.exit(1);
}

const payload = JSON.parse(text);
const content = payload?.choices?.[0]?.message?.content ?? '';
const raw =
  typeof content === 'string'
    ? content
    : content.map((part) => part?.text ?? '').join('');

const start = raw.indexOf('{');
const end = raw.lastIndexOf('}');
let parsed = null;
if (start >= 0 && end > start) {
  try {
    parsed = JSON.parse(raw.slice(start, end + 1));
  } catch (error) {
    parsed = { parseError: String(error) };
  }
}

const result = {
  provider,
  model,
  prompt: path.basename(promptPath),
  image: path.basename(imagePath),
  ms: Date.now() - started,
  usage: payload?.usage ?? null,
  // 原始文本一起存：解析失败时能看出是"模型多说了话"还是"格式不对"。
  raw,
  parsed,
};

const json = JSON.stringify(result, null, 2);
if (outPath) {
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, json, 'utf8');
}
console.log(json);
