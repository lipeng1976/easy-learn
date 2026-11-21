import '../models/homework_image_model.dart';
import '../models/homework_model.dart';
import '../models/photo_usage.dart';

/// 写照片行的结果 —— 落库后的行 **+** 服务端给的用量。
///
/// ## 为什么用量跟行一起回来，而不是另发一次请求
///
/// 「照片快满了」这句提示只有在**行写完之后**才准确：写之前那个数字
/// 少了本次这几张。而写行这一步恰好是唯一知道「这次写了几张」的地方，
/// 顺手带回用量是零成本；另发一次请求去查的话，两次之间还有一个窗口。
///
/// ## 本地实现回 null
///
/// 本地模式**没有配额**（那是服务端的规则），所以 [photoUsage] 是 null。
/// 调用方把 null 当「这次没有用量可提示」—— 与解析失败走同一条路，
/// 不必为本地模式另写一个分支。
class SavedHomeworkImages {
  const SavedHomeworkImages({required this.images, this.photoUsage});

  /// 落库后的照片行（服务端换过 id 的那一份）。
  final List<HomeworkImageModel> images;

  /// 服务端给的用量；本地实现、或响应里没有这个字段时为 null。
  final PhotoUsage? photoUsage;
}

/// 一次作业更新**要写哪些字段**，用显式的字段掩码表达。
///
/// ## 为什么不能用「可选命名参数 + `null`」表达（陷阱 ②）
///
/// 老签名 `updateHomework({String? summary, int? score, ...})` 靠 `null`
/// 表示「本次不改这个字段」。在 Dart 里这能工作，因为「没传」和「传了 null」
/// 由调用方语法决定，编译期就分开了。
///
/// **但这份区分活不过一次序列化。** 改成云端接口后要发 JSON，而
/// `{"summary": null}` 与「`summary` 这个键不存在」在标准 JSON 库里是
/// **同一个东西**（都反序列化成 `null`）。于是「清空批改结果」这个意图
/// 会在网络边界上被静默抹掉 —— 症状是**重新提交作业后家长仍看到上一次的旧分数**，
/// 不报错、不崩、只是数字不对。
///
/// 所以这里的掩码不靠 `null` 推断，而是**由"被 set 过"这个事实本身给出**：
/// 只有显式赋值过的字段才会进入 [toMap]，`toMap()` 的结果就是可以直接上行的
/// 字段集合。调用方**无法**表达出歧义 —— 想说「把这个字段写空」就赋空值，
/// 想说「别动它」就不碰它。
///
/// 用 setter 而不是构造参数也是同一个理由：构造参数是「可选的」，
/// 而「可选」正是那个会在序列化时丢信息的性质。
///
/// ```dart
/// final patch = HomeworkPatch(id: homeworkId)
///   ..status = HomeworkStatus.finished
///   ..checkedAt = now
///   ..score = 92;
/// ```
class HomeworkPatch {
  HomeworkPatch({required this.id});

  /// 要更新的作业 id。
  final String id;

  /// 只装「被显式写过的字段」。`null` 值会被保留 —— 它表示「写成空」。
  ///
  /// ⚠️ 时间字段存的是 **`DateTime` 本身**，不是已经格式化好的字符串。
  /// 理由见 [toMap] / [toWireMap]：同一个时间点在两种传输上要写成两种文本，
  /// 而在 setter 里就格式化等于**把传输格式烧进数据**，之后再也分不开。
  final Map<String, Object?> _values = <String, Object?>{};

  /// 本次要写的字段名。上云时它就是掩码，**不要**用 `toMap().keys` 之外的推断代替它。
  Set<String> get touchedFields => _values.keys.toSet();

  /// 什么都没写。调用方可以据此跳过整次调用。
  bool get isEmpty => _values.isEmpty;

  set status(HomeworkStatus value) => _values['status'] = value.name;
  set wrongCount(int value) => _values['wrongCount'] = value;
  set imageUrl(String value) => _values['imageUrl'] = value;
  set submittedAt(DateTime value) => _values['submittedAt'] = value;
  set checkedAt(DateTime value) => _values['checkedAt'] = value;
  set score(int value) => _values['score'] = value;
  set summary(String value) => _values['summary'] = value;
  set imageCount(int value) => _values['imageCount'] = value;
  set submitBatchId(String value) => _values['submitBatchId'] = value;
  set gradingSource(String value) => _values['gradingSource'] = value;

