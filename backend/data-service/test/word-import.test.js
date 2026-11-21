import assert from 'node:assert/strict';
import test from 'node:test';

import { encryptCredential } from '../src/ima_repository.js';
import { flattenEntries, normalizeWord, parseWordlist, primaryMeaning, titleFromFileName } from '../src/word_import.js';

/**
 * 英语单词打卡 · 词源与导入判据。
 *
 * 全部用假 client / 假 fetch，不碰真库也不联网（真库 025 迁移另由
 * `scripts/run-tests.mjs` 起库跑，路由注册由 contract.test.js 守）。
 *
 * ⚠️ 下面这组 golden vectors 与 `test/word_normalizer_test.dart` 是**同一份样本**：
 * 服务端与客户端各有一份同规则实现，改规则必须两边同步改，否则漂移会变成
 * 「选项里出现两个正确答案」这类静默错题。
 */

const SECRET = 'test-secret-0123456789abcdefghijklmn';

const VALID_MD = [
  '# 人教版七年级上册 单词表',
  '',
  "## Unit 1 My name's Gina",
  'hello | həˈləʊ | 你好；喂',
  'name | neɪm | n. 名字；名称',
  'nice | naɪs | 令人愉快的；宜人的',
  'meet || 遇见；结识',
  '',
  '## Unit 2 This is my sister',
  'sister | ˈsɪstə(r) | 姐；妹',
  'mother | ˈmʌðə(r) | 母亲；妈妈',
  '',
  // 半角竖线的引用行也要被忽略：提示词产出的统计行用全角 `｜`，
  // 但人工整理时很容易写成半角 —— 不忽略它就会混进一条假词条。
  '> note | ignore | 忽略',
  '> 单元数：2 ｜ 词条数：6 ｜ 跳过坏行：0 ｜ 建议文件名：words-人教版七上.md',
].join('\n');

// ===== 1. 清洗口径（golden vectors，与 Dart 侧同一份）=====

test('normalizeWord：去空白 / 小写 / 去首尾标点，内部撇号保留', () => {
  assert.equal(normalizeWord('  Hello. '), 'hello');
  assert.equal(normalizeWord("It's"), "it's");
  assert.equal(normalizeWord('**book**'), 'book');
  assert.equal(normalizeWord('  '), '');
});

test('primaryMeaning：只取首义、去词性前缀', () => {
  assert.equal(primaryMeaning('n. 名字；名称'), '名字');
  assert.equal(primaryMeaning('v 遇见；结识'), '遇见');
  assert.equal(primaryMeaning('令人愉快的；宜人的'), '令人愉快的');
  assert.equal(primaryMeaning('adj. 好的, 不错的'), '好的');
  assert.equal(primaryMeaning('n.'), '');
});

test('titleFromFileName：去 words- 前缀与 .md 后缀', () => {
  assert.equal(titleFromFileName('words-人教版七上.md'), '人教版七上');
  assert.equal(titleFromFileName('other.markdown', '兜底'), 'other');
  assert.equal(titleFromFileName('', '兜底书名'), '兜底书名');
});

// ===== 2. MD 解析 =====

test('解析规范词表：单元顺序、首义、空音标、统计行忽略', () => {
  const parsed = parseWordlist(VALID_MD, { title: '兜底' });
  assert.equal(parsed.title, '人教版七年级上册 单词表', 'MD 一级标题优先于文件名兜底');
  assert.equal(parsed.units.length, 2);
  assert.deepEqual(parsed.units.map((u) => u.unitOrder), [1, 2]);
  assert.equal(parsed.units[0].unit, "Unit 1 My name's Gina");
  assert.equal(parsed.units[0].entries.length, 4);
  assert.equal(parsed.units[1].entries.length, 2);
  assert.equal(parsed.units[0].entries[0].primaryMeaning, '你好');
  assert.equal(parsed.units[0].entries[1].primaryMeaning, '名字', 'n. 前缀要被去掉');
  assert.equal(parsed.units[0].entries[3].phonetic, '', 'meet || 中间空音标');
  assert.equal(parsed.units[0].entries[3].primaryMeaning, '遇见');
  assert.deepEqual(parsed.warnings, [], '统计行以 > 开头，必须忽略而非记坏行');
  assert.equal(flattenEntries(parsed).length, 6);
  assert.deepEqual(
    flattenEntries(parsed).map((e) => e.sortNo),
    [1, 2, 3, 4, 1, 2],
    'sortNo 在每个单元内重新开始',
  );
});

