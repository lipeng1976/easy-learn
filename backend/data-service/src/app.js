/**
 * 只做组装：把 HTTP 请求交给 router，把异常统一转成响应。
 * 业务逻辑一行都不放这里。
 */

import { sendNoContent, sendError } from '../../shared/http.js';
import { handleRequest } from './router.js';

export function createApp({ config }) {
  return async function handler(req, res) {
    try {
      if (req.method === 'OPTIONS') return sendNoContent(res);
      await handleRequest(req, res, { config });
    } catch (err) {
      // 未预期异常必须留日志，否则就是「静默失败」。
      sendError(res, err, console);
    }
  };
}
