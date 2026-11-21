import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { test } from 'node:test';

import {
  buildCanonicalRequest,
  createOssImageStore,
  deriveSigningKey,
  iso8601Utc,
  signRequest,
  uriEncode,
} from '../src/ossimagestore.js';
import { buildStorageKey } from '../src/imagestore.js';

/**
 * OSS 后端的判据。
 *
 * ⭐ 本文件的重点是**第一组**：官方文档给出的那份完整算例。它把
 * AccessKeySecret、时间戳、对象、以及期望的 SigningKey 和 Signature
 * 全都印在文档上，所以可以**逐段对照**，不需要任何真实凭证。
 *
 * 这三条断言里任意一条跑红，就说明本实现与官方算法已经分叉 ——
 * 而线上的表现会是一律 `SignatureDoesNotMatch`，看起来像 AccessKey 填错了。
 */

// ─────────────────────────────────────────────────────────────
// ① 官方算例：https://help.aliyun.com/en/oss/developer-reference/include-signature-in-header
// ─────────────────────────────────────────────────────────────

const VECTOR = {
  accessKeyId: 'LTAI****************',
  accessKeySecret: 'yourAccessKeySecret',
  timestamp: '20250411T064124Z',
  bucket: 'examplebucket',
  key: 'exampleobject',
  region: 'cn-hangzhou',
  headers: {
    'content-disposition': 'attachment',
    'content-length': '3',
    'content-md5': 'ICy5YqxZB1uWSwcVLSNLcA==',
    'content-type': 'text/plain',
  },
  additionalHeaders: ['content-disposition', 'content-length'],
};

test('官方算例①：规范请求逐行一致（含两个必须的头，且 host 不在其中）', () => {
  const { canonicalRequest, signedHeaderNames } = buildCanonicalRequest({
    method: 'PUT',
    bucket: VECTOR.bucket,
    key: VECTOR.key,
    headers: {
      ...VECTOR.headers,
      'x-oss-date': VECTOR.timestamp,
      'x-oss-content-sha256': 'UNSIGNED-PAYLOAD',
    },
    additionalHeaders: VECTOR.additionalHeaders,
  });

  const lines = canonicalRequest.split('\n');
  assert.equal(lines[0], 'PUT');
  // ⚠️ CanonicalURI **必须带 bucket** —— 这是 OSS 与 AWS SigV4 的差异之一。
  assert.equal(lines[1], '/examplebucket/exampleobject');
  assert.equal(lines[2], '', '没有查询参数时该行是空串');
  // 参与签名的头，按小写名排序：
  assert.deepEqual(signedHeaderNames, [
    'content-disposition',
    'content-length',
    'content-md5',
    'content-type',
    'x-oss-content-sha256',
    'x-oss-date',
  ]);
  // host 若被签进来会得到 SignatureDoesNotMatch，且完全看不出原因。
  assert.ok(!signedHeaderNames.includes('host'), 'host 不参与签名（与 AWS 不同）');
  // 结尾三行：空行 + 可选头清单 + payload 占位
  assert.deepEqual(lines.slice(-3), ['', 'content-disposition;content-length', 'UNSIGNED-PAYLOAD']);
});

test('⭐ 官方算例②：StringToSign 逐行一致（第四行是规范请求的哈希）', () => {
  const r = signRequest({
    method: 'PUT',
    bucket: VECTOR.bucket,
    key: VECTOR.key,
    headers: VECTOR.headers,
    additionalHeaders: VECTOR.additionalHeaders,
    accessKeyId: VECTOR.accessKeyId,
    accessKeySecret: VECTOR.accessKeySecret,
    region: VECTOR.region,
    timestamp: VECTOR.timestamp,
  });

  // 这一行对上，就说明 CanonicalRequest 的**每一个字节**都对 ——
  // 整串参与 SHA256，差一个空格、差一个换行都会变成另一个值。
  assert.deepEqual(r.stringToSign.split('\n'), [
    'OSS4-HMAC-SHA256',
    '20250411T064124Z',
    '20250411/cn-hangzhou/oss/aliyun_v4_request',
    'c46d96390bdbc2d739ac9363293ae9d710b14e48081fcb22cd8ad54b63136eca',
  ]);
});

