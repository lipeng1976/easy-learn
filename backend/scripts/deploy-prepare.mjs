// 一键部署：**准备产物的那一段能自动化的，全自动化**。
//
// ⚠️ 先说清楚这个脚本**不是**什么：它**不会**登录你的云账号、**不会**创建/上传函数、
//    也**不会**碰你的生产数据库。原因不是「懒得做」，而是这三件事都要求
//    **一段人类才能提供的凭证 + 一次不可逆的外部写入**，而这个项目的规矩是
//    「拿不到可信依据时宁可如实报告缺口，不编造一个看起来对的结果」。
//
// 它做的是**上云前所有可离线验证的事**，一次跑完、一条命令：
//
//   1. 产物自检        —— 两个函数目录是否完整、入口在不在、有没有误带 node_modules
//   2. 生产配置自检    —— 缺 Key / 用了开发密钥 / 单价只填一半 全部拦下
//   3. 打印**该填的环境变量清单**（按平台填表顺序排好，可直接抄）
//   4. 打印**逐步部署命令**（含验收命令与反面判据）
//   5. 校验客户端构建参数是否齐（少了会「注册成功但没进云库」）
//
// 用法：
//   node serverless/deploy-prepare.mjs
//   node serverless/deploy-prepare.mjs --env-file .env.prod     # 带上就顺带跑配置自检
//   node serverless/deploy-prepare.mjs --zip                    # 额外打出两个待上传的 zip
//
// 退出码：0 = 可以上云；1 = 有**阻塞项**（照它说的补完再跑）。
import {
  cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync,
} from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..');

const args = process.argv.slice(2);
const getArg = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const hasFlag = (name) => args.includes(name);

const envFile = getArg('--env-file');

const problems = [];
const warnings = [];
const ok = (m) => console.log(`  \x1b[32m✓\x1b[0m ${m}`);
const bad = (m) => {
  problems.push(m);
  console.log(`  \x1b[31m✗\x1b[0m ${m}`);
};
const warn = (m) => {
  warnings.push(m);
  console.log(`  \x1b[33m!\x1b[0m ${m}`);
};
const head = (m) => {
  console.log('');
  console.log(`\x1b[1m${m}\x1b[0m`);
};

console.log('');
console.log('═══════════════════════════════════════════════════════════════');
console.log('  伴学 · 上云准备（本脚本不登录云账号、不写生产库）');
console.log('═══════════════════════════════════════════════════════════════');

// ─────────────────────────────────────────────────────────────────
head('① 产物自检');

/** 要上传的两个服务。`needsDeps` 决定要不要带 node_modules。 */
const SERVICES = [
  {
    name: '数据服务',
    dir: join(REPO, 'serverless', 'data-service'),
    /** 暂存目录名（`build/deploy/` 下）：这才是**真正上传的那一份**。 */
    stagingDir: 'data-service-code',
    /** 暂存目录内服务自身的子目录名 —— `src/*.js` 的 `../../shared/` 靠它对齐。 */
    subDir: 'data-service',
    needsDeps: true,
    depsNote: '必须带 node_modules（有 pg 这个运行时依赖）',
  },
  {
    name: 'AI 网关',
    dir: join(REPO, 'serverless', 'ai-gateway'),
    stagingDir: 'ai-gateway-code',
    subDir: 'ai-gateway',
    needsDeps: false,
    depsNote: '**刻意零依赖**，上传时不要带 node_modules（冷启动更快）',
  },
];

for (const svc of SERVICES) {
  const entry = join(svc.dir, 'index.cjs');
  if (!existsSync(svc.dir)) {
    bad(`${svc.name}：目录不存在 ${svc.dir}`);
    continue;
  }
  if (!existsSync(entry)) {
    bad(`${svc.name}：缺少入口 index.cjs`);
    continue;
  }
  const src = readFileSync(entry, 'utf8');
  if (!/exports\.handler/.test(src)) {
    bad(`${svc.name}：index.cjs 里没有 exports.handler（平台入口签名不对）`);
    continue;
  }
  // 生产环境的入口应该指向平台能识别的 CJS handler，而不是 ESM。
  ok(`${svc.name}：目录与 index.cjs 都在，handler 签名正常`);

  const nm = join(svc.dir, 'node_modules');
  const hasNm = existsSync(nm);
  if (svc.needsDeps) {
    if (hasNm) {
      const pgOk = existsSync(join(nm, 'pg'));
      pgOk
        ? ok(`${svc.name}：node_modules 里有 pg（运行时依赖齐）`)
        : bad(`${svc.name}：node_modules 存在但没有 pg —— 先 npm install`);
    } else {
      bad(`${svc.name}：没有 node_modules —— 上传前先 cd 进去 npm install`);
    }
  } else if (hasNm) {
    warn(`${svc.name}：目录里有 node_modules。${svc.depsNote}，打包时可以排除它`);
  } else {
    ok(`${svc.name}：零依赖，目录干净（${svc.depsNote}）`);
  }

  // 生产配置不能带进产物（这是最容易漏的一条）。
  const envPath = join(svc.dir, '.env.local');
  if (existsSync(envPath)) {
    warn(`${svc.name}：目录里有 .env.local —— **绝不能**打进上传包（里面是真 Key）`);
  }
}

