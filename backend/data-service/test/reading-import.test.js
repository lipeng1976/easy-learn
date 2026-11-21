import assert from 'node:assert/strict';
import test from 'node:test';

import { parseBook, parseLesson, splitLessons, stripImages } from '../src/reading_import.js';

/**
 * 切课解析器。
 *
 * ## 这里压的全是「真实文件里的怪」，不是想象出来的格式
 *
 * 样本逐字取自 `感动世界的文字 英语小故事大全集 基础篇.md`（MinerU 输出，
 * 3.4MB / 96 课 / 311 张 base64 小图）。四条症状各对应一个真实发生过的
 * 失效方式，且**全部是静默的** —— 不会抛错，只会让书少几课、词汇表少几条：
 *
 *   ① `Lesson N` 的层级在 `#` 与 `##` 之间漂移（第 2、5 课是 `#`）；
 *   ② **第一条**词条带 `##`、后面几条是裸行（`2. die [daɪ] …`）；
 *   ③ 第 62 课没有 `## 参考阅读` 标签，中文标题直接跟在词汇表后面；
 *   ④ 扫描版每页底部有「读书笔记」，每张装饰小图是几十 KB 的 base64。
 */

const IMG = '![](data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCABaAGgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAMAAAAAAQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD9/KKKazBVyTgUAPprMEUsxwB1NZWoeILWxt3kMinb15rzDxR8SLiSQxWkuwA9VpN2E2kelal4n03T7d3a4UuowQPWuMm8f3l1OY7OAsh4yp6e9eYT61LLMzSz7ixyc1e0/xBFbMSz84qb3DmR6voVxqc9z5t3KAuOAaK4nQvGiRXWLggxH9KKLhc+laKKKoYUUUUAFFFFABRRRQAA//Z)';

const LESSON_1 = `## Lesson 1

${IMG}

## 美文赏析

## Poor or Rich

One day a rich father took his young son on a trip to the country.

"And what did you learn?" the father asked.

## 词汇详解

1. spend [spend] n 预算；花销 v 花费；浪费

典型例句 Obviously, we don't want to spend too much money.
很明显，我们不想花太多的钱。

联想记忆 take v 拿；取；花费

2. reach [riːtʃ] 到达；伸出；达成 n. 范围典型例句 They didn't reach the border until after dark.
他们直到天黑才到达边境。

## 参考阅读

## 贫富的真意

一天，一位富有的父亲带着他的小儿子去乡下旅行。

读书笔记
`;

const LESSON_2 = `# Lesson 2

${IMG}

## 美文赏析

## Three Fish Brothers in Shallow Water

Three fish lived in the sea. When they were young, their parents died.

## 词汇详解

## 1. young [jʌŋ] adj 年轻的；没有经验的 n 青年人

典型例句 Cities have a powerful effect on young people.

联想记忆 youth n 青年时期

2. die [daɪ] 死；枯竭；消失；渴望

最常用法 die out 灭绝

3. danger ['deɪndʒə(r)] 危险

## 参考阅读

## 浅水里的鱼兄弟

有三条鱼生活在大海里。在他们小的时候，他们的父母就死去了。

读书笔记
`;

/**
 * 第 62 课的真实形态：**没有 `## 参考阅读` 这一行**，中文标题直接出现。
 * 之前这段会被当成第 4 个词条的明细，译文区一片空白。
 */
const LESSON_62 = `## Lesson 62

## 美文赏析

## Do Not Wait ...

Do not wait ...

Don't wait for a smile to be nice ...

## 词汇详解

1. wait [weit] v. 等；等待 n. 等待；等候

典型例句 He kept us waiting for ages.

2. share [ʃeə(r)] 分；分配；共有

## 不要等到

不要等到……

不要等到了一个笑容才面露慈善

记住:友谊像醇酒，越久越浓。

读书笔记
`;

const BOOK = [LESSON_1, LESSON_2, LESSON_62].join('\n');

test('剥图：base64 与外链图片都不进正文', () => {
  const out = stripImages(`${IMG}\n\n![外链](https://example.com/a.png)\n\n正文`);
  assert.equal(out.includes('base64'), false);
  assert.equal(out.includes('example.com'), false);
  assert.equal(out.trim(), '正文');
});

