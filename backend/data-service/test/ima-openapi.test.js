import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  IMA_FOLDER_NAMES,
  IMA_MEDIA_TYPE_MARKDOWN,
  IMA_STATUS,
  addKnowledge,
  buildCheckinsMarkdown,
  buildCosSha1Authorization,
  buildKbName,
  buildMistakesMarkdown,
  createFolder,
  createKnowledgeBase,
  createMedia,
  ensureFolder,
  ensureStudentKb,
  groupRowsBySubject,
  imaFetch,
  shouldSync,
  subjectForFileName,
  subjectOf,
  syncStudentData,
  uploadMarkdown,
  uploadToCos,
} from '../src/ima_openapi.js';
import { ErrorCodes } from '../../shared/errors.js';

/**
 * 所有测试都不碰真网络：fetch 用假的，按 URL / 路径分发响应，并记录调用。
 *
 * 跑法（隔离验证本文件，不需要 PG）：
 *   node --test test/ima-openapi.test.js
 */

/** 造一个假 fetch：ima 路径按 `handlers[path]` 返回，COS 主机一律 200。 */
function makeFetch(handlers) {
  const calls = [];
  const fn = async (url, opts) => {
    const path = url.includes('myqcloud.com') ? '(cos)' : url.replace('https://ima.qq.com', '');
    calls.push({
      url,
      path,
      opts,
      body: typeof opts?.body === 'string' ? JSON.parse(opts.body) : undefined,
    });
    if (url.includes('myqcloud.com')) {
      return { ok: true, status: 200, text: async () => '' };
    }
    const h = handlers[path];
    if (!h) return { ok: false, status: 404, text: async () => `unknown ${path}` };
    const res = typeof h === 'function' ? await h({ body: opts?.body ? JSON.parse(opts.body) : undefined }) : h;
    const status = res.status ?? 200;
    const payload = res.body ?? {};
    const text = typeof payload === 'string' ? payload : JSON.stringify(payload);
    return { ok: status >= 200 && status < 300, status, text: async () => text };
  };
  return { fn, calls };
}

// ===== 同步守卫 =====

test('shouldSync：只有 active 才允许写入', () => {
  assert.equal(shouldSync(IMA_STATUS.ACTIVE), true);
  assert.equal(shouldSync(IMA_STATUS.UNCONNECTED), false);
  assert.equal(shouldSync(IMA_STATUS.EXPIRED), false);
  assert.equal(shouldSync(undefined), false);
});

// ===== COS SHA1 签名 =====

test('buildCosSha1Authorization：结构正确，且对 secretKey 敏感', () => {
  const base = {
    secretId: 'AKID-test',
    secretKey: 'secret-a',
    method: 'PUT',
    pathname: '/o1',
    contentLength: '10',
    host: 'b.cos.ap-guangzhou.myqcloud.com',
    startTime: 1000,
    expiredTime: 4600,
  };
  const a = buildCosSha1Authorization(base);
  assert.match(a, /q-sign-algorithm=sha1/);
  assert.match(a, /q-ak=AKID-test/);
  assert.match(a, /q-signature=[0-9a-f]+/);
  assert.match(a, /q-header-list=content-length;host/);

  const b = buildCosSha1Authorization({ ...base, secretKey: 'secret-b' });
  assert.notEqual(a, b, 'secretKey 变了，签名必须变（否则无法验证算法正确性）');
});

// ===== imaFetch 状态码映射 =====

test('imaFetch：200 返回解析后的 json', async () => {
  const { fn } = makeFetch({ '/openapi/wiki/v1/get_addable_knowledge_base_list': { body: { code: 0 } } });
  const json = await imaFetch({ clientId: 'c', apiKey: 'k', fetchImpl: fn, path: '/openapi/wiki/v1/get_addable_knowledge_base_list' });
  assert.deepEqual(json, { code: 0 });
});

test('imaFetch：401 / 403 → imaAuthFailed（不可重试）', async () => {
  for (const status of [401, 403]) {
    const { fn } = makeFetch({ '/x': { status, body: 'nope' } });
    await assert.rejects(
      () => imaFetch({ clientId: 'c', apiKey: 'k', fetchImpl: fn, path: '/x' }),
      (e) => e.code === ErrorCodes.imaAuthFailed && e.retryable === false,
    );
  }
});

