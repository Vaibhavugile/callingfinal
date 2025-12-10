import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:flutter/foundation.dart';

import '../models/lead.dart';
import '../widgets/gradient_appbar_title.dart';

// ----------------------- THEME (matches LeadListScreen) -----------------------

const Color _bgDark1 = Color(0xFF0B1220);
const Color _bgDark2 = Color(0xFF020617);
const Color _primaryColor = Color(0xFF020617);
const Color _accentIndigo = Color(0xFF6366F1);
const Color _accentCyan = Color(0xFF38BDF8);
const Color _mutedText = Color(0xFF9FB0C4);

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

// ----------------------------- Call model -------------------------------------

class LeadCall {
  final String id;
  final String? direction;
  final int? durationInSeconds;
  final DateTime? createdAt;
  final DateTime? finalizedAt;
  final String? finalOutcome;
  final String? phoneNumber;
  final String? handledByUserName;

  LeadCall({
    required this.id,
    this.direction,
    this.durationInSeconds,
    this.createdAt,
    this.finalizedAt,
    this.finalOutcome,
    this.phoneNumber,
    this.handledByUserName,
  });

  factory LeadCall.fromDoc(QueryDocumentSnapshot doc) {
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

    return LeadCall(
      id: doc.id,
      direction: (data['direction'] as String?)?.toLowerCase(),
      durationInSeconds: data['durationInSeconds'] is num
          ? (data['durationInSeconds'] as num).toInt()
          : null,
      createdAt: _toDate(data['createdAt']),
      finalizedAt: _toDate(data['finalizedAt']),
      finalOutcome: (data['finalOutcome'] as String?)?.toLowerCase() ??
          (data['outcome'] as String?)?.toLowerCase(),
      phoneNumber: data['phoneNumber'] as String?,
      handledByUserName: (data['handledByUserName'] as String?)?.trim(),
    );
  }
}

// ------------------------- Screen widget --------------------------------------

class LeadDetailsScreen extends StatefulWidget {
  final Lead lead;

  const LeadDetailsScreen({
    super.key,
    required this.lead,
  });

  @override
  State<LeadDetailsScreen> createState() => _LeadDetailsScreenState();
}

class _LeadDetailsScreenState extends State<LeadDetailsScreen> {
  bool _loadingCalls = true;
  List<LeadCall> _calls = [];
  String? _loadError;

  // --------- controllers for the details form (phone, name, etc.) -------------

  late TextEditingController _phoneController;
  late TextEditingController _nameController;
  late TextEditingController _addressController;
  late TextEditingController _requirementsController;
  String _status = 'new';

  @override
  void initState() {
    super.initState();
    _phoneController = TextEditingController(text: widget.lead.phoneNumber);
    _nameController = TextEditingController(text: widget.lead.name);
    _addressController = TextEditingController();
    _requirementsController = TextEditingController();
    _loadCallHistory();
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _nameController.dispose();
    _addressController.dispose();
    _requirementsController.dispose();
    super.dispose();
  }

  // -------------------------- Firestore load ---------------------------------

  Future<void> _loadCallHistory() async {
    setState(() {
      _loadingCalls = true;
      _loadError = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final tenantId = prefs.getString('tenantId') ?? 'default_tenant';

      final snap = await FirebaseFirestore.instance
          .collection('tenants')
          .doc(tenantId)
          .collection('leads')
          .doc(widget.lead.id)
          .collection('calls')
          .orderBy('createdAt', descending: true)
          .limit(50)
          .get();

      final calls = snap.docs.map((d) => LeadCall.fromDoc(d)).toList();

      if (!mounted) return;
      setState(() {
        _calls = calls;
        _loadingCalls = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _loadingCalls = false;
      });
    }
  }

  // ------------------------------ Helpers ------------------------------------

  bool _isMissedCall(LeadCall call) {
    final dir = call.direction ?? '';
    final dur = call.durationInSeconds ?? 0;
    final outcome = call.finalOutcome ?? '';

    if (dir == 'inbound' && dur == 0) return true;
    if (outcome == 'missed') return true;
    return false;
  }

  bool _isRejectedCall(LeadCall call) {
    final dir = call.direction ?? '';
    final dur = call.durationInSeconds ?? 0;
    final outcome = call.finalOutcome ?? '';

    if (dir != 'outbound') return false;
    if (dur == 0) return true;
    if (outcome == 'rejected') return true;
    return false;
  }

  String _formatTime24(DateTime? dt) {
    if (dt == null) return '';
    final local = dt.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  String _formatDuration(int? seconds) {
    if (seconds == null) return '';
    final s = seconds;
    final m = s ~/ 60;
    final rem = s % 60;
    if (m == 0) return '${rem}s';
    return '${m}m ${rem}s';
  }

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
    final number = _sanitizePhone(rawNumber ?? widget.lead.phoneNumber);
    if (number.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No phone number available')),
      );
      return;
    }

    final uri = Uri(scheme: 'tel', path: number);

    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );

