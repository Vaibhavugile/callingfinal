// lib/screens/lead_details_screen.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/lead.dart';
import '../services/lead_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:flutter/foundation.dart'; // for kIsWeb if not already imported

// -----------------------------------------------------------------------------
// Premium Theme
// -----------------------------------------------------------------------------
const Color _primaryColor = Color(0xFF0F172A); // deep navy
const Color _accentColor = Color(0xFFFFC857); // warm gold
const Gradient _cardGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFFFFFFFF), Color(0xFFF7FBFF)],
);

class LeadDetailsScreen extends StatefulWidget {
  final Lead lead;

  const LeadDetailsScreen({
    super.key,
    required this.lead,
  });

  @override
  State<LeadDetailsScreen> createState() => _LeadDetailsScreenState();
}

class LatestCall {
  final String id;
  final String? direction;
  final int? durationInSeconds;
  final DateTime? createdAt;
  final DateTime? finalizedAt;

  LatestCall({
    required this.id,
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
        final maybeInt = int.tryParse(v.toString());
        if (maybeInt != null) return DateTime.fromMillisecondsSinceEpoch(maybeInt);
        return null;
      }
    }

    return LatestCall(
      id: doc.id,
      direction: (data['direction'] as String?)?.toLowerCase(),
      durationInSeconds: data['durationInSeconds'] is num ? (data['durationInSeconds'] as num).toInt() : null,
      createdAt: _toDate(data['createdAt']),
      finalizedAt: _toDate(data['finalizedAt']),
    );
  }
}

class _LeadDetailsScreenState extends State<LeadDetailsScreen> with TickerProviderStateMixin {
  final LeadService _service = LeadService.instance;

  late Lead _lead;

  // Controllers
  late TextEditingController _phoneController;
  late TextEditingController _nameController;
  late TextEditingController _noteController;

  // NEW controllers for editable fields
  late TextEditingController _addressController;
  late TextEditingController _requirementsController;
  DateTime? _nextFollowUp;
  DateTime? _eventDate;

  bool _saving = false;

  final List<String> _statusOptions = [
    "new",
    "in progress",
    "follow up",
    "interested",
    "not interested",
    "closed",
  ];

  // Latest up to 5 calls for this lead
  List<LatestCall> _latestCalls = [];
  bool _loadingLatestCalls = false;

  // small animation controller for subtle UI motion
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _lead = widget.lead;

    _phoneController = TextEditingController(text: _lead.phoneNumber);
    _nameController = TextEditingController(text: _lead.name);
    _noteController = TextEditingController();

