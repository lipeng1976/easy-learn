import { createHash } from 'node:crypto';

import { DEFAULT_MAX_BYTES } from './attachments.js';
import { createImageStore } from './imagestore.js';
import { createOssImageStore } from './ossimagestore.js';

/**
 * 照片存储后端的选择 —— **唯一一处**「读哪个环境变量、装哪个实现」的判断。
 *
 * `handler.js`（云函数）与 `dev-server.js`（本机外壳）都调它。
 * 两处各写一份的话，本机能跑而线上不行的差异就会藏在这里 ——
 * 而那种差异的症状是「照片有时在、有时不在」，最难查。
 *
 * ## 默认值是 `fs`，所以这次改动**不改变任何既有部署的行为**
 *
 * 老部署没设 `IMAGE_DRIVER`，仍旧走文件系统 + `IMAGE_ROOT_DIR`。
 *
 * ## ⚠️ 驱动名不认识就**直接抛**，不许静默退回
 *
 * `IMAGE_DRIVER=Oss`（大小写错）或 `oss ` （带空格）这类笔误，如果悄悄退回
 * `fs`，后果是：数据写进了**函数实例的本地磁盘**，上传接口回 200、库里也真的
 * 有了记录，但那个文件随实例回收一起消失，而且多实例之间互相看不见。
 * 症状是「上传成功，过一会儿图没了」/「换台设备就看不到」。
 * 启动时就炸掉，比这好一万倍。
 */
export const IMAGE_DRIVERS = ['fs', 'oss'];

/** 不设 `IMAGE_DRIVER` 时用文件系统 —— 与改动前完全一致。 */
export const DEFAULT_IMAGE_DRIVER = 'fs';

/**
 * 各类型的默认字节上限现在**只有一处**（`attachments.js` 的 `DEFAULT_MAX_BYTES`）。
 * 这里原先还有一份 `const DEFAULT_MAX_BYTES = 8 * 1024 * 1024` ——
 * 与 `imagestore.js` / `ossimagestore.js` 里的各一份凑成三份。
 * 加音频/视频时三份都要改，漏掉任何一份的表现都是「某一类附件在某个后端上传不上去」。
 */

/**
 * 每个学生的照片张数上限 —— **默认值就在这里，别在别处再抄一个 3000**。
 *
 * 3000 是产品定的（2026-09-23 从 10000 下调，见 `doc/historical-data-plan.md` §3.3）。
 *
 * ## 它**不宽裕**，这是这次下调的意图
 *
 * 按「一天 3–5 张」算，3000 张约 **1.6–2.7 年**。也就是说一个从一年级开始用的
 * 学生，会在用满之前撞到它。上一个值（10000）按同样口径是 5–9 年，
 * 长到「不会有人碰到」，于是「照片只增不减」这个问题就一直不会被暴露出来。
 *
 * 撞到上限时学生该做什么，是另一件**还没定**的事 —— 见
 * `doc/historical-data-plan.md` 的「清理与归档」一节（手工删旧照片 vs
 * 系统按归档期清理），那里写着两条路各自的代价。
 *
 * ## 它还兼着「拦住失控」
 *
 * 客户端 bug 循环上传、或者有人拿脚本往里灌 —— 那是它作为上限的本职。
 * 但**别把它当成清理方案**：清理是让空间能被**重新使用**，
 * 而配额只是让写入停下来的那道墙。
 */
export const DEFAULT_QUOTA_PER_STUDENT = 3000;

/**
 * 剩余不足多少张时开始提示学生 —— 「快满了」这个说法的**唯一定义**。
 *
 * ## 为什么是 20 张，而不是一个百分比
 *
 * 百分比看着更「自适应」，对这个数却不合适：3000 的 10% 是 300 张，
 * 按一天 3–5 张算等于**提前两个月**开始喊。而这类提示唯一的用处是让人
 * 在**这几天内**去做点什么 —— 提前两个月喊，学生只会麻木，
 * 于是真到 20 张时那句提示也已经不起作用了（噪音的代价是真有问题的那条被淹掉，
 * 与 `config-check.js` 里那句话是同一个道理）。
 *
 * 20 张按一天 3–5 张算是 **4–7 天**：这才是「这周不处理就会停下来」的量级。
 *
 * ## ⚠️ 这里允许 0，与 `parsePhotoQuota` 拒绝 0 **不矛盾**
 *
 * `0` 只有一个读法：「剩余 ≤ 0 才提示」= 到上限才提示 = **没有提前提示**。
 * 也就是说它是一句显式关闭这个功能的写法（有人就是嫌这类提示烦）。
 * 而 `IMAGE_QUOTA_PER_STUDENT=0` 是另一回事 —— 它有「一张都不许存」和
 * 「不限制」两种读法，猜错的代价是两个极端之一，所以那边必须拒绝。
 * 两条规则不同，是因为**这两件事的语义本来就不同**。
 */
