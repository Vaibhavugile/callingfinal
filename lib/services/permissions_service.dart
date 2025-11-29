// lib/services/permissions_service.dart
// Robust permission flow with "show rationale once" behavior and safe fallbacks.
//
// Dependencies (pubspec.yaml):
//   permission_handler: ^10.x
//   url_launcher: ^6.x

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PermissionsService {
  // Native method channel (matches MainActivity in Android)
  static const MethodChannel _nativeChannel = MethodChannel('com.example.call_leads_app/native');

  // Prefix used for SharedPreferences keys tracking which rationales/info dialogs were shown.
  static const String _kRationaleShownPrefix = 'rationale_shown_';

  // ------------------------
  // Public API
  // ------------------------

  /// Ensure all app-required permissions are requested, showing rationales/info
  /// dialogs only once per app install (persisted in SharedPreferences).
  ///
  /// Call this from an addPostFrameCallback (so dialogs don't race with initial builds).
  static Future<void> ensureAllPermissions(BuildContext ctx) async {
    try {
      // Slight delay so UI is ready
      await Future.delayed(const Duration(milliseconds: 250));

      // PHONE-related permissions (READ_PHONE_STATE / READ_PHONE_NUMBERS proxy)
      await _handlePermissionWithOnceRationale(
        ctx,
        key: 'phone',
        permission: Permission.phone,
        title: 'Phone & Call access',
        message:
            'This app needs access to phone/call state so it can detect incoming/outgoing calls and log them to leads.',
        requiredQuietlyIfShown: true,
      );

      // FOREGROUND SERVICE: inform the user only once (no Android runtime permission required)
      await _showInfoOnceIfNeeded(
        ctx,
        key: 'foreground_service',
        title: 'Foreground service',
        message:
            'The app uses a foreground service to reliably monitor call events. You do not need to take action — this is just to inform you.',
      );

      // Draw over other apps (overlay) — special permission; ask once
      await _handleOverlayOnce(ctx, key: 'overlay');

      // Notifications (Android 13+ runtime POST_NOTIFICATIONS) — ask once
      await _handlePermissionWithOnceRationale(
        ctx,
        key: 'notifications',
        permission: Permission.notification,
        title: 'Notifications',
        message: 'Allow notifications so the app can show call capture / missed-call alerts.',
        requiredQuietlyIfShown: true,
      );

      // Optional: Read Call Log — show rationale once. permission_handler may not expose explicit readCallLog on all SDKs,
      // so we use Permission.phone as a proxy where appropriate.
      await _handlePermissionWithOnceRationale(
        ctx,
        key: 'read_call_log',
        permission: Permission.phone,
        title: 'Call log access (optional)',
        message:
            'To better match past calls and provide more accurate call history we request access to call logs. You can deny this if preferred.',
        requiredQuietlyIfShown: false, // do not noisily re-request optional permission
      );

      // Ask native to request dialer role (Android Q+). Native shows its own system dialog.
      if (Platform.isAndroid) {
        try {
          final res = await _nativeChannel.invokeMethod<bool>('requestDialerRole');
          debugPrint('requestDialerRole -> $res');
        } catch (e) {
          debugPrint('requestDialerRole error (native may be missing): $e');
        }
      }
    } catch (e) {
      debugPrint('PermissionsService.ensureAllPermissions error: $e');
    }
  }

  /// Debug helper (use only in development) to clear the shown-rationale flags so dialogs
  /// will appear again. Safe to call — wrapped in try/catch.
  static Future<void> clearPermissionRationaleFlagsForDebug() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith(_kRationaleShownPrefix)).toList();
      for (final k in keys) {
        await prefs.remove(k);
      }
      debugPrint('Cleared ${keys.length} rationale flags (debug).');
    } catch (e) {
      debugPrint('clearPermissionRationaleFlagsForDebug error: $e');
    }
  }

  // ------------------------
  // Internal helpers
  // ------------------------

  static Future<bool> _hasShownRationale(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('$_kRationaleShownPrefix$key') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _setShownRationale(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('$_kRationaleShownPrefix$key', true);
    } catch (_) {
      // ignore
    }
  }

  /// Generic handler that shows a rationale dialog once, then requests the permission.
  /// If `requiredQuietlyIfShown` is true, we will call `.request()` quietly on subsequent app opens
  /// if the permission is still not granted (no dialog).
  static Future<void> _handlePermissionWithOnceRationale(
    BuildContext ctx, {
    required String key,
    required Permission permission,
    required String title,
    required String message,
    required bool requiredQuietlyIfShown,
  }) async {
    try {
      final status = await permission.status;

      if (status.isGranted) return;

      final shown = await _hasShownRationale(key);

      if (!shown) {
        // Show rationale dialog then request
        final proceed = await _showRationaleDialog(ctx, title: title, message: message);
        await _setShownRationale(key);
        if (!proceed) return;
        final result = await permission.request();
        if (result.isPermanentlyDenied) {
          await _showSettingsRedirectDialog(ctx, title, message);
        }
      } else {
        // Already shown once before: either request quietly (if requested) or skip
        if (requiredQuietlyIfShown) {
          try {
            final result = await permission.request();
            if (result.isPermanentlyDenied) {
              await _showSettingsRedirectDialog(ctx, title, message);
            }
          } catch (e) {
            debugPrint('_handlePermissionWithOnceRationale request error: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('_handlePermissionWithOnceRationale error: $e');
    }
  }

  /// Show simple rationale dialog (returns true if user tapped Allow).
  static Future<bool> _showRationaleDialog(BuildContext ctx,
      {required String title, required String message}) async {
    try {
      final res = await showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (c) {
          return AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Skip')),
              ElevatedButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Allow')),
            ],
          );
        },
      );
      return res ?? false;
    } catch (e) {
      debugPrint('_showRationaleDialog error: $e');
      return false;
    }
  }

  /// Show an informational dialog once (no permission). Useful for foreground service notice.
  static Future<void> _showInfoOnceIfNeeded(BuildContext ctx,
      {required String key, required String title, required String message}) async {
    try {
      final shown = await _hasShownRationale(key);
      if (shown) return;
      await showDialog<void>(
        context: ctx,
        barrierDismissible: true,
        builder: (c) {
          return AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('OK'))],
          );
        },
      );
      await _setShownRationale(key);
    } catch (e) {
      debugPrint('_showInfoOnceIfNeeded error: $e');
    }
  }

  /// Overlay / SYSTEM_ALERT_WINDOW handler showing rationale once then requesting.
  static Future<void> _handleOverlayOnce(BuildContext ctx, {required String key}) async {
    try {
      if (!Platform.isAndroid) return;

      final status = await Permission.systemAlertWindow.status;
      if (status.isGranted) return;

      final shown = await _hasShownRationale(key);
      if (!shown) {
        final proceed = await _showRationaleDialog(
          ctx,
          title: 'Display over apps',
          message: 'To show quick incoming-call UI on top of other apps we may need permission to display over other apps.',
        );
        await _setShownRationale(key);
        if (!proceed) return;
      }

      // Request (this opens the system overlay settings)
      final req = await Permission.systemAlertWindow.request();
      if (req.isPermanentlyDenied) {
        await _showSettingsRedirectDialog(ctx, 'Display over apps', 'The overlay permission is blocked.');
      }
    } catch (e) {
      debugPrint('_handleOverlayOnce error: $e');
    }
  }

  /// Settings redirect dialog (when permission is permanently denied).
  static Future<void> _showSettingsRedirectDialog(BuildContext ctx, String title, String message) async {
    try {
      await showDialog<void>(
        context: ctx,
        barrierDismissible: false,
        builder: (c) {
          return AlertDialog(
            title: Text('$title — Permission required'),
            content: Text(
                '$message\n\nThis permission has been blocked. Please open App Settings and allow it for full functionality.'),
            actions: [
              TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () async {
                  Navigator.of(c).pop();
                  await openAppSettings();
                },
                child: const Text('Open settings'),
              ),
            ],
          );
        },
      );
    } catch (e) {
      debugPrint('_showSettingsRedirectDialog error: $e');
    }
  }
}