    _addressController = TextEditingController(text: _lead.address ?? '');
    _requirementsController = TextEditingController(text: _lead.requirements ?? '');
    _nextFollowUp = _lead.nextFollowUp;
    _eventDate = _lead.eventDate;

    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);

    _loadLatestCalls();
  }

  @override
  void didUpdateWidget(covariant LeadDetailsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.lead.id != oldWidget.lead.id) {
      setState(() {
        _lead = widget.lead;
        _phoneController.text = _lead.phoneNumber;
        _nameController.text = _lead.name;
        _addressController.text = _lead.address ?? '';
        _requirementsController.text = _lead.requirements ?? '';
        _nextFollowUp = _lead.nextFollowUp;
        _eventDate = _lead.eventDate;
      });
      _loadLatestCalls();
    }
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _nameController.dispose();
    _noteController.dispose();
    _addressController.dispose();
    _requirementsController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final minutes = (seconds ~/ 60).toString();
    final secs = (seconds % 60).toString().padLeft(2, '0');
    return '${minutes}:${secs}'; // mm:ss format
  }

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

  /// Save and then show a short success modal; then auto-close and return to lead list.
  Future<void> _saveAll() async {
    setState(() => _saving = true);
    try {
      final prefsTenant = await _getTenantIdFromPrefs();
      final updated = _lead.copyWith(
        name: _nameController.text.trim(),
        address: _addressController.text.trim().isEmpty ? null : _addressController.text.trim(),
        requirements: _requirementsController.text.trim().isEmpty ? null : _requirementsController.text.trim(),
        nextFollowUp: _nextFollowUp,
        eventDate: _eventDate,
        lastUpdated: DateTime.now(),
        lastInteraction: DateTime.now(),
        tenantId: _lead.tenantId.isNotEmpty ? _lead.tenantId : prefsTenant,
      );

      final saved = await _service.saveLead(updated);

      setState(() {
        _lead = saved;
        _nameController.text = _lead.name;
        _phoneController.text = _lead.phoneNumber;
        _addressController.text = _lead.address ?? '';
        _requirementsController.text = _lead.requirements ?? '';
        _nextFollowUp = _lead.nextFollowUp;
        _eventDate = _lead.eventDate;
      });

      // Show polished success modal that automatically closes and navigates back
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          // schedule auto-close after 900ms
          Future.delayed(const Duration(milliseconds: 900), () {
            if (!mounted) return;
            // close dialog first
            if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
            // then pop this screen and return `true` so the caller can refresh
            if (Navigator.of(context).canPop()) Navigator.of(context).pop(true);
          });

          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              decoration: BoxDecoration(
                gradient: _cardGradient,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 18)],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 6),
                  CircleAvatar(
                    radius: 36,
                    backgroundColor: Colors.green.shade700,
                    child: const Icon(Icons.check, color: Colors.white, size: 42),
                  ),
                  const SizedBox(height: 12),
                  const Text('Saved', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                    'Lead saved successfully. Returning to lead list...',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.blueGrey.shade700),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          );
        },
      );
    } catch (e) {
      // show error
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
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
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No phone number available')));
    return;
  }
  final uri = Uri(scheme: 'tel', path: number);

  try {
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      final fallback = "tel:$number";
      if (!kIsWeb) {
        await launchUrlString(fallback, mode: LaunchMode.externalApplication);
      } else {
        await launchUrlString(fallback);
      }
    }
  } catch (e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open dialer.')));
  }
}

