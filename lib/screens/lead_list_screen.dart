// lib/screens/lead_list_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // defaultTargetPlatform, kIsWeb
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/lead.dart';
import '../services/lead_service.dart';
import 'lead_form_screen.dart';
import '../widgets/gradient_appbar_title.dart';
// -------------------------------------------------------------------------
// ✨ Premium dark glass theme (matched to web admin)
// -------------------------------------------------------------------------
const Color _bgDark1 = Color(0xFF0B1220); // from web: --bg-1
const Color _bgDark2 = Color(0xFF061028); // from web: --bg-2
const Color _primaryColor = Color(0xFF0F172A); // card base
const Color _accentIndigo = Color(0xFF6C5CE7); // --accent
const Color _accentCyan = Color(0xFF00D4FF); // --accent2
const Color _mutedText = Color(0xFF9FB0C4);
const Color _dangerColor = Color(0xFFFF6B6B);
const Color _successColor = Color(0xFF00FF9D);

const Gradient _appBarGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [
    _bgDark1,
    _bgDark2,
  ],
);

const Gradient _cardGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [
    Color(0xFF111827),
    Color(0xFF020617),
  ],
);

const BoxShadow _softGlow = BoxShadow(
  color: Color.fromARGB(180, 2, 6, 23),
  blurRadius: 28,
  offset: Offset(0, 18),
);

// Lightweight model for the latest call (only from /calls subcollection)
class LatestCall {
  final String? callId;
  final String? phoneNumber;
  final String? direction; // inbound / outbound
  final int? durationInSeconds;
  final DateTime? createdAt;
  final DateTime? finalizedAt;
  final String? finalOutcome;

  // you might already have handledByUserName etc added here in your project;
  // keep your extra fields if you have them.
  final String? handledByUserName;

  LatestCall({
    this.callId,
    this.phoneNumber,
    this.direction,
    this.durationInSeconds,
    this.createdAt,
    this.finalizedAt,
    this.finalOutcome,
    this.handledByUserName,
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
      handledByUserName: (data['handledByUserName'] as String?)?.trim(),
    );
  }
}

class LeadListScreen extends StatefulWidget {
  /// Optional initial filter ("All", "Incoming", "Outgoing", "Missed", "Rejected", "Today")
  final String? initialFilter;

  const LeadListScreen({
    super.key,
    this.initialFilter,
  });

  @override
  State<LeadListScreen> createState() => _LeadListScreenState();
}

