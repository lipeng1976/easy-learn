/**
 * 把一本 MinerU 转出来的 MD 书切成「课」。
 *
 * ## 为什么要专门一个模块，而不是在路由里写几行正则
 *
 * 这本书的结构**不可靠**，这是从真实文件里量出来的，不是假设：
 *
 *   · `Lesson N` 的标题层级在 `#` 和 `##` 之间漂移（第 2、5、8…课是 `#`，
 *     其余是 `##`）。只匹配 `^## Lesson` 会漏掉 37 课 —— 而且漏掉的课
 *     不会报错，它们会**并进上一课**，症状是「某几课特别长、少了几课」。
 *   · 英文标题同样会变成 `#`（第 4 课的 `Life Is Like a Cafeteria`）。
 *   · 词条编号有时带 `##`（`## 4. end [end]`），有时是裸行（`2. die [daɪ]`）。
 *   · 一条词条里的换行会被 MinerU 吃掉，`联想记忆` / `典型例句` 直接粘在
 *     释义后面。
 *
 * 所以这里**不认标题层级，只认文本**：切课看 `Lesson <数字>`，切段看
 * 「美文赏析 / 词汇详解 / 参考阅读」三个固定词。层级只用来判断「这一行是不是
 * 标题」，不用来判断「是哪种标题」。
 *
 * ## 体积：先剥图
 *
 * 原始 MD 3.4MB 里 93% 是 311 张 base64 装饰小图标（每张两三行字符）。
 * 不剥掉它们，96 课加起来能把一次请求撑到几十兆 —— 而它们对阅读毫无用处
 * （都是页眉页脚的花边）。剥完正文约 230KB，一次全量入库毫无压力。
 *
 * ## 纯函数
 *
 * 这里不碰数据库、不碰网络，输入字符串输出对象。切课规则漂移过一次
 * （见上），必须有能在毫秒级跑完的单测盯着。
 */

/** 课与课的分界：`# Lesson 12` / `## Lesson 12` / `### Lesson 12` 都算。 */
const LESSON_HEADING = /^#{1,6}\s*Lesson\s+(\d+)\b.*$/i;

/** 课内的三段。**这是书的固定结构，不是 Markdown 语义**，所以按字面匹配。 */
const SECTION_RE = /^#{1,6}\s*(美文赏析|词汇详解|参考阅读)\s*$/;

/** 任意层级的标题行（用于取英文标题 / 中文标题，以及剥掉词条的 `##`）。 */
const ANY_HEADING = /^#{1,6}\s*(.*)$/;

/**
 * 词条起始：`1. young …`，可带标题前缀。
 *
 * ⚠️ `#{0,6}` 而不是 `#{1,6}`：MinerU 把**第一条**词条认成标题（带 `##`），
 * 后面几条当成普通段落（裸行 `2. die [daɪ] …`）。只认带 `#` 的那种，
 * 一课就只剩第一个词条 —— 而这件事不会报错，只是词汇表「莫名其妙只有一条」。
 */
const VOCAB_ENTRY = /^#{0,6}\s*(\d+)[.、]\s*(.+)$/;

/** 词条内部的子块标记。遇到它表示释义到此结束。 */
const VOCAB_DETAIL = /^(典型例句|最常用法|联想记忆|常用搭配|扩展记忆)/;

/** 页脚噪声：扫描版每页底部都有这四个字，不是正文。 */
const FOOTER_NOISE = /^读书笔记$/;

/** 词条数量上限：一本书里出现几百条说明匹配失控了，宁可留着原始文本。 */
const MAX_VOCAB = 50;

/**
 * 剥掉所有图片。
 *
 * `data:` 的 base64 是主要目标；外链图片一并去掉 —— 客户端不渲染图片，
 * 留着只会让正文里多出一串没人看得懂的 `![pic](https://…)`。
 */
export function stripImages(markdown) {
  return String(markdown ?? '').replace(/!\[[^\]]*\]\([^)]*\)/g, '');
}

/**
 * 按 `Lesson N` 切课。
 *
 * 返回的 `raw` **不含**课标题行本身。切不出任何课返回空数组 ——
 * 调用方据此明确拒绝导入，而不是存一本 0 课的书进去。
 */
