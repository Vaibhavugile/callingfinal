// lib/screens/lead_list_screen.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/lead.dart';
import '../services/lead_service.dart';
import 'lead_form_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

// -------------------------------------------------------------------------
// ✨ Premium visual theme (gradients, glossy accents, subtle animations)
// -------------------------------------------------------------------------
const Color _primaryColor = Color(0xFF0F172A); // Deep navy
const Color _accentColor = Color(0xFFFFC857); // Warm gold
const Color _mutedBg = Color(0xFFF4F6F9);
const Gradient _appBarGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF0F172A), Color(0xFF1E2A78)],
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

// Lightweight model for the latest call (kept local here to avoid requiring lead.dart edits)
class LatestCall {
  final String? callId;
  final String? phoneNumber;
  final String? direction; // inbound / outbound
  final int? durationInSeconds;
  final DateTime? createdAt;
  final DateTime? finalizedAt;

  LatestCall({
    this.callId,
    this.phoneNumber,
    this.direction,
    this.durationInSeconds,
    this.createdAt,
    this.finalizedAt,
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
      durationInSeconds: data['durationInSeconds'] is num ? (data['durationInSeconds'] as num).toInt() : null,
      createdAt: _toDate(data['createdAt']),
      finalizedAt: _toDate(data['finalizedAt']),
    );
  }
}

