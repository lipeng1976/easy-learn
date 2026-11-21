import { randomUUID } from 'node:crypto';

import { badRequest, forbidden, notFound } from '../../../shared/errors.js';
import { requireVisibleStudent } from '../auth.js';
import { requireText, toDate, toInt, toText } from '../coerce.js';
import {
  IMA_MEDIA_TYPE_FOLDER,
  IMA_MEDIA_TYPE_MARKDOWN,
  downloadMedia,
  getKnowledgeList,
  shouldSync,
} from '../ima_openapi.js';
import { decryptCredential, getStudentImaConfig } from '../ima_repository.js';
import { parseBook } from '../reading_import.js';
import { planLessonRead, taskProgress } from '../reading_progress.js';

/**
 * 英文阅读：从 ima 导入一本书 → 家长布置成长期任务 → 学生每读一篇打卡一次。
 *
 * ## 任务挂在书上，不挂在日期上
 *
 * 详见 `sql/023_reading.sql` 的文件头。这里只重复一条对接口形状的影响：
 * **没有「今日待办」端点**。学生端拿到的是「这本书读到 3/96，下一篇第 4 课」，
 * 而不是「今天该读第 4 课」。所以断更三天再打开，接口返回的东西**一模一样**
 * —— 顺延是数据模型自带的，不是一段需要维护的业务逻辑。
 *
 * ## ima 是可选的：「没开通」不能是错误
 *
 * 11-07 定下的硬规矩：不是所有人都有 ima，没有的话功能可以不出现，但不能出错。
 * 所以「没连 ima / 没配密钥 / 表没迁移 / 凭证失效 / 没有 KB」一律静默降级：
 * 书库列表回 2xx + `connected:false`，客户端把「从 ima 导入」整块藏起来。
 * 以前这里抛 400/500，家长一进「英文阅读」页就吃一条红色横幅 —— 正是要消灭的。
 *
 * ## 两个「必须响亮失败」的地方
 *
 * 只有**家长按了按钮在等**的动作才需要反馈，**沉默即 bug**：
 *
 *   ① 下载 / 切课失败 → 说清是哪一步（网络 / 文件太大 / 没识别出课）；
 *   ② 书里没有 `Lesson N` 标题 → 拒绝导入，不存一本 0 课的书
 *      （存进去之后，任务总篇数是 0，学生端会显示「已读完」）。
 */

/** ima 侧书籍目录。与 `doc/ima-integration-design.md` 里的约定一致。 */
const READING_FOLDER_PATH = ['教学资料', 'English'];

/**
 * 单本书的字节上限。
 *
 * 实测一本书（96 课、含 311 张 base64 小图）3.4MB；20MB 给了 6 倍余量。
 * 再大就不是「一本阅读书」了，而 `downloadMedia` 那边还有同一个数的硬闸。
 */
const MAX_BOOK_BYTES = 20 * 1024 * 1024;

const isDate = (value) => /^\d{4}-\d{2}-\d{2}$/.test(value);

/**
 * 布置 / 取消任务只给家长。
 *
 * 学生不能给自己布置任务，「取消」也不能给 —— 否则孩子读不下去时点一下
 * 就把家长布置的任务抹了，而家长端只会看到卡片消失，没人知道发生了什么。
 */
function requireParent(ctx, what) {
  if (ctx.role !== 'parent') throw forbidden(`只有家长可以${what}`);
}

/**
 * 这次请求操作的是哪个学生。
 *
 * ## 学生不传 `studentId` 就是「我自己」
 *
 * `requireVisibleStudent` 遇空值直接 400（那是为了拦住「家长没说是哪个孩子」
 * 这种真歧义）。但学生查自己的任务时，让他每次都显式带上自己的 id 是
 * 没有任何意义的仪式 —— 服务端本来就知道他是谁，而 `visibleStudents` 里
 * 只有他自己，也不可能因此越权。
 *
 * 家长仍然必须指定孩子：一个家长名下可能有好几个孩子，空值就是真歧义，
 * 400 比「猜一个」安全。
 */
