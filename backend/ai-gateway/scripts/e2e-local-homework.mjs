/**
 * 本地端到端验收：把「作业上传 → 批改」这条业务链路真跑一遍。
 *
 * 与 `probe-ollama.mjs` 的分工：
 * - `probe-ollama.mjs` 回答「这台机器上哪些模型能顶上网关的档位」（能力口径）；
 * - 本脚本回答「配好之后，学生的作业照片能不能真的走完一条链路」（业务口径）。
 *
 * 两者的区别不是重复：一个模型既能 tool_calls 又能读图，仍然可能在
 * **业务提示词**下跑飞（跳出 schema 说人话、把非作业图当作业批）。
 * 所以这里必须走网关的真 HTTP 端点、送真图片，而不是直接问模型一句。
 *
 * 用法（先在另一个终端把网关指向本机模型）：
 * ```bash
 * export ARK_API_KEY=local ARK_BASE_URL=http://127.0.0.1:11434/v1 \
 *        ARK_MODEL_VISION=gemma4:26b ARK_MODEL_REASONING=gemma4:26b ARK_MODEL_LIGHT=gemma4:26b
 * npm run dev
 *
 * node scripts/e2e-local-homework.mjs                    # 用内置的临时目录
 * node scripts/e2e-local-homework.mjs <图片目录>          # 指定目录
 * E2E_VARIANT=1 node scripts/e2e-local-homework.mjs      # 换一组题目（复跑必做，见下）
 * ```
 *
 * 对着**真方舟**跑也用它（网关指向方舟、`ARK_MODEL_*` 填真模型 ID 即可）：
 * 那时它回答的是「这个模型在客户端的窗口内能不能跑完」。
 *
 * 覆盖六条端点：批改 + 识别（视觉档带图），判定 / 讲解 / 出题 / 批量参考答案
 * （推理档纯文本）。四条推理链路必须一起看 —— 判定的输出只有几十个 token，
 * 讲解要写上千个，两者的耗时不是一个量级。
 *
 * ⚠️ **复跑必须换 `E2E_VARIANT`**：网关按 payload 做响应缓存，同一个 payload
 * 的第二次调用是缓存命中（几毫秒、units=0），判据会写「命中缓存」而不是「通过」。
 * 不换就会得到一份「全绿但什么都没测」的验收，还会掩盖上一轮超窗口的记录。
 *
 * 目录里需要三张图（`scripts/make-homework-photos.ps1` 可生成）：
 * - `homework_check.png`     作业页（含故意做错的题）→ `/ai/homework/check`
 * - `homework_list.png`      抄在本子上的作业清单   → `/ai/homework/ocr`
 * - `answer_handwriting.png` 学生在一道题下写的解答 → `/ai/review/answer-ocr`
 *
 * ⚠️ 第三张**缺了会被跳过**（脚本会打印 `[跳过]` 而不是报错）。
 * 所以看报告时别只看「全绿」——先确认这一行**在不在**。
 * 一条被跳过的用例不会失败，它只是安静地不在那里。
 */
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const BASE = process.env.GATEWAY_BASE_URL ?? 'http://127.0.0.1:8787';
const DIR = process.argv[2] ?? 'C:/Users/lp_pr/AppData/Local/Temp/hw_test';
const STUDENT_ID = 'stu_demo_001';
const DEVICE_ID = 'e2e-local';

/**
 * 第几组题目（`E2E_VARIANT=0/1`，超出就取模）。
 *
 * 网关按 payload 走**响应缓存**，所以同一个 payload 复跑量不到模型：
 * 返回体是几毫秒的缓存命中，判据却仍然写「通过」。**那是一次什么都没测的验收**，
 * 而且它会掩盖掉上一轮那条超窗口的记录。复跑请换一组。
 */
const VARIANT_INDEX = Number.parseInt(process.env.E2E_VARIANT ?? '0', 10) || 0;

/**
 * 客户端的两条超时线（`lib/services/ai_config.dart`）。
 *
 * 本机模型的耗时是**这台机器**决定的，不像云端那样稳定 ——
 * 所以验收必须把实测耗时和这两条线摆在一起看，否则「跑通了」是自欺欺人：
 * 一个 33s 的判定在单测里是成功，在用户手上是「AI 好像没生效」。
 */
const CLIENT_TIMEOUT = { request: 12_000, upload: 30_000 };