Future<void> _openWhatsApp(String? rawNumber) async {
  final normalized = _sanitizePhone(rawNumber);
  if (normalized.isEmpty) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No phone number available')));
    return;
  }

  final waDigits = normalized.startsWith('+') ? normalized.substring(1) : normalized;
  final waUri = Uri.parse("https://wa.me/$waDigits");
  final webWhatsapp = Uri.parse("https://web.whatsapp.com/send?phone=$waDigits");

  try {
    var opened = await launchUrl(waUri, mode: LaunchMode.externalApplication);
    if (!opened) {
      opened = await launchUrl(webWhatsapp, mode: LaunchMode.externalApplication);
    }
    if (!opened) {
      await launchUrlString("https://wa.me/$waDigits", mode: LaunchMode.externalApplication);
    }
  } catch (e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open WhatsApp.')));
  }
}


  Future<void> _saveStatus(String newStatus) async {
    final prefsTenant = await _getTenantIdFromPrefs();
    final updated = _lead.copyWith(
      status: newStatus,
      lastInteraction: DateTime.now(),
      lastUpdated: DateTime.now(),
      tenantId: _lead.tenantId.isNotEmpty ? _lead.tenantId : prefsTenant,
    );

    final saved = await _service.saveLead(updated);

    setState(() {
      _lead = saved;
      _nameController.text = _lead.name;
      _phoneController.text = _lead.phoneNumber;
    });

    // small confirmation snackbar (no navigation)
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Status updated')));
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create lead first: $e')));
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
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to add note: $e')));
  }
}


  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: Colors.blueGrey.shade900,
        ),
      ),
    );
  }

  Widget _headerCard() {
    final bool needsReview = _lead.needsManualReview;
    // Show last seen (from calls subcollection if available)
    final LatestCall? call = _latestCalls.isNotEmpty ? _latestCalls.first : null;
    final DateTime? lastSeen = call?.finalizedAt ?? call?.createdAt ?? _lead.lastInteraction;
    final lastSeenLabel = lastSeen != null ? _formatDateTimeShort(lastSeen) : '—';

    return Container(
      decoration: BoxDecoration(
        gradient: _card_gradient,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          // glossy square with phone icon
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [Colors.white, _primaryColor.withOpacity(0.06)]),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 6, offset: const Offset(0, 3))],
            ),
            child: Center(
              child: Icon(Icons.phone_android, size: 30, color: needsReview ? _accentColor : _primaryColor),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                _lead.phoneNumber,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  if ((_lead.address ?? '').isNotEmpty)
                    Flexible(child: Text('Address: ${_lead.address}', style: const TextStyle(fontSize: 13))),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('Last seen: $lastSeenLabel', style: TextStyle(fontSize: 13, color: Colors.blueGrey.shade600)),
                  const SizedBox(width: 10),
                  if (_lead.nextFollowUp != null)
                    Chip(label: Text('Follow: ${_formatDateTimeShort(_lead.nextFollowUp!)}')),
                ],
              ),
            ]),
          ),
          // Stacked Call + WhatsApp buttons (uses same pulse animation controller)
Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    ScaleTransition(
      scale: Tween(begin: 0.98, end: 1.02).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut)),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 10)],
        ),
        child: IconButton(
          icon: const Icon(Icons.phone),
          color: _primaryColor,
          tooltip: 'Call',
          onPressed: () => _openDialer(_lead.phoneNumber),
        ),
      ),
    ),
    const SizedBox(height: 8),
    ScaleTransition(
      scale: Tween(begin: 0.98, end: 1.02).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut)),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 10)],
        ),
        child: IconButton(
          icon: Image.network(
            'https://upload.wikimedia.org/wikipedia/commons/5/5e/WhatsApp_icon.png',
            width: 20,
            height: 20,
            errorBuilder: (_, __, ___) => const Icon(Icons.message, size: 20),
          ),
          tooltip: 'WhatsApp',
          onPressed: () => _openWhatsApp(_lead.phoneNumber),
        ),
      ),
    ),
  ],
),

        ],
      ),
    );
  }

  // -------------------------
  // Load latest up to 5 calls (tenant-scoped)
  // -------------------------
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
      // ignore: avoid_print
      print('Error loading latest calls for lead ${_lead.id}: $e\n$st');
      setState(() {
        _latest_calls = [];
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

  // compact call row
  Widget _callRow(LatestCall call) {
    final dir = call.direction?.toLowerCase();
    final bool inbound = dir == 'inbound';
final DateTime? dt = call.finalizedAt ?? call.createdAt;
final String timeShort = dt != null ? _formatDateTimeShort(dt) : '—';
    final String duration = (call.durationInSeconds != null) ? _formatDuration(call.durationInSeconds!) : '';

    return InkWell(
      onTap: () async {
        // temporarily reload latest calls (or you might navigate to call details)
        await _loadLatestCalls();
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          gradient: _cardGradient,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 6, offset: const Offset(0, 3))],
          border: Border.all(color: Colors.black.withOpacity(0.02)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: inbound ? Colors.green.withOpacity(0.08) : _primaryColor.withOpacity(0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(inbound ? Icons.call_received : Icons.call_made, color: inbound ? Colors.green.shade700 : _primaryColor, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        inbound ? 'Incoming' : 'Outgoing',
                        style: TextStyle(fontWeight: FontWeight.w700, color: inbound ? Colors.green.shade700 : _primaryColor),
                      ),
                    ),
                    Text(timeShort, style: TextStyle(color: Colors.blueGrey.shade400, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(child: Text(duration.isNotEmpty ? duration : 'No duration', style: TextStyle(color: Colors.blueGrey.shade600))),
                    // subtle chevron
                    Icon(Icons.chevron_right, color: Colors.blueGrey.shade300),
                  ],
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _callHistorySection() {
    if (_loadingLatestCalls) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8.0),
        child: SizedBox(height: 28, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }

    if (_latestCalls.isEmpty) {
      return const Text("No call history yet.");
    }

    return Column(
      children: _latestCalls.map((c) => _callRow(c)).toList(),
    );
  }

  Widget _notesSection() {
    if (_lead.notes.isEmpty) {
      return const Text("No notes yet");
    }

    return Column(
      children: _lead.notes.reversed.map((note) {
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 6)],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(note.text, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 8),
            Text(_formatDateTimeShort(note.timestamp), style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade300)),
          ]),
        );
      }).toList(),
    );
  }

  // Date/time pickers helpers UI
  Future<void> _pickDateTime({required bool forNextFollowUp}) async {
    final now = DateTime.now();
    final initial = forNextFollowUp ? (_nextFollowUp ?? now) : (_eventDate ?? now);
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 5),
    );
    if (pickedDate == null) return;

    final pickedTime = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
    final combined = DateTime(pickedDate.year, pickedDate.month, pickedDate.day, pickedTime?.hour ?? 0, pickedTime?.minute ?? 0);

    setState(() {
      if (forNextFollowUp) _nextFollowUp = combined;
      else _eventDate = combined;
    });
  }

  Widget _dateRow({required String label, DateTime? value, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          children: [
            Icon(label.contains('Follow') ? Icons.event : Icons.event_available, color: Colors.grey.shade700),
            const SizedBox(width: 12),
            Expanded(child: Text(value != null ? _formatDateTimeShort(value) : label, style: const TextStyle(fontSize: 14))),
            const SizedBox(width: 8),
            const Icon(Icons.edit, size: 18, color: Colors.blueGrey),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F9),
      appBar: AppBar(
        title: const Text('Lead Details'),
        backgroundColor: _primaryColor,
        foregroundColor: Colors.white,
        actions: [
          // single Save button only (clean UI)
          IconButton(
            icon: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.save),
            onPressed: _saving ? null : _saveAll,
            tooltip: 'Save',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _loadLatestCalls();
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _headerCard(),
            _sectionTitle('Phone Number'),
            TextField(
              controller: _phoneController,
              readOnly: true,
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.grey.shade200,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            _sectionTitle('Name'),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.grey.shade200,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onEditingComplete: _saveAll,
            ),
            _sectionTitle('Status'),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blueGrey.shade200),
              ),
              child: DropdownButton<String>(
                value: _lead.status,
                isExpanded: true,
                underline: const SizedBox(),
                items: _statusOptions.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                onChanged: (val) async {
                  if (val == null) return;
                  await _saveStatus(val);
                },
              ),
            ),
            _sectionTitle('Address'),
            TextField(
              controller: _address_controller,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: 'Address (optional)',
                filled: true,
                fillColor: Colors.grey.shade100,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onEditingComplete: _saveAll,
            ),
            _sectionTitle('Requirements'),
            TextField(
              controller: _requirements_controller,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'Lead requirements (what they need)',
                filled: true,
                fillColor: Colors.grey.shade100,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onEditingComplete: _saveAll,
            ),
            _sectionTitle('Next Follow-up'),
            const SizedBox(height: 6),
            _dateRow(label: 'Set next follow-up date', value: _nextFollowUp, onTap: () => _pickDateTime(forNextFollowUp: true)),
            const SizedBox(height: 12),
            _sectionTitle('Event Date'),
            const SizedBox(height: 6),
            _dateRow(label: 'Set event date', value: _eventDate, onTap: () => _pickDateTime(forNextFollowUp: false)),
            _sectionTitle('Call History'),
            const SizedBox(height: 6),
            _callHistorySection(),
            _sectionTitle('Notes'),
            const SizedBox(height: 6),
            _notesSection(),
            const SizedBox(height: 12),
            TextField(
              controller: _noteController,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'Write a note...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _addNote,
                ),
              ),
            ),
            const SizedBox(height: 40),
          ]),
        ),
      ),
    );
  }
}