export function studentScope(ctx, requested) {
  const one = String(requested ?? '').trim();
  if (one === '' && ctx.role === 'student') {
    return requireVisibleStudent(ctx.visibleStudents, ctx.userId);
  }
  return requireVisibleStudent(ctx.visibleStudents, one);
}

/**
 * 解析某学生可用的 ima 上下文（凭证 + 知识库 id）。
 *
 * ⚠️ 11-07 改口径：ima 是**可选能力**，「没开通 / 没配密钥 / 表没迁移 /
 * 凭证解不开 / 没有 KB」都不是错误，一律返回 null。调用方自己决定怎么呈现：
 *   · 书库列表（页面加载自动打）→ 2xx + `connected:false`，客户端藏入口；
 *   · 导入（家长主动点）→ 回一句温和的 400，绝不回 500。
 */
export async function resolveReaderContext(client, ctx, studentId) {
  try {
    // ⭐ 11-08：只认「这个学生自己的 KB」。
    // 旧实现先按登录人反推 owner，再退到「owner 名下第一个 KB」——
    // 多孩子家庭里会拿到哥哥的库，症状是「家长明明传了书，弟弟选书页里没有」；
    // 父母共管时还会从没配凭证的那位家长读起，直接整块降级。
    const cfg = await getStudentImaConfig(client, studentId);
    if (!cfg?.kbId) return null;
    if (!shouldSync(cfg.status)) return null;

    const secret = process.env.IMA_CREDENTIAL_SECRET;
    if (!secret) return null;

    let plain;
    try {
      plain = decryptCredential(
        { clientidEnc: cfg.clientidEnc, apikeyEnc: cfg.apikeyEnc },
        secret,
      );
    } catch (e) {
      console.error(`[reading] ima 凭证解密失败（按未开通处理）: ${e?.message ?? e}`);
      return null;
    }

    // `fetchImpl` 一并带出去：生产是全局 fetch，测试注入成假实现。
    return {
      ownerUserId: cfg.ownerUserId,
      clientId: plain.clientId,
      apiKey: plain.apiKey,
      kbId: cfg.kbId,
      fetchImpl: ctx.fetchImpl,
    };
  } catch (e) {
    // 表没建（42P01）/ RLS / 连接池异常：与「没开通」同等对待。
    console.error(`[reading] ima 上下文不可用（按未开通处理）: ${e?.message ?? e}`);
    return null;
  }
}

/**
 * 取一个文件夹下的全部条目（翻页）。
 *
 * ⚠️ 终止条件只认 `is_end`。ima 在**最后一页**会同时给出
 * `is_end: true` 和一个非空的 `next_cursor`，如果按「cursor 空了就停」
 * 来写，就会再请求一次、拿到 0 条、然后停 —— 多一次往返看起来无害，
 * 但真正的坑在反向：只看 cursor 非空就继续，遇到「is_end=true 且
 * cursor 非空」的响应会**无限翻**（实测踩过，2026-11-07）。
 */
export async function listAllEntries(ctx, { kbId, folderId = '' }) {
  const all = [];
  let cursor = '';
  for (let page = 0; page < 40; page += 1) {
    const json = await getKnowledgeList({
      clientId: ctx.clientId,
      apiKey: ctx.apiKey,
      fetchImpl: ctx.fetchImpl,
      kbId,
      folderId,
      cursor,
      limit: 50,
    });
    const data = json?.data ?? json;
    const list = data?.knowledge_list ?? data?.knowledgeList ?? [];
    all.push(...list);
    cursor = data?.next_cursor ?? data?.nextCursor ?? '';
    if (data?.is_end === true || cursor === '' || list.length === 0) break;
  }
  return all;
}

