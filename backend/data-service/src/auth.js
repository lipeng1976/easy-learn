import { verifySessionToken } from '../../shared/token.js';
import { badRequest, forbidden, unauthorized } from '../../shared/errors.js';
import { withAuthConnection } from './db.js';
import { assertSessionActive } from './session.js';

/**
 * 鉴权中间件：从请求里解出**唯一的**身份来源。
 *
 * R1 的落地：身份只由 token 给出，**客户端自报的 studentId / role 一律不采用**。
 * 之前客户端靠 `X-Student-Id` 声明自己是谁，那个值可以随手改成别人的学号；
 * 数据服务上云后，那个头连读都不读。
 *
 * 四点刻意的设计：
 *  ① **`requireRole: true`** —— 数据服务要拿 role 决定可见集合，
 *     少了它就只能靠猜，而猜错的后果是越权。缺 role 的 token 判 `token_invalid`
 *     而不是 `unauthorized`：客户端正确的动作是**重新登录拿到带 role 的新 token**。
 *  ② 取 `Authorization: Bearer`，与 ai-gateway 完全一致 ——
 *     两个服务对同一个客户端应该只有一种带凭证的方式。
 *  ③ **`requireSession: true` + 查一次会话表**（S2）—— 见下。
 *  ④ 不在这里查业务数据。「身份是谁」来自 token 与会话表，
 *     「能看到哪些学生」才是查库的结果（见 db.js 的 withRequestContext）。
 *
 * ## 为什么验签之后还要查库
 *
 * 签名只能证明「这串字节是我签的」，证明不了「这个凭证还能用」——
 * 用户登出、改密、丢手机，都要求在**服务端**把凭证作废，而签名校验看不见这些。
 * 所以这里多一次主键查询。它是「可吊销」唯一诚实的价格：
 * 省掉它，S2 加的那张会话表就只是个装饰。
 *
 * 查询用**鉴权连接**而不是应用连接：此时还没有身份，
 * 而 app_rls 的 policy 依赖 `current_setting('app.user_id')`，读不到任何行。
 */
export async function resolveIdentity(headers, { secret, authPool, now = Date.now() }) {
  const raw = headers?.authorization ?? headers?.Authorization ?? '';
  const token = String(raw).startsWith('Bearer ') ? String(raw).slice(7).trim() : '';

  if (token === '') {
    throw unauthorized('需要提供会话 token（Authorization: Bearer …）');
  }

  const { subject, role, sessionId } = verifySessionToken(token, {
    secret,
    now,
    requireRole: true,
    requireSession: true,
  });

  await withAuthConnection(authPool, (client) => assertSessionActive(client, sessionId, { now }));

  return { userId: subject, role, sessionId };
}

/**
 * 把一个筛选参数收敛进「我能看的集合」。
 *
 * 客户端可以传 `studentId` 做筛选（家长在两个孩子之间切换），
 * 但服务端**不会因此相信它** —— 参数只是用来在可见集合里再挑一个。
 * 结果不在集合里就明确报 403，而不是静默返回空列表：
 * 前者是「你越权了」，后者会被当成「这孩子还没写作业」，把问题藏起来。
 */
export function narrowToVisible(visibleStudents, requested) {
  if (requested === undefined || requested === null || requested === '') {
    return { students: visibleStudents, requested: undefined };
  }
  const one = String(requested);
  if (!visibleStudents.includes(one)) {
    return { students: [], requested: one, denied: true };
  }
  return { students: [one], requested: one };
}

/**
 * 写操作的归属校验：这条数据到底能记到谁头上。
 *
 * **这是最容易写错的一处**：客户端会兴高采烈地传 `studentId`，
 * 而服务端如果直接拿它入库，就等于「谁都能给别人的孩子写作业、记积分」。
 * 所以 rules 是：**写入的 studentId 必须落在调用者自己的可见集合里**，
 * 不在就 403，连「静默改写成一个合法值」都不做 —— 那样会把越权请求
 * 伪装成一次成功操作，问题要等到对账时才发现。
 */
export function requireVisibleStudent(visibleStudents, requested, what = '该学生') {
  const one = String(requested ?? '').trim();
  if (one === '') throw badRequest('缺少 studentId');
  if (!visibleStudents.includes(one)) throw forbidden(`无权访问${what}的数据`);
  return one;
}
