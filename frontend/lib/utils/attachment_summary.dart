import '../constants/attachment_limits.dart';
import '../models/homework_image_model.dart';

/// 一组附件的「类型 + 数量」摘要，例如 `2 张照片 · 1 个视频`。
///
/// ## 为什么需要它
///
/// 家长端原来把附件**行数**直接说成「N 张照片」。孩子交的是视频时，
/// 家长看到「1 张照片」——数字是对的，说法是错的：他会以为孩子交的是
/// 一张静态照片，直到点开才发现是视频。而 `mimeType` 一直都在行里，
/// 类别从来不是未知信息。
///
/// ## 为什么集中在一个函数里
///
/// 「照片 / 音频 / 视频」这句话在家长端出现了 5 处（首页卡片、作业行、
/// 复习页、详情横幅、附件区标题）。各处自己拼字符串，加视频时就会漏掉
/// 一两处 —— 这个 bug 正是这么来的。量词与顺序只在 [AttachmentKind]
/// 与本函数里定义。
///
/// 空输入返回空串；调用方据此决定显示「未上传附件」还是数量。
String attachmentSummary(Iterable<HomeworkImageModel> images) {
  final counts = <AttachmentKind, int>{};
  var unknown = 0;

  for (final image in images) {
    final kind = AttachmentKind.ofMime(image.mimeType);
    if (kind == null) {
      // 归不了类也要**说出来**：凭空少一个会让「共 N 个」与缩略图数量对不上，
      // 而家长数得出来。
      unknown += 1;
    } else {
      counts[kind] = (counts[kind] ?? 0) + 1;
    }
  }

  final parts = <String>[
    // 按 enum 声明顺序（照片 → 音频 → 视频），不按数量排：
    // 同一份作业每次打开的词序应当一致，否则读起来像换了句话。
    for (final kind in AttachmentKind.values)
      if ((counts[kind] ?? 0) > 0) '${counts[kind]} ${kind.unit}${kind.label}',
  ];
  if (unknown > 0) parts.add('$unknown 个未知附件');

  return parts.join(' · ');
}
