// lib/screens/lead_list_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // for defaultTargetPlatform, kIsWeb
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';
import '../models/lead.dart';
import '../services/lead_service.dart';
import 'lead_form_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

// -------------------------------------------------------------------------
// ✨ Premium visual theme (light/white + subtle accents)
// -------------------------------------------------------------------------
const Color _primaryColor = Color(0xFF111827); // near-black
const Color _accentColor = Color(0xFFFFC857); // warm gold
const Color _mutedBg = Color(0xFFF9FAFB);
const Gradient _appBarGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF111827), Color(0xFF1F2937)],
);
const Gradient _cardGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFFFFFFFF), Color(0xFFF7FBFF)],
);

class LeadListScreen extends StatefulWidget {
  const LeadListScreen({super.key});

  @override
  State<LeadListScreen> createState() => _LeadListScreenState();
}

// Lightweight model for the latest call from subcollection
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

  factory LatestCall.fromDoc(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;

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

class _LeadListScreenState extends State<LeadListScreen>
    with TickerProviderStateMixin {
  // Use the singleton instance so cache is shared across app
  final LeadService _service = LeadService.instance;

  // mutable lists used by the UI
  List<Lead> _allLeads = [];
  List<Lead> _filteredLeads = [];
  bool _loading = true;

  final TextEditingController _searchCtrl = TextEditingController();

  // State for the call filter
  String _selectedFilter = 'All';
  final List<String> _filters = [
    'All',
    'Incoming',
    'Outgoing',
    'Answered',
    'Missed',
    'Rejected',
    'Today', // today's follow-ups
  ];

  // Map leadId -> LatestCall (fetched from calls subcollection)
  final Map<String, LatestCall?> _latestCallByLead = {};
  bool _loadingLatestCalls = false;

  // pressed/active state for tap animation
  String? _pressedLeadId;

  // small animation controller for FAB pulse
  late final AnimationController _fabController;

  @override
  void initState() {
    super.initState();
    _fabController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _loadLeads();
    _searchCtrl.addListener(_applySearch);
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_applySearch);
    _searchCtrl.dispose();
    _fabController.dispose();
    super.dispose();
  }

  /// Fetch the single most recent call doc for the given lead.
  Future<LatestCall?> fetchLatestCallForLead(String leadId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tenantId =
          (prefs.getString('tenantId') ?? 'default_tenant').toString();

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
      // ignore: avoid_print
      print("fetchLatestCallForLead error for $leadId: $e\n$st");
      return null;
    }
  }

  /// Load leads and in parallel fetch latest calls (batched to avoid too many concurrent reads)
  Future<void> _loadLeads() async {
    setState(() => _loading = true);

    await _service.loadLeads();

    final fetched = _service.getAll();
    _allLeads = List<Lead>.from(fetched);

    // Clear previous latest map
    _latestCallByLead.clear();
    _loadingLatestCalls = true;

    // Fetch latest calls in batches to limit concurrent reads
    const int batchSize = 10;
    for (var i = 0; i < _allLeads.length; i += batchSize) {
      final batch = _allLeads.skip(i).take(batchSize).toList();
      final futures = batch.map((l) => fetchLatestCallForLead(l.id)).toList();
      final results = await Future.wait(futures);
      for (var j = 0; j < batch.length; j++) {
        _latestCallByLead[batch[j].id] = results[j];
      }
      setState(() {});
    }

    _applySearch(); // Apply search and filter after loading

    setState(() {
      _loading = false;
      _loadingLatestCalls = false;
    });
  }

  // Format a DateTime to 24-hour time (HH:mm) using local timezone.
  String _formatTime24(DateTime dt) {
    final local = dt.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  // Helper: is the provided DateTime 'today' local
  bool _isSameLocalDay(DateTime a, DateTime b) {
    final la = a.toLocal();
    final lb = b.toLocal();
    return la.year == lb.year && la.month == lb.month && la.day == lb.day;
  }

  // Count today's followups (based on lead.nextFollowUp if present, else ignore)
  int get todaysFollowupCount {
    final now = DateTime.now();
    return _allLeads.where((lead) {
      final nf = lead.nextFollowUp;
      if (nf == null) return false;
      return _isSameLocalDay(nf, now);
    }).length;
  }

  void _showTodayFollowups() {
    setState(() {
      _selectedFilter = 'Today';
      _applySearch();
    });
  }

  // --- Missed / Rejected detection using subcollection + outcome + duration ---
  bool _isMissedCall(LatestCall? latest) {
    if (latest == null) return false;

    final dir = latest.direction?.toLowerCase();
    final dur = latest.durationInSeconds ?? 0;
    final outcome = latest.finalOutcome ?? '';

    // Condition 1: inbound + 0 sec => missed
    if (dir == 'inbound' && dur == 0) return true;

    // Condition 2: finalOutcome explicitly "missed"
    if (outcome == 'missed') return true;

    return false;
  }

 bool _isRejectedCall(LatestCall? latest) {
  if (latest == null) return false;

  final dir = latest.direction?.toLowerCase();
  final dur = latest.durationInSeconds ?? 0;
  final outcome = latest.finalOutcome ?? '';

  // Only consider OUTGOING calls as "rejected"
  if (dir != 'outbound') return false;

  // outbound + 0 sec  OR  outbound + finalOutcome == "rejected"
  if (dur == 0) return true;
  if (outcome == 'rejected') return true;

  return false;
}


  void _applySearch() {
    final query = _searchCtrl.text.toLowerCase();

    // 1. Apply text search AND require that there IS a /calls doc
    List<Lead> searchFiltered = _allLeads.where((l) {
      final latest = _latestCallByLead[l.id];
      if (latest == null) return false; // ⛔ hide leads with no /calls
      return l.name.toLowerCase().contains(query) ||
          l.phoneNumber.contains(query);
    }).toList();

    // 2. Apply filter
    List<Lead> afterFilter = searchFiltered.where((l) {
      if (_selectedFilter == 'All') {
        // already guaranteed latest != null above
        return true;
      }

      if (_selectedFilter == 'Today') {
        final nf = l.nextFollowUp;
        if (nf == null) return false;
        return _isSameLocalDay(nf, DateTime.now());
      }

      final LatestCall? latest = _latestCallByLead[l.id];
      if (latest == null) return false; // defensive

      final direction = latest.direction?.toLowerCase();

      if (_selectedFilter == 'Answered') {
        return latest.durationInSeconds != null &&
            (latest.durationInSeconds! > 0);
      }

      if (_selectedFilter == 'Missed') {
        return _isMissedCall(latest);
      }

      if (_selectedFilter == 'Rejected') {
        return _isRejectedCall(latest);
      }

      if (_selectedFilter == 'Incoming') return direction == 'inbound';
      if (_selectedFilter == 'Outgoing') return direction == 'outbound';

      return false;
    }).toList();

    // 3. Sort strictly by latest call timestamps from /calls
    afterFilter.sort((a, b) {
      final la = _latestCallByLead[a.id];
      final lb = _latestCallByLead[b.id];

      final aTime =
          (la?.finalizedAt ?? la?.createdAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime =
          (lb?.finalizedAt ?? lb?.createdAt) ?? DateTime.fromMillisecondsSinceEpoch(0);

      return bTime.compareTo(aTime);
    });

    setState(() {
      _filteredLeads = afterFilter;
    });
  }

  // Method to handle filter change
  void _changeFilter(String filter) {
    setState(() {
      _selectedFilter = filter;
      _applySearch(); // Re-filter the list
    });
  }

  String _formatHeaderDate(DateTime dt) {
    final now = DateTime.now();
    if (_isSameLocalDay(dt, now)) return 'Today';
    final yesterday = now.subtract(const Duration(days: 1));
    if (_isSameLocalDay(dt, yesterday)) return 'Yesterday';
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  // Build grouped list: Map<header, List<Lead>>
  List<Widget> _buildGroupedList() {
    if (_filteredLeads.isEmpty) {
      return [
        const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text("No leads found matching current filters."),
          ),
        )
      ];
    }

    final Map<String, List<Lead>> grouped = {};
    final Map<String, DateTime> headerDateForKey = {};

    for (var lead in _filteredLeads) {
      final latest = _latestCallByLead[lead.id];
      if (latest == null) continue; // should not happen due to filtering

      final dt =
          (latest.finalizedAt ?? latest.createdAt) ??
              DateTime.fromMillisecondsSinceEpoch(0);

      final header = _formatHeaderDate(dt);
      grouped.putIfAbsent(header, () => []).add(lead);
      if (!headerDateForKey.containsKey(header)) {
        headerDateForKey[header] = dt;
      } else {
        if (dt.isAfter(headerDateForKey[header]!)) {
          headerDateForKey[header] = dt;
        }
      }
    }

    final headers = grouped.keys.toList()
      ..sort((a, b) => headerDateForKey[b]!.compareTo(headerDateForKey[a]!));

    final List<Widget> widgets = [];
    for (final header in headers) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Text(
            header,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
        ),
      );

      final leads = grouped[header]!;
      for (var i = 0; i < leads.length; i++) {
        widgets.add(_leadRow(leads[i]));
        if (i < leads.length - 1) {
          widgets.add(const Divider(height: 1, indent: 72));
        }
      }
    }

    return widgets;
  }

  // -----------------------------------------
  // DIALER / PHONE HELPERS
  // -----------------------------------------

  // Sanitize phone number and normalize for dialing/WhatsApp.
  String _sanitizePhone(String? raw) {
    if (raw == null) return '';
    var trimmed = raw.trim();

    if (trimmed.startsWith('+')) {
      final digits = trimmed.replaceAll(RegExp(r'[^0-9+]'), '');
      final normalized = '+' + digits.replaceAll('+', '');
      return normalized;
    }

    var digitsOnly = trimmed.replaceAll(RegExp(r'[^0-9]'), '');

    while (digitsOnly.startsWith('0')) {
      digitsOnly = digitsOnly.substring(1);
    }

    if (digitsOnly.length == 10) {
      return '+91$digitsOnly';
    }

    if (digitsOnly.length > 10 && digitsOnly.startsWith('91')) {
      return '+$digitsOnly';
    }

    if (digitsOnly.length > 10) {
      return '+$digitsOnly';
    }

    return digitsOnly;
  }

  Future<void> _openDialer(String? rawNumber) async {
    print("=== DIALER DEBUG START ===");

    final number = _sanitizePhone(rawNumber);
    print("Raw number: $rawNumber");
    print("Sanitized number: $number");

    if (number.isEmpty) {
      print("❌ No phone number found.");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No phone number available for this lead.'),
        ),
      );
      print("=== DIALER DEBUG END ===");
      return;
    }

    final uri = Uri(scheme: 'tel', path: number);
    print("Phone URI to launch: $uri");

    print("Platform: ${defaultTargetPlatform}");
    print("kIsWeb: $kIsWeb");

    try {
      final can = await canLaunchUrl(uri);
      print("canLaunchUrl(uri): $can");
    } catch (e) {
      print("❌ canLaunchUrl threw error: $e");
    }

    try {
      print("Trying launchUrl() with externalApplication...");
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      print("launchUrl result: $launched");

      if (launched) {
        print("✅ Dialer opened successfully.");
        print("=== DIALER DEBUG END ===");
        return;
      }

      print(
          "⚠️ launchUrl returned false; trying fallback launchUrlString...");
      final fallback = "tel:$number";
      bool fallbackResult = false;
      try {
        if (!kIsWeb) {
          fallbackResult = await launchUrlString(
            fallback,
            mode: LaunchMode.externalApplication,
          );
        } else {
          fallbackResult = await launchUrlString(fallback);
        }
      } catch (fe) {
        print("❌ fallback launch threw: $fe");
      }
      print("Fallback launchUrlString result: $fallbackResult");

      if (!fallbackResult) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open the dialer on this device.'),
          ),
        );
      }
    } catch (e, st) {
      print("❌ ERROR during launchUrl:");
      print("Error: $e");
      print("Stacktrace: $st");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Error while trying to open dialer.'),
        ),
      );
    }

    print("=== DIALER DEBUG END ===");
  }

  /// Open WhatsApp chat with the given phone number (uses wa.me).
  Future<void> _openWhatsApp(String? rawNumber) async {
    print("=== WHATSAPP DEBUG START ===");

    final normalized = _sanitizePhone(rawNumber);
    print("Raw WA number: $rawNumber");
    print("Normalized WA number: $normalized");

    if (normalized.isEmpty) {
      print("No number to open in WhatsApp.");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No phone number available")),
      );
      print("=== WHATSAPP DEBUG END ===");
      return;
    }

    final waPathNumber =
        normalized.startsWith('+') ? normalized.substring(1) : normalized;
    final waUri = Uri.parse("https://wa.me/$waPathNumber");
    final webWhatsapp =
        Uri.parse("https://web.whatsapp.com/send?phone=$waPathNumber");

    print("WhatsApp URI: $waUri");
    bool opened = false;

    try {
      opened = await launchUrl(waUri, mode: LaunchMode.externalApplication);
      print("launchUrl(waUri) result: $opened");
    } catch (e) {
      print("launchUrl(waUri) threw: $e");
    }

    if (!opened) {
      try {
        opened = await launchUrl(
          webWhatsapp,
          mode: LaunchMode.externalApplication,
        );
        print("launchUrl(webWhatsapp) result: $opened");
      } catch (e) {
        print("web.whatsapp launch threw: $e");
        opened = false;
      }
    }

    if (!opened) {
      try {
        final fallbackString = "https://wa.me/$waPathNumber";
        final fallbackLaunched = await launchUrlString(
          fallbackString,
          mode: LaunchMode.externalApplication,
        );
        print("launchUrlString fallback result: $fallbackLaunched");
        opened = fallbackLaunched;
      } catch (e) {
        print("launchUrlString fallback threw: $e");
      }
    }

    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Could not open WhatsApp.")),
      );
    }

    print("=== WHATSAPP DEBUG END ===");
  }

  // -----------------------------------------
  // UI: ANIMATED, GLOSSY LEAD ROW
  // -----------------------------------------
  Widget _leadRow(Lead lead) {
    final latest = _latestCallByLead[lead.id];

    // If somehow no latest (should already be filtered out), skip.
    if (latest == null) {
      return const SizedBox.shrink();
    }

    // duration & last time from latest call in subcollection
    String durationLabel = '';
    String lastCallTimeLabel = '';

    if (latest.durationInSeconds != null) {
      final d = latest.durationInSeconds!;
      final mins = d ~/ 60;
      final secs = d % 60;
      durationLabel = mins > 0 ? '${mins}m ${secs}s' : '${secs}s';
    }

    final dt = latest.finalizedAt ?? latest.createdAt;
    if (dt != null) {
      lastCallTimeLabel = _formatTime24(dt);
    }

    final subtitleText =
        '${lead.phoneNumber}${lead.nextFollowUp != null ? ' • ${lead.nextFollowUp!.day}/${lead.nextFollowUp!.month}' : ''}';

    final isPressed = _pressedLeadId == lead.id;

    // Missed / rejected badges
    final bool isMissed = _isMissedCall(latest);
    final bool isRejected = _isRejectedCall(latest);

    Widget? _buildStatusBadge() {
      if (isMissed) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.red.shade50,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.red.shade200),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.phone_missed,
                  size: 14, color: Colors.red.shade700),
              const SizedBox(width: 4),
              Text(
                'Missed',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.red.shade800,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        );
      }
      if (isRejected) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.red.shade50,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.red.shade200),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.call_end, size: 14, color: Colors.red.shade700),
              const SizedBox(width: 4),
              Text(
                'Rejected',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.red.shade800,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        );
      }
      return null;
    }

    final statusBadge = _buildStatusBadge();

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressedLeadId = lead.id),
      onTapCancel: () => setState(() => _pressedLeadId = null),
      onTapUp: (_) {
        setState(() => _pressedLeadId = null);
        Navigator.push(
          context,
          PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 280),
            pageBuilder: (_, __, ___) => LeadFormScreen(
              lead: lead,
              autoOpenedFromCall: false,
            ),
          ),
        ).then((_) => _loadLeads());
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          gradient: _cardGradient,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isPressed ? 0.12 : 0.06),
              blurRadius: isPressed ? 12 : 8,
              offset: Offset(0, isPressed ? 6 : 4),
            ),
          ],
          border: Border.all(color: Colors.black.withOpacity(0.02)),
        ),
        transform: Matrix4.identity()..scale(isPressed ? 0.995 : 1.0),
        child: Row(
          children: [
            // direction icon
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.white, _primaryColor.withOpacity(0.06)],
                ),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.black.withOpacity(0.04)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  )
                ],
              ),
              child: Center(child: _directionIcon(lead)),
            ),

            const SizedBox(width: 14),

            // Main text
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          lead.name.isEmpty ? 'No name' : lead.name,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: _primaryColor,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // ⏰ Last call time as chip (strictly from /calls)
                      if (lastCallTimeLabel.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.access_time,
                                size: 12,
                                color: Colors.blueGrey.shade400,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                lastCallTimeLabel,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.blueGrey.shade600,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          subtitleText,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.blueGrey.shade400,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (durationLabel.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(left: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            durationLabel,
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.blueGrey.shade700,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (statusBadge != null) ...[
                    const SizedBox(height: 6),
                    statusBadge,
                  ],
                ],
              ),
            ),

            const SizedBox(width: 8),

            // Call + WhatsApp (vertical)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(left: 8, bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.03),
                        blurRadius: 6,
                        offset: const Offset(0, 3),
                      )
                    ],
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.phone, size: 20),
                    color: _primaryColor,
                    padding: const EdgeInsets.all(8),
                    tooltip:
                        'Call ${lead.name.isEmpty ? lead.phoneNumber : lead.name}',
                    onPressed: () => _openDialer(lead.phoneNumber),
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.03),
                        blurRadius: 6,
                        offset: const Offset(0, 3),
                      )
                    ],
                  ),
                  child: IconButton(
                    iconSize: 20,
                    padding: const EdgeInsets.all(8),
                    tooltip:
                        'WhatsApp ${lead.name.isEmpty ? lead.phoneNumber : lead.name}',
                    icon: Image.network(
                      'https://upload.wikimedia.org/wikipedia/commons/5/5e/WhatsApp_icon.png',
                      width: 20,
                      height: 20,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.message, size: 20),
                    ),
                    onPressed: () => _openWhatsApp(lead.phoneNumber),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _directionIcon(Lead lead) {
    final latest = _latestCallByLead[lead.id];
    final dir = latest?.direction?.toLowerCase();
    if (dir == 'inbound') {
      return Icon(Icons.call_received,
          color: Colors.green.shade700, size: 20);
    }
    if (dir == 'outbound') {
      return const Icon(Icons.call_made, color: _primaryColor, size: 20);
    }
    return Icon(Icons.person,
        color: Colors.blueGrey.shade600, size: 20);
  }

  // -----------------------------------------
  // MAIN UI
  // -----------------------------------------
  @override
  Widget build(BuildContext context) {
    final groupedWidgets = _buildGroupedList();

    return Scaffold(
      backgroundColor: _mutedBg,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(88),
        child: Container(
          decoration: BoxDecoration(
            gradient: _appBarGradient,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 10,
              )
            ],
          ),
          child: SafeArea(
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Leads',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 6),
                        Text(
                          'Recent activity and calls',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (ctx) {
                          return AlertDialog(
                            content: TextField(
                              controller: _searchCtrl,
                              autofocus: true,
                              decoration: const InputDecoration(
                                hintText: 'Search by name or phone',
                              ),
                            ),
                          );
                        },
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            _accentColor.withOpacity(0.95),
                            _accentColor.withOpacity(0.7),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.12),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          )
                        ],
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.search, color: Colors.black87),
                          SizedBox(width: 8),
                          Text(
                            'Search',
                            style: TextStyle(color: Colors.black87),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: ScaleTransition(
        scale: Tween(begin: 0.98, end: 1.04).animate(
          CurvedAnimation(
            parent: _fabController,
            curve: Curves.easeInOut,
          ),
        ),
        child: GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => LeadFormScreen(
                  lead: Lead.newLead(""),
                  autoOpenedFromCall: false,
                ),
              ),
            ).then((_) => _loadLeads());
          },
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  _accentColor,
                  _accentColor.withOpacity(0.85),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: _accentColor.withOpacity(0.4),
                  blurRadius: 18,
                  offset: const Offset(0, 10),
                )
              ],
            ),
            child: const Icon(Icons.add, color: _primaryColor, size: 30),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (todaysFollowupCount > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16.0,
                      vertical: 10,
                    ),
                    child: InkWell(
                      onTap: _showTodayFollowups,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.orange.withOpacity(0.25),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.event_available,
                              color: Colors.orange.shade800,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                "Today's follow-ups: $todaysFollowupCount — tap to view",
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Colors.orange.shade900,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: _showTodayFollowups,
                              child: const Text('VIEW'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // SEARCH BAR
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16.0),
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      prefixIcon:
                          const Icon(Icons.search, color: _primaryColor),
                      hintText: "Search by name or phone",
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(
                          color: _primaryColor,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // FILTER CHIPS
                SizedBox(
                  height: 44,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _filters.length,
                    itemBuilder: (_, i) {
                      final filter = _filters[i];
                      final isSelected = _selectedFilter == filter;
                      return Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: AnimatedContainer(
                          duration:
                              const Duration(milliseconds: 260),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: isSelected
                                ? [
                                    BoxShadow(
                                      color: _primaryColor
                                          .withOpacity(0.12),
                                      blurRadius: 12,
                                      offset: const Offset(0, 6),
                                    )
                                  ]
                                : [
                                    BoxShadow(
                                      color: Colors.black
                                          .withOpacity(0.02),
                                      blurRadius: 4,
                                    )
                                  ],
                            border: Border.all(
                              color: isSelected
                                  ? _primaryColor
                                  : Colors.grey.shade200,
                            ),
                          ),
                          child: ChoiceChip(
                            label: Text(
                              filter,
                              style: TextStyle(
                                color: isSelected
                                    ? _primaryColor
                                    : Colors.black87,
                                fontWeight: isSelected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                            selected: isSelected,
                            onSelected: (_) => _changeFilter(filter),
                            backgroundColor: Colors.transparent,
                            selectedColor: Colors.transparent,
                          ),
                        ),
                      );
                    },
                  ),
                ),

                const SizedBox(height: 10),

                Expanded(
                  child: ListView(
                    children: groupedWidgets,
                  ),
                ),
              ],
            ),
    );
  }
}
