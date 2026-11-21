/**
 * 启动前的配置自检（数据服务）。
 *
 * ## 与网关那份的关系
 *
 * 网关有 `ai-gateway/src/config.js` 的 `validateConfig`，它查的是「配错了会
 * **静默**产生错误行为」的组合（开了鉴权却没有密钥 → 永远放行）。
 * 这一份做同一件事，只是对象换成了数据服务。两边都返回一串问题，**装配点负责炸**。
 *
 * ## 为什么要有它
 *
 * 数据服务原先只有**运行期**的三道闸（RLS 是否生效、鉴权角色是否被多授权、
 * 照片存储能不能写）。那三道查的是「连上库之后」的事 —— 而下面这几个问题
 * **连库都不用连**，且症状同样安静：
 *
 *   · `AI_SESSION_SECRET` 为空 → 所有 `/data/*` 判未配置。客户端表现是
 *     「登录成功，但进去一片空」—— 排查的人会先怀疑数据没同步、再怀疑 RLS，
 *     最后才想到密钥，因为「登录都成功了，密钥怎么可能有问题」。
 *   · 生产用着开发栈的那把密钥（`dev-stack-secret-not-for-production`）→
 *     任何人拿本仓公开的这个字符串都能**自己签一张票**。这个更坏：它不报错、
 *     不留痕，而票据校验全过。
 *   · 生产没配 `PGPASSWORD` → 起得来（驱动会重试），但每个请求都 500。
 *
 * 所以这里的取舍是：**宁可起不来，也不要裸奔** —— 与那三道闸同一个原则。
 * 少数几项（照片存储、CORS 通配）只报警不拦截，理由见下。
 *
 * 用法：
 *   const { problems, warnings } = validateConfig(process.env);
 *   for (const w of warnings) console.warn(`[data-service] 警告：${w}`);
 *   if (problems.length > 0) throw new Error(...);
 */

/**
 * 生产判定与那把公开密钥都来自 `shared/env.js` —— **不在本文件重新定义**。
 * 网关侧要用同一套判定（见 `ai-gateway/src/config.js`），
 * 两边各写一份的话「生产」这个词迟早会在某次修改里分叉，
 * 而分叉的代价是单侧的：一边按生产拦、另一边照旧放行。
 *
 * 这里 re-export 是为了让调用方（handler.js、测试）从一个地方拿全，
 * 不必知道它住在 shared 里。
 */
import { DEV_STACK_SECRET, MIN_SECRET_LENGTH, isProduction } from '../../shared/env.js';
import {
  DEFAULT_IMAGE_DRIVER,
  IMAGE_DRIVERS,
  parsePhotoQuota,
  parseQuotaWarnRemaining,
} from './image-store-factory.js';

export { DEV_STACK_SECRET, isProduction };

/**
 * 查一遍配置，返回 `{ problems, warnings }`。
 *
 * `problems` = **必须让进程起不来**（静默失效、或直接不可用）。
 * `warnings` = **起得来，但必须在启动日志里说出来**（功能降级、或安全上不理想）。
 * 两者的区别不是严重程度，而是「拦下来会不会让一件本来能跑的事跑不起来」——
 * 照片存储没配时，其余 40 多条路由本来是好的，把它拖死是过度反应。
 */