test('切课：`#` 与 `##` 两种层级都能切（只认 `##` 会漏课）', () => {
  const lessons = splitLessons(BOOK);
  assert.deepEqual(lessons.map((l) => l.lessonNo), [1, 2, 62]);

  // 反面判据：只认 `## Lesson` 会少掉第 2 课，而它会被并进第 1 课 ——
  // 症状是「第 1 课特别长、第 2 课不见了」，不会报任何错。
  const onlyH2 = splitLessons(BOOK.replace(/^# Lesson 2$/m, '### NOT-A-LESSON'));
  assert.deepEqual(onlyH2.map((l) => l.lessonNo), [1, 62]);
});

test('解析一课：英文标题 / 正文 / 中文标题 / 译文各自归位', () => {
  const [raw] = splitLessons(LESSON_2);
  const lesson = parseLesson(raw);
  assert.equal(lesson.lessonNo, 2);
  assert.equal(lesson.title, 'Three Fish Brothers in Shallow Water');
  assert.equal(lesson.titleZh, '浅水里的鱼兄弟');
  assert.match(lesson.body, /^Three fish lived in the sea/);
  // 正文里不能混进词汇表或译文 —— 混了就变成「一篇文章读起来像三份文档」。
  // ⚠️ 判据不能只看单词：正文第 2 句本来就有 `young`（"When they were young"）。
  // 要认的是**词条行的形状**（音标 + 词性），那才是词汇表独有的东西。
  assert.equal(lesson.body.includes('[jʌŋ]'), false);
  assert.equal(lesson.body.includes('adj 年轻的'), false);
  assert.equal(lesson.body.includes('有三条鱼'), false);
  assert.match(lesson.translation, /^有三条鱼生活在大海里/);
  // 「读书笔记」是扫描页脚，不是正文。
  assert.equal(lesson.translation.includes('读书笔记'), false);
});

test('词汇：裸编号词条（无 `##`）也要认出来', () => {
  const [raw] = splitLessons(LESSON_2);
  const { vocabulary } = parseLesson(raw);
  assert.deepEqual(vocabulary.map((v) => v.word), ['young', 'die', 'danger']);
  assert.equal(vocabulary[0].phonetic, '[jʌŋ]');
  assert.equal(vocabulary[0].meaning, 'adj 年轻的；没有经验的 n 青年人');
  assert.match(vocabulary[0].detail, /典型例句/);

  // 反面判据：只认带 `#` 的词条，一课只剩第一个 —— 而不报错。
  const [raw1] = splitLessons(LESSON_1);
  const v1 = parseLesson(raw1).vocabulary;
  assert.deepEqual(v1.map((v) => v.word), ['spend', 'reach']);
  assert.equal(v1[1].phonetic, '[riːtʃ]');
});

test('缺 `参考阅读` 标签的课：从词汇段里捞回译文', () => {
  const [raw] = splitLessons(LESSON_62);
  const lesson = parseLesson(raw);
  assert.equal(lesson.titleZh, '不要等到');
  assert.match(lesson.translation, /^不要等到……/);
  // 那一整段中文不该留在最后一个词条的明细里。
  assert.equal(lesson.vocabulary.at(-1).detail.includes('不要等到了一个笑容'), false);
  assert.deepEqual(lesson.vocabulary.map((v) => v.word), ['wait', 'share']);
});

test('整本：课号有序、重复课号只留第一份、空正文的课被如实报出', () => {
  // 目录页被识别成 `Lesson 1` 的形态：同一个课号出现两次。
  const withDup = `${LESSON_1}\n## Lesson 1\n\n## 美文赏析\n\n目录占位\n\n${LESSON_2}`;
  const book = parseBook(withDup, { title: '感动世界的文字' });
  assert.equal(book.rawLessonCount, 3);
  assert.deepEqual(book.lessons.map((l) => l.lessonNo), [1, 2]);
  // 保留第一次出现的那一份（有正文的那份），不是后者覆盖。
  assert.match(book.lessons[0].body, /^One day a rich father/);
});

test('整本：没有 `Lesson N` 标题时不编造课', () => {
  const book = parseBook('# 某本书\n\n只有一段正文。\n', { title: '某本书' });
  assert.deepEqual(book.lessons, []);
  assert.equal(book.title, '某本书');
});

test('书名：优先用 MD 首行一级标题，取不到才退回调用方给的', () => {
  const withHead = `# 英语小故事大全集\n\n${LESSON_1}`;
  assert.equal(parseBook(withHead, { title: '文件名' }).title, '英语小故事大全集');
  assert.equal(parseBook(LESSON_1, { title: '文件名' }).title, '文件名');
});
