// lib/screens/oem_settings_screen.dart
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/permissions_service.dart';

class OemSettingsScreen extends StatefulWidget {
  const OemSettingsScreen({Key? key}) : super(key: key);

  @override
  State<OemSettingsScreen> createState() => _OemSettingsScreenState();
}

class _OemSettingsScreenState extends State<OemSettingsScreen> {
  bool _checking = true;
  String _deviceBrand = 'device';
  bool _overlayDenied = false;
  bool _batteryOptimized = false;

  @override
  void initState() {
    super.initState();
    _probeStatus();
  }

  Future<void> _probeStatus() async {
    try {
      if (!Platform.isAndroid) {
        setState(() {
          _deviceBrand = 'non-Android device';
          _checking = false;
        });
        return;
      }

      final brand = await _getDeviceBrand();
      bool overlayDenied = false;
      bool batteryOptimized = false;

      try {
        final overlayStatus = await Permission.systemAlertWindow.status;
        overlayDenied = !overlayStatus.isGranted;
      } catch (_) {
        overlayDenied = true;
      }

      try {
        final ignoreStatus = await Permission.ignoreBatteryOptimizations.status;
        batteryOptimized = ignoreStatus.isDenied;
      } catch (_) {
        // Some platforms/versions may not expose this; treat as not definitely problematic
        batteryOptimized = false;
      }

      setState(() {
        _deviceBrand = brand.isNotEmpty ? brand : 'Android device';
        _overlayDenied = overlayDenied;
        _batteryOptimized = batteryOptimized;
        _checking = false;
      });
    } catch (e) {
      setState(() {
        _checking = false;
      });
    }
  }

  Future<String> _getDeviceBrand() async {
    try {
      final result = await const MethodChannel('oem/settings').invokeMethod<String>('getDeviceBrand');
      return (result ?? '').toString().toLowerCase();
    } catch (_) {
      // fallback: try common Android props via Platform (best-effort)
      try {
        // Platform.localeName or operatingSystem is not brand, but better than nothing
        return Platform.operatingSystem;
      } catch (_) {
        return '';
      }
    }
  }

  Widget _buildTip(String title, String text, {VoidCallback? onTap}) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: ListTile(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(text),
        trailing: onTap != null ? ElevatedButton(onPressed: onTap, child: const Text('Open')) : null,
      ),
    );
  }

  Future<void> _openAutoStart() async {
    await PermissionsService.openOemSettings();
  }

  Future<void> _openFloatingWindow() async {
    await PermissionsService.openOemSettings();
  }

  Future<void> _openBatterySettings() async {
    await PermissionsService.openOemSettings();
  }

  Future<void> _openAppSettings() async {
    try {
      await openAppSettings();
    } catch (e) {
      // fallback: call the PermissionsService opener
      await PermissionsService.openOemSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Device Settings — Keep App Running'),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: const Text('Done', style: TextStyle(color: Colors.white)),
          )
        ],
      ),
      body: _checking
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('We detected: $_deviceBrand', style: const TextStyle(fontSize: 16)),
                const SizedBox(height: 12),
                const Text(
                  'To ensure calls are captured reliably and the floating call UI works, please grant or verify the following:',
                  style: TextStyle(fontSize: 15),
                ),
                const SizedBox(height: 12),

                // Auto-start
                _buildTip(
                  'Allow Auto-start / Launch in background',
                  'This lets the app run in the background after device boot and keep the call listener active.',
                  onTap: _openAutoStart,
                ),

                // Floating window
                _buildTip(
                  'Allow Floating Window / Display over apps',
                  _overlayDenied
                      ? 'Floating window permission currently appears to be blocked. Grant it to show the incoming call popup over other apps.'
                      : 'Floating window permission looks OK. If you still see problems, re-open settings and ensure permission is allowed.',
                  onTap: _openFloatingWindow,
                ),

                // Battery optimization
                _buildTip(
                  'Disable Battery Optimization / Allow background run',
                  _batteryOptimized
                      ? 'Battery optimization may restrict background services. Whitelist the app or allow it to run unrestricted.'
                      : 'Battery optimization not detected as a problem. If you experience kills after some time, whitelist the app.',
                  onTap: _openBatterySettings,
                ),

                // App settings fallback
                _buildTip(
                  'Open App Settings',
                  'Open the app-specific settings where you can manually enable permissions, auto-start, and battery settings if needed.',
                  onTap: _openAppSettings,
                ),

                const SizedBox(height: 12),
                const Text('Device-specific hints', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                ..._deviceHints(),

                const SizedBox(height: 20),
                Center(
                  child: ElevatedButton(
                    onPressed: () async {
                      // Re-check status. If fixed, pop back
                      await _probeStatus();
                      final ok = !_overlayDenied; // simple heuristic
                      if (!ok) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('It looks like some settings are still blocked. Please follow the steps above.')),
                          );
                        }
                      } else {
                        if (mounted) Navigator.of(context).pop();
                      }
                    },
                    child: const Text('I\'ve applied the settings — test now'),
                  ),
                ),
                const SizedBox(height: 40),
                if (kDebugMode)
                  Center(
                    child: TextButton(
                      onPressed: () async {
                        await PermissionsService.clearPermissionRationaleFlagsForDebug();
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Rationale flags cleared (debug)')));
                      },
                      child: const Text('Reset permission rationales (debug)'),
                    ),
                  ),
              ]),
            ),
    );
  }

  List<Widget> _deviceHints() {
    final brand = _deviceBrand.toLowerCase();
    if (brand.contains('xiaomi') || brand.contains('redmi') || brand.contains('poco')) {
      return [
        const Text('Xiaomi / Redmi / POCO hint:'),
        const Text('- Open Security → Permissions → Autostart and enable for this app.'),
        const Text('- Open Settings → Apps → Special permissions → Display pop-up windows and enable.'),
        const SizedBox(height: 8),
      ];
    }
    if (brand.contains('huawei') || brand.contains('honor')) {
      return [
        const Text('Huawei / Honor hint:'),
        const Text('- Open Phone Manager → Startup Manager and allow this app.'),
        const Text('- Add to Protected apps to avoid background kills.'),
        const SizedBox(height: 8),
      ];
    }
    if (brand.contains('oppo') || brand.contains('realme')) {
      return [
        const Text('OPPO / realme hint:'),
        const Text('- Open Settings → Battery → App launch and allow auto-manage or manual launch.'),
        const Text('- Give Floating window / Display over other apps permission.'),
        const SizedBox(height: 8),
      ];
    }
    if (brand.contains('vivo')) {
      return [
        const Text('Vivo hint:'),
        const Text('- Open iManager/Permissions → App manager → allow floating window and autostart.'),
        const SizedBox(height: 8),
      ];
    }
    return [
      const Text('General hint:'),
      const Text('- Open App Settings → Permissions and enable required permissions.'),
      const Text('- If calls still stop after ~10–15 minutes, whitelist the app in battery / background optimizations.'),
      const SizedBox(height: 8),
    ];
  }
}