test('imaFetch：5xx → imaUnavailable（可重试）', async () => {
  const { fn } = makeFetch({ '/x': { status: 502, body: 'down' } });
  await assert.rejects(
    () => imaFetch({ clientId: 'c', apiKey: 'k', fetchImpl: fn, path: '/x' }),
    (e) => e.code === ErrorCodes.imaUnavailable && e.retryable === true,
  );
});

// ===== 建库 + 建文件夹 幂等 =====

test('ensureStudentKb：未建过 → 建库一次 + 建三个文件夹', async () => {
  // ⚠️ 这里必须用**官方返例的结构**，不能用我们「希望」的结构：
  //    官方文档给的 create_knowledge_base 返例是
  //      {"code":0,"data":{"knowledge_base_id":"yeVqEg7…"}}
  //    ——是 `knowledge_base_id`，不是 `id`。
  //    2026-10-27 家长端报「create_knowledge_base 未返回 id」就是栽在这上面，
  //    而当时的测试假数据写的正是 `data.id`，于是**测试全绿、线上必挂**。
  //    假数据比真实契约更宽松时，测试不是在验证，是在自欺。
  const { fn, calls } = makeFetch({
    '/openapi/wiki/v1/search_knowledge_base': { body: { code: 0, data: { info_list: [] } } },
    '/openapi/wiki/v1/create_knowledge_base': {
      body: { code: 0, data: { knowledge_base_id: 'kb_1', name: '伴学-李雨霏-2654' } },
    },
    '/openapi/wiki/v1/get_knowledge_list': { body: { code: 0, data: { knowledge_list: [] } } },
    '/openapi/wiki/v1/create_folder': ({ body }) => ({
      body: { code: 0, data: { media_id: `folder_${body.name}`, title: body.name } },
    }),
  });
  const out = await ensureStudentKb({ clientId: 'c', apiKey: 'k', fetchImpl: fn, studentId: '2654', displayName: '李雨霏' });
  assert.equal(out.kbId, 'kb_1');
  assert.equal(out.created, true);
  // 库名必须与真正建库用的那一个字符串一致：调用方拿它写 `ima_student_kb.kb_name`。
  // 一旦这里能自己拼第二份，就会出现「库里记 43 字、ima 里是 13 字」的分叉。
  assert.equal(out.kbName, '伴学-李雨霏-2654');
  assert.equal(Object.keys(out.folderIds).length, 3);
  assert.equal(out.folderIds.mistake, `folder_${IMA_FOLDER_NAMES.mistake}`);

  const createKb = calls.find((c) => c.path === '/openapi/wiki/v1/create_knowledge_base');
  assert.ok(createKb, '应当调用一次建库');
  const createFolderCalls = calls.filter((c) => c.path === '/openapi/wiki/v1/create_folder');
  assert.equal(createFolderCalls.length, 3, '应当建三个文件夹');
});

test('ensureStudentKb：已建过 → 不重复建库，复用 kb_id', async () => {
  // 文件夹列表的官方返回键是 `knowledge_list`（不是 `info_list`）。
  // 读错键的后果比「报错」更隐蔽：永远判成「文件夹不存在」，
  // 于是每次连接都重新建三个同名文件夹 —— ima 那边越堆越多，界面一切正常。
  const { fn, calls } = makeFetch({
    '/openapi/wiki/v1/search_knowledge_base': {
      body: { code: 0, data: { info_list: [{ kb_id: 'kb_existing', kb_name: '伴学-李雨霏-2654' }] } },
    },
    '/openapi/wiki/v1/get_knowledge_list': {
      body: {
        code: 0,
        data: {
          knowledge_list: [
            { media_id: 'folder_m', title: IMA_FOLDER_NAMES.mistake },
            { media_id: 'folder_c', title: IMA_FOLDER_NAMES.checkin },
            { media_id: 'folder_t', title: IMA_FOLDER_NAMES.teaching },
          ],
        },
      },
    },
  });
  const out = await ensureStudentKb({ clientId: 'c', apiKey: 'k', fetchImpl: fn, studentId: '2654', displayName: '李雨霏' });
  assert.equal(out.kbId, 'kb_existing');
  assert.equal(out.created, false);
  assert.equal(out.folderIds.mistake, 'folder_m');
  assert.equal(calls.find((c) => c.path === '/openapi/wiki/v1/create_knowledge_base'), undefined, '已存在时不应再建库');
  assert.equal(calls.find((c) => c.path === '/openapi/wiki/v1/create_folder'), undefined, '文件夹已存在时不应再建');
});

