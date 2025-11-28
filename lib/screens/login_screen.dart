// lib/screens/login_screen.dart
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';

import '../services/auth_service.dart';

/// Premium login / signup screen with improved UI/UX.
/// Keeps the same behavior as your previous screen (signIn/signUp/reset),
/// but uses modern visuals: gradient background, glossy form card, animations.
class LoginScreen extends StatefulWidget {
  final VoidCallback? onSignedIn;

  const LoginScreen({Key? key, this.onSignedIn}) : super(key: key);

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

const Color _primaryColor = Color(0xFF1A237E); // deep indigo
const Color _accentColor = Color(0xFFE6A600); // gold/amber
const Color _mutedBg = Color(0xFFF4F6FA);

class _LoginScreenState extends State<LoginScreen> with SingleTickerProviderStateMixin {
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
    _animCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _logoScale = CurvedAnimation(parent: _animCtrl, curve: Curves.elasticOut);
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
        final tenantProvided = _tenantCtl.text.trim().isNotEmpty ? _tenantCtl.text.trim() : null;
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
    if (!RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(email)) return 'Invalid email';
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

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final bool isWide = mq.size.width > 700;

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0F172A),
              Color(0xFF1A237E),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
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
                        child: Card(
                          elevation: 18,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          color: Colors.white,
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
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              _isSignUpMode ? 'Create account' : 'Welcome back',
                                              style: const TextStyle(
                                                color: _primaryColor,
                                                fontSize: 22,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              _isSignUpMode ? 'Sign up to continue' : 'Sign in to access your leads',
                                              style: TextStyle(color: Colors.grey.shade600),
                                            ),
                                          ],
                                        ),
                                      ),
                                      // tiny accent pill
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        decoration: BoxDecoration(
                                          gradient: const LinearGradient(colors: [_accentColor, Color(0xFFF6E27A)]),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Text(_isSignUpMode ? 'New' : 'Sign In',
                                            style: const TextStyle(fontWeight: FontWeight.w700)),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 18),

                                  if (_error != null)
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                                      margin: const EdgeInsets.only(bottom: 12),
                                      decoration: BoxDecoration(
                                        color: Colors.red.shade50,
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: Colors.red.shade100),
                                      ),
                                      child: Text(
                                        _error!,
                                        style: TextStyle(color: Colors.red.shade700),
                                      ),
                                    ),

                                  Form(
                                    key: _formKey,
                                    child: Column(
                                      children: [
                                        // email
                                        TextFormField(
                                          controller: _emailCtl,
                                          keyboardType: TextInputType.emailAddress,
                                          autofillHints: const [AutofillHints.email],
                                          validator: _validateEmail,
                                          decoration: InputDecoration(
                                            labelText: 'Email',
                                            prefixIcon: const Icon(Icons.email_outlined),
                                            filled: true,
                                            fillColor: _mutedBg,
                                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                          ),
                                        ),
                                        const SizedBox(height: 12),

                                        // password with toggle
                                        TextFormField(
                                          controller: _passCtl,
                                          obscureText: _obscurePassword,
                                          validator: _validatePassword,
                                          decoration: InputDecoration(
                                            labelText: 'Password',
                                            prefixIcon: const Icon(Icons.lock_outline),
                                            filled: true,
                                            fillColor: _mutedBg,
                                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                            suffixIcon: IconButton(
                                              icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                                              onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 10),

                                        // tenant (only sign up)
                                        AnimatedCrossFade(
                                          firstChild: const SizedBox.shrink(),
                                          secondChild: Column(
                                            children: [
                                              TextFormField(
                                                controller: _tenantCtl,
                                                decoration: InputDecoration(
                                                  labelText: 'Tenant ID (optional)',
                                                  prefixIcon: const Icon(Icons.apartment_outlined),
                                                  filled: true,
                                                  fillColor: _mutedBg,
                                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                                ),
                                              ),
                                              const SizedBox(height: 12),
                                            ],
                                          ),
                                          crossFadeState: _isSignUpMode ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                                          duration: const Duration(milliseconds: 260),
                                        ),

                                        // remember + forgot row
                                        Row(
                                          children: [
                                            Expanded(
                                              child: InkWell(
                                                onTap: () => setState(() => _rememberMe = !_rememberMe),
                                                child: Row(
                                                  children: [
                                                    Checkbox(value: _rememberMe, onChanged: (v) => setState(() => _rememberMe = v ?? false)),
                                                    const SizedBox(width: 6),
                                                    Text('Remember me', style: TextStyle(color: Colors.grey.shade700)),
                                                  ],
                                                ),
                                              ),
                                            ),
                                           
                                          ],
                                        ),

                                        const SizedBox(height: 12),

                                        // submit button
                                        SizedBox(
                                          width: double.infinity,
                                          height: 52,
                                          child: ElevatedButton(
                                            onPressed: _loading ? null : _submit,
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: _primaryColor,
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                              elevation: 6,
                                            ),
                                            child: _loading
                                                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.2))
                                                : Text(_isSignUpMode ? 'Sign Up' : 'Sign in', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                                          ),
                                        ),

                                        const SizedBox(height: 12),

                                        // alternative actions / mode switch
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Text(_isSignUpMode ? 'Already have an account?' : "Don't have an account?"),
                                            TextButton(
                                              onPressed: _loading
                                                  ? null
                                                  : () {
                                                      setState(() {
                                                        _isSignUpMode = !_isSignUpMode;
                                                        _error = null;
                                                      });
                                                    },
                                              child: Text(_isSignUpMode ? 'Sign in' : 'Sign Up'),
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
              gradient: const LinearGradient(colors: [Color(0xFFFFE082), Color(0xFFFFC857)]),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 16, offset: Offset(0, 8))],
            ),
            child: const Center(
              child: Icon(Icons.call, size: 48, color: Color(0xFF0F172A)),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Sales assistant\nbuilt for speed',
            style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800, height: 1.05),
          ),
          const SizedBox(height: 12),
          Text(
            'Log calls, manage leads, and never miss a follow up. Premium visuals, fast workflows.',
            style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 14),
          ),
        ],
      ),
    );
  }
}
