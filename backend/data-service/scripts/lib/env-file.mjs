import { readFileSync } from 'node:fs';

/**
 * 读一个 `KEY=VALUE` 环境变量文件。
 *
 * ## 为什么不用 dotenv
 *
 * 这份服务的运行时依赖只有 `pg` 一个，而这里要做的事小到不值得为它加一个包：
 * **平台上的环境变量由控制台注入**，这个文件只在「上线前自查 / 迁移 / 本机试跑」
 * 三种场合用得到。
 *
 * ## 三件容易出错的事
 *
 * 1. `#` 开头的整行注释（值里出现 `#` 不当作注释 —— 口令里带 `#` 是常事）。
 * 2. 两侧的引号（`KEY="a b"` 要读成 `a b`）。
 * 3. **值里带 `=`**（连接串、base64 都会带）→ 只在**第一个** `=` 处切。
 */
export function parseEnvFile(path) {
  const out = {};
  for (const raw of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (line === '' || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"'))
        || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    out[key] = value;
  }
  return out;
}

/**
 * 合并 `process.env` 与（可选的）环境变量文件，**文件优先**。
 *
 * 文件优先的理由：给了 `--env-file .env.prod` 的时候，人想查的就是
 * 「按这份生产配置跑会怎样」；让 shell 里残留的同名变量盖掉它，
 * 得到的是第三种谁也没预期的组合。
 */
export function loadEnv(file) {
  if (!file) return { env: { ...process.env }, count: 0, fromFile: false };
  const parsed = parseEnvFile(file);
  return { env: { ...process.env, ...parsed }, count: Object.keys(parsed).length, fromFile: true };
}

/** 取 `--flag value` 形式的参数值。 */
export function valueOf(args, flag) {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
}

/**
 * 取「**从 VPC 外**连库」该用的主机名。
 *
 * 生产库有两个端点，而且它们**不是同一个域名**（实例 ID 尾部差两个字符）：
 *   · `PGHOST`          —— **内网地址**，函数侧用它（配了 VPC 之后走 ENI）。
 *   · `PGHOST_EXTERNAL` —— **外网地址**，只在 VPC 外跑脚本时用。
 *
 * ⚠️ 内网地址从公网**能解析、但连不上**（2026-09-24 实测：本机解析到
 * `172.21.26.125`，TCP 6.1s 超时；同实例的外网名 322ms 连上）。
 * 所以本机运维脚本**一律用这个函数**取 host，**别直接读 `env.PGHOST`** ——
 * 否则把 `PGHOST` 换成内网地址的那天，它们会**集体静默失效**：
 * 现象是「连不上库」，看着像白名单没放行或库挂了，而真因只是解析到了私网 IP。
 *
 * 没配 `PGHOST_EXTERNAL` 时回落到 `PGHOST`（本机开发栈、单端点场景都走这条）。
 */
export function cloudHost(env) {
  return env.PGHOST_EXTERNAL || env.PGHOST || '127.0.0.1';
}