// 数据服务必须带 sql/，否则云上第一次迁移没东西可跑。
const sqlDir = join(REPO, 'serverless', 'data-service', 'sql');
if (existsSync(sqlDir)) {
  const n = readdirSync(sqlDir).filter((f) => f.endsWith('.sql')).length;
  n > 0
    ? ok(`数据服务：sql/ 里有 ${n} 个迁移文件（云端 migrate 要用）`)
    : bad('数据服务：sql/ 里没有 .sql 文件');
} else {
  bad('数据服务：缺少 sql/ 目录 —— 云上无法建表');
}

// ─────────────────────────────────────────────────────────────────
head('② 生产配置自检');

if (envFile) {
  const p = resolve(envFile);
  if (!existsSync(p)) {
    bad(`--env-file 指定的文件不存在：${p}`);
  } else {
    const r = spawnSync(
      process.execPath,
      [join(REPO, 'serverless', 'data-service', 'scripts', 'check-config.mjs'),
       '--env-file', p, '--production'],
      { cwd: REPO, encoding: 'utf8' },
    );
    if (r.status === 0) {
      ok('数据服务配置自检通过（check-config.mjs --production）');
    } else {
      bad('数据服务配置自检未通过 —— 上面那几行就是缺的东西');
      if (r.stdout) console.log(r.stdout.trimEnd());
    }
  }
} else {
  warn('没给 --env-file，跳过配置自检。部署前务必跑：');
  console.log('      node serverless/data-service/scripts/check-config.mjs \\');
  console.log('        --env-file .env.prod --production');
}

// 密钥强度：这条不靠平台，必须自己看。
const SECRET_BANNED = 'dev-stack-secret-not-for-production';
console.log('');
console.log('  生产密钥自查（脚本看不到你的平台环境变量，只能提醒）：');
console.log(`    · AI_SESSION_SECRET 两个服务**必须是同一把**，且 ≥32 字符`);
console.log(`    · 绝不能是仓库里那把：${SECRET_BANNED}`);
console.log('      （它写在仓库里，任何人拿它都能签一张有效的票，且校验全过、不留痕）');
console.log('    · 生成：node -e "console.log(require(\'crypto\').randomBytes(48).toString(\'base64url\'))"');

// ─────────────────────────────────────────────────────────────────
head('③ 客户端构建参数');

console.log('  客户端「连哪一份库」是**构建期**定的，打错了不会报错，只会连错库：');
console.log('');
console.log('    flutter build apk --release \\');
console.log('      --dart-define=DATA_API_BASE_URL=https://<数据服务域名> \\');
console.log('      --dart-define=AI_BASE_URL=https://<网关域名> \\');
console.log('      --dart-define=AI_TIMEOUT_MS=90000 \\');
console.log('      --dart-define=AI_UPLOAD_TIMEOUT_MS=120000');
console.log('');
console.log('  ⚠️ 少了 DATA_API_BASE_URL = 客户端走**设备本地库**：');
console.log('     注册登录全「成功」，但数据根本不进云库，家长在另一台设备上什么都看不到。');

// Web 版多一条 CORS。
console.log('');
console.log('  Web 版（浏览器）还多一件事：数据服务的 CORS 白名单必须写**具体来源**。');
console.log('  不配 = 浏览器里全被拦、而**后端日志一条都没有**（CORS 在浏览器侧生效）。');
console.log('  CORS_ALLOW_ORIGIN=https://<你的 Web 域名>    ← 写具体来源，不要 *');

// ─────────────────────────────────────────────────────────────────
head('④ 逐步部署命令（按这个顺序）');

