import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';

import { createPool } from '../src/db.js';
import { createApp } from '../src/app.js';
import { buildStorageKey } from '../src/imagestore.js';
import {
  imageStoreConfigFingerprint,
  parsePhotoQuota,
  parseQuotaWarnRemaining,
} from '../src/image-store-factory.js';
import { validateConfig } from '../src/config-check.js';
import { issueSessionToken } from '../../shared/token.js';

/**
 * 照片配额：**每学生 3000 张，且这个数是可配置的**（`IMAGE_QUOTA_PER_STUDENT`）。
 *
 * ## 这个文件真正在防的是什么
 *
 * 配额是这个项目里少见的「**看不出来**」的功能：它平时什么都不做。
 * 一张照片都不多的时候，配额实现得对不对、甚至实现得有没有，**表现完全一样**。
 * 所以它的判据不能是「传一张照片能成功」（那在配额代码被整段删掉之后
 * 照样绿），必须是**把边界造出来**。
 *
 * 这个文件用五个形状把边界钉住：
 *
 * ① **默认值真的是 3000，不是「大概三千」**（最重要的一条）。
 *    用**不传 `photoQuota`** 的实例（即走 `app.js` 的默认参数）跑到边界上：
 *    库里 2999 张时第 3000 张能写，3000 张时第 3001 张被拒。
 *    手写死一个别的数字（比如 1000）会让后半条**恰好**也过 —— 因为它确实越界了 ——
 *    所以必须有前半条。**只有边界两侧都测，数字才被真正钉住。**
 *
 * ② **可配置是真的可配置**。同一份库状态（3 行），只把注入的数字从 3 改成 4，
 *    结论必须从「拒」变成「通过」。这一条是「3000 硬编码」的直接证伪：
 *    硬编码时两次都是 200，前半条立刻红。
 *
 * ③ **归属是按「这个学生」算的，不是按「我能看见的学生」算的**。
 *    家长带两个孩子，老大满、老二空 —— 老二必须还能传。
 *    实现若用 `student_id = any(可见集合)` 去 count，家长同时看两个孩子时
 *    会把张数加起来，于是**老二明明有空却传不上去**。这种错按请求的参数组合
 *    偶发（家长只点一个孩子时碰巧正常），是本项目最贵的一类。
 *
 * ④ **批量是「整批一起判」**。`details.incoming` 必须等于**批大小**，
 *    而不是 1 —— 逐张判的实现也会回 409、库里也不会留下半截
 *    （整个请求在一个事务里，抛错就回滚），**客户端看到的完全一样**。
 *    唯一能把两者分开的就是 `incoming` 这个数字。
 *
 * ⑤ **超限时字节根本没进存储**。用假存储的调用计数验，且必须**配一条正面**
 *    （额度内计数为 1）—— 否则「计数为 0」什么也证明不了，
 *    一个从头到尾没被接上的假存储同样恒为 0。
 *
 * ## 为什么默认值手抄成 `EXPECTED_DEFAULT_QUOTA` 而不 import
 *
 * `DEFAULT_QUOTA_PER_STUDENT` 就在被测代码里。import 过来会让
 * 「有人把 3000 改成 1000」这类改动**同时改掉断言** —— 判据就跟着被测代码漂了，
 * 等于没守。手抄的代价是「改了就红」，而那正是我们要的：
 * 改产品定的上限必须是一次**有意识的**决定（它还写进了
 * `doc/historical-data-plan.md` 的 Q2）。
 *
 * 跑法：`npm test`（先起本机 PG 再执行本文件）。
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

/**
 * 本文件**专有**的账号 id。
 *
 * 刻意带 `q_` 前缀，而不是复用日历那个文件里的 `stu_001` / `par_001`：
 * 这个文件排在字母序最后（见 `scripts/run-tests.mjs` 的说明），
 * 前面七八个文件都往同一份库里写过东西。用别人的 id 就得先猜
 * 「哪些行还在、哪些被清过」，而这一点**没有任何地方保证** ——
 * 猜错的症状是 `before` 钩子炸掉、所有用例报同一句话（日历那个文件里
 * 记着这个教训：24 条用例看起来像 24 个独立失败，其实只有一个原因）。
 * 换一组没人用过的 id，交叉影响在结构上就不存在。
 */
const STU1 = 'q_stu_1';
const STU2 = 'q_stu_2';
const PAR1 = 'q_par_1';

