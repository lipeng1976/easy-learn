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

  /// 心愿列表的统一展示顺序：**申请兑现时间越新越靠前**。
  ///
  /// 口径（家长端/学生端共用，服务端 `wish.js` 的 ORDER BY 必须逐字对齐）：
  ///   1. `redeemRequestedAt` 降序，`null`（从没申请过兑现的）排最后；
  ///   2. 同为 null 时按 `expectedDate` 降序，近的在前；
  ///   3. 还是并列就按 `id` 升序，保证顺序稳定、每次刷新不跳动。
  ///
  /// 为什么用 DateTime 而不是本地库里存的 ISO 字符串排序：本地字符串可能是
  /// 不同时区写的（`toIso8601String` 带偏移），字典序不等于时间序。
  ///
  /// 注意：这是**纯展示顺序**，不改余额/状态判定，也不碰原列表之外的任何东西。
  static int compareByRequestTimeDesc(WishModel a, WishModel b) {
    final ar = a.redeemRequestedAt;
    final br = b.redeemRequestedAt;
    if (ar != null && br != null) {
      final c = br.compareTo(ar);
      if (c != 0) return c;
    } else if (ar != null) {
      return -1;
    } else if (br != null) {
      return 1;
    }

    final ae = a.expectedDate;
    final be = b.expectedDate;
    if (ae != null && be != null) {
      final c = be.compareTo(ae);
      if (c != 0) return c;
    } else if (ae != null) {
      return -1;
    } else if (be != null) {
      return 1;
    }
    return a.id.compareTo(b.id);
  }
}

/// 按 [WishModel.compareByRequestTimeDesc] 原地排序，返回同一个列表方便链式调用。
List<WishModel> sortWishesByRequestTimeDesc(List<WishModel> wishes) =>
    wishes..sort(WishModel.compareByRequestTimeDesc);
