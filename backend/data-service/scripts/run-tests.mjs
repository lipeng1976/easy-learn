#!/usr/bin/env node
/**
 * 本机契约测试入口：起真实 PostgreSQL → 跑迁移 → 执行 `node --test` → 停库清目录。
 *
 * ## 为什么需要一个 wrapper，而不是在测试里起库
 *
 * `node:test` 会再 spawn 一层子进程去跑测试文件；而 postgres 是**常驻进程**，
 * 如果由测试进程持有它，运行器会一直等不到句柄释放，最终被超时杀掉 ——
 * 现象是「一条用例都没执行到」。把 PostgreSQL 的生命周期挪到测试**外面**就解决了。
 *
 * 顺带一个好处：测试只认 `TEST_PG_*` 环境变量，所以**同一套测试可以直接指向云 PG**
 * （`npm run test:remote`），不用改一行测试代码。
 */
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { LOCAL_PG, withMigratedDatabase } from '../src/pg-local.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const serviceRoot = path.resolve(here, '..');

const log = (...parts) => process.stderr.write(`[test] ${parts.join(' ')}\n`);

let exitCode = 1;
try {
  exitCode = await withMigratedDatabase(
    (_client, { applied, port, database }) => {
      log('迁移已应用:', applied.join(', '));
      log('启动测试运行器...');
      return new Promise((resolve) => {
        const child = spawn(process.execPath, [
          '--test',
          // **串行**：两个测试文件共用同一个数据库，并行跑时一个文件的种子
          // 会被另一个的 `delete from` 清掉，症状是随机失败的用例。
          '--test-concurrency=1',
          // 显式列文件而不是传目录：本机 Node 的 `node --test test/` 不认目录参数。
          // 加文件时记得同步这一行（漏了就是「写了测试但没跑」）。
          //
          // ⚠️ **这个数组的顺序不起作用** —— node 会把文件参数**按名称排序**后再跑
          // （2026-09-20 实测：传 `z.test.js a.test.js`，实际先跑 a）。
          // 所以真实顺序是字母序：auth → contract → data → db-pool。
          // 下面按「依赖关系」写的顺序只是给人看的，不要据此推断执行顺序。
          //
          // 原本的意图是「让清空表最多的 data.test.js 放最后」，那个意图**从未生效**；
          // 现在仍然能过，是因为每个文件都清掉自己碰过的表、对上一轮残留幂等 ——
          // 也就是说这条约束是靠**各文件自己干净**满足的，不是靠顺序。
          // 真要控顺序就得改文件名，别指望数组下标。
          'test/db-pool.test.js', // 不碰数据库，顺序上无所谓
          'test/ops-scripts.test.js', // 运维脚本取址（cloudHost 单点）；不碰库、不联网
          'test/deploy-entry.test.js', // 线上入口：配置自检 + 事件归一化（也不碰库）
          // 迁移用哪个身份连库（也不碰库）。守的是「PGUSER 一个名字挂两个值」那个矛盾：
          // 迁移要管理员、函数上必须是 app_rls，所以运维身份单独叫 PG_OPS_*。
          'test/migrate-target.test.js',
          // OSS 照片后端：纯单元测试（官方签名算例 + 注入 fetch），不碰库也不碰网络。
          // 它是「云上照片能不能存」的判据 —— 签名算错的表现是线上一律
          // SignatureDoesNotMatch，看着像 AccessKey 填错了。
          'test/oss-imagestore.test.js',
          // 附件类型 / 白名单 / 按类型分别的上限（照片 9 · 音频 3 · 视频 1）
          // + 两条直传与直读的签发路径。纯单元测试，不碰库也不碰网络。
          //
          // ⚠️ 它 2026-10-03 才被加进来 —— 加音视频附件时写了它，但**忘了这一行**，
          //    于是 18 条用例一次都没跑过，而且里面已经有一条断言是漂的
          //    （`signDirectPut` 的地址少了桶名子域，而那正是当天在真机上
          //    栽过的 `NoSuchBucket`）。这正是上面那句「漏了就是『写了测试但没跑』」
          //    的实例：**没跑过的判据与没有判据等价，而且更危险 —— 它看着是绿的**。
          'test/attachments.test.js',
          'test/contract.test.js',
          'test/auth.test.js',
          'test/data.test.js',
          'test/images.test.js', // 照片字节链路（上传 / 落盘 / 按 id 读回）
          'test/chat.test.js', // 聊天（读写 + 三条越权反面：非成员 / 非 active / 无票）
          'test/bootstrap.test.js', // 首屏聚合读（逐段等价 + 一段失败不拖垮其余）
          'test/calendar.test.js', // 历史时间窗 + 日历月摘要（含「不带时间窗仍回 50 条」这条守门人）
          // 照片配额：默认值见 `src/image-store-factory.js`（边界两侧都验）
          // + 可配置 + 归属按学生 + 整批判。
          // ⚠️ 这里**故意不写具体数字**：副本会漂 —— 这一行原先写着那个旧值，
          // 而代码早已下调，没有任何测试能发现这个矛盾（`npm run quota:where` 才会）。
          // 它排在最后是因为**状态性最强**（要按需要造「配额-1 / 配额」两侧的行数），
          // 用带 `q_` 前缀的专有账号，与其它文件互不影响。
          'test/photo-quota.test.js',

          // ===== ima 同步（纯单元测试：假 client + 假 fetch，不碰库也不联网）=====
          // ⚠️ 这两条之前**不在清单里**：文件写好了、也手动跑绿过，但 `npm test`
          // 从来没执行过它们 —— 正是上面那句「漏了就是写了测试但没跑」的第二次实例。
          // 现在由 `test/runner-list.test.js` 盯着，再漏会红。
          'test/ima-openapi.test.js',
          'test/ima-credential.test.js',
          // 「不是所有人都有 ima」的判据：没开通 / 没配密钥 / 表没迁移时
          // 状态与书库恒 2xx、交卷可选同步永不抛错。漏了这条，
          // 家长一进「英文阅读」页就吃红色横幅（11-07 修）。
          'test/ima-optional.test.js',
          // 「配置主体是学生」的判据（11-08）：父母共管读同一行、切孩子状态跟着切、
          // connect 只建一个库、交卷与阅读按 studentId 取配置。
          'test/ima-student-scope.test.js',

          // ===== 每日概念打卡（同上，纯单元测试）=====
          'test/checkin-store.test.js',
          // 学生端「已完成」按科目分组（11-12）：汇总必须是库 group by 出来的
          // 真数（用已加载的那页去数，分页 10 条时数字会骗人且不报错）、
          // 列表的 subject 过滤要按参数下达（只断 SQL 里出现过 subject，
          // 过滤写反时照样绿）。
          'test/checkin-summary.test.js',
          // 服务端出题：题目带答案下发（交卷时本机判分要用）、下发那份与入库
          // 那份逐字一致、错题聚合口径、网关错误映射。
          'test/checkin-generate.test.js',

          // ===== 英文阅读（同上，纯单元测试）=====
          // 切课：这本书的 `Lesson N` 在 `#` / `##` 之间漂移、词条一半带 `#`
          // 一半是裸行、还有一课缺「参考阅读」标签。四条症状全是静默的
          // （少几课 / 词汇表只剩一条 / 译文空白），只能靠样本判据盯着。
          'test/reading-import.test.js',
          // 打卡判定：跳读 / 重复 / 读完自动收尾 / 中间有洞。写错的症状是
          // 「三天读完一本书」或「96/96 还挂着剩 1 篇」，都不报错。
          'test/reading-progress.test.js',

          // ===== 英语单词打卡（词表导入 / 范围 / 摘要，纯假 client）=====
          // 词表解析器的 golden vectors 与 test/word_normalizer_test.dart 同一份；
          // 无 ima 不报错、越界 bookId、025 未迁移降级都在这里盯。
          'test/word-import.test.js',
          'test/word-scope.test.js',

          // ===== 学科范围（家长配一次，出题直接用）=====
          // 十科白名单与客户端 `HomeworkItemNormalizer.subjectNames` 逐字对齐；
          // 越界不静默改默认值；026 未迁移时读降级、写响亮。
          'test/subject-scope.test.js',

          // ===== 书的年级学期（029）=====
          // 规范词 / 别名归一 / 宽松比对：同一年级两种叫法不能弹橙色横幅。
          'test/book-grade-term.test.js',

          // ===== 学科教材（骨架 MD → 章节 → 出题范围）=====
          // 解析器直接决定「哪一节能被考到」；取范围必须在没配教材 / 027
          // 未迁移时安静回 null，让出题退回错题本那条老路。
          'test/textbook-import.test.js',
          // 删旧教材：章节/书/范围三条一起删且不跨学生；漏清 scope 的症状是
          // 「界面还显示教材，出题却静默退回手填范围」。
          'test/textbook-delete.test.js',
          // 试卷错题 MD → review_mistake：格式闸挡住自动镜像、幂等删旧行必须
          // 同时带 student_id + source_type，否则会静默删掉其它来源的错题。
          'test/exam-mistake-import.test.js',

          // 清单自身的守门人：每个 test/*.test.js 都必须在上面出现过。
          // 它自己也在清单里（自指不会递归，它只读文件、不 spawn）。
          'test/runner-list.test.js',
        ], {
          cwd: serviceRoot,
          stdio: 'inherit',
          env: {
            ...process.env,
            TEST_PG_HOST: '127.0.0.1',
            TEST_PG_PORT: String(port),
            TEST_PG_DATABASE: database,
            TEST_PG_ADMIN_USER: LOCAL_PG.admin.user,
            TEST_PG_ADMIN_PASSWORD: LOCAL_PG.admin.password,
            TEST_PG_APP_USER: LOCAL_PG.app.user,
            TEST_PG_APP_PASSWORD: LOCAL_PG.app.password,
            TEST_PG_AUTH_USER: LOCAL_PG.auth.user,
            TEST_PG_AUTH_PASSWORD: LOCAL_PG.auth.password,
          },
        });
        // signal 非空说明子进程被外部杀掉了，那不算通过。
        child.on('exit', (code, signal) => resolve(signal ? 1 : (code ?? 1)));
        child.on('error', () => resolve(1));
      });
    },
    // 端口与演示栈错开（`LOCAL_PG.testPort`）：共用一个端口时，
    // 「演示栈还开着」会表现成「起库失败、测试环境坏了」。
    //
    // `onLog` 接上 `log`：起库/收尾阶段本来就有几句话必须能传出来 ——
    // 尤其是「测试库目录没删掉」那条警告（见 pg-local.js 的 removeDirWithRetry）。
    // 不接的话它落进默认的空回调里，而下一次开跑会死在 initdb 上。
    {
      databaseDir: path.join(serviceRoot, '.pgdata-test'),
      port: LOCAL_PG.testPort,
      onLog: log,
    },
  );
} catch (e) {
  log('起库或迁移失败：', e.message);
}

process.exit(exitCode);
