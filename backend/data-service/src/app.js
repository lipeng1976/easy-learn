import { forbidden, methodNotAllowed, notFound, notImplemented } from '../../shared/errors.js';
import { narrowToVisible, resolveIdentity } from './auth.js';
import { translateDbError, withAuthConnection, withAuthTransaction, withRequestContext } from './db.js';
import { errorResponse, jsonResponse, newRequestId, okEnvelope } from './http.js';
import {
  DEFAULT_QUOTA_PER_STUDENT,
  DEFAULT_QUOTA_WARN_REMAINING,
} from './image-store-factory.js';
import * as appUpdate from './routes/app_update.js';
import * as auth from './routes/auth.js';
import * as bootstrap from './routes/bootstrap.js';
import * as calendar from './routes/calendar.js';
import * as chat from './routes/chat.js';
import * as focus from './routes/focus.js';
import * as homework from './routes/homework.js';
import * as notification from './routes/notification.js';
import * as points from './routes/points.js';
import * as relationship from './routes/relationship.js';
import * as review from './routes/review.js';
import * as studyPlan from './routes/study_plan.js';
import * as user from './routes/user.js';
import * as wish from './routes/wish.js';
import * as workout from './routes/workout.js';
import * as ima from './routes/ima.js';
import * as checkin from './routes/checkin.js';
import * as reading from './routes/reading.js';
import * as word from './routes/word.js';
import * as subject from './routes/subject.js';
import * as textbook from './routes/textbook.js';
import * as exam from './routes/exam.js';

/**
 * 数据服务的请求处理核心。
 *
 * 刻意不依赖任何 HTTP 框架：网关是零依赖的 Node ESM，这里保持一致 ——
 * 部署到云函数时不用打包 node_modules，冷启动也快。
 * dev-server.js 用 node:http 包一层，云函数入口用同一套调用。
 *
 * ## 路由分两类，走两条不同的连接
 *
 * - **公开**（`public: true`）—— 注册与登录。此刻还没有身份，
 *   所以走 `app_auth` 连接（它带 BYPASSRLS，但只被授权碰三张账号表）。
 * - **受保护** —— 其余全部。先解析身份（验签 + 查会话），
 *   再用 `app_rls` 连接在事务里带身份执行，RLS 生效。
 *
 * 分类写在路由表里而不是靠路径前缀猜：`/auth/*` 里只有两条是公开的，
 * 用前缀判断迟早会把某条新加的账号接口错误地开放出去。
 */
/**
 * 路由表由 `createApp` 在拿到 `updatePackageDir` 之后构造。
 *
 * 之前是模块级常量，但更新端点需要注入目录 —— 写成常量时 handler 引用了
 * 函数内的局部变量，模块一加载就 ReferenceError（判据 app_update.test.js 抓到）。
 * 保留 `buildRoutes` 导出给测试读元数据，不改变「分类写在表里、不靠前缀猜」的口径。
 */
