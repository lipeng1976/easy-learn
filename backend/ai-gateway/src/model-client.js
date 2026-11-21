import { ArkModelClient } from './ark.js';
import { MockModelClient } from './mock-model.js';

/**
 * 装配模型客户端。
 *
 * `ark` 是默认且线上一律用它；`mock` 要显式配置才生效，
 * 避免哪次环境变量抄漏了就把假数据发给了用户。
 */
export function createModelClient(config, options = {}) {
  if (config.modelClient === 'mock') {
    return new MockModelClient({ config, ...options });
  }
  return new ArkModelClient({ config, ...options });
}
