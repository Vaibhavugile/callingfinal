// lib/main.dart
// Main entry - integrated with PermissionsService and OEM settings onboarding.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

import 'call_event_handler.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/oem_settings_screen.dart';
import 'services/auth_service.dart';
import 'services/permissions_service.dart';

const MethodChannel _nativeChannel =
    MethodChannel('com.example.call_leads_app/native');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------
  // 1) Initialize Firebase
  // -------------------------------------------------------------
  try {
    await Firebase.initializeApp();
    debugPrint('✅ Firebase.initializeApp() completed.');
  } catch (e, st) {
    debugPrint('❌ Firebase.initializeApp() failed: $e\n$st');
  }

  // -------------------------------------------------------------
  // 2) Setup Crashlytics forwarding for framework errors
  // -------------------------------------------------------------
  FlutterError.onError = (FlutterErrorDetails details) {
    FirebaseCrashlytics.instance.recordFlutterFatalError(details);
  };

  // Optional: send a non-fatal event on startup to test Crashlytics
  try {
    FirebaseCrashlytics.instance.recordError(
      Exception("TEST_STARTUP_EVENT_FROM_MAIN.DART"),
      StackTrace.current,
      fatal: false,
    );
    debugPrint("📡 Sent test Crashlytics startup event.");
  } catch (e) {
    debugPrint("⚠️ Crashlytics test event failed to send: $e");
  }

  // -------------------------------------------------------------
  // 3) Pre-warm SharedPreferences
  // -------------------------------------------------------------
  try {
    final prefs = await SharedPreferences.getInstance();
    final tenant = prefs.getString('tenantId') ?? '<not-set>';
    debugPrint('📣 Preloaded SharedPreferences tenantId=$tenant');
  } catch (e) {
    debugPrint('⚠️ Could not read SharedPreferences on startup: $e');
  }

  // -------------------------------------------------------------
  // 4) Early native event flush
  // -------------------------------------------------------------
  try {
    await _nativeChannel.invokeMethod('flushPendingEvents');
    debugPrint('🔁 Requested native flushPendingEvents()');
  } catch (e) {
    debugPrint('ℹ️ flushPendingEvents not available or failed: $e');
  }

  // -------------------------------------------------------------
  // 5) Run app inside a guarded zone so uncaught async errors are reported
  // -------------------------------------------------------------
  runZonedGuarded<Future<void>>(
    () async {
      runApp(MyApp());
    },
    (error, stack) {
      try {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      } catch (e) {
        debugPrint('⚠️ Failed to send error to Crashlytics: $e');
        debugPrint('Original error: $error\n$stack');
      }
    },
  );
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

    // -------------------------------------------------------------
    // Runtime permissions & OEM settings onboarding
    // -------------------------------------------------------------
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await PermissionsService.ensureAllPermissions(
          navigatorKey.currentContext ?? context,
        );
        debugPrint('🔔 Permissions flow completed.');

        final needs = await PermissionsService.needsOemSettings();
        final prefs = await SharedPreferences.getInstance();
        final shown = prefs.getBool('oem_settings_shown') ?? false;

        if (needs && !shown) {
          await Navigator.of(navigatorKey.currentContext ?? context).push(
            MaterialPageRoute(builder: (_) => const OemSettingsScreen()),
          );
          await prefs.setBool('oem_settings_shown', true);
        }
      } catch (e) {
        debugPrint('⚠️ Permissions/OEM flow error: $e');
      }
    });

    // -------------------------------------------------------------
    // Firebase Authentication listener
    // -------------------------------------------------------------
    _authSub =
        FirebaseAuth.instance.authStateChanges().listen((User? user) async {
      debugPrint("🔐 authStateChanges() => uid=${user?.uid}");

      if (user != null) {
        debugPrint("➡️ User signed in: ${user.uid}");

        try {
          await _ensureTenantSyncedForUser(user.uid);
        } catch (e) {
          debugPrint("⚠️ Tenant sync error: $e");
        }

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

    if (state == AppLifecycleState.resumed &&
        FirebaseAuth.instance.currentUser != null) {
      debugPrint("🔄 Resumed — reattaching CallEventHandler.");
      try {
        _callHandler.startListening();
      } catch (e) {
        debugPrint("❌ startListening on resume failed: $e");
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
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }

          final user = snapshot.data;

          if (user == null) {
            debugPrint("🧭 Navigating to LoginScreen");
            return LoginScreen();
          } else {
            debugPrint("🧭 Navigating to HomeScreen (uid=${user.uid})");
            return HomeScreen(callHandler: _callHandler);
          }
        },
      ),
    );
  }

  // -------------------------------------------------------------
  // Sync tenantId to SharedPreferences + Native layer
  // -------------------------------------------------------------
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
      debugPrint("ℹ️ userProfiles/$uid has NO tenantId.");
      return;
    }

    await prefs.setString("tenantId", tenant);
    debugPrint("✅ Stored tenantId in SharedPreferences → $tenant");

    try {
      await _nativeChannel.invokeMethod("setTenantId", {"tenantId": tenant});
      debugPrint("✅ Synced tenantId to native layer → $tenant");
    } catch (e) {
      debugPrint("⚠️ Native tenant sync failed: $e");
    }
  }
}