test('搜索命中用 id/name 写法也能复用（两份官方文档字段不一致）', async () => {
  const { fn, calls } = makeFetch({
    '/openapi/wiki/v1/search_knowledge_base': {
      body: { code: 0, data: { info_list: [{ id: 'kb_from_id', name: '伴学-李雨霏-2654' }] } },
    },
    '/openapi/wiki/v1/get_knowledge_list': {
      body: {
        code: 0,
        data: {
          knowledge_list: [
            { media_id: 'folder_m', title: IMA_FOLDER_NAMES.mistake },
            { media_id: 'folder_c', title: IMA_FOLDER_NAMES.checkin },
            { media_id: 'folder_t', title: IMA_FOLDER_NAMES.teaching },
          ],
        },
      },
    },
  });
  const out = await ensureStudentKb({
    clientId: 'c', apiKey: 'k', fetchImpl: fn, studentId: '2654', displayName: '李雨霏',
  });
  assert.equal(out.kbId, 'kb_from_id');
  assert.equal(out.created, false);
  assert.equal(calls.find((c) => c.path === '/openapi/wiki/v1/create_knowledge_base'), undefined);
});

// ===== 库名长度（ima 硬约束：1-25 字）=====

test('buildKbName：真实 UUID 也不能超过 25（按字节算，中文 3 字节）', () => {
  const sid = '2654d216-ffd9-4b2a-aca4-01cdc83858f8';
  const name = buildKbName('李雨霏', sid);
  // 拼完整 UUID 是 43 个字符 —— 那是 2026-10-27 连不上的第二个原因，
  // 而它的报错长得跟「字段名读错」一模一样。
  assert.ok(
    Buffer.byteLength(name, 'utf8') <= 25,
    `库名 ${Buffer.byteLength(name, 'utf8')} 字节超限：${name}`,
  );
  assert.ok(name.length <= 25, `字符数也超了：${name.length}`);
  assert.equal(name, '伴学-李雨霏-2654d2');
});

test('buildKbName：姓名很长时逐字回退，不切出半个汉字', () => {
  const name = buildKbName('欧阳娜娜娜娜娜娜娜娜娜', '2654d216-ffd9-4b2a-aca4-01cdc83858f8');
  assert.ok(Buffer.byteLength(name, 'utf8') <= 25, `${Buffer.byteLength(name, 'utf8')} 字节：${name}`);
  // 回退必须停在完整字符上：不能出现 U+FFFD 或半个码元
  assert.ok(!name.includes('\uFFFD'), `切出了坏字符：${name}`);
  assert.match(name, /^伴学-欧阳/);
});

test('buildKbName：没给姓名时用「学生」兜底，不出 undefined', () => {
  const name = buildKbName(undefined, '2654d216-ffd9-4b2a-aca4-01cdc83858f8');
  assert.match(name, /^伴学-学生-/);
  assert.ok(!name.includes('undefined'), '库名里出现 undefined 说明兜底没生效');
});

// ===== ima 的「HTTP 200 + 业务错误码」=====

test('ima 业务码非 0：必须抛错，并把 ima 的原文带出来', async () => {
  const { fn } = makeFetch({
    '/openapi/wiki/v1/create_knowledge_base': {
      body: { code: 10004, errmsg: '知识库数量已达上限' },
    },
  });
  await assert.rejects(
    () => createKnowledgeBase({ clientId: 'c', apiKey: 'k', fetchImpl: fn, name: 'x' }),
    (err) => {
      assert.equal(err.code, ErrorCodes.imaRequestFailed);
      // 关键：错误里必须有 ima 自己说的话。少了它，家长只看到一句
      // 「未返回 id」，而真正的原因（额度满了）永远不见天日。
      assert.match(err.message, /知识库数量已达上限/);
      assert.match(err.message, /10004/);
      return true;
    },
  );
});

