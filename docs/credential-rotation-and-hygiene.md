# 云凭证轮换 + 白名单收窄 · 作战清单（2026-09-30）

> 触发：`stage-archive-aliyun.md` §4.3 的三条云侧卫生遗留。
> ⚠️ **状态：暂缓（虫子 09-30 二次拍板）** —— 现在是**开发阶段**，旧 AccessKey 能用就用，
> 轮换的收益（消除泄漏风险）要等**生产上线前**才真正兑现。**上线前按本清单执行一遍即可。**
> 当前唯一生效的口径：**能用就继续用，不轮换、不额外收窄。**
>
> ⚠️ 本清单里**所有「在控制台点按钮」的动作，都需要你本人登录对应控制台操作**，
> 我这边只负责：给精确步骤 · 在你操作后**回填本地文件** · **跑 probe 验证轮换后能连上**。
> 我不会替你改云控制台，也不该有人替 —— 那正是凭证要轮换的原因。

---

## 0. 先说结论：哪些要轮、哪些不用

| 类别 | 具体凭证 | 现状 | 要不要轮 | 轮换动作在哪 |
|---|---|---|---|---|
| 阿里云账号级 | `s` 工具的 default AccessKey（`~/.s/access.yaml`） | 进过对话、用于部署 | ✅ **必轮** | 阿里云 RAM 控制台 → 重发 AccessKey |
| 阿里云账号级 | OSS `OSS_ACCESS_KEY_ID/SECRET`（.env.prod） | 进过对话 | ✅ **必轮** | 同上（或独立 OSS RAM 子账号） |
| RDS 密码 | `PGPASSWORD`（app_rls）· `PG_AUTH_PASSWORD`（app_auth）· `PG_OPS_PASSWORD`（easylearn_admin） | 进过对话 | ✅ **必轮** | RDS 控制台 → 重置账号密码 |
| 百炼 | `BAILIAN_API_KEY` | 进过对话，换方舟后已不用但**还在文件里** | ✅ 轮（或直接删） | 百炼控制台 → 重置 / 删除 |
| 方舟 | `ARK_API_KEY` | 进过对话、当前在用 | ✅ **必轮** | 火山方舟控制台 → 重置 API Key |
| 火山账号级 | `VOLC_ACCESS_KEY_ID/SECRET`（.env.volc.local） | 进过对话 | ✅ **必轮** | 火山访问控制 → 重发 AccessKey |
| 自签会话密钥 | `AI_SESSION_SECRET` · `AI_KV_TOKEN` · `AI_METRICS_TOKEN` | 本地生成的随机串 | ✅ 轮（本地重生成即可，无控制台） | 我这边直接重新生成 |
| 其他 | `AI_PRICE_*` / `ARK_PRICE_*` / `BAILIAN_PRICE_*` | 价格常量，非秘密 | ❌ 不用 | — |

---

## 1. 阿里云 AccessKey 轮换（`~/.s/access.yaml` 的 default）

**这一步动的是 `s` 工具部署用的那个 AccessKey。**