export function buildRoutes(updateRoutes) {
  return [
  // ===== 公开：注册与登录（S2）=====
  { method: 'POST', path: '/auth/register', public: true, handler: auth.register },
  { method: 'POST', path: '/auth/login', public: true, handler: auth.login },
  // 微信登录：客户端的登录方式枚举里已经留了这一档（`doc/auth-extension-seams.md`）。
  // 服务端把路径先占住，回 **501 `not_implemented` 而不是 404** ——
  // 两者的排查方向相反：404 会让人去查「是不是这次部署漏了这段代码」，
  // 而这里其实是计划内的空缺。见 `shared/errors.js` 的 `notImplemented`。
  {
    method: 'POST',
    path: '/auth/login-wechat',
    public: true,
    handler: () => { throw notImplemented('微信登录尚未接入（预留端点）'); },
  },

  // ===== 公开：本机版 App 更新（登录前也要能检查）=====
  //
  // `public: true` 而不是挂 AuthGuard：旧版本可能因 bug 根本登不进去，
  // 那时「必须先登录才能检查更新」等于把自救通道堵死。
  // 清单只回契约字段、下载只认清单里点名的 APK，见 routes/app_update.js。
  { method: 'GET', path: '/app/update', public: true, handler: updateRoutes.checkUpdate },
  // `raw: true`：APK 74MB，不能包进 JSON 信封（那会多一次编码且解码端要拆层）。
  { method: 'GET', path: '/app/download', public: true, raw: true, handler: updateRoutes.downloadApk },

  // ===== 受保护：会话管理（S2）=====
  { method: 'GET', path: '/auth/me', handler: auth.me },
  { method: 'GET', path: '/auth/sessions', handler: auth.listSessions },
  { method: 'POST', path: '/auth/logout', handler: auth.logout },
  { method: 'POST', path: '/auth/password', handler: auth.changePassword },

  // ===== 受保护：首屏聚合读（P2-2）=====
  //
  // 一次往返带回首屏要的二十段数据，客户端据此**预热读缓存** —— 于是首页那
  // 18 次读全部变成缓存命中。它是一个**加速手段，不是数据通路**：客户端在
  // 它失败（或这条路由不存在）时逐条读，行为与本端点出现之前完全一致。
  //
  // ⚠️ 这条路由的 handler **不含任何 SQL**，每一段都转调各路由自己的 list 函数。
  // 理由见 `routes/bootstrap.js` 的文件头 —— 聚合端点最容易写坏的形态就是
  // 「顺手在这里再写一遍查询」，那会让「我能看到哪些作业」有两份实现。
  { method: 'GET', path: '/data/bootstrap', handler: bootstrap.readBootstrap },

  // ===== 受保护：日历月摘要（历史数据方案 §2.2）=====
  //
  // 「历史查不到」这件事的修法分两半：**按月摘要**（本端点，给出每天有几条，
  // 日历据此打点、并判断「这个月是不是空的」）+ **按天明细**（已有的
  // `/data/homework` 等，加了 `from`/`to`）。
  //
  // 为什么要单独一个端点而不是让客户端按天逐次查：翻月时日历不知道哪天有数据，
  // 就只能让人一格一格点；而且连点几天就是连发几次请求。
  //
  // ⚠️ 它**必须**要知道用户时区（`tzOffsetMinutes`），因为「这是哪一天」是
  // 时区相关的，而服务端不猜时区（R3 的教训：猜错就是静默偏一整天）。
  // 打卡那一列是 DATE，是唯一的例外 —— 它本来就是本地日，不做换算。
  { method: 'GET', path: '/data/calendar/summary', handler: calendar.calendarSummary },

  // ===== 受保护：用户与档案（S3 收尾）=====
  // S3 落地时这一组被「聚合读端点推迟到 S4」一并推迟了（计划 §4.5 ④），
  // 于是客户端切过来时「读档案」「把 id 解析成姓名」无处可去。
  // 这里只补契约真正需要的两条；`bootstrap` 那种聚合仍留给 S4。
  // 两个读法合成一个端点（`?userId=` / `?ids=`）的理由见 routes/user.js。
  { method: 'GET', path: '/data/users', handler: user.listUsers },
  { method: 'POST', path: '/data/users/profile', handler: user.saveProfile },

  // ===== 受保护：结伴（S2，修掉「两台手机必然失败」）=====
  { method: 'GET', path: '/data/relationship', handler: relationship.listRelationships },
  { method: 'POST', path: '/data/relationship/invite', handler: relationship.invite },
  { method: 'POST', path: '/data/relationship/status', handler: relationship.updateStatus },
  // 解除（2026-09-26）—— **独立端点**而不是 `status` 的一个取值：
  // 前置状态（active vs pending）、权限（仅家长 vs 被邀请方）、
  // 语义（撤销已成立的关系 vs 回应一个邀请）三样都不同。
  { method: 'POST', path: '/data/relationship/revoke', handler: relationship.revoke },

  // ===== 受保护：聊天（结伴双方的一对一对话）=====
  //
  // 表 / 索引 / RLS 从一开始就在（`sql/001_schema.sql` 17/22），**只缺这两条路由** ——
  // 于是云端模式下「伴学消息」读写都抛 `not_implemented`，点发送毫无反应。
  // 校验见 `routes/chat.js` 头注释：成员 + `active` 两道，缺一都是越权。
  { method: 'GET', path: '/data/chat/messages', handler: chat.listChatMessages },
  { method: 'POST', path: '/data/chat/messages', handler: chat.sendChatMessage },

  // ===== 受保护：ima 连接（多家庭·多学生独立知识库 + 可选同步）=====
  // 无 ima 账号可完全不连接（status 默认 unconnected），核心功能零影响。
  { method: 'POST', path: '/data/ima/connect', handler: ima.connectIma },
  { method: 'POST', path: '/data/ima/disconnect', handler: ima.disconnectIma },
  { method: 'GET', path: '/data/ima/status', handler: ima.getImaStatus },

  // ===== 受保护：英文阅读（从 ima 导入书 → 长期任务 → 每篇一次打卡）=====
  // 任务挂在**书**上而不是日期上：没有「今日待办」端点，也没有「顺延」逻辑。
  // 学生断更几天再打开，`GET /data/reading/tasks` 返回的还是一模一样的进度。
  // 详见 `sql/023_reading.sql` 与 `routes/reading.js` 的文件头。
  //
  // ima 是可选能力：`books/available` 在没开通时回 2xx + `connected:false`，
  // 客户端据此把「从 ima 导入」整块藏起来；不能回 4xx/5xx 让页面飘红。
  // 只有「导入」（家长主动点的动作）才允许回一句温和的 400。
  { method: 'GET', path: '/data/reading/books/available', handler: reading.listAvailableBooks },
  { method: 'POST', path: '/data/reading/books/import', handler: reading.importBook },
  { method: 'GET', path: '/data/reading/books', handler: reading.listBooks },
  { method: 'GET', path: '/data/reading/lessons', handler: reading.listLessons },
  { method: 'GET', path: '/data/reading/lesson', handler: reading.getLesson },
  { method: 'GET', path: '/data/reading/tasks', handler: reading.listTasks },
  { method: 'POST', path: '/data/reading/tasks', handler: reading.createTask },
  { method: 'POST', path: '/data/reading/tasks/read', handler: reading.readLesson },
  { method: 'POST', path: '/data/reading/tasks/cancel', handler: reading.cancelTask },
  // 打卡记录（哪天读了第几篇）。任务进度只回答「读到第几篇」，
  // 「今天读了没有 / 这一周读了几天」只能查这张表 —— 见 routes/reading.js 的 listLogs。
  { method: 'GET', path: '/data/reading/logs', handler: reading.listLogs },

  // ===== 受保护：英语单词打卡（词表真值 + 练习范围 + 成绩摘要）=====
  // ⚠️ **没有出题端点**：题目由客户端按日期种子从本地词表确定性生成，
  // 服务端没有题目快照、也不复算判分（`doc/word-checkin-design.md` §7.3）。
  // `books` 恒 2xx：没开通 ima 时 connected:false，但 `imported` 仍列出已导入的书，
  // 让已缓存词表的家庭照常切书、打卡，不弹红条。
  { method: 'GET', path: '/data/word/books', handler: word.listAvailableWordlists },
  { method: 'POST', path: '/data/word/import', handler: word.importWordlist },
  { method: 'GET', path: '/data/word/entries', handler: word.listWordEntries },
  { method: 'GET', path: '/data/word/scope', handler: word.getWordScope },
  { method: 'PUT', path: '/data/word/scope', handler: word.putWordScope },
  { method: 'POST', path: '/data/word/daily', handler: word.postWordDaily },
  { method: 'GET', path: '/data/word/daily', handler: word.listWordDaily },

  // ===== 受保护：学科范围（家长配一次，出题直接用）=====
  // 十科都预留：能配范围的是全部科目，本轮打通出题的只有数学（AI）
  // 与英语（本地单词）。`026` 未迁移时读端点按「未配置」降级，写端点响亮失败。
  { method: 'GET', path: '/data/subject/scopes', handler: subject.listSubjectScopes },
  { method: 'GET', path: '/data/subject/scope', handler: subject.getSubjectScope },
  { method: 'GET', path: '/data/subject/seeds', handler: subject.listSubjectSeeds },
  { method: 'PUT', path: '/data/subject/scope', handler: subject.putSubjectScope },
  // 教材：ima 骨架 MD → 章节 → 出题范围。列表恒 2xx（ima 可选），导入才响亮失败。
  { method: 'GET', path: '/data/textbook/books', handler: textbook.listTextbooks },
  { method: 'GET', path: '/data/textbook/units', handler: textbook.listUnits },
  { method: 'POST', path: '/data/textbook/import', handler: textbook.importTextbook },
  // 教材换版时删掉旧的那本；同一个事务里清掉指向它的 subject_scope，
  // 否则「教材还配着」但出题静默退回手填范围。
  { method: 'POST', path: '/data/textbook/delete', handler: textbook.deleteTextbook },
  // 试卷错题：ima `教学资料/试卷错题/` 的手工 MD → review_mistake。
  // 列表恒 2xx（ima 可选）；导入/撤销按 (student_id, source_type, source_ref) 幂等。
  { method: 'GET', path: '/data/exam/mistakes/files', handler: exam.listExamMistakeFiles },
  { method: 'POST', path: '/data/exam/mistakes/import', handler: exam.importExamMistakes },
  { method: 'POST', path: '/data/exam/mistakes/revoke', handler: exam.revokeExamMistakes },

  // ===== 受保护：每日概念打卡 =====
  // `generate` 是**服务端出题**：错题聚合 → 调 AI 网关 → 落库 → 返回题目。
  // 题目带答案（客户端交卷时本机立刻判对错）；「答题时看不到答案」由客户端
  // 渲染层负责。判分同时也由服务端按题目快照复算 —— 客户端那份只用于即时反馈，
  // 理由见 routes/checkin.js 的「判分在这里复算」。
  // `seeds` 是家长挑知识点的候选（与出题同一段聚合逻辑，只是不截到 6 个）。
  { method: 'GET', path: '/data/checkin/seeds', handler: checkin.listCheckinSeeds },
  { method: 'POST', path: '/data/checkin/generate', handler: checkin.generateCheckin },
  { method: 'POST', path: '/data/checkin/quiz', handler: checkin.saveCheckinQuiz },
  { method: 'GET', path: '/data/checkin/quiz', handler: checkin.getCheckinQuiz },
  { method: 'GET', path: '/data/checkin/summary', handler: checkin.listCheckinSummary },
  { method: 'POST', path: '/data/checkin/submit', handler: checkin.submitCheckin },
  { method: 'GET', path: '/data/checkin/results', handler: checkin.listCheckinResults },

  // ===== 受保护：作业 =====
  // 写路径是 `insert` / `update`(掩码) / `delete` / 照片行。
  // 计划 §4.3 里还列了 `submit` / `check` —— 核过 Repository 接口后
  // **没有建**，理由见 routes/homework.js 的文件头（它们是 L1 动作，在这里就是掩码）。
  // 而 `delete` **建了**：它同样是 L1 动作，但删作业不是「按掩码写回」，
  // 而且必须在一个事务里连照片行与错题一起删（`homework` 表没有外键指向它）。
  { method: 'GET', path: '/data/homework', handler: homework.listHomework },
  { method: 'POST', path: '/data/homework', handler: homework.createHomework },
  { method: 'POST', path: '/data/homework/update', handler: homework.updateHomework },
  { method: 'POST', path: '/data/homework/delete', handler: homework.deleteHomework },
  { method: 'POST', path: '/data/homework/images', handler: homework.saveHomeworkImages },
  { method: 'GET', path: '/data/homework/images', handler: homework.listHomeworkImages },
  { method: 'GET', path: '/data/homework/images/count', handler: homework.countHomeworkImages },
  { method: 'POST', path: '/data/homework/images/delete', handler: homework.deleteHomeworkImages },
  // 照片的**字节**（前面三条只管「行」，这条管字节）。
  //
  // `upload` 的请求体是原始字节而不是 JSON —— 图片是二进制，
  // 让它走 base64 会在链路上凭空胖三分之一，且两端各多一次编解码。
  // 元数据（文件名 / 类型）因此只能走 query，见 `scoped.query` 的说明。
  { method: 'POST', path: '/data/homework/images/upload', handler: homework.uploadHomeworkImage },
  // 大附件（音频/视频）的**直传签发**。它不接收字节，只回一个签好名的位置 ——
  // 100MB 的视频过不去函数请求体，只能让客户端直接 PUT 到对象存储。
  // 返回 `uploadUrl` + `headers`，客户端原样发送即可（见该 handler 的说明）。
  { method: 'POST', path: '/data/homework/images/sign-upload', handler: homework.signHomeworkAttachmentUpload },
  // 大附件（视频）的**直读签发**。与 `sign-upload` 对称，但绕开的是**响应体**上限：
  // 函数回不了超过 32 MiB 的响应，而视频上限 100 MB —— 于是「传得上去、取不回来」。
  // 客户端拿到 `readUrl` + `headers` 后直接从对象存储取（可流式播放，不用整段进内存）。
  // 见 `doc/open-items.md` B32。
  { method: 'GET', path: '/data/homework/images/sign-read', handler: homework.signHomeworkAttachmentRead },
  // `raw: true`：该路由的返回值**直接就是响应**，不包成功信封（见 http.js 的 binaryResponse）。
  { method: 'GET', path: '/data/homework/images/file', raw: true, handler: homework.readHomeworkImageBytes },

  // ===== 受保护：复习（S3）=====
  { method: 'GET', path: '/data/review/mistakes', handler: review.listMistakes },
  { method: 'POST', path: '/data/review/mistakes/insert', handler: review.insertMistakes },
  // `overwrite`（整行覆盖）与 `state`（掩码）刻意是两个端点，见 MISTAKE_STATE_SPEC：
  // 合成一个会得到「传了什么就覆盖什么、没传的就清空」的接口。
  { method: 'POST', path: '/data/review/mistakes/overwrite', handler: review.overwriteMistake },
  { method: 'POST', path: '/data/review/mistakes/state', handler: review.updateMistakeState },
  { method: 'POST', path: '/data/review/mistakes/delete', handler: review.deleteMistake },
  { method: 'POST', path: '/data/review/mistakes/delete-by-homework', handler: review.deleteMistakesByHomework },
  // 错题图片：与 homework_image 分表，读取端点也分开（见 sql/011）。
  { method: 'GET', path: '/data/review/mistake-images', handler: review.listMistakeImages },
  { method: 'POST', path: '/data/review/mistake-images/insert', handler: review.insertMistakeImages },
  { method: 'POST', path: '/data/review/mistake-images/delete', handler: review.deleteMistakeImage },
  { method: 'GET', path: '/data/review/mistake-images/file', raw: true, handler: review.readMistakeImageBytes },
  { method: 'GET', path: '/data/review/papers', handler: review.listPapers },
  { method: 'GET', path: '/data/review/paper-items', handler: review.listPaperItems },
  { method: 'POST', path: '/data/review/papers/create', handler: review.createPaper },
  { method: 'POST', path: '/data/review/papers/update', handler: review.updatePaper },
  { method: 'POST', path: '/data/review/paper-items/update', handler: review.updatePaperItem },
  { method: 'GET', path: '/data/review/attempts', handler: review.listAttempts },
  { method: 'POST', path: '/data/review/attempts/insert', handler: review.insertAttempts },
  { method: 'GET', path: '/data/review/practice', handler: review.listPractice },
  { method: 'POST', path: '/data/review/practice/replace', handler: review.replacePractice },
  { method: 'POST', path: '/data/review/practice/update', handler: review.updatePractice },
  { method: 'GET', path: '/data/review/explains', handler: review.listExplains },
  { method: 'POST', path: '/data/review/explains/insert', handler: review.insertExplain },
  { method: 'GET', path: '/data/review/summaries', handler: review.listSummaries },
  { method: 'POST', path: '/data/review/summaries/upsert', handler: review.upsertSummary },
  { method: 'GET', path: '/data/review/judgement-ab', handler: review.listJudgementAB },
  { method: 'POST', path: '/data/review/judgement-ab/insert', handler: review.insertJudgementAB },

  // ===== 受保护：积分 =====
  // 前四条的路径是 S1 契约测试钉住的，**不能改名**（`reverse` 的实现已换成
  // 原子的 `revokePoints`，但路径属于对外协议）。
  { method: 'GET', path: '/data/points/ledger', handler: points.queryLedger },
  { method: 'POST', path: '/data/points/earn', handler: points.earnPoints },
  { method: 'POST', path: '/data/points/reverse', handler: points.revokePoints },
  { method: 'GET', path: '/data/points/balance', handler: points.balanceOf },
  { method: 'GET', path: '/data/points/rules', handler: points.listRules },
  { method: 'POST', path: '/data/points/rules', handler: points.upsertRule },

  // ===== 受保护：心愿（S3）=====
  { method: 'GET', path: '/data/wishes', handler: wish.listWishes },
  { method: 'POST', path: '/data/wishes', handler: wish.insertWish },
  { method: 'POST', path: '/data/wishes/confirm', handler: wish.confirmWish },
  { method: 'POST', path: '/data/wishes/archive', handler: wish.archiveWish },
  { method: 'POST', path: '/data/wishes/redeem', handler: wish.redeemWish },

  // ===== 受保护：学习计划与打卡（S3）=====
  { method: 'GET', path: '/data/study-plans', handler: studyPlan.listPlans },
  { method: 'POST', path: '/data/study-plans', handler: studyPlan.insertPlan },
  { method: 'POST', path: '/data/study-plans/status', handler: studyPlan.updatePlanStatus },
  { method: 'GET', path: '/data/study-plans/checkins', handler: studyPlan.listCheckins },
  { method: 'POST', path: '/data/study-plans/checkin', handler: studyPlan.checkin },
  { method: 'POST', path: '/data/study-plans/checkin/delete', handler: studyPlan.deleteCheckin },

  // ===== 受保护：专注计时流水 =====
  { method: 'GET', path: '/data/focus-session', handler: focus.listFocusSessions },
  { method: 'POST', path: '/data/focus-session/save', handler: focus.saveFocusSession },

  // ===== 受保护：运动（S3）=====
  { method: 'GET', path: '/data/workouts/plans', handler: workout.listPlans },
  { method: 'POST', path: '/data/workouts/plans', handler: workout.insertPlan },
  { method: 'POST', path: '/data/workouts/plans/active', handler: workout.setPlanActive },
  { method: 'GET', path: '/data/workouts/records', handler: workout.listRecords },
  { method: 'POST', path: '/data/workouts/records', handler: workout.insertRecord },

  // ===== 受保护：通知与每日点评（S3）=====
  // ⚠️ **刻意没有 `POST /data/notifications`**。`NotificationRepository.insertNotification`
  // 在本地实现里是「客户端把通知写进本机的库」，上云后它退化成**服务端内部调用**
  // （见 routes/notify.js）：通知在事件发生时由服务端生成。
  // 让接口*不存在*比「存在但返回 403」更能表达这件事 —— 少一条路，就少一个
  // 将来被误用的口子，而且客户端不会因为它存在而过早地依赖它。
  { method: 'GET', path: '/data/notifications', handler: notification.queryNotifications },
  { method: 'POST', path: '/data/notifications/read', handler: notification.markNotificationRead },
  // 批量标已读。**不收 body**：能标哪些由服务端按 token 推导，
  // 客户端传 id 列表等于让它决定「能标谁的通知」。
  { method: 'POST', path: '/data/notifications/read-all', handler: notification.markAllNotificationsRead },
  { method: 'GET', path: '/data/daily-comments', handler: notification.queryDailyComments },
  { method: 'POST', path: '/data/daily-comments', handler: notification.insertDailyComment },
  ];
}

