import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { createApp } from '../src/app.js';
import { assertAuthRoleScoped, assertRlsEnforced, createPool } from '../src/db.js';
import { ErrorCodes } from '../../shared/errors.js';
import { createImageStore, isServerImageKey } from '../src/imagestore.js';
import { createImageStoreFor } from '../src/image-store-factory.js';

/**
 * 作业照片的**字节**链路：上传 → 落盘 → 入库 → 家长端按 id 读回。
 *
 * ## 这个文件守着的那件事
 *
 * 在它之前，「照片家长端看不到」是一个**没有症状**的故障：图片位置一片空白、
 * 不报错、不影响任何其它功能。根因有两层，而且**两层都要治**：
 *
 *   ① 键的语义 —— `storage_key` 存的是**设备本地标识**（原生端绝对路径 /
 *      Web 端浏览器存储键）。换个设备必然读不到。所以键必须变成
 *      「相对存储根目录的路径」，再由服务端解释。
 *   ② 字节的搬运 —— 字节此前**从未离开过学生那台设备**。服务端表里
 *      只有元数据，一个字节列都没有。
 *
 * ## 用例里最值钱的两条
 *
 * · **字节逐字节相同的断言**（含非 UTF-8 字节）：整条链路上任何一处
 *   把 Buffer 当字符串（`toString('utf8')`）都会静默损坏图片 ——
 *   不报错，只得到一张打不开的图。
 * · **权限正反对照**：同一条图片记录，结伴家长读得到（200）、
 *   别的学生读不到（404）。少任何一半，这条测试都可以被一个
 *   「永远返回 200」的实现骗过去。
 *
 * 跑法：`npm test`（先起本机 PG）。
 */

const SECRET = 'test-secret-not-for-production';

const PG = {
  host: process.env.TEST_PG_HOST,
  port: Number(process.env.TEST_PG_PORT ?? 0),
  database: process.env.TEST_PG_DATABASE,
  adminUser: process.env.TEST_PG_ADMIN_USER,
  adminPassword: process.env.TEST_PG_ADMIN_PASSWORD,
  appUser: process.env.TEST_PG_APP_USER,
  appPassword: process.env.TEST_PG_APP_PASSWORD,
  authUser: process.env.TEST_PG_AUTH_USER,
  authPassword: process.env.TEST_PG_AUTH_PASSWORD,
};

const PASSWORD = 'abc123';
/** 刻意避开演示号段与 auth.test.js 的号段，避免同一库里互相踩。 */
const STU_PHONE = '13800003001';
const OTHER_PHONE = '13800003002';
const PAR_PHONE = '13800003003';

/**
 * 一张**假的**作业照片。
 *
 * 前四个字节是真的 JPEG 魔数（`FF D8 FF E0`），后面全是**非 UTF-8**
 * 的字节（`FF`、`FE`、`80` 单独出现都不是合法 UTF-8 序列）。
 * 它们就是这条用例存在的理由：任何一处把 Buffer 当字符串处理，
 * 这些字节都会变成 U+FFFD，而比对上必然失败。
 */
const PHOTO = Buffer.from([
  0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00,
  0x01, 0x80, 0xfe, 0xff, 0x00, 0x9c, 0xa5, 0xc3, 0x28, 0xf0, 0xff,
]);

let adminPool;
let appPool;
let authPool;
let app;
let imageRoot;

async function call(method, pathname, { token, query, body } = {}) {
  const res = await app({
    method,
    pathname,
    query: query ?? {},
    headers: token === undefined ? {} : { authorization: `Bearer ${token}` },
    body: body ?? {},
  });
  return { status: res.status, json: JSON.parse(res.body) };
}

/** 原始字节请求 / 原始响应。照片这条路**不能**过 JSON 解析（两端都不行）。 */
async function raw(method, pathname, { token, query, bytes, contentType } = {}) {
  return app({
    method,
    pathname,
    query: query ?? {},
    headers: {
      ...(token === undefined ? {} : { authorization: `Bearer ${token}` }),
      ...(contentType === undefined ? {} : { 'content-type': contentType }),
    },
    body: {},
    bytes: bytes ?? null,
  });
}

