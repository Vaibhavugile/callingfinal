import 'package:cloud_firestore/cloud_firestore.dart';

class CallCache {
  static final CallCache instance = CallCache._();
  CallCache._();

  String? tenantId;
  DateTime? from;
  DateTime? to;

  /// phoneNumber → latest call doc data
  final Map<String, Map<String, dynamic>> latestByPhone = {};

  DateTime? lastLoadedAt;

  /// 🛑 Prevent parallel refreshes
  bool isRefreshing = false;

  /// Check whether cache can be reused
  bool isValid({
    required String tenantId,
    required DateTime from,
    required DateTime to,
  }) {
    if (this.tenantId != tenantId) return false;

    // ⚠️ DateTime object comparison is unsafe → compare timestamps
    if (this.from?.millisecondsSinceEpoch !=
        from.millisecondsSinceEpoch) return false;

    if (this.to?.millisecondsSinceEpoch !=
        to.millisecondsSinceEpoch) return false;

    if (lastLoadedAt == null) return false;

    // Cache valid for 60 seconds
    return DateTime.now().difference(lastLoadedAt!).inSeconds < 60;
  }

  /// 🔥 Mark cache as stale (forces reload on next access)
  void invalidate() {
    lastLoadedAt = null;
  }

  /// 🧹 Fully clear cache and scope (tenant / date change, logout, etc.)
  void clear() {
    latestByPhone.clear();
    tenantId = null;
    from = null;
    to = null;
    lastLoadedAt = null;
    isRefreshing = false;
  }
}
