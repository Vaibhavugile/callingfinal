// lib/screens/lead_form_screen.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/lead.dart';
import '../services/lead_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:flutter/foundation.dart'; // for kIsWeb
import '../widgets/gradient_appbar_title.dart';

// -------------------------------------------------------------------------
// 🌌 DARK / NEON THEME (aligned with LeadListScreen & LeadDetailsScreen)
// -------------------------------------------------------------------------
const Color _bgDark1 = Color(0xFF0B1220);
const Color _bgDark2 = Color(0xFF020617);
const Color _primaryColor = Color(0xFF020617);
const Color _accentIndigo = Color(0xFF6366F1);
const Color _accentCyan = Color(0xFF38BDF8);
const Color _accentColor = _accentCyan;
const Color _mutedText = Color(0xFF94A3B8);
const Color _mutedBg = _bgDark1;

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
    Color(0xFF0F172A),
    Color(0xFF020617),
  ],
);

// -------------------------------------------------------------------------
// Small model for a call doc (we only require a few fields)
// -------------------------------------------------------------------------
class LatestCall {
  final String id;
  final String? direction;
  final int? durationInSeconds;
  final DateTime? createdAt;
  final DateTime? finalizedAt;
  final String? finalOutcome;
  final String? handledByUserName;

  LatestCall({
    required this.id,
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
      id: doc.id,
      direction: (data['direction'] as String?)?.toLowerCase(),
      durationInSeconds: data['durationInSeconds'] is num
          ? (data['durationInSeconds'] as num).toInt()
          : null,
      createdAt: _toDate(data['createdAt']),
      finalizedAt: _toDate(data['finalizedAt']),
      finalOutcome: (data['finalOutcome'] as String?)?.toLowerCase() ??
          (data['outcome'] as String?)?.toLowerCase(),
      handledByUserName: (data['handledByUserName'] as String?)?.trim(),
    );
  }
}

class LeadFormScreen extends StatefulWidget {
  final Lead lead;
  final bool autoOpenedFromCall;

  const LeadFormScreen({
    super.key,
    required this.lead,
    this.autoOpenedFromCall = false,
  });

  @override
  State<LeadFormScreen> createState() => _LeadFormScreenState();
}