console.log(`
  第 1 步 · 云数据库建角色（先）与建表（后）
    cd serverless/data-service
    node scripts/provision-app-roles.mjs --env-file .env.prod --yes   # 先建带强口令的角色
    node scripts/migrate.mjs --env-file .env.prod --dry-run            # 再看会做什么（只读）
    node scripts/migrate.mjs --env-file .env.prod --yes                 # 真执行

    ⚠️ 顺序不能反：迁移 SQL 不含任何口令，角色不存在且未注入口令时会报错，
       不会静默用默认值。绝不要拿本机开发栈随机生成的口令去连云端库。

  第 2 步 · 备一份 .env.prod，然后跑上传前体检
    cp .env.prod.example .env.prod      # 照着模板填（模板进版本库，.env.prod 不会）
    node serverless/scripts/deploy-check.mjs --env-file .env.prod

    它做两件事，都是**上传前**必须知道的：
      · 对账 s.yaml 引用的变量与 .env.prod 里真有的值（漏一边都只会安静地出事）
      · 把两边配置自检跑一遍（生产用开发密钥、要求鉴权却没密钥……）
    详见 doc/release-guide.md 的「配置的唯一定义处」。

  第 3 步 · 一键上传（推荐）
    npm i -g @serverless-devs/s
    s config add                        # 填阿里云 AK/SK，别名用 default
    set -a && . ./.env.prod && set +a   # 把值灌进 shell；s 从环境变量里取
    s deploy                            # 一把上传两个函数（s.yaml 里描述）

    ⚠️ s.yaml 的 code 指向的是 **⑦ 建好的暂存目录**，不是 serverless/data-service/：
         build/deploy/data-service-code/
       （直接传 serverless/data-service/ 会**起不来**：它 import '../../shared/xxx.js'，
        而那两级落在包外。暂存目录就是为这件事存在的。）
       所以顺序是：先跑本命令（构造暂存目录）→ 再 s deploy。

  第 4 步 · 不想用 CLI 就手工上传
    上传的还是那两个暂存目录：build/deploy/data-service-code/ 与 ai-gateway-code/

    ⚠️ **内存不能填 256MB** —— FC3 要求 cpu : 内存(GB) 落在 **1:1 ~ 1:4** 之间，
       256MB(0.25GB) 配 0.5 核就是 2:1，创建时直接报 InvalidArgument，
       而那行报错看不出是内存配小了。

    平台配置（与 s.yaml 里的值一致）：
      数据服务：事件函数 · Node 20 · 入口 index.cjs 的 handler（垫片在包根）
                区域北京 · cpu 0.5 vCPU / 内存 1024MB · 超时 60s
                1GB 不是随便挑的：照片上传要 base64 编解码，12MB 请求体解码后
                还要再留一份给图片处理，512MB 以下容易 OOM（函数被强杀、无响应）
      AI 网关：事件函数 · Node 20 · 入口 index.cjs 的 handler（垫片在包根）
                区域北京 · cpu 0.25 vCPU / 内存 512MB · 超时 120s
                超时必须**大于**最慢那条模型链路；被掐断的表现是
                「AI 有时候没反应」，看着像网络抖动

    ⚠️ 路径这件事分两种情形，别混：
       · 直接用 FC3 的 HTTP 触发器（就是 s.yaml 的做法）：**不用配路径** ——
         FC3 把完整路径透传给函数，/data/* 和 /auth/* 原样到达。
       · 前面再挂 API Gateway / 自定义域名并且做了路径重写：**必须保住完整前缀**，
         否则线上每个请求都 404，而响应体是本服务的标准错误信封、**看起来完全正常**。

  第 5 步 · 环境变量去哪了
    走 s.yaml（第 3 步）时**不用手工填** —— 变量已经在 s.yaml 的
    environmentVariables 里，s deploy 会一起下发。清单见下面 ⑤，那是给
    「手工上传」和「核对控制台」用的。

    ⚠️ 手工上传的话这一格**必须逐项填**：配漏一项不会让服务起不来，
       只会让某个功能安静地不对（PGHOST 空了 → 连不上库；
       AI_SESSION_SECRET 空了 → 所有 /data/* 判「未配置」，
       客户端表现是「登录成功但进去一片空」）。

  第 6 步 · 验收（每一步都能红，尤其最后一条是**反面判据**）
    curl -i https://<数据服务域名>/health                      # 期望 200
    curl -i https://<网关域名>/ai/health                       # 期望 200
    curl -i https://<数据服务域名>/data/bootstrap              # 期望 **401**
    #   ↑ 返回 200 说明鉴权链断了。「永远 200」从正面看和正常一模一样。
    curl -i -X POST https://<数据服务域名>/auth/login \\
      -H 'content-type: application/json' \\
      -d '{"phone":"<真实测试账号>","password":"<口令>"}'       # 期望 200 带 token
    curl -s https://<网关域名>/ai/health | grep modelProvider  # 确认厂商是预期那个

  第 7 步 · 真凭证探活（这一步本地测不出来）
    cd serverless/ai-gateway
    node scripts/probe-ark-catalog.mjs        # 确认模型**确实已开通**
    cd ../data-service
    node --env-file=../../.env.prod scripts/probe-oss.mjs   # 确认 OSS 签名被真桶接受
`);

// ─────────────────────────────────────────────────────────────────
head('④-2 模型厂商开关（`AI_MODEL_PROVIDER`）');

// 这一段在 2026-09-23 之前是「换厂商必须改代码」的三条清单；
// 2026-09-30 晚又改了第二次 —— 从「共用一组槽位、切换时手工换值」
// 改成「两套配置并存，切换只动这一个变量」。
console.log(`
  网关支持**用开关选厂商**，不改代码，也不改值：

    AI_MODEL_PROVIDER=ark        # 火山引擎方舟（**默认**，不配就是这个）
    AI_MODEL_PROVIDER=bailian    # 阿里云百炼

  ⭐ 两组环境变量**互不覆盖**，同时存在。切过去、切回来都不需要重新填任何值：

      方舟那一组      ARK_API_KEY · ARK_REGION · ARK_MODEL_* · ARK_PRICE_* · ARK_THINKING_DISABLED_KINDS
      百炼那一组      BAILIAN_API_KEY · BAILIAN_MODEL_* · BAILIAN_PRICE_* · BAILIAN_THINKING_DISABLED_KINDS

  这个开关管的是「协议差异」，也就是那些**照抄会静默出错**的地方：
  baseUrl 默认值 · 思维链字段名与取值 · tool_choice 能不能传对象 ·
  以及跟着厂商走的**模型名 / 单价 / 思维链名单**。

  ⚠️ 为什么单价与思维链名单也要分（2026-09-30 补的）：
    它们**不参与任何功能**，错了完全没有症状 ——
    · 单价错了 → 接口全通、看板给出一个**格式完整、数值错误**的成本数字
    · 名单错了 → 百炼用短名单 = 硬约束悄悄降级；方舟用长名单 = 白关思维链
    所以「跟着厂商走」这件事必须在**读取时**就分好，不能靠人记得改。

  ⚠️ 回退仍然保留（旧的单套写法不会失效）：
    BAILIAN_* 为空时会回退去读 ARK_* / AI_PRICE_* / AI_THINKING_DISABLED_KINDS。
    但那意味着你读到的是**另一家的值** —— 是否发生了回退，看 /ai/health 的
    modelProviderEnvFallbacks（正常是空数组；非空就是漏填了前缀）。

  ⚠️ 换来换去之前要确认的两件事：

  1) 模型名两家的形态**互不认**，自检会在两个方向都拦（2026-09-30 补齐反方向）
       方舟形如 doubao-seed-2-1-pro-260628（带 -YYMMDD 后缀）
       百炼形如 qwen3-max / qwen3-vl-plus
     ⚠️ 守卫**只在端点还是厂商默认地址时**生效 —— 指向自建网关 / 本机 Ollama 时
     模型名不受约束（否则那条退路会被堵死）。

  2) 真凭证探活（本地测不出来）
       cd serverless/ai-gateway
       node scripts/probe-ark-catalog.mjs     # 确认模型**确实已开通**
     切到另一家之后，**那一家的链路要重新真调一次** —— 单元测试只能证明
     "读值读对了"，证明不了"那家的 Key + 模型名 + 端点真能用"。

  🔴 下面这条旧结论**已被实测推翻**，别再照着做（保留在此以防有人翻到旧笔记）：
     "百炼对非流式调用思考模式模型有限制 → 必须关思维链"
     真相（2026-09-24 真凭证实测）：不发 enable_thinking 时思考照常跑
     （usage 里 reasoning_tokens 有值）。真正被禁的只有
     「思考模式 + 对象/required 形式的 tool_choice」（那会 400）。

  验证开关是否真的生效（这条比看配置可靠）：
     curl -s https://<网关域名>/ai/health | grep -E 'modelProvider|modelProviderEnv'
  它会如实回显当前厂商**与它读的是哪一组变量**。**改了环境变量但实例缓存
  没重建**时，这里显示的和实际调用的会不一致 —— 所以签名里带了厂商。
  生产环境特意**不回显 baseUrl**（避免带出内网地址）。
`);

