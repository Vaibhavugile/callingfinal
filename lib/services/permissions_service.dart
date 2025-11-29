// lib/services/permissions_service.dart
// Robust permission flow with "show rationale once" and OEM helpers.

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PermissionsService {
  static const MethodChannel _nativeChannel = MethodChannel('oem/settings');
  static const String _kRationaleShownPrefix = 'rationale_shown_';

  // ------------------------
  // Public API
  // ------------------------

  static Future<void> ensureAllPermissions(BuildContext ctx) async {
    try {
      await Future.delayed(const Duration(milliseconds: 250));

      await _handlePermissionWithOnceRationale(
        ctx,
        key: 'phone',
        permission: Permission.phone,
        title: 'Phone & Call access',
        message:
            'This app needs access to phone/call state so it can detect incoming/outgoing calls and log them to leads.',
        requiredQuietlyIfShown: true,
      );

      await _showInfoOnceIfNeeded(
        ctx,
        key: 'foreground_service',
        title: 'Foreground service',
        message:
            'The app uses a foreground service to reliably monitor call events. You do not need to take action — this is just to inform you.',
      );

      await _handleOverlayOnce(ctx, key: 'overlay');

      await _handlePermissionWithOnceRationale(
        ctx,
        key: 'notifications',
        permission: Permission.notification,
        title: 'Notifications',
        message: 'Allow notifications so the app can show call capture / missed-call alerts.',
        requiredQuietlyIfShown: true,
      );

      await _handlePermissionWithOnceRationale(
        ctx,
        key: 'read_call_log',
        permission: Permission.phone,
        title: 'Call log access (optional)',
        message:
            'To better match past calls and provide more accurate call history we request access to call logs. You can deny this if preferred.',
        requiredQuietlyIfShown: false,
      );

      // Ask native to request dialer role (Android)
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

  /// Heuristic: does this device probably need OEM settings (overlay/battery/autostart)
  static Future<bool> needsOemSettings() async {
    try {
      if (!Platform.isAndroid) return false;

      // overlay permission
      final overlayStatus = await Permission.systemAlertWindow.status;
      if (!overlayStatus.isGranted) return true;

      // battery optimization ignored? If ignoreBatteryOptimizations permission exists, check it:
      try {
        final ignoreStatus = await Permission.ignoreBatteryOptimizations.status;
        if (ignoreStatus.isDenied) return true;
      } catch (_) {
        // Some devices/permission_handler versions don't expose this permission — fallback: check common ones
      }

      // notifications sometimes blocked — don't treat as OEM necessity
      return false;
    } catch (e) {
      debugPrint('needsOemSettings error: $e');
      return false;
    }
  }

  /// Try to open OEM-specific auto-start/floating/battery settings using a native method channel.
  /// Falls back to opening the generic App Settings if native doesn't handle it.
  static Future<void> openOemSettings() async {
    try {
      // Try vendor-specific native deep links first (MainActivity must implement 'openAutoStartSettings')
      try {
        final res = await _nativeChannel.invokeMethod<bool>('openAutoStartSettings');
        if (res == true) return;
      } catch (e) {
        debugPrint('openAutoStartSettings native not available or failed: $e');
      }

      // Fallback: open App settings
      await openAppSettings();
    } catch (e) {
      debugPrint('openOemSettings fallback error: $e');
    }
  }

  // ------------------------
  // Debug helper
  // ------------------------

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
    } catch (_) {}
  }

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
        final proceed = await _showRationaleDialog(ctx, title: title, message: message);
        await _setShownRationale(key);
        if (!proceed) return;
        final result = await permission.request();
        if (result.isPermanentlyDenied) {
          await _showSettingsRedirectDialog(ctx, title, message);
        }
      } else {
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

      final req = await Permission.systemAlertWindow.request();
      if (req.isPermanentlyDenied) {
        await _showSettingsRedirectDialog(ctx, 'Display over apps', 'The overlay permission is blocked.');
      }
    } catch (e) {
      debugPrint('_handleOverlayOnce error: $e');
    }
  }

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
