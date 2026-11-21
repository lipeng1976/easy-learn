import 'package:easy_learn_app/models/relationship_model.dart';
import 'package:easy_learn_app/models/user_profile_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('profile stores student details and multi-select hobbies', () {
    const profile = UserProfileModel(
      userId: 'stu_test',
      name: '小明',
      gender: '男',
      grade: '六年级',
      hobbies: ['阅读', '编程'],
      bio: '喜欢探索新知识',
    );

    expect(profile.toMap()['hobbies'], '阅读,编程');
    expect(profile.toMap()['grade'], '六年级');
  });

  test('relationship is inactive until the student accepts', () {
    final pending = RelationshipModel(
      id: 'rel_test',
      studentId: 'stu_test',
      parentId: 'teacher_test',
      senderId: 'teacher_test',
      studentName: '小明',
      parentName: '李老师',
      status: RelationshipStatus.pending,
    );
    final active = RelationshipModel(
      id: 'rel_test',
      studentId: 'stu_test',
      parentId: 'teacher_test',
      senderId: 'teacher_test',
      studentName: '小明',
      parentName: '李老师',
      status: RelationshipStatus.active,
    );

    expect(pending.isActive, isFalse);
    expect(active.isActive, isTrue);
  });
}