test('⭐ 官方算例③：用文档印出的 SigningKey 能签出文档印出的 Signature', () => {
  // ⚠️ 为什么绕这一下：文档为了不泄露密钥，把 AccessKeySecret 写成了占位的
  // `yourAccessKeySecret`，**但它印出的 SigningKey / Signature 是用真实 SK 算的**
  // —— 所以拿那个占位 SK 永远算不出文档上那两个数，直接对照会得到一条
  // 永远红的用例（那不是实现错了，是期望值取错了）。
  //
  // 而「给定文档的 SigningKey + 我算的 StringToSign → 应该得到文档的 Signature」
  // 这条是**能对上的**，且它一次性验证了两件事：StringToSign 的拼接（含换行）、
  // 以及最终那一步 HMAC。剩下只有「SigningKey 怎么派生」没被这一步覆盖，
  // 那由下一条用例管。
  const docSigningKey = Buffer.from(
    '3543b7686e65eda71e5e5ca19d548d78423c37e8ddba4dc9d83f90228b457c76',
    'hex',
  );
  const stringToSign = signRequest({
    method: 'PUT',
    bucket: VECTOR.bucket,
    key: VECTOR.key,
    headers: VECTOR.headers,
    additionalHeaders: VECTOR.additionalHeaders,
    accessKeyId: VECTOR.accessKeyId,
    accessKeySecret: VECTOR.accessKeySecret,
    region: VECTOR.region,
    timestamp: VECTOR.timestamp,
  }).stringToSign;

  const signature = createHmac('sha256', docSigningKey)
    .update(stringToSign, 'utf8')
    .digest('hex');

  assert.equal(signature, '053edbf550ebd239b32a9cdfd93b0b2b3f2d223083aa61f75e9ac16856d61f23');
});

test('⭐ 官方算例④：SigningKey 派生与 Authorization 全串（对照 Python 标准库独立复算）', () => {
  // 期望值来源：`build/probe-sig.py` —— 照抄官方 Python SDK v4.py 的派生链，
  // 但由 Python 标准库独立执行。两边一致，才说明这条 HMAC 链的实现无误。
  const r = signRequest({
    method: 'PUT',
    bucket: VECTOR.bucket,
    key: VECTOR.key,
    headers: VECTOR.headers,
    additionalHeaders: VECTOR.additionalHeaders,
    accessKeyId: VECTOR.accessKeyId,
    accessKeySecret: VECTOR.accessKeySecret,
    region: VECTOR.region,
    timestamp: VECTOR.timestamp,
  });

  assert.equal(
    deriveSigningKey({
      accessKeySecret: VECTOR.accessKeySecret,
      date: '20250411',
      region: VECTOR.region,
    }).toString('hex'),
    '8a01ff4efcc65ca2cbc75375045c61ab5f3fa8b9a2d84f0add27ef16a25feb3c',
  );

  assert.equal(
    r.authorization,
    'OSS4-HMAC-SHA256 Credential=LTAI****************/20250411/cn-hangzhou/oss/aliyun_v4_request'
      + ',AdditionalHeaders=content-disposition;content-length'
      + ',Signature=d3694c2dfc5371ee6acd35e88c4871ac95a7ba01d3a2f476768fe61218590097',
  );
});

// ─────────────────────────────────────────────────────────────
// ② 形状细节（每条都对应一个「错了就这样失败」的坑）
// ─────────────────────────────────────────────────────────────

test('没有可选头时，Authorization 里**整段省略** AdditionalHeaders', () => {
  const r = signRequest({
    method: 'GET',
    bucket: 'b',
    key: 'k',
    accessKeyId: 'AK',
    accessKeySecret: 'SK',
    region: 'cn-beijing',
    timestamp: '20260923T000000Z',
  });
  assert.ok(
    !r.authorization.includes('AdditionalHeaders'),
    '空的 AdditionalHeaders 不该出现（会变成另一种形状）',
  );
  assert.match(r.authorization, /^OSS4-HMAC-SHA256 Credential=AK\/20260923\/cn-beijing\/oss\/aliyun_v4_request,Signature=[0-9a-f]{64}$/);
});

