import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';

import '../services/lead_service.dart';
import '../models/lead.dart';
import 'lead_list_screen.dart';
import '../call_event_handler.dart';
import '../widgets/gradient_appbar_title.dart';
import '../services/call_loader.dart';
import '../services/call_cache.dart';

class HomeScreen extends StatefulWidget {
  final CallEventHandler callHandler;

  const HomeScreen({
    super.key,
    required this.callHandler,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// Lightweight latest-call model (same idea as in LeadListScreen)
class LatestCall {
  final String? callId;
  final String? phoneNumber;
  final String? direction; // inbound / outbound
  final int? durationInSeconds;
  final DateTime? createdAt;
  final DateTime? finalizedAt;
  final String? finalOutcome;

  LatestCall({
    this.callId,
    this.phoneNumber,
    this.direction,
    this.durationInSeconds,
    this.createdAt,
    this.finalizedAt,
    this.finalOutcome,
  });

  factory LatestCall.fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();

    DateTime? _toDate(Object? v) {
      if (v == null) return null;
      if (v is Timestamp) return v.toDate();
      if (v is DateTime) return v;
      try {
        return DateTime.parse(v.toString());
      } catch (_) {
        return null;
      }
    }

    return LatestCall(
      callId: doc.id,
      phoneNumber: (data['phoneNumber'] as String?)?.trim(),
      direction: (data['direction'] as String?)?.toLowerCase(),
      durationInSeconds: data['durationInSeconds'] is num
          ? (data['durationInSeconds'] as num).toInt()
          : null,
      createdAt: _toDate(data['createdAt']),
      finalizedAt: _toDate(data['finalizedAt']),
      finalOutcome: (data['finalOutcome'] as String?)?.toLowerCase(),
    );
  }
}

class _HomeScreenState extends State<HomeScreen> {
  final LeadService _leadService = LeadService.instance;
DateTime _fromDate = DateTime.now().subtract(const Duration(days: 2));
DateTime _toDate = DateTime.now();
String _dateFilter = '2d';
bool _didInitialLoad = false;


  bool _loading = true;
  List<Lead> _leads = [];
  String _tenantId = '';
Timer? _cacheTimer;

  // For call-log sync progress
  bool _syncing = false;
  String _syncLabel = "";
int _missedCount = 0;
int _rejectedCount = 0;
int _answeredCount = 0;

StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _callSub;

  // latest call per leadId
  // final Map<String, LatestCall?> _latestCallByLead = {};
  // bool _loadingLatestCalls = false;

  // Dark / Neon Palette
  final Color _bgDark1 = const Color(0xFF020617);
  final Color _bgDark2 = const Color(0xFF0B1120);
  final Color _primaryColor = const Color(0xFF0F172A);
  final Color _accentIndigo = const Color(0xFF6366F1);
  final Color _accentTeal = const Color(0xFF14B8A6);
  final Color _accentOrange = const Color(0xFFF97316);
  final Color _accentRed = const Color(0xFFEF4444);
  final Color _mutedText = const Color(0xFF94A3B8);


@override
void initState() {
  super.initState();

  if (!_didInitialLoad) {
    _didInitialLoad = true;
    _initOnAppOpen();
  }
}


Future<void> _initOnAppOpen() async {
  await _loadTenantAndLeads();

  // 🔥 ONE-TIME Firestore load on app open
  await loadLatestCalls(
    tenantId: _tenantId,
    from: _fromDate,
    to: _toDate,
    backgroundRefresh: false,
  );

  // ✅ UI from cache only
  await _loadCallStatsOnce();
}


@override
void dispose() {
  // Clean up timers

  // Existing cleanup
  _callSub?.cancel();

  super.dispose();
}


Future<void> _loadCallStatsOnce() async {
  if (_tenantId.isEmpty) return;

  try {
  final calls = await loadLatestCalls(
  tenantId: _tenantId,
  from: _fromDate,
  to: _toDate,
  backgroundRefresh: false,
);


    int missed = 0;
    int rejected = 0;
    int answered = 0;

    for (final data in calls.values) {
      final dir = (data['direction'] as String?)?.toLowerCase();
      final dur = (data['durationInSeconds'] as num?)?.toInt() ?? 0;
      final outcome = (data['finalOutcome'] as String?)?.toLowerCase();

      if ((dir == 'inbound' && dur == 0) || outcome == 'missed') {
        missed++;
      } else if (dir == 'outbound' &&
          (dur == 0 || outcome == 'rejected')) {
        rejected++;
      } else if (dur > 0) {
        answered++;
      }
    }

    if (!mounted) return;

    setState(() {
      _missedCount = missed;
      _rejectedCount = rejected;
      _answeredCount = answered;
    });
  } catch (e, st) {
    print('❌ loadCallStats error: $e');
    print(st);
  }
}
Future<void> _confirmPasswordAndFix() async {
  final TextEditingController pwdCtrl = TextEditingController();
  bool wrongPassword = false;

  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocalState) {
          return AlertDialog(
            backgroundColor: _primaryColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text(
              "Confirm Action",
              style: TextStyle(color: Colors.white),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  "Enter admin password to remove ALL missed / rejected calls.",
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pwdCtrl,
                  obscureText: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: "Password",
                    hintStyle: const TextStyle(color: Colors.white38),
                    errorText:
                        wrongPassword ? "Incorrect password" : null,
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: Colors.white.withOpacity(0.2),
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide:
                          const BorderSide(color: Colors.cyanAccent),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Cancel"),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                ),
                onPressed: () {
                  const adminPassword = "Reddy@7777";

                  if (pwdCtrl.text == adminPassword) {
                    // Close password dialog
                    Navigator.pop(ctx);

                    // 🔴 SHOW BLOCKING PROGRESS IMMEDIATELY
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => AlertDialog(
                        backgroundColor: _primaryColor,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            CircularProgressIndicator(
                              valueColor: AlwaysStoppedAnimation(
                                Colors.cyanAccent,
                              ),
                            ),
                            SizedBox(height: 16),
                            Text(
                              "Removing missed / rejected calls...\nPlease wait",
                              style: TextStyle(color: Colors.white),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    );

                    // 🔥 START FIREBASE FIX
                    _fixAllZeroDurationCallsAllTime();
                  } else {
                    setLocalState(() => wrongPassword = true);
                  }
                },
                child: const Text("Confirm"),
              ),
            ],
          );
        },
      );
    },
  );
}







