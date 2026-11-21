enum RelationshipStatus { pending, active, rejected, removed }

class RelationshipModel {
  final String id;
  final String studentId;
  final String parentId;
  final String senderId;
  final String studentName;
  final String parentName;
  final RelationshipStatus status;

  RelationshipModel({
    required this.id,
    required this.studentId,
    required this.parentId,
    required this.senderId,
    required this.studentName,
    required this.parentName,
    required this.status,
  });

  bool get isActive => status == RelationshipStatus.active;

  bool isSentBy(String userId) => senderId == userId;
}