class _LeadListScreenState extends State<LeadListScreen>
    with TickerProviderStateMixin {
  // Use singleton so cache is shared
  final LeadService _service = LeadService.instance;

  List<Lead> _allLeads = [];
  List<Lead> _filteredLeads = [];
  bool _loading = true;
  

final ScrollController _scrollCtrl = ScrollController();


  final TextEditingController _searchCtrl = TextEditingController();

  // Filter state
  String _selectedFilter = 'All';
  final List<String> _filters = const [
    'All',
    'Incoming',
    'Outgoing',
    'Answered',
    'Missed',
    'Rejected',
    'Today',
  ];

  // Map leadId -> LatestCall from /calls subcollection
  final Map<String, LatestCall?> _latestCallByLead = {};
  bool _loadingLatestCalls = false;

  // For press animation
  String? _pressedLeadId;

  late final AnimationController _fabController;

@override
void initState() {
  super.initState();

  _fabController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  // Use initial filter from caller (Missed / Incoming / etc)
  _selectedFilter = widget.initialFilter ?? 'All';

  // 🔹 Load leads + all calls ONCE
  _loadLeads();

  // 🔹 Search works fully in-memory
  _searchCtrl.addListener(_applySearch);
}



  @override
void dispose() {
  _searchCtrl.removeListener(_applySearch);
  _searchCtrl.dispose();
  _scrollCtrl.dispose();
  _fabController.dispose();
  super.dispose();
}


  // ---------------------------------------------------------------------------
  // FIRESTORE LOADERS
  // ---------------------------------------------------------------------------



  /// Load leads and in parallel fetch latest calls; only keep leads that
  /// actually have at least one /calls doc.
Future<void> _loadLeads() async {
  setState(() => _loading = true);

  // 1️⃣ Load all leads
  await _service.loadLeads();
  _allLeads = List<Lead>.from(_service.getAll());

  // 2️⃣ Load ALL calls once (like HomeScreen)
  final prefs = await SharedPreferences.getInstance();
  final tenantId = prefs.getString('tenantId') ?? 'default_tenant';

  final callSnap = await FirebaseFirestore.instance
      .collectionGroup('calls')
      .where('tenantId', isEqualTo: tenantId)
      .get();

  // 3️⃣ Normalize calls → latest call per PHONE NUMBER
  final Map<String, LatestCall> latestByPhone = {};

  for (final doc in callSnap.docs) {
    final call = LatestCall.fromDoc(doc);

    final phone = call.phoneNumber;
    if (phone == null || phone.isEmpty) continue;

    final callTime = call.finalizedAt ?? call.createdAt;
    if (callTime == null) continue;

    final existing = latestByPhone[phone];
    if (existing == null) {
      latestByPhone[phone] = call;
    } else {
      final existingTime =
          existing.finalizedAt ??
          existing.createdAt ??
          DateTime.fromMillisecondsSinceEpoch(0);

      if (callTime.isAfter(existingTime)) {
        latestByPhone[phone] = call;
      }
    }
  }

  // 4️⃣ Attach latest call to leads using phoneNumber
  _latestCallByLead.clear();

  for (final lead in _allLeads) {
    final phone = lead.phoneNumber.trim();
    if (latestByPhone.containsKey(phone)) {
      _latestCallByLead[lead.id] = latestByPhone[phone];
    }
  }

  // 5️⃣ Sort leads by latest activity (call → fallback)
  _allLeads.sort((a, b) {
    final aTime =
        (_latestCallByLead[a.id]?.finalizedAt ??
                _latestCallByLead[a.id]?.createdAt) ??
            a.lastInteraction ??
            DateTime.fromMillisecondsSinceEpoch(0);

    final bTime =
        (_latestCallByLead[b.id]?.finalizedAt ??
                _latestCallByLead[b.id]?.createdAt) ??
            b.lastInteraction ??
            DateTime.fromMillisecondsSinceEpoch(0);

    return bTime.compareTo(aTime);
  });

  // 6️⃣ Apply filters
  _applySearch();

  if (mounted) {
    setState(() => _loading = false);
  }
}



  // ---------------------------------------------------------------------------
  // TIME HELPERS
  // ---------------------------------------------------------------------------

  String _formatTime24(DateTime dt) {
    final local = dt.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  bool _isSameLocalDay(DateTime a, DateTime b) {
    final la = a.toLocal();
    final lb = b.toLocal();
    return la.year == lb.year && la.month == lb.month && la.day == lb.day;
  }

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

  // ---------------------------------------------------------------------------
  // MISSED / REJECTED HEURISTICS (only from /calls)
  // ---------------------------------------------------------------------------

  bool _isMissedCall(LatestCall? latest) {
    if (latest == null) return false;

    final dir = latest.direction?.toLowerCase();
    final dur = latest.durationInSeconds ?? 0;
    final outcome = (latest.finalOutcome ?? '').toLowerCase();

    // inbound + 0 sec OR explicit missed
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

  // ---------------------------------------------------------------------------
  // SEARCH + FILTER
  // ---------------------------------------------------------------------------

  void _applySearch() {
  

  final query = _searchCtrl.text.toLowerCase();

  // ------------------------------------------------------------------
  // 1. TEXT SEARCH
  // ------------------------------------------------------------------
  List<Lead> searchFiltered = _allLeads.where((l) {
    final matchesQuery =
        l.name.toLowerCase().contains(query) ||
        l.phoneNumber.contains(query);

    if (!matchesQuery) return false;

    // 🔹 "All" allows leads even if latest call not loaded yet
    if (_selectedFilter == 'All') return true;

    // 🔹 Other filters require latest call
    return _latestCallByLead[l.id] != null;
  }).toList();

  // ------------------------------------------------------------------
  // 2. APPLY FILTER (call-based filters)
  // ------------------------------------------------------------------
  List<Lead> afterFilter = searchFiltered.where((l) {
    if (_selectedFilter == 'All') return true;

    if (_selectedFilter == 'Today') {
      final nf = l.nextFollowUp;
      if (nf == null) return false;
      return _isSameLocalDay(nf, DateTime.now());
    }

    final LatestCall? latest = _latestCallByLead[l.id];
    if (latest == null) return false;

    final direction = latest.direction?.toLowerCase();
    final dur = latest.durationInSeconds ?? 0;

    if (_selectedFilter == 'Answered') return dur > 0;
    if (_selectedFilter == 'Missed') return _isMissedCall(latest);
    if (_selectedFilter == 'Rejected') return _isRejectedCall(latest);
    if (_selectedFilter == 'Incoming') return direction == 'inbound';
    if (_selectedFilter == 'Outgoing') return direction == 'outbound';

    return false;
  }).toList();

  // ------------------------------------------------------------------
  // 3. SORT — LATEST FIRST (calls → interaction → fallback)
  // ------------------------------------------------------------------
  afterFilter.sort((a, b) {
    final DateTime aTime =
        (_latestCallByLead[a.id]?.finalizedAt ??
                _latestCallByLead[a.id]?.createdAt) ??
            a.lastInteraction ??
            DateTime.fromMillisecondsSinceEpoch(0);

    final DateTime bTime =
        (_latestCallByLead[b.id]?.finalizedAt ??
                _latestCallByLead[b.id]?.createdAt) ??
            b.lastInteraction ??
            DateTime.fromMillisecondsSinceEpoch(0);

    return bTime.compareTo(aTime);
  });

  setState(() {
    _filteredLeads = afterFilter;
  });
}


  void _changeFilter(String filter) {
    setState(() {
      _selectedFilter = filter;
      _applySearch();
    });
  }

  String _formatHeaderDate(DateTime dt) {
    final now = DateTime.now();
    if (_isSameLocalDay(dt, now)) return 'Today';
    final yesterday = now.subtract(const Duration(days: 1));
    if (_isSameLocalDay(dt, yesterday)) return 'Yesterday';
    const months = [
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

  List<Widget> _buildGroupedList() {
    if (_filteredLeads.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.02),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withOpacity(0.04)),
            ),
            child: const Center(
              child: Text(
                "No leads found matching current filters.",
                style: TextStyle(
                  color: _mutedText,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        )
      ];
    }

    final Map<String, List<Lead>> grouped = {};
    final Map<String, DateTime> headerDateForKey = {};

    for (var lead in _filteredLeads) {
      final latest = _latestCallByLead[lead.id];
      final dt =
          (latest?.finalizedAt ?? latest?.createdAt) ?? lead.lastInteraction;

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
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
          child: Text(
            header,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: Colors.white,
              fontSize: 14,
            ),
          ),
        ),
      );

      final leads = grouped[header]!;
      for (var i = 0; i < leads.length; i++) {
        widgets.add(_leadRow(leads[i]));
        if (i < leads.length - 1) {
          widgets.add(
            Divider(
              height: 1,
              indent: 72,
              color: Colors.white.withOpacity(0.04),
            ),
          );
        }
      }
    }

    return widgets;
  }

  // ---------------------------------------------------------------------------
  // PHONE HELPERS
  // ---------------------------------------------------------------------------

  // Normalize phone for dialing / WhatsApp
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

      print("⚠️ launchUrl returned false; trying fallback launchUrlString...");
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
        const SnackBar(content: Text('Error while trying to open dialer.')),
      );
    }

    print("=== DIALER DEBUG END ===");
  }

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

  // ---------------------------------------------------------------------------
  // ROW UI
  // ---------------------------------------------------------------------------

  Widget _leadRow(Lead lead) {
    final latest = _latestCallByLead[lead.id];

    String durationLabel = '';
    String lastCallTimeLabel = '';

    if (latest != null) {
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
    }

    if (lastCallTimeLabel.isEmpty && lead.lastInteraction != null) {
      lastCallTimeLabel = _formatTime24(lead.lastInteraction);
    }

    final subtitleText =
        '${lead.phoneNumber}${lead.nextFollowUp != null ? ' • ${lead.nextFollowUp!.day}/${lead.nextFollowUp!.month}' : ''}';

    final isPressed = _pressedLeadId == lead.id;

    // BADGES for missed / rejected
    final bool isMissed = _isMissedCall(latest);
    final bool isRejected = _isRejectedCall(latest);

    Widget? badge;
    if (isMissed) {
      badge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: _dangerColor.withOpacity(0.08),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          'MISSED',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: _dangerColor.withOpacity(0.9),
          ),
        ),
      );
    } else if (isRejected) {
      badge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: _dangerColor.withOpacity(0.08),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          'REJECTED',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: _dangerColor.withOpacity(0.9),
          ),
        ),
      );
    }

    final String? handlerName =
        latest?.handledByUserName?.trim().isNotEmpty == true
            ? latest!.handledByUserName!.trim()
            : null;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressedLeadId = lead.id),
      onTapCancel: () => setState(() => _pressedLeadId = null),
      onTapUp: (_) {
        setState(() => _pressedLeadId = null);
        Navigator.push(
          context,
          PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 280),
            pageBuilder: (_, __, ___) =>
                LeadFormScreen(lead: lead, autoOpenedFromCall: false),
          ),
        ).then((_) => _loadLeads()); // refresh when returning
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          gradient: _cardGradient,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color:
                  Colors.black.withOpacity(isPressed ? 0.6 : 0.45), // deep glow
              blurRadius: isPressed ? 28 : 20,
              offset: Offset(0, isPressed ? 18 : 14),
            ),
          ],
          border: Border.all(
            color: Colors.white.withOpacity(0.04),
          ),
        ),
        transform: Matrix4.identity()
          ..scale(isPressed ? 0.992 : 1.0)
          ..translate(0.0, isPressed ? 1.0 : 0.0),
        child: Row(
          children: [
            // icon
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    _accentIndigo.withOpacity(0.24),
                    _accentCyan.withOpacity(0.16),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.06)),
                boxShadow: const [
                  BoxShadow(
                    color: Color.fromARGB(120, 15, 23, 42),
                    blurRadius: 18,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Center(child: _directionIcon(lead)),
            ),
            const SizedBox(width: 14),

            // main text
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // top row: name + badge + time
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          lead.name.isEmpty ? 'No name' : lead.name,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (badge != null) badge,
                      if (badge != null) const SizedBox(width: 6),
                      Text(
                        lastCallTimeLabel.isNotEmpty ? lastCallTimeLabel : '',
                        style: TextStyle(
                          fontSize: 12,
                          color: _mutedText.withOpacity(0.9),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 6),

                  // second row: PHONE (full) + duration
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          subtitleText,
                          style: TextStyle(
                            fontSize: 13,
                            color: _mutedText,
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
                            color: Colors.white.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            durationLabel,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),

                  // third row: handler pill alone
                  if (handlerName != null) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.06),
                            ),
                            color: Colors.white.withOpacity(0.04),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.person_outline,
                                size: 13,
                                color: _mutedText,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                handlerName,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(width: 8),

            // call + whatsapp buttons, vertical
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(left: 8, bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: const [
                      BoxShadow(
                        color: Color.fromARGB(100, 15, 23, 42),
                        blurRadius: 18,
                        offset: Offset(0, 10),
                      ),
                    ],
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.phone, size: 20),
                    color: _successColor.withOpacity(0.9),
                    padding: const EdgeInsets.all(8),
                    tooltip:
                        'Call ${lead.name.isEmpty ? lead.phoneNumber : lead.name}',
                    onPressed: () => _openDialer(lead.phoneNumber),
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: const [
                      BoxShadow(
                        color: Color.fromARGB(100, 15, 23, 42),
                        blurRadius: 18,
                        offset: Offset(0, 10),
                      ),
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
          color: _successColor.withOpacity(0.9), size: 22);
    }
    if (dir == 'outbound') {
      return Icon(Icons.call_made,
          color: _accentIndigo.withOpacity(0.9), size: 22);
    }
    return Icon(Icons.person,
        color: _mutedText.withOpacity(0.9), size: 20);
  }

  // ---------------------------------------------------------------------------
  // MAIN UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final groupedWidgets = _buildGroupedList();

    return Scaffold(
      backgroundColor: _bgDark1,
      appBar: PreferredSize(
  preferredSize: const Size.fromHeight(88),
  child: Container(
    decoration: BoxDecoration(
      gradient: _appBarGradient,
      boxShadow: const [
        BoxShadow(
          color: Color.fromARGB(220, 3, 7, 18),
          blurRadius: 26,
          offset: Offset(0, 16),
        ),
      ],
    ),
    child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  // ✅ gradient text like admin navbar
                  GradientAppBarTitle(
                    'Leads',
                    fontSize: 20,
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Recent activity and calls',
                    style: TextStyle(
                      color: _mutedText,
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
                      backgroundColor: _primaryColor,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      content: TextField(
                        controller: _searchCtrl,
                        autofocus: true,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          hintText: 'Search by name or phone',
                          hintStyle:
                              TextStyle(color: _mutedText, fontSize: 14),
                          enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: _mutedText),
                          ),
                          focusedBorder: UnderlineInputBorder(
                            borderSide:
                                BorderSide(color: _accentCyan, width: 1.4),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      _accentIndigo,
                      _accentCyan,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: const [
                    BoxShadow(
                      color: Color.fromARGB(180, 12, 24, 80),
                      blurRadius: 18,
                      offset: Offset(0, 10),
                    ),
                  ],
                ),
                child: const Row(
                  children: [
                    Icon(Icons.search,
                        color: Colors.black87, size: 18),
                    SizedBox(width: 8),
                    Text(
                      'Search',
                      style: TextStyle(
                        color: Colors.black87,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
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
            ).then((_) => _loadLeads()); // refresh after new lead
          },
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFFFFC857),
                  const Color(0xFFFFC857).withOpacity(0.9),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
              boxShadow: const [
                BoxShadow(
                  color: Color.fromARGB(200, 255, 200, 80),
                  blurRadius: 26,
                  offset: Offset(0, 14),
                ),
              ],
            ),
            child: const Icon(Icons.add, color: _primaryColor, size: 30),
          ),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _bgDark1,
              _bgDark2,
            ],
          ),
        ),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  if (todaysFollowupCount > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16.0, vertical: 10),
                      child: InkWell(
                        onTap: _showTodayFollowups,
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.orange.withOpacity(0.20),
                                Colors.orange.withOpacity(0.08),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Colors.orange.withOpacity(0.45),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.event_available,
                                color: Colors.orange.shade200,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Today\'s follow-ups: $todaysFollowupCount — tap to view',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: Colors.orange.shade50,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: _showTodayFollowups,
                                child: const Text(
                                  'VIEW',
                                  style: TextStyle(color: Colors.white),
                                ),
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
                      style: const TextStyle(color: Colors.white),
                      cursorColor: _accentCyan,
                      decoration: InputDecoration(
                        prefixIcon:
                            const Icon(Icons.search, color: Colors.white70),
                        hintText: "Search by name or phone",
                        hintStyle: const TextStyle(
                            color: _mutedText, fontSize: 14),
                        filled: true,
                        fillColor: const Color(0xFF0F172A),
                        contentPadding: const EdgeInsets.symmetric(
                            vertical: 12, horizontal: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: Colors.white.withOpacity(0.04),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: Colors.white.withOpacity(0.04),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(
                            color: _accentCyan,
                            width: 1.6,
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // FILTER CHIPS
                  // FILTER CHIPS
SizedBox(
  height: 48,
  child: ListView.separated(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    itemCount: _filters.length,
    separatorBuilder: (_, __) => const SizedBox(width: 10),
    itemBuilder: (_, i) {
      final filter = _filters[i];
      final bool isSelected = _selectedFilter == filter;

      return GestureDetector(
        onTap: () => _changeFilter(filter), // 🔹 same logic
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 8,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            gradient: isSelected
                ? const LinearGradient(
                    colors: [
                      _accentIndigo,
                      _accentCyan,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            color: isSelected
                ? null
                : const Color(0xFF0F172A), // dark pill for unselected
            border: Border.all(
              color: isSelected
                  ? Colors.white.withOpacity(0.85)
                  : Colors.white.withOpacity(0.14),
            ),
            boxShadow: isSelected
                ? const [
                    BoxShadow(
                      color: Color.fromARGB(140, 37, 99, 235),
                      blurRadius: 16,
                      offset: Offset(0, 8),
                    ),
                  ]
                : [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.45),
                      blurRadius: 10,
                      offset: const Offset(0, 6),
                    ),
                  ],
          ),
          child: Center(
            child: Text(
              filter,
              style: TextStyle(
                fontSize: 13,
                fontWeight:
                    isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? Colors.black : Colors.white,
              ),
            ),
          ),
        ),
      );
    },
  ),
),


                  const SizedBox(height: 10),

                  // LIST with pull-to-refresh
               Expanded(
  child: RefreshIndicator(
    color: _accentCyan,
    backgroundColor: _primaryColor,
    onRefresh: _loadLeads,
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: groupedWidgets,
    ),
  ),
),

                ],
              ),
      ),
    );
  }
}
