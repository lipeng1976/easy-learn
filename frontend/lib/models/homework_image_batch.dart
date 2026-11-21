import 'homework_image_model.dart';

/// 一次作业提交产生的照片集合。
///
/// 学生可以「更正后重新提交」，于是同一份作业会有多批照片。
/// 家长端按批展示（第 1 次提交 / 更正后提交），既能看到原始作答，
/// 也能确认孩子真的改过了，而不是只看到一堆来源不明的图片。
class HomeworkImageBatch {
  const HomeworkImageBatch({
    required this.batchId,
    required this.submittedAt,
    required this.images,
  });

  final String batchId;
  final DateTime submittedAt;
  final List<HomeworkImageModel> images;

  int get count => images.length;

  /// 首图存储键，可用于列表缩略图。
  String get coverKey => images.isEmpty ? '' : images.first.storageKey;
}