/**
 * 沿给定路径逐层找文件夹，找不到返回 null（而不是抛错）。
 *
 * 导出给 `routes/word.js` 复用（`教学资料/Wordlist`）：翻页只认 `is_end`
 * 这条契约只有一处实现，两边都不会写歪。
 *
 * ⚠️ 12 日实测：虫子建的目录是 `教学资料/wordlist`（小写 w），而代码找的是
 * `Wordlist` —— `includes` 区分大小写，于是「目录明明有、导入区说没有」。
 * 目录名是人手敲的，大小写不该决定功能在不在，所以这里统一**忽略大小写**。
 */
export async function findFolderByPath(reader, names) {
  let parentId = '';
  let found = null;
  for (const name of names) {
    const wanted = String(name).toLowerCase();
    const list = await listAllEntries(reader, { kbId: reader.kbId, folderId: parentId });
    found = list.find(
      (item) => Number(item.media_type ?? item.mediaType) === IMA_MEDIA_TYPE_FOLDER
        && String(item.title ?? '').toLowerCase().includes(wanted),
    );
    if (!found) return null;
    parentId = found.media_id;
  }
  return found;
}

/** 沿 `教学资料/English` 找到那个文件夹。 */
function findReadingFolder(reader) {
  return findFolderByPath(reader, READING_FOLDER_PATH);
}

/** 去掉末尾的 `.md`。书名用文件名，不用 MD 首行 —— 首行经常是丛书名。 */
function bookTitleFromFileName(title, fallback) {
  const one = String(title ?? '').trim();
  if (one === '') return fallback;
  return one.replace(/\.(md|markdown)$/i, '').trim() || fallback;
}

/** 行 → 客户端书对象。字段名与 SQL 列一一对应，不在两处各起一个名字。 */
function toBook(row) {
  return {
    id: row.id,
    title: row.title,
    author: row.author,
    intro: row.intro,
    lessonCount: Number(row.lesson_count ?? 0),
    source: row.source,
    sourcePath: row.source_path,
    createdAt: row.created_at,
  };
}

function toTask(row, readLessonNos) {
  const progress = taskProgress({
    readLessonNos,
    totalLessons: Number(row.total_lessons ?? 0),
    status: row.status,
  });
  return {
    id: row.id,
    bookId: row.book_id,
    bookTitle: row.book_title ?? '',
    dailyTarget: Number(row.daily_target ?? 1),
    status: row.status,
    doneLessons: progress.doneLessons,
    totalLessons: progress.totalLessons,
    nextLessonNo: progress.nextLessonNo,
    finished: progress.finished,
    startedAt: row.started_at,
    completedAt: row.completed_at,
    // 「今天读了几篇」由客户端按本地日算 —— 服务端不替它决定「今天」是哪天
    // （R4：UTC 的今天在晚上 8 点后会错一天）。
    readLessonNos: [...readLessonNos].sort((a, b) => a - b),
  };
}

/**
 * 可导入的书：ima `教学资料/English` 下的 md 文件。
 *
 * 同时把「已导入过哪几本」标出来，让家长一眼看到 —— 否则他会反复导入同一本，
 * 而服务端只能靠 `source_media_id` 去重，界面上毫无反馈。
 */