test('坏行记 warning 且跳过，不整单失败', () => {
  const md = [
    '## Unit 1',
    'a | eɪ | 一个',
    'b | biː | 坏行 | 多一段',
    '| | 空词中文',
    '中文词 | zhōng | 不是词条',
    '说明文字没有竖线',
    '',
  ].join('\n');
  const parsed = parseWordlist(md);
  assert.equal(flattenEntries(parsed).length, 1, '只保留 a 一行');
  assert.deepEqual(
    parsed.warnings.map((w) => w.reason),
    ['bad_line', 'empty_word'],
    '含中文的 word 与无竖线行是「忽略」，不是坏行',
  );
});

test('同单元重复词保留首条 + warning；跨单元允许', () => {
  const md = [
    '## Unit 1',
    'hello | h | 你好',
    'Hello. | hh | 喂',
    '## Unit 2',
    'hello | h2 | 哈喽',
  ].join('\n');
  const parsed = parseWordlist(md);
  assert.equal(parsed.units[0].entries.length, 1);
  assert.equal(parsed.units[1].entries.length, 1);
  assert.equal(parsed.warnings.filter((w) => w.reason === 'duplicate_word').length, 1);
});

test('没有 ## 单元时归入「默认单元」，且不破坏后续单元的 unitOrder', () => {
  const md = ['no | nəʊ | 没有', '## Unit 1', 'a | eɪ | 一个'].join('\n');
  const parsed = parseWordlist(md);
  assert.equal(parsed.units[0].unit, '默认单元');
  assert.deepEqual(parsed.units.map((u) => u.unitOrder), [1, 2]);
  assert.equal(parsed.warnings[0].reason, 'no_unit');
});

test('全坏行：解析结果为空（由路由响亮拒绝，不存 0 词的书）', () => {
  const parsed = parseWordlist('# 只有标题\n这是一段说明\n> 统计行\n');
  assert.equal(parsed.units.length, 0);
  assert.equal(flattenEntries(parsed).length, 0);
  assert.equal(parsed.title, '只有标题');
  assert.equal(titleFromFileName(''), '未命名词表');
});

// ===== 3. 导入落库（假 client + 假 ima 下载）=====

function fakeFetch(text, { folderTitle = 'Wordlist' } = {}) {
  return async (url) => {
    const one = String(url);
    if (one.includes('get_knowledge_list')) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({
          code: 0,
          data: {
            knowledge_list: [
              { media_id: 'folder_root', media_type: 99, title: '教学资料' },
              { media_id: 'folder_wordlist', media_type: 99, title: folderTitle },
              { media_id: 'm1', media_type: 7, title: 'words-人教版七上.md' },
            ],
            is_end: true,
            next_cursor: 'unused',
          },
        }),
      };
    }
    if (one.includes('get_media_info')) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({
          code: 0,
          data: { url_info: { url: 'https://cos.local/words.md', headers: {} } },
        }),
      };
    }
    if (one.includes('cos.local')) {
      return {
        ok: true,
        status: 200,
        headers: { get: () => null },
        arrayBuffer: async () => Buffer.from(text, 'utf8'),
      };
    }
    throw new Error(`未预期的请求：${one}`);
  };
}

