#!/usr/bin/env node
/**
 * 上传前体检 —— 走 Serverless Devs（`s deploy`）这条路时的最后一道闸。
 *
 * ## 它防的是什么
 *
 * `s.yaml` 里所有密钥都写成 `${env('X')}`，值由 shell 注入。这套做法的好处是
 * **s.yaml 能进版本库、密钥不进**；坏处是同一件事有了两个副本，而且是分开的两份：
 *
 *   · s.yaml 说「平台需要 X」
 *   · .env.prod 说「X 的值在这」
 *
 * 两边只要漏一边，症状都极其安静：
 *   · s.yaml 引用了 X，而 .env.prod 里没写 X → 平台拿到**空串**。
 *     函数照样启动、健康检查照样 200，只在**第一个用到它的请求**上以奇怪的样子失败
 *     （PGHOST 空了 → 连不上库；AI_SESSION_SECRET 空了 → 所有 /data/* 判「未配置」）。
 *   · .env.prod 写了 Y，而 s.yaml 没引用 Y → 你明明配了、值却根本没上传。
 *     这个更难查：控制台上看不到 Y，因为没人问过平台要它。
 *
 * ## 一个容易搞错的地方：平台上那份配置是**两半加起来**
 *
 * 平台实际拿到的 = s.yaml 里**写死的值** ∪ `${env('X')}` 注入的值。
 * 只把后者喂给配置自检，校验的就不是「平台上那份配置」——
 * 比如 `AI_KV_DRIVER=memory` + `AI_ALLOW_EPHEMERAL_KV=true` 是写在 s.yaml 里的，
 * 只看 shell 就会报「生产不许用 memory」，看着像真问题，其实平台上允许。
 * 所以下面第一步先把两半合起来，**再**去问那两个服务「这份配置行不行」。
 *
 * ## 为什么复用那两份 validateConfig 而不在这里重写
 *
 * 因为「空串」这件事，两个服务各自已经有一套很细的判据（生产用开发密钥、
 * 要求鉴权却没密钥、IMAGE_DRIVER 认不出来……）。抄一份就多一处会漂的副本，
 * 而漂的方向是把拦截悄悄放松。这里只负责把配置喂给它们、把结论带出来。
 *
 * 用法：
 *   node serverless/scripts/deploy-check.mjs --env-file .env.prod
 *   node serverless/scripts/deploy-check.mjs              # 只看当前 shell
 *
 * 退出码：0 = 可以上传；1 = 有致命问题，先修。
 */
import { lookup } from 'node:dns/promises';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { loadEnv, valueOf } from '../data-service/scripts/lib/env-file.mjs';
import { validateConfig as validateDataService } from '../data-service/src/config-check.js';
import { loadConfig, validateConfig as validateAiGateway } from '../ai-gateway/src/config.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..', '..');
const S_YAML = resolve(REPO, 's.yaml');

const problems = [];
const warnings = [];

const ok = (m) => console.log(`  ✓ ${m}`);
const warn = (m) => {
  warnings.push(m);
  console.log(`  ⚠️  ${m}`);
};
const bad = (m) => {
  problems.push(m);
  console.log(`  ✗ ${m}`);
};

console.log('═══════════════════════════════════════════════════════════════');
console.log('  上传前体检（Serverless Devs 路径）');
console.log('═══════════════════════════════════════════════════════════════\n');

if (!existsSync(S_YAML)) {
  console.log(`  ✗ 找不到 ${S_YAML} —— 没有它就没有「一键上传」这条路\n`);
  console.log('✗ 1 个致命问题，先修。');
  process.exit(1);
}

const yaml = readFileSync(S_YAML, 'utf8');

/**
 * 抓出所有 `${env('NAME')}` 引用，连同**同一行上的 `@optional` 标记**。
 *
 * 标记必须与引用同行 —— 这是刻意设计：判断「必填还是可空」的名单**只有这一处**，
 * 不在本脚本里另抄。抄一份名单的后果是：s.yaml 加了新变量而名单没跟，
 * 于是新变量永远被判成「可空」，而它恰恰是最可能被漏配的那一个。
 */
