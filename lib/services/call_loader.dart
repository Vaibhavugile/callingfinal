import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'call_cache.dart';

/// Public API used by HomeScreen & LeadListScreen
Future<Map<String, Map<String, dynamic>>> loadLatestCalls({
  required String tenantId,
  required DateTime from,
  required DateTime to,
  bool backgroundRefresh = true,
}) async {
  final cache = CallCache.instance;

  final bool hasValidCache =
      cache.isValid(tenantId: tenantId, from: from, to: to);

  // 🧪 DEBUG LOGGING
  if (hasValidCache) {
    debugPrint(
      "🟢 CallCache HIT | tenant=$tenantId | "
      "age=${cache.lastLoadedAt != null
          ? DateTime.now().difference(cache.lastLoadedAt!).inSeconds
          : '?'}s",
    );
  } else {
    debugPrint(
      "🔴 CallCache MISS | tenant=$tenantId | loading from Firestore",
    );
  }

  // 1️⃣ FAST PATH → return cache immediately
  if (hasValidCache) {
    if (backgroundRefresh) {
      // 🔄 Fire-and-forget refresh (NON BLOCKING)
      _refreshLatestCalls(
        tenantId: tenantId,
        from: from,
        to: to,
      );
    }
    return cache.latestByPhone;
  }

  // 2️⃣ No cache → block once and load
  return await _refreshLatestCalls(
    tenantId: tenantId,
    from: from,
    to: to,
  );
}

/// Internal loader that actually hits Firestore
Future<Map<String, Map<String, dynamic>>> _refreshLatestCalls({
  required String tenantId,
  required DateTime from,
  required DateTime to,
}) async {
  final cache = CallCache.instance;

  // 🛑 Prevent parallel refreshes
  if (cache.isRefreshing) {
    return cache.latestByPhone;
  }

  cache.isRefreshing = true;

  try {
    final Map<String, Map<String, dynamic>> latestByPhone = {};
    final Timestamp fromTs = Timestamp.fromDate(from);
    final Timestamp toTs = Timestamp.fromDate(to);

    QueryDocumentSnapshot<Map<String, dynamic>>? lastDoc;
    int totalFetched = 0;
    const int maxDocs = 2000;

    while (totalFetched < maxDocs) {
      Query<Map<String, dynamic>> query = FirebaseFirestore.instance
          .collectionGroup('calls')
          .where('tenantId', isEqualTo: tenantId)
          .where('createdAt', isGreaterThanOrEqualTo: fromTs)
          .where('createdAt', isLessThanOrEqualTo: toTs)
          .orderBy('createdAt', descending: true)
          .limit(400);

      if (lastDoc != null) {
        query = query.startAfterDocument(lastDoc);
      }

      final snap = await query.get();
      if (snap.docs.isEmpty) break;

      totalFetched += snap.docs.length;

      for (final doc in snap.docs) {
        final data = doc.data();

        final String? phone =
            (data['phoneNumber'] as String?)?.trim();
        if (phone == null || phone.isEmpty) continue;

        // DESC order → first occurrence is latest call
        latestByPhone.putIfAbsent(phone, () => data);
      }

      lastDoc = snap.docs.last;
    }

    // ✅ Update cache atomically
  cache.tenantId = tenantId;
cache.from = from;
cache.to = to;

cache.latestByPhone.clear();
cache.latestByPhone.addAll(latestByPhone);

cache.lastLoadedAt = DateTime.now();


    return latestByPhone;
  } finally {
    cache.isRefreshing = false;
  }
}
