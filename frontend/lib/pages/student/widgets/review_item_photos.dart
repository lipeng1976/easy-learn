import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../constants/app_colors.dart';
import '../../../models/homework_image_model.dart';
import '../../../models/review_model.dart';
import '../../../widgets/homework_image_viewer.dart';

/// 卷内某道题的**原题照片**。
///
/// ── 为什么快照页必须有它 ──────────────────────────────────────────────
///
/// 导出 PDF 那条路一直印原题照片（`ReviewController._mistakeImageBytes`），
/// 而屏幕上的快照页从来没渲染过图。于是同一份卷子出现**两个版本**：
/// 印出来的纸有图，家长/孩子在 App 里点开的「同一份卷子」只有题干文字 ——
/// 而错题里的图往往正是题目的全部信息（一道几何题把条件全画在图里，
/// 只留一行「如图」等于没有题目）。
///
/// 所以这里刻意与 PDF 取同一个来源（`review_mistake_image` + 同一个
/// `HomeworkImageReader`），保证「纸上有图 ⟺ 屏幕上有图」。
///
/// ⚠️ 读不到时给**有文字的占位**，不给空白框：空白框看起来像
/// 「这道题本来就没有图」，而这里的事实是「这张图这次没取到」。
class ReviewItemPhotos extends StatefulWidget {
  const ReviewItemPhotos({
    super.key,
    required this.mistakeId,
    required this.loader,
    this.tileSize = 96,
  });

  /// 卷内快照带过来的 `mistakeId`。为空说明这是一道没有来源错题的题
  /// （理论上不该出现），直接不渲染。
  final String mistakeId;

  /// 由调用方注入取图方式：学生端走 `ReviewController`，家长端走
  /// 本地直读。两处**共用同一套渲染**，避免「家长端看不到、学生端看得到」。
  final Future<List<ReviewMistakeImage>> Function(String mistakeId) loader;

  final double tileSize;

  @override
  State<ReviewItemPhotos> createState() => _ReviewItemPhotosState();
}

class _ReviewItemPhotosState extends State<ReviewItemPhotos> {
  static const String _endpoint = '/data/review/mistake-images/file';

  late Future<List<ReviewMistakeImage>> _future = _load();

  Future<List<ReviewMistakeImage>> _load() {
    if (widget.mistakeId.isEmpty) {
      return Future<List<ReviewMistakeImage>>.value(const []);
    }
    return widget.loader(widget.mistakeId);
  }

  @override
  void didUpdateWidget(covariant ReviewItemPhotos oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 列表复用 State 时 `mistakeId` 会变：不重新取，第二道题会一直显示
    // 第一道题的照片 —— 图不会报错，只会**张冠李戴**。
    if (oldWidget.mistakeId != widget.mistakeId) {
      _future = _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ReviewMistakeImage>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Padding(
            padding: const EdgeInsets.only(top: 10),
            child: SizedBox(
              height: widget.tileSize,
              child: const Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          );
        }
        if (snapshot.hasError) {
          // 出错也要说出来 —— 静默缩成 0 高度，用户会以为「这道题没配图」。
          return const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              '原题照片暂时读不到（不影响作答与批改）',
              style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
            ),
          );
        }
        final images = snapshot.data ?? const <ReviewMistakeImage>[];
        if (images.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '原题照片 · 点图看大图',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: widget.tileSize,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: images.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) => _PhotoTile(
                    image: images[index],
                    endpoint: _endpoint,
                    size: widget.tileSize,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    required this.image,
    required this.endpoint,
    required this.size,
  });

  final ReviewMistakeImage image;
  final String endpoint;
  final double size;

  @override
  Widget build(BuildContext context) {
    final model = HomeworkImageModel(
      id: image.id,
      studentId: image.studentId,
      homeworkId: null,
      storageKey: image.storageKey,
      fileName: '',
      fileSize: image.fileSize,
      mimeType: image.mimeType,
      ocrStatus: '',
      ocrText: '',
      createdAt: image.createdAt ?? DateTime.now(),
      sortOrder: image.sortOrder,
    );
    return FutureBuilder<Uint8List?>(
      future: HomeworkImageReader.load(model, endpoint: endpoint),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) {
          return Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: const Text(
              '读不到',
              style: TextStyle(fontSize: 10.5, color: AppColors.textMuted),
            ),
          );
        }
        return GestureDetector(
          onTap: () => showDialog<void>(
            context: context,
            builder: (context) => Dialog(
              backgroundColor: Colors.black,
              insetPadding: const EdgeInsets.all(10),
              child: InteractiveViewer(
                maxScale: 4,
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              bytes,
              width: size,
              height: size,
              fit: BoxFit.cover,
              // ⛔ 少了这一行就是一个内存炸弹：`Image.memory` 默认按**原始像素**
              // 解码，手机拍的题图一张 4000×3000 ≈ 48 MB 位图。一份卷子 10 道题
              // 就是 480 MB —— 而屏幕上只需要 96 像素一块。
              // 按 3 倍屏给目标宽度，既清楚又不至于把内存吃掉。
              cacheWidth: (size * 3).round(),
            ),
          ),
        );
      },
    );
  }
}
