class ChatMessageModel {
  final String id;
  final String relationshipId;
  final String senderId;
  final String receiverId;
  final String content;
  final DateTime createdAt;
  final bool isRead;

  const ChatMessageModel({
    required this.id,
    required this.relationshipId,
    required this.senderId,
    required this.receiverId,
    required this.content,
    required this.createdAt,
    required this.isRead,
  });

  bool isMine(String userId) => senderId == userId;
}
