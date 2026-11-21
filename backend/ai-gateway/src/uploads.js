import { createHmac, randomUUID, timingSafeEqual } from 'node:crypto';

import { GatewayError, ErrorCodes, badRequest } from './errors.js';
import { buildPresignedUrl, tosReady } from './tos.js';

/**
 * 图片上传服务：签发出一个「客户端可以往里写、模型可以读出来」的位置。
 *
 * ## 为什么需要它
 *
 * 作业照片原本存在客户端本地（桌面/移动端是文件路径，Web 端是 localStorage），
 * 这些值进了 Serverless 函数一律读不到 —— 而且本地实现完全忽略图片，
 * 所以从测试到运行都不会报错，只会在接入云端的那一天表现为「批改从来不看图」。
 *
 * ## 两种模式
 *
 * - `proxy`：网关**自己**当存储。签名后用 `PUT /ai/uploads/put`
 *   写进来，模型通过 `GET /ai/files/{key}` 读出去。零外部依赖，
 *   适合本地联调与预发环境。
 *   **限制必须说清楚**：对象存在进程内存里，函数实例一回收就没了；
 *   多实例之间也不共享。**不要用在生产**。
 * - `tos`（生产用法）：为火山引擎 TOS 生成直传预签名 URL，
 *   客户端直接 PUT 到对象存储，网关只签名、不经手字节。
 *   需要 TOS_ACCESS_KEY_ID / TOS_ACCESS_KEY_SECRET；
 *   没配齐时如实报 `upload_not_configured`，
 *   而不是返回一个「看起来能用、上传时 403」的假 URL。
 *
 * 默认的图片传输方式是客户端侧的**内联模式**，以上都不需要。
 */
