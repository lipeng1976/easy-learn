#!/usr/bin/env node
/**
 * 把「SQL 模板字符串的注释里出现的反引号」挑出来。
 *
 * ## 为什么需要这个
 *
 * 项目里的种子 SQL 都写成 JS 模板字符串（``const S = `insert ...`;``），
 * 而注释里一旦出现 markdown 代码样式的反引号，那个反引号会**提前闭合模板**，
 * 后面的 SQL 文本被当成 JS 代码 —— 报错是
 * 「SyntaxError: Unexpected identifier 'xxx'」，指向的是**注释里的某个词**，
 * 完全看不出「是反引号的问题」。
 *
 * 2026-09-22 这一天我在同一个文件上踩了三次（每次都是写注释时顺手加了反引号）。
 * 靠记性解决不了 —— 所以做成一条可以随时跑的检查。
 *
 * ## 判定方式（第二版 —— 第一版误报太多）
 *
 * 第一版的做法是「在模板字符串内部数反引号，偶数个就报」。
 * 它把 `${...}` 插值里的反引号也报了出来（`log(\`… ${x} …\`)` 那种嵌套是合法的），
 * 一个仓库报了 27 处、其中 23 处是误报 —— **误报多的检查等于没有检查**，
 * 因为人会养成「忽略它」的习惯。
 *
 * 第二版收窄到**只报一种形态**：
 *   在**模板字符串内部**的、**以 SQL 注释（`--`）开头**的行里出现的反引号。
 *
 * 这条判据精确且零误报：SQL 注释里的反引号**永远不会是语法的一部分**，
 * 它只可能是 markdown 样式跑进了 SQL。而正是这种行在实际中引发过三次事故。
 *
 * 跑法：`node scripts/check-sql-templates.mjs`（也已挂进 npm test 的前置）。
 */
import { readFileSync } from 'node:fs';
import { readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');

/** 递归收集 .js / .mjs。 */
async function collect(dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name.startsWith('.pgdata')) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...(await collect(full)));
    else if (/\.(m?js)$/.test(entry.name)) out.push(full);
  }
  return out;
}

/** 去掉行内的转义反引号，剩下的反引号才是「语法意义上」的。 */
const countTicks = (line) => (line.replace(/\\`/g, '').match(/`/g) ?? []).length;

const problems = [];

for (const file of await collect(root)) {
  const lines = readFileSync(file, 'utf8').split('\n');
  let inTemplate = false;
  lines.forEach((line, i) => {
    const ticks = countTicks(line);
    if (!inTemplate) {
      // 奇数个 → 这一行开了模板，且没在同一行关掉。
      if (ticks % 2 === 1) inTemplate = true;
      return;
    }

    // 在模板字符串里。只关心**SQL 注释行**里的反引号 ——
    // 那种反引号不可能是语法的一部分，只会提前闭合模板。
    const trimmed = line.trim();
    if (trimmed.startsWith('--') && ticks > 0) {
      problems.push({ file, line: i + 1, text: trimmed });
    }

    // 维护状态：奇数个反引号 = 这一行关掉了模板。
    if (ticks % 2 === 1) inTemplate = false;
  });
}

if (problems.length === 0) {
  console.log('✓ SQL 模板字符串里没有多余的反引号');
  process.exit(0);
}

console.error(`✗ 找到 ${problems.length} 处「模板字符串内部的反引号」：\n`);
for (const p of problems) {
  console.error(`  ${path.relative(root, p.file)}:${p.line}`);
  console.error(`    ${p.text}`);
}
console.error(
  '\n这些反引号会提前闭合模板字符串，报错是「SyntaxError: Unexpected identifier」。'
    + '\n处置：把 SQL 注释里的 markdown 反引号去掉（用「」或直接写词）。',
);
process.exit(1);
