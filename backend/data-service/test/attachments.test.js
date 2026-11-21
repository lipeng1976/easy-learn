import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  ATTACHMENT_KINDS,
  DEFAULT_MAX_BYTES,
  MAX_COUNT,
  MIME_EXT,
  SUPPORTED_MIME_TYPES,
  extensionFor,
  kindOfMime,
  maxBytesFor,
  validateUpload,
} from '../src/attachments.js';
import { createImageStore } from '../src/imagestore.js';
import { createOssImageStore } from '../src/ossimagestore.js';

/**
 * 附件类型、白名单与按类型分别的大小上限。
 *
 * ## 这个文件守着什么
 *
 * 加音频/视频之前，「哪些类型合法」只有图片一种答案，所以写错也看不出来。
 * 现在有三类，而**每一类的上限不同**（照片 8MB、音频 20MB、视频 100MB）——
 * 于是出现一整类新的静默失败：
 *
 *   · 上限**取成同一个数**：取大的话照片不受保护，取小的话视频传不上来。
 *     「传不上来」有报错但报错内容对不上（说 8MB 超了、其实该给 100MB），
 *     排查方向会被带到「文件是不是太大了」上去。
 *   · MIME 白名单**只在一处扩了**：文件系统后端能存、对象存储后端存不了
 *     （或反过来），而两种部署各自都「本地全绿」。
 *
 * ## 数字手抄，不 import
 *
 * 与 `photo-quota.test.js` 同一条理由：import 过来会让「有人把 100MB 改成 5MB」
 * 这类改动**同时改掉断言**，判据就跟着被测代码漂了。手抄的代价是
 * 「改了就红」，而那正是要的 —— 上限是产品口径，改它必须是一次有意识的决定。
 */

/** 产品口径，**手抄**（对应客户端 `attachment_limits.dart` 的同一组数）。 */
const EXPECTED_MAX_BYTES = { image: 8, audio: 20, video: 100 }; // MB
const EXPECTED_MAX_COUNT = { image: 9, audio: 3, video: 1 };

const MB = 1024 * 1024;

// ─────────────────────────────────────────────────────────────
// ① 归类：认不出必须是 null，不许兜底成图片
// ─────────────────────────────────────────────────────────────

test('kindOfMime：按类型前缀归类，大小写不敏感', () => {
  assert.equal(kindOfMime('image/jpeg'), 'image');
  assert.equal(kindOfMime('audio/mpeg'), 'audio');
  assert.equal(kindOfMime('video/mp4'), 'video');
  assert.equal(kindOfMime('IMAGE/PNG'), 'image');
  assert.equal(kindOfMime('  audio/wav  '), 'audio');
});

test('kindOfMime：认不出一律 null —— **不兜底成 image**', () => {
  // 这条是文件里最重要的一条。兜底成 image 的表现是：一段音频以「图片」的
  // 身份被送进视觉模型，而模型对不认识的内容是**静默丢弃**的 ——
  // 不报错，只是批改结果里这个附件凭空消失（见 doc/open-items.md B29）。
  assert.equal(kindOfMime('application/pdf'), null);
  assert.equal(kindOfMime('text/plain'), null);
  assert.equal(kindOfMime('imagex/jpeg'), null, '前缀必须是完整的一段，不是 startsWith');
  assert.equal(kindOfMime('/jpeg'), null);
  assert.equal(kindOfMime(''), null);
  assert.equal(kindOfMime(undefined), null);
  assert.equal(kindOfMime(null), null);
});

test('extensionFor：三类都认，认不出是空串而不是 .bin', () => {
  assert.equal(extensionFor('image/heic'), '.heic');
  assert.equal(extensionFor('audio/mpeg'), '.mp3');
  assert.equal(extensionFor('audio/mp4'), '.m4a');
  assert.equal(extensionFor('video/quicktime'), '.mov');
  assert.equal(extensionFor('video/3gpp'), '.3gp');
  assert.equal(extensionFor('application/pdf'), '');
  assert.equal(extensionFor(''), '');
});

test('ATTACHMENT_KINDS 与 MIME_EXT 的前缀集合一致（没有孤儿类型）', () => {
  for (const mime of SUPPORTED_MIME_TYPES) {
    assert.notEqual(kindOfMime(mime), null, `${mime} 的前缀不在 ATTACHMENT_KINDS 里`);
  }
  for (const kind of ATTACHMENT_KINDS) {
    const any = SUPPORTED_MIME_TYPES.some((m) => m.startsWith(`${kind}/`));
    assert.ok(any, `${kind} 一种 MIME 都没有`);
  }
});

// ─────────────────────────────────────────────────────────────
// ② 上限：**按类型分别取**，且默认值就是产品定的那一组
// ─────────────────────────────────────────────────────────────

