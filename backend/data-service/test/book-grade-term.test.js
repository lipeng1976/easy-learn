import test from 'node:test';
import assert from 'node:assert/strict';

import { toBook as textbookToBook } from '../src/routes/textbook.js';
import { toBook as wordToBook } from '../src/routes/word.js';

/**
 * 教材 / 词表的年级学期（029）必须原样出现在「已导入书」的列表响应里。
 *
 * 这是配置页「年级不匹配预警」的数据基础：列表不带回 grade/term，
 * 预警永远拿不到值。判据可证伪 —— 把 toBook 里的 grade/term 去掉，
 * 下面两条断言立刻失败。
 */

test('教材 toBook 带出 grade/term', () => {
  const row = {
    id: 'tb_1',
    student_id: 's1',
    subject: '数学',
    title: '七上数学',
    source: 'ima',
    source_media_id: 'm1',
    unit_count: 20,
    grade: '七',
    term: '上',
    created_at: null,
  };
  const book = textbookToBook(row);
  assert.equal(book.grade, '七', '书的年级必须透传');
  assert.equal(book.term, '上', '书的学期必须透传');
});

test('教材 toBook 老数据 grade/term 为空串（不报错、不填默认值）', () => {
  const row = {
    id: 'tb_2',
    student_id: 's1',
    subject: '数学',
    title: 'x',
    source: 'ima',
    source_media_id: '',
    unit_count: 0,
    created_at: null,
  };
  const book = textbookToBook(row);
  assert.equal(book.grade, '', '029 之前的书年级留空');
  assert.equal(book.term, '');
});

test('词表 toBook 带出 grade/term', () => {
  const row = {
    id: 'wb_1',
    title: '七上词表',
    unit_count: 10,
    word_count: 200,
    source_path: '',
    created_at: null,
    source_media_id: 'm',
    grade: '七',
    term: '上',
  };
  const book = wordToBook(row);
  assert.equal(book.grade, '七');
  assert.equal(book.term, '上');
});