export async function listAvailableBooks(client, ctx, query) {
  const studentId = studentScope(ctx, query?.studentId);
  const folderPath = READING_FOLDER_PATH.join('/');

  // 没开通 ima 是**正常状态**：回 2xx，让客户端把「从 ima 导入」整块藏起来。
  // 以前这里抛 400/500，家长一进「英文阅读」页就是一条红色横幅。
  const reader = await resolveReaderContext(client, ctx, studentId);
  if (!reader) {
    return { connected: false, folderPath, books: [], reason: 'ima_unavailable' };
  }

  // 已经连上、只是这次没读到（ima 抖动 / 401 / 超时）：入口要留着给家长
  // 刷新重试，所以仍是 connected:true，只带一个 reason 让界面说灰话。
  try {
    const folder = await findReadingFolder(reader);
    if (!folder) return { connected: true, folderPath, books: [] };

    const entries = await listAllEntries(reader, { kbId: reader.kbId, folderId: folder.media_id });
    const imported = await client.query(
      `select id, source_media_id, title, lesson_count
         from reading_book where student_id = $1 and source_media_id <> ''`,
      [studentId],
    );
    const importedByMedia = new Map(imported.rows.map((row) => [row.source_media_id, row]));

    const books = entries
      .filter((item) => Number(item.media_type ?? item.mediaType) === IMA_MEDIA_TYPE_MARKDOWN)
      .map((item) => {
        const hit = importedByMedia.get(item.media_id);
        return {
          mediaId: item.media_id,
          fileName: item.title ?? '',
          title: bookTitleFromFileName(item.title, '未命名书籍'),
          importedBookId: hit?.id ?? null,
          importedLessonCount: hit ? Number(hit.lesson_count ?? 0) : 0,
        };
      });

    return { connected: true, folderPath, books };
  } catch (e) {
    console.error(`[reading] 读 ima 目录失败（保留入口，按这次没读到处理）: ${e?.message ?? e}`);
    return { connected: true, folderPath, books: [], reason: 'ima_read_error' };
  }
}

/**
 * 导入一本书：下载 md → 切课 → 落库。
 *
 * 幂等：同一个 `mediaId` 再次导入直接返回已有的书（不重复建、不覆盖已有进度）。
 * 家长多点了两下不该出现两本一模一样的书。
 */
export async function importBook(client, ctx, body) {
  const studentId = studentScope(ctx, body?.studentId);
  const mediaId = requireText(body?.mediaId, 'mediaId');

  const existing = await client.query(
    `select * from reading_book where student_id = $1 and source_media_id = $2`,
    [studentId, mediaId],
  );
  if (existing.rowCount > 0) {
    return { book: toBook(existing.rows[0]), imported: false, skipped: [] };
  }

  const reader = await resolveReaderContext(client, ctx, studentId);
  if (!reader) {
    // 只有家长真的点了「导入」才走得到这里（没开通时入口是隐藏的）。
    // 给一句能照做的说明，但绝不能是 500：可选功能不可用不是服务端故障。
    throw badRequest('当前没有可用的 ima 知识库，暂时不能导入新书；已经导入的书照常可以阅读和布置。');
  }

  // 文件名：从 ima 条目里取，用于兜底书名与记录来源路径。
  let fileName = String(toText(body?.fileName) ?? '').trim();
  if (fileName === '') {
    const folder = await findReadingFolder(reader);
    if (folder) {
      const entries = await listAllEntries(reader, { kbId: reader.kbId, folderId: folder.media_id });
      const hit = entries.find(
        (item) => item.media_id === mediaId
          && Number(item.media_type ?? item.mediaType) === IMA_MEDIA_TYPE_MARKDOWN,
      );
      fileName = String(hit?.title ?? '');
    }
  }
  if (fileName === '') fileName = 'reading.md';

  const { bytes } = await downloadMedia({
    clientId: reader.clientId,
    apiKey: reader.apiKey,
    fetchImpl: ctx.fetchImpl,
    kbId: reader.kbId,
    mediaId,
    maxBytes: MAX_BOOK_BYTES,
  });

  const parsed = parseBook(bytes.toString('utf8'), { title: bookTitleFromFileName(fileName, '') });
  if (parsed.lessons.length === 0) {
    throw badRequest(
      '这本书里没有识别到任何一课。阅读书需要按「Lesson 1 / Lesson 2 …」分课，'
        + `当前文件（${fileName}）里没找到这种标题。`,
    );
  }

  const bookId = `rb_${randomUUID()}`;
  const title = String(toText(body?.title) ?? '').trim()
    || bookTitleFromFileName(fileName, parsed.title);

  await client.query(
    `insert into reading_book
       (id, student_id, owner_user_id, title, author, intro, source, source_media_id, source_path, lesson_count)
     values ($1, $2, $3, $4, '', '', 'ima', $5, $6, $7)`,
    [
      bookId,
      studentId,
      ctx.userId,
      title,
      mediaId,
      `${READING_FOLDER_PATH.join('/')}/${fileName}`,
      parsed.lessons.length,
    ],
  );

  // 96 行一次插入：循环 insert 在云上 RDS 是 96 次网络往返（约 3~5 秒），
  // 而家长点完「导入」就在等这一下。jsonb_to_recordset 只花一个来回。
  const payload = parsed.lessons.map((lesson) => ({
    id: `rl_${bookId}_${String(lesson.lessonNo).padStart(3, '0')}`,
    lesson_no: lesson.lessonNo,
    title: lesson.title,
    title_zh: lesson.titleZh,
    body: lesson.body,
    vocabulary: JSON.stringify(lesson.vocabulary),
    translation: lesson.translation,
    char_count: lesson.charCount,
  }));
  await client.query(
    `insert into reading_lesson
       (id, book_id, student_id, lesson_no, title, title_zh, body, vocabulary, translation, char_count)
     select x.id, $1, $2, x.lesson_no, x.title, x.title_zh, x.body, x.vocabulary::jsonb, x.translation, x.char_count
       from jsonb_to_recordset($3::jsonb) as x(
         id text, lesson_no int, title text, title_zh text, body text,
         vocabulary text, translation text, char_count int
       )`,
    [bookId, studentId, JSON.stringify(payload)],
  );

  const row = await client.query('select * from reading_book where id = $1', [bookId]);
  return {
    book: toBook(row.rows[0]),
    imported: true,
    // 解析不出正文的课如实回报。**不从书里静默删掉它们**：总篇数变成 95 而家长
    // 以为 96，最后会出现「读到 96/95 还没读完」这种无法解释的状态。
    skipped: parsed.skipped,
  };
}