test('ima 返回里的 retcode 写法同样识别（两份文档不一致）', async () => {
  const { fn } = makeFetch({
    '/openapi/wiki/v1/create_knowledge_base': { body: { retcode: 40003, errmsg: '凭证无权' } },
  });
  await assert.rejects(
    () => createKnowledgeBase({ clientId: 'c', apiKey: 'k', fetchImpl: fn, name: 'x' }),
    (err) => {
      assert.match(err.message, /凭证无权/);
      return true;
    },
  );
});

test('没有业务码字段时不能误判为失败（防过度拦截）', async () => {
  // 旧结构 / 某些端点可能只回 data。这种必须当成功，否则一次升级会把
  // 所有正常调用都拦成 502 —— 比原来那个 bug 更难查。
  const { fn } = makeFetch({
    '/openapi/wiki/v1/create_knowledge_base': { body: { data: { knowledge_base_id: 'kb_ok' } } },
  });
  const out = await createKnowledgeBase({ clientId: 'c', apiKey: 'k', fetchImpl: fn, name: 'x' });
  assert.equal(out.id, 'kb_ok');
});

test('建库缺 id：错误里要写实际返回了哪些字段（可诊断）', async () => {
  const { fn } = makeFetch({
    '/openapi/wiki/v1/create_knowledge_base': { body: { code: 0, data: { weird_key: 'v' } } },
  });
  await assert.rejects(
    () => createKnowledgeBase({ clientId: 'c', apiKey: 'k', fetchImpl: fn, name: 'x' }),
    (err) => {
      // 只说「未返回 id」等于什么都没说；把字段名摆出来，下次一眼就知道
      // 该改哪个键，而不是再去翻一遍文档。
      assert.match(err.message, /weird_key/);
      return true;
    },
  );
});

// ===== 上传 markdown 闭环 =====

test('uploadMarkdown：重名检查 → 建媒体 → 传 COS → 入知识库', async () => {
  const { fn, calls } = makeFetch({
    '/openapi/wiki/v1/check_repeated_names': { body: { code: 0 } },
    '/openapi/wiki/v1/create_media': {
      body: { data: { media_id: 'm1', secret_id: 'sid', secret_key: 'skey', token: 'tok', bucket: 'b', region: 'r', object_key: 'o1' } },
    },
    '/openapi/wiki/v1/add_knowledge': { body: { code: 0 } },
  });
  const res = await uploadMarkdown({
    clientId: 'c', apiKey: 'k', fetchImpl: fn, kbId: 'kb_1', folderId: 'folder_m', title: '错题档案-2026-10-26', markdown: '# hi',
  });
  assert.equal(res.mediaId, 'm1');

  const createMedia = calls.find((c) => c.path === '/openapi/wiki/v1/create_media');
  assert.ok(createMedia, '应调用 create_media');
  // 证伪点（2026-10-28 更正）：create_media **没有 media_type 字段**。
  // 官方只认 content_type + file_ext；多传 media_type（1 或 7 都一样）会稳定
  // 220001 invalid media_type —— 之前「把 1 改成 7」修错了对象，库一直是空的。
  assert.equal(createMedia.body.media_type, undefined,
    'create_media 不许带 media_type（多传即 220001）');
  assert.equal(createMedia.body.content_type, 'text/markdown');
  assert.equal(createMedia.body.file_ext, 'md');
  const addK = calls.find((c) => c.path === '/openapi/wiki/v1/add_knowledge');
  assert.ok(addK, '应调用 add_knowledge');
  assert.equal(addK.body.folder_id, 'folder_m', 'add_knowledge 必须带上目标文件夹');
  // add_knowledge 才是 media_type 该出现的地方，且要带 file_info 收尾。
  assert.equal(addK.body.media_type, IMA_MEDIA_TYPE_MARKDOWN);
  assert.equal(addK.body.file_info.cos_key, 'o1');
  assert.equal(addK.body.file_info.file_name, '错题档案-2026-10-26.md');

  const cos = calls.find((c) => c.url.includes('myqcloud.com'));
  assert.ok(cos, '应把文件 PUT 到 COS');
  assert.match(cos.opts.headers.Authorization, /q-sign-algorithm=sha1/, 'COS 必须用 SHA1 签名');
  assert.equal(cos.opts.headers['x-cos-security-token'], 'tok', 'token 走独立头、不参与签名');

  // 重名检查的待查项必须放在 `params` 数组里（官方契约），且名字要和
  // create_media 实际用的文件名一致 —— 否则查的是一个不存在的名字，查了等于没查。
  const repeated = calls.find((c) => c.path === '/openapi/wiki/v1/check_repeated_names');
  assert.ok(repeated, '上传前应做重名检查');
  assert.ok(Array.isArray(repeated.body.params), '待查项必须在 params 数组里，平铺会参数校验失败');
  assert.equal(repeated.body.params[0].name, '错题档案-2026-10-26.md');
  assert.equal(repeated.body.params[0].media_type, IMA_MEDIA_TYPE_MARKDOWN,
    '重名检查按 markdown(7) 查，否则查的是另一个类型');
});

