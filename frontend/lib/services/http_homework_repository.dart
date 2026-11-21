import '../models/homework_image_model.dart';
import '../models/homework_model.dart';
import '../models/photo_usage.dart';
import '../repositories/homework_repository.dart';
import 'data_api_client.dart';
import 'data_row_values.dart';

/// 作业与作业照片的**服务端实现**（`HomeworkRepository` 的第二个实现）。
///
/// 本地那份在 `local_database_service.dart`。两者实现同一个契约，所以
/// `StudentController` / `ParentController` 一行都不用改 —— 这正是当初抽
/// L2 接口的目的（`doc/architecture-refactor-plan.md`）。
///
/// ## 三处「照搬本地写法就会错」的地方
///
/// **① 归属不再由客户端声明。** 本地实现里 `studentId` 是行里的一列，写什么就是什么。
/// 服务端从 token 推导可见集合，body 里的 `studentId` 只是**在这个集合里挑一个**
/// （`narrowToVisible`），越界直接 403。所以这里不必（也不能）自己判断权限。
///
/// **② id 由服务端生成，所以插入要回填。** 服务端会忽略客户端送的 id 并自己
/// 生成一个 —— 插入之后，**调用方手里那个对象的 id 已经不对了**。而作业 id 是
/// 照片 / 提交 / 批改 / 错题明细共同的关联键，错位的后果是一串静默失败
/// （照片挂在服务端不存在的作业上、提交的 update 打空被吞掉）。
/// 处置：`insertHomework` **返回服务端那一行**，由调用方（`StudentController`）
/// 用它替换掉本地那份的 id。这是契约与 R2 的裂缝补上的地方，
/// 背景见 `doc/cloud-migration-plan.md` 的 §R2 与 §4.5。
///
/// **③ 布尔与时区**见 `data_row_values.dart`。最危险的一条是 `aiEnabled`：
/// 服务端回 `true`，而本地那套写法 `(row['aiEnabled'] as num?)?.toInt() == 1`
/// 遇到 `true` 会得到 `false` —— 静默地。
class HttpHomeworkRepository implements HomeworkRepository {
  HttpHomeworkRepository(this._api);

  final DataApiClient _api;

  /// `userRole` 被**刻意忽略**。
  ///
  /// 本地实现里它决定「学生看全部 / 家长看自己结伴的孩子」。服务端把这件事
  /// 收归 token：`ctx.students` 就是当前身份看得见的学生集合。
  /// 换句话说，这个参数在云端实现里**没有可信来源**，留着只是为了让签名不变。
  @override
  Future<List<HomeworkItem>> queryHomework(String userRole) async {
    final items = await _api.getItems('/data/homework');
    return items.map(_fromRow).toList();
  }

  /// 取指定孩子的作业。
  ///
  /// 单个 id 时下推成服务端过滤（越界会 403，这正是我们想要的**显式失败**）；
  /// 多个 id 时拉一次可见集合再在内存里筛 —— 服务端只有一个 `studentId` 参数，
  /// 发 N 次请求换来的只是 N 次往返，而家长端通常只有一个孩子在当前视图里。
  @override
  Future<List<HomeworkItem>> queryHomeworkByStudentIds(List<String> studentIds) async {
    if (studentIds.isEmpty) return const [];
    if (studentIds.length == 1) {
      final items = await _api.getItems('/data/homework', query: {'studentId': studentIds.first});
      return items.map(_fromRow).toList();
    }
    final wanted = studentIds.toSet();
    final items = await _api.getItems('/data/homework');
    return items.map(_fromRow).where((h) => wanted.contains(h.studentId)).toList();
  }