test('默认上限逐类型核对：照片 8MB / 音频 20MB / 视频 100MB', () => {
  for (const [kind, mb] of Object.entries(EXPECTED_MAX_BYTES)) {
    assert.equal(
      DEFAULT_MAX_BYTES.get(kind),
      mb * MB,
      `${kind} 的默认上限不是 ${mb}MB —— 改了产品口径就要同步改这条断言`,
    );
  }
});

test('默认数量逐类型核对：照片 9 / 音频 3 / 视频 1', () => {
  for (const [kind, n] of Object.entries(EXPECTED_MAX_COUNT)) {
    assert.equal(MAX_COUNT.get(kind), n, `${kind} 的数量上限不是 ${n}`);
  }
});

test('validateUpload：照片在自己的上限之内通过、超一个字节就 413', () => {
  const atLimit = Buffer.alloc(EXPECTED_MAX_BYTES.image * MB);
  const ok = validateUpload({ bytes: atLimit, mimeType: 'image/jpeg' });
  assert.equal(ok.kind, 'image');
  assert.equal(ok.ext, '.jpg');

  const over = Buffer.alloc(EXPECTED_MAX_BYTES.image * MB + 1);
  assert.throws(
    () => validateUpload({ bytes: over, mimeType: 'image/jpeg' }),
    (e) => {
      assert.equal(e.code, 'payload_too_large');
      // 报错要带**这个类型**的上限：只说「文件过大」的话，
      // 用户不知道是哪个文件、也不知道能传多大。
      assert.equal(e.details.limit, EXPECTED_MAX_BYTES.image * MB);
      assert.equal(e.details.kind, 'image');
      assert.match(e.message, /照片/);
      return true;
    },
  );
});

test('validateUpload：**不同类型取不同上限** —— 用同一份字节验两边结论相反', () => {
  // 这是「上限按类型分别取」的直接判据。如果实现退回「一个 maxBytes 管所有类型」，
  // 那么同尺寸的字节在两类上会得到**同一个结论**，其中必有一条变红。
  const size = 12 * MB; // 超过照片 8MB，但在音频 20MB 之内
  const bytes = Buffer.alloc(size);

  assert.throws(
    () => validateUpload({ bytes, mimeType: 'image/jpeg' }),
    (e) => e.code === 'payload_too_large',
    '12MB 的照片应当被拒（照片上限 8MB）',
  );

  const audioOk = validateUpload({ bytes, mimeType: 'audio/mpeg' });
  assert.equal(audioOk.kind, 'audio', '12MB 的音频应当通过（音频上限 20MB）');
});

test('validateUpload：视频走 100MB 这一档，且报错带上「视频」', () => {
  const custom = { video: 1024 }; // 用小值验边界，避免真的分配 100MB
  assert.throws(
    () => validateUpload({ bytes: Buffer.alloc(1025), mimeType: 'video/mp4', maxBytesByKind: custom }),
    (e) => {
      assert.equal(e.code, 'payload_too_large');
      assert.match(e.message, /视频/);
      assert.equal(e.details.limit, 1024);
      return true;
    },
  );
  const ok = validateUpload({ bytes: Buffer.alloc(1024), mimeType: 'video/mp4', maxBytesByKind: custom });
  assert.equal(ok.kind, 'video');
  assert.equal(ok.ext, '.mp4');
});

test('validateUpload：空内容与非白名单类型分别报 400', () => {
  assert.throws(
    () => validateUpload({ bytes: Buffer.alloc(0), mimeType: 'image/jpeg' }),
    (e) => e.code === 'bad_request' && /为空/.test(e.message),
  );
  assert.throws(
    () => validateUpload({ bytes: Buffer.alloc(4), mimeType: 'application/pdf' }),
    (e) => e.code === 'bad_request' && /不支持/.test(e.message),
  );
});

test('maxBytesFor：没给覆盖表时回落到默认值，给了就按类型取', () => {
  assert.equal(maxBytesFor(undefined, 'video'), EXPECTED_MAX_BYTES.video * MB);
  assert.equal(maxBytesFor({}, 'audio'), EXPECTED_MAX_BYTES.audio * MB);
  assert.equal(maxBytesFor({ audio: 123 }, 'audio'), 123);
  // 覆盖表里没有这一类型时，仍然回落 —— 不能变成 0 或 undefined
  assert.equal(maxBytesFor({ audio: 123 }, 'video'), EXPECTED_MAX_BYTES.video * MB);
  // Map 形态也要认（工厂产出的是 Map）
  assert.equal(maxBytesFor(new Map([['image', 7]]), 'image'), 7);
  // 非正数/非数字一律回落，而不是把上限设成 0（那会让什么都传不上去）
  assert.equal(maxBytesFor({ image: 0 }, 'image'), EXPECTED_MAX_BYTES.image * MB);
  assert.equal(maxBytesFor({ image: 'oops' }, 'image'), EXPECTED_MAX_BYTES.image * MB);
});