/** 已导入的书（家长端选书、学生端显示进度都用它）。 */
export async function listBooks(client, ctx, query) {
  const studentId = studentScope(ctx, query?.studentId);
  const r = await client.query(
    `select b.*,
            (select count(*) from reading_task t
              where t.book_id = b.id and t.status = 'active') as active_tasks
       from reading_book b
      where b.student_id = $1
      order by b.created_at desc`,
    [studentId],
  );
  return {
    books: r.rows.map((row) => ({
      ...toBook(row),
      activeTaskCount: Number(row.active_tasks ?? 0),
    })),
  };
}

/** 某本书的课目录（不含正文，正文单独取 —— 96 篇正文一次发下去是 100KB+）。 */
export async function listLessons(client, ctx, query) {
  const bookId = requireText(query?.bookId, 'bookId');
  const studentId = studentScope(ctx, query?.studentId);
  const r = await client.query(
    `select lesson_no, title, title_zh, char_count
       from reading_lesson
      where book_id = $1 and student_id = $2
      order by lesson_no`,
    [bookId, studentId],
  );
  return {
    lessons: r.rows.map((row) => ({
      lessonNo: Number(row.lesson_no),
      title: row.title,
      titleZh: row.title_zh,
      charCount: Number(row.char_count ?? 0),
    })),
  };
}

/** 单课全文（正文 + 词汇 + 译文）。 */
export async function getLesson(client, ctx, query) {
  const bookId = requireText(query?.bookId, 'bookId');
  const lessonNo = toInt(query?.lessonNo, 'lessonNo');
  if (!lessonNo || lessonNo < 1) throw badRequest('lessonNo 必须是正整数');
  const studentId = studentScope(ctx, query?.studentId);

  const r = await client.query(
    `select lesson_no, title, title_zh, body, vocabulary, translation, char_count
       from reading_lesson
      where book_id = $1 and student_id = $2 and lesson_no = $3`,
    [bookId, studentId, lessonNo],
  );
  if (r.rowCount === 0) throw notFound('这一课不存在');
  const row = r.rows[0];
  return {
    lesson: {
      lessonNo: Number(row.lesson_no),
      title: row.title,
      titleZh: row.title_zh,
      body: row.body,
      vocabulary: Array.isArray(row.vocabulary) ? row.vocabulary : [],
      translation: row.translation,
      charCount: Number(row.char_count ?? 0),
    },
  };
}