class _LeadListScreenState extends State<LeadListScreen> with TickerProviderStateMixin {
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
    'Needs Review',
    'Incoming',
    'Outgoing',
    'Answered',
    'Missed',
    'Rejected',
    'Today' // today's follow-ups
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
    _fabController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);
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
      // Read tenantId from Flutter SharedPreferences (same place AuthService writes)
      final prefs = await SharedPreferences.getInstance();
      final tenantId = (prefs.getString('tenantId') ?? 'default_tenant').toString();

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
      // keep UI resilient: log and return null
      // single-line print with escaped newline to avoid source-line breaks
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

  void _applySearch() {
    final query = _searchCtrl.text.toLowerCase();

    // 1. Apply text search
    List<Lead> searchFiltered = _allLeads.where((l) {
      return l.name.toLowerCase().contains(query) || l.phoneNumber.contains(query);
    }).toList();

    // 2. Apply call/review filter - use _latestCallByLead only (no fallback to callHistory array)
    List<Lead> afterFilter = searchFiltered.where((l) {
      if (_selectedFilter == 'All') return true;

      if (_selectedFilter == 'Today') {
        final nf = l.nextFollowUp;
        if (nf == null) return false;
        return _isSameLocalDay(nf, DateTime.now());
      }

      if (_selectedFilter == 'Needs Review') return l.needsManualReview;

      final LatestCall? latest = _latestCallByLead[l.id];
      // If we require call-specific filters but there's no latest call yet, don't match
      if (latest == null) return false;

      final direction = latest.direction?.toLowerCase();

      if (_selectedFilter == 'Answered') return latest.durationInSeconds != null && (latest.durationInSeconds! > 0);
      if (_selectedFilter == 'Missed') return false; // cannot reliably detect missed without outcome field
      if (_selectedFilter == 'Rejected') return false;
      if (_selectedFilter == 'Incoming') return direction == 'inbound';
      if (_selectedFilter == 'Outgoing') return direction == 'outbound';

      return false;
    }).toList();

    // Sort by most recent call time (if available) or lead.lastInteraction
    afterFilter.sort((a, b) {
      DateTime aTime = (_latestCallByLead[a.id]?.finalizedAt ?? _latestCallByLead[a.id]?.createdAt) ?? a.lastInteraction;
      DateTime bTime = (_latestCallByLead[b.id]?.finalizedAt ?? _latestCallByLead[b.id]?.createdAt) ?? b.lastInteraction;
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

  String? timeAgoShort(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }

  String _formatHeaderDate(DateTime dt) {
    final now = DateTime.now();
    if (_isSameLocalDay(dt, now)) return 'Today';
    final yesterday = now.subtract(const Duration(days: 1));
    if (_isSameLocalDay(dt, yesterday)) return 'Yesterday';
    final months = [
      'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
    ];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  // Build grouped list: Map<header, List<Lead>>
  List<Widget> _buildGroupedList() {
    if (_filteredLeads.isEmpty) {
      return [const Center(child: Padding(padding: EdgeInsets.all(16), child: Text("No leads found matching current filters.")))];
    }

    final Map<String, List<Lead>> grouped = {};
    final Map<String, DateTime> headerDateForKey = {};

    for (var lead in _filteredLeads) {
      final dt = (_latestCallByLead[lead.id]?.finalizedAt ?? _latestCallByLead[lead.id]?.createdAt) ?? lead.lastInteraction;
      final header = _formatHeaderDate(dt);
      grouped.putIfAbsent(header, () => []).add(lead);
      if (!headerDateForKey.containsKey(header)) headerDateForKey[header] = dt;
      else {
        if (dt.isAfter(headerDateForKey[header]!)) headerDateForKey[header] = dt;
      }
    }

    final headers = grouped.keys.toList()..sort((a,b) => headerDateForKey[b]!.compareTo(headerDateForKey[a]!));

    final List<Widget> widgets = [];
    for (final header in headers) {
      widgets.add(Padding(
        padding: const EdgeInsets.fromLTRB(16,12,16,6),
        child: Text(header, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
      ));

      final leads = grouped[header]!;
      for (var i = 0; i < leads.length; i++) {
        widgets.add(_leadRow(leads[i]));
        if (i < leads.length - 1) widgets.add(const Divider(height: 1, indent: 72));
      }
    }

    return widgets;
  }

  // -----------------------------------------
  // UI: ANIMATED, GLOSSY LEAD ROW (shows duration + last call time)
  // -----------------------------------------
  Widget _leadRow(Lead lead) {
    final bool needsReview = lead.needsManualReview;
    final latest = _latestCallByLead[lead.id];

    // duration & last time from latest call in subcollection
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
      if (dt != null) lastCallTimeLabel = timeAgoShort(dt) ?? '';
    }

    final subtitleText = '${lead.phoneNumber}${lead.nextFollowUp != null ? ' • ${lead.nextFollowUp!.day}/${lead.nextFollowUp!.month}' : ''}';

    final isPressed = _pressedLeadId == lead.id;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressedLeadId = lead.id),
      onTapCancel: () => setState(() => _pressedLeadId = null),
      onTapUp: (_) {
        setState(() => _pressedLeadId = null);
        Navigator.push(
          context,
          PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 280),
            pageBuilder: (_, __, ___) => LeadFormScreen(lead: lead, autoOpenedFromCall: false),
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
            // direction icon instead of avatar — use only subcollection direction
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [Colors.white, _primaryColor.withOpacity(0.06)]),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.black.withOpacity(0.04)),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 6, offset: const Offset(0, 3))],
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
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: needsReview ? _accentColor : _primaryColor),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        // show last call time (short) if available, else fallback to lead lastInteraction
                        lastCallTimeLabel.isNotEmpty ? lastCallTimeLabel : _leadTimeLabel(lead),
                        style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade400),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          subtitleText,
                          style: TextStyle(fontSize: 13, color: Colors.blueGrey.shade400),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // show duration only (no outcome)
                      if (durationLabel.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(left: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            durationLabel,
                            style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade700, fontWeight: FontWeight.w800),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(width: 8),
            // removed quick action icons as requested
          ],
        ),
      ),
    );
  }

  Widget _directionIcon(Lead lead) {
    final latest = _latestCallByLead[lead.id];
    final dir = latest?.direction?.toLowerCase();
    if (dir == 'inbound') return Icon(Icons.call_received, color: Colors.green.shade700, size: 20);
    if (dir == 'outbound') return Icon(Icons.call_made, color: _primaryColor, size: 20);
    return Icon(Icons.person, color: Colors.blueGrey.shade600, size: 20);
  }

  String _leadTimeLabel(Lead lead) {
    final latest = _latestCallByLead[lead.id];
    final dt = (latest?.finalizedAt ?? latest?.createdAt) ?? lead.lastInteraction;
    final diff = DateTime.now().difference(dt);
    if (diff.inHours < 24) {
      if (diff.inMinutes < 60) return '${diff.inMinutes}m';
      return '${diff.inHours}h';
    }
    return '${dt.day}/${dt.month}/${dt.year.toString().substring(2)}';
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
          decoration: BoxDecoration(gradient: _appBarGradient, boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 10)]),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text('Leads', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                        SizedBox(height: 6),
                        Text('Recent activity and calls', style: TextStyle(color: Colors.white70, fontSize: 13)),
                      ],
                    ),
                  ),
                  // small gradient rounded search shortcut
                  GestureDetector(
                    onTap: () {
                      // focus the search field by opening a dialog with the search input
                      showDialog(context: context, builder: (ctx) {
                        return AlertDialog(
                          content: TextField(
                            controller: _searchCtrl,
                            autofocus: true,
                            decoration: const InputDecoration(hintText: 'Search by name or phone'),
                          ),
                        );
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [_accentColor.withOpacity(0.95), _accentColor.withOpacity(0.7)]),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 8, offset: const Offset(0, 3))],
                      ),
                      child: Row(
                        children: const [Icon(Icons.search, color: Colors.black87), SizedBox(width: 8), Text('Search', style: TextStyle(color: Colors.black87))],
                      ),
                    ),
                  )
                ],
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: ScaleTransition(
        scale: Tween(begin: 0.98, end: 1.04).animate(CurvedAnimation(parent: _fabController, curve: Curves.easeInOut)),
        child: GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                // Opens form for a new, empty lead.
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
              gradient: LinearGradient(colors: [_accentColor, _accentColor.withOpacity(0.85)], begin: Alignment.topLeft, end: Alignment.bottomRight),
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: _accentColor.withOpacity(0.4), blurRadius: 18, offset: const Offset(0, 10))],
            ),
            child: Icon(Icons.add, color: _primaryColor, size: 30),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // TODAY FOLLOWUPS BANNER
                if (todaysFollowupCount > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10),
                    child: InkWell(
                      onTap: _showTodayFollowups,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.orange.withOpacity(0.25)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.event_available, color: Colors.orange.shade800),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Today\'s follow-ups: $todaysFollowupCount — tap to view',
                                style: TextStyle(fontWeight: FontWeight.w700, color: Colors.orange.shade900),
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
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search, color: _primaryColor),
                      hintText: "Search by name or phone",
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: _primaryColor, width: 2),
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
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _filters.length,
                    itemBuilder: (_, i) {
                      final filter = _filters[i];
                      final isSelected = _selectedFilter == filter;
                      return Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 260),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: isSelected ? Colors.white : Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: isSelected
                                ? [BoxShadow(color: _primaryColor.withOpacity(0.12), blurRadius: 12, offset: const Offset(0, 6))]
                                : [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 4)],
                            border: Border.all(color: isSelected ? _primaryColor : Colors.grey.shade200),
                          ),
                          child: ChoiceChip(
                            label: Text(filter, style: TextStyle(color: isSelected ? _primaryColor : Colors.black87, fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500)),
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

                // LIST - grouped
                Expanded(
                  child: ListView(
                    children: _buildGroupedList(),
                  ),
                ),
              ],
            ),
    );
  }
}