const register = (body) => call('POST', '/auth/register', { body });
const login = (body) => call('POST', '/auth/login', { body });

let stuId;
let stuToken;
let otherId;
let otherToken;
let parId;
let parToken;

before(async () => {
  if (!PG.host || !PG.database) {
    throw new Error(
      '照片验收需要 PostgreSQL：请用 `npm test` 运行（它会起本机 PG），'
        + '或提供 TEST_PG_HOST / TEST_PG_DATABASE 等环境变量指向已有实例。',
    );
  }

  adminPool = createPool({
    host: PG.host, port: PG.port, database: PG.database,
    user: PG.adminUser, password: PG.adminPassword, max: 2,
  });
  await adminPool.query(`
    delete from homework_image;
    delete from homework;
    delete from relationship;
    delete from app_user;
  `);

  appPool = createPool({
    host: PG.host, port: PG.port, database: PG.database,
    user: PG.appUser, password: PG.appPassword, max: 4,
  });
  authPool = createPool({
    host: PG.host, port: PG.port, database: PG.database,
    user: PG.authUser, password: PG.authPassword, max: 4,
  });

  assert.equal(await assertRlsEnforced(appPool), PG.appUser);
  assert.equal(await assertAuthRoleScoped(authPool), PG.authUser);

  // 每次跑都用**全新的空目录**：上一次跑落的文件不能参与这一次的判据，
  // 否则「文件其实没写成功、但上一轮的还在」会被读成通过。
  imageRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'easylearn-img-'));
  const imageStore = createImageStore({ rootDir: imageRoot });

  app = createApp({ pool: appPool, authPool, sessionSecret: SECRET, imageStore });

  const stu = await register({ phone: STU_PHONE, password: PASSWORD, role: 'student' });
  assert.equal(stu.status, 200, JSON.stringify(stu.json));
  stuId = stu.json.data.user.id;
  stuToken = stu.json.data.token;

  const other = await register({ phone: OTHER_PHONE, password: PASSWORD, role: 'student' });
  otherId = other.json.data.user.id;
  otherToken = other.json.data.token;

  const par = await register({ phone: PAR_PHONE, password: PASSWORD, role: 'parent' });
  parId = par.json.data.user.id;
  parToken = par.json.data.token;
});

after(async () => {
  await appPool?.end().catch(() => {});
  await authPool?.end().catch(() => {});
  await adminPool?.end().catch(() => {});
  if (imageRoot) fs.rmSync(imageRoot, { recursive: true, force: true });
});

// ===== ① 键的判别（纯函数，不碰库）=====

test('键的判别：只认服务端相对键，旧的设备本地标识一律不认', () => {
  assert.equal(isServerImageKey('20260920/36e392cd-ab12/f3a1c2d4.jpg'), true);

  // 旧标识三种写法，都要被认出来（认出它们才能回退本地读，而不是报损坏）。
  assert.equal(isServerImageKey('memory://students/x/homework/img_1.jpg'), false, 'Web 端浏览器存储键');
  assert.equal(isServerImageKey('/data/user/0/com.x/files/img.jpg'), false, '原生端绝对路径');
  assert.equal(isServerImageKey('C:\\Users\\me\\Documents\\img.jpg'), false, 'Windows 绝对路径');

  // 穿越：`..` 段必须被挡。正则的字符类含 `.`，所以它**能**匹到 `20260920/abc/..`，
  // 靠的是段级那一次收口 —— 少那一次收口，这条就会红。
  assert.equal(isServerImageKey('20260920/abc/..'), false);
  assert.equal(isServerImageKey('20260920/../../etc/passwd'), false);
  assert.equal(isServerImageKey(''), false);
  assert.equal(isServerImageKey(null), false);
});

