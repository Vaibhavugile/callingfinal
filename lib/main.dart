// lib/main.dart
// Main entry - integrated with PermissionsService and OEM settings onboarding.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

import 'call_event_handler.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/oem_settings_screen.dart';
import 'services/auth_service.dart';
import 'services/permissions_service.dart';

const MethodChannel _nativeChannel = MethodChannel('com.example.call_leads_app/native');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase before constructing anything that might use it.
  try {
    await Firebase.initializeApp();
    debugPrint('✅ Firebase.initializeApp() completed.');
  } catch (e, st) {
    debugPrint('❌ Firebase.initializeApp() failed: $e\n$st');
  }

  // Pre-warm SharedPreferences and log current tenant for quick verification.
  try {
    final prefs = await SharedPreferences.getInstance();
    final tenant = prefs.getString('tenantId') ?? '<not-set>';
    debugPrint('📣 Preloaded SharedPreferences tenantId=$tenant');
  } catch (e) {
    debugPrint('⚠️ Could not read SharedPreferences on startup: $e');
  }

  // Early attempt to flush native pending events (non-fatal)
  try {
    await _nativeChannel.invokeMethod('flushPendingEvents');
    debugPrint('🔁 Requested native flushPendingEvents()');
  } catch (e) {
    debugPrint('ℹ️ flushPendingEvents not available or failed: $e');
  }

  runApp(MyApp());
}

class MyApp extends StatefulWidget {
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  late final CallEventHandler _callHandler;
  StreamSubscription<User?>? _authSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _callHandler = CallEventHandler(navigatorKey: navigatorKey);

    // Run permission onboarding after first frame so dialogs don't conflict with startup UI
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        // Ask runtime permissions (rationale shown once per permission inside PermissionsService)
        await PermissionsService.ensureAllPermissions(navigatorKey.currentContext ?? context);
        debugPrint('🔔 Permissions flow completed (or dismissed by user).');

        // If device likely needs OEM settings (overlay/autostart/battery), show the friendly OEM settings screen ONCE.
        final needs = await PermissionsService.needsOemSettings();
        final prefs = await SharedPreferences.getInstance();
        final shown = prefs.getBool('oem_settings_shown') ?? false;

        if (needs && !shown) {
          // show a full-screen helper for the user to follow steps
          await Navigator.of(navigatorKey.currentContext ?? context).push(
            MaterialPageRoute(builder: (_) => const OemSettingsScreen()),
          );

          // mark shown once user navigates back
          await prefs.setBool('oem_settings_shown', true);
        }
      } catch (e) {
        debugPrint('⚠️ Permissions or OEM flow error: $e');
      }
    });

    // Monitor Firebase auth state
    _authSub = FirebaseAuth.instance.authStateChanges().listen((User? user) async {
      debugPrint("🔐 authStateChanges() => uid=${user?.uid}, email=${user?.email}");

      if (user != null) {
        // user logged in
        debugPrint("➡️ User signed in: ${user.uid}");

        // ensure tenant synced locally + to native
        try {
          await _ensureTenantSyncedForUser(user.uid);
        } catch (e) {
          debugPrint("⚠️ Tenant sync error: $e");
        }

        // start call handler
        try {
          Future.microtask(() => _callHandler.startListening());
        } catch (e) {
          debugPrint("❌ Failed to start CallEventHandler: $e");
        }
      } else {
        debugPrint("⬅️ User signed out.");
        try {
          _callHandler.stopListening();
        } catch (e) {
          debugPrint("❌ Failed to stop CallEventHandler: $e");
        }
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authSub?.cancel();
    _callHandler.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint("📱 Lifecycle state changed: $state");

    if (state == AppLifecycleState.resumed) {
      if (FirebaseAuth.instance.currentUser != null) {
        debugPrint("🔄 Resumed — reattaching CallEventHandler.");
        try {
          _callHandler.startListening();
        } catch (e) {
          debugPrint("❌ startListening on resume failed: $e");
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Call Leads',
      navigatorKey: navigatorKey,
      theme: ThemeData(primarySwatch: Colors.blue),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          final user = snapshot.data;

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }

          if (user == null) {
            debugPrint("🧭 Navigating to LoginScreen");
            return LoginScreen();
          } else {
            debugPrint("🧭 Navigating to HomeScreen for uid=${user.uid}");
            return HomeScreen();
          }
        },
      ),
    );
  }

  /// Ensure tenantId is present in SharedPreferences & native preferences.
  Future<void> _ensureTenantSyncedForUser(String uid) async {
    debugPrint("🔍 Checking tenant sync for uid=$uid");

    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString('tenantId');

    if (existing != null && existing.trim().isNotEmpty) {
      debugPrint("🔁 tenantId already in prefs → $existing");
      return;
    }

    debugPrint("🌐 Fetching profile from Firestore...");
    final profile = await AuthService().fetchUserProfile(uid);

    if (profile == null) {
      debugPrint("⚠️ No userProfiles/$uid doc found — cannot sync tenant.");
      return;
    }

    final tenant = (profile["tenantId"] as String?)?.trim();

    if (tenant == null || tenant.isEmpty) {
      debugPrint("ℹ️ userProfiles/$uid has NO tenantId assigned.");
      return;
    }

    // store to prefs
    await prefs.setString("tenantId", tenant);
    debugPrint("✅ Stored tenantId in SharedPreferences → $tenant");

    // store to native
    try {
      await _nativeChannel.invokeMethod("setTenantId", {"tenantId": tenant});
      debugPrint("✅ Synced tenantId to native layer → $tenant");
    } catch (e) {
      debugPrint("⚠️ Failed to sync tenantId to native prefs: $e");
    }
  }
}
