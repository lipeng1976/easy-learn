class UserProfileModel {
  final String userId;
  final String name;
  final String gender;
  final String grade;

  /// 学期：`上` / `下` / 空串（未填写）。
  final String term;
  final List<String> hobbies;
  final String bio;

  const UserProfileModel({
    required this.userId,
    required this.name,
    required this.gender,
    required this.grade,
    this.term = '',
    required this.hobbies,
    required this.bio,
  });

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'gender': gender,
      'grade': grade,
      'term': term,
      'hobbies': hobbies.join(','),
      'bio': bio,
    };
  }
}