test('规范里点名要签、但请求里没有的头，不该出现在 AdditionalHeaders', () => {
  const r = signRequest({
    method: 'PUT',
    bucket: 'b',
    key: 'k',
    headers: { 'content-type': 'image/jpeg' },
    additionalHeaders: ['content-disposition', 'x-oss-meta-nope'],
    accessKeyId: 'AK',
    accessKeySecret: 'SK',
    region: 'cn-beijing',
    timestamp: '20260923T000000Z',
  });
  assert.ok(!r.authorization.includes('content-disposition'));
  assert.ok(!r.authorization.includes('x-oss-meta-nope'));
});

test('content-type 会被签名（不在额外清单里也签）', () => {
  const r = signRequest({
    method: 'PUT',
    bucket: 'b',
    key: 'k',
    headers: { 'content-type': 'image/jpeg' },
    accessKeyId: 'AK',
    accessKeySecret: 'SK',
    region: 'cn-beijing',
    timestamp: '20260923T000000Z',
  });
  assert.ok(r.canonicalRequest.includes('content-type:image/jpeg'));
});

test('URI 编码：不编码 -_.~ 与斜杠，编码 !\'()*', () => {
  assert.equal(uriEncode('a-b_c.d~e'), 'a-b_c.d~e');
  assert.equal(uriEncode("!*'()"), '%21%2A%27%28%29');
  assert.equal(uriEncode('a b'), 'a%20b');
});

test('斜杠在路径里保持不编码（编码了就变成另一个对象名）', () => {
  const { canonicalRequest } = buildCanonicalRequest({
    method: 'GET',
    bucket: 'b',
    key: '20260923/stu-1/abc.jpg',
    headers: { 'x-oss-date': '20260923T000000Z', 'x-oss-content-sha256': 'UNSIGNED-PAYLOAD' },
  });
  assert.equal(canonicalRequest.split('\n')[1], '/b/20260923/stu-1/abc.jpg');
});

test('时间戳格式：ISO8601 UTC，无分隔符、无毫秒', () => {
  assert.equal(iso8601Utc(Date.UTC(2025, 3, 11, 6, 41, 24)), '20250411T064124Z');
});

test('缺凭证/缺区域时在签名前就抛，不发出一个注定失败的请求', () => {
  assert.throws(() => signRequest({ method: 'GET', bucket: 'b', key: 'k', region: 'cn-beijing' }), /凭证未配置/);
  assert.throws(
    () => signRequest({ method: 'GET', bucket: 'b', key: 'k', accessKeyId: 'a', accessKeySecret: 'b' }),
    /OSS_REGION/,
  );
});

// ─────────────────────────────────────────────────────────────
// ③ 存储行为（注入 fetch，不打真网络）
// ─────────────────────────────────────────────────────────────

const CREDS = {
  bucket: 'xueban-photos',
  region: 'cn-beijing',
  accessKeyId: 'AK',
  accessKeySecret: 'SK',
};

function fakeFetch(handler) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push({ url, method: init.method, headers: init.headers, body: init.body });
    const r = handler(url, init) ?? {};
    const status = r.status ?? 200;
    const buf = Buffer.isBuffer(r.bytes) ? r.bytes : Buffer.from(r.bytes ?? []);
    return {
      ok: status >= 200 && status < 300,
      status,
      headers: { get: (n) => (String(n).toLowerCase() === 'x-oss-request-id' ? 'REQ-TEST' : null) },
      text: async () => r.text ?? '',
      arrayBuffer: async () => buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength),
    };
  };
  return { impl, calls };
}

function ossErrorXml(code) {
  return `<Error><Code>${code}</Code><Message>m</Message><RequestId>REQ-TEST</RequestId></Error>`;
}