/** 记录所有 SQL，按用途返回行；不碰真库。 */
function makeClient({ existingBook = null, importedBooks = [], units = ['Unit 1', 'Unit 2'] } = {}) {
  const sqlLog = [];
  const enc = encryptCredential({ clientid: 'cid', apikey: 'akey' }, SECRET);
  return {
    sqlLog,
    async query(sql, params = []) {
      sqlLog.push({ sql, params });
      if (/from ima_student_kb where student_id/.test(sql)) {
        return { rowCount: 1, rows: [{ kb_id: 'kb1', owner_user_id: 'parent-1', kb_name: '伴学' }] };
      }
      if (/from ima_credential where owner_user_id/.test(sql)) {
        return {
          rowCount: 1,
          rows: [{
            clientid_enc: enc.clientidEnc,
            apikey_enc: enc.apikeyEnc,
            status: 'active',
            kb_owner_name: '伴学',
          }],
        };
      }
      if (/from word_book where student_id = \$1 order by created_at/.test(sql)) {
        return { rowCount: importedBooks.length, rows: importedBooks };
      }
      if (/select id from word_book where student_id = \$1 and source_media_id/.test(sql)) {
        return existingBook
          ? { rowCount: 1, rows: [{ id: existingBook }] }
          : { rowCount: 0, rows: [] };
      }
      if (/select \* from word_book where id = \$1/.test(sql)) {
        return {
          rowCount: 1,
          rows: [{
            id: params[0], title: '人教版七上', unit_count: 2, word_count: 6,
            source_path: '', created_at: '2026-11-11T00:00:00Z',
          }],
        };
      }
      if (/select id, title from word_book where id = \$1 and student_id = \$2/.test(sql)) {
        return { rowCount: 1, rows: [{ id: params[0], title: '人教版七上' }] };
      }
      if (/select unit from word_entry/.test(sql)) {
        return { rowCount: units.length, rows: units.map((unit) => ({ unit })) };
      }
      return { rowCount: 1, rows: [] };
    },
  };
}

function parentCtx(fetchImpl) {
  return {
    userId: 'parent-1',
    role: 'parent',
    visibleStudents: ['s1'],
    fetchImpl,
  };
}

async function withSecret(fn) {
  const saved = process.env.IMA_CREDENTIAL_SECRET;
  process.env.IMA_CREDENTIAL_SECRET = SECRET;
  try { await fn(); } finally {
    if (saved == null) delete process.env.IMA_CREDENTIAL_SECRET;
    else process.env.IMA_CREDENTIAL_SECRET = saved;
  }
}

test('导入：下载 → 解析 → 落库，首次导入自动建 scope', async () => {
  await withSecret(async () => {
    const { importWordlist } = await import('../src/routes/word.js');
    const client = makeClient();
    const res = await importWordlist(client, parentCtx(fakeFetch(VALID_MD)), {
      studentId: 's1', mediaId: 'm1', fileName: 'words-人教版七上.md',
    });
    assert.equal(res.imported, true);
    assert.equal(res.unitCount, 2);
    assert.equal(res.wordCount, 6);
    const sql = client.sqlLog.map((one) => one.sql).join('\n');
    assert.match(sql, /insert into word_book/);
    assert.match(sql, /insert into word_entry/);
    assert.match(sql, /insert into word_scope/);
    const scopeInsert = client.sqlLog.find((one) => /insert into word_scope/.test(one.sql));
    assert.equal(scopeInsert.params[2], "Unit 1 My name's Gina", '默认当前单元 = 第 1 单元');
    const payload = client.sqlLog.find((one) => /jsonb_to_recordset/.test(one.sql));
    assert.equal(JSON.parse(payload.params[2]).length, 6, '几百词条一次插入，不是逐条往返');
  });
});

test('重复导入覆盖更新：保留 book.id（word_scope.book_id 指着它），不新建书', async () => {
  await withSecret(async () => {
    const { importWordlist } = await import('../src/routes/word.js');
    const client = makeClient({ existingBook: 'wb_existing' });
    await importWordlist(client, parentCtx(fakeFetch(VALID_MD)), {
      studentId: 's1', mediaId: 'm1', fileName: 'words.md',
    });
    const sql = client.sqlLog.map((one) => one.sql).join('\n');
    assert.match(sql, /delete from word_entry/);
    assert.match(sql, /update word_book set title/);
    assert.doesNotMatch(sql, /insert into word_book/, '删书重建会让已配置的范围静默失效');
    assert.match(sql, /on conflict \(student_id\) do nothing/, '已有范围不被导入覆盖');
  });
});

test('词表全坏 → 响亮拒绝，不写任何书', async () => {
  await withSecret(async () => {
    const { importWordlist } = await import('../src/routes/word.js');
    const client = makeClient();
    await assert.rejects(
      () => importWordlist(client, parentCtx(fakeFetch('# 只有标题\n说明文字\n')), {
        studentId: 's1', mediaId: 'm1', fileName: 'words.md',
      }),
      (e) => e.code === 'bad_request',
    );
    assert.doesNotMatch(client.sqlLog.map((one) => one.sql).join('\n'), /insert into word_book/);
  });
});