Future<void> _fixAllZeroDurationCallsAllTime() async {
  if (_tenantId.isEmpty) return;

  setState(() => _syncing = true);

  try {
    const int batchLimit = 400;
    int totalUpdated = 0;
    QueryDocumentSnapshot<Map<String, dynamic>>? lastDoc;

    while (true) {
      Query<Map<String, dynamic>> query = FirebaseFirestore.instance
          .collectionGroup('calls')
          .where('tenantId', isEqualTo: _tenantId)
          .where('durationInSeconds', isEqualTo: 0)
          .orderBy('createdAt', descending: true)
          .limit(batchLimit);

      if (lastDoc != null) {
        query = query.startAfterDocument(lastDoc);
      }

      final snap = await query.get();
      if (snap.docs.isEmpty) break;

      final batch = FirebaseFirestore.instance.batch();

      for (final doc in snap.docs) {
        batch.update(doc.reference, {
          'durationInSeconds': 1,
          'finalOutcome': 'answered',
        });
        totalUpdated++;
      }

      await batch.commit();
      lastDoc = snap.docs.last;
    }

    // 🔄 IMPORTANT: clear cache AFTER Firebase mutation
    CallCache.instance.clear();

    // 🔄 reload dashboard stats
    await _loadCallStatsOnce();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          totalUpdated == 0
              ? "No missed/rejected calls found."
              : "Fixed $totalUpdated calls (all time).",
        ),
      ),
    );
  } catch (e, st) {
    FirebaseCrashlytics.instance.recordError(e, st);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Failed to update calls in Firebase.")),
    );
  } finally {
    if (mounted) setState(() => _syncing = false);
  }
}


  Future<void> _loadTenantAndLeads() async {
    setState(() => _loading = true);

    // Load tenantId
    final prefs = await SharedPreferences.getInstance();
    _tenantId = prefs.getString('tenantId') ?? '';
// await _loadCallStatsOnce();


    print("🏷 Loaded tenantId in HomeScreen: $_tenantId");

    // Load leads
    await _leadService.loadLeads();
    _leads = List<Lead>.from(_leadService.getAll());

    // Load latest calls for each lead
    // await _loadLatestCallsForLeads();

    setState(() => _loading = false);
  }

  /// Fetch single most recent call doc for one lead
  Future<LatestCall?> _fetchLatestCallForLead(String leadId) async {
    try {
      final tenantId = _tenantId.isNotEmpty ? _tenantId : 'default_tenant';

      final q = await FirebaseFirestore.instance
          .collection('tenants')
          .doc(tenantId)
          .collection('leads')
          .doc(leadId)
          .collection('calls')
          .orderBy('createdAt', descending: true)
          .limit(1)
          .get();

      if (q.docs.isEmpty) return null;
      return LatestCall.fromDoc(q.docs.first);
    } catch (e, st) {
      // ignore errors, just log
      // ignore: avoid_print
      print("fetchLatestCallForLead error for $leadId: $e\n$st");
      return null;
    }
  }

  void _applyDateFilter(String filter) {
  final now = DateTime.now();

   setState(() {
    _dateFilter = filter;

    if (filter == '2d') {
      _fromDate = now.subtract(const Duration(days: 2));
    } else if (filter == '7d') {
      _fromDate = now.subtract(const Duration(days: 7));
    } else if (filter == '30d') {
      _fromDate = now.subtract(const Duration(days: 30));
    }

    _toDate = now;
  });

  _loadCallStatsOnce(); // 🔄 reload stats
}
Future<void> _pickCustomDateRange() async {
  final picked = await showDateRangePicker(
    context: context,
    firstDate: DateTime.now().subtract(const Duration(days: 365)),
    lastDate: DateTime.now(),
    initialDateRange: DateTimeRange(
      start: _fromDate,
      end: _toDate,
    ),
  );

  if (picked == null) return;

  setState(() {
    _dateFilter = 'custom';
    _fromDate = picked.start;
    _toDate = picked.end;
  });

  _loadCallStatsOnce();
}
Widget _dateChip(String label, String value) {
  final bool isSelected = _dateFilter == value;

  return GestureDetector(
    onTap: () {
      if (value == 'custom') {
        _pickCustomDateRange();
      } else {
        _applyDateFilter(value);
      }
    },
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: isSelected
            ? Colors.cyanAccent
            : Colors.white.withOpacity(0.08),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: isSelected ? Colors.black : Colors.white,
        ),
      ),
    ),
  );
}


  /// Load latest calls in small batches
  // Future<void> _loadLatestCallsForLeads() async {
  //   _latestCallByLead.clear();
  //   if (_leads.isEmpty) return;

  //   setState(() => _loadingLatestCalls = true);

  //   const int batchSize = 10;
  //   for (var i = 0; i < _leads.length; i += batchSize) {
  //     final batch = _leads.skip(i).take(batchSize).toList();
  //     final futures = batch.map((l) => _fetchLatestCallForLead(l.id)).toList();
  //     final results = await Future.wait(futures);
  //     for (var j = 0; j < batch.length; j++) {
  //       _latestCallByLead[batch[j].id] = results[j];
  //     }
  //     if (mounted) setState(() {});
  //   }

  //   if (mounted) {
  //     setState(() => _loadingLatestCalls = false);
  //   }
  // }
  

  // // ----------------- MISSED / REJECTED HEURISTICS (from calls doc) -----------------

  // bool _isMissedCall(LatestCall? latest) {
  //   if (latest == null) return false;

  //   final dir = latest.direction?.toLowerCase();
  //   final dur = latest.durationInSeconds ?? 0;
  //   final outcome = (latest.finalOutcome ?? '').toLowerCase();

  //   // inbound + 0 sec  OR  explicit finalOutcome == "missed"
  //   if (dir == 'inbound' && dur == 0) return true;
  //   if (outcome == 'missed') return true;

  //   return false;
  // }

  // bool _isRejectedCall(LatestCall? latest) {
  //   if (latest == null) return false;

  //   final dir = latest.direction?.toLowerCase();
  //   final dur = latest.durationInSeconds ?? 0;
  //   final outcome = (latest.finalOutcome ?? '').toLowerCase();

  //   // Only outgoing are considered rejected
  //   if (dir != 'outbound') return false;

  //   if (dur == 0) return true;
  //   if (outcome == 'rejected') return true;

  //   return false;
  // }

  // -------------------------- UI HELPERS --------------------------

  Widget _statCard({
    required String title,
    required int value,
    required Color color,
    required IconData icon,
    double? width,
    VoidCallback? onTap,
  }) {
    final card = Container(
      width: width,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _primaryColor,
            _bgDark2,
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.45),
            blurRadius: 18,
            offset: const Offset(0, 12),
          ),
        ],
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // colored top bar
          Container(
            height: 3,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              gradient: LinearGradient(
                colors: [
                  color.withOpacity(0.95),
                  color.withOpacity(0.6),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: color.withOpacity(0.12),
                child: Icon(icon, size: 16, color: color),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value.toString(),
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return card;

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: card,
    );
  }

  Widget _tenantBadge() {
    final hasTenant = _tenantId.isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: hasTenant
            ? const Color(0xFF0F172A)
            : Colors.white.withOpacity(0.02),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: hasTenant ? _accentIndigo : Colors.white24,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.business,
            size: 18,
            color: hasTenant ? _accentIndigo : _mutedText,
          ),
          const SizedBox(width: 6),
          Text(
            hasTenant ? "User: $_tenantId" : "No user assigned",
            style: TextStyle(
              fontSize: 13,
              color: hasTenant ? Colors.white : _mutedText,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

 void _openLeadListWithFilter(String filter) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => LeadListScreen(initialFilter: filter),
    ),
  );
}

  /// Generic runner for call-log sync with nice progress UI
  Future<void> _runFixFromCallLog({
  required Future<void> Function() action,
  required String label,
}) async {
  if (_syncing) return;

  setState(() {
    _syncing = true;
    _syncLabel = "Syncing $label from phone log...";
  });

  try {
    await action();
  CallCache.instance.invalidate();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("Finished syncing $label from call log."),
      ),
    );

    // ✅ NO manual reload needed
    // Firestore stream will auto-update counts

  } catch (e, st) {
    FirebaseCrashlytics.instance.recordError(e, st);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("Failed to sync $label. Check logs."),
      ),
    );
  } finally {
    if (mounted) {
      setState(() {
        _syncing = false;
        _syncLabel = "";
      });
    }
  }
}


  Future<void> _runFixTodayFromCallLog() async {
    return _runFixFromCallLog(
      action: () => widget.callHandler.fixTodayFromCallLog(),
      label: "today's calls",
    );
  }

  Future<void> _runFixLast7DaysFromCallLog() async {
    return _runFixFromCallLog(
      action: () => widget.callHandler.fixLast7DaysFromCallLog(),
      label: "last 7 days",
    );
  }

  Future<void> _runFixLast30DaysFromCallLog() async {
    return _runFixFromCallLog(
      action: () => widget.callHandler.fixLast30DaysFromCallLog(),
      label: "last 30 days",
    );
  }

  void _showFixOptionsSheet() {
    if (_syncing) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: _bgDark1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  "Fix data from Call Log",
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),

                const SizedBox(height: 4),
                Text(
                  "Choose which calls you want to sync.",
                  style: TextStyle(
                    fontSize: 13,
                    color: _mutedText,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.all(14),
                      backgroundColor: _accentTeal,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.today),
                    label: const Text("Fix TODAY's calls"),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _runFixTodayFromCallLog();
                    },
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.all(14),
                      backgroundColor: _bgDark2,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: _accentIndigo.withOpacity(0.6),
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.calendar_view_week_rounded),
                    label: const Text("Fix LAST 7 DAYS"),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _runFixLast7DaysFromCallLog();
                    },
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.all(14),
                      backgroundColor: _bgDark2,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: _accentIndigo.withOpacity(0.6),
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.calendar_month_rounded),
                    label: const Text("Fix LAST 30 DAYS"),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _runFixLast30DaysFromCallLog();
                    },
                  ),
                ),
                ElevatedButton.icon(
  style: ElevatedButton.styleFrom(
    backgroundColor: Colors.deepOrange,
    foregroundColor: Colors.white,
    padding: const EdgeInsets.all(14),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    ),
  ),
  icon: const Icon(Icons.cleaning_services),
  label: const Text(
    "Remove ALL Missed / Rejected (All Time)",
    style: TextStyle(fontSize: 15),
  ),
  onPressed: _confirmPasswordAndFix, // method comes later
),

                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _syncProgressCard() {
    if (!_syncing) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(top: 14, bottom: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _primaryColor,
            _bgDark2,
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.45),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(
                height: 28,
                width: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(Colors.lightBlueAccent),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _syncLabel.isNotEmpty
                      ? _syncLabel
                      : "Syncing from call log...",
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: const LinearProgressIndicator(
              minHeight: 3,
              valueColor:
                  AlwaysStoppedAnimation<Color>(Colors.lightBlueAccent),
              backgroundColor: Colors.white12,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalLeads = _leads.length;
    final followUpCount =
        _leads.where((e) => e.status == "Follow Up").length;
        final missedCount = _missedCount;
final rejectedCount = _rejectedCount;


    // Missed / Rejected based on latest /calls doc
    // final missedCount = _leads.where((lead) {
    //   final latest = _latestCallByLead[lead.id];
    //   return _isMissedCall(latest);
    // }).length;

    // final rejectedCount = _leads.where((lead) {
    //   final latest = _latestCallByLead[lead.id];
    //   return _isRejectedCall(latest);
    // }).length;

    return Scaffold(
      backgroundColor: _bgDark1,
      appBar: AppBar(
  elevation: 0,
  foregroundColor: Colors.white,
  flexibleSpace: Container(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: [
          _bgDark2,
          _primaryColor,
        ],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
  ),
  title: const GradientAppBarTitle(
    "Call Leads CRM",
    fontSize: 18,
  ),
),

      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    _bgDark1,
                    _bgDark2,
                  ],
                ),
              ),
              child: RefreshIndicator(
   onRefresh: () async {
  CallCache.instance.clear();

  await _loadTenantAndLeads();

  await loadLatestCalls(
    tenantId: _tenantId,
    from: _fromDate,
    to: _toDate,
    backgroundRefresh: false,
  );

  await _loadCallStatsOnce();
},


                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _tenantBadge(),

                    // DASHBOARD TITLE
const Text(
  "Dashboard",
  style: TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.bold,
    color: Colors.white,
  ),
),

const SizedBox(height: 6),

// TOTAL LEADS
Text(
  _loading
      ? "Loading dashboard..."
      : "Total: $totalLeads leads",
  style: TextStyle(
    fontSize: 13,
    color: _mutedText,
  ),
),

const SizedBox(height: 12),

// DATE FILTER CHIPS (SAFE)
SizedBox(
  height: 42,
  child: ListView(
    scrollDirection: Axis.horizontal,
    children: [
      _dateChip('Last 2 days', '2d'),
      const SizedBox(width: 8),
      _dateChip('Last 7 Days', '7d'),
      const SizedBox(width: 8),
      _dateChip('Last 30 Days', '30d'),
      const SizedBox(width: 8),
      _dateChip('Custom', 'custom'),
    ],
  ),
),

                      const SizedBox(height: 10),

                      // 2 cards per row, all clickable
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final cardWidth = (constraints.maxWidth - 12) / 2;
                          return Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              _statCard(
                                title: "Total Leads",
                                value: totalLeads,
                                color: Colors.cyanAccent,
                                icon: Icons.people_alt_rounded,
                                width: cardWidth,
                                onTap: () => _openLeadListWithFilter('All'),
                              ),
                              _statCard(
                                title: "Follow Up (Today)",
                                value: followUpCount,
                                color: _accentOrange,
                                icon: Icons.notifications_active_rounded,
                                width: cardWidth,
                                onTap: () =>
                                    _openLeadListWithFilter('Today'),
                              ),
                              _statCard(
                                title: "Missed Calls (latest)",
                                value: missedCount,
                                color: _accentRed,
                                icon: Icons.call_missed_rounded,
                                width: cardWidth,
                                onTap: () =>
                                    _openLeadListWithFilter('Missed'),
                              ),
                              _statCard(
                                title: "Rejected Calls (latest)",
                                value: rejectedCount,
                                color: _accentRed.withOpacity(0.85),
                                icon: Icons.call_end_rounded,
                                width: cardWidth,
                                onTap: () =>
                                    _openLeadListWithFilter('Rejected'),
                              ),
                            ],
                          );
                        },
                      ),

                      _syncProgressCard(),

                      const SizedBox(height: 12),

                      // Fix from CallLog card
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              _primaryColor,
                              _bgDark2,
                            ],
                          ),
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.45),
                              blurRadius: 18,
                              offset: const Offset(0, 12),
                            ),
                          ],
                          border:
                              Border.all(color: Colors.white.withOpacity(0.06)),
                        ),
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: _accentIndigo.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    Icons.sync_rounded,
                                    color: _accentIndigo,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                const Text(
                                  "Fix data from Call Log",
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              "If some calls were missed or durations are wrong, you can correct them using your phone's call log.",
                              style: TextStyle(
                                fontSize: 13,
                                color: _mutedText,
                              ),
                            ),
                            const SizedBox(height: 14),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.all(14),
                                  backgroundColor: _accentIndigo,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                icon: const Icon(Icons.tune_rounded),
                                label: const Text(
                                  "Choose range & fix",
                                  style: TextStyle(
                                    fontSize: 15,
                                  ),
                                ),
                                onPressed:
                                    _syncing ? null : _showFixOptionsSheet,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),


                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.all(16),
                            backgroundColor: Colors.cyanAccent,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            foregroundColor: Colors.black,
                          ),
                          icon: const Icon(Icons.list_alt_rounded),
                          onPressed: () => _openLeadListWithFilter('All'),
                          label: const Text(
                            "View All Leads",
                            style: TextStyle(
                              fontSize: 18,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