console.log('');

// ─────────────────────────────────────────────────────────────────
head('⑤ 环境变量清单（可直接抄）');

console.log(`
  ── 数据服务 ──────────────────────────────────────────────
  NODE_ENV=production                 必填。决定下面那些拦截是否生效
  PGHOST=<主机>                        必填
  PGPORT=5432                          必填
  PGDATABASE=easy_learn                必填
  PGUSER=app_rls                       **应用角色**，不是管理员
  PGPASSWORD=<强口令>                  必填
  PG_AUTH_USER=app_auth                鉴权角色，只碰三张账号表
  PG_AUTH_PASSWORD=<另一个强口令>

  ── 只在跑迁移时读到，**不要配到函数上** ──────────────────
  PG_OPS_USER=<管理员账号>              运维连接：迁移要建 BYPASSRLS 角色
  PG_OPS_PASSWORD=<管理员口令>          只有 migrate.mjs 读它
    ⚠️ 为什么单独命名而不复用 PGUSER：同一个名字上挂着两个互斥的值 ——
       迁移要管理员、函数上必须是 app_rls，而 loadEnv 是文件优先（shell 覆盖无效）。
       分开命名还顺带保证**管理员凭证不上云**。
  AI_SESSION_SECRET=<≥32 字符>         与 AI 网关**同一把**
  AI_GATEWAY_BASE_URL=<网关公网 URL>    每日打卡的**服务端出题**要调它（两个服务两个函数）
    ⚠️ 不配 = 打卡出题回 model_not_enabled（其余功能正常，启动日志有警告）；
       千万别写 127.0.0.1 兜底 —— 云上那就是「打卡永远出不了题」而日志看着正常。
  IMA_CREDENTIAL_SECRET=<≥32 字符>      ima 密钥的加密口令（opt-in；不配则连 ima 回 server_config_missing）
    ⚠️ 轮换后旧密文解不开，家长要重新连接一次。
  PGSSLMODE=require                    云 PG 常只接受 TLS
                                       （实测本项目那台支持 SSL，TLSv1.3；
                                        换新实例先跑 probe-db-access.mjs 问一句）
  CORS_ALLOW_ORIGIN=<具体来源>          Web 版必填，不要 *
  PG_POOL_MAX=5 / PG_AUTH_POOL_MAX=3    建议显式，见连接数坑

  ── 函数走 VPC 内网连库（**只有数据服务要**，见 s.yaml 的 vpcConfig）──
  FC_VPC_ID=<vpc-xxx>                   与 RDS 同一个 VPC
  FC_VSWITCH_ID=<vsw-xxx>               要在 FC 支持的可用区
  FC_SECURITY_GROUP_ID=<sg-xxx>         别选云服务托管的那些
    ⚠️ 不配这三项 = 函数只能从公网连库，而 FC 的**出口 IP 是动态的** ——
       白名单追不上，只能放开一大片网段（等于把库敞在公网上）。
    ⚠️ RDS 白名单要用 **IP 段**方式授权（**别用安全组**，否则「偶尔连不上」），
       并把**交换机网段 CIDR** 加进去；安全组**出方向**放行 5432 与 **ICMP**。
    ⚠️ AI 网关**刻意不配**：它不碰库，而配 VPC 会拖慢冷启动。别为了「一致」补上。
    ⚠️ 配了 VPC 之后 internetAccess: true 仍要留着（数据服务还要连 OSS 公网域名）。

  ── 照片存储（二选一，见 ⑥）──────────────────────────────
  IMAGE_DRIVER=oss                      云函数用 oss；fs 只在有持久磁盘时成立
  #  走 oss 时填这几项：
  OSS_BUCKET=<桶名>
  OSS_REGION=cn-hangzhou                **参与签名**，必须与桶所在区域一致
  OSS_ACCESS_KEY_ID=<RAM 子账号>        只授予该桶 PutObject/GetObject，别用主账号
  OSS_ACCESS_KEY_SECRET=<密钥>
  OSS_ENDPOINT=<可留空>                 线上同区域填 oss-<region>-internal.aliyuncs.com
                                        ⚠️ 内网域名只能从**同区域**的机器访问 ——
                                        本机跑探活脚本要用外网域名，两者各填各的
  OSS_PREFIX=<可留空>                   多套环境共用一个桶时用它隔离
  #  走 fs 时填这一项（仅 ECS + 挂载了云盘/NAS 的部署）：
  IMAGE_ROOT_DIR=<挂载点>
  IMAGE_QUOTA_PER_STUDENT=3000          每学生照片**张数**上限（两条后端共用）
  IMAGE_QUOTA_WARN_REMAINING=20         剩余少于它时给学生一句提示（0 = 不提前提示）

  ── AI 网关 ──────────────────────────────────────────────
  NODE_ENV=production
  AI_MODEL_PROVIDER=ark                选厂商：ark（默认）/ bailian。见 ④-2
                                       ⭐ **只改这一个变量就能换厂商**（改完重新部署）

  # 方舟那一组（前缀 ARK_，与旧名同字）
  ARK_API_KEY=<方舟的 Key>
  ARK_REGION=cn-beijing                只有方舟用；百炼端点固定，留着也无害
  ARK_MODEL_VISION=<视觉档>            拍照识别/批改。没有就留空
  ARK_MODEL_REASONING=<强推理档>        错题判定/讲解/出题
  ARK_MODEL_LIGHT=                     当前没有业务端点用它，留空
  ARK_THINKING_DISABLED_KINDS=<路由名单> 方舟的关思维链名单（只用来省时间）
  ARK_PRICE_*（六个）                   方舟单价。见下方 ＜单价＞ 那一段

  # 百炼那一组（前缀 BAILIAN_）—— 与上面**并存**，互不覆盖
  BAILIAN_API_KEY=<百炼的 Key>
  BAILIAN_MODEL_VISION / _REASONING / _LIGHT
  BAILIAN_THINKING_DISABLED_KINDS=<路由名单>
                                       百炼这份**必须更长**：它在思维链开启时不接受
                                       对象 tool_choice，多关几条路由才拿得回硬约束
  BAILIAN_PRICE_*（六个）

  AI_REQUIRE_AUTH=true                 **生产必须 true**，否则 studentId 可被伪造
  AI_SESSION_SECRET=<与数据服务同一把>
  AI_KV_DRIVER=http                    多实例必须；memory 会让配额成倍放大
  AI_KV_URL=<KV 地址>
  AI_KV_TOKEN=<KV 口令>
  AI_METRICS_TOKEN=<看板口令>           公网部署必须配
  AI_THINKING_DISABLED_KINDS=<路由名单>  旧通用槽：**只作为回退**。
                                       两套并存时请填上面各自那一份 ——
                                       留着它会成为「切过去之后串价/串名单」的入口
  AI_PRICE_*（六个）/ ARK_PRICE_*（六个）/ BAILIAN_PRICE_*（六个）
       ↑ 每家**要么六个全填、要么全空**。全空 = 看板如实显示「成本未知」（这是对的）；
         只填一半 = 缺的被算成 0，看板给出一个偏小但看起来完整的数字（最坏）。
         ⚠️ 单价**跟着厂商走**：用甲家的价算乙家的账，接口全通、看板数字是错的。
`);