// ===== 4. 可选能力降级（硬规矩：没有 ima 也不能报错）=====

test('没连 ima → books 恒 2xx connected:false，但已导入的书照样列出', async () => {
  await withSecret(async () => {
    const { listAvailableWordlists } = await import('../src/routes/word.js');
    const client = makeClient({
      importedBooks: [{ id: 'wb1', title: '七上', unit_count: 2, word_count: 60, source_media_id: 'm1' }],
    });
    // 让 ima_credential 查不到 → resolveReaderContext 返回 null。
    const noImaClient = {
      ...client,
      async query(sql, params) {
        if (/from ima_credential/.test(sql)) return { rowCount: 0, rows: [] };
        return client.query(sql, params);
      },
    };
    const res = await listAvailableWordlists(noImaClient, parentCtx(fakeFetch('')), { studentId: 's1' });
    assert.equal(res.connected, false);
    assert.equal(res.reason, 'ima_unavailable');
    assert.deepEqual(res.books, []);
    assert.equal(res.imported.length, 1, '已缓存词表的家庭仍能切书、打卡');
  });
});

test('025 未迁移（word_book 表不存在）→ books 仍 2xx，不弹红条', async () => {
  const boom = Object.assign(new Error('relation "word_book" does not exist'), { code: '42P01' });
  const client = {
    async query(sql) {
      if (/from word_book/.test(sql)) throw boom;
      return { rowCount: 0, rows: [] };
    },
  };
  const { listAvailableWordlists } = await import('../src/routes/word.js');
  const res = await listAvailableWordlists(client, parentCtx(fakeFetch('')), { studentId: 's1' });
  assert.equal(res.connected, false);
  assert.deepEqual(res.imported, []);
});

test('目录名大小写不敏感：ima 里叫 wordlist（小写）也能列出来', async () => {
  await withSecret(async () => {
    const { listAvailableWordlists } = await import('../src/routes/word.js');
    const client = makeClient();

    const lower = await listAvailableWordlists(
      client,
      parentCtx(fakeFetch('', { folderTitle: 'wordlist' })),
      { studentId: 's1' },
    );
    assert.equal(lower.connected, true);
    assert.equal(lower.reason, undefined, '找到目录就不该带降级 reason');
    assert.equal(
      lower.books.length, 1,
      '实测虫子建的就是小写 wordlist；includes 区分大小写会变成「目录明明有、导入区说没有」',
    );
    assert.equal(lower.books[0].mediaId, 'm1');
    assert.equal(lower.books[0].importedBookId, null);

    // 反面：大写照旧能找（改大小写不敏感不能把原来的路弄坏）。
    const upper = await listAvailableWordlists(
      client,
      parentCtx(fakeFetch('')),
      { studentId: 's1' },
    );
    assert.equal(upper.books.length, 1);
    assert.equal(upper.books[0].mediaId, 'm1');
  });
});

test('家长主动点导入但 ima 不可用 → 温和 bad_request，不是 500', async () => {
  await withSecret(async () => {
    const { importWordlist } = await import('../src/routes/word.js');
    const client = makeClient();
    const noImaClient = {
      ...client,
      async query(sql, params) {
        if (/from ima_credential/.test(sql)) return { rowCount: 0, rows: [] };
        return client.query(sql, params);
      },
    };
    await assert.rejects(
      () => importWordlist(noImaClient, parentCtx(fakeFetch('')), {
        studentId: 's1', mediaId: 'm1',
      }),
      (e) => e.code === 'bad_request',
    );
  });
});

test('越界 bookId 读词表 → 403，不靠 RLS 静默变空', async () => {
  const { listWordEntries } = await import('../src/routes/word.js');
  const client = {
    async query() { return { rowCount: 0, rows: [] }; },
  };
  await assert.rejects(
    () => listWordEntries(client, parentCtx(fakeFetch('')), {
      studentId: 's1', bookId: '别人的书',
    }),
    (e) => e.code === 'forbidden',
  );
});
