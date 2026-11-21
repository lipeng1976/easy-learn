# 文档索引

| 文档 | 什么时候读 |
|---|---|
| [`../README.md`](../README.md) | 第一次接手：技术栈、启动、环境变量、建库 |
| [`architecture.md`](architecture.md) | 要改调用链、加服务、动鉴权之前 |
| [`environment.md`](environment.md) | 配环境、密钥轮换、上生产之前 |
| [`database.md`](database.md) | **动任何路径 / 附件 / 表结构之前**（★） |
| [`../db/README.md`](../db/README.md) | 建库、迁移、RLS 排障 |
| [`source-index.md`](source-index.md) | 从原仓库迁入业务代码时 |
| [`handover.md`](handover.md) | 交接当天必读：坑、纪律、红线 |

## 一句话定位

这个包是**工程基线**：把目录规范、配置规范、路径规范、DDL 终态、启动方式固定下来。
业务源码仍在原仓库继续开发，迁入顺序见 `source-index.md`。

## 三条不可协商的规矩

1. **密钥只在 `.env`**：代码、SQL、文档里都不出现密钥字面量。模板只有 `.env.example`。
2. **数据库不存绝对路径**：所有路径列是 `rel_path` 域；根目录只在 `STORAGE_ROOT` 配置。
3. **一个语义只许一处定义**：端点、错误码、状态词、路径规则、env 读取各只有一个文件。

## 验证入口

```bash
npm run verify          # 语法 / 密钥 / 绝对路径 / 文件完整性
npm run check:env       # 环境变量自检
cd frontend && flutter test
```

> 验证纪律见 `handover.md`：**「全绿」本身不是判据**，每修一个 bug 都要能证明
> 「还原改动后恰好那几条变红、反面仍然绿」。