test('上传：返回相对键，键的形状与文件系统版**逐字一致**', async () => {
  const { impl, calls } = fakeFetch(() => ({ status: 200 }));
  const store = createOssImageStore({
    ...CREDS,
    fetchImpl: impl,
    now: () => Date.UTC(2026, 8, 23, 6, 0, 0),
  });

  const bytes = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x01]);
  const saved = await store.put({ studentId: 'stu-1', bytes, mimeType: 'image/jpeg' });

  assert.match(saved.storageKey, /^20260923\/stu-1\/[0-9a-f-]{36}\.jpg$/);
  assert.equal(saved.byteSize, bytes.length);
  assert.equal(saved.mimeType, 'image/jpeg');
  // 键必须与文件系统实现同源 —— 否则切换后端会让老照片全部失联。
  const fsKey = buildStorageKey({ studentId: 'stu-1', ext: '.jpg', epochMs: Date.UTC(2026, 8, 23) });
  assert.equal(fsKey.split('/').length, saved.storageKey.split('/').length);

  assert.equal(calls[0].method, 'PUT');
  assert.match(calls[0].url, /^https:\/\/xueban-photos\.oss-cn-beijing\.aliyuncs\.com\/20260923\/stu-1\//);
  assert.equal(calls[0].headers['content-type'], 'image/jpeg');
  assert.match(calls[0].headers.authorization, /^OSS4-HMAC-SHA256 Credential=AK\//);
  assert.equal(calls[0].headers['x-oss-content-sha256'], 'UNSIGNED-PAYLOAD');
});

test('上传校验与文件系统版同一段逻辑：空 400 / 超限 413 / 类型不支持 400', async () => {
  const { impl, calls } = fakeFetch(() => ({ status: 200 }));
  const store = createOssImageStore({ ...CREDS, fetchImpl: impl, maxBytesByKind: { image: 10 } });

  await assert.rejects(store.put({ studentId: 's', bytes: Buffer.alloc(0), mimeType: 'image/jpeg' }), /上传内容为空/);
  await assert.rejects(store.put({ studentId: 's', bytes: Buffer.alloc(11), mimeType: 'image/jpeg' }), /不得超过/);
  await assert.rejects(
    store.put({ studentId: 's', bytes: Buffer.alloc(4), mimeType: 'application/pdf' }),
    /不支持的附件类型/,
  );
  assert.equal(calls.length, 0, '校验不通过时不该发出请求');
});

test('读回：字节逐字节相同', async () => {
  const payload = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0xff]);
  const { impl } = fakeFetch(() => ({ status: 200, bytes: payload }));
  const store = createOssImageStore({ ...CREDS, fetchImpl: impl });

  const got = await store.get('20260923/stu-1/abc.png');
  assert.deepEqual([...got], [...payload]);
});

test('读回：NoSuchKey → file_missing（照片真没了）', async () => {
  const { impl } = fakeFetch(() => ({ status: 404, text: ossErrorXml('NoSuchKey') }));
  const store = createOssImageStore({ ...CREDS, fetchImpl: impl });

  await assert.rejects(store.get('20260923/stu-1/gone.jpg'), (e) => {
    assert.equal(e.status, 404);
    assert.equal(e.details.reason, 'file_missing');
    return true;
  });
});

test('⭐ 读回：NoSuchBucket **不是**「照片没了」—— 桶名配错不能表现成照片被清理', async () => {
  // 这两个错误**都是 404**。只看状态码的话，「环境变量填错了」会被读成
  // 「照片被清理了」，于是所有人去查清理策略 —— 而真实原因在配置里。
  const { impl } = fakeFetch(() => ({ status: 404, text: ossErrorXml('NoSuchBucket') }));
  const store = createOssImageStore({ ...CREDS, fetchImpl: impl });

  await assert.rejects(store.get('20260923/stu-1/abc.jpg'), (e) => {
    assert.notEqual(e.details?.reason, 'file_missing', '这是配置问题，不是照片丢了');
    assert.notEqual(e.details?.reason, 'not_on_server');
    assert.equal(e.details.reason, 'storage_backend_error');
    assert.equal(e.details.ossCode, 'NoSuchBucket');
    assert.match(e.message, /OSS_BUCKET/, '错误信息要指向该改的那个环境变量');
    return true;
  });
});