// ─────────────────────────────────────────────────────────────────
head('⑥ 两件必须先定下来的事');

console.log(`
  1) 照片存哪 —— **后端两条都已实现，按部署形态选一条**
     由 IMAGE_DRIVER 决定（默认 fs，所以既有部署行为不变）：

       · fs —— 文件系统。**只在有持久磁盘的部署上成立**（ECS + 挂载云盘/NAS）。
               函数计算上必丢数据：实例回收后文件就没了，多实例之间也不共享 ——
               症状是「上传成功，过一会儿图没了」或「换台设备就看不到」。
               配置：IMAGE_ROOT_DIR

       · oss —— 阿里云对象存储。**函数计算上唯一正确的选择**。
               配置：OSS_BUCKET / OSS_REGION / OSS_ACCESS_KEY_ID / OSS_ACCESS_KEY_SECRET
               可选：OSS_ENDPOINT（同区域填 oss-<region>-internal.aliyuncs.com 走内网）
                     OSS_PREFIX  （多套环境共用一个桶时用它隔离）

     ⚠️ 生产用 fs 时启动自检会**警告但不拦** —— ECS 挂盘是正当部署，
        一律拦下等于让一种正确做法起不来。
     ⚠️ IMAGE_DRIVER 写错会**直接起不来**，不会静默退回 fs。

     ⚠️ 签名是零依赖自写的（V1 对新账号/新桶已禁用，必须 V4）。
        单元测试对齐了官方算例，但**签名对不对只有 OSS 说了算** ——
        上线前务必用真凭证打一次：
            node --env-file=.env.oss scripts/probe-oss.mjs
        它验的是「配好了」这件事，本地测不出来（桶 ACL、RAM 权限、区域、时钟偏差）。

     ⚠️ 生产请用**只授予该桶 PutObject/GetObject 的 RAM 子账号**，别用主账号 AccessKey。

     ⚠️ 每学生照片配额默认 **3000** 张（IMAGE_QUOTA_PER_STUDENT），达到上限时
        写照片回 409 storage_quota_exceeded（不是「保存失败」—— 它是再试也不会好的那类）。
        剩余不足 IMAGE_QUOTA_WARN_REMAINING（默认 20）张时，提交成功后给学生一句提示 ——
        没有这句提示的话，学生会在**下一次传不上去**时才知道，而那时作业已经交不了了。
        **这个数在计费上是有含义的**：按实拍 1–3MB 估，3000 张 ≈ 3–9GB/学生，
        OSS 标准存储约 0.12 元/GB/月 → 约 4–13 元/年/学生。改小是安全的
        （已有照片不会因此被删，只是不再接受新的）。

     ⚠️ 3000 张按「一天 3–5 张」算约 **1.6–2.7 年** —— 学生是**会撞到它**的。
        撞到之后怎么办（手工删旧照片 / 系统按归档期清理）**还没定**，
        见 doc/historical-data-plan.md 的「清理与归档」一节。
        这件事得在上线前想清楚：**配额只让写入停下，不让空间能被重新使用。**

  2) 连接数算式（写进值班手册）
     函数实例会弹性伸缩，每个实例都有自己的连接池。
        实例上限 × (PG_POOL_MAX + PG_AUTH_POOL_MAX) < 数据库 max_connections
     默认值下是 8 连接/实例，50 个实例 = 400 连接，很容易打爆。
     症状是**高峰期大面积超时**（看着像接口变慢，其实是连不上库）。
`);

