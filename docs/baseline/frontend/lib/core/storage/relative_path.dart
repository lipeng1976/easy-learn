/// ★ 相对路径规则（客户端侧）—— 与后端 `backend/shared/paths.js`、
/// 数据库 `CREATE DOMAIN rel_path` **逐条对应**。
///
/// 前端只做校验与归一化，**不拼绝对路径**：
/// 附件根目录只在服务端 STORAGE_ROOT 配置，客户端只持有相对路径字符串。
/// 客户端拿到的附件字节走 `GET /data/attachments/:id`，从不传路径。

class RelativePathException implements Exception {
  const RelativePathException(this.message);
  final String message;

  @override
  String toString() => 'RelativePathException: $message';
}

class RelativePath {
  const RelativePath._();

  static const String errorCode = 'ERR_INVALID_PATH';

  /// 合法则原样返回；不合法抛 RelativePathException。
  /// 不做「自动修正」——静默修正会让错误数据在库里活下来。
  static String assertRelative(String value) {
    final v = value.trim();
    if (v.isEmpty) return '';
    if (v.startsWith('/') || v.startsWith('\\')) {
      throw RelativePathException('不允许绝对路径：$v');
    }
    if (RegExp(r'^[A-Za-z]:').hasMatch(v)) {
      throw RelativePathException('不允许盘符路径：$v');
    }
    if (v.contains('\\')) {
      throw RelativePathException('路径分隔符必须统一为 /：$v');
    }
    if (v.contains('..')) {
      throw RelativePathException('不允许 .. 上跳：$v');
    }
    if (v.endsWith('/')) {
      throw RelativePathException('路径必须指向文件而不是目录：$v');
    }
    return v;
  }

  /// 归一化（旧数据 / 外部输入用）：反斜杠→/、去前导 ./、压缩重复斜杠。
  /// 新数据一律直接 assertRelative。
  static String normalize(String value) {
    var v = value.trim().replaceAll('\\', '/');
    while (v.startsWith('./')) {
      v = v.substring(2);
    }
    v = v.replaceAll(RegExp(r'/{2,}'), '/');
    return assertRelative(v);
  }

  static bool isRelative(String value) {
    try {
      assertRelative(value);
      return true;
    } on RelativePathException {
      return false;
    }
  }
}