  /// 实际用时（秒）。
  ///
  /// 与状态类字段不同，这个值**只会被专注计时写**，而且是「累计后的总量」，
  /// 不是增量：一次计时结束（或暂停）时把 `原有 + 本次` 整份写上去。
  ///
  /// ⚠️ 不做增量是刻意的。增量接口在网络重试下会**重复累加**
  /// （请求超时但服务端已写成功，客户端重发就是加两遍），
  /// 而这类错误在界面上只表现为「时间莫名变多了」——
  /// 学生会以为自己计时错了。整份覆盖是幂等的：重发多少次都是同一个数。
  set actualSeconds(int value) => _values['actualSeconds'] = value;

  /// `bool` 而不是 `bool?` —— 到了这里，「不改」已经由「不调用 setter」表达了，
  /// 所以 `false` 可以干干净净地只表示「要写进去的值 false」。
  ///
  /// 本地那份编码成 `1/0`（SQLite 没有布尔列），上行则原样发 `true/false` ——
  /// 两种编码各由 [toMap] / [toWireMap] 负责。
  set needsGrading(bool value) => _values['needsGrading'] = value;

  /// 作业内容与科目 —— 识别录错字之后，学生**唯一**的补救方式。
  ///
  /// ## 为什么这两个字段是后加的（2026-09-29）
  ///
  /// 服务端 `routes/homework.js` 里有两张表：`WRITABLE`（**新建**时可写）与
  /// `PATCH_SPEC`（**更新**时可写）。前者一直有 `title` / `subject`，后者
  /// **刻意没有** —— 因为更新是「键出现即写」的掩码，而客户端顺手把整个作业
  /// 对象发上来时，`title` / `subject` / `dueAt` 会一起被写回去，那不是
  /// 「改坏了几个字段」而是**整行覆盖**（服务端为此刻意用 400 拦住它们，
  /// 见该文件的长注释）。
  ///
  /// 代价是：**存完就再也改不了标题和科目**。而识别录入恰恰会认错字
  /// （`练字→练习` 25 次错 19 次，见 `doc/open-items.md` B27），学生核对时
  /// 若能改就没事，一旦点了「确认保存全部」发现错了，出路只剩「删了重录」。
  ///
  /// 所以口径改成：**这两个放开，其余照旧**。
  ///
  /// ⚠️ 整行覆盖的守卫**没有被削弱**：它防的是「一次写入一批不该由客户端决定的
  /// 字段」，而标题与内容本来就是学生的输入。`dueAt` / `status` / 批改结果
  /// 仍不在 `PATCH_SPEC` 里，一次误发整个对象依然会 400 —— 那正是要保住的行为。
  ///
  /// ⚠️ 服务端与本地实现**必须同时支持**：只加客户端的话，云端更新会回 400
  /// 「这些字段不能通过本端点写：title」，而本地模式却是好的 —— 症状是
  /// 「同一份改动，在家能用、在学校不能用」。
  set title(String value) => _values['title'] = value;
  set subject(String value) => _values['subject'] = value;

  /// 清空批改结果，让作业回到「尚未批改」。
  ///
  /// 单独一个方法而不是让调用方自己逐个赋空：这**四个字段必须一起清**。
  /// 少清 `gradingSource` 的话，重新提交的作业在批改完成之前会顶着一个
  /// 「离线参考结果」的标记 —— 而上一次的结果早就没了。
  ///
  /// 它写在最后会**覆盖**前面写过的同名字段，与老实现的顺序语义一致。
  void clearResult() {
    _values['checkedAt'] = null;
    _values['score'] = null;
    _values['summary'] = '';
    _values['gradingSource'] = GradingSource.none;
  }

  /// **本地库**的编码。`LocalDatabaseService` 直接把它交给 `db.update`。
  ///
  /// 时间是**本地时区的 ISO 文本、不带偏移量**，与库里已有的历史行一字不差 ——
  /// 改掉它会让本地模式里所有已存时间的显示整体偏移，而本地模式必须零行为变化。
  Map<String, Object?> toMap() => _render((t) => t.toIso8601String());