test('落盘与读回：字节必须**逐字节相同**（含非 UTF-8 字节）', async () => {
  const store = createImageStore({ rootDir: imageRoot });
  const saved = await store.put({ studentId: 'stu-1', bytes: PHOTO, mimeType: 'image/jpeg' });

  // 键的形状：日期目录 / 学生 / uuid + 扩展名。
  // uuid 而不是递增序号 —— 并发不撞键，且不可被猜路径。
  assert.match(saved.storageKey, /^\d{8}\/stu-1\/[0-9a-f-]{36}\.jpg$/);
  assert.equal(saved.byteSize, PHOTO.length);
  assert.equal(saved.mimeType, 'image/jpeg');

  const back = await store.get(saved.storageKey);
  assert.equal(Buffer.compare(back, PHOTO), 0, '读回的字节与写入的不一致 —— 链路上有地方把 Buffer 当字符串了');
});

test('旧标识取字节：回「不在服务端」，而不是「文件丢了」', async () => {
  const store = createImageStore({ rootDir: imageRoot });
  await assert.rejects(
    () => store.get('memory://students/x/homework/img_1.jpg'),
    (e) => {
      assert.equal(e.code, ErrorCodes.notFound);
      // 客户端**只靠这个值**区分两种 404：这一种要回退本地读。
      assert.equal(e.details?.reason, 'not_on_server');
      return true;
    },
  );
});

test('体积与类型：超限 413、不支持的 MIME 400（都不落盘）', async () => {
  // ⚠️ **必须用独立目录**。共用 `imageRoot` 的话，「盘上什么都没留下」
  // 这条断言会被前面用例落的文件搞红 —— 而那不是被测代码的问题，
  // 是这条用例自己把一个「空目录」当成了前提。
  const alone = fs.mkdtempSync(path.join(os.tmpdir(), 'easylearn-img-reject-'));
  try {
    // ⚠️ 上限**按类型分别给**（不再是「一个 maxBytes 管所有类型」）：
    //    一个数字同时管 8MB 的照片和 50MB 的视频只能是两者之一。
    const store = createImageStore({ rootDir: alone, maxBytesByKind: { image: 16 } });

    await assert.rejects(
      () => store.put({ studentId: 's', bytes: Buffer.alloc(17), mimeType: 'image/jpeg' }),
      (e) => {
        assert.equal(e.code, ErrorCodes.payloadTooLarge);
        return true;
      },
    );
    await assert.rejects(
      () => store.put({ studentId: 's', bytes: Buffer.from([1, 2]), mimeType: 'application/pdf' }),
      (e) => {
        assert.equal(e.code, ErrorCodes.badRequest);
        return true;
      },
    );
    await assert.rejects(
      () => store.put({ studentId: 's', bytes: Buffer.alloc(0), mimeType: 'image/jpeg' }),
      (e) => {
        assert.equal(e.code, ErrorCodes.badRequest);
        return true;
      },
    );
    // 被拒的三次都不该在盘上留下东西 —— 包括**半截的 `.tmp`**。
    assert.deepEqual(fs.readdirSync(alone), [], '被拒绝的上传不该在存储根目录里留下任何文件');
  } finally {
    fs.rmSync(alone, { recursive: true, force: true });
  }
});

// ===== ② 端到端：上传 → 入库 → 家长读回 =====

let imageId;
/** 与 [imageId] 配套的**相对键** —— 直读那条路的判据要用它（见 ②b）。 */
let imageStorageKey;