export const DEFAULT_QUOTA_WARN_REMAINING = 20;

/**
 * 解析 `IMAGE_QUOTA_PER_STUDENT`。返回 `{ quota }` 或 `{ error }`。
 *
 * ## 为什么不写 `Number(raw) || DEFAULT`
 *
 * 那种一行写法把三类错误都吞成「用默认值」：
 *   · `50O00`（字母 O）→ `NaN` → 默认值，于是有人以为限额是 5 万，实际是 1 万；
 *   · `0` → falsy → 默认值，于是有人以为「不限」；
 *   · `1e5` / `0x10` → `Number` 收下，得到一个没人预期的数。
 * 共同点是**改了配置却毫无反应**，而这类问题的排查成本极高
 * （人会先怀疑代码没部署、再怀疑环境变量没生效）。
 *
 * ## ⚠️ 没有 `0 = 不限` 这个哨兵值
 *
 * 刻意不做。`0` 至少有两种读法（「一张都不许传」/「不限制」），
 * 而猜错的代价是两个极端之一。想放开就把数字写大（`999999`），
 * 那是显式的、看得见的。
 */
export function parsePhotoQuota(raw) {
  const text = String(raw ?? '').trim();
  // 空 = 用默认值。这与「写了但写错」是两件事，见上面的说明。
  if (text === '') return { quota: DEFAULT_QUOTA_PER_STUDENT };

  if (!/^\d+$/.test(text)) {
    return {
      error:
        `IMAGE_QUOTA_PER_STUDENT=${text} 不是纯数字。`
        + `它必须是一个正整数（张数），或者留空用默认的 ${DEFAULT_QUOTA_PER_STUDENT}`,
    };
  }

  const quota = Number(text);
  if (quota < 1) {
    return {
      error:
        `IMAGE_QUOTA_PER_STUDENT=${text} 是 0：这会让**任何**学生都传不了照片。`
        + '这里没有「0 = 不限」这种约定（0 至少有两种读法，猜错的代价是两个极端之一）——'
        + `想放开就写一个大数字，比如 999999`,
    };
  }
  if (!Number.isSafeInteger(quota)) {
    return { error: `IMAGE_QUOTA_PER_STUDENT=${text} 太大，超出安全整数范围` };
  }

  return { quota };
}

/**
 * 解析 `IMAGE_QUOTA_WARN_REMAINING`。形状与 [parsePhotoQuota] 相同，
 * 但**允许 0** —— 理由见 `DEFAULT_QUOTA_WARN_REMAINING` 的说明。
 *
 * 与配额那一条一样：写错就报错，**绝不静默退回默认值**。
 * 静默退回的后果是「我明明配了不提示，它还在提示」（或反过来），
 * 而排查的人会先去怀疑客户端缓存 —— 那是一条查不出来的线索。
 */
export function parseQuotaWarnRemaining(raw) {
  const text = String(raw ?? '').trim();
  if (text === '') return { warnRemaining: DEFAULT_QUOTA_WARN_REMAINING };

  if (!/^\d+$/.test(text)) {
    return {
      error:
        `IMAGE_QUOTA_WARN_REMAINING=${text} 不是纯数字。`
        + '它必须是一个非负整数（剩余多少张开始提示），'
        + `或者留空用默认的 ${DEFAULT_QUOTA_WARN_REMAINING}（写 0 = 不提前提示）`,
    };
  }

  const warnRemaining = Number(text);
  // ⚠️ `0` 走到这里是**合法的**（不提前提示），别照着 parsePhotoQuota 去补一条
  // 「0 报错」—— 那会让「我就不想要这个提示」变成一种配不出来的需求。
  if (!Number.isSafeInteger(warnRemaining)) {
    return { error: `IMAGE_QUOTA_WARN_REMAINING=${text} 太大，超出安全整数范围` };
  }

  return { warnRemaining };
}

/**
 * 按附件类型分别的字节上限 —— 从环境变量读，缺省取 `attachments.js` 的默认值。
 *
 * ## ⚠️ `IMAGE_MAX_BYTES` 是**旧名**，只管图片
 *
 * 保留它而不是改名成 `PHOTO_MAX_BYTES`，是因为既有部署就设着这个名字 ——
 * 改名会让「线上照片上限」在一次部署里**悄悄变回默认值**，而那种变化
 * 没有任何症状，直到有人传了一张 9MB 的图。
 *
 * 音频与视频是新增的，用新名字（`AUDIO_MAX_BYTES` / `VIDEO_MAX_BYTES`）。
 *
 * ## 解析不出来就**用默认值**，不抛
 *
 * 与 `IMAGE_DRIVER` 那条「不认识就抛」不同：驱动名写错的后果是**数据写错地方**
 * （不可逆），而上限写错的后果是「限制不生效」或「限制过严」—— 两者都是
 * 可恢复的，且抛异常会让整个服务起不来（连照片都传不了，代价远大于收益）。
 * 但配置自检（`config-check.js`）会把它报出来。
 */