test('读回：签名错同样是后端故障，且指向 AccessKey', async () => {
  const { impl } = fakeFetch(() => ({ status: 403, text: ossErrorXml('SignatureDoesNotMatch') }));
  const store = createOssImageStore({ ...CREDS, fetchImpl: impl });

  await assert.rejects(store.get('20260923/stu-1/abc.jpg'), (e) => {
    assert.equal(e.details.reason, 'storage_backend_error');
    assert.match(e.message, /ACCESS_KEY/);
    return true;
  });
});

test('读回：旧的设备本地标识 → not_on_server，且**不发请求**（服务端根本没这个键）', async () => {
  const { impl, calls } = fakeFetch(() => ({ status: 200 }));
  const store = createOssImageStore({ ...CREDS, fetchImpl: impl });

  for (const legacy of ['memory://photos/3', '/data/user/0/app/files/a.jpg', 'C:\\Users\\me\\a.jpg']) {
    await assert.rejects(store.get(legacy), (e) => {
      assert.equal(e.status, 404);
      assert.equal(e.details.reason, 'not_on_server');
      return true;
    });
  }
  assert.equal(calls.length, 0, '旧标识在服务端无意义，不该浪费一次请求');
});

// ─────────────────────────────────────────────────────────────
// ④ 启动自检：签名写错了必须在这里暴露
// ─────────────────────────────────────────────────────────────

test('自检：探测对象返回 NoSuchKey = 全对（桶在、凭证对、签名对）', async () => {
  const { impl, calls } = fakeFetch(() => ({ status: 404, text: ossErrorXml('NoSuchKey') }));
  const store = createOssImageStore({ ...CREDS, fetchImpl: impl });

  const r = await store.assertReady();
  assert.equal(r.ok, true);
  assert.equal(r.root, 'oss://xueban-photos');
  // 「期望 404」是刻意的：拿到了 NoSuchKey 就说明签名被接受、桶也存在。
  assert.equal(calls[0].method, 'GET');
  assert.match(calls[0].url, /__cold-start-probe__$/);
});

test('自检：签名错 → 不通过，且说清是哪一类问题', async () => {
  const { impl } = fakeFetch(() => ({ status: 403, text: ossErrorXml('SignatureDoesNotMatch') }));
  const store = createOssImageStore({ ...CREDS, fetchImpl: impl });

  const r = await store.assertReady();
  assert.equal(r.ok, false);
  assert.match(r.reason, /签名不匹配/);
});

test('自检：桶不存在 → 不通过，并指向 OSS_BUCKET / OSS_REGION', async () => {
  const { impl } = fakeFetch(() => ({ status: 404, text: ossErrorXml('NoSuchBucket') }));
  const store = createOssImageStore({ ...CREDS, fetchImpl: impl });

  const r = await store.assertReady();
  assert.equal(r.ok, false);
  assert.match(r.reason, /OSS_BUCKET/);
});

test('自检：连不上时不抛异常，而是回一条人能读懂的原因', async () => {
  const store = createOssImageStore({
    ...CREDS,
    fetchImpl: async () => {
      throw new Error('getaddrinfo EAI_AGAIN');
    },
  });
  const r = await store.assertReady();
  assert.equal(r.ok, false);
  assert.match(r.reason, /连不上对象存储/);
});

test('自检：未配置时**逐个点名**缺哪个变量（否则运维只知道「没配」）', async () => {
  const store = createOssImageStore({ bucket: 'b' });
  assert.equal(store.ready, false);

  const r = await store.assertReady();
  assert.equal(r.ok, false);
  assert.match(r.reason, /OSS_REGION/);
  assert.match(r.reason, /OSS_ACCESS_KEY_ID/);
  assert.match(r.reason, /OSS_ACCESS_KEY_SECRET/);
  assert.ok(!r.reason.includes('OSS_BUCKET'), 'b 配了，不该被列出来');
});

