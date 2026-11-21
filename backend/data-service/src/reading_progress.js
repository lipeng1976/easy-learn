/**
 * 「这次打卡该不该算」的判定 —— 纯函数，不碰数据库。
 *
 * ## 为什么不写在路由里
 *
 * 这三条规则一旦写错，症状全是**静默的**：
 *
 *   · 允许跳读 → 学生从第 1 课直接点第 96 课，进度 96/96，任务「读完了」
 *     而书根本没读。没有任何报错，家长看到的是「孩子三天读完一本书」。
 *   · 重复打卡不判重 → 同一课点五次，进度涨 5，任务提前结束。
 *   · 读完不自动收尾 → 进度 96/96 但任务永远 `active`，学生端一直挂着
 *     「还有一篇」，家长端永远等不到「已读完」。
 *
 * 放在路由里就得靠「假 client 返回我预期的行」来测，而那种测试经常
 * 连字段名都对不上却照样是绿的（这类假绿在本工程栽过好几次）。
 * 抽成纯函数之后，判据是「给一组已读课号，应该得到什么动作」，
 * 与 SQL 长什么样无关。
 */

/**
 * 一次打卡请求应该产生什么结果。
 *
 * @param {object} input
 * @param {Iterable<number>} input.readLessonNos 这个任务**已经**读完的课号
 * @param {number} input.totalLessons 任务要求的总篇数（布置时的快照）
 * @param {number} input.lessonNo 这次要打卡的课号
 * @returns {{action:'read'|'already'|'out_of_order', lessonNo:number,
 *            expectedLessonNo:number, doneLessons:number, taskDone:boolean}}
 */
export function planLessonRead({ readLessonNos, totalLessons, lessonNo }) {
  const read = new Set([...readLessonNos].map(Number));
  const total = Number(totalLessons) || 0;

  // 「下一篇该读哪篇」= 从 1 开始第一个没读的课号。
  //
  // 不能用 `max(read) + 1`：万一历史数据里有一课中途被删（换版书重导），
  // max+1 会让中间那个洞永远补不上，学生卡在那儿反复点同一课。
  let expected = 1;
  while (read.has(expected)) expected += 1;

  if (read.has(lessonNo)) {
    return {
      action: 'already',
      lessonNo,
      expectedLessonNo: expected,
      doneLessons: read.size,
      // 幂等请求同样要如实报告「任务是不是已经读完了」：客户端重复点击
      // 时如果这里返回 false，界面会把一张已完成的卡重新画成进行中。
      taskDone: total > 0 && read.size >= total,
    };
  }

  if (lessonNo !== expected) {
    return {
      action: 'out_of_order',
      lessonNo,
      expectedLessonNo: expected,
      doneLessons: read.size,
      taskDone: false,
    };
  }

  const doneLessons = read.size + 1;
  return {
    action: 'read',
    lessonNo,
    expectedLessonNo: expected + 1,
    doneLessons,
    taskDone: total > 0 && doneLessons >= total,
  };
}

/**
 * 任务的下一步 —— 给客户端画卡片用。
 *
 * `nextLessonNo` 为 `null` 表示**没有下一篇可读**（读完了 / 任务被取消）。
 * 用 `null` 而不是 `0`：0 是一个合法课号的相邻值，判空写错就变成
 * 「从第 0 课开始」这种没人看得懂的状态。
 *
 * ⚠️ `finished`（读完了）与「有没有下一篇」是两件事：被取消的任务
 * 没有下一篇，但它不算「读完」—— 混成一个布尔值的话，家长端会把
 * 一张被自己撤掉的任务画成「已读完」。
 */
export function taskProgress({ readLessonNos, totalLessons, status }) {
  const read = new Set([...readLessonNos].map(Number));
  const total = Number(totalLessons) || 0;
  let next = 1;
  while (read.has(next)) next += 1;

  const finished = status === 'done' || (total > 0 && read.size >= total);
  const hasNext = status === 'active' && !finished && next <= total;
  return {
    doneLessons: read.size,
    totalLessons: total,
    nextLessonNo: hasNext ? next : null,
    finished,
  };
}
