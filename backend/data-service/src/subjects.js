/**
 * 科目白名单：**一处定义，两处引用**。
 *
 * ⚠️ 必须与客户端 `HomeworkItemNormalizer.subjectNames` 逐字一致（`其他` 也在内）。
 * 客户端那份由 `kSubjectNames` 兜住（`test/subject_board_test.dart` 断言十个字面量），
 * 服务端这份由 `test/subject-scope.test.js` 逐字断言。
 *
 * ## 为什么从 `routes/subject.js` 里搬出来
 *
 * 教材导入（`routes/textbook.js`）也要校验科目，而 `routes/subject.js` 已经
 * 依赖 `routes/checkin.js`（取错题候选）。如果教材再反过来 import subject，
 * 就成了 `subject → checkin → textbook → subject` 的环 —— ESM 能跑，但
 * 静态分析会报「初始化顺序未定义」，而这类错误只在某些入口顺序下才出现。
 * 白名单本身没有依赖，单独一个文件就没有环。
 *
 * `routes/subject.js` 仍然 `export { SUBJECTS }`，对外形状不变。
 */
export const SUBJECTS = [
  '语文',
  '数学',
  '英语',
  '物理',
  '化学',
  '生物',
  '历史',
  '地理',
  '政治',
  '其他',
];

export const SUBJECT_SET = new Set(SUBJECTS);
