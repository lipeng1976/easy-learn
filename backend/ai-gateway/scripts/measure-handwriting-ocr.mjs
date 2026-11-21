#!/usr/bin/env node
/**
 * 手写体识别率的实测脚本。
 *
 * 为什么要专门测「手写」：此前的验收样本是**楷体 + 每行 3px 平移**，那只是
 * 「工整学生字」，识别率 100% 是必然的，回答不了「手写体识别率低不低」。
 *
 * 这个脚本把**字迹工整度**当作唯一变量：四张图的文字内容完全相同，
 * 只有字体与逐字抖动不同（L1 楷体 → L4 舒体+抖动+不均光照）。
 * 于是任何识别率的差异都只能归因于字迹，而不是内容难度。
 *
 * 评分口径（任务级，与产品行为一致 —— 学生看到的是任务清单）：
 *   - 召回：6 条作业要求里认对几条。判据是「某条识别出的任务文本同时含该条的全部关键词」。
 *   - 精确：识别出的任务里有多少条不是 6 条中的任何一条（多出来的）。
 *   - 科目：语/数/英三科是否都出现在任务里。
 *   - 置信度：模型**自报**的把握。这一项比准确率更值得盯 ——
 *     客户端有 0.8 的置信度门槛（`kOcrConfidenceFloor`），
 *     若模型在潦草字迹上依然自报 0.95，门槛就形同虚设，
 *     劣质任务会被当成正常结果落库。
 *
 * 用法：
 *   node scripts/measure-handwriting-ocr.mjs [图片目录] [学生ID]
 *   默认目录 ../..//doc/demo，默认学生 stu_001
 */

import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

const BASE = process.env.AI_BASE_URL || 'http://127.0.0.1:8787';
const DIR = process.argv[2] || path.resolve('../../doc/demo');
const STUDENT = process.argv[3] || 'stu_001';
/** 只跑指定档位，逗号分隔，例如 `L4` 或 `L3,L4`；不传则全跑。 */
const ONLY = (process.argv[4] || '')
  .split(',')
  .map((s) => s.trim().toUpperCase())
  .filter(Boolean);
const CLIENT_TIMEOUT_MS = 120000; // 本机 26B 冷启动可能到 40s 以上

/** 四档样本，内容相同、只有字迹工整度不同。 */
const SAMPLES = [
  { level: 'L1', label: '楷体·工整', file: 'L1_kaiti.png' },
  { level: 'L2', label: '行楷·工整', file: 'L2_xingkai.png' },
  { level: 'L3', label: '行楷·逐字抖动', file: 'L3_xingkai_jitter.png' },
  { level: 'L4', label: '舒体·潦草+不均光照', file: 'L4_shuti_messy.png' },
  { level: 'S0', label: '（对照）既有样例楷体', file: 'homework_list.png' },
];

/**
 * 6 条作业要求。关键词全部命中才算这一条认出来了。
 * 用「关键词」而不是整句比对：手写识别本来就不会逐字完美，
 * 而产品要的是「学生能照着做」—— 认出「背诵」和「静夜思」就够了。
 */
const EXPECTED = [
  { subject: '语文', want: '抄写第3课生字', keys: ['抄写', '生字'] },
  { subject: '语文', want: '背诵《静夜思》', keys: ['背诵', '静夜思'] },
  { subject: '数学', want: '练习册P12 第1-5题', keys: ['练习册'] },
  { subject: '数学', want: '口算20题', keys: ['口算'] },
  { subject: '英语', want: '听读Unit 2', keys: ['听读'] },
  { subject: '英语', want: '默写单词', keys: ['默写', '单词'] },
];

/** 置信度门槛，与客户端 `kOcrConfidenceFloor` 保持一致。 */
const CONFIDENCE_FLOOR = 0.8;

const norm = (s) =>
  String(s ?? '')
    .replace(/[\s\u3000]/g, '')
    .replace(/[（）()]/g, '');

function mimeOf(name, buf) {
  if (buf.length > 4 && buf[0] === 0x89 && buf[1] === 0x50) return 'image/png';
  if (buf.length > 3 && buf[0] === 0xff && buf[1] === 0xd8) return 'image/jpeg';
  if (name.toLowerCase().endsWith('.png')) return 'image/png';
  return 'image/jpeg';
}