/**
 * @param {object} deps
 * @param {import('pg').Pool} deps.pool 应用连接池（RLS 生效的角色 app_rls，见 db.js）
 * @param {import('pg').Pool} deps.authPool 鉴权连接池（app_auth）—— 注册登录的必经之路
 * @param {string} deps.sessionSecret 会话签名密钥
 * @param {object} [deps.imageStore] 照片字节存储（见 imagestore.js）
 * @param {number} [deps.photoQuota] 单学生照片张数上限（见 `IMAGE_QUOTA_PER_STUDENT`）
 * @param {number} [deps.photoWarnRemaining] 剩余不足多少张时提示（见 `IMAGE_QUOTA_WARN_REMAINING`）
 */
export function createApp({
  pool,
  authPool,
  sessionSecret,
  imageStore = null,
  photoQuota = DEFAULT_QUOTA_PER_STUDENT,
  photoWarnRemaining = DEFAULT_QUOTA_WARN_REMAINING,
  /**
   * AI 网关客户端（见 src/ai_client.js）。
   *
   * 可能为 `null` —— 表示这台部署没配 `AI_GATEWAY_BASE_URL`。
   * **不在这里抛错**：那会让「没接上 AI」表现成「整个数据服务起不来」，
   * 而登录、作业、错题、积分这些路由本来好好的。
   * 用到它的那条路由（`/data/checkin/generate`）会如实回
   * `model_not_enabled`，其余照常工作。
   */
  aiGateway = null,
  /**
   * 这台部署的**身份**（`SERVER_INSTANCE_ID`）。由 `/health` 原样回出。
   *
   * 客户端用它排除「同网段的另一台机器」：手机在家连 `192.168.3.80`，
   * 而在别人家 WiFi 里这个地址很可能是别人的设备 —— 只看「端口通」不够，
   * 得确认「服务是我的」。空值 = 不报这个字段（旧部署兼容）。
   */
  instanceId = '',
  /**
   * 更新包目录（`UPDATE_PACKAGE_DIR`）。空 = 这台部署没有更新能力，
   * 端点仍注册但回「无更新」，客户端据此安静跳过（ima 式的静默降级）。
   */
  updatePackageDir = '',
  now = () => Date.now(),
  logger = console,
}) {
  const updateRoutes = appUpdate.createUpdateRoutes({ updatePackageDir });
  const ROUTES = buildRoutes(updateRoutes);
  // 缺 authPool 时立刻报错，而不是等到有人点「注册」才发现：
  // 那会表现成一次线上故障，而它其实是一次部署配置遗漏。
  if (!authPool) {
    throw new Error('createApp 需要 authPool（鉴权连接池，角色 app_auth）：注册/登录/会话校验都走它');
  }

  /**
   * @param {{method: string, pathname: string, query: object, headers: object, body: object, remoteAddress?: string}} request
   * @returns {Promise<{status: number, headers: object, body: string}>}
   */
  return async function handle(request) {
    const requestId = newRequestId();
    const { method, pathname, query = {}, headers = {}, body = {}, bytes = null } = request;

    try {
      // ── 跨域预检（2026-09-26 实测补上）────────────────────────────────────
      //
      // **放在最前面**：预检与具体路径无关。浏览器只对它「即将要发的那一个
      // 请求」问一句「允不允许」，自己不带业务语义 —— 所以这里不查路由表，
      // 也不要求那条路径存在。
      //
      // 浏览器在发**带自定义头**的请求之前会先发一个 OPTIONS。本项目每个业务
      // 请求都带 `accept` + `authorization`（`data_api_client.dart:697`），
      // 写请求还带 `content-type: application/json` —— 这些都**不在 CORS
      // 简单请求的白名单里**，所以 Web 版**每一个**业务请求（含登录本身）
      // 都要先过预检。
      //
      // 而路由表里没有 OPTIONS，它走到下面那句会被判成 405（「路径存在但方法
      // 不对」）。**405 不是 2xx ⇒ 浏览器判定预检失败 ⇒ 实际请求根本不发。**
      //
      // ⚠️ 缺了这段的症状极难查（2026-09-26 真浏览器实测的记录）：
      //   · 浏览器侧只有一句 `Failed to fetch`，本地 37ms 就返回（不是超时）；
      //   · **后端日志里一条都没有** —— 请求压根没发出来，服务端没收到任何东西；
      //   · 而 `curl -X OPTIONS` 能拿到 405 + 一整套 CORS 头，**看着像已经配好了**。
      //   · 原生 App 不发 `Origin`，完全不受影响 ⇒ 「手机上好好的，浏览器里全挂」。
      //
      // 这个配 / 实现的错位是本项目里最典型的「配置对了、行为不对」：
      // `s.yaml` 的 trigger **早就**把 OPTIONS 加进了 `methods`，注释还写着
      // 「Web 版的跨域预检要用它；缺了浏览器侧直接失败而后端无日志」——
      // 但**函数代码里没有任何地方接它**。触发器放行了 OPTIONS，函数把它当成
      // 一个不认识的方法。两半必须都在。
      //
      // 这里**只终止预检、不回任何 CORS 头**：来源该由网关统一决定，不该由业务
      // 代码各自决定（见 `doc/release-guide.md` §1.6）。云上 FC 的 Default CORS
      // 会按请求回显 `Access-Control-Allow-Origin` 等头；函数再自己加一份的话
      // 会出现**重复的** `Access-Control-Allow-Origin`，那是浏览器直接报错的形态。
      //
      // 本机外壳 `dev-server.js` 在更外层就自己处理了 OPTIONS（回 204 + 它那套
      // CORS），所以本机这条路不经过这里 —— 但对 OPTIONS 的口径两边一致：**204**。
      // （那边的注释写着「预检必须在读请求体之前结束」，同一个道理。）
      if (method === 'OPTIONS') {
        return { status: 204, headers: {}, body: '' };
      }

      if (pathname === '/health') {
        return jsonResponse(200, okEnvelope({
          service: 'data-service',
          // 只在配了的时候出现 —— 空串和「没配」在客户端是两种处理，
          // 回一个空串会让人以为配了但没生效。
          ...(instanceId ? { instanceId } : {}),
        }));
      }

      const matched = ROUTES.filter((r) => r.path === pathname);
      if (matched.length === 0) {
        throw notFound(`未知端点：${method} ${pathname}`);
      }
      const route = matched.find((r) => r.method === method);
      if (!route) {
        // 路径存在但方法不对，要明确 405 而不是 404 —— 否则排查时会去查路由表有没有漏配。
        throw methodNotAllowed(
          `${pathname} 支持 ${matched.map((r) => r.method).join(' / ')}，收到 ${method}`,
        );
      }

      const input = route.method === 'GET' ? query : body;
      // 记下这是哪台设备开的会话。只在建会话时用得上，但要**从第一次**
      // 就开始写 —— 「列出登录设备」这个功能迟早要有，那时补写不进历史会话。
      const clientLabel = String(headers['user-agent'] ?? headers['User-Agent'] ?? '').slice(0, 200);
      // 登录留痕用的来源 IP。转发头优先：云函数网关会给 X-Forwarded-For；
      // 本机 FRP 是纯 tcp 转发，没有转发头，就退回 socket 地址（127.0.0.1）。
      // 只取第一段，逗号后面是代理链，不是客户端。
      const forwarded = String(headers['x-forwarded-for'] ?? headers['X-Forwarded-For'] ?? '')
        .split(',')[0].trim();
      const realIp = String(headers['x-real-ip'] ?? headers['X-Real-IP'] ?? '').trim();
      const clientIp = (forwarded || realIp || String(request.remoteAddress ?? '')).slice(0, 64);

      if (route.public === true) {
        const result = await withAuthTransaction(authPool, (client) => route.handler({
          client, sessionSecret, now, requestId, clientLabel, clientIp,
        }, input));
        // raw 公开路由（/app/download）：返回值本身就是响应，不包信封。
        // 与受保护分支的 raw 口径一致 —— 客户端对「字节」只写一套解析。
        if (route.raw === true) return result;
        return jsonResponse(200, okEnvelope(result, { requestId }));
      }

      // 身份在进业务事务之前就定下来：token 无效 / 会话已吊销的请求不该占用业务连接。
      // 这里的两次查询（验签在内存里、会话查一次库）都走鉴权连接。
      const identity = await resolveIdentity(headers, { secret: sessionSecret, authPool, now: now() });

      const result = await withRequestContext(pool, identity, async (client, ctx) => {
        // 客户端可以带 studentId 做筛选（家长在两个孩子间切换），
        // 但**只能在这个请求的可见集合里挑**，越界直接 403。
        const narrowed = narrowToVisible(ctx.visibleStudents, query.studentId ?? body?.studentId);
        if (narrowed.denied) {
          throw forbidden('该学生不在你的可见范围内');
        }
        const scoped = {
          ...ctx,
          students: narrowed.students,
          now,
          clientLabel,
          /**
           * 客户端带来的原始 `Authorization` 头，**原样转发给 AI 网关**用。
           *
           * 为什么不新签一张服务票：项目里「取票只走 `AiIdentity.resolve`」是
           * 硬约束 —— 另建一份票，迟早出现「票写 A、身份取 B」，本地全绿、
           * 只有网关 401。转发同一张票，两个服务看到的是同一个人。
           */
          authHeader: String(headers?.authorization ?? headers?.Authorization ?? ''),
          /** AI 网关客户端；可能为 null（没配基址），见 createApp 的说明。 */
          aiGateway,
          // 改密要签一个新 token，而签名需要密钥。`ctx` 是 db.js 建的
          // （只装身份与可见集合），所以密钥在这里显式带上 ——
          // 少了它的症状是改密时抛「Cannot read properties of undefined」。
          sessionSecret,
          /**
           * 「按手机号找一个账号」——结伴邀请要用（邀请方手里只有手机号）。
           *
           * 为什么必须是**惰性**的：它得走鉴权连接（app_user 的 policy 让已登录用户
           * 看不到无关账号），而绝大多数请求根本不需要这个能力。
           * 每个请求预先借一条连接，等于把一个偶发需求变成常态开销。
           *
           * 它返回的是**含哈希的整行**（auth.selectUserByPhone 的 LEFT JOIN），
           * 所以调用方有义务只取需要的字段 —— 见 routes/relationship.js 的用法。
           */
          lookupUserByPhone: (phone) => withAuthConnection(
            authPool,
            (c) => auth.selectUserByPhone(c, phone),
          ),
          /**
           * 照片字节的存储（见 imagestore.js）。可能为 `null` —— 表示这次部署
           * 没配 `IMAGE_ROOT_DIR`。**不在这里抛错**：那会让「没配图片存储」
           * 表现成「整个数据服务起不来」，而其余 40 多条路由本来好好的。
           * 让用到它的那两条路由各自如实回 `upload_not_configured`。
           */
          imageStore,
          /**
           * 单学生照片张数上限（`IMAGE_QUOTA_PER_STUDENT`，见 image-store-factory.js）。
           *
           * **刻意与 `imageStore` 分开挂**：测试里注入一个假存储时，
           * 配额应当仍是真实的那一个。挂在 store 上的话，
           * 「配额」这条逻辑会在测试里悄悄用上另一套数字，
           * 而它的失败信息会指向「存储没接通」这个假线索。
           */
          photoQuota,
          /**
           * 「剩余不足多少张时提示」。与 `photoQuota` 一样是**独立装配项**。
           *
           * 两个数都由服务端放进响应的 `photoUsage` 交给客户端，而不是让客户端
           * 自己再抄一份阈值 —— 抄一份的话，改配额的人不会想到还有第二处要改，
           * 症状是「阈值配了却不见效」，而排查方向会先跑到客户端缓存上去。
           */
          photoWarnRemaining,
          /**
           * 上传照片要同时拿到**查询参数**和**原始字节**两样东西，
           * 而 `input`（GET 取 query / POST 取 body）只能装一样 ——
           * 上传的 body 就是图片本身，不是 JSON，所以元数据只能走 query。
           * 为两条路由改掉 40 多个 handler 的签名不划算，所以显式挂在这里。
           */
          query,
          rawBody: bytes,
        };
        return route.handler(client, scoped, input);
      });

      // `raw` 路由的返回值**本身就是响应**（照片字节，见 http.js 的 binaryResponse）。
      // 它们的失败仍然走下面的 catch —— 抛出来的 ApiError 照样是一个 JSON 信封，
      // 客户端因此不需要为「图片」单独写一套错误解析。
      if (route.raw === true) return result;

      return jsonResponse(200, okEnvelope(result, { requestId }));
    } catch (e) {
      return errorResponse(translateDbError(e), requestId);
    }
  };
}