test('createMedia：凭证嵌在 data.cos_credential 下也能解析（真接口形状）', async () => {
  // 证伪点（2026-10-28 按真接口实测改正）：COS 凭证**不是平铺在 data 上**，
  // 而是 `data.cos_credential.{secret_id,secret_key,token,bucket_name,region,cos_key}`。
  // 旧代码 `extractCosCredentials(data)` 直接读顶层 ⇒ 全 undefined ⇒
  // uploadToCos 抛「COS 凭证不完整」。mock 若照着自己的假设平铺返回，这条永远是绿的。
  const { fn, calls } = makeFetch({
    '/openapi/wiki/v1/create_media': {
      body: {
        code: 0,
        data: {
          media_id: 'm9',
          cos_credential: {
            token: 'tok',
            secret_id: 'sid',
            secret_key: 'skey',
            bucket_name: 'b9',
            region: 'r9',
            cos_key: 'o9',
          },
        },
      },
    },
  });
  const res = await createMedia({
    clientId: 'c', apiKey: 'k', fetchImpl: fn, kbId: 'kb_1', fileName: 'x.md', fileSize: 3,
  });
  assert.equal(res.mediaId, 'm9');
  assert.equal(res.cosCredentials.bucket, 'b9', '应取 data.cos_credential.bucket_name');
  assert.equal(res.cosCredentials.secretId, 'sid');
  assert.equal(res.cosCredentials.token, 'tok');
  assert.equal(res.cosKey, 'o9', '应取 data.cos_credential.cos_key');
  // 顺带确认 create_media 走的是 content_type/file_ext 契约，且不带 media_type。
  const cm = calls.find((c) => c.path === '/openapi/wiki/v1/create_media');
  assert.equal(cm.body.content_type, 'text/markdown');
  assert.equal(cm.body.file_ext, 'md');
  assert.equal(cm.body.media_type, undefined);
});

test('createMedia：旧字段名平铺（bucket / object_key）仍兼容', async () => {
  // 负责任的兼容：早期 PoC 里凭证可能平铺在 data 上，别因为改正契约就把这条老路砍掉。
  const { fn } = makeFetch({
    '/openapi/wiki/v1/create_media': {
      body: { data: { media_id: 'm8', secret_id: 'sid', secret_key: 'skey', token: 'tok', bucket_name: 'b8', region: 'r8', cos_key: 'o8' } },
    },
  });
  const res = await createMedia({
    clientId: 'c', apiKey: 'k', fetchImpl: fn, kbId: 'kb_1', fileName: 'x.md', fileSize: 3,
  });
  assert.equal(res.cosCredentials.bucket, 'b8');
  assert.equal(res.cosKey, 'o8');
});

test('uploadToCos：凭证不完整 → imaRequestFailed', async () => {
  await assert.rejects(
    () => uploadToCos({ cosCredentials: { secretId: 'x' }, cosKey: 'o' }),
    (e) => e.code === ErrorCodes.imaRequestFailed,
  );
});

// ===== 同步编排：守卫 + 跳过 =====

