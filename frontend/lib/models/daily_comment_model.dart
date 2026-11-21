class DailyCommentModel {
  final String id;
  final String rating;
  final String content;
  final DateTime createdAt;
  final String studentId;

  DailyCommentModel({
    required this.id,
    required this.rating,
    required this.content,
    required this.createdAt,
    this.studentId = '',
  });
}
