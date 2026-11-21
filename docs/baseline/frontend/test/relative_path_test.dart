import 'package:flutter_test/flutter_test.dart';
import 'package:easy_learn_app/core/storage/relative_path.dart';

/// 这些用例与后端 `backend/shared/paths.js`、数据库 `CREATE DOMAIN rel_path`
/// 是同一套规则。改动任一侧，三处必须同步。
void main() {
  group('RelativePath.assertRelative — 正例', () {
    test('标准存储键通过', () {
      const key = '20261121/stu_001/ab12cd34.jpg';
      expect(RelativePath.assertRelative(key), key);
    });

    test('ima 逻辑路径通过', () {
      const key = '教学资料/English/Unit1.md';
      expect(RelativePath.assertRelative(key), key);
    });

    test('允许空串（历史行 / 未上传完）', () {
      expect(RelativePath.assertRelative(''), '');
    });

    test('首尾空白被去掉', () {
      expect(RelativePath.assertRelative('  a/b.jpg  '), 'a/b.jpg');
    });
  });

  group('RelativePath.assertRelative — 反例', () {
    void expectRejected(String value) {
      expect(
        () => RelativePath.assertRelative(value),
        throwsA(isA<RelativePathException>()),
        reason: '应拒绝：$value',
      );
    }

    test('Unix 绝对路径', () => expectRejected('/var/data/a.jpg'));
    test('Windows 盘符（正斜杠）', () => expectRejected('D:/data/a.jpg'));
    test('Windows 盘符 + 反斜杠', () => expectRejected(r'C:\data\a.jpg'));
    test('UNC / 反斜杠开头', () => expectRejected(r'\\nas\share\a.jpg'));
    test('路径穿越', () => expectRejected('20261121/../../etc/passwd'));
    test('反斜杠分隔', () => expectRejected(r'20261121\stu_001\a.jpg'));
    test('指向目录而不是文件', () => expectRejected('20261121/'));
  });

  group('RelativePath.normalize', () {
    test('反斜杠转 / 并去掉前导 ./', () {
      expect(
        RelativePath.normalize(r'./20261121\stu_001\a.jpg'),
        '20261121/stu_001/a.jpg',
      );
    });

    test('压缩重复斜杠', () {
      expect(RelativePath.normalize('a//b///c.jpg'), 'a/b/c.jpg');
    });

    test('归一化后仍要走同一套校验', () {
      expect(
        () => RelativePath.normalize('./../../etc/passwd'),
        throwsA(isA<RelativePathException>()),
      );
    });
  });

  group('判据有效性（证伪用）', () {
    // 这几条专门盯住「规则被悄悄放宽」：若有人把 CHECK 删了、或前端放宽了
    // 判断，下面会变红。全绿本身不是判据，能变红才是。
    test('isRelative 对绝对路径返回 false', () {
      expect(RelativePath.isRelative('/tmp/a.jpg'), isFalse);
      expect(RelativePath.isRelative('C:/a.jpg'), isFalse);
      expect(RelativePath.isRelative('../a.jpg'), isFalse);
    });

    test('isRelative 对标准键返回 true', () {
      expect(RelativePath.isRelative('20261121/stu_001/a.jpg'), isTrue);
    });
  });
}