/** 产品定的默认上限。**手抄**，理由见文件头。 */
const EXPECTED_DEFAULT_QUOTA = 3000;

/** 剩余少于多少张算「快满了」。同样**手抄** —— 改它必须是一次有意识的决定。 */
const EXPECTED_DEFAULT_WARN_REMAINING = 20;

/** 1×1 的 PNG（67 字节）。够过 MIME 白名单与「非空」两道校验，又足够小。 */
const PNG_1PX = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
  'base64',
);

let adminPool;
let appPool;
let authPool;

let stu1Token;
let stu2Token;
let parentToken;

/**
 * 假的字节存储 —— **只关心 `put` 被调了几次**。
 *
 * 不写真文件的理由：这个文件要验的是「配额拦在写之前」，
 * 而「写之前」只能用「写有没有发生过」来观察。真文件系统同样能观察
 * （看目录里有没有东西），但要处理临时目录、清理、以及沙箱拦删除
 * （见 `pg-local.js` 那个已知问题）—— 为了一个计数引入这些不值。
 *
 * ⚠️ 计数**必须配正面用例**：只有一个「超限时计数为 0」的断言
 * 会被一个从未接通的假存储骗过去（它恒为 0）。所以下面有一条
 * 「额度内计数为 1」。
 */
function fakeStore({ ready = true } = {}) {
  const calls = [];
  return {
    calls,
    ready,
    root: '',
    maxBytesByKind: { image: 8 * 1024 * 1024 },
    async assertReady() {
      return ready ? { ok: true, root: '' } : { ok: false, reason: '（测试用假存储）' };
    },
    async put({ studentId, bytes, mimeType }) {
      calls.push({ studentId, size: bytes?.length ?? 0, mimeType });
      return {
        storageKey: buildStorageKey({ studentId, ext: '.png', epochMs: Date.now() }),
        byteSize: bytes?.length ?? 0,
        mimeType,
      };
    },
    async get() {
      throw new Error('本文件不验读图，get 不该被调到');
    },
  };
}

/**
 * 造一个 app。`quota` / `warnRemaining` **都可以不传** —— 不传时走 `app.js`
 * 的默认参数（即真的去读 `DEFAULT_QUOTA_PER_STUDENT` /
 * `DEFAULT_QUOTA_WARN_REMAINING`），这是验默认值那几条的入口。
 */
function appWith({ quota, warnRemaining, store = fakeStore() } = {}) {
  const app = createApp({
    pool: appPool,
    authPool,
    sessionSecret: SECRET,
    imageStore: store,
    ...(quota === undefined ? {} : { photoQuota: quota }),
    ...(warnRemaining === undefined ? {} : { photoWarnRemaining: warnRemaining }),
  });
  return { app, store };
}

async function call(app, method, pathname, { token, query, body, bytes } = {}) {
  const res = await app({
    method,
    pathname,
    query: query ?? {},
    headers: token === undefined ? {} : { authorization: `Bearer ${token}` },
    body: body ?? {},
    bytes: bytes ?? null,
  });
  return { status: res.status, json: JSON.parse(res.body) };
}

/**
 * 把库里 `q_` 两个学生的照片行重设成「指定学生 n 行、另一个 0 行」。
 *
 * 每个用例开头都调它，所以这个文件**不依赖执行顺序**、也不依赖
 * 上一个用例留下了什么 —— 配额用例的状态性太强，靠「上一个用例的残留」
 * 会让失败变得无法复现。
 *
 * ⚠️ 只删自己那两个 id：别的文件的行留着不动。
 */
async function seedImages(studentId, n) {
  await adminPool.query(
    'delete from homework_image where student_id = any($1::text[])',
    [[STU1, STU2]],
  );
  if (n === 0) return;

  // 用 generate_series 一次造完：逐条 insert 三千行会让这个文件慢到没人愿意跑，
  // 而慢的测试等于没有测试。
  await adminPool.query(
    `insert into homework_image
       (id, student_id, homework_id, storage_key, file_name, file_size,
        mime_type, ocr_status, ocr_text, batch_id, sort_order)
     select
       'q_img_' || $1 || '_' || g,
       $1,
       null,
       '20260101/' || $1 || '/' || g || '.png',
       'p' || g || '.png',
       1024,
       'image/png',
       'pending',
       '',
       '',
       0
     from generate_series(1, $2::int) as g`,
    [studentId, n],
  );
}

