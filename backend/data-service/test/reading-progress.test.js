import assert from 'node:assert/strict';
import test from 'node:test';

import { planLessonRead, taskProgress } from '../src/reading_progress.js';

/**
 * 「这次打卡该不该算」。
 *
 * 四条规则错了都不会报错，只会让家长看到一个不可能的数字：
 *   · 允许跳读 → 三天读完一本书；
 *   · 不判重 → 同一课点五次，进度涨 5；
 *   · 读完不收尾 → 96/96 还挂着「还剩 1 篇」；
 *   · 用 `max(已读)+1` 算下一篇 → 中间有洞就永远补不上。
 */

test('顺序读：接下一课，进度加一', () => {
  const plan = planLessonRead({ readLessonNos: [1, 2], totalLessons: 5, lessonNo: 3 });
  assert.equal(plan.action, 'read');
  assert.equal(plan.doneLessons, 3);
  assert.equal(plan.taskDone, false);
  assert.equal(plan.expectedLessonNo, 4);
});

test('跳读：拒绝，并告诉客户端下一篇是第几课', () => {
  const plan = planLessonRead({ readLessonNos: [1], totalLessons: 5, lessonNo: 4 });
  assert.equal(plan.action, 'out_of_order');
  assert.equal(plan.expectedLessonNo, 2);
  // 拒绝时进度不能动 —— 返回 3 就等于「拒了但还是算了」。
  assert.equal(plan.doneLessons, 1);
  assert.equal(plan.taskDone, false);
});

test('重复读：幂等，不涨进度也不报错', () => {
  const plan = planLessonRead({ readLessonNos: [1, 2, 3], totalLessons: 5, lessonNo: 2 });
  assert.equal(plan.action, 'already');
  assert.equal(plan.doneLessons, 3);
  assert.equal(plan.taskDone, false);
});

test('读完最后一课：同一次请求里就要判定任务完成', () => {
  const plan = planLessonRead({ readLessonNos: [1, 2, 3, 4], totalLessons: 5, lessonNo: 5 });
  assert.equal(plan.action, 'read');
  assert.equal(plan.doneLessons, 5);
  assert.equal(plan.taskDone, true);
});

test('重复点最后一课：仍然要如实报告「任务已完成」', () => {
  // 断网重试的形态：第一次其实已经落库了，第二次是重复请求。
  // 这里若返回 taskDone:false，客户端会把一张已完成的卡重新画成进行中。
  const plan = planLessonRead({ readLessonNos: [1, 2, 3, 4, 5], totalLessons: 5, lessonNo: 5 });
  assert.equal(plan.action, 'already');
  assert.equal(plan.taskDone, true);
});

test('中间有洞：下一篇是洞里那一课，不是最大的那课 +1', () => {
  // 换版重导等历史原因造成的缺口。用 `max+1` 会让第 3 课永远读不到。
  const plan = planLessonRead({ readLessonNos: [1, 2, 4], totalLessons: 5, lessonNo: 5 });
  assert.equal(plan.action, 'out_of_order');
  assert.equal(plan.expectedLessonNo, 3);

  const fix = planLessonRead({ readLessonNos: [1, 2, 4], totalLessons: 5, lessonNo: 3 });
  assert.equal(fix.action, 'read');
});

test('总篇数为 0 时不能判定完成', () => {
  // 0 篇的书不该存在（导入时就拒了），但万一有，不能显示「已读完」。
  const plan = planLessonRead({ readLessonNos: [], totalLessons: 0, lessonNo: 1 });
  assert.equal(plan.taskDone, false);
});

test('taskProgress：读完 / 未读完 / 有洞 三种形态的 nextLessonNo', () => {
  assert.deepEqual(
    taskProgress({ readLessonNos: [1, 2], totalLessons: 4, status: 'active' }),
    { doneLessons: 2, totalLessons: 4, nextLessonNo: 3, finished: false },
  );

  // 全部读完但状态还没更新（例如并发下的下一次读）—— 仍然算完成，
  // 不能因为 status 还是 active 就再给一个「下一篇」。
  assert.deepEqual(
    taskProgress({ readLessonNos: [1, 2, 3, 4], totalLessons: 4, status: 'active' }),
    { doneLessons: 4, totalLessons: 4, nextLessonNo: null, finished: true },
  );

  assert.deepEqual(
    taskProgress({ readLessonNos: [1, 3], totalLessons: 4, status: 'active' }),
    { doneLessons: 2, totalLessons: 4, nextLessonNo: 2, finished: false },
  );

  // 取消的任务不再给「下一篇」：否则学生端会一直催他读一本家长已经撤掉的书。
  assert.deepEqual(
    taskProgress({ readLessonNos: [1], totalLessons: 4, status: 'cancelled' }),
    { doneLessons: 1, totalLessons: 4, nextLessonNo: null, finished: false },
  );
});
