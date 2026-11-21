/**
 * ⚠️ LaTeX 转义保护：解析「模型序列化成字符串的结构」之前必须过这道闸。
 *
 * ── 事故（2026-10-21，家长端复习资料截图坐实）──────────────────────────
 * 百炼的 qwen3-vl 会把 `items` 数组**序列化成字符串**（见 `schema.js` 的
 * `repairStringifiedStructures`）。解这层字符串时用 `JSON.parse` ——
 * 如果模型在里面对 LaTeX **少转义一层**（写 `\frac` 而不是 `\\frac`）：
 *
 *   `\f` 是合法 JSON 转义（换页符 0x0C）→ 解析**不报错**，`frac` 变 `rac`
 *   `\t` 是合法 JSON 转义（制表符 0x09）→ `times` 变 `imes`
 *   `\n` `\r` `\b` 同理，都是「看不见但内容坏了」。
 *   （`\u` 少转义反而会解析失败，因为 `\u` 后面要跟 4 位十六进制 —— 坏得明显。）
 *
 * 症状：错因里印出 `rac{2}{5}`、`\imes4`，看起来像「模型写错公式」，
 * 实际是**我们这层把内容静默弄坏了**。典型「静默失败」：没有报错，
 * 只有数据里多出不可见控制字符 —— 用 `encode(convert_to(...))` 的 hex
 * 才抓到 `0c`（换页符）。
 *
 * ── 修法 ────────────────────────────────────────────────────────────────
 * 解析前扫描原文：`\` 后面跟 `b/f/n/r/t` 且**再后面是字母**（LaTeX 命令的
 * 形状，如 `\frac`、`\times`、`\neq`、`\right`）→ 把反斜杠补成双份。
 * `\u` 后面不是 4 位十六进制而是字母（`\underbrace`）→ 同样补。
 *
 * 为什么不会误伤正常转义的数据：正常 JSON 里 LaTeX `\frac` 写作 `\\frac`，
 * 扫描器看到 `\\` 成对先跳过，剩下的 `frac` 是普通字符 —— 一个字节都不动。
 * 真正的制表符转义 `\t` 后面紧跟英文字母的情形（`\tfoo`）在本业务字段里
 * 不存在；宁可多补一次反斜杠，也不让公式静默变残废。
 */

export function protectLatexEscapes(text) {
  if (typeof text !== 'string' || !text.includes('\\')) return text;

  let out = '';
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch !== '\\') {
      out += ch;
      continue;
    }

    const next = text[i + 1];
    if (next === '\\') {
      // 成对的反斜杠（JSON 转义的 `\` 或 LaTeX 换行 `\\`）：原样保留一对。
      out += '\\\\';
      i += 1;
      continue;
    }

    const after = text[i + 2];
    const looksLikeCommand = typeof after === 'string' && /[A-Za-z]/.test(after);

    if (next !== undefined && 'bfnrt'.includes(next) && looksLikeCommand) {
      // `\frac` / `\times` / `\neq` …：少转义，补成 `\\frac`。
      out += '\\\\' + next;
      i += 1;
      continue;
    }

    if (next === 'u' && looksLikeCommand && !/^[0-9a-fA-F]{4}/.test(text.slice(i + 2, i + 6))) {
      // `\underbrace` 这类（`\u` 后面不是合法十六进制）：同样补。
      out += '\\\\u';
      i += 1;
      continue;
    }

    out += ch;
  }
  return out;
}