// ─────────────────────────────────────────────────────────────────
head('⑦ 构造部署暂存目录');

/**
 * ## 为什么需要这一层目录（这是本地绝对复现不出来的一类错）
 *
 * 两个服务都在源码里 `import '../../shared/xxx.js'` —— 相对**服务目录**的上两级。
 * 而平台要求**入口文件位于代码包的根目录**（`handler: index.handler`，不带路径）。
 *
 * 这两件事在「包根 = 服务目录」的前提下**不可能同时成立**：
 * 打包 `serverless/data-service/` 时，`../../shared/` 指向**包外**。
 * 线上症状是函数起不来（`Cannot find module .../shared/token.js`），
 * 而它在本地永远复现不出来 —— 本地跑的时候 `serverless/shared/` 就在旁边，
 * 同样的相对路径恰好对得上。**「本地全绿、线上才炸」的又一型。**
 *
 * 所以包结构构造成：
 *
 *     <包根>/index.cjs        ← 本脚本生成的转发垫片（满足「入口在包根」）
 *     <包根>/shared/          ← 从 serverless/shared 整目录复制
 *     <包根>/data-service/    ← 服务目录原样搬进来
 *         src/ …              ← 它的 `../../shared/` 正好落回包内的 shared/
 *
 * 为什么不干脆把 shared 复制成两份、把 import 改成 `../shared/`：
 * 那等于让错误码与 token 契约有**两个来源**，分叉时的症状是
 * 「同一个失败在两个服务里叫两个名字」—— 正是 `shared/package.json`
 * 的 description 里点名要避免的那类 bug。仓库里保持单一来源，
 * 「搬进包」这件事只发生在打包这一步。
 */
const STAGING_ROOT = join(REPO, 'build', 'deploy');
const SHARED_SRC = join(REPO, 'serverless', 'shared');

/** 服务目录里不该进包的顶层目录。 */
const STAGING_SKIP_TOP = new Set(['build', 'out', 'test']);
/** `node_modules` 里的本机开发依赖：云端入口链不碰它们。 */
const STAGING_SKIP_DEPS = new Set(['embedded-postgres', '@embedded-postgres']);

/**
 * 复制服务目录时的过滤器。
 *
 * `embedded-postgres` 必须排除：它是 devDependency，被 `src/pg-local.js` 顶层 import，
 * 而 `pg-local.js` **只在 scripts/ 里被引用**（本机起库、跑测试、迁移），
 * 不在 `handler.js` 的依赖链上。带上它，包会大一个数量级；
 * 而它又确实有可能在大起来的过程中**大得毫无意义**。
 */
function makeStagingFilter(svcDir, { dropNodeModules }) {
  return (src) => {
    const rel = relative(svcDir, src);
    if (rel === '') return true;
    const parts = rel.split(sep);
    const top = parts[0];
    // 顶层点开头的一律排除：.env* / .pgdata-* / .s / .testout.txt 这些本机杂项。
    // 注意只看**顶层**，所以 node_modules 内部的点文件不受影响。
    if (top.startsWith('.')) return false;
    if (top.endsWith('.log')) return false;
    if (STAGING_SKIP_TOP.has(top)) return false;
    if (dropNodeModules && top === 'node_modules') return false;
    if (top === 'node_modules' && parts.length >= 2 && STAGING_SKIP_DEPS.has(parts[1])) {
      return false;
    }
    return true;
  };
}

/**
 * 根级入口垫片的文本。**生成而不是手写**：两份内容只差一行相对路径，
 * 手写就会漂，而漂了的症状是「另一个服务指向了自己」。
 */
function entryShim(subDir) {
  return `/**
 * 部署包的根级入口垫片 —— 由 serverless/deploy-prepare.mjs 生成，**不要手改**。
 *
 * 它存在的原因见 deploy-prepare.mjs 的「⑦ 构造部署暂存目录」：
 * 服务源码要 import '../../shared/xxx.js'，而平台要求入口在包根，
 * 二者只能靠多一层目录同时满足。
 *
 * 真正的实现在 ./${subDir}/src/handler.js。
 */
exports.handler = async function handler(event, context) {
  const module = await import('./${subDir}/src/handler.js');
  return module.handler(event, context);
};
`;
}

/** 递归数文件个数 —— 只为让人对上「这一包有多少东西」有个体感，不参与判断。 */
function countFiles(dir) {
  let n = 0;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    n += entry.isDirectory() ? countFiles(join(dir, entry.name)) : 1;
  }
  return n;
}