/** 库里某学生真正的照片行数 —— 断言「有没有写进去」用。 */
async function imageCount(studentId) {
  const r = await adminPool.query(
    'select count(*)::int as n from homework_image where student_id = $1',
    [studentId],
  );
  return r.rows[0].n;
}

/** 走**写行**那条路（`POST /data/homework/images`）提交 n 张。 */
async function writeImages(app, token, studentId, n) {
  const images = Array.from({ length: n }, (_, i) => ({
    studentId,
    storageKey: `20260101/${studentId}/body-${i}.png`,
    fileName: `photo-${i}.png`,
    fileSize: 1024,
    mimeType: 'image/png',
  }));
  return call(app, 'POST', '/data/homework/images', { token, body: { images } });
}

/** 走**上传字节**那条路（`POST /data/homework/images/upload`）传一张。 */
async function uploadImage(app, token, studentId) {
  return call(app, 'POST', '/data/homework/images/upload', {
    token,
    query: { studentId, mimeType: 'image/png', fileName: 'p.png' },
    bytes: PNG_1PX,
  });
}

async function sessionFor(userId, role) {
  const sid = `sess_${userId}`;
  await adminPool.query(
    `insert into user_session (id, user_id, issued_at, expires_at)
     values ($1, $2, now(), now() + interval '1 hour')
     on conflict (id) do nothing`,
    [sid, userId],
  );
  return issueSessionToken({ secret: SECRET, subject: userId, role, sessionId: sid });
}

before(async () => {
  if (!PG.host || !PG.database) {
    throw new Error(
      '照片配额测试需要 PostgreSQL：请用 `npm test` 运行（它会起本机 PG），'
        + '或提供 TEST_PG_HOST / TEST_PG_DATABASE 等环境变量指向已有实例。',
    );
  }

  adminPool = createPool({
    host: PG.host, port: PG.port, database: PG.database,
    user: PG.adminUser, password: PG.adminPassword, max: 2,
  });
  appPool = createPool({
    host: PG.host, port: PG.port, database: PG.database,
    user: PG.appUser, password: PG.appPassword, max: 4,
  });
  authPool = createPool({
    host: PG.host, port: PG.port, database: PG.database,
    user: PG.authUser, password: PG.authPassword, max: 2,
  });

  // `on conflict do nothing` 而不是先删：这两个账号**只有本文件用**，
  // 所以撞上别人的可能性为零；而「先删 app_user」会牵动一串外键
  // （前面几个文件往里写过 chat_message 之类），风险全在别处。
  await adminPool.query(
    `insert into app_user (id, name, role, avatar) values
       ('${STU1}', '配额甲', 'student', 'fox'),
       ('${STU2}', '配额乙', 'student', 'rabbit'),
       ('${PAR1}', '配额家长', 'parent', 'teacher')
     on conflict (id) do nothing;

     insert into relationship (id, student_id, parent_id, sender_id, status) values
       ('q_rel_1', '${STU1}', '${PAR1}', '${PAR1}', 'active'),
       ('q_rel_2', '${STU2}', '${PAR1}', '${PAR1}', 'active')
     on conflict (id) do nothing;`,
  );

  stu1Token = await sessionFor(STU1, 'student');
  stu2Token = await sessionFor(STU2, 'student');
  parentToken = await sessionFor(PAR1, 'parent');
});

after(async () => {
  await appPool?.end();
  await authPool?.end();
  await adminPool?.end();
});

// ===== ① 配置解析（纯函数，不需要数据库）=====

test('默认上限是 3000（**手抄**在断言里，不从被测代码 import）', () => {
  // 三种「没写」的形态都走默认值：完全没设、空串、只有空白。
  // 它们与「写了但写错」是两件事，后者见下一条。
  assert.equal(parsePhotoQuota(undefined).quota, EXPECTED_DEFAULT_QUOTA);
  assert.equal(parsePhotoQuota('').quota, EXPECTED_DEFAULT_QUOTA);
  assert.equal(parsePhotoQuota('   ').quota, EXPECTED_DEFAULT_QUOTA);
});

test('可配置：写多少就是多少', () => {
  assert.equal(parsePhotoQuota('50').quota, 50);
  assert.equal(parsePhotoQuota('1').quota, 1);
  assert.equal(parsePhotoQuota('999999').quota, 999999);
});