  /// **上行到服务端**的编码。
  ///
  /// 与服务端 `toTs()` 的契约一致（迁移计划 §R3）：**时间必须带时区**。
  /// 不带的那一类会被服务端直接 400 拒掉，而不是猜一个时区 ——
  /// 猜的代价是一整天的静默偏移，而那种错在演示里根本看不出来（谁的作业
  /// 早交了一天？）只会在「跨时区看同一份数据」时冒出来。
  ///
  /// 两处差异不只是时间：`needsGrading` 在本地写 `1/0`（SQLite 无布尔列），
  /// 上行发真布尔。所以这一份**不能**用 [toMap] 代替。
  Map<String, Object?> toWireMap() => _render(
        (t) => t.toUtc().toIso8601String(),
        encodeBool: (b) => b,
      );

  /// 按传输方式渲染掩码。键的顺序与写入顺序一致，`null` 原样保留。
  ///
  /// `encodeBool` 缺省时把布尔写成 `1/0`（本地库的表示法）。
  Map<String, Object?> _render(
    String Function(DateTime) encodeTime, {
    Object? Function(bool)? encodeBool,
  }) {
    return <String, Object?>{
      for (final e in _values.entries)
        e.key: switch (e.value) {
          final DateTime t => encodeTime(t),
          final bool b when encodeBool != null => encodeBool(b),
          final bool b => b ? 1 : 0,
          _ => e.value,
        },
    };
  }
}

/// 作业与作业照片的数据访问契约（L2）。
///
/// 只做「取出来 / 写回去」，不含业务判断 —— 什么时候算超时、照片该删几张、
/// 批改结果要不要清，都在 `StudentController`（L1）。
abstract class HomeworkRepository {
  /// 按角色取作业列表（`student` / `parent` 看到的范围不同）。
  Future<List<HomeworkItem>> queryHomework(String userRole);

  /// 一次取多个孩子的作业（家长端多孩子聚合用）。
  Future<List<HomeworkItem>> queryHomeworkByStudentIds(
    List<String> studentIds,
  );

  /// 新建作业，**返回落库之后真实的那一行**。
  ///
  /// ## ⚠️ 返回值不是装饰，是必需的
  ///
  /// 服务端会**忽略客户端送的 id 并自己生成一个**（迁移规则 R2）。所以
  /// 「插入之后，调用方手里那个对象的 id 已经不对了」—— 而作业 id 是
  /// **照片、提交、批改、错题明细**四处共同的关联键。不回填的后果不是一次
  /// 报错，而是一串**静默失败**，每一段单独看都「正常」：
  ///
  /// - 照片写进服务端时带着本地 id → 挂在一个**不存在的作业**上，
  ///   按作业查照片永远查不到（「照片看不到」）；
  /// - 提交时 `PATCH /data/homework` 打在本地 id 上 → 服务端 403
  ///   「找不到这份作业」，而调用链上的 `_safePersist` 把它吞了 →
  ///   界面显示已提交，刷新后回到未提交；
  /// - 重新查询列表（服务端那份用的是 uuid）之后，作业与照片对不上。
  ///
  /// 契约因此是：**返回落库后的那一行**。本地实现原样返回入参
  /// （id 本来就是客户端拼的，落库前后同一个），两个实现的语义一致 ——
  /// 调用方不必知道自己在哪一侧。
  ///
  /// 早先这个契约是 `Future<void>`，理由是「插入后不假装同步」。
  /// 那条理由只对了一半：不假装同步是对的，**但把服务端刚返回的新行丢掉
  /// 不是** —— 服务端的 `POST /data/homework` 一直有 `returning *`，
  /// 信息本来就在手上，只是没往外传。
  Future<HomeworkItem> insertHomework(HomeworkItem item, String userRole);

  /// 按 [HomeworkPatch] 的字段掩码局部更新。
  ///
  /// ⚠️ **契约要点**：只有 `patch.touchedFields` 里的字段会被写。
  /// 云端实现**必须原样转发这份掩码**，不许把它降级成一个「值为 null 就不写」的
  /// JSON 对象 —— 那正是陷阱 ② 的形态（见 [HomeworkPatch] 的说明）。
  ///
  /// 掩码为空时调用方应跳过本次调用，实现也要容忍它（直接返回）。
  Future<void> updateHomework(HomeworkPatch patch);