export function createUploadService({ config, now = () => Date.now() }) {
  /** key -> {bytes, contentType, expiresAt} */
  const objects = new Map();

  function signingSecret() {
    const secret = config.upload.signingSecret;
    if (secret === '') {
      throw new GatewayError(
        ErrorCodes.uploadNotConfigured,
        '未配置 AI_UPLOAD_SIGNING_SECRET，无法签发上传凭证。'
          + '若不需要对象存储模式，请把客户端切回内联模式（默认）。',
        { status: 503 },
      );
    }
    return secret;
  }

  function assertProxyReady() {
    if (config.upload.proxyUrlBase === '') {
      throw new GatewayError(
        ErrorCodes.uploadNotConfigured,
        '未配置 AI_UPLOAD_URL_BASE（网关自身的公网地址），无法签发上传凭证',
        { status: 503 },
      );
    }
    signingSecret();
  }

  /**
   * TOS 直传模式的签名。
   *
   * 网关**不碰字节**：它只算出一个预签名 URL 交给客户端，
   * 客户端自己 PUT 到对象存储。这样做的收益是三重的 ——
   * 不受 Serverless 请求体上限约束、不把 3MB 图片在函数里转一手、
   * 也不占用函数的内存与执行时长（那两项在 Serverless 上都是钱）。
   */
  function signViaTos(files, identity) {
    if (!tosReady(config)) {
      throw new GatewayError(
        ErrorCodes.uploadNotConfigured,
        'TOS 直传未配齐：需要 TOS_BUCKET / TOS_ACCESS_KEY_ID / TOS_ACCESS_KEY_SECRET'
          + '（都在网关环境变量里，不需要写进客户端）。'
          + '若暂不使用对象存储，请让客户端保持内联模式（默认）。',
        { status: 503 },
      );
    }

    const tos = config.upload.tos;
    const uploadTtl = config.upload.ttlSeconds;
    // 只上传一份 objectUrl，让客户端拿到即可跳到「先上传再批改」的路由；
    // 上传凭证与读凭证**有效期必须不同** —— 见 tos.objectTtlSeconds 的注释。
    const objectTtl = Math.max(tos.objectTtlSeconds, uploadTtl * 4);
    const publicBase = String(tos.objectUrlBase ?? '').replace(/\/$/, '');

    return {
      uploads: files.map((file) => {
        if (typeof file !== 'object' || file === null) {
          throw badRequest('files 的元素应为对象');
        }
        const storageKey = String(file.storageKey ?? '');
        if (storageKey === '') throw badRequest('files[].storageKey 不能为空');

        const contentType = String(file.contentType ?? 'image/jpeg');
        // 对象键按学生分目录：便于按人清理，也避免不同学生撞键。
        // 带扩展名，因为下游（模型侧取图 / 人工排查）经常靠后缀判断类型。
        const objectKey = `students/${identity.studentId}/${randomUUID()}${extensionFor(contentType)}`;

        const signed = buildPresignedUrl({
          method: 'PUT',
          bucket: tos.bucket,
          region: tos.region,
          endpoint: tos.endpoint,
          objectKey,
          accessKeyId: tos.accessKeyId,
          accessKeySecret: tos.accessKeySecret,
          securityToken: tos.securityToken,
          expiresSeconds: uploadTtl,
          now: now(),
        });

        // 读侧优先用公共读前缀（CDN / 公共读桶），那样模型抓图不需要签名，
        // 也不会因为「签名过期」在批改那一刻失败。没配才退化成预签名 GET。
        const objectUrl = publicBase === ''
          ? buildPresignedUrl({
              method: 'GET',
              bucket: tos.bucket,
              region: tos.region,
              endpoint: tos.endpoint,
              objectKey,
              accessKeyId: tos.accessKeyId,
              accessKeySecret: tos.accessKeySecret,
              securityToken: tos.securityToken,
              expiresSeconds: objectTtl,
              now: now(),
            }).url
          : `${publicBase}/${objectKey}`;

        return {
          storageKey,
          objectKey,
          contentType,
          // 客户端按原样 PUT，不要带额外的 Authorization —— 预签名 URL 自带授权，
          // 再叠一个鉴权头会被对象存储判为签名冲突。
          uploadUrl: signed.url,
          objectUrl,
          headers: { 'Content-Type': contentType },
          expiresIn: uploadTtl,
        };
      }),
    };
  }

  function sign(key, expiresAt, operation) {
    return createHmac('sha256', signingSecret())
      .update(`${operation}|${key}|${expiresAt}`)
      .digest('hex');
  }

  function verify(key, expiresAt, operation, token) {
    if (!Number.isFinite(expiresAt) || expiresAt < now()) {
      throw badRequest('上传凭证已过期');
    }
    const expected = Buffer.from(sign(key, expiresAt, operation));
    const actual = Buffer.from(String(token ?? ''));
    // 长度不等时 timingSafeEqual 会抛，先挡掉。
    if (expected.length !== actual.length) throw badRequest('上传凭证无效');
    if (!timingSafeEqual(expected, actual)) throw badRequest('上传凭证无效');
  }

  return {
    /** 为一批文件签发上传位置。 */
    sign(files, identity) {
      if (!Array.isArray(files) || files.length === 0) {
        throw badRequest('files 应为非空数组');
      }
      if (files.length > config.maxImages) {
        throw badRequest(`单次最多签发 ${config.maxImages} 个上传位置`);
      }
      if (config.upload.signer === 'tos') {
        return signViaTos(files, identity);
      }
      assertProxyReady();

      const expiresAt = now() + config.upload.ttlSeconds * 1000;
      const base = config.upload.proxyUrlBase.replace(/\/$/, '');

      return {
        uploads: files.map((file) => {
          if (typeof file !== 'object' || file === null) {
            throw badRequest('files 的元素应为对象');
          }
          const storageKey = String(file.storageKey ?? '');
          if (storageKey === '') throw badRequest('files[].storageKey 不能为空');

          // 对象键按学生分目录：便于按人清理，也避免不同学生撞键。
          const objectKey = `students/${identity.studentId}/${randomUUID()}`;
          return {
            storageKey,
            objectKey,
            contentType: String(file.contentType ?? 'image/jpeg'),
            // 客户端按原样 PUT，不要带额外的 Authorization —— 预签名 URL 自带授权，
            // 再叠一个鉴权头会被对象存储判为签名冲突。
            uploadUrl: `${base}/ai/uploads/put?key=${encodeURIComponent(objectKey)}`
              + `&exp=${expiresAt}&sig=${sign(objectKey, expiresAt, 'put')}`,
            // key 走 query 而不是路径：与 PUT 对称，也不必处理路径里的转义。
            objectUrl: `${base}/ai/files?key=${encodeURIComponent(objectKey)}`
              + `&exp=${expiresAt}&sig=${sign(objectKey, expiresAt, 'get')}`,
            headers: { 'Content-Type': String(file.contentType ?? 'image/jpeg') },
            expiresIn: config.upload.ttlSeconds,
          };
        }),
      };
    },

    /** 接收客户端直传的字节。 */
    put(query, bytes, contentType = 'image/jpeg') {
      const key = requireParam(query, 'key');
      const expiresAt = Number.parseInt(requireParam(query, 'exp'), 10);
      verify(key, expiresAt, 'put', query.sig);

      if (!bytes || bytes.length === 0) throw badRequest('上传内容为空');
      if (bytes.length > config.maxImageBytes) {
        throw badRequest(`单张照片不得超过 ${Math.round(config.maxImageBytes / 1024 / 1024)}MB`);
      }

      objects.set(key, {
        bytes,
        contentType,
        // 存储侧的过期时间比凭证晚一分钟：凭证刚好在边界上过期时，
        // 模型抓图不应该因为「秒级的时间差」而拿不到已经传好的图。
        expiresAt: expiresAt + 60_000,
      });
      evictExpired();
      return { objectKey: key, byteSize: bytes.length };
    },

    /** 供模型抓取图片。 */
    get(query) {
      const key = requireParam(query, 'key');
      const expiresAt = Number.parseInt(requireParam(query, 'exp'), 10);
      verify(key, expiresAt, 'get', query.sig);

      const object = objects.get(key);
      if (!object) {
        // 内存对象在实例回收后就没了。这不是「凭证错」，是架构限制，
        // 所以要明确说出来，否则会被当成签名 bug 查半天。
        throw new GatewayError(
          ErrorCodes.notFound,
          '照片不存在：可能已被回收（proxy 模式的对象仅存在于当前函数实例内存中）',
          { status: 404 },
        );
      }
      return object;
    },

    /** 测试用。 */
    size() {
      return objects.size;
    },
  };

  function evictExpired() {
    const current = now();
    for (const [key, object] of objects) {
      if (object.expiresAt < current) objects.delete(key);
    }
  }
}

function requireParam(query, name) {
  const value = query?.[name];
  if (value === undefined || value === '') {
    throw badRequest(`缺少参数 ${name}`);
  }
  return String(value);
}

/**
 * 由 MIME 推一个扩展名。
 *
 * 只为可读性与排查方便：对象存储本身不看后缀。
 * 认不出就返回空串 —— 编一个 `.bin` 只会让人误以为那是真实类型。
 */
function extensionFor(contentType) {
  switch (String(contentType).toLowerCase()) {
    case 'image/jpeg':
    case 'image/jpg':
      return '.jpg';
    case 'image/png':
      return '.png';
    case 'image/webp':
      return '.webp';
    case 'image/heic':
      return '.heic';
    default:
      return '';
  }
}
