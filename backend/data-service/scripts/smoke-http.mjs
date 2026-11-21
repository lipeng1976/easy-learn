#!/usr/bin/env node
/**
 * HTTP 冒烟：验证**真的有 HTTP**这条路是通的。
 *
 * 契约测试是直接调 `createApp({method, pathname, …})` —— 它验的是应用层语义，
 * 跳过了 `node:http` 那一环。这个脚本补上那一环：
 * 起真库 → 起 dev-server 子进程 → 发真请求 → 断言信封与错误码 → 收摊。
 *
 * S2 起它还多验一件事：**走真实的注册流程拿 token**。
 * 契约测试里的 token 是直接造会话行签出来的（那是为了绕开慢哈希），
 * 所以「注册 → 拿 token → 访问 → 登出 → 再访问」这条完整链路
 * 只有在这个脚本里被真正跑过一遍。
 *
 * 跑法：`npm run smoke:http`
 */
import { spawn, spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { issueSessionToken } from '../../shared/token.js';

import { LOCAL_PG, withMigratedDatabase } from '../src/pg-local.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const serviceRoot = path.resolve(here, '..');

const PORT = 8788;
const BASE = `http://127.0.0.1:${PORT}`;
const SECRET = 'smoke-secret-not-for-production';
/** 冒烟每次都在全新的库上跑，所以固定号码不会冲突，且失败时更好认。 */
const PHONE = '13800003001';
const PASSWORD = 'abc123';

const log = (...parts) => process.stdout.write(`[smoke] ${parts.join(' ')}\n`);
const failures = [];

/**
 * 结论只出一次，且**要在收尾之前就出**。
 *
 * 收尾（停 postgres、删数据目录）在 Windows 上偶尔会慢到被外部超时打断；
 * 那时若结论还没打印，一次全过的验收会看起来像失败（退出码是 SIGTERM 而非 0）。
 * 所以 `report()` 在 `finally` 开头先调一次，脚本末尾再兜一次（幂等）。
 */
let reported = false;
function report() {
  if (reported) return;
  reported = true;
  if (failures.length > 0) {
    log(`失败 ${failures.length} 项：${failures.join('、')}`);
    process.exitCode = 1;
  } else {
    log('全部通过');
    process.exitCode = 0;
  }
}

function check(name, cond, detail = '') {
  if (cond) {
    log(`✓ ${name}`);
  } else {
    log(`✗ ${name}${detail ? ` —— ${detail}` : ''}`);
    failures.push(name);
  }
}

/** 发一个请求并解出信封。`body` 为 undefined 时不带请求体（GET）。 */
async function req(method, pathname, { token, body } = {}) {
  const res = await fetch(`${BASE}${pathname}`, {
    method,
    headers: {
      ...(body === undefined ? {} : { 'content-type': 'application/json' }),
      ...(token === undefined ? {} : { authorization: `Bearer ${token}` }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: res.status, json: await res.json() };
}

/**
 * 等 dev-server 起来。
 *
 * 预算给得宽（约 45 秒）：它前面站着两件事 —— PG 冷启动后建立第一条连接，
 * 以及**两次启动自检**（`assertRlsEnforced` + `assertAuthRoleScoped`，
 * 后者要遍历 pg_class 逐表检查鉴权角色的权限）。本机同时还在跑别的事时会更慢。
 *
 * ⚠️ 这个等待是**真的等待**，不是掩盖问题：服务起来后会打一行「监听 http://…」，
 * 超时结束时那一行会出现在日志里 —— 那时才说明卡在别的地方（比如端口被占）。
 */
async function waitForHealth(attempts = 150) {
  for (let i = 0; i < attempts; i += 1) {
    try {
      const res = await fetch(`${BASE}/health`);
      if (res.status === 200) return true;
    } catch {
      // 还没起来，继续等
    }
    await new Promise((resolve) => setTimeout(resolve, 300));
  }
  return false;
}

function killTree(child) {
  if (!child?.pid) return;
  if (process.platform === 'win32') {
    const taskkill = path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'taskkill.exe');
    spawnSync(taskkill, ['/pid', String(child.pid), '/f', '/t'], { stdio: 'ignore' });
  } else {
    child.kill('SIGTERM');
  }
}

await withMigratedDatabase(
  async () => {
    const server = spawn(process.execPath, ['src/dev-server.js'], {
      cwd: serviceRoot,
      stdio: ['ignore', 'pipe', 'pipe'],
      env: {
        ...process.env,
        PORT: String(PORT),
        PGHOST: '127.0.0.1',
        PGPORT: String(LOCAL_PG.port),
        PGDATABASE: LOCAL_PG.database,
        // 两个角色都要给：应用连接跑业务，鉴权连接跑注册与登录。
        // 漏掉 PG_AUTH_* 时 createPool 会退回 PGUSER（= app_rls），
        // 现象是「注册也报手机号已占用」或干脆读不到行 —— 见 db.js 的说明。
        PGUSER: LOCAL_PG.app.user,
        PGPASSWORD: LOCAL_PG.app.password,
        PG_AUTH_USER: LOCAL_PG.auth.user,
        PG_AUTH_PASSWORD: LOCAL_PG.auth.password,
        AI_SESSION_SECRET: SECRET,
      },
    });
    server.stdout.on('data', (b) => process.stdout.write(`[server] ${b}`));
    server.stderr.on('data', (b) => process.stderr.write(`[server] ${b}`));

    try {
      const up = await waitForHealth();
      check('服务起来了并响应 /health', up);
      if (!up) return;

      const health = await req('GET', '/health');
      check('/health 返回统一信封',
        health.json.ok === true && health.json.data.service === 'data-service',
        JSON.stringify(health.json));

      const anonymous = await req('GET', '/data/homework');
      check('无 token 被拒（401 unauthorized）',
        anonymous.status === 401 && anonymous.json.error?.code === 'unauthorized',
        `${anonymous.status} ${JSON.stringify(anonymous.json)}`);

      // S2 最核心的一次行为变化：**S1 那种不带 sid 的 token 现在进不来了**。
      // 不拒的话，签一个不带 sid 的 token 就绕过了整张会话表，S2 等于白做。
      const legacy = issueSessionToken({ secret: SECRET, subject: 'stu_001', role: 'student' });
      const legacyRes = await req('GET', '/data/homework', { token: legacy });
      check('不带 sid 的旧式 token 被拒（token_invalid）',
        legacyRes.status === 401 && legacyRes.json.error?.code === 'token_invalid',
        `${legacyRes.status} ${JSON.stringify(legacyRes.json)}`);

      // ===== 真实注册 → 访问 → 登出 =====
      const reg = await req('POST', '/auth/register', {
        body: { phone: PHONE, password: PASSWORD, role: 'student' },
      });
      check('注册成功并直接返回会话',
        reg.status === 200 && typeof reg.json.data?.token === 'string',
        `${reg.status} ${JSON.stringify(reg.json)}`);
      check('注册响应里不含口令哈希',
        !JSON.stringify(reg.json).includes('scrypt$') && reg.json.data?.user?.passwordHash === undefined,
        JSON.stringify(reg.json.data?.user));

      const token = reg.json.data?.token;

      const me = await req('GET', '/auth/me', { token });
      check('带 token 能读到自己的身份',
        me.status === 200 && me.json.data?.user?.phone === PHONE,
        `${me.status} ${JSON.stringify(me.json)}`);

      const authed = await req('GET', '/data/homework', { token });
      check('带 token 通过鉴权并返回信封',
        authed.status === 200 && authed.json.ok === true && Array.isArray(authed.json.data.items),
        `${authed.status} ${JSON.stringify(authed.json)}`);
      // requestId 的位置与 ai-gateway 一致（router.js:298）：成功在 `meta.requestId`、
      // 失败在 `error.requestId`。两处形状不同是网关既有约定，客户端写日志时取两处。
      check('响应带 requestId（排查用）', typeof authed.json.meta?.requestId === 'string',
        JSON.stringify(authed.json.meta));

      const sessions = await req('GET', '/auth/sessions', { token });
      check('会话列表里能看到当前这台设备',
        sessions.status === 200
          && sessions.json.data?.items?.length === 1
          && sessions.json.data.items[0].current === true,
        JSON.stringify(sessions.json));

      const out = await req('POST', '/auth/logout', { token, body: {} });
      check('登出成功', out.status === 200 && out.json.data?.revoked === true,
        `${out.status} ${JSON.stringify(out.json)}`);

      const afterLogout = await req('GET', '/data/homework', { token });
      check('登出后同一 token 立刻失效（token_invalid）',
        afterLogout.status === 401 && afterLogout.json.error?.code === 'token_invalid',
        `${afterLogout.status} ${JSON.stringify(afterLogout.json)}`);

      const notFound = await req('GET', '/data/nope', { token });
      check('未知端点 404', notFound.status === 404, String(notFound.status));
    } finally {
      report();
      killTree(server);
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  },
  { databaseDir: path.join(serviceRoot, '.pgdata-smoke') },
);

report();
process.exit(process.exitCode ?? 0);
