#!/usr/bin/env node
/**
 * 坐标探针：让视觉模型对着一张作业照片，给出每道错题的**框**。
 *
 * 这是一次**实验**，不是生产代码：它决定「错题裁图」这条路值不值得做。
 * 判据是「框能不能套住那道题」，而不是「模型说它给了框」——
 * 框偏半行就裁到隔壁题，那种截图上学生会做一道不属于他的题。
 *
 * 用法：
 *   node tools/bbox-probe.mjs --image <照片> [--out <结果.json>]
 *
 * ⚠️ 密钥从 `D:\easy_learn_home\config\ai.env` 读，**不打印**。
 */
import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
const argOf = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : '';
};

const imagePath = argOf('--image');
const outPath = argOf('--out');
if (!imagePath) {
  console.error('用法：node tools/bbox-probe.mjs --image <照片> [--out <json>]');
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

const provider = String(env.AI_MODEL_PROVIDER || 'ark').toLowerCase();
const isBailian = provider.includes('bailian') || provider.includes('dashscope');
const apiKey = isBailian ? env.BAILIAN_API_KEY : env.ARK_API_KEY;
const model = isBailian ? env.BAILIAN_MODEL_VISION : env.ARK_MODEL_VISION;
const baseUrl = isBailian
  ? env.BAILIAN_BASE_URL || 'https://dashscope.aliyuncs.com/compatible-mode/v1'
  : env.ARK_BASE_URL ||
    `https://ark.${env.ARK_REGION || 'cn-beijing'}.volces.com/api/v3`;

if (!apiKey || !model) {
  console.error('缺少 API Key 或视觉模型 ID');
  process.exit(2);
}

const PROMPT = [
  '这是一张学生的作业照片。请做两件事：',
  '',
  '1. 找出**确实做错**的题（答案错了，或中间某一步本身写错）。',
  '   漏单位、没写答句这类「写得不好但没做错」的**不算**。',
  '2. 对每一道错题，给出它**在照片里的位置**，用归一化坐标：',
  '   [x1, y1, x2, y2]，取值 0-1，左上角为原点。',
  '   框要覆盖这道题的**题干与作答的完整区域**（从题号开始，到这道题结束），',
  '   但**不要**框进相邻的题。',
  '',
  '同时给出卷面上的题号原文（如 "20(4)"），以及错在哪。',
  '',
  '只输出 JSON，不要解释，格式：',
  '{"items":[{"questionNo":"20(4)","question":"题干原文",',
  '  "wrongReason":"错在哪","box":[0.12,0.34,0.88,0.41]}]}',
].join('\n');

const imageBytes = fs.readFileSync(imagePath);
const mime = imagePath.toLowerCase().endsWith('.png')
  ? 'image/png'
  : 'image/jpeg';
const dataUrl = `data:${mime};base64,${imageBytes.toString('base64')}`;

const body = {
  model,
  messages: [
    {
      role: 'system',
      content: '你是一个严格的作业批改助手，只输出 JSON。',
    },
    {
      role: 'user',
      content: [
        { type: 'image_url', image_url: { url: dataUrl } },
        { type: 'text', text: PROMPT },
      ],
    },
  ],
  temperature: 0,
};

const started = Date.now();
const response = await fetch(`${baseUrl}/chat/completions`, {
  method: 'POST',
  headers: {
    'content-type': 'application/json',
    authorization: `Bearer ${apiKey}`,
  },
  body: JSON.stringify(body),
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
if (start < 0 || end <= start) {
  console.error('模型没有返回 JSON：');
  console.error(raw.slice(0, 800));
  process.exit(1);
}

const parsed = JSON.parse(raw.slice(start, end + 1));
const items = Array.isArray(parsed.items) ? parsed.items : [];
const result = {
  provider,
  model,
  image: path.resolve(imagePath),
  ms: Date.now() - started,
  usage: payload?.usage ?? null,
  items,
};

const json = JSON.stringify(result, null, 2);
if (outPath) {
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, json, 'utf8');
}
console.log(json);
