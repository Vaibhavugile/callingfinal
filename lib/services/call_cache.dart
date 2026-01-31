import 'package:cloud_firestore/cloud_firestore.dart';

class CallCache {
  static final CallCache instance = CallCache._();
  CallCache._();

  /// Scope
  String? tenantId;
  DateTime? from;
  DateTime? to;

  /// phoneNumber → latest call doc data
  final Map<String, Map<String, dynamic>> latestByPhone = {};

  /// When Firestore was last hit
  DateTime? lastLoadedAt;

  /// 🛑 Prevent parallel refreshes
  bool isRefreshing = false;

  /// ✅ Used ONLY to decide whether Firestore should be hit again
  bool isValid({
    required String tenantId,
    required DateTime from,
    required DateTime to,
  }) {
    if (this.tenantId != tenantId) return false;
    if (lastLoadedAt == null) return false;

    // Cache freshness window (60 seconds)
    return DateTime.now().difference(lastLoadedAt!).inSeconds < 60;
  }

  /// 📦 READ cached calls
  /// ⚠️ IMPORTANT:
  /// - Do NOT block on from/to mismatch
  /// - DateTimes differ slightly across screens
  /// - Cache is still valid for UI usage
  Map<String, Map<String, dynamic>> getLatestCalls({
    required String tenantId,
    required DateTime from,
    required DateTime to,
  }) {
    if (this.tenantId != tenantId) return {};

    return latestByPhone;
  }

  /// 🔥 Mark cache as stale (forces Firestore refresh next time)
  void invalidate() {
    lastLoadedAt = null;
  }

  /// 🧹 Fully clear cache (logout / tenant switch)
  void clear() {
    latestByPhone.clear();
    tenantId = null;
    from = null;
    to = null;
    lastLoadedAt = null;
    isRefreshing = false;
  }
}