test('prefix：只影响实际访问路径，**数据库里存的仍是不带前缀的键**', async () => {
  const { impl, calls } = fakeFetch(() => ({ status: 200 }));
  const store = createOssImageStore({
    ...CREDS,
    prefix: 'staging',
    fetchImpl: impl,
    now: () => Date.UTC(2026, 8, 23),
  });

  const saved = await store.put({ studentId: 's1', bytes: Buffer.alloc(4, 1), mimeType: 'image/png' });
  assert.ok(!saved.storageKey.startsWith('staging/'), '前缀是存储层的实现细节，不能写进库');
  assert.match(calls[0].url, /\/staging\/20260923\/s1\//);
  // 读的时候也要加回来，否则读不到刚写的东西。
  const { impl: impl2, calls: calls2 } = fakeFetch(() => ({ status: 200, bytes: Buffer.alloc(4) }));
  const store2 = createOssImageStore({ ...CREDS, prefix: 'staging', fetchImpl: impl2 });
  await store2.get(saved.storageKey);
  assert.match(calls2[0].url, /\/staging\/20260923\/s1\//);
});

test('内网 endpoint 生效（函数计算与桶同区域时省流量费）', async () => {
  const { impl, calls } = fakeFetch(() => ({ status: 404, text: ossErrorXml('NoSuchKey') }));
  const store = createOssImageStore({
    ...CREDS,
    endpoint: 'oss-cn-beijing-internal.aliyuncs.com',
    fetchImpl: impl,
  });
  await store.assertReady();
  assert.match(calls[0].url, /^https:\/\/xueban-photos\.oss-cn-beijing-internal\.aliyuncs\.com\//);
});

test('未配置时读写都诚实失败，不伪装成「照片不存在」', async () => {
  const store = createOssImageStore({});
  await assert.rejects(store.put({ studentId: 's', bytes: Buffer.alloc(4), mimeType: 'image/jpeg' }), /未配置/);
  await assert.rejects(store.get('20260923/s/a.jpg'), /未配置/);
});

// ─────────────────────────────────────────────────────────────
// endpoint 的输入形态
// ─────────────────────────────────────────────────────────────
//
// 这一组的存在理由很具体：OSS 控制台上「访问域名」那一栏**就是**带
// `https://` 的完整 URL，而使用者会照抄。不做归一化的话 host 会被拼成
// `xueban-photos.https://oss-...`，`fetch` 抛的是 `Failed to parse URL`
// —— 那句话指不出是哪个变量错了，排查方向会先跑到桶名上。

test('endpoint 带 https:// 协议前缀：自动归一化，url 里不会出现两层协议', async () => {
  const { impl, calls } = fakeFetch(() => ({ status: 404, text: ossErrorXml('NoSuchKey') }));
  const store = createOssImageStore({
    ...CREDS,
    region: 'cn-hangzhou',
    endpoint: 'https://oss-cn-hangzhou.aliyuncs.com',
    fetchImpl: impl,
  });
  const r = await store.assertReady();
  assert.equal(r.ok, true);
  // 注意末尾那个 `[^/]`：只写 `com\//` 的话，**没归一化也能匹配**
  // （拼成 `com//2026...`，第一个 `/` 就满足了）—— 那样这条断言就看不见差别。
  assert.match(calls[0].url, /^https:\/\/xueban-photos\.oss-cn-hangzhou\.aliyuncs\.com\/[^/]/);
  // 归一化必须**不静默**：做了什么要说出来，否则「我明明填了 https」会变成疑惑。
  assert.match(r.note, /协议/);
  assert.match(r.note, /已自动去掉/);
});

test('endpoint 带尾斜杠：同样归一化', async () => {
  const { impl, calls } = fakeFetch(() => ({ status: 404, text: ossErrorXml('NoSuchKey') }));
  const store = createOssImageStore({
    ...CREDS,
    region: 'cn-hangzhou',
    endpoint: 'oss-cn-hangzhou.aliyuncs.com/',
    fetchImpl: impl,
  });
  const r = await store.assertReady();
  assert.equal(r.ok, true);
  // 同上：host 之后必须**紧跟一个非斜杠**，否则尾斜杠没剥掉也照样绿。
  assert.match(calls[0].url, /^https:\/\/xueban-photos\.oss-cn-hangzhou\.aliyuncs\.com\/[^/]/);
});

test('endpoint 填成带路径的 URL：点名 OSS_ENDPOINT，而不是抛 Invalid URL', async () => {
  const store = createOssImageStore({
    ...CREDS,
    endpoint: 'https://oss-cn-hangzhou.aliyuncs.com/abc',
  });
  const r = await store.assertReady();
  assert.equal(r.ok, false);
  assert.match(r.reason, /OSS_ENDPOINT/);
  assert.match(r.reason, /纯域名/);
});

test('endpoint 填成 bucket 域名：点名报错（否则症状是 NoSuchBucket，看着像桶名拼错）', async () => {
  const store = createOssImageStore({
    ...CREDS,
    endpoint: 'https://xueban-photos.oss-cn-hangzhou.aliyuncs.com',
  });
  const r = await store.assertReady();
  assert.equal(r.ok, false);
  assert.match(r.reason, /OSS_ENDPOINT/);
  // 文案里要能看出「会拼成什么」，否则使用者不知道该删哪一段。
  assert.match(r.reason, /xueban-photos\.xueban-photos\./);

  // 写路径也要走同一条判定，不能只挡读。
  await assert.rejects(
    store.put({ studentId: 's', bytes: Buffer.alloc(4), mimeType: 'image/jpeg' }),
    /OSS_ENDPOINT/,
  );
});

// ─────────────────────────────────────────────────────────────
// OSS_REGION 与 endpoint 里的区域必须一致
// ─────────────────────────────────────────────────────────────
//
// 签名按 OSS_REGION 算，请求打到 endpoint 的 host。两处不同区时服务端回 403
// —— 而它和「RAM 权限没给对」长得一模一样，排查会先跑去控制台重发密钥。
// 2026-09-24 差点真踩：控制台给的域名在杭州，配置里 region 写的是北京。

test('endpoint 的区域与 OSS_REGION 一致：正常通过（含 -internal 形态）', async () => {
  const { impl, calls } = fakeFetch(() => ({ status: 404, text: ossErrorXml('NoSuchKey') }));
  const store = createOssImageStore({
    ...CREDS,
    region: 'cn-hangzhou',
    endpoint: 'oss-cn-hangzhou-internal.aliyuncs.com',
    fetchImpl: impl,
  });
  const r = await store.assertReady();
  assert.equal(r.ok, true);
  assert.match(calls[0].url, /^https:\/\/xueban-photos\.oss-cn-hangzhou-internal\.aliyuncs\.com\//);
});

test('endpoint 的区域与 OSS_REGION 不一致：点名两个区域，别让它退化成一个 403', async () => {
  // CREDS.region 是 cn-beijing，而域名在杭州。
  const store = createOssImageStore({ ...CREDS, endpoint: 'oss-cn-hangzhou.aliyuncs.com' });
  const r = await store.assertReady();
  assert.equal(r.ok, false);
  assert.match(r.reason, /cn-hangzhou/);
  assert.match(r.reason, /cn-beijing/);
  assert.match(r.reason, /403/);
});

test('自定义域名（CNAME）：推不出区域就跳过这条检查，不误报', async () => {
  const { impl, calls } = fakeFetch(() => ({ status: 404, text: ossErrorXml('NoSuchKey') }));
  const store = createOssImageStore({
    ...CREDS,
    endpoint: 'img.example.com',
    fetchImpl: impl,
  });
  const r = await store.assertReady();
  assert.equal(r.ok, true);
  assert.match(calls[0].url, /^https:\/\/xueban-photos\.img\.example\.com\//);
});