test('写错的配置一律报错 —— 绝不静默退回默认值', () => {
  // ⚠️ 这一条是冲着「`Number(raw) || DEFAULT`」这种一行写法去的。
  // 那种写法把下面每一类都吞成「用默认值」，共同点是**改了配置却毫无反应**：
  //   · `50O00`（字母 O）→ NaN → 默认值，你以为限额是 5 万，实际是 3 千；
  //   · `0` → falsy → 默认值，你以为「不限」；
  //   · `1e5` → Number 收下 100000，得到一个没人预期的数。
  // 排查成本极高：人会先怀疑代码没部署、再怀疑环境变量没生效。
  for (const bad of ['50O00', '0', '-5', '1e5', '0x10', '10.5', '一万', '3000张']) {
    const r = parsePhotoQuota(bad);
    assert.ok(r.error, `IMAGE_QUOTA_PER_STUDENT=${bad} 必须报错，实际拿到了 ${JSON.stringify(r)}`);
    assert.equal(
      r.quota,
      undefined,
      `IMAGE_QUOTA_PER_STUDENT=${bad} 报错时不该同时给出一个配额数字 —— `
        + '那会被调用方当成「有值」继续用下去',
    );
  }
});

test('报错信息点名是哪一条配置 —— 运维看到就知道去改哪个变量', () => {
  const r = parsePhotoQuota('abc');
  assert.match(r.error, /IMAGE_QUOTA_PER_STUDENT/);
  // `0` 那条要解释「这里没有 0 = 不限」，否则下一个人会以为是自己写法不对。
  assert.match(parsePhotoQuota('0').error, /不限/);
});

// ===== ② 配置自检：写错要在**启动时**拦下 =====

test('非法配额进 problems（不是 warnings）：它起不来，而不是带着错误上限跑', () => {
  const { problems, warnings } = validateConfig({
    NODE_ENV: 'production',
    IMAGE_QUOTA_PER_STUDENT: '50O00',
  });
  assert.ok(
    problems.some((p) => p.includes('IMAGE_QUOTA_PER_STUDENT')),
    `非法配额必须进 problems，实际 problems=${JSON.stringify(problems)} warnings=${JSON.stringify(warnings)}`,
  );
});

test('合法配额（以及留空）不产生任何与配额有关的条目', () => {
  for (const env of [{ IMAGE_QUOTA_PER_STUDENT: '500' }, {}]) {
    const { problems, warnings } = validateConfig({ NODE_ENV: 'production', ...env });
    const quotaNoise = [...problems, ...warnings].filter((m) => m.includes('IMAGE_QUOTA_PER_STUDENT'));
    assert.deepEqual(
      quotaNoise,
      [],
      `配额配置正常时不该有相关条目 —— 噪音的代价是真出问题的那条被淹掉：${quotaNoise.join('；')}`,
    );
  }
});

test('配额进配置指纹：改了它，热实例必须重建', () => {
  // 指纹相同 → `getDataService` 直接复用上一个实例。少了这一段，
  // 「改大配额 → 服务还在用旧数字」会**完全静默**：配置看着是新的，
  // 行为还是旧的，而没有任何一处会说不一致。
  const base = { IMAGE_DRIVER: 'oss', OSS_BUCKET: 'b', OSS_REGION: 'cn-beijing' };
  assert.notEqual(
    imageStoreConfigFingerprint({ ...base, IMAGE_QUOTA_PER_STUDENT: '3000' }),
    imageStoreConfigFingerprint({ ...base, IMAGE_QUOTA_PER_STUDENT: '20000' }),
    '配额变了指纹却没变 → 服务端会继续用旧上限，且没有任何提示',
  );
  // 反面：没改时指纹必须稳定，否则每次调用都重建实例（连接池来回关）。
  assert.equal(
    imageStoreConfigFingerprint({ ...base, IMAGE_QUOTA_PER_STUDENT: '3000' }),
    imageStoreConfigFingerprint({ ...base, IMAGE_QUOTA_PER_STUDENT: '3000' }),
  );
});

// ===== ③ 默认值 3000 真的在路由上生效（边界两侧都验）=====