async function callOcr(fileName, buf) {
  const body = {
    fileName,
    images: [
      {
        mimeType: mimeOf(fileName, buf),
        byteSize: buf.length,
        base64: buf.toString('base64'),
      },
    ],
  };
  const started = Date.now();
  const res = await fetch(`${BASE}/ai/homework/ocr`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Student-Id': STUDENT,
      'X-Request-Id': `hw-hand-${Date.now()}`,
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(CLIENT_TIMEOUT_MS),
  });
  const latencyMs = Date.now() - started;
  const json = await res.json().catch(() => null);
  return { latencyMs, httpStatus: res.status, envelope: json };
}

/** 把网关返回的信封压成一行可评分的记录。 */
function summarize(sample, r) {
  const env = r.envelope ?? {};
  const data = env?.data ?? {};
  const tasks = Array.isArray(data.tasks) ? data.tasks : [];
  const texts = tasks.map((t) => ({
    subject: String(t?.subject ?? '').trim(),
    text: String(t?.text ?? '').trim(),
    n: norm(t?.text),
  }));

  const hits = EXPECTED.map((exp) => {
    const hit = texts.find(
      (t) => exp.keys.every((k) => t.n.includes(norm(k))) && t.n.length > 0,
    );
    return { ...exp, hit: Boolean(hit), got: hit ? hit.text : '' };
  });

  const hitIdx = new Set();
  for (const exp of EXPECTED) {
    const i = texts.findIndex((t) => exp.keys.every((k) => t.n.includes(norm(k))));
    if (i >= 0) hitIdx.add(i);
  }
  const extra = texts.filter((_, i) => !hitIdx.has(i)).map((t) => t.text);

  const subjects = new Set(texts.map((t) => t.subject));
  const subjectsOk = ['语文', '数学', '英语'].every((s) => subjects.has(s));

  // 模型自报「有认不准的字」的条目。这是手写识别里唯一能指出
  // 「错在哪一条」的信号 —— 置信度做不到（实测从工整到潦草只从 0.98 掉到 0.9），
  // 所以它必须被记下来，否则「改了提示词有没有用」无从判断。
  const flagged = tasks
    .filter((t) => t?.uncertain === true)
    .map((t) => String(t?.text ?? '').trim());
  // 转录里出现了「（？）」，也算模型承认了不确定 —— 有些模型只标在文字里，
  // 不填结构化字段。两条路径都数出来，才能分清「没标」和「标了但没进字段」。
  const markedInText = /（\?）|\(\?\)/.test(String(data.text ?? ''));

  return {
    level: sample.level,
    label: sample.label,
    file: sample.file,
    ok: env?.ok === true,
    errorCode: env?.ok === true ? null : (env?.error?.code ?? 'unknown'),
    httpStatus: r.httpStatus,
    latencyMs: r.latencyMs,
    confidence: typeof data.confidence === 'number' ? data.confidence : null,
    subject: data.subject ?? '',
    subjectsOk,
    taskCount: tasks.length,
    recall: hits.filter((h) => h.hit).length,
    recallTotal: EXPECTED.length,
    extraCount: extra.length,
    uncertainTasks: flagged,
    markedInText,
    hits,
    extra,
    textPreview: String(data.text ?? '').slice(0, 300),
  };
}

const line = (c = '-') => c.repeat(72);