/** 任务列表：进行中的在前，已结束的在后（按布置时间倒序）。 */
export async function listTasks(client, ctx, query) {
  const studentId = studentScope(ctx, query?.studentId);
  const r = await client.query(
    `select t.*, b.title as book_title
       from reading_task t
       join reading_book b on b.id = t.book_id
      where t.student_id = $1
      order by case when t.status = 'active' then 0 else 1 end, t.created_at desc`,
    [studentId],
  );
  const logs = await client.query(
    `select task_id, lesson_no from reading_log where student_id = $1`,
    [studentId],
  );
  const byTask = new Map();
  for (const row of logs.rows) {
    const list = byTask.get(row.task_id) ?? [];
    list.push(Number(row.lesson_no));
    byTask.set(row.task_id, list);
  }
  return {
    tasks: r.rows.map((row) => toTask(row, byTask.get(row.id) ?? [])),
  };
}

/**
 * 打卡记录：**哪天读了第几篇**。
 *
 * ## 为什么这条查询必须存在
 *
 * `reading_log` 一直是数据的唯一真相，但接口只把 `lesson_no` 拼回任务进度，
 * **日期和篇名都被丢掉了**。于是学生打完卡只看到「3/96 篇」，家长那边连
 * 「今天读了没有」都查不到 —— 打卡对孩子就退化成了一次点按钮。
 *
 * ## 日期用 `day::text`，不用 JS Date
 *
 * `day` 是 DATE。`pg` 会把它解析成**服务端本地时区**的 0 点，`JSON.stringify`
 * 再转成 UTC ISO（中国时区下变成前一天 16:00Z）。客户端 `substring(0,10)`
 * 拿到的是**前一天**，而且没有任何报错。与 `checkin.js` 里 `quiz_date::text`
 * 同一条规矩。
 *
 * ## 时间窗是可选的，没给就是「全部」
 *
 * `coerce.toTimeWindow` 那条注释里写的原则：**不给默认窗口**。默认最近 90 天
 * 会把更早的记录从结果里悄悄抹掉，而列表看起来是完整的 —— 用户会认为
 * 「那时候没读」。所以 `from`/`to` 都可选，缺省即不限；给了就必须是合法
 * 纯日期，且 `from > to` 直接 400（回空会被读成「那天没打卡」）。
 */
export async function listLogs(client, ctx, query) {
  const studentId = studentScope(ctx, query?.studentId);
  const from = toDate(query?.from, 'from');
  const to = toDate(query?.to, 'to');
  if (from && to && from > to) {
    // 纯日期是定长 ISO，字符串比较与日期比较等价。
    throw badRequest(`from 不能晚于 to（收到 from=${from}、to=${to}）`);
  }

  // `limit=0` = 全量（「近 7 天」这种小窗口没必要分页）。
  // 其余情况没给就 50 —— 与 calendar 那套「列表满着、用户知道还有更多」一致。
  const rawLimit = toInt(query?.limit, 'limit');
  if (rawLimit !== null && rawLimit < 0) throw badRequest('limit 不能是负数');
  const limit = rawLimit === null ? 50 : rawLimit;
  const offset = toInt(query?.offset, 'offset') ?? 0;
  if (offset < 0) throw badRequest('offset 不能是负数');

  const where = `l.student_id = $1
      and ($2::text is null or l.day >= $2::date)
      and ($3::text is null or l.day <= $3::date)`;
  const params = [studentId, from, to];

  const counted = await client.query(
    `select count(*)::int as total from reading_log l where ${where}`,
    params,
  );
  const total = Number(counted.rows[0]?.total ?? 0);

  // 课名走 left join：正文被重导入删过的老记录仍要能显示（只少一个标题），
  // 不能因为拿不到标题就整条消失。
  const r = await client.query(
    `select l.id, l.task_id, l.book_id, l.lesson_no, l.day::text as day, l.read_at,
            b.title as book_title,
            le.title as lesson_title, le.title_zh as lesson_title_zh
       from reading_log l
       join reading_book b on b.id = l.book_id
       left join reading_lesson le
              on le.book_id = l.book_id and le.lesson_no = l.lesson_no
      where ${where}
      order by l.day desc, l.read_at desc, l.lesson_no desc
      ${limit > 0 ? `limit ${limit} offset ${offset}` : ''}`,
    params,
  );

  const logs = r.rows.map((row) => ({
    id: row.id,
    taskId: row.task_id,
    bookId: row.book_id,
    bookTitle: row.book_title ?? '',
    lessonNo: Number(row.lesson_no),
    lessonTitle: row.lesson_title ?? '',
    lessonTitleZh: row.lesson_title_zh ?? '',
    day: row.day,
    readAt: row.read_at,
  }));

  return { logs, total, hasMore: offset + logs.length < total };
}