      if (!launched) {
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
        } catch (_) {}
        if (!fallbackResult && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not open the dialer on this device.'),
            ),
          );
        }
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error while trying to open dialer.')),
      );
    }
  }

  Future<void> _openWhatsApp(String? rawNumber) async {
    final normalized = _sanitizePhone(rawNumber ?? widget.lead.phoneNumber);

    if (normalized.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No phone number available")),
      );
      return;
    }

    final waPathNumber =
        normalized.startsWith('+') ? normalized.substring(1) : normalized;
    final waUri = Uri.parse("https://wa.me/$waPathNumber");
    final webWhatsapp =
        Uri.parse("https://web.whatsapp.com/send?phone=$waPathNumber");

    bool opened = false;

    try {
      opened = await launchUrl(waUri, mode: LaunchMode.externalApplication);
    } catch (_) {}

    if (!opened) {
      try {
        opened = await launchUrl(
          webWhatsapp,
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
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
        opened = fallbackLaunched;
      } catch (_) {}
    }

    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Could not open WhatsApp.")),
      );
    }
  }

  // ----------------- COMMON BORDER + DECORATION FOR FIELDS --------------------

  OutlineInputBorder _neonBorder([double width = 1.4]) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(
        color: Color(0xFF3B82F6), // neon-ish blue
        width: width,
      ),
    );
  }

  InputDecoration _neonInputDecoration({
    String? hint,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(
        color: _mutedText,
        fontSize: 14,
      ),
      filled: true,
      fillColor: _primaryColor,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 16,
      ),
      border: _neonBorder(),
      enabledBorder: _neonBorder(),
      focusedBorder: _neonBorder(1.8), // slightly thicker on focus
      disabledBorder: _neonBorder(),
    );
  }

  Widget _buildLabeledField({
    required String label,
    required Widget child,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  // ------------------------------ UI pieces ----------------------------------

  Widget _buildHeaderCard() {
    final lead = widget.lead;
    final phone = lead.phoneNumber;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: _cardGradient,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.45),
            blurRadius: 22,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
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
            child: const Center(
              child: Icon(Icons.person, color: Colors.white, size: 26),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  lead.name.isEmpty ? 'No name' : lead.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Text(
                  phone.isEmpty ? 'No phone' : phone,
                  style: const TextStyle(
                    color: _mutedText,
                    fontSize: 14,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: IconButton(
                  icon: const Icon(Icons.phone, size: 20),
                  color: Colors.greenAccent,
                  onPressed: () => _openDialer(phone),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: IconButton(
                  iconSize: 20,
                  icon: Image.network(
                    'https://upload.wikimedia.org/wikipedia/commons/5/5e/WhatsApp_icon.png',
                    width: 20,
                    height: 20,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.message,
                      size: 20,
                      color: Colors.greenAccent,
                    ),
                  ),
                  onPressed: () => _openWhatsApp(phone),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ------------- DETAILS FORM (phone, name, status, address, etc.) -----------

  Widget _buildDetailsForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'Profile, status & notes',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Update lead information and requirements.',
            style: TextStyle(
              color: _mutedText,
              fontSize: 13,
            ),
          ),
        ),
        const SizedBox(height: 4),

        // Phone number
        _buildLabeledField(
          label: 'Phone Number',
          child: TextFormField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            style: const TextStyle(color: Colors.white),
            decoration: _neonInputDecoration(
              hint: 'Enter phone number',
            ),
          ),
        ),

        // Lead name
        _buildLabeledField(
          label: 'Lead Name',
          child: TextFormField(
            controller: _nameController,
            style: const TextStyle(color: Colors.white),
            decoration: _neonInputDecoration(
              hint: 'Enter lead name',
            ),
          ),
        ),

        // Status dropdown
        _buildLabeledField(
          label: 'Status',
          child: DropdownButtonFormField<String>(
            value: _status,
            dropdownColor: _primaryColor,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: _neonInputDecoration(),
            items: const [
              DropdownMenuItem(
                value: 'new',
                child: Text('New'),
              ),
              DropdownMenuItem(
                value: 'in_progress',
                child: Text('In progress'),
              ),
              DropdownMenuItem(
                value: 'follow_up',
                child: Text('Follow up'),
              ),
              DropdownMenuItem(
                value: 'converted',
                child: Text('Converted'),
              ),
              DropdownMenuItem(
                value: 'closed',
                child: Text('Closed'),
              ),
            ],
            onChanged: (val) {
              if (val == null) return;
              setState(() {
                _status = val;
              });
            },
          ),
        ),

        // Address
        _buildLabeledField(
          label: 'Address',
          child: TextFormField(
            controller: _addressController,
            maxLines: 2,
            style: const TextStyle(color: Colors.white),
            decoration: _neonInputDecoration(
              hint: 'Address (optional)',
            ),
          ),
        ),

        // Requirements
        _buildLabeledField(
          label: 'Requirements',
          child: TextFormField(
            controller: _requirementsController,
            maxLines: 3,
            style: const TextStyle(color: Colors.white),
            decoration: _neonInputDecoration(
              hint: 'Requirements / notes',
            ),
          ),
        ),

        const SizedBox(height: 8),
      ],
    );
  }

  Widget _callHistoryRow(LeadCall call) {
    final isMissed = _isMissedCall(call);
    final isRejected = _isRejectedCall(call);

    final statusColor = isMissed || isRejected
        ? Colors.red.shade400
        : Colors.greenAccent.shade400;

    final statusLabel = isMissed
        ? 'MISSED'
        : isRejected
            ? 'REJECTED'
            : (call.durationInSeconds != null &&
                    (call.durationInSeconds ?? 0) > 0)
                ? 'ANSWERED'
                : '';

    final handlerName = (call.handledByUserName ?? '').trim().isEmpty
        ? null
        : call.handledByUserName!.trim();

    final timeLabel = _formatTime24(call.finalizedAt ?? call.createdAt);
    final durationLabel = _formatDuration(call.durationInSeconds);

    Icon directionIcon;
    if (call.direction == 'inbound') {
      directionIcon =
          Icon(Icons.call_received, color: Colors.tealAccent, size: 22);
    } else if (call.direction == 'outbound') {
      directionIcon =
          Icon(Icons.call_made, color: Colors.blueAccent.shade200, size: 22);
    } else {
      directionIcon =
          Icon(Icons.phone, color: Colors.blueGrey.shade200, size: 22);
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        gradient: _cardGradient,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.04)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.45),
            blurRadius: 18,
            offset: const Offset(0, 12),
          )
        ],
      ),
      child: Row(
        children: [
          // Direction icon box
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF0F172A),
                  Color(0xFF020617),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.5),
                  blurRadius: 14,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Center(child: directionIcon),
          ),
          const SizedBox(width: 14),

          // Middle info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        timeLabel.isEmpty ? 'Call' : timeLabel,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    if (statusLabel.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: (isMissed || isRejected)
                              ? Colors.red.withOpacity(0.25)
                              : Colors.green.withOpacity(0.25),
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
                    ],
                  ],
                ),
                const SizedBox(height: 6),

                Row(
                  children: [
                    if (handlerName != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0B1120),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.08),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.person,
                                size: 12,
                                color: Colors.blueGrey.shade100),
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
                    if (durationLabel.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF020617),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                              color: Colors.white.withOpacity(0.04)),
                        ),
                        child: Text(
                          durationLabel,
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

          const SizedBox(width: 10),

          // Right side: call + WhatsApp buttons
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF020617),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.6),
                      blurRadius: 10,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: IconButton(
                  icon: const Icon(Icons.phone, size: 20),
                  color: Colors.greenAccent,
                  onPressed: () => _openDialer(call.phoneNumber),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF020617),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.6),
                      blurRadius: 10,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: IconButton(
                  iconSize: 20,
                  icon: Image.network(
                    'https://upload.wikimedia.org/wikipedia/commons/5/5e/WhatsApp_icon.png',
                    width: 20,
                    height: 20,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.message,
                      size: 20,
                      color: Colors.greenAccent,
                    ),
                  ),
                  onPressed: () => _openWhatsApp(call.phoneNumber),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCallHistorySection() {
    if (_loadingCalls) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_loadError != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Error loading call history:\n$_loadError',
          style: const TextStyle(color: Colors.redAccent),
        ),
      );
    }

    if (_calls.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No calls found for this lead yet.',
          style: TextStyle(color: _mutedText),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 24, 16, 4),
          child: Text(
            'Call history',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Latest calls for this lead',
            style: TextStyle(
              color: _mutedText,
              fontSize: 13,
            ),
          ),
        ),
        const SizedBox(height: 8),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _calls.length,
          itemBuilder: (context, index) {
            final call = _calls[index];
            return _callHistoryRow(call);
          },
        ),
      ],
    );
  }

  // ---------------------------- BUILD ----------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDark1,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(88),
        child: Container(
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
          child: SafeArea(
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        GradientAppBarTitle(
                          'Lead details',
                          fontSize: 20,
                        ),
                        SizedBox(height: 6),
                        Text(
                          'Profile & recent calls',
                          style: TextStyle(
                            color: _mutedText,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [_accentIndigo, _accentCyan],
                      ),
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.35),
                          blurRadius: 16,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.person,
                            color: Colors.black87, size: 18),
                        SizedBox(width: 6),
                        Text(
                          'Lead',
                          style: TextStyle(
                            color: Colors.black87,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
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
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeaderCard(),
              _buildDetailsForm(), // <-- new section with neon borders
              _buildCallHistorySection(),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