async function main() {
  console.log('手写体识别率实测');
  console.log(`网关 ${BASE}   学生 ${STUDENT}`);
  console.log(`样本目录 ${DIR}`);
  console.log(line('='));

  const rows = [];
  const picked = ONLY.length > 0
    ? SAMPLES.filter((s) => ONLY.includes(s.level.toUpperCase()))
    : SAMPLES;
  if (ONLY.length > 0) console.log(`（只跑 ${picked.map((s) => s.level).join('、')}）`);
  for (const sample of picked) {
    const file = path.join(DIR, sample.file);
    let buf;
    try {
      buf = await readFile(file);
    } catch (cause) {
      console.log(`[跳过] ${sample.level} ${sample.label}：读不到 ${sample.file}`);
      continue;
    }
    process.stdout.write(
      `[实测] ${sample.level} ${sample.label}（${(buf.length / 1024).toFixed(0)}KB）… `,
    );
    let row;
    try {
      row = summarize(sample, await callOcr(sample.file, buf));
    } catch (cause) {
      row = {
        level: sample.level,
        label: sample.label,
        file: sample.file,
        ok: false,
        errorCode: `transport:${cause.name}`,
        latencyMs: null,
        recall: 0,
        recallTotal: EXPECTED.length,
        extraCount: 0,
        confidence: null,
        hits: [],
        extra: [],
      };
    }
    rows.push(row);
    console.log(
      `${row.ok ? 'ok' : `FAIL(${row.errorCode})`}  ` +
        `召回 ${row.recall}/${row.recallTotal}  多出 ${row.extraCount}  ` +
        `可疑 ${row.uncertainTasks?.length ?? 0}  ` +
        `置信度 ${row.confidence ?? '-'}  ${(row.latencyMs / 1000).toFixed(1)}s`,
    );
  }

  console.log(line('='));
  console.log('汇总（任务级）');
  console.log(
    '档位  字迹                 召回   多余  可疑  科目  置信度  耗时',
  );
  for (const r of rows) {
    console.log(
      `${r.level.padEnd(5)} ${r.label.padEnd(20)} ` +
        `${String(r.recall + '/' + r.recallTotal).padEnd(6)} ` +
        `${String(r.extraCount).padEnd(5)} ` +
        `${String(r.uncertainTasks?.length ?? 0).padEnd(5)} ` +
        `${(r.subjectsOk ? '全对' : '缺').padEnd(5)} ` +
        `${String(r.confidence ?? '-').padEnd(7)} ` +
        `${r.latencyMs != null ? (r.latencyMs / 1000).toFixed(1) + 's' : '-'}`,
    );
  }

  console.log(line('='));
  console.log('逐条明细');
  for (const r of rows) {
    console.log(`\n${r.level} ${r.label}`);
    for (const h of r.hits ?? []) {
      console.log(
        `  ${h.hit ? '认对' : '漏掉'}  ${h.subject}｜${h.want}` +
          (h.hit ? `   → ${h.got}` : ''),
      );
    }
    if (r.extra?.length) {
      console.log(`  多出：${r.extra.join(' / ')}`);
    }
    if (r.uncertainTasks?.length) {
      console.log(`  模型标了「没把握」：${r.uncertainTasks.join(' / ')}`);
    } else {
      console.log(
        `  模型没标任何「没把握」${r.markedInText ? '（但转录里出现了（？）标记）' : ''}`,
      );
    }
    if (r.textPreview) {
      console.log(`  转录：${r.textPreview.replace(/\n/g, ' ⏎ ')}`);
    }
  }

  // 置信度与真实工整度的相关性 —— 这一项决定「0.8 门槛」是否有意义。
  console.log('\n' + line('='));
  console.log('置信度校准检查');
  const aboveFloor = rows.filter((r) => r.confidence != null && r.confidence >= CONFIDENCE_FLOOR);
  const badButConfident = rows.filter(
    (r) => r.confidence != null && r.confidence >= CONFIDENCE_FLOOR && r.recall < r.recallTotal,
  );
  console.log(
    `  置信度 ≥ ${CONFIDENCE_FLOOR} 的档位：${aboveFloor.length}/${rows.length}` +
      `（其中识别有遗漏的：${badButConfident.length}）`,
  );
  console.log(
    badButConfident.length === 0
      ? '  → 门槛与实际情况一致：认不全时模型也承认没把握。'
      : `  → 门槛被架空：${badButConfident.map((r) => r.level).join('、')} 认不全却自报「有把握」，` +
        '客户端会把这些结果当正常结果落库，学生看到的是缺项的作业清单却没有提示。',
  );

  const out = path.join(DIR, 'handwriting-ocr-report.json');
  await writeFile(out, JSON.stringify({ base: BASE, student: STUDENT, rows }, null, 2), 'utf8');
  console.log(`\n报告已写入 ${out}`);
}

main().catch((cause) => {
  console.error('实测失败：', cause);
  process.exitCode = 1;
});