export function validateConfig(env = process.env) {
  const problems = [];
  const warnings = [];
  const production = isProduction(env);

  // ===== 会话密钥 =====
  const secret = String(env.AI_SESSION_SECRET ?? '');
  if (secret === '') {
    const msg =
      'AI_SESSION_SECRET 为空：所有 /data/* 请求都会判「未配置」，'
      + '客户端表现为「登录成功但进去一片空」（它会把这个错归类成读不到数据）';
    if (production) problems.push(msg);
    else warnings.push(`${msg}。本机开发只跑数据服务时可以先不管，但要跑完整链路就必须设`);
  } else if (secret === DEV_STACK_SECRET) {
    const msg =
      `AI_SESSION_SECRET 用的是开发栈那把公开密钥（${DEV_STACK_SECRET}）——`
      + '它写在仓库里，任何人拿它都能自己签一张有效的票，而且**票据校验全过、不留痕**';
    if (production) problems.push(msg);
    else warnings.push(`${msg}。本机开发没问题，上线前必须换掉`);
  } else if (secret.length < MIN_SECRET_LENGTH) {
    warnings.push(
      `AI_SESSION_SECRET 只有 ${secret.length} 个字符（建议 ≥ ${MIN_SECRET_LENGTH}）：`
      + 'HMAC 的强度等于密钥的熵，短密钥可以被离线爆破',
    );
  }

  // ===== 数据库口令 =====
  if (production && String(env.PGPASSWORD ?? '') === '') {
    problems.push(
      '生产环境没有 PGPASSWORD：连接池会一直重试，每个请求都 500。'
      + '（口令请放在平台的「环境变量 / 密钥管理」里，不要写进镜像或代码）',
    );
  }

  // ===== AI 网关 =====
  // 每日打卡的**服务端出题**要调网关（见 routes/checkin.js 的 generateCheckin）。
  // 没配只影响那一条路由（如实回 `model_not_enabled`），其余照常 ——
  // 但它必须在启动日志里说出来：否则第一次发现是在家长点「发起打卡」时，
  // 而排查方向会先跑到网关的模型配置上去。
  const gateway = String(env.AI_GATEWAY_BASE_URL ?? '').trim();
  if (gateway === '') {
    warnings.push(
      'AI_GATEWAY_BASE_URL 为空：每日打卡的服务端出题不可用（该路由回 model_not_enabled），'
        + '其余功能正常。本机开发栈是 http://127.0.0.1:8787；'
        + '云上请填网关函数的公网 URL —— 别留空让它去猜，'
        + '猜成 127.0.0.1 的症状是「打卡永远出不了题」而日志看着一切正常',
    );
  } else if (!/^https?:\/\//i.test(gateway)) {
    warnings.push(
      `AI_GATEWAY_BASE_URL=${gateway} 不像一个 URL（要以 http:// 或 https:// 开头）：`
        + '出题请求会全部连不上',
    );
  }

  // ===== 照片存储 =====
  // 这一整段**只报警**：没配好时该功能会让路由如实回 `upload_not_configured`，
  // 其余 40 多条路由本来好好的 —— 让它把整个服务拖死是过度反应（见 imagestore.js）。
  //
  // ⚠️ 包括「生产环境用文件系统后端」在内也只警告，这个判断是刻意放松的：
  // 文件系统后端在**有持久磁盘**的部署上完全正常（ECS + 挂载云盘/NAS 就是），
  // 只有函数计算那类「没有持久磁盘」的形态才会丢数据。把前者一起拦下，
  // 等于让一种正当部署起不来 —— 那是另一种错误。
  const driver = String(env.IMAGE_DRIVER ?? '').trim() || DEFAULT_IMAGE_DRIVER;

  if (!IMAGE_DRIVERS.includes(driver)) {
    // 这一条**进 problems**：驱动名写错时不该猜人的意图。
    // 与 image-store-factory 的抛错刻意重复一次，这里跑在任何连接之前，
    // 报得更早，而且能顺手告诉人正确值有哪些。
    problems.push(
      `IMAGE_DRIVER=${driver} 不认识（可选：${IMAGE_DRIVERS.join(' / ')}）。`
      + '不许它静默退回默认后端 —— 那会把照片写进一个你以为不是那里的地方',
    );
  } else if (driver === 'fs') {
    if (String(env.IMAGE_ROOT_DIR ?? '') === '') {
      warnings.push(
        'IMAGE_ROOT_DIR 为空：拍照上传与读图会如实回 upload_not_configured（其余功能正常）。'
          + '要启用的话，云上得挂一块**多实例共享**的持久卷（ECS 挂云盘/NAS），'
          + '别用函数实例的本地临时盘 —— 那会「上传成功但过一会儿图没了」',
      );
    } else if (production) {
      // 只在**真的在用**文件系统后端时才提平台风险（配了 IMAGE_ROOT_DIR 说明有人在用）。
      // 没配的时候上面那条已经说清楚了，再说一遍「生产用 fs 有风险」是噪音 ——
      // 而噪音的代价是真出问题的那条被淹掉。
      warnings.push(
        '生产环境用的是文件系统后端（IMAGE_DRIVER=fs）。它在**有持久磁盘**的部署上没问题'
          + '（ECS 挂载云盘/NAS 就是），但**函数计算没有持久磁盘** —— 那边照片会随实例回收消失，'
          + '多实例之间也不共享，症状是「上传成功，过一会儿图没了」或「换台设备就看不到」。'
          + '跑函数计算请改 IMAGE_DRIVER=oss 并填 OSS_BUCKET / OSS_REGION / '
          + 'OSS_ACCESS_KEY_ID / OSS_ACCESS_KEY_SECRET',
      );
    }
  } else {
    const missing = ['OSS_BUCKET', 'OSS_REGION', 'OSS_ACCESS_KEY_ID', 'OSS_ACCESS_KEY_SECRET']
      .filter((k) => String(env[k] ?? '') === '');
    if (missing.length > 0) {
      warnings.push(
        `${missing.join(' / ')} 为空：照片的上传与读取会如实回 upload_not_configured（其余功能正常）`,
      );
    }
    // ⚠️ 这里**刻意不检查** `OSS_ENDPOINT` 和 `OSS_PREFIX`：
    // 它们为空是**正常配置**（外网域名能用；一个环境一个桶时不需要前缀）。
    // 「可以更好」的东西每次都念一遍，代价是真出问题的那条被淹掉 ——
    // 启动日志一旦习惯性被跳过，它就等于不存在。它们写进部署文档就够了。
  }

  // ===== 照片配额 =====
  // 与后端选择**无关** —— 两条后端都要守同一个上限，所以放在 if/else 之外。
  //
  // 这一条进 problems 而不是 warnings：配额写错的症状是「上限不对」，
  // 而「上限不对」既看不见也不报错 —— 要么放行得比预期多（白花钱），
  // 要么拦得比预期早（学生交不了作业）。两者都不是能靠日志发现的事，
  // 与 `IMAGE_DRIVER` 写错是同一类（见 image-store-factory.js 的说明）。
  const quota = parsePhotoQuota(env.IMAGE_QUOTA_PER_STUDENT);
  if (quota.error) problems.push(quota.error);

  // 「还剩多少张开始提示」写错是同一类问题：配错了不报错，只是
  // 那句提示**该来的时候没来**（学生于是在下一次传不上去时才知道），
  // 或者每次提交都来（于是没人再读它）。
  const quotaWarn = parseQuotaWarnRemaining(env.IMAGE_QUOTA_WARN_REMAINING);
  if (quotaWarn.error) problems.push(quotaWarn.error);

  // ===== CORS =====
  // 通配放行等于「用户浏览器里随手打开的任意网页都能打这个服务的 /auth/login」。
  // 默认值本来就是收敛的，所以这里只提醒；真要通配就该知道自己在放弃什么。
  if (String(env.CORS_ALLOW_ORIGIN ?? '') === '*') {
    warnings.push(
      'CORS_ALLOW_ORIGIN=* ：任意网页都能向本服务发跨源请求，而 /auth/login 是公开端点 ——'
      + '等于给每个网页一个免费的口令爆破入口。生产请写成具体来源（逗号分隔）',
    );
  }

  // ===== 监听地址 =====
  if (production && String(env.BIND_HOST ?? '') === '0.0.0.0') {
    warnings.push(
      '生产环境 BIND_HOST=0.0.0.0：实例会直接对公网可达。'
      + '正常形态是放在 API 网关 / 负载均衡后面（那里统一做 TLS、限流与鉴权）',
    );
  }

  return { problems, warnings };
}