test('默认上限：库里 2999 张时，第 3000 张**写得进去**', async () => {
  // ⚠️ 这条看起来是「废话」（2999 < 3000 当然能写），但它是**必须的**：
  // 少了它，下面那条「第 3001 张被拒」在「有人把上限写成 1000」时
  // **照样会绿**（1000 张时当然也拒）。只有两侧都测，3000 这个数字才被钉住。
  //
  // 用不传 `photoQuota` 的实例 —— 这样走的是 `app.js` 的默认参数，
  // 也就是真的在生产同一条路径上读默认值，而不是我在测试里喂进去的数。
  await seedImages(STU1, EXPECTED_DEFAULT_QUOTA - 1);
  const { app } = appWith();

  const res = await writeImages(app, stu1Token, STU1, 1);
  assert.equal(res.status, 200, `第 ${EXPECTED_DEFAULT_QUOTA} 张应当能写：${JSON.stringify(res.json)}`);
  assert.equal(await imageCount(STU1), EXPECTED_DEFAULT_QUOTA);
});

test('默认上限：库里已经 3000 张时，第 3001 张被拒', async () => {
  await seedImages(STU1, EXPECTED_DEFAULT_QUOTA);
  const { app } = appWith();

  const res = await writeImages(app, stu1Token, STU1, 1);
  assert.equal(res.status, 409, `第 ${EXPECTED_DEFAULT_QUOTA + 1} 张必须被拒：${JSON.stringify(res.json)}`);
  assert.equal(res.json.error.code, 'storage_quota_exceeded');
  assert.equal(res.json.error.details.quota, EXPECTED_DEFAULT_QUOTA, '回给客户端的数字必须是默认上限');
  assert.equal(res.json.error.details.used, EXPECTED_DEFAULT_QUOTA);
  assert.equal(await imageCount(STU1), EXPECTED_DEFAULT_QUOTA, '被拒时库里一行都不该多');
});

// ===== ④ 可配置：只换那个数字，结论就反过来 =====

test('同一份库状态，只把配额从 3 改成 4，结论必须反过来', async () => {
  // 「3000 做成可配置」的**直接证伪**：硬编码 3000 时两次都是 200，前半条立刻红。
  // 反过来，如果实现把配额读成固定的小数字，后半条会红。
  await seedImages(STU1, 3);

  const tight = appWith({ quota: 3 });
  const rejected = await writeImages(tight.app, stu1Token, STU1, 1);
  assert.equal(rejected.status, 409, `quota=3、已用 3 时必须拒：${JSON.stringify(rejected.json)}`);

  // ⚠️ 库状态**没有被上一步改掉**（被拒了），所以这一步是纯粹的「只换了数字」对照。
  const roomy = appWith({ quota: 4 });
  const accepted = await writeImages(roomy.app, stu1Token, STU1, 1);
  assert.equal(accepted.status, 200, `quota=4、已用 3 时必须过：${JSON.stringify(accepted.json)}`);
  assert.equal(await imageCount(STU1), 4);
});

test('正好到上限**算通过**（`>` 与 `>=` 的区别）', async () => {
  // 写成 `used + incoming >= quota` 会让第 3000 张传不上去 ——
  // 学生看到的是「照片数量已达上限，删掉一些旧照片再试」，
  // 而他其实还有一张的额度。这种差一张的错只在边界上出现。
  await seedImages(STU1, 4);
  const { app } = appWith({ quota: 5 });

  const res = await writeImages(app, stu1Token, STU1, 1);
  assert.equal(res.status, 200, `4 + 1 = 5 恰好等于上限，必须通过：${JSON.stringify(res.json)}`);
  assert.equal(await imageCount(STU1), 5);
});

// ===== ⑤ 归属：按「这个学生」算，不按「我能看见的学生」算 =====

test('老大满了不影响老二（家长同时看两个孩子时最容易错的那一处）', async () => {
  await seedImages(STU1, 2); // 老二（STU2）0 张
  const { app } = appWith({ quota: 2 });

  // 家长对**老大**（已满）：拒。
  const elder = await writeImages(app, parentToken, STU1, 1);
  assert.equal(elder.status, 409, `老大已满，必须拒：${JSON.stringify(elder.json)}`);

  // 家长对**老二**（0 张）：必须能写。
  //
  // ⚠️ 实现若用 `student_id = any(可见集合)` 去 count，家长这一次的 count 是 2
  // （两个孩子的行加在一起）→ 老二被误拒。而家长**只点一个孩子**时
  // 那个数字碰巧就是对的 —— 所以这个 bug 按请求的参数组合偶发，
  // 换一种用法就正常，是最难被报告上来的那一类。
  const younger = await writeImages(app, parentToken, STU2, 1);
  assert.equal(
    younger.status,
    200,
    `老二还有 2 张额度，不该因为老大满了而被拦：${JSON.stringify(younger.json)}`,
  );
  assert.equal(await imageCount(STU2), 1);
});