mkdirSync(STAGING_ROOT, { recursive: true });

for (const svc of SERVICES) {
  const staging = join(STAGING_ROOT, svc.stagingDir);
  rmSync(staging, { recursive: true, force: true });
  mkdirSync(staging, { recursive: true });

  cpSync(SHARED_SRC, join(staging, 'shared'), { recursive: true });
  cpSync(svc.dir, join(staging, svc.subDir), {
    recursive: true,
    filter: makeStagingFilter(svc.dir, { dropNodeModules: !svc.needsDeps }),
  });
  writeFileSync(join(staging, 'index.cjs'), entryShim(svc.subDir), 'utf8');

  // 判据①：结构。三样缺一不可，缺了任何一样线上都是「函数起不来」。
  const must = [
    [join(staging, 'index.cjs'), '根级入口 index.cjs'],
    [join(staging, 'shared', 'token.js'), 'shared/token.js（两个服务都 import 它）'],
    [join(staging, 'shared', 'package.json'), 'shared/package.json（缺了它 shared 会被当 CJS 解析）'],
    [join(staging, svc.subDir, 'src', 'handler.js'), `${svc.subDir}/src/handler.js`],
  ];
  const missing = must.filter(([p]) => !existsSync(p)).map(([, label]) => label);
  if (missing.length > 0) {
    bad(`${svc.name}：暂存目录缺 ${missing.join(' / ')}`);
    continue;
  }

  // 判据②：**相对路径真的解析得到**。这条才是关键 ——
  // 结构对不代表 `../../shared/` 落点对，而落点错了只有线上才看得见。
  // 在暂存目录里 import 一次 `src/auth.js`（它直接 import 那两个 shared 模块，
  // 且不碰数据库），能加载成功就说明 shared 被找到了。
  const probePath = join(staging, svc.subDir, 'src', 'auth.js');
  const probe = spawnSync(
    process.execPath,
    ['--input-type=module', '-e', `await import(${JSON.stringify(pathToFileURL(probePath).href)});`],
    { encoding: 'utf8' },
  );
  if (probe.status !== 0) {
    bad(
      `${svc.name}：暂存目录里 ${svc.subDir}/src/auth.js 加载失败 —— `
        + `说明 '../../shared/' 解析不到。${(probe.stderr ?? '').trim().split('\n')[0]}`,
    );
    continue;
  }

  const files = countFiles(staging);
  ok(`${svc.name}：暂存目录就绪（${files} 个文件）· 入口在根 · shared 解析通过`);
  console.log(`      ${relative(REPO, staging).replace(/\\/g, '/')}`);
}