export function splitLessons(markdown) {
  const lines = stripImages(markdown).split(/\r?\n/);
  const lessons = [];
  let current = null;

  for (const line of lines) {
    const m = LESSON_HEADING.exec(line.trim());
    if (m) {
      if (current) lessons.push(current);
      current = { lessonNo: Number(m[1]), lines: [] };
      continue;
    }
    if (current) current.lines.push(line);
  }
  if (current) lessons.push(current);

  return lessons.map((lesson) => ({
    lessonNo: lesson.lessonNo,
    raw: lesson.lines.join('\n'),
  }));
}

/** 中文字符（译文段判定用）。 */
const CJK_CHAR = /[\u4e00-\u9fff]/;

/**
 * 这一行像不像「译文段的标题」。
 *
 * 典型值：`## 不要等到`、`## 浅水里的鱼兄弟`。排除条件都是为了不把词条
 * 本身误判进来：词条以数字开头、带音标方括号。
 */
function looksLikeChineseHeading(line) {
  const m = ANY_HEADING.exec(line.trim());
  if (!m) return false;
  const text = m[1].trim();
  if (text === '' || /^\d+[.、]/.test(text)) return false;
  if (/\[[^\]]*\]/.test(text)) return false;
  const cjk = (text.match(/[\u4e00-\u9fff]/g) ?? []).length;
  return cjk >= 2 && cjk / text.length > 0.6;
}

/**
 * 把一课切成三段。
 *
 * 没找到分节词时，整课都算正文 —— 有的课（尤其非本书来源）可能没有
 * 「词汇详解」，那不该让这一课变成空课。
 *
 * ## 第 62 课那种「缺参考阅读标签」的课
 *
 * 这本书里有一课（62）的 `## 参考阅读` 没被识别出来，中文标题
 * `## 不要等到` 直接跟在词汇表后面 —— 于是一整段中文译文会被当成第 4 个
 * 词条的明细，`translation` 为空，学生在译文区看到一片空白。
 *
 * 所以译文段为空时，回头在词汇段里找「第一个像中文标题的行」，从那里
 * 切开。判据放在 [looksLikeChineseHeading] 里，只认「中文占多数且不是词条」。
 */
function splitSections(raw) {
  const sections = { article: [], vocab: [], translation: [] };
  let bucket = 'article';
  for (const line of raw.split(/\r?\n/)) {
    const m = SECTION_RE.exec(line.trim());
    if (m) {
      bucket = m[1] === '美文赏析' ? 'article' : m[1] === '词汇详解' ? 'vocab' : 'translation';
      continue;
    }
    sections[bucket].push(line);
  }

  if (sections.translation.every((line) => line.trim() === '')) {
    const at = sections.vocab.findIndex(looksLikeChineseHeading);
    if (at >= 0) {
      sections.translation = sections.vocab.slice(at);
      sections.vocab = sections.vocab.slice(0, at);
    }
  }

  return sections;
}

/**
 * 从一段里取出「标题 + 正文」。
 *
 * 标题只认**第一个非空的标题行**，且它后面还有内容 —— 最后一行是标题
 * 意味着这只是一个孤立的小标题，当标题用会把正文丢掉。
 */
function takeTitledBody(lines) {
  const cleaned = lines
    .map((line) => line.trim())
    .filter((line) => line !== '' && !FOOTER_NOISE.test(line));

  let title = '';
  let start = 0;
  const first = cleaned[0];
  if (first !== undefined) {
    const m = ANY_HEADING.exec(first);
    if (m) {
      title = m[1].trim();
      start = 1;
    }
  }

  const bodyLines = cleaned.slice(start).filter((line) => !ANY_HEADING.test(line));
  return { title, body: bodyLines.join('\n').replace(/\n{3,}/g, '\n\n').trim() };
}

/**
 * 解析词汇表。
 *
 * 只取「编号 + 词 + 音标 + 释义」，`典型例句 / 最常用法 / 联想记忆` 收进
 * `detail`。**不试图把它们拆成结构化字段**：原书排版太松（例句中英文混排、
 * 用法一行塞五条），再拆下去必然出错，而出错的地方是「学生看到的释义」。
 */
