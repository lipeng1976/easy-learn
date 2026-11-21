import 'package:easy_learn_app/models/relationship_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only active relationship status authorizes chat access', () {
    final pending = RelationshipModel(
      id: 'rel_pending',
      studentId: 'stu_001',
      parentId: 'teacher_001',
      senderId: 'teacher_001',
      studentName: '小明',
      parentName: '李老师',
      status: RelationshipStatus.pending,
    );
    final active = RelationshipModel(
      id: 'rel_active',
      studentId: 'stu_001',
      parentId: 'teacher_001',
      senderId: 'teacher_001',
      studentName: '小明',
      parentName: '李老师',
      status: RelationshipStatus.active,
    );

    expect(pending.isActive, isFalse);
    expect(active.isActive, isTrue);
  });
}