test('上传：原始字节进、相对键出（库里存的必须是相对键，不是设备路径）', async () => {
  const up = await raw('POST', '/data/homework/images/upload', {
    token: stuToken,
    query: { studentId: stuId, fileName: '今天的作业.jpg', mimeType: 'image/jpeg' },
    bytes: PHOTO,
    contentType: 'image/jpeg',
  });
  assert.equal(up.status, 200, String(up.body));

  const saved = JSON.parse(up.body).data;
  assert.match(saved.storageKey, /^\d{8}\//, 'storageKey 必须是相对键');
  assert.equal(saved.byteSize, PHOTO.length);
  assert.equal(saved.fileName, '今天的作业.jpg', '中文文件名要在 query 里活着走完一趟');

  // 盘上真的多了一个文件 —— 「返回了一个键」和「字节真的落了盘」是两件事。
  const onDisk = fs.readdirSync(imageRoot, { recursive: true }).length;
  assert.ok(onDisk > 0, '存储根目录下应当出现文件');

  const row = await call('POST', '/data/homework/images', {
    token: stuToken,
    body: {
      studentId: stuId,
      storageKey: saved.storageKey,
      fileName: '今天的作业.jpg',
      fileSize: saved.byteSize,
      mimeType: 'image/jpeg',
    },
  });
  assert.equal(row.status, 200, JSON.stringify(row.json));
  imageId = row.json.data.items[0].id;
  imageStorageKey = saved.storageKey;
  assert.equal(row.json.data.items[0].storageKey, saved.storageKey);
});

test('读图：家长结伴前读不到（正反对照的反面）', async () => {
  const res = await raw('GET', '/data/homework/images/file', {
    token: parToken,
    query: { id: imageId },
  });
  assert.equal(res.status, 404, '还没结伴就看得到孩子的照片 —— 可见性没收口');
});

test('读图：结伴后家长读回**同样的字节**，且缓存头是 private', async () => {
  await adminPool.query(
    `insert into relationship (id, student_id, parent_id, sender_id, status)
     values ('rel_img_e2e', $1, $2, $2, 'active')`,
    [stuId, parId],
  );

  const res = await raw('GET', '/data/homework/images/file', {
    token: parToken,
    query: { id: imageId },
  });
  assert.equal(res.status, 200, String(res.body));
  assert.equal(res.headers['content-type'], 'image/jpeg');
  assert.equal(res.headers['content-length'], String(PHOTO.length));
  // 学生作业照片**不能**进共享缓存：public 会让中间任何一层缓存
  // 把它存下来、并且可能回给另一个用户。
  assert.match(String(res.headers['cache-control']), /private/);

  assert.equal(
    Buffer.compare(Buffer.from(res.body), PHOTO),
    0,
    '家长读到的字节与孩子上传的不一致 —— 这正是「照片打不开」的形态',
  );
});

test('读图：别的学生读不到（正反对照的正面）', async () => {
  const res = await raw('GET', '/data/homework/images/file', {
    token: otherToken,
    query: { id: imageId },
  });
  assert.equal(res.status, 404, '别人的照片读到了 —— RLS 这条路漏了');
});

test('读图：不存在的 id 回 404，且与「无权」不可区分', async () => {
  const res = await raw('GET', '/data/homework/images/file', {
    token: stuToken,
    query: { id: 'img_does_not_exist' },
  });
  assert.equal(res.status, 404);
  const json = JSON.parse(res.body);
  assert.equal(json.error.code, ErrorCodes.notFound);
  // 刻意**不给** reason：能区分「不存在」与「存在但无权」的响应
  // 就是一个存在性探针（拿别人的 id 来试，看是 404 还是 403）。
  assert.equal(json.error.details?.reason, undefined);
});

test('读图：旧版设备本地标识 → 404 带 not_on_server（客户端据此回退本地读）', async () => {
  const row = await call('POST', '/data/homework/images', {
    token: stuToken,
    body: {
      studentId: stuId,
      storageKey: 'memory://students/old/homework/img_9.jpg',
      fileName: '老照片.jpg',
      fileSize: 10,
      mimeType: 'image/jpeg',
    },
  });
  const legacyId = row.json.data.items[0].id;

  const res = await raw('GET', '/data/homework/images/file', {
    token: stuToken,
    query: { id: legacyId },
  });
  assert.equal(res.status, 404);
  const json = JSON.parse(res.body);
  assert.equal(json.error.details?.reason, 'not_on_server');
});

// ===== ②b 直读签发（修 B32：超过 32 MiB 的附件传得上去、取不回来）=====
//
// 函数计算的**响应体**上限是 32 MiB，而视频上限 50 MB ⇒ 走上面那条
// `images/file` 的话，超过 32 MiB 的视频播不了。修法是让字节不经过函数：
// 服务端签一个对象存储的直读位置，客户端自己去取（还能流式播放）。
//
// ⚠️ 本组刻意**不碰 OSS**：signDirectGet 是纯签名、不发请求，
// 所以「地址长什么样」可以在本机判。真正「取不取得到」由
// `scripts/probe-readback-ceiling.mjs` 用真凭证在云端说了算。

test('直读签发：文件系统后端**没有**这条路 —— 如实回 503，而不是编一个假地址', async () => {
  const res = await call('GET', '/data/homework/images/sign-read', {
    token: stuToken,
    query: { id: imageId },
  });
  assert.equal(res.status, 503, JSON.stringify(res.json));
  assert.equal(res.json.error.code, ErrorCodes.uploadNotConfigured);
  // 客户端靠 code + reason 认出「这条路在本部署上不存在」，回落到字节那条路
  // （那条路在 fs 后端上本来就走得通）。少了它，客户端会把 503 当成故障。
  assert.equal(res.json.error.details?.reason, 'direct_read_unsupported');
});

test('直读签发：归属**先于**能力 —— 别人的 id 在哪种后端上都是 404', async () => {
  // 顺序是有意义的：先判能力的话，fs 后端上「自己的照片」与「别人的照片」
  // 会回同一个 503，而这个接口不该能当存在性探针用（同 `images/file` 的 404 口径）。
  const mine = await call('GET', '/data/homework/images/sign-read', {
    token: stuToken,
    query: { id: imageId },
  });
  const theirs = await call('GET', '/data/homework/images/sign-read', {
    token: otherToken,
    query: { id: imageId },
  });
  assert.equal(theirs.status, 404, '别人的照片被签出来了 —— RLS 这条路漏了');
  assert.notEqual(theirs.status, mine.status, '两边同码 = 归属没在能力之前判');
});

test('⭐ 直读签发（对象存储）：地址不带查询串、指向同一个键、只签两个 x-oss 头', async () => {
  const ossStore = createImageStoreFor({
    IMAGE_DRIVER: 'oss',
    OSS_BUCKET: 'xueban-test',
    OSS_REGION: 'cn-hangzhou',
    OSS_ACCESS_KEY_ID: 'AK',
    OSS_ACCESS_KEY_SECRET: 'SK',
  });
  assert.equal(ossStore.ready, true);

  const ossApp = createApp({
    pool: appPool, authPool, sessionSecret: SECRET, imageStore: ossStore,
  });
  const res = await ossApp({
    method: 'GET',
    pathname: '/data/homework/images/sign-read',
    query: { id: imageId },
    headers: { authorization: `Bearer ${stuToken}` },
    body: {},
  });
  assert.equal(res.status, 200, res.body);
  const data = JSON.parse(res.body).data;

  const url = new URL(data.readUrl);
  // 桶名在**子域**上（虚拟主机风格）。漏掉它的形态会让 OSS 把键的第一段
  // 当桶名回 `NoSuchBucket`，看起来像桶名配错。
  assert.equal(url.host, 'xueban-test.oss-cn-hangzhou.aliyuncs.com');
  // ⚠️ 签名是按**空**查询串算的 —— 地址上多一个参数就 SignatureDoesNotMatch，
  // 而那个错误看起来像 AccessKey 填错。
  assert.equal(url.search, '');
  // 行里存的那个键必须原样出现在地址里：签的与给的同一个对象。
  assert.ok(
    data.readUrl.endsWith(String(imageStorageKey)),
    `${data.readUrl} 没有指向行里那个键 ${imageStorageKey}`,
  );

  assert.match(data.headers.authorization, /^OSS4-HMAC-SHA256 Credential=AK\//);
  assert.equal(data.headers['x-oss-content-sha256'], 'UNSIGNED-PAYLOAD');
  assert.match(String(data.headers['x-oss-date']), /^\d{8}T\d{6}Z$/);
  assert.equal(data.expiresIn, 900);
  // 类型来自**行**（同一份数据，不给客户端自己报的机会）。
  assert.equal(data.mimeType, 'image/jpeg');
});

// ===== ③ 没配存储时的「如实失败」=====

test('未配置存储：上传与读图都回 upload_not_configured，而不是伪装成 IO 失败', async () => {
  const noStore = createApp({ pool: appPool, authPool, sessionSecret: SECRET });

  const up = await noStore({
    method: 'POST',
    pathname: '/data/homework/images/upload',
    query: { studentId: stuId, mimeType: 'image/jpeg' },
    headers: { authorization: `Bearer ${stuToken}`, 'content-type': 'image/jpeg' },
    body: {},
    bytes: PHOTO,
  });
  assert.equal(up.status, 503);
  assert.equal(JSON.parse(up.body).error.code, ErrorCodes.uploadNotConfigured);

  const read = await noStore({
    method: 'GET',
    pathname: '/data/homework/images/file',
    query: { id: imageId },
    headers: { authorization: `Bearer ${stuToken}` },
    body: {},
  });
  assert.equal(read.status, 503);
  assert.equal(JSON.parse(read.body).error.code, ErrorCodes.uploadNotConfigured);
});

test('未配置存储：**走真实构造路径**也回 503（这一条曾经是 500）', async () => {
  // 上一条用例是「压根不传 imageStore」，所以 ctx.imageStore 是 null。
  // 但生产路径不长这样：handler 交进来的**永远是一个对象**，只是 `ready` 为 false。
  //
  // 早先 requireImageStore 判的是「对象在不在」，于是那个 503 分支在生产上
  // **永远进不来** —— 未配置时一路走到 put() 里抛一个普通 Error，被顶层兜成
  // 500「服务端内部错误」。客户端看到 500 会以为后端炸了，而真相只是
  // 「这个功能没开」；后者客户端本来是可以优雅降级的。
  const notReady = createImageStoreFor({ IMAGE_DRIVER: 'oss' });
  assert.equal(notReady.ready, false, 'OSS 后端缺变量时应当就是 not ready');

  const app = createApp({
    pool: appPool,
    authPool,
    sessionSecret: SECRET,
    imageStore: notReady,
  });

  const up = await app({
    method: 'POST',
    pathname: '/data/homework/images/upload',
    query: { studentId: stuId, mimeType: 'image/jpeg' },
    headers: { authorization: `Bearer ${stuToken}`, 'content-type': 'image/jpeg' },
    body: {},
    bytes: PHOTO,
  });
  assert.equal(up.status, 503);
  assert.equal(JSON.parse(up.body).error.code, ErrorCodes.uploadNotConfigured);

  const read = await app({
    method: 'GET',
    pathname: '/data/homework/images/file',
    query: { id: imageId },
    headers: { authorization: `Bearer ${stuToken}` },
    body: {},
  });
  assert.equal(read.status, 503);
  assert.equal(JSON.parse(read.body).error.code, ErrorCodes.uploadNotConfigured);
});

test('IMAGE_DRIVER 拼错时**直接抛**，不许静默退回文件系统', () => {
  // 静默退回的后果：照片写进函数实例的本地磁盘 —— 上传回 200、库里也有记录，
  // 但文件随实例回收消失、多实例之间也看不见。这正是「上传成功但图没了」的成因，
  // 所以宁可起不来。
  assert.throws(() => createImageStoreFor({ IMAGE_DRIVER: 'Oss' }), /IMAGE_DRIVER=Oss/);
  assert.throws(() => createImageStoreFor({ IMAGE_DRIVER: 's3' }), /可选：fs \/ oss/);
});

test('不设 IMAGE_DRIVER 时仍是文件系统后端（既有部署行为不变）', () => {
  assert.equal(createImageStoreFor({ IMAGE_ROOT_DIR: '' }).ready, false);

  const fsStore = createImageStoreFor({ IMAGE_ROOT_DIR: os.tmpdir() });
  assert.equal(fsStore.ready, true);
  assert.equal(fsStore.root, path.resolve(os.tmpdir()));
});