export function maxBytesByKindFromEnv(env = {}) {
  const out = new Map(DEFAULT_MAX_BYTES);
  const override = (kind, raw) => {
    const text = String(raw ?? '').trim();
    if (text === '') return;
    const n = Number(text);
    if (Number.isFinite(n) && n > 0) out.set(kind, n);
  };
  override('image', env.IMAGE_MAX_BYTES);
  override('audio', env.AUDIO_MAX_BYTES);
  override('video', env.VIDEO_MAX_BYTES);
  return out;
}

export function createImageStoreFor(env = {}) {
  const driver = String(env.IMAGE_DRIVER ?? '').trim() || DEFAULT_IMAGE_DRIVER;
  const maxBytesByKind = maxBytesByKindFromEnv(env);

  if (driver === 'oss') {
    return createOssImageStore({
      bucket: env.OSS_BUCKET,
      region: env.OSS_REGION,
      // 不填就按区域推：函数计算/ECS 与桶同区域时，建议显式填内网域名
      // （`oss-<region>-internal.aliyuncs.com`）省流量费，见部署文档。
      endpoint: env.OSS_ENDPOINT,
      accessKeyId: env.OSS_ACCESS_KEY_ID,
      accessKeySecret: env.OSS_ACCESS_KEY_SECRET,
      prefix: env.OSS_PREFIX ?? '',
      maxBytesByKind,
    });
  }

  if (driver === 'fs') {
    return createImageStore({ rootDir: env.IMAGE_ROOT_DIR ?? '', maxBytesByKind });
  }

  throw new Error(
    `不认识的 IMAGE_DRIVER=${driver}（可选：${IMAGE_DRIVERS.join(' / ')}）。`
      + '别指望它退回默认值 —— 那会把照片写进函数实例的本地磁盘，'
      + '表现为「上传成功但过一会儿图没了」',
  );
}

/**
 * 照片存储的**配置指纹**，给热实例复用判断用（见 handler.js 的 `getDataService`）。
 *
 * 为什么需要它单独一个函数：热实例会被反复复用，配置变了必须重建实例，
 * 否则「改了环境变量却不生效」—— 那种情况下健康检查显示新配置、实际请求走旧配置，
 * 是本项目最典型的静默失败形状。
 *
 * ⚠️ `OSS_ACCESS_KEY_SECRET` **不直接进指纹**，取它的 SHA256 前 12 位。
 * 两个目的：轮换密钥后指纹必变（该重建）；以及万一有人在排查
 * 「为什么配置没生效」时打印了这个串，密钥不会跟着漏进日志。
 *
 * ⚠️ 配额也进指纹，且用的是**原始字符串**而不是解析后的数字。
 * 用原始值只会带来多余的**重建**（把没设和设成同一个值当成两次配置），
 * 而漏掉一次重建的后果是「配额改了但不生效」—— 健康检查显示新配置、
 * 实际请求按旧配额走。两个方向的代价不对称，所以往「宁可多重启一次」偏。
 */
export function imageStoreConfigFingerprint(env = {}) {
  const secret = String(env.OSS_ACCESS_KEY_SECRET ?? '');
  const secretMark = secret === ''
    ? ''
    : createHash('sha256').update(secret).digest('hex').slice(0, 12);

  return [
    env.IMAGE_DRIVER ?? '',
    env.IMAGE_ROOT_DIR ?? '',
    env.IMAGE_MAX_BYTES ?? '',
    // 音频/视频的上限也要进指纹 —— 与 IMAGE_MAX_BYTES 同一条理由：
    // 改了而热实例没重建的话，表现是「上限配了却不见效」，
    // 而健康检查显示的却是新值。
    env.AUDIO_MAX_BYTES ?? '',
    env.VIDEO_MAX_BYTES ?? '',
    env.IMAGE_QUOTA_PER_STUDENT ?? '',
    // 「剩多少张开始提示」也要进指纹：改了它而实例没重建的话，
    // 表现是「阈值配了却不见效」—— 与配额同一条理由（见 handler.js 的签名注释）。
    env.IMAGE_QUOTA_WARN_REMAINING ?? '',
    env.OSS_BUCKET ?? '',
    env.OSS_REGION ?? '',
    env.OSS_ENDPOINT ?? '',
    env.OSS_ACCESS_KEY_ID ?? '',
    secretMark,
    env.OSS_PREFIX ?? '',
  ].join('|');
}