1. 登录 [阿里云 RAM 控制台](https://ram.console.aliyun.com/users/)（用主账号）。
2. 找到当前 `default` 对应的 RAM 用户（名字在 `~/.s/access.yaml` 的注释里，或问我要）。
3. 该用户 → **认证管理 → 创建 AccessKey**（⚠️ 先别删旧的，等新 key 验证通过再删）。
4. 记下新的 `AccessKey ID` 和 `AccessKey Secret`，**发给我**（我会回填到 `~/.s/access.yaml`，且不写进任何日志/文档）。
5. 新 key 验证通过后，回到控制台**删除旧的 AccessKey**。

⚠️ 顺带一条（§4.3 第 3 条）：当前 RAM 用户带 **`AliyunRAMFullAccess`**，权限过大。
轮换时可以**顺手收窄**：把这个 FullAccess 策略换成一个「只够部署」的自定义策略
（`fc:CreateService/UpdateService`、`fc:CreateFunction/UpdateFunction`、`oss:PutObject` 等最小集合）。
但这一步**与轮换解耦**，可以今天只轮 key、权限收窄另起一轮做，避免一次动太多。

---

## 2. OSS AccessKey 轮换（.env.prod 的 OSS_*）

- 现状：`.env.prod` 里 `OSS_ACCESS_KEY_ID` / `OSS_ACCESS_KEY_SECRET`。
- 若与 §1 是**同一个 RAM 用户**，则 §1 轮换后这里跟着改同一对新 key 即可。
- 若 OSS 用的是**独立子账号**（按 `release-guide.md:927` 建议「只授该桶 PutObject/GetObject 的子账号」），则去那个子账号重发 key。
- 回填位置：`.env.prod` 的 `OSS_ACCESS_KEY_ID=` / `OSS_ACCESS_KEY_SECRET=`。

---

## 3. RDS 三个角色密码轮换（.env.prod 的 PG*_PASSWORD）

三个数据库角色，都在同一个 RDS 实例 `pgm-bp18o4i0278o6p9u` 上：

| 变量 | 角色 | 用途 |
|---|---|---|
| `PG_OPS_PASSWORD` | `easylearn_admin` | 迁移/对账用的管理员（`rolbypassrls`，**绝不能上函数**） |
| `PGPASSWORD` | `app_rls` | 业务读写的 RLS 受限角色 |
| `PG_AUTH_PASSWORD` | `app_auth` | 认证端点用的角色 |

1. 登录 [阿里云 RDS 控制台](https://rdsnext.console.aliyun.com/) → 华东1（杭州）→ 实例 `pgm-bp18o4i0278o6p9u`。
2. **账号管理** → 逐个角色**重置密码**（三个都要换新密码）。
3. 新密码发给我，回填到 `.env.prod` 的 `PGPASSWORD=` / `PG_AUTH_PASSWORD=` / `PG_OPS_PASSWORD=`。
4. ⚠️ 改完必须**重新部署两个函数**（数据服务 + AI 网关），否则函数里跑的还是旧密码、连库会失败。

---

## 4. 百炼 `BAILIAN_API_KEY`（已不用，二选一）

换方舟后百炼已经不用了，但 key 还躺在 `.env.prod` 里。

- **方案 A（推荐）**：去百炼控制台**删除/禁用**这个 key，然后在 `.env.prod` 里把 `BAILIAN_API_KEY=` 清空（或整组 `BAILIAN_*` 留空，反正有方舟回退）。
- **方案 B**：保留但重置 key。

---

## 5. 方舟 `ARK_API_KEY` 轮换（.env.prod / .env.volc.local / ai-gateway/.env.local）

当前在用的模型 key，必轮。

1. 登录 [火山方舟控制台](https://console.volcengine.com/ark)。
2. API Key 管理 → **重置/新建**一个 key。
3. 新 key 发给我，回填三处（三份文件里都有 `ARK_API_KEY`）：
   - `.env.prod`
   - `.env.volc.local`
   - `serverless/ai-gateway/.env.local`
4. ⚠️ 回填后**重新部署** AI 网关，否则函数用旧 key 调方舟会 401。

---

## 6. 火山 AccessKey 轮换（.env.volc.local 的 VOLC_*）

1. 登录 [火山访问控制](https://console.volcengine.com/iam/)。
2. 重发 `VOLC_ACCESS_KEY_ID` / `VOLC_SECRET_ACCESS_KEY`。
3. 新值发我，回填 `.env.volc.local`。

---

## 7. 自签会话密钥（我这边直接重生成，无需控制台）

`AI_SESSION_SECRET`（两函数共用一把、≥32 字符）、`AI_KV_TOKEN`、`AI_METRICS_TOKEN`
都是本地生成的随机串，没进过云控制台，我直接重新生成回填 `.env.prod` 即可，
你无需操作。但改完同样要**重新部署**让新值生效。

---

## 8. RDS 白名单收窄（§4.3 第 1 条）

现状：白名单没收窄，**公网可连**（任何人拿到密码就能从公网打库）。

**目标**：白名单只放行两类来源 ——
1. **函数走 VPC 内网连库**的那段：交换机网段 CIDR（一个固定值，见 `release-guide.md:783`）。
2. **跑迁移/对账脚本的那台机器**的出口 IP（本机）。

**操作**（RDS 控制台 → 白名单）：
1. 记下本机当前出口 IP（我可以帮你跑 `curl ifconfig.me` 拿）。
2. RDS 白名单里**删掉 `0.0.0.0/0` 或 `%` 这类全放行**条目。
3. 新增：① 交换机网段 CIDR（查 `FC_VSWITCH_ID` 对应的网段）② 本机出口 IP。
4. ⚠️ 收窄后**立刻验证**：跑 `node serverless/data-service/scripts/cloud-accounts.mjs` 能连上库（走的是 `PGHOST_EXTERNAL` 公网端点，验证的是本机 IP 已放行）；再验函数侧（走 `PGHOST` 内网）连库正常。

⚠️ **顺序要小心**：先确认函数走 VPC 内网（`PGHOST` 是内网地址 `172.x`），再收窄白名单，
否则收窄后函数连不上库。

---

## 9. 我这边要做的（等你的控制台操作）

你每完成一步、把新值发我，我依次：

1. 回填 `.env.prod` / `.env.volc.local` / `.env.local` / `~/.s/access.yaml`。
2. 重新生成自签密钥（§7）。
3. 跑验证脚本（`cloud-accounts.mjs` 连库、`probe-oss.mjs` 连 OSS、方舟 key 探活）。
4. 全绿后，**重新部署**数据服务 + AI 网关，让云端函数拿到新凭证。
5. 同步更新 `stage-archive-aliyun.md` §4.3（把三条遗留划掉）和 `release-guide.md` 的 checklist。

---

## 10. 安全纪律（本轮必须守住）

- **新凭证绝不再进对话明文**：你发我时可以用「ID 前 4 位 + 后 4 位」的口径让我确认，完整值我用别的方式（比如你直接改文件、或走加密通道）交接。
- **回填后**：所有 `.bak` 旧备份文件（`.env.prod.bak-*`）里还存着旧密码，轮换完成后应**删除或同样更新**（否则等于留了旧钥匙）。
- **部署日志**：`s` 会明文回显环境变量，部署时**不要 `> 日志`**（记忆里的 9 处密钥落盘教训）。
