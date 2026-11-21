class WishModel {
  final String id;
  final String title;
  final String description;
  final bool isPublic;
  final bool parentConfirmed;
  final bool studentConfirmed;
  final bool isArchived;
  final String studentId;
  final DateTime? expectedDate;

  /// 家长定价：兑现这个心愿要花多少积分。**0 表示不消耗积分**。
  ///
  /// 定价由家长在确认心愿时填，也可以在孩子申请兑换之前改。
  final int pointCost;

  /// 学生提出兑换申请的时间。只登记意向，**这时一分都不扣**。
  final DateTime? redeemRequestedAt;

  /// 家长确认兑现的时间。扣分就发生在这个时刻。
  final DateTime? redeemedAt;

  /// 家长拒绝这次申请的时间。拒绝不动积分，孩子可以再申请。
  final DateTime? redeemRejectedAt;

  WishModel({
    required this.id,
    required this.title,
    required this.description,
    required this.isPublic,
    required this.parentConfirmed,
    required this.studentConfirmed,
    required this.isArchived,
    this.studentId = '',
    this.expectedDate,
    this.pointCost = 0,
    this.redeemRequestedAt,
    this.redeemedAt,
    this.redeemRejectedAt,
  });

  /// 是否需要用积分兑换。
  bool get needsPoints => pointCost > 0;

  /// 已经兑现过了。一个心愿只能兑一次。
  bool get isRedeemed => redeemedAt != null;

  /// 正等着家长确认兑现（申请过、还没被兑现或拒绝）。
  ///
  /// 拒绝后 [redeemRequestedAt] 会被清掉，所以这里不用再判断拒绝时间 ——
  /// 「拒绝」不是一个持续状态，它只是把申请撤回并把决定权还给家长。
  bool get isRedeemPending => redeemRequestedAt != null && redeemedAt == null;

  /// 家长拒绝过、还没有被兑现。
  bool get isRedeemRejected =>
      redeemRejectedAt != null && redeemRequestedAt == null && !isRedeemed;

  WishModel copyWith({
    String? id,
    String? title,
    String? description,
    bool? isPublic,
    bool? parentConfirmed,
    bool? studentConfirmed,
    bool? isArchived,
    String? studentId,
    DateTime? expectedDate,
    int? pointCost,
    DateTime? redeemRequestedAt,
    DateTime? redeemedAt,
    DateTime? redeemRejectedAt,
    // 三个时间戳都要能被「清空」，而 `?? this.x` 的写法做不到 ——
    // 传 null 会被当成「不改这个字段」，于是「撤回申请」永远写不掉。
    bool clearRedeemRequest = false,
    bool clearRedeemRejected = false,
  }) {
    return WishModel(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      isPublic: isPublic ?? this.isPublic,
      parentConfirmed: parentConfirmed ?? this.parentConfirmed,
      studentConfirmed: studentConfirmed ?? this.studentConfirmed,
      isArchived: isArchived ?? this.isArchived,
      studentId: studentId ?? this.studentId,
      expectedDate: expectedDate ?? this.expectedDate,
      pointCost: pointCost ?? this.pointCost,
      redeemRequestedAt: clearRedeemRequest
          ? null
          : (redeemRequestedAt ?? this.redeemRequestedAt),
      redeemedAt: redeemedAt ?? this.redeemedAt,
      redeemRejectedAt: clearRedeemRejected
          ? null
          : (redeemRejectedAt ?? this.redeemRejectedAt),
    );
  }
}