/**
 * 布置任务：一本书一个进行中的任务。
 *
 * 已经有一个进行中的同书任务时**返回那一个**而不是报错 —— 家长双击、
 * 或者两个孩子用同一本书，都不该看到一句「已经布置过了」的红色提示。
 * 数据库那条部分唯一索引是最后一道闸，这里先把它变成一次正常返回。
 */
export async function createTask(client, ctx, body) {
  requireParent(ctx, '布置阅读任务');
  const studentId = studentScope(ctx, body?.studentId);
  const bookId = requireText(body?.bookId, 'bookId');

  const book = await client.query(
    `select id, title, lesson_count from reading_book where id = $1 and student_id = $2`,
    [bookId, studentId],
  );
  if (book.rowCount === 0) throw notFound('这本书不存在');
  const lessonCount = Number(book.rows[0].lesson_count ?? 0);
  if (lessonCount <= 0) throw badRequest('这本书还没有内容，无法布置阅读任务');

  const active = await client.query(
    `select t.*, b.title as book_title
       from reading_task t join reading_book b on b.id = t.book_id
      where t.book_id = $1 and t.status = 'active'`,
    [bookId],
  );
  if (active.rowCount > 0) {
    const logs = await client.query(`select lesson_no from reading_log where task_id = $1`, [active.rows[0].id]);
    return {
      task: toTask(active.rows[0], logs.rows.map((row) => Number(row.lesson_no))),
      created: false,
    };
  }

  const id = `rt_${randomUUID()}`;
  await client.query(
    `insert into reading_task
       (id, student_id, book_id, owner_user_id, daily_target, total_lessons, status)
     values ($1, $2, $3, $4, 1, $5, 'active')`,
    [id, studentId, bookId, ctx.userId, lessonCount],
  );

  const row = await client.query(
    `select t.*, b.title as book_title
       from reading_task t join reading_book b on b.id = t.book_id
      where t.id = $1`,
    [id],
  );
  return { task: toTask(row.rows[0], []), created: true };
}

/**
 * 打卡：读了一篇。
 *
 * ## 幂等 + 顺序
 *
 * 重复点同一课：返回 `already=true` 且**不报错**（断网重试、双端点两次都会这样），
 * 进度不变。跳着读：400，并告诉客户端下一篇是第几课 —— 只说「顺序不对」
 * 的话，学生要自己数到哪了。
 *
 * ## 读完自动收尾
 *
 * 最后一课落库的同一次请求里把任务置 `done`。不放在「下次查询时顺手修」：
 * 那样学生交完最后一篇返回列表，卡片还写着「还剩 1 篇」—— 得等他下次进来
 * 才变，而那时他已经在想「是不是没记录上」了。
 */
