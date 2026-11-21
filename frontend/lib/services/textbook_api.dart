import '../models/textbook.dart';
import 'data_api_client.dart';

/// 教材仓库：ima 骨架 MD → 章节 → 出题范围。
///
/// ## 读降级 / 写响亮（与词表、阅读同一口径）
///
/// `listBooks` 恒 2xx：没开通 ima 回 `connected:false`，客户端把「从 ima
/// 导入」整块藏起来，已导入的书照常可选。**这是可选能力，不是错误状态。**
///
/// `importBook` 是家长按了按钮在等结果，失败必须抛 —— 静默成功会让他
/// 以为导进去了，配置页却选不到那本书。
///
/// ## 为什么不把「解析」放客户端
///
/// 解析器在服务端（`src/textbook_import.js`）：**导入只发生一次**，
/// 放在服务端就不用两条实现（Dart 一份、Node 一份）去守同一个格式，
/// 而格式一旦漂，症状是「有的书导得进来、有的导不进来」。
abstract class TextbookRepository {
  Future<TextbookLibrary> listBooks({
    required String studentId,
    required String subject,
  });

  Future<List<TextbookUnit>> listUnits({
    required String studentId,
    required String bookId,
  });

  Future<TextbookBook> importBook({
    required String studentId,
    required String subject,
    required String mediaId,
    String fileName = '',
    String grade = '',
    String term = '',
  });

  /// 删掉一本已导入的教材（换版 / 导错了重来）。
  ///
  /// 返回 `scopeCleared`：服务端发现当前范围正指着这本书时已经清掉了它，
  /// 调用方必须同步清掉本地 `_scope`，否则家长随后点「保存范围」会把一个
  /// 已经不存在的 bookId 写回去（界面显示教材、出题却退回手填范围）。
  Future<bool> deleteBook({
    required String studentId,
    required String bookId,
  });
}

class HttpTextbookRepository implements TextbookRepository {
  const HttpTextbookRepository(this._api);

  final DataApiClient _api;

  @override
  Future<TextbookLibrary> listBooks({
    required String studentId,
    required String subject,
  }) async {
    final data = await _api.getJson(
      '/data/textbook/books',
      query: <String, Object?>{'studentId': studentId, 'subject': subject},
    );
    return TextbookLibrary.fromJson(data);
  }

  @override
  Future<List<TextbookUnit>> listUnits({
    required String studentId,
    required String bookId,
  }) async {
    final data = await _api.getJson(
      '/data/textbook/units',
      query: <String, Object?>{'studentId': studentId, 'bookId': bookId},
    );
    final raw = data['units'];
    if (raw is! List) return const <TextbookUnit>[];
    return raw
        .whereType<Map>()
        .map((one) => TextbookUnit.fromJson(Map<String, dynamic>.from(one)))
        .toList();
  }

  @override
  Future<TextbookBook> importBook({
    required String studentId,
    required String subject,
    required String mediaId,
    String fileName = '',
    String grade = '',
    String term = '',
  }) async {
    final data = await _api.postJson(
      '/data/textbook/import',
      body: <String, Object?>{
        'studentId': studentId,
        'subject': subject,
        'mediaId': mediaId,
        'fileName': fileName,
        'grade': grade,
        'term': term,
      },
    );
    final book = data['book'];
    return TextbookBook.fromJson(
      book is Map ? Map<String, dynamic>.from(book) : const <String, dynamic>{},
    );
  }

  @override
  Future<bool> deleteBook({
    required String studentId,
    required String bookId,
  }) async {
    final data = await _api.postJson(
      '/data/textbook/delete',
      body: <String, Object?>{
        'studentId': studentId,
        'bookId': bookId,
      },
    );
    return data['scopeCleared'] == true;
  }
}

/// 没连云端：没有书，也不能导入（写要响亮失败）。
class UnavailableTextbookRepository implements TextbookRepository {
  const UnavailableTextbookRepository();

  @override
  Future<TextbookLibrary> listBooks({
    required String studentId,
    required String subject,
  }) async =>
      TextbookLibrary.empty;

  @override
  Future<List<TextbookUnit>> listUnits({
    required String studentId,
    required String bookId,
  }) async =>
      const <TextbookUnit>[];

  @override
  Future<TextbookBook> importBook({
    required String studentId,
    required String subject,
    required String mediaId,
    String fileName = '',
    String grade = '',
    String term = '',
  }) async {
    throw StateError('没有连接数据服务，教材导入不了');
  }

  @override
  Future<bool> deleteBook({
    required String studentId,
    required String bookId,
  }) async {
    throw StateError('没有连接数据服务，教材删不了');
  }
}