class _LeadFormScreenState extends State<LeadFormScreen>
    with TickerProviderStateMixin {
  final LeadService _service = LeadService.instance;

  late Lead _lead;

  late TextEditingController _nameController;
  late TextEditingController _noteController;
  late TextEditingController _phoneController;

  // NEW controllers for added fields
  late TextEditingController _addressController;
  late TextEditingController _requirementsController;
  DateTime? _nextFollowUp;
  DateTime? _eventDate;

  bool _hasUnsavedNameChanges = false;
  bool _hasUserSavedOrNoted = false;

  final List<String> _statusOptions = [
    "new",
    "in progress",
    "follow up",
    "interested",
    "not interested",
    "closed",
  ];

  // Latest up to 5 calls (fresh from calls subcollection)
  List<LatestCall> _latestCalls = [];
  bool _loadingLatestCalls = false;

  // subtle animation controller for small UI motion
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _lead = widget.lead;
    _nameController = TextEditingController(text: _lead.name);
    _noteController = TextEditingController();
    _phoneController = TextEditingController(text: _lead.phoneNumber);

    // init new controllers and date fields from lead (nullable)
    _addressController = TextEditingController(text: _lead.address ?? '');
    _requirementsController =
        TextEditingController(text: _lead.requirements ?? '');
    _nextFollowUp = _lead.nextFollowUp;
    _eventDate = _lead.eventDate;

    _nameController.addListener(_checkUnsavedChanges);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    // Load the latest call docs for this lead
    _loadLatestCalls();
  }

  @override
  void dispose() {
    if (widget.autoOpenedFromCall &&
        !_hasUserSavedOrNoted &&
        _lead.id.isNotEmpty) {
      // keep this print single-line so it won't break compilation
      print(
          "UI closed without save/note. Marking Lead ${_lead.id} for manual review.");
      _service.markLeadForReview(_lead.id, true).catchError((e) {
        print("Error marking lead for review: $e");
      });
    }

    _nameController.removeListener(_checkUnsavedChanges);
    _nameController.dispose();
    _noteController.dispose();
    _phoneController.dispose();

    // dispose new controllers
    _addressController.dispose();
    _requirementsController.dispose();

    _pulseController.dispose();
    super.dispose();
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final minutes = (seconds ~/ 60);
    final secs = (seconds % 60).toString().padLeft(2, '0');
    return '${minutes}:${secs}'; // mm:ss format — compact
  }

  String _formatDate(DateTime dt) {
    final d = dt.toLocal();
    return "${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}  "
        "${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}";
  }

  // Format DateTime to local "YYYY-MM-DD HH:mm" (used by header & call rows)
  String _formatDateTimeShort(DateTime dt) {
    final d = dt.toLocal();
    return "${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} "
        "${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}";
  }

  Future<String> _getTenantIdFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final t = prefs.getString('tenantId');
      if (t != null && t.isNotEmpty) return t;
    } catch (_) {}
    return 'default_tenant';
  }

  /// Persist a transient lead (if id empty) and include address/requirements/dates
  Future<void> _persistLeadIfTransient() async {
    if (_lead.id.isEmpty) {
      print("First save: Persisting new lead for ${_lead.phoneNumber}");
      final persistedLead = await _service.createLead(_lead.phoneNumber);

      final prefsTenant = await _getTenantIdFromPrefs();

      final updatedTransientLead = persistedLead.copyWith(
        name: _nameController.text.trim(),
        status: _lead.status,
        callHistory: _lead.callHistory,
        notes: _lead.notes,
        lastCallOutcome: _lead.lastCallOutcome,
        lastInteraction: DateTime.now(),
        lastUpdated: DateTime.now(),
        address: _addressController.text.trim().isEmpty
            ? null
            : _addressController.text.trim(),
        requirements: _requirementsController.text.trim().isEmpty
            ? null
            : _requirementsController.text.trim(),
        nextFollowUp: _nextFollowUp,
        eventDate: _eventDate,
        tenantId:
            persistedLead.tenantId.isNotEmpty ? persistedLead.tenantId : prefsTenant,
      );

      await _service.saveLead(updatedTransientLead);

      Lead? refreshed;
      try {
        refreshed = await _service.getLead(leadId: updatedTransientLead.id);
      } catch (_) {
        refreshed = null;
      }

      setState(() {
        _lead = refreshed ?? updatedTransientLead;
      });
    }
  }

  void _checkUnsavedChanges() {
    final currentName = _nameController.text.trim();
    final hasChanges = currentName != _lead.name;

    if (hasChanges != _hasUnsavedNameChanges) {
      setState(() {
        _hasUnsavedNameChanges = hasChanges;
      });
    }
  }

  // -----------------------------
  // Phone / WhatsApp helpers
  // -----------------------------
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
    final number = _sanitizePhone(rawNumber);
    if (number.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No phone number available')),
        );
      }
      return;
    }
    final uri = Uri(scheme: 'tel', path: number);

    try {
      final launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        final fallback = "tel:$number";
        if (!kIsWeb) {
          await launchUrlString(fallback,
              mode: LaunchMode.externalApplication);
        } else {
          await launchUrlString(fallback);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open dialer.')),
        );
      }
    }
  }

  Future<void> _openWhatsApp(String? rawNumber) async {
    final normalized = _sanitizePhone(rawNumber);
    if (normalized.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No phone number available')),
        );
      }
      return;
    }

    final waDigits =
        normalized.startsWith('+') ? normalized.substring(1) : normalized;
    final waUri = Uri.parse("https://wa.me/$waDigits");
    final webWhatsapp =
        Uri.parse("https://web.whatsapp.com/send?phone=$waDigits");

    try {
      var opened =
          await launchUrl(waUri, mode: LaunchMode.externalApplication);
      if (!opened) {
        opened = await launchUrl(
          webWhatsapp,
          mode: LaunchMode.externalApplication,
        );
      }
      if (!opened) {
        await launchUrlString("https://wa.me/$waDigits",
            mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open WhatsApp.')),
        );
      }
    }
  }

  /// Save lead including new fields
  Future<void> _saveLead({String? newStatus, String? newName}) async {
    await _persistLeadIfTransient();

    final name = newName ?? _nameController.text.trim();
    final status = newStatus ?? _lead.status;

    final bool fieldsChanged = name != _lead.name ||
        status != _lead.status ||
        (_addressController.text.trim().isNotEmpty &&
            _addressController.text.trim() != (_lead.address ?? '')) ||
        (_requirementsController.text.trim().isNotEmpty &&
            _requirementsController.text.trim() !=
                (_lead.requirements ?? '')) ||
        _nextFollowUp != _lead.nextFollowUp ||
        _eventDate != _lead.eventDate;

    if (!fieldsChanged && newStatus == null && newName == null) {
      return;
    }

    final updatedLead = _lead.copyWith(
      name: name,
      status: status,
      address: _addressController.text.trim().isEmpty
          ? null
          : _addressController.text.trim(),
      requirements: _requirementsController.text.trim().isEmpty
          ? null
          : _requirementsController.text.trim(),
      nextFollowUp: _nextFollowUp,
      eventDate: _eventDate,
      lastUpdated: DateTime.now(),
      lastInteraction: DateTime.now(),
    );

    final prefsTenant = await _getTenantIdFromPrefs();
    final leadWithTenant = updatedLead.copyWith(
      tenantId: updatedLead.tenantId.isNotEmpty
          ? updatedLead.tenantId
          : prefsTenant,
    );

    await _service.saveLead(leadWithTenant);

    Lead? refreshed;
    try {
      refreshed = await _service.getLead(leadId: leadWithTenant.id);
    } catch (e) {
      print('Warning: could not fetch refreshed lead after save: $e');
      refreshed = null;
    }
    final savedLead = refreshed ?? leadWithTenant;

    _hasUserSavedOrNoted = true;

    setState(() {
      _lead = savedLead;
      _hasUnsavedNameChanges = false;
      _nameController.text = _lead.name;
      _addressController.text = _lead.address ?? '';
      _requirementsController.text = _lead.requirements ?? '';
      _nextFollowUp = _lead.nextFollowUp;
      _eventDate = _lead.eventDate;
    });

    _checkUnsavedChanges();

    await _loadLatestCalls();

    // Show success modal, auto-close and pop back to lead list
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        // schedule auto-close after 900ms
        Future.delayed(const Duration(milliseconds: 900), () {
          if (!mounted) return;
          if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
          // pop this screen and return `true` to caller so the list can refresh
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop(true);
          }
        });

        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            decoration: BoxDecoration(
              gradient: _cardGradient,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.35),
                  blurRadius: 22,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 6),
                CircleAvatar(
                  radius: 36,
                  backgroundColor: Colors.green.shade600,
                  child:
                      const Icon(Icons.check, color: Colors.white, size: 42),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Saved',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Lead saved successfully. Returning to lead list...',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _mutedText),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _addNote() async {
    if (_noteController.text.isEmpty) return;

    // Preserve whatever the user has typed in the name field so a backend refresh doesn't wipe it.
    final String currentTypedName = _nameController.text.trim();

    // Ensure lead exists server-side (for transient leads)
    try {
      if (mounted) {
        await _persistLeadIfTransient();
      }
    } catch (e) {
      // If persisting failed, still attempt to continue but warn the user
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create lead first: $e')),
        );
      }
      return;
    }

    final String note = _noteController.text.trim();
    _noteController.clear();

    try {
      await _service.addNote(lead: _lead, note: note);
      _hasUserSavedOrNoted = true;

      // Fetch canonical lead from backend
      final updatedLead = await _service.getLead(leadId: _lead.id);

      if (!mounted) return;

      setState(() {
        if (updatedLead != null) {
          _lead = updatedLead;

          // Preserve user's typed name if they haven't saved it to backend yet.
          if (currentTypedName.isNotEmpty) {
            _nameController.text = currentTypedName;
          } else {
            _nameController.text = _lead.name;
          }

          _phoneController.text = _lead.phoneNumber;
          _addressController.text = _lead.address ?? '';
          _requirementsController.text = _lead.requirements ?? '';
          _nextFollowUp = _lead.nextFollowUp;
          _eventDate = _lead.eventDate;
        }
      });

      // Refresh call list (safe no-op)
      await _loadLatestCalls();
    } catch (e) {
      // keep logs single-line
      // ignore: avoid_print
      print('Error adding note: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add note: $e')),
        );
      }
    }
  }

  // --------------------------------------------------------------------
  // UI helpers
  // --------------------------------------------------------------------
  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: Colors.white,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  Widget _headerCard() {
    final bool needsReview = _lead.needsManualReview;

    final LatestCall? call =
        _latestCalls.isNotEmpty ? _latestCalls.first : null;
    final DateTime? lastSeen =
        call?.finalizedAt ?? call?.createdAt ?? _lead.lastInteraction;
    final lastSeenLabel =
        lastSeen != null ? _formatDateTimeShort(lastSeen) : '—';

    return Container(
      decoration: BoxDecoration(
        gradient: _cardGradient,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.45),
            blurRadius: 22,
            offset: const Offset(0, 14),
          ),
        ],
        border: needsReview
            ? Border.all(color: _accentCyan.withOpacity(0.8), width: 1.4)
            : Border.all(color: Colors.white.withOpacity(0.04)),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: const LinearGradient(
                colors: [
                  Color(0xFF1D4ED8),
                  Color(0xFF38BDF8),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.55),
                  blurRadius: 18,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Center(
              child: Icon(
                Icons.smartphone,
                color: needsReview ? Colors.yellowAccent : Colors.white,
                size: 26,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _lead.phoneNumber,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ScaleTransition(
                        scale: Tween(begin: 0.98, end: 1.02).animate(
                          CurvedAnimation(
                            parent: _pulseController,
                            curve: Curves.easeInOut,
                          ),
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.6),
                                blurRadius: 12,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: IconButton(
                            icon: const Icon(Icons.phone),
                            color: Colors.greenAccent,
                            tooltip: 'Call',
                            onPressed: () =>
                                _openDialer(_lead.phoneNumber),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      ScaleTransition(
                        scale: Tween(begin: 0.98, end: 1.02).animate(
                          CurvedAnimation(
                            parent: _pulseController,
                            curve: Curves.easeInOut,
                          ),
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.6),
                                blurRadius: 12,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: IconButton(
                            icon: Image.network(
                              'https://upload.wikimedia.org/wikipedia/commons/5/5e/WhatsApp_icon.png',
                              width: 20,
                              height: 20,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.message, size: 20),
                            ),
                            tooltip: 'WhatsApp',
                            onPressed: () =>
                                _openWhatsApp(_lead.phoneNumber),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    'Last seen: $lastSeenLabel',
                    style: const TextStyle(
                      color: _mutedText,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_lead.nextFollowUp != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.18),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'Follow: ${_formatDate(_lead.nextFollowUp!)}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.orangeAccent,
                        ),
                      ),
                    ),
                ],
              ),
              if ((_lead.address ?? '').isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Address: ${_lead.address}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.white70,
                  ),
                ),
              ],
            ]),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------
  // NEW: load latest up to 5 call docs from tenant-scoped calls subcollection
  // -------------------------------------------------------------------
  Future<void> _loadLatestCalls() async {
    setState(() {
      _loadingLatestCalls = true;
    });

    try {
      if (_lead.id.isEmpty) {
        setState(() {
          _latestCalls = [];
          _loadingLatestCalls = false;
        });
        return;
      }

      final tenantId = await _getTenantIdFromPrefs();

      final q = await FirebaseFirestore.instance
          .collection('tenants')
          .doc(tenantId)
          .collection('leads')
          .doc(_lead.id)
          .collection('calls')
          .orderBy('createdAt', descending: true)
          .limit(5)
          .get();

      final list = q.docs.map((d) => LatestCall.fromDoc(d)).toList();
      setState(() {
        _latestCalls = list;
      });
    } catch (e, st) {
      print("Error loading latest calls for lead ${_lead.id}: $e\n$st");
      setState(() {
        _latestCalls = [];
      });
    } finally {
      setState(() {
        _loadingLatestCalls = false;
      });
    }
  }

  String? _timeAgo(DateTime? dt) {
    if (dt == null) return null;
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }

  bool _isMissedCall(LatestCall call) {
    final dir = call.direction ?? '';
    final dur = call.durationInSeconds ?? 0;
    final outcome = call.finalOutcome ?? '';

    if (dir == 'inbound' && dur == 0) return true;
    if (outcome == 'missed') return true;
    return false;
  }

  bool _isRejectedCall(LatestCall call) {
    final dir = call.direction ?? '';
    final dur = call.durationInSeconds ?? 0;
    final outcome = call.finalOutcome ?? '';

    if (dir != 'outbound') return false;
    if (dur == 0) return true;
    if (outcome == 'rejected') return true;
    return false;
  }

  // compact call row — dark, with MISSED/REJECTED + handler pill
  Widget _callRow(LatestCall call) {
    final bool inbound = call.direction == 'inbound';
    final DateTime? dt = call.finalizedAt ?? call.createdAt;
    final String timeShort =
        dt != null ? _formatDateTimeShort(dt) : '—';
    final String duration = (call.durationInSeconds != null)
        ? _formatDuration(call.durationInSeconds!)
        : '-';

    final isMissed = _isMissedCall(call);
    final isRejected = _isRejectedCall(call);

    final statusLabel = isMissed
        ? 'MISSED'
        : isRejected
            ? 'REJECTED'
            : (call.durationInSeconds != null &&
                    (call.durationInSeconds ?? 0) > 0)
                ? 'ANSWERED'
                : '';

    final statusColor = isMissed || isRejected
        ? Colors.redAccent
        : Colors.greenAccent;

    final handlerName = (call.handledByUserName ?? '').trim().isEmpty
        ? null
        : call.handledByUserName!.trim();

    Icon directionIcon;
    if (inbound) {
      directionIcon =
          const Icon(Icons.call_received, color: Colors.tealAccent, size: 20);
    } else if (call.direction == 'outbound') {
      directionIcon = Icon(Icons.call_made,
          color: Colors.blueAccent.shade200, size: 20);
    } else {
      directionIcon = Icon(Icons.phone,
          color: Colors.blueGrey.shade200, size: 20);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        gradient: _cardGradient,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.04)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 16,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: const LinearGradient(
                colors: [
                  Color(0xFF0F172A),
                  Color(0xFF020617),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.5),
                  blurRadius: 10,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Center(child: directionIcon),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        inbound ? 'Incoming' : 'Outgoing',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    Text(
                      timeShort,
                      style: const TextStyle(
                        color: _mutedText,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (statusLabel.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: (isMissed || isRejected)
                              ? Colors.red.withOpacity(0.22)
                              : Colors.green.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          statusLabel,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                            color: statusColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (handlerName != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF020617),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.08),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.person,
                              size: 12,
                              color: Colors.blueGrey.shade100,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              handlerName,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF020617),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.06),
                        ),
                      ),
                      child: Text(
                        duration,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _callHistorySection() {
    if (_loadingLatestCalls) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8.0),
        child: SizedBox(
          height: 28,
          child: Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
            ),
          ),
        ),
      );
    }

    if (_latestCalls.isEmpty) {
      return const Text(
        "No recent calls",
        style: TextStyle(color: _mutedText),
      );
    }

    return Column(children: _latestCalls.map((c) => _callRow(c)).toList());
  }

  Widget _notesSection() {
    if (_lead.notes.isEmpty) {
      return const Text(
        "No notes yet",
        style: TextStyle(color: _mutedText),
      );
    }

    return Column(
      children: _lead.notes.reversed.map((note) {
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            gradient: _cardGradient,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.4),
                blurRadius: 16,
                offset: const Offset(0, 10),
              ),
            ],
            border: Border.all(color: Colors.white.withOpacity(0.04)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                note.text,
                style: const TextStyle(fontSize: 14, color: Colors.white),
              ),
              const SizedBox(height: 8),
              Text(
                _formatDate(note.timestamp),
                style: TextStyle(
                  fontSize: 12,
                  color: _mutedText,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  // ------------------------------
  // Date/time pickers helpers UI
  // ------------------------------
  Future<void> _pickDateTime({required bool forNextFollowUp}) async {
    final now = DateTime.now();
    final initial =
        forNextFollowUp ? (_nextFollowUp ?? now) : (_eventDate ?? now);
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 5),
    );
    if (pickedDate == null) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    final combined = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime?.hour ?? 0,
      pickedTime?.minute ?? 0,
    );

    setState(() {
      if (forNextFollowUp) {
        _nextFollowUp = combined;
      } else {
        _eventDate = combined;
      }
    });
  }

  Widget _dateButton({
    required String label,
    DateTime? value,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF020617),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
        ),
        child: Row(
          children: [
            Icon(
              label.contains('Follow') ? Icons.event : Icons.event_available,
              color: _mutedText,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                value != null ? _formatDate(value) : label,
                style: const TextStyle(fontSize: 14, color: Colors.white),
              ),
            ),
            const Icon(Icons.edit, color: Colors.white70, size: 18),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------
  // BUILD
  // --------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _mutedBg,
      appBar: AppBar(
  elevation: 0,
  backgroundColor: Colors.transparent,
  flexibleSpace: Container(
    decoration: BoxDecoration(
      gradient: _appBarGradient,
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.35),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
    ),
  ),
  title: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // ✅ ADMIN NAVBAR–STYLE GRADIENT TITLE
      GradientAppBarTitle(
        widget.autoOpenedFromCall
            ? "Call lead review"
            : "Lead details",
        fontSize: 18,
      ),
      const SizedBox(height: 2),
      const Text(
        'Profile, status & notes',
        style: TextStyle(
          fontSize: 12,
          color: _mutedText,
        ),
      ),
    ],
  ),
  iconTheme: const IconThemeData(color: Colors.white),
  actions: [
    IconButton(
      icon: const Icon(Icons.save),
      onPressed: () => _saveLead(),
      tooltip: 'Save',
    ),
  ],
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
        child: RefreshIndicator(
          onRefresh: () async {
            await _loadLatestCalls();
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _headerCard(),

                _sectionTitle("Phone Number"),
                TextField(
                  controller: _phoneController,
                  readOnly: true,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: const Color(0xFF020617),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: _accentCyan, width: 1.4),
                    ),
                  ),
                ),

                _sectionTitle("Lead Name"),
                TextField(
                  controller: _nameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: "Enter lead name",
                    hintStyle:
                        const TextStyle(color: Colors.white54, fontSize: 14),
                    filled: true,
                    fillColor: const Color(0xFF020617),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: _accentCyan, width: 1.4),
                    ),
                  ),
                  onSubmitted: (val) => _saveLead(newName: val),
                  onEditingComplete: () =>
                      _saveLead(newName: _nameController.text.trim()),
                ),

                _sectionTitle("Status"),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF020617),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.1),
                    ),
                  ),
                  child: DropdownButton<String>(
                    value: _lead.status,
                    isExpanded: true,
                    underline: const SizedBox(),
                    dropdownColor: const Color(0xFF020617),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                    items: _statusOptions
                        .map(
                          (s) => DropdownMenuItem(
                            value: s,
                            child: Text(s),
                          ),
                        )
                        .toList(),
                    onChanged: (val) async {
                      if (val == null) return;
                      await _saveLead(newStatus: val);
                    },
                  ),
                ),

                _sectionTitle("Address"),
                TextField(
                  controller: _addressController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: "Address (optional)",
                    hintStyle:
                        const TextStyle(color: Colors.white54, fontSize: 14),
                    filled: true,
                    fillColor: const Color(0xFF020617),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: _accentCyan, width: 1.4),
                    ),
                  ),
                  onEditingComplete: () => _saveLead(),
                ),
                _sectionTitle("Event Date"),
                const SizedBox(height: 6),
                _dateButton(
                  label: 'Set event date',
                  value: _eventDate,
                  onTap: () => _pickDateTime(forNextFollowUp: false),
                ),


                _sectionTitle("Requirements"),
                TextField(
                  controller: _requirementsController,
                  maxLines: 3,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: "What does the lead require? (free-text)",
                    hintStyle:
                        const TextStyle(color: Colors.white54, fontSize: 14),
                    filled: true,
                    fillColor: const Color(0xFF020617),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: _accentCyan, width: 1.4),
                    ),
                  ),
                  onEditingComplete: () => _saveLead(),
                ),

                _sectionTitle("Next Follow-up"),
                const SizedBox(height: 6),
                _dateButton(
                  label: 'Set next follow-up date',
                  value: _nextFollowUp,
                  onTap: () => _pickDateTime(forNextFollowUp: true),
                ),

                const SizedBox(height: 12),
                
                _sectionTitle("Call History"),
                const SizedBox(height: 6),
                _callHistorySection(),

                _sectionTitle("Notes"),
                const SizedBox(height: 6),
                _notesSection(),

                const SizedBox(height: 12),
                TextField(
                  controller: _noteController,
                  minLines: 1,
                  maxLines: 3,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: "Write a follow-up note...",
                    hintStyle:
                        const TextStyle(color: Colors.white54, fontSize: 14),
                    filled: true,
                    fillColor: const Color(0xFF020617),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: _accentCyan, width: 1.4),
                    ),
                    suffixIcon: Container(
                      margin: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [_accentCyan, _accentIndigo],
                        ),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.5),
                            blurRadius: 16,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.send, color: Colors.black87),
                        onPressed: _addNote,
                        tooltip: 'Add Note',
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