  /// 新建作业，**返回服务端落库后的那一行**。
  ///
  /// 服务端的 `POST /data/homework` 一直带着 `returning *`，所以新 id
  /// 本来就在响应里 —— 只是早先的契约把它丢掉了（见类注释 ②）。
  /// 现在把它交出去：调用方拿到的是**服务端真实的那一行**，不是自己拼的那个。
  ///
  /// ⚠️ 值必须走 [_fromRow] 解析，不能拿 `item.copyWith(id: …)` 糊一个 ——
  /// 服务端还定了 `status`（新作业一律 `pending`，客户端传什么都无所谓）
  /// 与 `wrongCount`（显式写 0），这些**也是真实值的一部分**。
  @override
  Future<HomeworkItem> insertHomework(HomeworkItem item, String userRole) async {
    final data = await _api.postJson('/data/homework', body: {
      'studentId': item.studentId,
      'title': item.title,
      'subject': item.subject,
      'imageUrl': item.imageUrl,
      'dueAt': utcTimeText(item.dueAt),
      'estimatedMinutes': item.estimatedMinutes.toInt(),
      'needsGrading': item.needsGrading,
      'aiEnabled': item.aiEnabled,
      'summary': item.summary,
    });
    final created = data['item'];
    if (created is! Map) {
      // 回了 200 却没给行 —— 那就是**一个拿不到 id 的作业**，后面照片、
      // 提交、批改全都会挂在一个错的键上。宁可在这一步断掉：
      // 与 `RemoteImageStorageService` 里「上传成功但没给存储键」同一处置。
      throw const DataApiException(
        code: 'bad_response',
        message: '作业已创建，但服务端没有返回这一行（拿不到它的 id，后续照片与提交都会对不上）',
      );
    }
    return _fromRow(Map<String, dynamic>.from(created));
  }

  /// 按掩码局部更新。
  ///
  /// 键的语义**原样**保留（「键出现 = 这次要写它」在 JSON 上仍然可表达：
  /// 键不存在 vs 值为 null 是两件事），而服务端的 `updateHomework`
  /// 正是照这个语义实现的。
  ///
  /// ⚠️ 值**不能**用 `toMap()`，要用 [HomeworkPatch.toWireMap]：
  /// `toMap()` 是**本地库**的编码（时间不带时区、布尔写 `1/0`），照搬到网络上
  /// 会得到一次 400「submittedAt 必须带时区」。这条不是猜的 ——
  /// `test/cloud_live_test.dart` 第一次跑起来就撞在它上面。
  ///
  /// ⚠️ 也不能顺手补上 `title` / `subject` 这类字段：服务端会把「掩码里出现了
  /// 不该出现的字段」当成一次 400 —— 那种写法的效果是**整行覆盖**，
  /// 而它是静默的（见 `routes/homework.js` 的 `assertKnownFields`）。
  @override
  Future<void> updateHomework(HomeworkPatch patch) async {
    final mask = patch.toWireMap();
    if (mask.isEmpty) return; // 契约：空掩码调用方跳过、实现也要容忍
    await _api.postJson('/data/homework/update', body: {'id': patch.id, ...mask});
  }

  /// 单张的简写。**用量在这里被丢掉** —— 它的调用方（`ocr_service` 的批改链路）
  /// 只用返回值本身，不关心还剩几张。要提示用量的调用方走 [saveHomeworkImages]。
  @override
  Future<List<HomeworkImageModel>> saveHomeworkImage(HomeworkImageModel image) async =>
      (await saveHomeworkImages([image])).images;

  /// 写照片行，**返回服务端落库后的那些行**。
  ///
  /// ## 为什么必须返回（这条曾经是「提交后照片看不到」的真因）
  ///
  /// 服务端的 `POST /data/homework/images` 一直有 `returning *`，而它的 `id`
  /// 是**服务端自己生成的**：`imageRow()` 里写死 `id: newId()`，请求里带的
  /// id 一律忽略 —— 与作业那条是同一规则（R2）。
  ///
  /// 而照片行的 `id` 是**唯一的读图键**（`GET /data/homework/images/file?id=`）。
  /// 把返回的行丢掉、让调用方继续用上传时那个本地占位 id，后果不是报错，
  /// 是**照片一片空白**：字节已经在服务端、行也在，按那个 id 却查不到它。
  /// 换个页签、返回都救不回来，只有重登（重走 `queryHomeworkImages`，
  /// 那时拿到的才是真 id）才看得见 —— 这正是真机反馈的形态。
  ///
  /// ## 拿不到 `items` 时为什么**不**抛（与 [insertHomework] 的差别）
  ///
  /// [insertHomework] 在那里断掉，是因为作业拿不到 id 之后**没有任何补救**：
  /// 照片、提交、批改会全挂在一个错的键上。照片这里不一样 —— 字节还在本进程
  /// 内存里（`RemoteImageStorageService._recentUploads` 按 `storageKey` 存着，
  /// `HomeworkImageReader` 会先命中它），所以退化成入参那份仍然**看得见**，
  /// 只是本会话之后不再成立。两处的取舍不同，是数据不同，不是标准松了。
  @override
  Future<SavedHomeworkImages> saveHomeworkImages(
    List<HomeworkImageModel> images,
  ) async {
    if (images.isEmpty) {
      return const SavedHomeworkImages(images: <HomeworkImageModel>[]);
    }
    final data = await _api.postJson('/data/homework/images', body: {
      'studentId': images.first.studentId,
      // `createdAt` 必须去掉：它是**记录时间**（R3），服务端说了算，
      // 而 `toMap()` 天然会带上它 —— 原样转发会得到一次 400，
      // 报错文案是「照片对象里出现了不认识的字段：createdAt」。
      'images': images.map((e) => e.toMap()..remove('createdAt')).toList(),
    });
    final stored = _rowsOf(data['items']);
    return SavedHomeworkImages(
      images: stored.isEmpty ? images : stored,
      // 解析不出就是 null（服务端版本旧、或响应形状变了）—— 这**不该影响
      // 提交成功**，只是这次少一句「快满了」提示。理由见 `PhotoUsage` 的类文档。
      photoUsage: PhotoUsage.tryParse(data['photoUsage']),
    );
  }

