// lib/screens/login_screen.dart
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';

import '../services/auth_service.dart';

// ----------------------- DARK / NEON THEME CONSTANTS ----------------------
// These are copied from lead_details_screen.dart and lead_form_screen.dart
const Color _bgDark1 = Color(0xFF0B1220); // Primary dark background
const Color _bgDark2 = Color(0xFF020617); // Secondary dark background
const Color _accentIndigo = Color(0xFF6366F1); // Primary accent (used for buttons)
const Color _accentCyan = Color(0xFF38BDF8); // Secondary accent (used for highlights)

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
    Color(0xFF0F172A), // Slightly lighter dark
    _bgDark2,
  ],
);
// --------------------------------------------------------------------------

/// Premium login / signup screen with improved UI/UX.
/// Keeps the same behavior as your previous screen (signIn/signUp/reset),
/// but now ties into the app Theme (primary/secondary colors, background).
class LoginScreen extends StatefulWidget {
  final VoidCallback? onSignedIn;

  const LoginScreen({Key? key, this.onSignedIn}) : super(key: key);

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

// Dark, subtle background for TextFields (no more white boxes).
const Color _fieldBg = Color(0xFF111827);

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _emailCtl = TextEditingController();
  final TextEditingController _passCtl = TextEditingController();
  final TextEditingController _tenantCtl = TextEditingController();

  final AuthService _auth = AuthService();

  bool _isSignUpMode = false;
  bool _loading = false;
  String? _error;
  bool _rememberMe = false;
  bool _obscurePassword = true;

  // small entrance animation for logo/card
  late final AnimationController _animCtrl;
  late final Animation<double> _logoScale;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _logoScale = CurvedAnimation(
      parent: _animCtrl,
      curve: Curves.elasticOut,
    );
    _animCtrl.forward();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _emailCtl.dispose();
    _passCtl.dispose();
    _tenantCtl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Initialize Firebase if not yet initialized (safe-guard)
      try {
        await Firebase.initializeApp();
      } catch (_) {}