function parseVocabulary(lines) {
  const entries = [];
  let current = null;

  const push = () => {
    if (!current) return;
    const { meaning, detail } = splitMeaning(current.raw);
    entries.push({
      no: current.no,
      word: current.word,
      phonetic: current.phonetic,
      meaning,
      detail: detail.join('\n').trim(),
    });
    current = null;
  };

  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (line === '' || FOOTER_NOISE.test(line)) continue;

    const m = VOCAB_ENTRY.exec(line);
    if (m) {
      push();
      const head = m[2].trim();
      // `young [jʌŋ] adj …` → word=young / phonetic=[jʌŋ] / 释义留在 raw 里
      const bracket = /^([^[]*?)\s*\[([^\]]*)\]\s*(.*)$/.exec(head);
      current = {
        no: Number(m[1]),
        word: bracket ? bracket[1].trim() : head.split(/\s+/)[0],
        phonetic: bracket ? `[${bracket[2].trim()}]` : '',
        raw: [bracket ? bracket[3] : head],
      };
      continue;
    }

    if (current) current.raw.push(line);
  }
  push();

  return entries.slice(0, MAX_VOCAB);
}

/** 把一条词条的行切成「释义」与「明细」。 */
function splitMeaning(lines) {
  const meaning = [];
  const detail = [];
  let inDetail = false;
  for (const line of lines) {
    if (!inDetail && VOCAB_DETAIL.test(line)) inDetail = true;
    if (inDetail) detail.push(line);
    else meaning.push(line);
  }
  // 同一行里粘着 `典型例句`（MinerU 丢换行的产物）：在释义里就地切开。
  if (detail.length === 0 && meaning.length > 0) {
    const joined = meaning.join(' ');
    const at = joined.search(/典型例句|最常用法|联想记忆|常用搭配|扩展记忆/);
    if (at > 0) {
      return {
        meaning: joined.slice(0, at).trim(),
        detail: [joined.slice(at).trim()],
      };
    }
  }
  return {
    meaning: meaning.join(' ').replace(/\s{2,}/g, ' ').trim(),
    detail,
  };
}

/**
 * 解析一课。
 *
 * `body` 为空时不编造内容 —— 返回空串，由调用方统计「解析不全的课」。
 * 宁可让家长看到「这一课没读出来」，也不要把词汇表当成正文塞进去。
 */
export function parseLesson({ lessonNo, raw }) {
  const sections = splitSections(raw);
  const article = takeTitledBody(sections.article);
  const reference = takeTitledBody(sections.translation);
  const vocabulary = parseVocabulary(sections.vocab);

  return {
    lessonNo,
    title: article.title,
    titleZh: reference.title,
    body: article.body,
    translation: reference.body,
    vocabulary,
    charCount: article.body.length,
  };
}

/** 书名兜底：MD 开头的第一个一级标题。取不到就用调用方给的名字。 */
function guessBookTitle(markdown, fallback) {
  for (const line of String(markdown ?? '').split(/\r?\n/).slice(0, 40)) {
    const m = /^#\s+(.+)$/.exec(line.trim());
    if (m && !LESSON_HEADING.test(line.trim()) && !SECTION_RE.test(line.trim())) {
      return m[1].trim();
    }
  }
  return fallback;
}

/**
 * 解析整本书。
 *
 * 返回 `{ title, lessons, skipped }`：
 *   · `lessons` 按课号升序，课号重复时保留**第一次**出现的那一份
 *     （MinerU 偶尔把目录页也识别成课，重复课号一律视为噪声）；
 *   · `skipped` 是「有课号但正文为空」的课号，供导入结果如实回报。
 */
export function parseBook(markdown, { title = '' } = {}) {
  const text = String(markdown ?? '');
  const rawLessons = splitLessons(text);

  const byNo = new Map();
  for (const lesson of rawLessons) {
    if (byNo.has(lesson.lessonNo)) continue;
    byNo.set(lesson.lessonNo, lesson);
  }

  const lessons = [];
  const skipped = [];
  for (const lessonNo of [...byNo.keys()].sort((a, b) => a - b)) {
    const parsed = parseLesson(byNo.get(lessonNo));
    if (parsed.body === '') {
      skipped.push(lessonNo);
      continue;
    }
    lessons.push(parsed);
  }

  return {
    title: guessBookTitle(text, title) || title || '未命名书籍',
    lessons,
    skipped,
    // 原始文件里出现过几个课号（含重复），用于发现「切分把课切重了」。
    rawLessonCount: rawLessons.length,
  };
}
