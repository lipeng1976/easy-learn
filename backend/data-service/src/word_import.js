/**
 * 教材词表 MD 解析器（`教学资料/Wordlist/words-*.md`）。
 *
 * ⚠️ **不复用 `reading_import.js`**：那边是针对 MinerU 故事书的另一套语义
 * （`Lesson N` 三段式、词条带编号、音标必须方括号），拿它解析裸
 * `hello | həˈləʊ | 你好；喂` 会一条也认不出来，而且是**静默**认不出来。
 * 两套解析器各管一种 MD，不许互相兜底 —— 一个语义只许一处定义。
 *
 * ## 格式（`doc/word-checkin-design.md` §2.2 是唯一口径）
 *
 * ```
 * # 人教版七年级上册 单词表         ← 书名（可省，缺省取文件名）
 * ## Unit 1 My name's Gina          ← 单元，`##` 出现顺序即进度顺序
 * hello | həˈləʊ | 你好；喂
 * meet || 遇见；结识                  ← 音标可空
 * ```
 *
 * ## 坏行策略
 *
 * 坏行记 `warning` 并跳过，**不整单失败**；一条都没解析出来才由调用方拒绝导入
 * （存一本 0 词的书，页面会显示「今日 0 题」却什么都不说，比报错更难查）。
 *
 * ## 与客户端的口径同步
 *
 * `normalizeWord` / `primaryMeaning` 在客户端 `lib/utils/word_normalizer.dart`
 * 有一份同规则实现（本地缓存去重 / 选项比对要用）。两边测试共用同一组
 * golden vectors，**改规则必须同时改两边样本**，否则漂移会变成静默错题。
 */

/** 中文字符（基本区 + 兼容区）。英文段里出现即认为这行不是词条。 */
const HAN = /[\u3400-\u9FFF\uF900-\uFAFF]/;

/**
 * 词性前缀：`n. ` / `v ` / `adj. 好的` …… 只删开头那一个。
 * 末尾允许「直接到串尾」：整行只有 `n.` 时也算清洗干净 → 空释义 → 记坏行跳过，
 * 否则会把 `n.` 本身当成中文答案出成一道无人能答对的题。
 */
const POS_PREFIX = /^(?:n|v|adj|adv|prep|conj|pron|num|art|int)\.?(?:\s+|$)/i;

/** 多义项分隔符。只取首义，因为「一词多义」出成选择题会有多个正确答案。 */
const MEANING_SPLIT = /[；;，,]/;

/** trim → 小写 → 去首尾标点。ASCII 集合是刻意的：Dart / JS 两边行为完全一致。 */
export function normalizeWord(word) {
  return String(word ?? '')
    .trim()
    .toLowerCase()
    .replace(/^[^\da-z]+/, '')
    .replace(/[^\da-z]+$/, '');
}

/** 取首义并去掉词性前缀。教材常见「n. 名字；名称」，答案应是「名字」。 */
export function primaryMeaning(meaning) {
  return String(meaning ?? '')
    .split(MEANING_SPLIT)[0]
    .trim()
    .replace(POS_PREFIX, '')
    .trim();
}

/** 去掉 `.md` 后缀与 `words-` 前缀，供缺省书名用。 */
export function titleFromFileName(fileName, fallback = '未命名词表') {
  const one = String(fileName ?? '').trim();
  if (one === '') return fallback;
  return one
    .replace(/\.(md|markdown)$/i, '')
    .replace(/^words-/, '')
    .trim() || fallback;
}

/**
 * 解析一份词表 MD。
 *
 * @param {string} markdown UTF-8 文本（调用方负责从 bytes 解码）
 * @param {{title?: string}} [options] 缺省书名（一般是文件名）
 * @returns {{title: string, units: Array<{unit:string, unitOrder:number,
 *   entries:Array<{word:string, phonetic:string, meaning:string,
 *   primaryMeaning:string, normalizedWord:string, sortNo:number}>}>,
 *   warnings: Array<{line:number, reason:string, raw:string}>, rawLineCount: number}}
 */
export function parseWordlist(markdown, options = {}) {
  const lines = String(markdown ?? '').split(/\r?\n/);
  const warnings = [];
  const units = [];
  // `options.title` 是**兜底**（一般是文件名）；MD 里的一级标题优先。
  const fallbackTitle = String(options.title ?? '').trim();
  let mdTitle = '';
  let current = null;
  let sortNo = 0;

  const warn = (line, reason, raw) => {
    warnings.push({ line, reason, raw: String(raw).slice(0, 120) });
  };

  lines.forEach((raw, index) => {
    const line = String(raw).trim();
    const lineNo = index + 1;
    if (line === '') return;

    // `> 单元数：N …` 统计行、以及引用块：导入器忽略。
    if (line.startsWith('>')) return;

    if (line.startsWith('# ')) {
      const heading = line.slice(2).trim();
      if (mdTitle === '' && heading !== '') mdTitle = heading;
      return;
    }

    if (/^##\s+/.test(line)) {
      const unit = line.replace(/^##\s+/, '').trim();
      current = { unit, unitOrder: units.length + 1, entries: [] };
      units.push(current);
      sortNo = 0;
      return;
    }

    // 其余 `#` 开头（如 `###`、无空格的 `#标题`）一律忽略：提示词里没有这种行。
    if (line.startsWith('#')) return;

    // 无竖线 = 说明性文字，静默忽略（MD 里常有「以下为单词表」这类句子）。
    if (!line.includes('|')) return;

    const parts = line.split('|').map((p) => p.trim());
    if (parts.length !== 3) {
      warn(lineNo, 'bad_line', line);
      return;
    }

    const [word, phonetic, meaning] = parts;
    // 英文段含中文 = 表头 / 例句，静默忽略，不算坏行。
    if (HAN.test(word)) return;
    if (word === '' || meaning === '') {
      warn(lineNo, word === '' ? 'empty_word' : 'empty_meaning', line);
      return;
    }

    const normalizedWord = normalizeWord(word);
    const firstMeaning = primaryMeaning(meaning);
    if (normalizedWord === '' || firstMeaning === '') {
      warn(lineNo, 'unusable_entry', line);
      return;
    }

    if (!current) {
      warn(lineNo, 'no_unit', line);
      current = { unit: '默认单元', unitOrder: 1, entries: [] };
      // ⚠️ 放在最前：无单元的词条本来就在文件开头，进度顺序不能倒过来。
      units.unshift(current);
    }

    if (current.entries.some((e) => e.normalizedWord === normalizedWord)) {
      warn(lineNo, 'duplicate_word', line);
      return;
    }

    sortNo += 1;
    current.entries.push({
      word,
      phonetic,
      meaning,
      primaryMeaning: firstMeaning,
      normalizedWord,
      sortNo,
    });
  });

  // 「默认单元」插到最前时，后面单元的 unitOrder 要重编号，否则会出现 1,1,2…
  units.forEach((unit, i) => { unit.unitOrder = i + 1; });

  return {
    title: mdTitle || fallbackTitle || '未命名词表',
    units,
    warnings,
    rawLineCount: lines.length,
  };
}

/** 扁平化成写库用的行（顺序 = 单元顺序 → 单元内 sort_no）。 */
export function flattenEntries(parsed) {
  const rows = [];
  for (const unit of parsed.units) {
    for (const entry of unit.entries) {
      rows.push({ ...entry, unit: unit.unit, unitOrder: unit.unitOrder });
    }
  }
  return rows;
}