test('反面：给看不见的学生写 / 传，一律 403（配额之前就拦）', async () => {
  // 两个方向都要验 —— 写行那条与上传字节那条都会先解析归属，
  // 所以「拿配额当探针去问别人家用了几张」在结构上不成立。
  await seedImages(STU1, 2);
  const { app } = appWith({ quota: 2 });

  const write = await writeImages(app, stu1Token, STU2, 1);
  assert.equal(write.status, 403, `学生给别的学生写照片必须 403：${JSON.stringify(write.json)}`);

  const upload = await uploadImage(app, stu1Token, STU2);
  assert.equal(upload.status, 403, `学生给别的学生传字节必须 403：${JSON.stringify(upload.json)}`);

  assert.equal(await imageCount(STU2), 0, '被拒之后别的学生名下一行都不该有');
});

// ===== ⑥ 批量：整批一起判 =====

test('批量越界：**整批**拒（incoming 是批大小，不是 1），库里一行都不多', async () => {
  await seedImages(STU1, 4);
  const { app } = appWith({ quota: 5 });

  const res = await writeImages(app, stu1Token, STU1, 2); // 4 + 2 = 6 > 5
  assert.equal(res.status, 409, `4 + 2 越界，必须拒：${JSON.stringify(res.json)}`);

  // ⚠️ **这一条才是能把「整批判」与「逐张判」分开的判据。**
  // 逐张判的实现也会回 409、库里也不会留下半截（整个请求在一个事务里，
  // 抛错就整体回滚），客户端看到的完全一样 —— 换句话说，
  // 光断言「有一张写不进去就整体失败」是**分辨不出**两种实现的。
  // 唯一分开它们的是这个数字：逐张判会报 `incoming: 1`。
  assert.equal(
    res.json.error.details.incoming,
    2,
    'incoming 必须是这一批的总张数 —— 报 1 说明是逐张判的',
  );

  assert.equal(await imageCount(STU1), 4, '被拒时库里必须仍是 4 行（不能半截写入）');
});

test('错误码是 `storage_quota_exceeded`，不是 AI 那个 `quota_exhausted`', async () => {
  // 两个码语义相近、处置完全不同：AI 额度用完了等明天，
  // 照片配额满了要**去删旧照片**（或让运维调大）。用同一个码会让客户端
  // 弹出一句「今天的 AI 额度用完了」—— 指的方向是错的。
  await seedImages(STU1, 1);
  const { app } = appWith({ quota: 1 });

  const res = await writeImages(app, stu1Token, STU1, 1);
  assert.equal(res.status, 409);
  assert.equal(res.json.error.code, 'storage_quota_exceeded');
  assert.notEqual(res.json.error.code, 'quota_exhausted');

  // details 要够客户端把话说清楚（「已用 1 / 1 张」），而不是只有一个「失败了」。
  assert.deepEqual(
    res.json.error.details,
    { used: 1, quota: 1, incoming: 1, remaining: 0 },
    'details 必须带 used / quota / incoming / remaining',
  );
  assert.match(res.json.error.message, /上限/);
});

// ===== ⑦ 上传字节：配额拦在**写之前** =====

test('额度内：能传，回报里带用量（客户端「快满了」提示的数据来源）', async () => {
  // 这条同时是下面那条的**对照**：它证明假存储的计数是活的
  // （不然「超限时计数为 0」可能只是计数根本没被接上）。
  await seedImages(STU1, 1);
  const { app, store } = appWith({ quota: 5 });

  const res = await uploadImage(app, stu1Token, STU1);
  assert.equal(res.status, 200, `额度内必须能传：${JSON.stringify(res.json)}`);
  assert.equal(store.calls.length, 1, '额度内 put 应当恰好被调 1 次');

  const usage = res.json.data.photoUsage;
  assert.ok(usage, '响应里必须带 photoUsage —— 上传是唯一需要这个数字的时刻');
  assert.equal(usage.used, 1, '上传不写行，所以这里是**写之前**的行数（如实）');
  assert.equal(usage.quota, 5);
  assert.equal(usage.remaining, 4);

  // ⚠️ **必须是数字，不能是字符串。** `count(*)` 是 bigint，`pg` 会把它
  // 返回成 `"1"`；少了 SQL 里的 `::int`，`used + incoming` 会变成
  // 字符串拼接（`"9" + 1` → `"91"`）而**不报错** —— 症状是「明明有额度却传不上去」，
  // 报表和日志里一切看起来都正常。
  assert.equal(typeof usage.used, 'number', 'used 必须是数字：字符串会让 used + incoming 变成拼接');
  assert.equal(typeof usage.remaining, 'number');
});

