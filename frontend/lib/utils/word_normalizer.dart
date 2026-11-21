// 单词清洗口径的**客户端单点定义**。
//
// ⚠️ 服务端 `serverless/data-service/src/word_import.js` 有一份同规则实现。
// 两边测试共用同一组 golden vectors（`test/word_normalizer_test.dart` 与
// `test/word-import.test.js`），改规则必须同时改两边样本 —— 否则漂移的表现
// 是「选项里出现两个正确答案」，没人会收到报错。
//
// 客户端主要用 normalizeWord 做干扰项去重；primaryMeaning 只用于
// 「服务端下发值缺失」时的兜底，正常链路一律以服务端 primaryMeaning 为准。

/// trim → 小写 → 去首尾标点。ASCII 集合是刻意的：Dart / JS 两边行为一致。
String normalizeWord(String word) => word
    .trim()
    .toLowerCase()
    .replaceFirst(RegExp(r'^[^0-9a-z]+'), '')
    .replaceFirst(RegExp(r'[^0-9a-z]+$'), '');

/// 词性前缀：`n. ` / `v ` / `adj. 好的`；整行只有 `n.` 时也算清洗干净。
final RegExp _posPrefix = RegExp(
  r'^(?:n|v|adj|adv|prep|conj|pron|num|art|int)\.?(?:\s+|$)',
  caseSensitive: false,
);

/// 多义项分隔符：只取首义，避免一道题有两个正确答案。
final RegExp _meaningSplit = RegExp(r'[；;，,]');

String primaryMeaning(String meaning) => meaning
    .split(_meaningSplit)
    .first
    .trim()
    .replaceFirst(_posPrefix, '')
    .trim();