// ─────────────────────────────────────────────────────────────
// ③ 两种后端共用的校验段必须一致（不许一边放宽）
// ─────────────────────────────────────────────────────────────

test('文件系统与对象存储后端对同一份非法输入给出**同一个**结论', async () => {
  const { mkdtempSync, rmSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const nodePath = await import('node:path');

  const dir = mkdtempSync(nodePath.join(tmpdir(), 'easylearn-att-'));
  try {
    const fsStore = createImageStore({ rootDir: dir, maxBytesByKind: { image: 16 } });
    const ossStore = createOssImageStore({
      bucket: 'b',
      region: 'cn-hangzhou',
      accessKeyId: 'AK',
      accessKeySecret: 'SK',
      maxBytesByKind: { image: 16 },
      fetchImpl: async () => ({ status: 200, text: async () => '' }),
    });

    for (const store of [fsStore, ossStore]) {
      const label = store === fsStore ? 'fs' : 'oss';
      await assert.rejects(
        () => store.put({ studentId: 's', bytes: Buffer.alloc(17), mimeType: 'image/jpeg' }),
        (e) => e.code === 'payload_too_large',
        `${label}: 17 字节超过 16 的上限，应当 413`,
      );
      await assert.rejects(
        () => store.put({ studentId: 's', bytes: Buffer.alloc(4), mimeType: 'application/pdf' }),
        (e) => e.code === 'bad_request',
        `${label}: 非白名单类型应当 400`,
      );
      await assert.rejects(
        () => store.put({ studentId: 's', bytes: Buffer.alloc(0), mimeType: 'image/jpeg' }),
        (e) => e.code === 'bad_request',
        `${label}: 空内容应当 400`,
      );
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ─────────────────────────────────────────────────────────────
// ④ 直传签发：只有对象存储能做，文件系统**必须没有这个方法**
// ─────────────────────────────────────────────────────────────

test('文件系统后端没有 signDirectPut —— 直传在它上面结构上不成立', () => {
  const store = createImageStore({ rootDir: '/tmp/whatever' });
  assert.equal(
    typeof store.signDirectPut,
    'undefined',
    '文件系统不是一个 HTTP 服务，没有可直传的端点；给出一个假 URL 比报错更坏',
  );
});

test('signDirectPut：键带正确后缀，头里三样齐备且签名覆盖该对象', () => {
  const store = createOssImageStore({
    bucket: 'xueban-photos',
    region: 'cn-beijing',
    accessKeyId: 'AK',
    accessKeySecret: 'SK',
  });

  const signed = store.signDirectPut({ studentId: 'stu_1', mimeType: 'video/mp4', maxBytes: 50 * MB });
  assert.notEqual(signed, null);
  assert.match(signed.storageKey, /\.mp4$/, '落盘后缀要能反映类型');
  // ⚠️ **桶名必须在子域上**（虚拟主机风格）。这一行原先断言的是
  //    `https://oss-cn-beijing.aliyuncs.com/…` —— 那是**修之前**的形态，
  //    而它一直没人发现，因为这个文件当时**没被 run-tests.mjs 纳入**
  //    （2026-10-03 补上，见该文件清单）。漏掉桶名的实测后果是
  //    OSS 把键的第一段当桶名回 `NoSuchBucket`，看着像桶名配错了。
  assert.match(signed.uploadUrl, /^https:\/\/xueban-photos\.oss-cn-beijing\.aliyuncs\.com\//);
  assert.ok(signed.uploadUrl.endsWith(signed.storageKey), 'URL 必须指向同一个键');

  // 客户端要**原样发送**这几个头 —— 少一个就是签名不匹配。
  assert.match(signed.headers.authorization, /^OSS4-HMAC-SHA256 Credential=AK\//);
  assert.equal(signed.headers['x-oss-content-sha256'], 'UNSIGNED-PAYLOAD');
  assert.match(String(signed.headers['x-oss-date']), /^\d{8}T\d{6}Z$/);
  assert.equal(signed.headers['content-type'], 'video/mp4');
  assert.equal(signed.expiresIn, 900);
  assert.equal(signed.maxBytes, 50 * MB);
});

test('signDirectPut：类型不支持或存储未就绪时返回 null（不编一个假位置出来）', () => {
  const ready = createOssImageStore({
    bucket: 'b', region: 'cn-hangzhou', accessKeyId: 'AK', accessKeySecret: 'SK',
  });
  assert.equal(ready.signDirectPut({ studentId: 's', mimeType: 'application/pdf', maxBytes: 1 }), null);

  const notReady = createOssImageStore({ bucket: '', region: '', accessKeyId: '', accessKeySecret: '' });
  assert.equal(notReady.ready, false);
  assert.equal(notReady.signDirectPut({ studentId: 's', mimeType: 'video/mp4', maxBytes: 1 }), null);
});

// ─────────────────────────────────────────────────────────────
// ⑤ 直读签发：修掉「传得上去、取不回来」
// ─────────────────────────────────────────────────────────────
//
// 背景（doc/open-items.md B32）：函数计算的**响应体**上限是 32 MiB，
// 而视频上限 50 MB —— 超过 32 MiB 的视频走 `images/file` 取不回来（400
// ResponseTooLarge）。修法与上传侧对称：服务端只签名，客户端直连对象存储。
//
// ⚠️ 这里判的是**签出来的东西长什么样**，不是「OSS 收不收」。后者只有
// `scripts/probe-readback-ceiling.mjs` 用真凭证说了算。

test('文件系统后端没有 signDirectGet —— 直读在它上面同样结构上不成立', () => {
  const store = createImageStore({ rootDir: '/tmp/whatever' });
  assert.equal(
    typeof store.signDirectGet,
    'undefined',
    '文件系统不是一个 HTTP 服务，没有可直读的端点；设备上那条路是「字节先落盘」',
  );
});

test('⭐ signDirectGet：地址**不带查询串**、桶名在子域、只有两个 x-oss 头参与签名', () => {
  const stamp = '20261003T071500Z';
  const store = createOssImageStore({
    bucket: 'xueban-photos',
    region: 'cn-hangzhou',
    accessKeyId: 'AK',
    accessKeySecret: 'SK',
    now: () => Date.parse('2026-10-03T07:15:00Z'),
  });

  const signed = store.signDirectGet('20261003/stu_1/abc.mp4');
  assert.notEqual(signed, null);

  const url = new URL(signed.readUrl);
  // 桶名必须在**子域**上。漏掉它的形态（路径风格）会让 OSS 把键的第一段
  // 当桶名，回 `NoSuchBucket` —— 看着像桶名配错（上传侧栽过一次，见 signDirectPut）。
  assert.equal(url.host, 'xueban-photos.oss-cn-hangzhou.aliyuncs.com');
  assert.ok(signed.readUrl.endsWith('20261003/stu_1/abc.mp4'));
  // ⚠️ 这条是本组最值钱的一条：签名是按**空** CanonicalQueryString 算的
  //    （见 buildCanonicalRequest）。地址上多出任何一个查询参数，
  //    OSS 算出来的规范请求就与签名的那份不同 → SignatureDoesNotMatch，
  //    而那个错误看起来像 AccessKey 填错了。
  assert.equal(url.search, '');

  // GET 没有请求体 ⇒ 不签 content-*。多签一个，客户端就得凭空多发一个头，
  // 「签的」与「发的」不一致的风险平白多一处。
  assert.equal(signed.headers['content-type'], undefined);
  assert.equal(signed.headers['content-md5'], undefined);
  assert.deepEqual(
    Object.keys(signed.headers).sort(),
    ['authorization', 'x-oss-content-sha256', 'x-oss-date'],
  );
  // 客户端要**原样发送**这几个头（少一个就是签名不匹配）。
  assert.match(signed.headers.authorization, /^OSS4-HMAC-SHA256 Credential=AK\//);
  assert.equal(signed.headers['x-oss-content-sha256'], 'UNSIGNED-PAYLOAD');
  assert.equal(signed.headers['x-oss-date'], stamp);
  // Authorization 里的 scope 日期必须与 x-oss-date 同一天 —— 两者不一致时
  // 同样只回 SignatureDoesNotMatch，而看不出是哪一处不同步。
  assert.match(signed.headers.authorization, /Credential=AK\/20261003\/cn-hangzhou\/oss\/aliyun_v4_request/);

  // 有效期如实回传：它不是「这个地址能用多久」，而是 OSS 的 V4 时钟窗。
  assert.equal(signed.expiresIn, 900);
});

test('signDirectGet：未就绪 / 旧的设备本地标识一律 null（不签一个必然 404 的地址）', () => {
  const notReady = createOssImageStore({ bucket: '', region: '', accessKeyId: '', accessKeySecret: '' });
  assert.equal(notReady.ready, false);
  assert.equal(notReady.signDirectGet('20261003/stu_1/abc.mp4'), null);

  const ready = createOssImageStore({
    bucket: 'b', region: 'cn-hangzhou', accessKeyId: 'AK', accessKeySecret: 'SK',
  });
  // 旧数据的字节只在当初那台设备上，对象存储里没有这个对象 ——
  // 签出来必然 404，而客户端要的是「回退本地读」这条正路（见 routes 的 reason）。
  assert.equal(ready.signDirectGet('memory://students/x/homework/img_1.jpg'), null);
  assert.equal(ready.signDirectGet('/data/user/0/com.x/files/img.jpg'), null);
  assert.equal(ready.signDirectGet(''), null);
});