test('syncStudentData：unconnected → 不联网、不查数据', async () => {
  let fetchCalled = false;
  const spyFetch = async () => { fetchCalled = true; throw new Error('不应被调用'); };
  let fetchMistakesCalled = false;
  const out = await syncStudentData({
    imaStatus: IMA_STATUS.UNCONNECTED,
    credential: { clientId: 'c', apiKey: 'k' },
    studentId: '2654',
    fetchMistakes: async () => { fetchMistakesCalled = true; return []; },
    fetchCheckins: async () => [],
    fetchImpl: spyFetch,
  });
  assert.equal(out.synced, false);
  assert.equal(fetchCalled, false, '未连接时不应有任何网络调用');
  assert.equal(fetchMistakesCalled, false, '未连接时不应查本地数据');
});

test('syncStudentData：active → 调用 ensureKb + 各推一份 md（错题 + 打卡）', async () => {
  let ensureKbCalled = false;
  let uploadMdCalls = 0;
  const out = await syncStudentData({
    imaStatus: IMA_STATUS.ACTIVE,
    credential: { clientId: 'c', apiKey: 'k' },
    studentId: '2654',
    displayName: '李雨霏',
    fetchMistakes: async () => ([{ knowledge_point: '解方程', title: 't', wrong_count: 2, state: 'reviewing' }]),
    fetchCheckins: async () => ([{ knowledge: '有理数', created_at: new Date(), correct: true }]),
    fetchImpl: async () => ({ ok: true, status: 200, text: async () => '{}' }),
    ensureKbImpl: async ({ studentId }) => { ensureKbCalled = true; return { kbId: 'kb_1', folderIds: { mistake: 'fm', checkin: 'fc', teaching: 'ft' } }; },
    uploadMdImpl: async () => { uploadMdCalls += 1; return { mediaId: 'm' }; },
  });
  assert.equal(out.synced, true);
  assert.equal(ensureKbCalled, true);
  assert.equal(uploadMdCalls, 2, '错题与打卡各推一份');
  assert.equal(out.pushed, 2);
});

test('syncStudentData：active 但凭证缺失 → imaAuthFailed', async () => {
  await assert.rejects(
    () => syncStudentData({
      imaStatus: IMA_STATUS.ACTIVE,
      credential: {},
      studentId: '2654',
      fetchMistakes: async () => [],
      fetchCheckins: async () => [],
      fetchImpl: async () => ({ ok: true, status: 200, text: async () => '{}' }),
    }),
    (e) => e.code === ErrorCodes.imaAuthFailed,
  );
});

// ===== markdown 构建（纯函数） =====