  /// 写入一份或多份照片记录，**返回落库后的那些行**。
  ///
  /// 契约与 [insertHomework] 完全相同，理由也是同一个：服务端的
  /// `POST /data/homework/images` 一直有 `returning *`，信息本来就在手上，
  /// 只是没往外传。而照片行的 `id` 是**唯一的读图键**
  /// （`GET /data/homework/images/file?id=`），
  /// 沿用客户端那个 id 的后果不是报错，是**照片一片空白**：
  /// 字节明明已经传上去了、行也写进去了，按那个 id 却查不到这一行。
  ///
  /// 为什么在照片这条路上后果更重：上传字节与写行是**两步**
  /// （见 `RemoteImageStorageService`），字节那一步返回的 `id` 本来就是
  /// 本地占位、服务端不认 —— 而写行这一步恰好是把真 id 拿回来的唯一机会。
  /// 丢掉它，「刚提交的照片」在本会话里就再也读不出来了，
  /// 只能靠重登（重走 `queryHomeworkImages`）才看得见。
  ///
  /// 本地实现原样返回入参（本地 id 本来就是最终的），两个实现语义一致。
  Future<List<HomeworkImageModel>> saveHomeworkImage(HomeworkImageModel image);

  /// 写入一批照片行，返回**落库后的行 + 服务端给的用量**。
  ///
  /// 用量是给「照片快满了」提示用的（见 [SavedHomeworkImages]）。做成一个
  /// 复合结果而不是多一个方法，是因为这两样东西**必须来自同一次请求** ——
  /// 拆成两次就会有「行已经写完了、拿到的还是旧用量」的窗口。
  Future<SavedHomeworkImages> saveHomeworkImages(
    List<HomeworkImageModel> images,
  );

  /// 某个孩子提交过的全部照片，按提交时间倒序。
  Future<List<HomeworkImageModel>> queryHomeworkImages(String studentId);

  Future<List<HomeworkImageModel>> queryHomeworkImagesByHomeworkId(
    String homeworkId,
  );

  Future<void> deleteHomeworkImagesByHomeworkId(String homeworkId);

  /// 删除一份作业 —— **连同它的照片行和它带出来的错题**。
  ///
  /// ## 为什么是「一份作业」而不是「一行作业」
  ///
  /// 服务端与本地库的 `homework` 表**都没有外键指向它**（服务端全库只有三条
  /// 外键，都指 `app_user` / `app_notification`）。所以「删掉作业那一行」
  /// 不会级联任何东西，留下的是**查不出来的孤儿**：照片行还在（配额照算）、
  /// 错题还在错题本里（点进去那个「来源作业」指向一份不存在的作业）。
  ///
  /// 所以这个方法的契约是「把这份作业整个从系统里拿掉」，
  /// 不是「删一张表里的一行」。
  ///
  /// ## 为什么必须是一个方法，而不是调用方编排三次
  ///
  /// 三个实现都把三件事放在**一次事务**里。客户端编排（删错题 → 删照片 →
  /// 删作业）拿不到这个性质：中途断网留下的是**半截删除**，
  /// 而界面上看不出删到了哪一步 —— 与「删一道错题必须一次动 5 张表」
  /// 是同一条理由（见 `ReviewRepository.deleteReviewMistake`）。
  ///
  /// ⚠️ **刻意不动的两样东西**：已发出的积分流水（账本，撤一笔余额就对不上）
  /// 与已发出的通知（「当时确实发生过」的凭据）。两者都不按作业反查，
  /// 所以删作业不会让它们报错：积分流水存的是 `reason` 文本，
  /// 通知点击是跳到对应 tab 而不是跳到那一条。
  ///
  /// ⚠️ **找不到、或不在可见集合里 ⇒ 必须抛错**（服务端回 403）。
  /// 不能当成「已经删了」静默放过 —— 那会让界面显示成功、刷新之后那条又回来。
  Future<void> deleteHomework(String id);

  Future<int> countHomeworkImages(String homeworkId);
}