test('到上限：上传被拒，且字节**根本没进存储**（put 一次都没调）', async () => {
  await seedImages(STU1, 2);
  const { app, store } = appWith({ quota: 2 });

  const res = await uploadImage(app, stu1Token, STU1);
  assert.equal(res.status, 409, `已满时必须拒：${JSON.stringify(res.json)}`);
  assert.equal(res.json.error.code, 'storage_quota_exceeded');

  // 超限时不该先把字节落进桶里再报错 —— 那既白花存储，
  // 又留下一个永远没有行去引用的孤儿对象（而且它在对象存储里要付钱）。
  assert.equal(
    store.calls.length,
    0,
    '配额判定必须在写字节**之前**：put 被调到说明字节已经落进存储了',
  );
});

// ===== ⑧ 写行回传用量：「快满了」提示的数据来源 =====
//
// 这一组防的是同一类错：**提示该来的时候没来，或不该来的时候来了**。
// 它比「传不上去」更难被发现 —— 传不上去至少会报错，而提示错了只是
// 一句没人细看的话。所以每条都配了反面。

test('写行成功时回报**写入之后**的用量', async () => {
  // ⚠️ 报「写之前」的数也是个能跑的实现，而且更难被发现：学生看到
  // 「还剩 18 张」、实际只剩 16 张，差几张不痛不痒，直到某次真的传不上去
  // 才会有人去查这个数字从哪来。**只有断言精确到 7 才能把两种实现分开**
  // （写之前是 5，写之后是 7）。
  await seedImages(STU1, 5);
  const { app } = appWith({ quota: 100 });

  const res = await writeImages(app, stu1Token, STU1, 2);
  assert.equal(res.status, 200, JSON.stringify(res.json));

  const usage = res.json.data.photoUsage;
  assert.ok(usage, '写行响应必须带 photoUsage —— 这是唯一知道「这次写了几张」的时刻');
  assert.equal(usage.used, 7, '必须是写之后的 7：报 5 说明漏掉了本次这两张');
  assert.equal(usage.quota, 100);
  assert.equal(usage.remaining, 93);
  assert.equal(typeof usage.used, 'number', 'used 必须是数字（`::int`，见上传那条的说明）');
});

test('默认阈值 20：剩 21 张**不说**「快满了」', async () => {
  // 边界的一侧。不传 `warnRemaining` = 真的走 `app.js` 的默认参数。
  await seedImages(STU1, 0);
  const { app } = appWith({ quota: 22 });

  const res = await writeImages(app, stu1Token, STU1, 1);
  const usage = res.json.data.photoUsage;
  assert.equal(usage.used, 1);
  assert.equal(usage.remaining, 21);
  assert.equal(
    usage.warnRemaining,
    EXPECTED_DEFAULT_WARN_REMAINING,
    '回传给客户端的阈值必须就是那个默认值 —— 客户端拿它显示，不自己抄一份',
  );
  assert.equal(usage.nearLimit, false, '还剩 21 张（阈值 20）不该喊「快满了」');
});

test('默认阈值 20：剩 20 张**说**「快满了」', async () => {
  // 边界的另一侧。⚠️ 少了这一条，把阈值实现成 0（= 永不提示）也会全绿。
  await seedImages(STU1, 0);
  const { app } = appWith({ quota: 21 });

  const res = await writeImages(app, stu1Token, STU1, 1);
  const usage = res.json.data.photoUsage;
  assert.equal(usage.remaining, 20);
  assert.equal(usage.nearLimit, true, '正好等于阈值必须算「接近」—— 差一张的错只在边界上出现');
});

test('阈值可配置：同一份库状态，只把阈值从 10 改成 30，结论反过来', async () => {
  // 「阈值写死 20」的直接证伪：写死时两次结论相同，前半条立刻红。
  await seedImages(STU1, 85); // 再写 1 张 → used=86、remaining=14
  const tight = appWith({ quota: 100, warnRemaining: 10 });
  const a = await writeImages(tight.app, stu1Token, STU1, 1);
  assert.equal(a.json.data.photoUsage.remaining, 14);
  assert.equal(a.json.data.photoUsage.nearLimit, false, '阈值 10、剩 14 张 → 不该提示');

  await seedImages(STU1, 85); // 重置到同一状态，只换阈值
  const loose = appWith({ quota: 100, warnRemaining: 30 });
  const b = await writeImages(loose.app, stu1Token, STU1, 1);
  assert.equal(b.json.data.photoUsage.remaining, 14);
  assert.equal(b.json.data.photoUsage.nearLimit, true, '阈值 30、剩 14 张 → 必须提示');
});

