/**
 * ai-gateway 的错误码与错误构造器入口。
 *
 * ## 这个文件现在是什么
 *
 * 它是 `serverless/shared/errors.js` 的一层**薄壳** —— 真正的内容在共享层。
 *
 * ## 为什么要共享而不是各写一份
 *
 * 错误码是**客户端协议的一部分**。两个服务各定义一份的话，同一个失败会在
 * 两个服务里叫不同的名字，而客户端只认一套 ——
 * 症状是「AI 请求能正确重试，数据请求却莫名重试写操作」这类最难查的分叉。
 *
 * ## 为什么保留这个文件与两个旧名字
 *
 * 网关里有 8 个模块从 `./errors.js` 导入，其中两个用的是旧类名 `GatewayError` /
 * `toGatewayError`。共享层用的是中性名 `ApiError` / `toApiError`
 * （数据服务不是网关，叫 gateway 会让人以为它只该在网关里用）。
 *
 * 这里把旧名字做成别名再导出，于是**调用点一行都不用改**，
 * 而实现只有一份。别名指向同一个类，`instanceof` 照常成立。
 */
export * from '../../shared/errors.js';

export {
  ApiError as GatewayError,
  toApiError as toGatewayError,
} from '../../shared/errors.js';