export async function readLesson(client, ctx, body) {
  const studentId = studentScope(ctx, body?.studentId);
  const taskId = requireText(body?.taskId, 'taskId');
  const lessonNo = toInt(body?.lessonNo, 'lessonNo');
  if (!lessonNo || lessonNo < 1) throw badRequest('lessonNo 必须是正整数');

  const day = String(toText(body?.day) ?? '').trim();
  if (day !== '' && !isDate(day)) throw badRequest('day 必须是 yyyy-MM-dd');

  const task = await client.query(
    `select t.*, b.title as book_title
       from reading_task t join reading_book b on b.id = t.book_id
      where t.id = $1 and t.student_id = $2`,
    [taskId, studentId],
  );
  if (task.rowCount === 0) throw notFound('阅读任务不存在');
  const row = task.rows[0];

  if (row.status !== 'active') {
    // 已读完 / 已取消：如实返回当前状态，不报错。客户端据此把卡片画成终态。
    const logs = await client.query(`select lesson_no from reading_log where task_id = $1`, [taskId]);
    return {
      already: true,
      taskDone: row.status === 'done',
      task: toTask(row, logs.rows.map((item) => Number(item.lesson_no))),
    };
  }

  const logs = await client.query(`select lesson_no from reading_log where task_id = $1`, [taskId]);
  const readLessonNos = logs.rows.map((item) => Number(item.lesson_no));
  const plan = planLessonRead({
    readLessonNos,
    totalLessons: Number(row.total_lessons ?? 0),
    lessonNo,
  });

  if (plan.action === 'out_of_order') {
    throw badRequest(`请按顺序读：下一篇是第 ${plan.expectedLessonNo} 课`);
  }

  if (plan.action === 'read') {
    await client.query(
      // day 由客户端给（R4：服务端按 UTC 算会在晚上 8 点后记错一天）。
      // 老客户端不传时退到今天 —— 兜底一次，但绝不因此拒收整条打卡：
      // 「读了没记上」比「日期差一天」严重得多。
      `insert into reading_log (id, task_id, student_id, book_id, lesson_no, day)
       values ($1, $2, $3, $4, $5, coalesce($6::date, current_date))
       on conflict (task_id, lesson_no) do nothing`,
      [`rg_${randomUUID()}`, taskId, studentId, row.book_id, lessonNo, day || null],
    );
  }

  if (plan.taskDone) {
    await client.query(
      `update reading_task set status = 'done', completed_at = now(), updated_at = now()
        where id = $1 and status = 'active'`,
      [taskId],
    );
  }

  const fresh = await client.query(
    `select t.*, b.title as book_title
       from reading_task t join reading_book b on b.id = t.book_id
      where t.id = $1`,
    [taskId],
  );
  const after = await client.query(`select lesson_no from reading_log where task_id = $1`, [taskId]);
  return {
    already: plan.action === 'already',
    taskDone: plan.taskDone,
    task: toTask(fresh.rows[0], after.rows.map((item) => Number(item.lesson_no))),
  };
}

/** 取消任务。只允许家长取消，且只取消进行中的（已结束的原样返回）。 */
export async function cancelTask(client, ctx, body) {
  requireParent(ctx, '取消阅读任务');
  const studentId = studentScope(ctx, body?.studentId);
  const taskId = requireText(body?.taskId, 'taskId');

  const task = await client.query(
    `select t.*, b.title as book_title
       from reading_task t join reading_book b on b.id = t.book_id
      where t.id = $1 and t.student_id = $2`,
    [taskId, studentId],
  );
  if (task.rowCount === 0) throw notFound('阅读任务不存在');

  if (task.rows[0].status === 'active') {
    await client.query(
      `update reading_task set status = 'cancelled', updated_at = now() where id = $1`,
      [taskId],
    );
  }
  const fresh = await client.query(
    `select t.*, b.title as book_title
       from reading_task t join reading_book b on b.id = t.book_id
      where t.id = $1`,
    [taskId],
  );
  const logs = await client.query(`select lesson_no from reading_log where task_id = $1`, [taskId]);
  return { task: toTask(fresh.rows[0], logs.rows.map((row) => Number(row.lesson_no))) };
}