  /// 响应里的 `items` → 模型列表。形状不对就交回空表，由调用方决定退路。
  List<HomeworkImageModel> _rowsOf(Object? raw) {
    if (raw is! List) return const <HomeworkImageModel>[];
    return raw
        .whereType<Map>()
        .map((row) => HomeworkImageModel.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  @override
  Future<List<HomeworkImageModel>> queryHomeworkImages(String studentId) async {
    final items = await _api.getItems('/data/homework/images', query: {'studentId': studentId});
    return items.map(HomeworkImageModel.fromMap).toList();
  }

  @override
  Future<List<HomeworkImageModel>> queryHomeworkImagesByHomeworkId(String homeworkId) async {
    final items = await _api.getItems('/data/homework/images', query: {'homeworkId': homeworkId});
    return items.map(HomeworkImageModel.fromMap).toList();
  }

  @override
  Future<void> deleteHomework(String id) async {
    await _api.postJson('/data/homework/delete', body: {'id': id});
  }

  @override
  Future<void> deleteHomeworkImagesByHomeworkId(String homeworkId) async {
    await _api.postJson('/data/homework/images/delete', body: {'homeworkId': homeworkId});
  }

  @override
  Future<int> countHomeworkImages(String homeworkId) async {
    final data = await _api.getJson('/data/homework/images/count', query: {'homeworkId': homeworkId});
    return intOf(data['count']);
  }

  /// 服务端的行 → [HomeworkItem]。
  ///
  /// 与本地那份 `_homeworkFromMap` 形状一致，差别只在**取值方式**：
  /// 布尔要认 `true/false`、时间要转到本地时区。见 `data_row_values.dart`。
  HomeworkItem _fromRow(Map<String, dynamic> row) {
    return HomeworkItem(
      id: textOf(row['id']),
      title: textOf(row['title']),
      subject: textOf(row['subject']),
      imageUrl: textOf(row['imageUrl']),
      dueAt: timeOr(row['dueAt'], DateTime.now()),
      estimatedMinutes: doubleOf(row['estimatedMinutes']),
      // 缺列时当 0 = 从未计时。⚠️ 不能按 `estimatedMinutes` 兜底：
      // 那会把「计划用时」伪装成「实际用时」，而两者恰恰是要对比着看的。
      actualSeconds: intOf(row['actualSeconds']),
      status: HomeworkStatus.parse(row['status'] as String?),
      wrongCount: intOf(row['wrongCount']),
      aiEnabled: boolOf(row['aiEnabled'], fallback: true),
      // 缺列时当成「需要批改」—— 与本地实现取反的那个默认值一致：
      // 不能因为一次读不到就把一份已批过的卷子变成「无需批改」。
      needsGrading: boolOf(row['needsGrading'], fallback: true),
      userRole: textOf(row['userRole'], fallback: 'student'),
      studentId: textOf(row['studentId']),
      submittedAt: timeOf(row['submittedAt']),
      checkedAt: timeOf(row['checkedAt']),
      score: intOrNull(row['score']),
      summary: textOf(row['summary']),
      imageCount: intOf(row['imageCount']),
      submitBatchId: textOf(row['submitBatchId']),
      gradingSource: textOf(row['gradingSource'], fallback: GradingSource.none),
    );
  }
}