// ─────────────────────────────────────────────────────────────────
if (hasFlag('--zip')) {
  head('⑧ 打包');

  // 用平台无关的方式打包：Git Bash 和 PowerShell 里都有 tar（Windows 10+ 自带 bsdtar）。
  // 不引第三方 zip 库 —— 这是个准备脚本，多一个依赖就多一个装不上的理由。
  //
  // ⚠️ **输出路径必须用相对路径**（配 `cwd`），不能传 `D:\...` 这种绝对路径：
  //    GNU tar 把 `host:path` 当**远端规格**，于是 `D:\x.zip` 里的 `D:` 被当成主机名，
  //    报 `tar (child): Cannot connect to D: resolve failed` / `Child returned status 128`，
  //    退出码 2。而这个报错看着像「tar 装坏了」，实际只是路径形式。（已踩，2026-09-23）
  //    注意 `tar -tzf` 读包同理，别只改一半（第一版就是这样漏了校验那一半）。
  const outDirRel = join('build', 'deploy');
  mkdirSync(join(REPO, outDirRel), { recursive: true });

  for (const svc of SERVICES) {
      const zipName = svc.needsDeps ? 'data-service.zip' : 'ai-gateway.zip';
      const staging = join(outDirRel, svc.stagingDir);

      if (!existsSync(join(REPO, staging, 'index.cjs'))) {
        bad(`${svc.name}：暂存目录没建起来（见 ⑦），跳过打包`);
        continue;
      }

      // 打包的是**暂存目录**，不是服务目录 —— 那才是结构正确、能上线的那一份。
      // 排除规则在这里只剩兜底作用（⑦ 的 filter 已经过滤过一遍），
      // 留着它防的是将来有人改坏了 filter。
      //
      // ⚠️ 必须写 `./.*` 而不是 `.*`：
      //    tar 归档里的顶层路径就是 `./`，它本身也"点开头" → `.*` 会把 `./` 整个吃掉，
      //    打出一个 **0 字节的包**，而且上面还报 `✓ 0 KB`（成功）—— 又一个静默失败。
      //    （已踩两次：一次是 0 KB 假成功，一次是 `tar -tzf` 读包时漏改另一半）
      const excludes = [
        '--exclude=.env.local',
        '--exclude=.env.prod',
        '--exclude=*.log',
        '--exclude=./.*',
      ];

      // 先删旧包：同名文件被别的进程占着时 tar 会报 `EBUSY`，
      // 而那个报错看着像「tar 坏了」，其实只是残留文件。（已踩，2026-09-23）
      rmSync(join(REPO, outDirRel, zipName), { force: true });

      const r = spawnSync(
        'tar',
        ['-czf', join(outDirRel, zipName), ...excludes, '-C', staging, '.'],
        { cwd: REPO, encoding: 'utf8' },
      );
      if (r.error || r.status !== 0) {
        bad(
          `${svc.name}：打包失败（${r.error?.message ?? `退出码 ${r.status}: ${(r.stderr ?? '').trim().split('\n')[0]}`}）`,
        );
        continue;
      }
      const bytes = statSync(join(REPO, outDirRel, zipName)).size;
      const kb = (bytes / 1024).toFixed(0);
      // 体积断言。没有它，「exclude 规则写错 → 空包」会以 `✓ 0 KB` 的样子报成功，
      // 而这个空包上传到平台后**部署也会成功**，直到线上第一个请求才 500。
      if (bytes < 20 * 1024) {
        bad(`${svc.name}：包只有 ${kb} KB，不像个能跑的服务包 —— 检查 exclude 规则是否把代码也排掉了`);
        continue;
      }
      ok(`${svc.name} → build/deploy/${zipName}（${kb} KB）`);
    }

  console.log('');
  console.log('  ⚠️ 打包前务必确认 zip 里**没有** .env.local（真 Key 在里面）：');
  console.log("       tar -tzf build/deploy/data-service.zip | grep -E '\\.env\\.'");
  console.log('     这条命令应当**什么都不输出**。输出了就说明包里有密钥，别上传。');
  console.log('     ⚠️ 判据必须是 `\\.env\\.` 而不是松散的 `grep -i env` —— 后者会把');
  console.log('        `shared/env.js` 和 `scripts/lib/env-file.mjs` 这两个**源码文件**');
  console.log('        也报出来，于是这条命令**永远有输出**。一个永远报警的检查，');
  console.log('        看两次之后就没人看了 —— 而它要拦的是真密钥。');

  // 顺手真验一次，不靠人记得跑。
  for (const name of ['data-service.zip', 'ai-gateway.zip']) {
    const zipRel = join(outDirRel, name);
    if (!existsSync(join(REPO, zipRel))) continue;
    const list = spawnSync('tar', ['-tzf', zipRel], { cwd: REPO, encoding: 'utf8' });
    const entries = (list.stdout ?? '').split('\n').filter((l) => l.trim() !== '');
    const leaked = entries.filter((l) => /\.env\./i.test(l));
    // 空包会「通过」泄漏检查（什么都没打进，当然没密钥）—— 所以先断言它非空。
    if (entries.length < 10) {
      bad(`${name}：归档里只有 ${entries.length} 个条目 —— 包是空的，泄漏检查的"通过"没有意义`);
      continue;
    }

    // 结构判据（读包而不是读磁盘 —— 验的是**真正上传的那份**）。
    // 少了 shared/ 的症状是函数起不来 `Cannot find module .../shared/token.js`，
    // 而本地永远复现不出来：本地跑的时候 serverless/shared 就在服务目录旁边。
    const layout = [
      [/^\.\/index\.cjs$/, '根级入口 index.cjs'],
      [/^\.\/shared\/token\.js$/, 'shared/token.js'],
      [/^\.\/shared\/package\.json$/, 'shared/package.json（缺它 shared 会被当 CJS 解析）'],
    ];
    const missing = layout.filter(([re]) => !entries.some((l) => re.test(l))).map(([, w]) => w);

    if (leaked.length > 0) {
      bad(`${name} 里打进了环境文件：${leaked.join(', ')} —— **不要上传这个包**`);
    } else if (missing.length > 0) {
      bad(`${name} 里缺 ${missing.join(' / ')} —— 上传后函数起不来`);
    } else {
      ok(`${name}：${entries.length} 个条目 · 入口在根 · shared 在包内 · 无 .env.*`);
    }
  }
} else {
  head('⑧ 打包（可选）');
  console.log('  要顺手打出两个待上传的 zip，加 --zip 重跑本命令。');
  console.log('  ⚠️ 用 `s deploy`（走 s.yaml）时**不需要** zip —— 它直接上传 ⑦ 建好的暂存目录。');
}

// ─────────────────────────────────────────────────────────────────
console.log('');
console.log('═══════════════════════════════════════════════════════════════');
if (problems.length === 0) {
  console.log(`  \x1b[32m可以上云\x1b[0m —— 阻塞项 0 个，提醒 ${warnings.length} 条`);
  // ⚠️ 这个「0 个」只说**本脚本查过的那几件事**。它**不**核对 s.yaml 里引用的
  //    环境变量是不是都取得到值 —— 那是 deploy-check 的活，而那个方向漏了会**安静地出事**
  //    （平台拿到空串，函数照常启动、健康检查照样 200，只在第一个用到它的请求上失败）。
  //    所以两个脚本口径不同是**正常**的：这里 0 个、deploy-check 那边可能报 2 个致命。
  //    别把这一行当成放行信号 —— 真正的闸门是 deploy-check 的退出码。
  //    （2026-09-24 加 vpcConfig 时实测到这件事：这里报 0 个，那里报 2 个。）
  console.log('  接下来照 ④ 的顺序做；每步的验收命令都在上面。');
  console.log('  ⚠️ 本脚本「不查」引用对账 —— 上传前必须再跑一次（那个才是闸门）：');
  console.log('       node serverless/scripts/deploy-check.mjs --env-file .env.prod');
  console.log('═══════════════════════════════════════════════════════════════');
  console.log('');
  process.exit(0);
} else {
  console.log(`  \x1b[31m还不能上云\x1b[0m —— 阻塞项 ${problems.length} 个：`);
  for (const p of problems) console.log(`    · ${p}`);
  console.log('═══════════════════════════════════════════════════════════════');
  console.log('');
  process.exit(1);
}
