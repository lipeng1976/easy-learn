/**
 * 「试卷错题 MD」→ 结构化错题（纯函数，不碰网络与数据库）。
 *
 * ## 这是哪一类资料
 *
 * 家长在 ima 里手工核对**考试卷**（不是作业、不是每日打卡），把错题整理成
 * 一份 MD，放进 `教学资料/试卷错题/`。App 把它读回来写进 `review_mistake`，
 * 之后现有的重做卷 / 举一反三就能直接用，不需要另造一套出题链路。
 *
 * ## 为什么不复用「错题档案」的格式
 *
 * App 自动推送的「错题档案」是**按知识点聚合的镜像**（`buildMistakesMarkdown`），
 * 分节写 `## <知识点名>`；这里只认 `## 知识点：<知识点名>`。
 * 这个差别是**故意的格式闸**：就算有人把一份 83 条的自动镜像误拖进
 * `试卷错题/`，解析结果也是 0 条，导入端点会响亮报错，不会把旧错题
 * 整批重复灌回去（失败不报错是本项目最常踩的一类坑）。
 *
 * ## 为什么 `source_ref` 用 mediaId、`homework_id` 留空
 *
 * `028` 已经为「非作业来源」加了 `source_ref`。这里 `source_type='ima_exam'`、
 * `source_ref=<ima media id>`：重复导入同一份 MD 先按这两个条件删旧行再写，
 * 不会翻倍。绝不能把 mediaId 塞进 `homework_id` —— 作业详情页会拿它去
 * `homework` 表查一个不存在的行，且不报错。
 */

/** 错题来源词：单点定义，路由 / 判据 / 探针都引用它。 */
export const EXAM_MISTAKE_SOURCE_TYPE = 'ima_exam';

/** ima 侧目录：与 App 自动推送的「错题档案」文件夹物理隔离。 */
export const EXAM_MISTAKE_FOLDER_PATH = ['教学资料', '试卷错题'];

/** 一份试卷的错题 MD 通常几 KB；2MB 足够，也挡住误传的大 PDF。 */
export const EXAM_MISTAKE_MAX_BYTES = 2 * 1024 * 1024;

export const EXAM_MISTAKE_FORMAT_HINT =
  '每道错题写在「## 知识点：xxx」下面的「### 题目标题」里，'
  + '并用「- 题干：」「- 错因：」「- 正确答案：」列出字段；'
  + '「知识点总览 / 备查 / 复习建议」这类段落不会被当错题。';

const SECTION_RE = /^##\s*知识点\s*[：:]\s*(.+?)\s*$/;
const QUESTION_RE = /^###\s+(.+?)\s*$/;
const FIELD_RE = /^-\s*([^：:]{1,16})\s*[：:]\s*(.*)$/;
const HEADING_RE = /^#{1,6}\s/;
const NO_RE = /第\s*(\d+)\s*题\s*(?:\(\s*(\d+)\s*\))?/;

const FIELD_KEYS = new Map([
  ['学科', 'subject'],
  ['题干', 'questionBody'],
  ['错因', 'wrongReason'],
  ['正确答案', 'answerKey'],
  ['来源作业', 'sourceHomeworkTitle'],
  ['学生答案', 'originalAnswer'],
  ['解题过程', 'studentProcess'],
  ['状态', 'stateLine'],
]);

function questionNoOf(title, source) {
  // 标题里的「第23题(1)」比「来源作业」里的页码更准（后者常是「（第1页）」）。
  const match = NO_RE.exec(title ?? '') ?? NO_RE.exec(source ?? '');
  if (!match) return '';
  return `${match[1]}${match[2] ? `(${match[2]})` : ''}`;
}

function wrongCountOf(stateLine) {
  const match = /错误次数\s*[：:]\s*(\d+)/.exec(stateLine ?? '');
  const value = match ? Number(match[1]) : 1;
  return Number.isFinite(value) && value > 0 ? Math.min(value, 99) : 1;
}

function finalize(entry, meta, knowledgePoint) {
  const fields = entry.fields;
  const questionBody = String(fields.questionBody ?? '').trim();
  // 没有题干的段落不收：存一条空题进错题本，组卷会排出一道空白题，
  // 而且不报错 —— 宁可少收，不可造一道不存在的题。
  if (questionBody === '') return null;
  return {
    title: entry.title,
    subject: String(fields.subject ?? '').trim() || meta.subject,
    questionBody,
    answerKey: String(fields.answerKey ?? '').trim(),
    wrongReason: String(fields.wrongReason ?? '').trim(),
    knowledgePoint,
    questionNo: questionNoOf(entry.title, fields.sourceHomeworkTitle),
    sourceHomeworkTitle:
      String(fields.sourceHomeworkTitle ?? '').trim() || meta.examTitle,
    wrongCount: wrongCountOf(fields.stateLine),
    originalAnswer: String(fields.originalAnswer ?? '').trim(),
    studentProcess: String(fields.studentProcess ?? '').trim(),
  };
}

/**
 * 解析一份试卷错题 MD。
 *
 * 返回 `{ subject, examTitle, items }`。`items` 为空表示「这不是一份试卷错题
 * MD」—— 调用方**必须**响亮失败，不能静默存一个空导入。
 */
export function parseExamMistakes(markdown) {
  const lines = String(markdown ?? '').split(/\r?\n/);
  const meta = { subject: '', examTitle: '' };
  const items = [];
  let knowledgePoint = '';
  let current = null;
  let currentField = '';

  const flush = () => {
    if (!current) return;
    const item = finalize(current, meta, knowledgePoint);
    if (item) items.push(item);
    current = null;
    currentField = '';
  };

  for (const raw of lines) {
    const trimmed = raw.replace(/\u00a0/g, ' ').trim();

    const section = SECTION_RE.exec(trimmed);
    if (section) {
      flush();
      knowledgePoint = section[1].trim();
      continue;
    }
    if (/^##\s/.test(trimmed)) {
      // 「知识点总览 / 本次核对中判定为作答正确… / 复习建议」到此为止。
      // 之后即便还有 ###，也因为 knowledgePoint 为空而不收。
      flush();
      knowledgePoint = '';
      continue;
    }
    const question = QUESTION_RE.exec(trimmed);
    if (question) {
      flush();
      if (knowledgePoint === '') continue;
      current = { title: question[1].trim(), fields: {} };
      currentField = '';
      continue;
    }

    if (!current) {
      if (trimmed.startsWith('# ')) {
        const first = trimmed.slice(2).trim();
        const subject = /[·|]\s*([^（(]+?)\s*(?:[（(]|$)/.exec(first);
        if (subject) meta.subject = subject[1].trim();
        const exam = /[（(](.+?)[）)]\s*$/.exec(first);
        if (exam) meta.examTitle = exam[1].trim();
      }
      const field = FIELD_RE.exec(trimmed);
      if (field && !HEADING_RE.test(trimmed)) {
        const key = field[1].trim();
        const value = field[2].trim();
        if (key === '学科') meta.subject = value;
        if (key === '来源试卷') meta.examTitle = value;
      }
      continue;
    }

    const field = FIELD_RE.exec(trimmed);
    if (field) {
      const key = FIELD_KEYS.get(field[1].trim()) ?? '';
      currentField = key;
      if (key !== '') current.fields[key] = field[2].trim();
      continue;
    }
    // 题干 / 错因可能跨行（选项 A/B/C/D、多行说明），续行接到当前字段后面。
    if (currentField !== '' && trimmed !== '' && !HEADING_RE.test(trimmed)) {
      current.fields[currentField] += `\n${trimmed}`;
    }
  }
  flush();
  return { ...meta, items };
}