const REF = /\$\{env\('([A-Z0-9_]+)'([,)])/;
const refs = [];
yaml.split(/\r?\n/).forEach((line, i) => {
  // ⚠️ **整行注释必须跳过**。s.yaml 的说明文字里就写着 `${env('X')}`（用来解释这套
  //    语法），不跳过的话它会变成一个叫 `X` 的「必填变量」，凭空报一条查无此物的错。
  //    实测踩过：报错精确指向 `s.yaml:9`，而第 9 行是一段注释 —— 那种错会让人
  //    开始怀疑脚本而不是配置，最后的结果是把整套检查绕过去。
  if (/^\s*#/.test(line)) return;
  const m = REF.exec(line);
  if (!m) return;
  refs.push({
    name: m[1],
    line: i + 1,
    optional: /#\s*@optional\b/.test(line),
    // 第二参数是**回落值**（`${env('X', '')}`）。这件事必须单独抓出来：
    //   s CLI 把「值为空」与「变量不存在」看成**同一件事**，都直接抛
    //   `RuntimeError: env('X') not found` 并让整个部署失败。
    //   所以在 s.yaml 里**只标 `# @optional` 是不够的** —— 必须有回落值。
    //   （2026-09-24 实测：8 个标了 @optional 的引用全没有回落值，
    //    闸门说「允许留空」，s 却拒绝部署，而且报错只指向第一个变量。）
    hasFallback: m[2] === ',',
  });
});

/**
 * 把 `environmentVariables:` 块里**写死的**那些值也抠出来。
 *
 * 判据靠缩进：`environmentVariables:` 那行的缩进为基准，往后所有缩进更深的行都算它的内容。
 * 块内只会是 `KEY: value` 这种平铺结构（没有嵌套），所以不必真解析 YAML。
 * 只认 `[A-Z][A-Z0-9_]*` 形式的键 —— 这样 `description:` / `triggerConfig:` 这类
 * 小写的兄弟键不会被误收进来。
 */
function literalEnvFromSqaml(text) {
  const out = {};
  const lines = text.split(/\r?\n/);
  let baseIndent = null;
  for (const raw of lines) {
    if (raw.trim() === '') continue;
    const indent = raw.length - raw.trimStart().length;

    if (baseIndent !== null && indent <= baseIndent) baseIndent = null; // 块结束
    if (baseIndent === null) {
      if (/^\s*environmentVariables:\s*$/.test(raw)) baseIndent = indent;
      continue;
    }

    const m = /^\s*([A-Z][A-Z0-9_]*):\s*(.*)$/.exec(raw);
    if (!m) continue;
    let value = m[2].replace(/\s+#.*$/, '').trim(); // 去掉行尾注释（含 @optional）
    if ((value.startsWith("'") && value.endsWith("'"))
        || (value.startsWith('"') && value.endsWith('"'))) {
      value = value.slice(1, -1);
    }
    if (REF.test(value)) continue; // 引用型交给下面的 ① 去查
    out[m[1]] = value;
  }
  return out;
}

const literals = literalEnvFromSqaml(yaml);

// ── ① s.yaml 引用的环境变量 ────────────────────────────────────────
console.log('① s.yaml 引用的环境变量\n');

const envFile = valueOf(process.argv.slice(2), '--env-file');
const { env, count, fromFile } = loadEnv(envFile);

// ⚠️ 忘了 `--env-file .env.prod` 时，本脚本只读当前 shell —— 而 shell 里通常一个变量都没有，
//    于是**每一个引用都报「根本没有」**。实测形态：漏掉这个参数 → 20 条致命，
//    而 .env.prod 本身是全对的（值一个不少）。那份报告读起来像「我的配置怎么全空了」，
//    真相却是**用法问题**。所以这里主动喊一声，而且要喊在那一长串 ✗ **之前** ——
//    喊在后面就等于没喊，人已经先按「配置全空」去排查了。
const defaultEnvFile = resolve(REPO, '.env.prod');
const forgotEnvFile = !fromFile && existsSync(defaultEnvFile);

console.log(fromFile
  ? `   环境来源：${envFile}（${count} 个键）+ 当前 shell`
  : '   环境来源：仅当前 shell（没给 --env-file）');
if (forgotEnvFile) {
  console.log('\n  ⚠️  仓库根目录有 .env.prod，但**这次没读它** —— 下面凡是「根本没有」的，');
  console.log('      都可能只是没读文件，不代表你没配。要核对 .env.prod 请加参数重跑：');
  console.log('        node serverless/scripts/deploy-check.mjs --env-file .env.prod');
  console.log('      （反之，若你确实只想验当前 shell 的环境，无视本提示即可）');
}
console.log(`\n   s.yaml 里另有 ${Object.keys(literals).length} 个写死的值，一并算进平台配置\n`);

const PLACEHOLDER = /^<.*>$/;
const seen = new Set();
let refOk = 0;
// 「有交代」不等于「有值」。留空是**合法的配置决策**（本项目用 @optional 标它），
// 但它和「配好了」在后果上完全不同：那一项对应的功能会是**降级但可用**的状态
// （例：AI_PRICE_* 空 → 成本看板显示「未知」而不是金额）。
// ⚠️ 所以结论行必须把这两个数**分开报** —— 只报「31 个全部到位」会让只读结论的人
// 以为万事俱备，而实际上有 8 项是空的。这正是本项目最怕的那类「判据让人得出错结论」。
let blankOk = 0;

/** 把「带回落值的写法」拼出来。做成函数是为了别在模板串里嵌 `${}`（读起来太绕）。 */
const withFallback = (name) => "${env('" + name + "', '')}";

for (const r of refs) {
  const key = `${r.name}|${r.optional}|${r.hasFallback}`;
  if (seen.has(key)) continue;
  seen.add(key);

  const raw = env[r.name];
  const absent = raw === undefined;
  const value = String(raw ?? '').trim();
  // ⚠️ 对 s CLI 而言「值为空」与「变量不存在」是**同一个结果**（都抛 not found），
  //    所以这两件事必须合起来判 —— 分开写两个分支再各自对齐口径，迟早漂掉。
  const blank = absent || value === '';

  if (PLACEHOLDER.test(value)) {
    bad(`${r.name}（s.yaml:${r.line}）还是模板占位符「${value}」—— 值没填真`);
  } else if (blank && r.optional && r.hasFallback) {
    ok(`${r.name}：留空（该行有回落值，s 会用它）`);
    refOk += 1;
    blankOk += 1;
  } else if (blank && r.optional) {
    bad(
      `${r.name}（s.yaml:${r.line}）标了 @optional，但**没有回落值** —— `
      + 's 把「空值」和「变量不存在」看成同一件事，整个部署会失败在'
      + `\n      RuntimeError: env('${r.name}') not found`
      + `\n      光标 @optional 不构成「允许留空」。写成 ${withFallback(r.name)} 才算。`,
    );
  } else if (blank) {
    bad(
      `${r.name}（s.yaml:${r.line}）在环境里取不到值 → s 会抛 `
      + `env('${r.name}') not found，**整个部署失败**（不是「函数里少个变量」那么轻）。`
      + `\n      确实不需要它？写成 ${withFallback(r.name)} 并在行尾加 \`# @optional\`。`,
    );
  } else {
    ok(`${r.name}：已提供（${value.length} 字符）`);
    refOk += 1;
  }
}

// ── ② 反过来查：.env.prod 配了，但实际下发的不是这个值 ─────────────
console.log('\n② 反过来查：.env.prod 里配了、但实际下发的可能不是这个值\n');

if (!fromFile) {
  console.log('   （没给 --env-file，跳过 —— 当前 shell 里本来就有很多无关变量）');
} else {
  const referenced = new Set(refs.map((r) => r.name));
  // 只挑「一看就是本项目的」名字，免得把 shell 里无关的变量报成问题。
  const PROJECTISH = /^(PG|PG_|OSS_|ARK_|AI_|IMAGE_|CORS_|SEED_|NODE_ENV)/;
  const orphans = Object.keys(env)
    .filter((k) => PROJECTISH.test(k) && !referenced.has(k))
    // 这几个是**本机运维专用、刻意不下发到函数**的，不算漏：
    //   · `PG_OPS_USER` / `PG_OPS_PASSWORD` —— 管理员身份，只给迁移/建角色用（更不能上云）；
    //   · `PGHOST_EXTERNAL` —— RDS 的**外网端点**，只给「在 VPC 外跑」的本机脚本用。
    //     函数侧要的是**内网端点**（`PGHOST`）；把外网端点下发过去等于绕开 VPC。
    .filter((k) => !['PG_OPS_USER', 'PG_OPS_PASSWORD', 'PGHOST_EXTERNAL'].includes(k));

  // 必须分成三类，因为**处置完全不同**：
  //   · 真孤儿        —— s.yaml 里既没引用也没写死 → 值确实没上传（警告，原本就对）
  //   · 被写死且一致  —— 值是对的，但**改 .env.prod 不会生效**（要改 s.yaml）
  //   · 被写死且不一致 —— **最危险的一类**：你在 .env.prod 里写了一个值、看起来生效了，
  //       平台拿到的却是 s.yaml 里另一个值。上线后的表现是「配了却毫无反应」，
  //       而排查的人会先怀疑代码没部署 / 缓存 / 环境变量没生效 —— 那条线索是假的。
  //       （实测这一类比比皆是：s.yaml 写死 PGSSLMODE=require，而 .env.prod 写 disable，
  //        真库又不支持 SSL → 函数连不上库。）
  const trulyOrphan = [];
  const shadowSame = [];
  const shadowDiff = [];
  for (const k of orphans) {
    if (!(k in literals)) {
      trulyOrphan.push(k);
      continue;
    }
    const mine = String(env[k] ?? '').trim();
    const theirs = String(literals[k] ?? '').trim();
    if (mine === theirs) shadowSame.push(k);
    else shadowDiff.push({ k, mine, theirs });
  }

  for (const k of trulyOrphan) {
    // ⚠️ 值为空的**不算**「值丢了」：显式留空是正常配置（本项目用 `@optional` 标它，
    //    例如「共享 KV 还没申请，先跑 memory」）。不区分的话这条检查会持续误报 ——
    //    而一直误报的检查等于不存在。
    //    ⚠️ 只在**这一处**放过空值：下面「写死」那两类照旧 ——「s.yaml 写死 X 而
    //    .env.prod 里为空」正是要报的不一致（你以为留空 = 不设置，平台却会用那个字面量）。
    if (String(env[k] ?? '').trim() === '') continue;
    warn(`${k} 配了值，但 s.yaml 里既没引用、也没写死 —— 这个值**不会被上传**`);
  }

  for (const { k, mine, theirs } of shadowDiff) {
    bad(
      `${k} **两边不一致**：s.yaml 里写死的是 \`${theirs}\`，而 .env.prod 里写的是 \`${mine}\`。`
      + `\n      s.yaml 那一行是字面量、没有引用 ${k}，所以平台拿到的是 \`${theirs}\` ——`
      + `\n      **你在 .env.prod 里写的 \`${mine}\` 不会生效**，但它看起来像是生效的那个。`
      + `\n      修法：把 s.yaml 那一行改成 ${k}: \${env('${k}')}，让 .env.prod 成为唯一真值；`
      + '\n      或者反过来把 s.yaml 的值改成与 .env.prod 一致（但那就仍是两份真值）。',
    );
  }

  if (shadowSame.length > 0) {
    ok(`${shadowSame.length} 个键在 s.yaml 里写死，且与 .env.prod 一致：${shadowSame.join(' · ')}`);
    console.log('      （值是对的。但要改它们时**必须改 s.yaml** —— 改 .env.prod 不会生效）');
  }

  const orphanWithValue = trulyOrphan.filter((k) => String(env[k] ?? '').trim() !== '');
  if (orphans.length === 0 || orphanWithValue.length === 0) {
    ok('没有孤儿变量：环境里配的项目变量都被 s.yaml 引用了（显式留空的不算孤儿）');
  }
}

// ── ③ 暂存目录 ────────────────────────────────────────────────────
console.log('\n③ 暂存目录（code: 指向的那两个）\n');

const codePaths = [...yaml.matchAll(/^\s*code:\s*(\S+)\s*$/gm)].map((m) => m[1]);
if (codePaths.length === 0) {
  bad('s.yaml 里一个 code: 都没解析出来 —— 格式不对，或正则没跟上');
}
for (const p of codePaths) {
  if (existsSync(resolve(REPO, p))) {
    ok(`${p}`);
  } else {
    bad(`${p} 不存在 —— 先跑 \`node serverless/deploy-prepare.mjs\`（它会构造暂存目录）`);
  }
}

// ── ④ 两个服务各自的配置自检（复用，不重写）────────────────────────
console.log('\n④ 两个服务自己的配置自检（按平台口径）\n');

// 平台上的 NODE_ENV 由 s.yaml 写死成 production，直接跟着它走，
// 否则「生产才拦」的那些判据一条都不会触发 —— 体检就成了走过场。
const platformEnv = { ...env, ...literals };

const ds = validateDataService(platformEnv);
if (ds.problems.length === 0) {
  ok(`数据服务：无致命问题（${ds.warnings.length} 条警告）`);
} else {
  ds.problems.forEach((p) => bad(`数据服务：${p}`));
}
ds.warnings.forEach((w) => warn(`数据服务（警告）：${w}`));

/**
 * 应用角色这一条**不是**新规则，是把一条已有判据的发现时机提前。
 *
 * 「应用账号不能是超管、不能带 BYPASSRLS」的**权威判据在 `db.js` 的
 * `assertRlsEnforced`** —— 它连上库查 `pg_roles`，看行为不看名字，比这里准得多。
 * 但它跑在**函数启动时**，也就是**上传之后**：那时才看到一条
 * 「应用连接用的是超级用户 …」或「角色 xxx 带 BYPASSRLS」，再回头改配置、重新上传。
 *
 * ## 为什么这里可以写死名字（上一版判断错了，这是实测纠正）
 *
 * 上一版用的是名字启发式：`/^(postgres|root|admin)$/` → 拦，
 * `/(admin|superuser|root)/` → 只**提示**。当初的理由是「写死名字等于把
 * `002_rls.sql` 的角色名抄一份」。这个理由不成立，而且后果很糟 ——
 * 2026-09-24 在真 RDS 上实测：管理员账号叫 `easylearn_admin`，名字里带 admin，
 * 所以只吃到一条提示；而它 `rolbypassrls = true`、继承 `pg_rds_superuser` ——
 * **用它连库会让整套多家庭隔离静默失效**。
 * 一条把「隔离失效」降级成提示的检查，其实不如没有。
 *
 * 关键认识：`app_rls` 这个名字**不是**可以随便换的配置，而是**结构事实**：
 *   · `002_rls.sql` 的 `GRANT ... ON ALL TABLES ... TO app_rls` 只授给这个名字；
 *   · `004_credential.sql` 的 `REVOKE INSERT, DELETE ON app_user FROM app_rls` 同理；
 *   · `003_session.sql` 里甚至有一条断言 `has_table_privilege('app_rls', ...)`。
 * 换个名字的后果**不是**「配置照样生效」，而是那个角色一张业务表都读不到。
 * 所以「PGUSER 必须等于 app_rls」不是一份副本，它本身就是判据。
 *
 * 仍然防了一手漂移：下面先去 sql 文件里确认这两个名字**确实**是迁移建出来的。
 * 哪天有人改了角色名，这里会红 —— 而不是安静地继续认旧名字。
 */
const APP_ROLE = 'app_rls';
const AUTH_ROLE = 'app_auth';
const sqlText = (f) => readFileSync(resolve(REPO, 'serverless/data-service/sql', f), 'utf8');
const declares = (f, role) => new RegExp(`CREATE ROLE\\s+${role}\\b`).test(sqlText(f));

if (!declares('002_rls.sql', APP_ROLE)) {
  bad(`sql/002_rls.sql 里找不到 CREATE ROLE ${APP_ROLE} —— 角色名改过了？本脚本要跟着改`);
}
if (!declares('003_session.sql', AUTH_ROLE)) {
  bad(`sql/003_session.sql 里找不到 CREATE ROLE ${AUTH_ROLE} —— 角色名改过了？本脚本要跟着改`);
}

const roleChecks = [
  { key: 'PGUSER', want: APP_ROLE, why: '业务表的四件套权限只授给了它（002_rls.sql）' },
  {
    key: 'PG_AUTH_USER',
    want: AUTH_ROLE,
    why: '它是唯一带 BYPASSRLS、且被限制在三张账号表上的角色（003_session.sql）',
  },
];
for (const { key, want, why } of roleChecks) {
  const got = String(platformEnv[key] ?? '').trim();
  if (got === '') continue; // 空值由 ① 负责报，这里不重复
  if (got === want) {
    ok(`${key}=${got}（正确）`);
  } else {
    bad(
      `${key}=${got} —— 但只能是 ${want}：${why}。\n`
      + '      用别的角色有两种后果，一种不报错、一种报得很晚：\n'
      + '        · 它是超管或带 BYPASSRLS（例如 RDS 的 xxx_admin）→ **整套 RLS 静默失效**，\n'
      + '          一个家庭能查到另一个家庭的行，且没有任何报错；\n'
      + '        · 它是普通角色但没被 GRANT 过 → 每个查询都 permission denied。\n'
      + '      （函数启动自检会拦住第一种，但那是上传之后 —— 别等它来告诉你。）',
    );
  }
}

// ⚠️ 网关这份 validateConfig 只返回**一个数组**，而数据服务那份返回 `{ problems, warnings }`。
//    两边形状不一样，别按同一个形状去解 —— 解错了会抛 TypeError，而这行在体检脚本里，
//    看起来像「体检脚本自己坏了」，很容易被当成误报而整个跳过。
try {
  const aiProblems = validateAiGateway(loadConfig(platformEnv));
  if (aiProblems.length === 0) {
    ok('AI 网关：无致命问题');
  } else {
    aiProblems.forEach((p) => bad(`AI 网关：${p}`));
  }
} catch (e) {
  // loadConfig 自己抛，说明连解析都过不去（比如厂商名认不出来）。
  bad(`AI 网关：配置解析就失败了 —— ${e.message}`);
}

// ── ⑤ 跨函数一致性 ────────────────────────────────────────────────
console.log('\n⑤ 跨函数一致性\n');

const secretRefs = refs.filter((r) => r.name === 'AI_SESSION_SECRET');
if (secretRefs.length === 2) {
  ok("两个函数引用的是**同一个** AI_SESSION_SECRET —— 结构上不可能分叉");
} else {
  bad(`AI_SESSION_SECRET 被引用 ${secretRefs.length} 次（应为 2：两个函数各一次）`
      + ' —— 有人把它拆成两份的话，票会在一个服务上签、在另一个服务上验不过（401）');
}

// ── ⑥ VPC ↔ 数据库端点 ────────────────────────────────────────────
//
// 为什么单列一节：**「配了 VPC」≠「走了内网」**。
// 2026-09-24 实测过一次完整的假象：`s deploy` 不报错、`/health` 是 200、
// 登录也能成功 —— 但 `app_auth` 的连接来自**会变的公网 IP**（FC 共享出口），
// 也就是说 VPC 那张 ENI 一次都没用上。放开它的是 RDS 白名单里某条过宽的规则；
// 等哪天把白名单收窄成「交换机网段」，函数就会**静默断掉**（现象是登录 500，
// 看起来像 VPC 配错了）。真因只是 `PGHOST` 填的是**外网地址**。
//
// ⚠️ 这里用 DNS 解析来判断 —— 因为内外网是**两个不同的域名**（实例 ID 尾部差两个
//    字符），能不能走内网**完全取决于 `PGHOST` 解析出的地址**，与配不配 VPC 无关。
console.log('\n⑥ VPC 与数据库端点的搭配（配了 VPC ≠ 走了内网）\n');

// 「有没有配 VPC」用 s.yaml 的**结构事实**判断（跳过整行注释 —— 那一节里
// 就有解释性的 `vpcConfig` 字样）。不在这里另抄一份开关：抄一份迟早不一致。
const hasVpcBlock = yaml
  .split(/\r?\n/)
  .some((l) => !/^\s*#/.test(l) && /^\s+vpcConfig:\s*$/.test(l));

const pgHost = String(env.PGHOST ?? '').trim();
const isPrivateIp = (ip) => /^10\./.test(ip)
  || /^192\.168\./.test(ip)
  || /^172\.(1[6-9]|2\d|3[01])\./.test(ip);

if (!fromFile || pgHost === '') {
  console.log('   （没给 --env-file 或 PGHOST 为空 —— 跳过）');
} else {
  // ⚠️ 必须带超时：体检是上传前的闸门，不能被一次 DNS 卡住。
  const addrs = await Promise.race([
    lookup(pgHost, { all: true }).then((r) => r.map((x) => x.address)).catch(() => null),
    new Promise((r) => { const t = setTimeout(() => r('TIMEOUT'), 5000); t.unref?.(); }),
  ]);

  if (addrs === 'TIMEOUT' || addrs === null) {
    console.log(`   · ${pgHost} 解析不了（离线？）—— 这条检查跳过，别当成通过`);
  } else {
    const priv = addrs.filter(isPrivateIp);
    if (priv.length > 0 && hasVpcBlock) {
      ok(`PGHOST 解析到 ${priv[0]}（私有网段）—— 与 s.yaml 的 vpcConfig 自洽`);
    } else if (priv.length > 0 && !hasVpcBlock) {
      warn(`PGHOST 是**内网地址**（${priv[0]}），但 s.yaml 的数据服务**没有 vpcConfig**`
           + ' → 函数在 VPC 外，**没有通往该网段的路由**，连不上库（现象是登录 500）。'
           + ' 要么配上 vpcConfig，要么把 PGHOST 换回外网地址。');
    } else if (priv.length === 0 && hasVpcBlock) {
      warn(`PGHOST 解析到**公网**地址（${addrs[0]}），但数据服务配了 vpcConfig`
           + ' → **VPC 等于白配**：函数会从 FC 的**共享出口**连库（源 IP 会变），'
           + ' 而不是走内网。要真走内网，把 PGHOST 换成 RDS 的**内网地址** ——'
           + ' 它与外网地址**不是同一个域名**（实例 ID 尾部差两个字符，别当成笔误）。');
    } else {
      console.log(`   · PGHOST 解析到公网地址（${addrs[0]}），且没配 VPC —— 两者自洽，`
                  + '但代价是 RDS 白名单必须放开 FC 的**动态**出口 IP（等于把库敞在公网上）。');
    }
  }

  if (hasVpcBlock) {
    // 说清这条检查的**边界**，免得被当成「VPC 通了」的证据。
    console.log('   📌 这只证明**端点配对了**，不证明**真的走了内网** —— 后者只能在');
    console.log('      部署之后从**库侧**看：node serverless/data-service/scripts/probe-vpc-path.mjs');
    console.log('      （⚠️ 它必须用**管理员**身份读，否则看不到 app_auth 的行 —— 假阴性）');
  }
}

// ── 结论 ──────────────────────────────────────────────────────────
console.log('\n═══════════════════════════════════════════════════════════════');
if (problems.length === 0) {
  const filledOk = refOk - blankOk;
  console.log(`  可以上传 —— ${refOk} 个引用全部有交代：${filledOk} 个有值 · ${blankOk} 个显式留空 · 警告 ${warnings.length} 条`);
  if (blankOk > 0) {
    console.log(`     ⚠️ 那 ${blankOk} 个「显式留空」不等于「已配好」：它们对应的功能会是`);
    console.log('        **降级但可用**的状态（例：AI_PRICE_* 空 → 成本看板显示「未知」而非金额）。');
    console.log('        上面标「显式留空」的那几行值得扫一眼：是真不需要，还是只是忘了填。');
  }
  // ⚠️ 这里**必须**指向 run-s.mjs，不能是手写的 `set -a && . ./.env.prod && set +a && s deploy`：
  //    后者漏掉「清代理」，在带本地代理的机器上（本机就是）会得到 `status code 400`，
  //    而 s 不打印响应体 —— 从那句话看不出是代理，看着像配置写错了。
  console.log('  下一步：node serverless/scripts/run-s.mjs deploy');
  console.log('═══════════════════════════════════════════════════════════════');
  process.exit(0);
}
console.log(`  ✗ ${problems.length} 个致命问题（警告 ${warnings.length} 条）—— 先修再上传。`);
console.log('    带着这些上传不会立刻炸：函数能起来、健康检查 200，');
console.log('    问题会在第一个用到那个变量的请求上以一种看不出原因的样子出现。');
if (forgotEnvFile) {
  console.log('');
  console.log('  ⚠️  先排除一种可能：**本次没读 .env.prod**（漏了 --env-file）。');
  console.log('      这类「配置全空」的报告，多数情况加一个参数就消失了 ——');
  console.log('        node serverless/scripts/deploy-check.mjs --env-file .env.prod');
}
console.log('═══════════════════════════════════════════════════════════════');
process.exit(1);
