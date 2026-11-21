import 'package:easy_learn_app/models/chat_message_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('chat message knows whether it belongs to the current user', () {
    final message = ChatMessageModel(
      id: 'msg_test',
      relationshipId: 'rel_test',
      senderId: 'stu_test',
      receiverId: 'teacher_test',
      content: '今天作业已完成',
      createdAt: DateTime.now(),
      isRead: false,
    );

    expect(message.isMine('stu_test'), isTrue);
    expect(message.isMine('teacher_test'), isFalse);
  });
}