test('buildMistakesMarkdown：同义知识点被归一，不重复成多组', () => {
  const rows = [
    { knowledge_point: '解方程', title: 't1', wrong_count: 2, state: 'reviewing' },
    { knowledge_point: '解一元一次方程', title: 't2', wrong_count: 3, state: 'pending' },
    { knowledge_point: '有理数混合运算', title: 't3', wrong_count: 1, state: 'mastered' },
  ];
  const md = buildMistakesMarkdown(rows, '2026-10-26');
  assert.match(md, /## 解一元一次方程/);
  assert.doesNotMatch(md, /## 解方程\n/, '解方程应被归一掉，不留独立小节');
  assert.match(md, /## 有理数混合运算/);
  assert.match(md, /错题总数：3 条/);
});

test('buildCheckinsMarkdown：包含日期与结果', () => {
  const rows = [{ knowledge: '有理数', subject: '数学', question: '1+1=?', answer: '2', correct: true, created_at: new Date('2026-10-26T10:00:00') }];
  const md = buildCheckinsMarkdown(rows, '2026-10-26');
  assert.match(md, /# 打卡档案/);
  assert.match(md, /主攻方向：有理数/);
  assert.match(md, /结果：正确/);
  assert.match(md, /2026-10-26/);
});

// ===== 按学科分档（2026-11-02 报障：三科混在一份 md，看不出是哪一科） =====

test('groupRowsBySubject：一科一组，空学科归「未分科」，条数多的在前', () => {
  const groups = groupRowsBySubject([
    { subject: '英语', title: 'e1' },
    { subject: '数学', title: 'm1' },
    { subject: '数学', title: 'm2' },
    { subject: '' , title: 'x1' },
    { title: 'x2' },
  ]);
  assert.deepEqual(groups.map((g) => g.subject), ['数学', '未分科', '英语'],
    '条数降序；同为 2 条时按学科名，未分科不并进任何一科');
  assert.equal(groups[0].rows.length, 2);
  assert.equal(groups[1].rows.length, 2, 'subject 缺失与空串是同一回事');
  assert.equal(subjectOf({ subject: '  语文 ' }), '语文');
});

test('subjectForFileName：斜杠/空格不会进文件名', () => {
  assert.equal(subjectForFileName('数学'), '数学');
  assert.equal(subjectForFileName('数学/物理'), '数学-物理');
  assert.equal(subjectForFileName('   '), '未分科');
});

test('buildMistakesMarkdown：标题带学科，每条也标学科', () => {
  const md = buildMistakesMarkdown(
    [{ knowledge_point: '解方程', title: 't1', subject: '数学', wrong_count: 2, state: 'reviewing' }],
    '2026-11-02',
    '数学',
  );
  assert.match(md, /^# 错题档案 · 数学/);
  assert.match(md, /- 学科：数学/);
});

test('buildCheckinsMarkdown：标题带学科', () => {
  const md = buildCheckinsMarkdown(
    [{ knowledge: '阅读理解', subject: '语文', correct: '3/5', created_at: '2026-11-01' }],
    '2026-11-02',
    '语文',
  );
  assert.match(md, /^# 打卡档案 · 语文/);
});

test('syncStudentData：多科 → 一科一份，文件名带学科与日期', async () => {
  const uploads = [];
  const out = await syncStudentData({
    imaStatus: IMA_STATUS.ACTIVE,
    credential: { clientId: 'c', apiKey: 'k' },
    studentId: '2654',
    displayName: '李雨霏',
    fetchMistakes: async () => ([
      { knowledge_point: '解方程', subject: '数学', title: 'm1' },
      { knowledge_point: '语法', subject: '英语', title: 'e1' },
    ]),
    fetchCheckins: async () => ([
      { subject: '数学', knowledge: '有理数', correct: '4/5' },
      { subject: '语文', knowledge: '阅读理解', correct: '3/5' },
      { subject: '英语', knowledge: '语法', correct: '2/5' },
    ]),
    fetchImpl: async () => ({ ok: true, status: 200, text: async () => '{}' }),
    ensureKbImpl: async () => ({ kbId: 'kb_1', folderIds: { mistake: 'fm', checkin: 'fc', teaching: 'ft' } }),
    uploadMdImpl: async (args) => { uploads.push(args); return { mediaId: 'm' }; },
    now: () => new Date('2026-11-02T10:00:00Z'),
  });

  assert.equal(out.synced, true);
  assert.equal(out.pushed, 5, '错题 2 科 + 打卡 3 科');
  const mistakeTitles = uploads.filter((u) => u.folderId === 'fm').map((u) => u.title);
  assert.deepEqual(mistakeTitles, ['错题档案-数学-2026-11-02', '错题档案-英语-2026-11-02']);
  const checkinTitles = uploads.filter((u) => u.folderId === 'fc').map((u) => u.title);
  assert.deepEqual(checkinTitles, [
    '打卡档案-数学-2026-11-02',
    '打卡档案-英语-2026-11-02',
    '打卡档案-语文-2026-11-02',
  ], '同条数按学科名排序');
  // 每份 md 只能含自己那一科 —— 这条是报障的正题
  for (const u of uploads) {
    const subjects = new Set([...u.markdown.matchAll(/- 学科：(.+)/g)].map((m) => m[1].trim()));
    assert.equal(subjects.size, 1, `《${u.title}》混进了多科：${[...subjects]}`);
  }
});

// ===== 单接口回归（确保导出齐全、形参正确） =====

test('导出函数齐全且可调用', async () => {
  assert.equal(typeof createKnowledgeBase, 'function');
  assert.equal(typeof createFolder, 'function');
  assert.equal(typeof ensureFolder, 'function');
  assert.equal(typeof createMedia, 'function');
  assert.equal(typeof addKnowledge, 'function');
});