test('阈值 0 = 显式关闭（到上限才提示）', async () => {
  // `IMAGE_QUOTA_PER_STUDENT=0` 是错的（「一张都不许」还是「不限制」？两种读法），
  // 但 `IMAGE_QUOTA_WARN_REMAINING=0` 只有一种读法：到上限才提示 = 不提前提示。
  // 所以这里允许 0 —— 两条规则不同，是因为语义本来就不同。
  await seedImages(STU1, 98);
  const { app } = appWith({ quota: 100, warnRemaining: 0 });

  const res = await writeImages(app, stu1Token, STU1, 1);
  const usage = res.json.data.photoUsage;
  assert.equal(usage.used, 99);
  assert.equal(usage.remaining, 1);
  assert.equal(usage.nearLimit, false, '还剩 1 张、阈值 0 → 不提示（这就是「关闭」的含义）');
});

test('阈值解析：留空用默认 20，0 合法，写错一律报错', () => {
  assert.equal(parseQuotaWarnRemaining(undefined).warnRemaining, EXPECTED_DEFAULT_WARN_REMAINING);
  assert.equal(parseQuotaWarnRemaining('').warnRemaining, EXPECTED_DEFAULT_WARN_REMAINING);
  assert.equal(parseQuotaWarnRemaining('   ').warnRemaining, EXPECTED_DEFAULT_WARN_REMAINING);
  assert.equal(parseQuotaWarnRemaining('0').warnRemaining, 0, '0 在这里是**合法值**');
  assert.equal(parseQuotaWarnRemaining('50').warnRemaining, 50);

  for (const bad of ['-1', '2O', '1e3', '十', '20张']) {
    const r = parseQuotaWarnRemaining(bad);
    assert.ok(r.error, `IMAGE_QUOTA_WARN_REMAINING=${bad} 必须报错，实际 ${JSON.stringify(r)}`);
    // 与配额那条同一个要求：报错时不能同时给出一个数字，否则调用方会拿它继续跑。
    assert.equal(r.warnRemaining, undefined);
  }
});

test('非法阈值进 problems（不是 warnings）：它起不来，而不是带着错误行为跑', () => {
  const { problems } = validateConfig({
    NODE_ENV: 'production',
    IMAGE_QUOTA_WARN_REMAINING: '2O',
  });
  assert.ok(
    problems.some((x) => x.includes('IMAGE_QUOTA_WARN_REMAINING')),
    `非法阈值必须进 problems，实际 problems=${JSON.stringify(problems)}`,
  );
});

test('合法阈值（含 0 与留空）不产生任何与它有关的条目', () => {
  for (const env of [
    { IMAGE_QUOTA_WARN_REMAINING: '50' },
    { IMAGE_QUOTA_WARN_REMAINING: '0' },
    {},
  ]) {
    const { problems, warnings } = validateConfig({ NODE_ENV: 'production', ...env });
    const noise = [...problems, ...warnings]
      .filter((m) => m.includes('IMAGE_QUOTA_WARN_REMAINING'));
    assert.deepEqual(
      noise,
      [],
      `阈值配置正常时不该有相关条目（噪音的代价是真出问题的那条被淹掉）：${noise.join('；')}`,
    );
  }
});

test('阈值进配置指纹：改了它，热实例必须重建', () => {
  // 少了它，「改小阈值 → 服务还在用旧阈值」会完全静默：配置看着是新的，
  // 行为还是旧的，而没有任何一处会说不一致。
  const base = { IMAGE_DRIVER: 'oss', OSS_BUCKET: 'b', OSS_REGION: 'cn-beijing' };
  assert.notEqual(
    imageStoreConfigFingerprint({ ...base, IMAGE_QUOTA_WARN_REMAINING: '20' }),
    imageStoreConfigFingerprint({ ...base, IMAGE_QUOTA_WARN_REMAINING: '50' }),
    '阈值变了指纹却没变 → 服务端会继续用旧阈值，且没有任何提示',
  );
});
