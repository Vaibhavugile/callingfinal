import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../services/lead_service.dart';
import '../models/lead.dart';
import 'lead_list_screen.dart';
import '../call_event_handler.dart';

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

  bool _loading = true;
  List<Lead> _leads = [];
  String _tenantId = '';

  // For call-log sync progress
  bool _syncing = false;
  String _syncLabel = "";

  // latest call per leadId
  final Map<String, LatestCall?> _latestCallByLead = {};
  bool _loadingLatestCalls = false;

  // Palette
  final Color _bgColor = const Color(0xFFF3F4F6);
  final Color _primaryColor = const Color(0xFF111827); // dark text
  final Color _accentIndigo = const Color(0xFF6366F1);
  final Color _accentTeal = const Color(0xFF0D9488);
  final Color _accentOrange = const Color(0xFFF97316);
  final Color _accentRed = const Color(0xFFDC2626);

  @override
  void initState() {
    super.initState();
    _loadTenantAndLeads();
  }

  Future<void> _loadTenantAndLeads() async {
    setState(() => _loading = true);

    // Load tenantId
    final prefs = await SharedPreferences.getInstance();
    _tenantId = prefs.getString('tenantId') ?? '';

    print("🏷 Loaded tenantId in HomeScreen: $_tenantId");

    // Load leads
    await _leadService.loadLeads();
    _leads = List<Lead>.from(_leadService.getAll());

    // Load latest calls for each lead
    await _loadLatestCallsForLeads();

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

  /// Load latest calls in small batches
  Future<void> _loadLatestCallsForLeads() async {
    _latestCallByLead.clear();
    if (_leads.isEmpty) return;

    setState(() => _loadingLatestCalls = true);

    const int batchSize = 10;
    for (var i = 0; i < _leads.length; i += batchSize) {
      final batch = _leads.skip(i).take(batchSize).toList();
      final futures = batch.map((l) => _fetchLatestCallForLead(l.id)).toList();
      final results = await Future.wait(futures);
      for (var j = 0; j < batch.length; j++) {
        _latestCallByLead[batch[j].id] = results[j];
      }
      if (mounted) setState(() {});
    }

    if (mounted) {
      setState(() => _loadingLatestCalls = false);
    }
  }

  // ----------------- MISSED / REJECTED HEURISTICS (from calls doc) -----------------

  bool _isMissedCall(LatestCall? latest) {
    if (latest == null) return false;

    final dir = latest.direction?.toLowerCase();
    final dur = latest.durationInSeconds ?? 0;
    final outcome = (latest.finalOutcome ?? '').toLowerCase();

    // inbound + 0 sec  OR  explicit finalOutcome == "missed"
    if (dir == 'inbound' && dur == 0) return true;
    if (outcome == 'missed') return true;

    return false;
  }

  bool _isRejectedCall(LatestCall? latest) {
    if (latest == null) return false;

    final dir = latest.direction?.toLowerCase();
    final dur = latest.durationInSeconds ?? 0;
    final outcome = (latest.finalOutcome ?? '').toLowerCase();

    // Only outgoing are considered rejected
    if (dir != 'outbound') return false;

    if (dur == 0) return true;
    if (outcome == 'rejected') return true;

    return false;
  }

  // -------------------------- UI HELPERS --------------------------

  Widget _statCard({
    required String title,
    required int value,
    required Color color,
    required IconData icon,
    double? width,
  }) {
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
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
                backgroundColor: color.withOpacity(0.1),
                child: Icon(icon, size: 16, color: color),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade700,
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
  }

  Widget _tenantBadge() {
    final hasTenant = _tenantId.isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: hasTenant ? const Color(0xFFE0ECFF) : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: hasTenant ? _accentIndigo : Colors.grey.shade400,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.business,
            size: 18,
            color: hasTenant ? _accentIndigo : Colors.grey.shade600,
          ),
          const SizedBox(width: 6),
          Text(
            hasTenant ? "Tenant: $_tenantId" : "No tenant assigned",
            style: TextStyle(
              fontSize: 13,
              color: hasTenant ? _accentIndigo : Colors.grey.shade700,
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
    if (_syncing) return; // prevent double taps

    setState(() {
      _syncing = true;
      _syncLabel = "Syncing $label from phone log...";
    });

    try {
      await action();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Finished syncing $label from call log."),
        ),
      );

      // Reload latest calls after sync
      await _loadLatestCallsForLeads();
      if (mounted) setState(() {});
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
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  "Fix data from Call Log",
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "Choose which calls you want to sync.",
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.all(14),
                      backgroundColor: _accentTeal,
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
                      backgroundColor: Colors.white,
                      foregroundColor: _accentIndigo,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: _accentIndigo.withOpacity(0.4),
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
                      backgroundColor: Colors.white,
                      foregroundColor: _accentIndigo,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: _accentIndigo.withOpacity(0.4),
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

    return Card(
      elevation: 4,
      margin: const EdgeInsets.only(top: 14, bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        child: Column(
          children: [
            Row(
              children: [
                const SizedBox(
                  height: 28,
                  width: 28,
                  child: CircularProgressIndicator(strokeWidth: 3),
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
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: const LinearProgressIndicator(minHeight: 3),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalLeads = _leads.length;
    final followUpCount =
        _leads.where((e) => e.status == "Follow Up").length;

    // Missed / Rejected based on latest /calls doc
    final missedCount = _leads.where((lead) {
      final latest = _latestCallByLead[lead.id];
      return _isMissedCall(latest);
    }).length;

    final rejectedCount = _leads.where((lead) {
      final latest = _latestCallByLead[lead.id];
      return _isRejectedCall(latest);
    }).length;

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        title: const Text(
          "Call Leads CRM",
          style: TextStyle(
            fontWeight: FontWeight.w700,
          ),
        ),
        foregroundColor: Colors.white,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                _primaryColor,
                const Color(0xFF1F2937),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
      ),
      backgroundColor: _bgColor,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadTenantAndLeads,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _tenantBadge(),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "Dashboard",
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          _loadingLatestCalls
                              ? "Loading call stats..."
                              : "Total: $totalLeads leads",
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // 2 cards per row
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
                              color: _primaryColor,
                              icon: Icons.people_alt_rounded,
                              width: cardWidth,
                            ),
                            _statCard(
                              title: "Follow Up",
                              value: followUpCount,
                              color: _accentOrange,
                              icon: Icons.notifications_active_rounded,
                              width: cardWidth,
                            ),
                            // clickable Missed
                            GestureDetector(
                              onTap: () => _openLeadListWithFilter('Missed'),
                              child: _statCard(
                                title: "Missed Calls (latest)",
                                value: missedCount,
                                color: _accentRed,
                                icon: Icons.call_missed_rounded,
                                width: cardWidth,
                              ),
                            ),
                            // clickable Rejected
                            GestureDetector(
                              onTap: () => _openLeadListWithFilter('Rejected'),
                              child: _statCard(
                                title: "Rejected Calls (latest)",
                                value: rejectedCount,
                                color: _accentRed.withOpacity(0.85),
                                icon: Icons.call_end_rounded,
                                width: cardWidth,
                              ),
                            ),
                          ],
                        );
                      },
                    ),

                    _syncProgressCard(),

                    const SizedBox(height: 12),

                    // Simple card with one button that opens bottom sheet
                    Card(
                      elevation: 3,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: _accentIndigo.withOpacity(0.08),
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
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              "If some calls were missed or durations are wrong, you can correct them using your phone's call log.",
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade700,
                              ),
                            ),
                            const SizedBox(height: 14),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.all(14),
                                  backgroundColor: _accentIndigo,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                icon: const Icon(Icons.tune_rounded),
                                label: const Text(
                                  "Choose range & fix",
                                  style: TextStyle(fontSize: 15),
                                ),
                                onPressed: _syncing ? null : _showFixOptionsSheet,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 20),

                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.all(16),
                          backgroundColor: _primaryColor,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        icon: const Icon(Icons.list_alt_rounded),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const LeadListScreen(),
                            ),
                          );
                        },
                        label: const Text(
                          "View All Leads",
                          style: TextStyle(fontSize: 18),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