      if (_isSignUpMode) {
        final tenantProvided =
            _tenantCtl.text.trim().isNotEmpty ? _tenantCtl.text.trim() : null;
        try {
          await _auth.signUpWithEmail(
            email: _emailCtl.text.trim(),
            password: _passCtl.text,
            displayName: null,
            tenantIdForNewUser: tenantProvided,
          );
          if (widget.onSignedIn != null) widget.onSignedIn!();
        } catch (e) {
          setState(() => _error = e.toString());
        }
      } else {
        try {
          await _auth.signInWithEmail(
            email: _emailCtl.text.trim(),
            password: _passCtl.text,
          );
          if (widget.onSignedIn != null) widget.onSignedIn!();
        } catch (e) {
          setState(() => _error = e.toString());
        }
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String? _validateEmail(String? s) {
    if (s == null || s.trim().isEmpty) return 'Please enter your email';
    final email = s.trim();
    if (!RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(email)) {
      return 'Invalid email';
    }
    return null;
  }

  String? _validatePassword(String? s) {
    if (s == null || s.isEmpty) return 'Please enter password';
    if (s.length < 6) return 'Minimum 6 characters';
    return null;
  }

  Future<void> _sendPasswordReset() async {
    final email = _emailCtl.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Enter email to reset password');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await _auth.sendPasswordReset(email: email);
      setState(() => _error = 'Password reset email sent');
    } catch (e) {
      setState(() => _error = 'Failed to send reset: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  InputDecoration _darkFieldDecoration({
    required String label,
    required IconData icon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(
        icon,
        color: Colors.white70,
      ),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: _fieldBg,
      labelStyle: const TextStyle(
        color: Colors.white70,
      ),
      hintStyle: const TextStyle(
        color: Colors.white54,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(
          color: Colors.white24,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(
          color: _accentIndigo,
          width: 1.4,
        ),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(
          color: Colors.redAccent,
        ),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(
          color: Colors.redAccent,
          width: 1.4,
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 14,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final bool isWide = mq.size.width > 700;

    final theme = Theme.of(context);

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        // Match background / gradient with app theme
        decoration: const BoxDecoration(
          // Use the dark theme app bar gradient
          gradient: _appBarGradient,
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Left: branding / illustration (hidden on narrow screens)
                    if (isWide)
                      Expanded(
                        flex: 5,
                        child: FadeTransition(
                          opacity: _logoScale,
                          child: ScaleTransition(
                            scale: _logoScale,
                            child: _BrandPanel(),
                          ),
                        ),
                      ),

                    // Right: form card
                    Expanded(
                      flex: 6,
                      child: Center(
                        // Replaced Card with Container to use the dark gradient
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: _cardGradient,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.06),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.4),
                                blurRadius: 20,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(22.0),
                            child: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // title + subtitle
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              _isSignUpMode
                                                  ? 'Create account'
                                                  : 'Welcome back',
                                              style: theme.textTheme.titleLarge
                                                  ?.copyWith(
                                                color: _accentCyan,
                                                fontSize: 22,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              _isSignUpMode
                                                  ? 'Sign up to continue'
                                                  : 'Sign in to access your leads',
                                              style: theme
                                                  .textTheme.bodyMedium
                                                  ?.copyWith(
                                                color: Colors.white70,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      // tiny accent pill
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [
                                              _accentIndigo,
                                              _accentIndigo.withOpacity(0.7),
                                            ],
                                          ),
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          _isSignUpMode ? 'New' : 'Sign In',
                                          style: theme.textTheme.labelMedium
                                              ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                            color: Colors.black,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 18),

                                  if (_error != null)
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 10,
                                        horizontal: 12,
                                      ),
                                      margin:
                                          const EdgeInsets.only(bottom: 12),
                                      decoration: BoxDecoration(
                                        color: Colors.red.shade900
                                            .withOpacity(0.3),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: Colors.red.shade700,
                                        ),
                                      ),
                                      child: Text(
                                        _error!,
                                        style: TextStyle(
                                          color: Colors.red.shade200,
                                        ),
                                      ),
                                    ),

                                  Form(
                                    key: _formKey,
                                    child: Column(
                                      children: [
                                        // email
                                        TextFormField(
                                          controller: _emailCtl,
                                          keyboardType:
                                              TextInputType.emailAddress,
                                          autofillHints: const [
                                            AutofillHints.email
                                          ],
                                          validator: _validateEmail,
                                          style: const TextStyle(
                                            color: Colors.white,
                                          ),
                                          cursorColor: _accentIndigo,
                                          decoration: _darkFieldDecoration(
                                            label: 'Email',
                                            icon: Icons.email_outlined,
                                          ),
                                        ),
                                        const SizedBox(height: 12),

                                        // password with toggle
                                        TextFormField(
                                          controller: _passCtl,
                                          obscureText: _obscurePassword,
                                          validator: _validatePassword,
                                          style: const TextStyle(
                                            color: Colors.white,
                                          ),
                                          cursorColor: _accentIndigo,
                                          decoration: _darkFieldDecoration(
                                            label: 'Password',
                                            icon: Icons.lock_outline,
                                            suffixIcon: IconButton(
                                              icon: Icon(
                                                _obscurePassword
                                                    ? Icons.visibility_off
                                                    : Icons.visibility,
                                                color: Colors.white70,
                                              ),
                                              onPressed: () => setState(
                                                () => _obscurePassword =
                                                    !_obscurePassword,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 10),

                                        // tenant (only sign up)
                                        AnimatedCrossFade(
                                          firstChild:
                                              const SizedBox.shrink(),
                                          secondChild: Column(
                                            children: [
                                              TextFormField(
                                                controller: _tenantCtl,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                ),
                                                cursorColor: _accentIndigo,
                                                decoration:
                                                    _darkFieldDecoration(
                                                  label:
                                                      'Tenant ID (optional)',
                                                  icon: Icons
                                                      .apartment_outlined,
                                                ),
                                              ),
                                              const SizedBox(height: 12),
                                            ],
                                          ),
                                          crossFadeState: _isSignUpMode
                                              ? CrossFadeState.showSecond
                                              : CrossFadeState.showFirst,
                                          duration: const Duration(
                                            milliseconds: 260,
                                          ),
                                        ),

                                        // remember + forgot row
                                        

                                        const SizedBox(height: 12),

                                        // submit button
                                        SizedBox(
                                          width: double.infinity,
                                          height: 52,
                                          child: ElevatedButton(
                                            onPressed:
                                                _loading ? null : _submit,
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: _accentIndigo,
                                              foregroundColor: Colors.black,
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                              elevation: 6,
                                            ),
                                            child: _loading
                                                ? const SizedBox(
                                                    width: 22,
                                                    height: 22,
                                                    child:
                                                        CircularProgressIndicator(
                                                      color: Colors.black,
                                                      strokeWidth: 2.2,
                                                    ),
                                                  )
                                                : Text(
                                                    _isSignUpMode
                                                        ? 'Sign Up'
                                                        : 'Sign in',
                                                    style: const TextStyle(
                                                      fontSize: 16,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                          ),
                                        ),

                                        const SizedBox(height: 12),

                                        // alternative actions / mode switch
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              _isSignUpMode
                                                  ? 'Already have an account?'
                                                  : "Don't have an account?",
                                              style: const TextStyle(
                                                color: Colors.white70,
                                              ),
                                            ),
                                            TextButton(
                                              onPressed: _loading
                                                  ? null
                                                  : () {
                                                      setState(() {
                                                        _isSignUpMode =
                                                            !_isSignUpMode;
                                                        _error = null;
                                                      });
                                                    },
                                              child: Text(
                                                _isSignUpMode
                                                    ? 'Sign in'
                                                    : 'Sign Up',
                                                style: const TextStyle(
                                                  color: _accentCyan,
                                                  fontWeight: FontWeight.w600,
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
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Left-side branding panel with short message and illustration.
/// Kept simple so it looks clean in the app.
class _BrandPanel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(right: 28.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // small glossy logo
          Container(
            width: 110,
            height: 110,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [
                  _accentCyan,
                  _accentIndigo.withOpacity(0.7),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: const Icon(
              Icons.call,
              size: 48,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Sales assistant\nbuilt for speed',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              height: 1.05,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Log calls, manage leads, and never miss a follow up. '
            'Premium visuals, fast workflows.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white.withOpacity(0.9),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