async function imagePart(file) {
  const bytes = await readFile(file);
  return {
    mimeType: 'image/png',
    base64: bytes.toString('base64'),
    bytes: bytes.length,
  };
}

async function callGateway(endpoint, body, { label }) {
  const startedAt = Date.now();
  let status = 0;
  let json = null;
  let transportError = null;
  try {
    const response = await fetch(`${BASE}${endpoint}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-student-id': STUDENT_ID,
        'x-device-id': DEVICE_ID,
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(240_000),
    });
    status = response.status;
    const text = await response.text();
    try {
      json = JSON.parse(text);
    } catch {
      transportError = `响应不是 JSON：${text.slice(0, 200)}`;
    }
  } catch (cause) {
    transportError = String(cause?.message ?? cause);
  }
  return { label, endpoint, status, elapsedMs: Date.now() - startedAt, json, transportError };
}

function summarize(raw) {
  const out = {
    label: raw.label,
    endpoint: raw.endpoint,
    httpStatus: raw.status,
    latencyMs: raw.elapsedMs,
    ok: raw.json?.ok === true,
  };
  if (raw.transportError) out.transportError = raw.transportError;
  if (!out.ok) {
    out.error = raw.json?.error ?? null;
    return out;
  }
  const data = raw.json.data ?? {};
  const meta = raw.json.meta ?? {};
  out.model = meta.model ?? null;
  out.cached = meta.cached === true;
  out.units = meta.units ?? null;
  out.usage = meta.usage ?? null;
  out.imageCount = meta.images ?? undefined;
  // 两个端点各自最要紧的字段：批改看分数与错题，识别看科目与任务条数。
  if (data.score !== undefined) out.score = data.score;
  if (data.comment !== undefined) out.comment = data.comment;
  // ⚠️ 字段名是 `items`（`schema.js` 的 homeworkCheck 与客户端
  // `RemoteAiDataSource._parseHomeworkCheck` 都用它）。
  //
  // 这里**曾经**写成 `data.wrongItems` —— 全仓不存在那个字段，于是 `wrongCount`
  // 恒为 `undefined`、`wrongItems` 恒为空：验收报告里「错题条数」这一列
  // **一次都没生效过**。判据空转比判据失败更隐蔽 —— 后者会红，前者只会一直绿。
  if (Array.isArray(data.items)) {
    out.wrongCount = data.items.length;
    out.wrongItems = data.items;
  }
  if (Array.isArray(data.tasks)) {
    out.taskCount = data.tasks.length;
    out.tasks = data.tasks;
    out.overallConfidence = data.confidence;
  }
  // 拍照作答：要看的**就是这段文字本身**，它会被填进学生的作答框。
  // 只记 `confidence` 是不够的 —— 一个自信的错字比一个犹豫的对字糟得多。
  if (typeof data.text === 'string' && data.score === undefined) {
    out.transcribedText = data.text;
    out.confidence = data.confidence;
    if (data.uncertain !== undefined) out.uncertain = data.uncertain;
  }
  if (Array.isArray(data.subjects)) out.subjects = data.subjects;
  out.rawData = data;
  return out;
}

function verdictOf(row, timeoutMs) {
  if (row.transportError) return '传输失败';
  if (!row.ok) return `网关拒绝（${row.error?.code ?? row.httpStatus}）`;
  // 缓存命中的耗时与模型无关，判成「通过」等于把一次没测到模型的调用记成验收通过。
  // 它必须有自己的判词，否则复跑看起来永远全绿。
  if (row.cached) return '命中缓存（未触达模型，耗时无意义）';
  if (row.latencyMs > timeoutMs) {
    return `成功但超客户端 ${timeoutMs / 1000}s 窗口（客户端会降级）`;
  }
  return '通过';
}

function line(char = '-', n = 78) {
  return char.repeat(n);
}

async function main() {
  console.log(`网关：${BASE}`);
  console.log(`图片目录：${DIR}`);
  console.log(`题目组：E2E_VARIANT=${VARIANT_INDEX}（复跑换一组，否则测的是缓存）`);
  console.log(line('='));

  // 1. 先看能力位 —— 客户端据此决定「要不要发图」。它错了，后面全错。
  const health = await fetch(`${BASE}/ai/health`).then((r) => r.json());
  const healthData = health.data ?? {};
  console.log('健康检查');
  console.log(`  capabilities：${JSON.stringify(healthData.capabilities)}`);
  console.log(`  图片预算    ：最多 ${healthData.maxImages} 张 / ` +
    `${Math.round((healthData.maxImageBytes ?? 0) / 1024 / 1024)}MB，` +
    `传输方式 ${healthData.imageTransportHint}`);
  console.log(`  配额        ：${JSON.stringify(healthData.quota)}`);
  console.log(line('='));

  /**
   * 每轮换一组题目。
   *
   * 网关按 payload 做**响应缓存**，所以同一个 payload 复跑测到的是缓存
   * （2–26ms、units=0），而不是模型 —— 上一轮那条 14s 的记录会被一轮
   * 「全绿」的复跑掩盖掉。换 `E2E_VARIANT` 就能得到一条可比的新数据。
   */
  const variants = [
    {
      tag: 'A',
      check: { subject: '数学', title: '数学练习册 P.12' },
      ocr: { fileName: 'homework_list.png' },
      // 题干与知识点只用来把模型的注意力收在这一道上：一张照片里
      // 常常还拍进了旁边的题，不给范围会把隔壁那道也转录进来。
      answerOcr: { questionContent: '9 × 3 = ?', knowledgePoint: '乘法口诀' },
      judge: { questionContent: '9 × 3 = ?', studentAnswer: '26', referenceAnswer: '27' },
      explain: {
        subject: '数学', knowledgePoint: '乘法口诀',
        title: '9 × 3 = ?', wrongReason: '把 9×3 算成了 26',
      },
      practice: { subject: '数学', knowledgePoint: '乘法口诀', difficulty: '基础', count: 3 },
      batch: {
        items: [
          { subject: '数学', knowledgePoint: '同分母分数加法' },
          { subject: '数学', knowledgePoint: '异分母分数加法' },
          { subject: '英语', knowledgePoint: '一般过去时' },
        ],
      },
    },
    {
      tag: 'B',
      // 只在**不影响语义**的字段上变化（科目/知识点不变，改标题、改文件名）——
      // 目的是换掉缓存键，不是换一道题。
      // ⚠️ `ocr.fileName` 与实际发的图片（`homework_list.png`）对不上：这里没有第二张
      // 真图，而 payload 里只有它可改。它只是元数据标签，不影响识别结果。
      check: { subject: '数学', title: '数学练习册 P.14' },
      ocr: { fileName: 'homework_list.png（第二轮验收）' },
      answerOcr: { questionContent: '7 × 8 = ?', knowledgePoint: '乘法口诀' },
      judge: { questionContent: '7 × 8 = ?', studentAnswer: '54', referenceAnswer: '56' },
      explain: {
        subject: '数学', knowledgePoint: '乘法口诀',
        title: '7 × 8 = ?', wrongReason: '把 7×8 算成了 54',
      },
      practice: { subject: '数学', knowledgePoint: '两位数乘法', difficulty: '提高', count: 3 },
      batch: {
        items: [
          { subject: '数学', knowledgePoint: '长方形周长的计算' },
          { subject: '英语', knowledgePoint: '现在完成时' },
        ],
      },
    },
  ];
  const variant = variants[VARIANT_INDEX % variants.length];

  const cases = [
    {
      label: '作业批改',
      endpoint: '/ai/homework/check',
      timeout: CLIENT_TIMEOUT.upload,
      file: path.join(DIR, 'homework_check.png'),
      body: (img) => ({
        subject: variant.check.subject,
        title: variant.check.title,
        imagesSkipped: 0,
        images: [{ mimeType: img.mimeType, base64: img.base64 }],
      }),
    },
    {
      label: '作业清单识别',
      endpoint: '/ai/homework/ocr',
      timeout: CLIENT_TIMEOUT.upload,
      file: path.join(DIR, 'homework_list.png'),
      body: (img) => ({
        fileName: variant.ocr.fileName,
        images: [{ mimeType: img.mimeType, base64: img.base64 }],
      }),
    },
    /**
     * 拍照作答（举一反三里学生手写的那一题解答）。
     *
     * 与「作业清单识别」看着像同一件事，其实问的不是同一个问题：
     * 那条要「按科目归纳作业要求」，这条只要「学生这一题写了什么」。
     * 同一个模型很可能前者满分、后者把学生的作答归纳成一句作业要求 ——
     * 所以必须单独测，不能靠「ocr 那条过了」推断。
     *
     * 判据看 `text`：它会被填进学生的作答框，认错一个数字就会
     * 让做对的学生被判错。
     */
    {
      label: '拍照作答识别',
      endpoint: '/ai/review/answer-ocr',
      timeout: CLIENT_TIMEOUT.upload,
      file: path.join(DIR, 'answer_handwriting.png'),
      body: (img) => ({
        questionContent: variant.answerOcr.questionContent,
        knowledgePoint: variant.answerOcr.knowledgePoint,
        images: [{ mimeType: img.mimeType, base64: img.base64 }],
      }),
    },
    /**
     * 复习的四条链路没有图，但它们才是**本机模型最容易翻车的地方**：
     * 客户端的窗口只有 12s，而不是带图那 30s。
     * 一个模型能批改作业，不代表它能在这个窗口内做判定 ——
     * 这四条必须一起测，否则「26B 当后台」的结论是片面的。
     *
     * 四条里最好的一条与最坏的一条差得很远，这不是噪音：
     * 判定的输出只有几十个 token，讲解/出题要写上千个（还会带思维链）。
     * 只看判定的耗时，会得到「模型完全够快」的错误结论。
     */
    {
      label: '错题判定',
      endpoint: '/ai/review/judge',
      timeout: CLIENT_TIMEOUT.request,
      body: () => variant.judge,
    },
    {
      label: '错题讲解',
      endpoint: '/ai/review/explain',
      timeout: CLIENT_TIMEOUT.request,
      body: () => variant.explain,
    },
    {
      label: '举一反三出题',
      endpoint: '/ai/review/practice',
      timeout: CLIENT_TIMEOUT.request,
      body: () => variant.practice,
    },
    {
      label: '批量参考答案',
      endpoint: '/ai/review/reference-batch',
      timeout: CLIENT_TIMEOUT.request,
      body: () => variant.batch,
    },
  ];

  const report = {
    base: BASE,
    // 记下这一轮用的是哪组题：报告里的耗时数字离开上下文就没法比，
    // 而「上一轮用 A、这一轮用 B」正是解释差异的第一条线索。
    variant: variant.tag,
    thinkingNote: '耗时与网关侧 AI_THINKING_DISABLED_KINDS 有关，记录数字时一并记下它',
    generatedAt: new Date().toISOString(),
    health,
    rows: [],
  };

  for (const item of cases) {
    let img = null;
    if (item.file) {
      try {
        img = await imagePart(item.file);
      } catch (cause) {
        console.log(`[跳过] ${item.label}：读不到 ${item.file}（${cause.message}）`);
        console.log(line());
        continue;
      }
    }
    process.stdout.write(
      `[实测] ${item.label}（${img ? `${(img.bytes / 1024).toFixed(0)}KB 图片` : '纯文本'}）… `,
    );
    const raw = await callGateway(item.endpoint, item.body(img), { label: item.label });
    const row = summarize(raw);
    if (img) row.imageBytes = img.bytes;
    row.timeoutMs = item.timeout;
    row.verdict = verdictOf(row, item.timeout);
    report.rows.push(row);

    console.log(`${(row.latencyMs / 1000).toFixed(1)}s → ${row.verdict}`);
    console.log(
      `  模型：${row.model}｜用量：${JSON.stringify(row.usage)}｜配额单位：${row.units}`
        + (row.cached ? '｜缓存命中' : ''),
    );
    if (row.ok) {
      console.log(`  返回：${JSON.stringify(row.rawData)}`);
    } else {
      console.log(`  错误：${JSON.stringify(row.error ?? row.transportError)}`);
    }
    console.log(line());
  }

  console.log('结论');
  console.log(line('='));
  for (const row of report.rows) {
    console.log(
      `${row.label.padEnd(8, '　')} ${(row.latencyMs / 1000).toFixed(1).padStart(6)}s  ` +
        `（客户端窗口 ${row.timeoutMs / 1000}s）  ${row.verdict}`,
    );
  }

  const outFile = path.join(DIR, 'e2e-report.json');
  await (await import('node:fs/promises')).writeFile(
    outFile,
    JSON.stringify(report, null, 2),
    'utf8',
  );
  console.log(`\n明细已写入 ${outFile}`);
}

main().catch((cause) => {
  console.error('验收脚本自身失败：', cause);
  process.exitCode = 1;
});
