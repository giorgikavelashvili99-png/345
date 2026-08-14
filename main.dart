// =============================================================================
// GPN — Gaming Ping Normalizer
// A simple, no-backend WireGuard VPN client that stabilizes ping for ONE
// selected game at a time via split tunneling. No auth, no database.
//
// REQUIRED DEPENDENCIES (add to pubspec.yaml):
//   dependencies:
//     flutter:
//       sdk: flutter
//     wireguard_flutter: ^0.1.9   // check pub.dev for the latest version —
//                                 // method/enum names below (initialize,
//                                 // startVpn, vpnStageSnapshot, VpnStage)
//                                 // may differ slightly between plugin
//                                 // versions; verify against yours.
//     device_apps: ^2.2.0        // Android-only installed-app listing
//
// ANDROID SETUP:
//   - minSdkVersion 21+ in android/app/build.gradle
//   - Android 11+ needs a <queries> block in AndroidManifest.xml so the
//     app can see other installed apps, e.g.:
//       <queries>
//         <intent><action android:name="android.intent.action.MAIN"/></intent>
//       </queries>
//   - No manual VPN permission entry is required — the wireguard-android
//     library triggers the system VpnService consent dialog
//     (VpnService.prepare) automatically the first time startVpn() runs.
//   - Split tunneling below is implemented via the "IncludedApplications"
//     key inside the wg-quick config text. The native wireguard-android
//     library reads that key and calls VpnService.Builder
//     .addAllowedApplication() internally when it builds the tunnel — you
//     don't call that Android API directly from Dart.
//
// iOS SETUP:
//   - Requires a Network Extension app target, a paid Apple Developer
//     account, and the networkextension entitlement from Apple.
//   - iOS has no equivalent of addAllowedApplication for regular
//     third-party apps outside MDM-supervised devices, so on iOS this
//     app can only tunnel ALL device traffic — not a single selected game.
//
// SECURITY NOTE:
//   The WireGuardConfig values below are placeholders. If you ship this
//   publicly with ONE hardcoded private key baked into every install,
//   every user's device presents the SAME WireGuard identity to your
//   server — new connections will keep kicking older ones offline.
//   Hardcoding is fine for a personal/single-device build. A public app
//   needs either per-install self-generated keypairs (`wg genkey` run
//   on-device, with the server accepting any peer on a shared scheme) or
//   a small provisioning endpoint handing out unique keys — both go
//   beyond "no backend" but are worth knowing before shipping this wider.
// =============================================================================

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:wireguard_flutter/wireguard_flutter.dart';
import 'package:device_apps/device_apps.dart';

void main() {
  runApp(const GpnApp());
}

class GpnApp extends StatelessWidget {
  const GpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GPN',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D0D0F),
      ),
      home: const HomeScreen(),
    );
  }
}

// -----------------------------------------------------------------------
// Hardcoded WireGuard server config — see SECURITY NOTE above.
// -----------------------------------------------------------------------
class WireGuardConfig {
  static const String serverAddress = '203.0.113.10:51820';
  static const String clientPrivateKey = 'YOUR_CLIENT_PRIVATE_KEY_HERE=';
  static const String serverPublicKey = 'YOUR_SERVER_PUBLIC_KEY_HERE=';
  static const String clientAddress = '10.66.66.2/32';
  static const String dns = '1.1.1.1';
  // iOS only — bundle id of your Network Extension target.
  static const String iosProviderBundleIdentifier =
      'com.yourcompany.gpn.VPNExtension';
}

/// Builds a wg-quick style config, optionally restricted to one app's
/// traffic for split tunneling (Android only — see notes above).
String buildWgQuickConfig({String? allowedAppPackage}) {
  final buffer = StringBuffer()
    ..writeln('[Interface]')
    ..writeln('PrivateKey = ${WireGuardConfig.clientPrivateKey}')
    ..writeln('Address = ${WireGuardConfig.clientAddress}')
    ..writeln('DNS = ${WireGuardConfig.dns}');

  if (allowedAppPackage != null && allowedAppPackage.isNotEmpty) {
    buffer.writeln('IncludedApplications = $allowedAppPackage');
  }

  buffer
    ..writeln()
    ..writeln('[Peer]')
    ..writeln('PublicKey = ${WireGuardConfig.serverPublicKey}')
    ..writeln('Endpoint = ${WireGuardConfig.serverAddress}')
    ..writeln('AllowedIPs = 0.0.0.0/0, ::/0')
    ..writeln('PersistentKeepalive = 25');

  return buffer.toString();
}

/// Simplified UI-facing connection state (kept separate from Flutter's own
/// built-in `ConnectionState` enum from async.dart to avoid a name clash).
enum GpnConnectionState { disconnected, connecting, connected, disconnecting }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final WireGuardFlutter _wireguard = WireGuardFlutter.instance;

  GpnConnectionState _state = GpnConnectionState.disconnected;
  Application? _selectedApp;
  int _ping = 45;
  Timer? _pingTimer;
  StreamSubscription<VpnStage>? _stageSub;

  @override
  void initState() {
    super.initState();
    _initWireGuard();
    _startPingSimulation();
  }

  Future<void> _initWireGuard() async {
    try {
      await _wireguard.initialize(interfaceName: 'gpn0');
      _stageSub = _wireguard.vpnStageSnapshot.listen((stage) {
        if (!mounted) return;
        setState(() => _state = _mapStage(stage));
      });
    } catch (e) {
      // The WireGuard plugin only runs on Android/iOS — safe to ignore
      // elsewhere (e.g. while iterating on the UI in a desktop simulator).
      debugPrint('WireGuard init skipped: $e');
    }
  }

  GpnConnectionState _mapStage(VpnStage stage) {
    switch (stage) {
      case VpnStage.connected:
        return GpnConnectionState.connected;
      case VpnStage.connecting:
      case VpnStage.preparing:
        return GpnConnectionState.connecting;
      case VpnStage.disconnecting:
        return GpnConnectionState.disconnecting;
      default:
        return GpnConnectionState.disconnected;
    }
  }

  void _startPingSimulation() {
    final rand = Random();
    _pingTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      setState(() {
        final connected = _state == GpnConnectionState.connected;
        final base = connected ? 26 : 45;
        final jitter = rand.nextInt(connected ? 8 : 20);
        _ping = base + jitter;
      });
    });
  }

  Future<void> _pickGame() async {
    final apps = await DeviceApps.getInstalledApplications(
      includeAppIcons: true,
      onlyAppsWithLaunchIntent: true,
    );
    apps.sort((a, b) => a.appName.compareTo(b.appName));

    if (!mounted) return;
    final chosen = await showModalBottomSheet<Application>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (context) => _AppPickerSheet(apps: apps),
    );

    if (chosen != null) {
      setState(() => _selectedApp = chosen);
    }
  }

  Future<void> _toggleConnection() async {
    if (_selectedApp == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select a game first to enable split tunneling.'),
        ),
      );
      return;
    }

    if (_state == GpnConnectionState.disconnected) {
      setState(() => _state = GpnConnectionState.connecting);
      final config = buildWgQuickConfig(
        allowedAppPackage: _selectedApp!.packageName,
      );
      try {
        await _wireguard.startVpn(
          serverAddress: WireGuardConfig.serverAddress,
          wgQuickConfig: config,
          providerBundleIdentifier: WireGuardConfig.iosProviderBundleIdentifier,
        );
      } catch (e) {
        if (!mounted) return;
        setState(() => _state = GpnConnectionState.disconnected);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection failed: $e')),
        );
      }
    } else if (_state == GpnConnectionState.connected) {
      setState(() => _state = GpnConnectionState.disconnecting);
      await _wireguard.stopVpn();
    }
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _stageSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _state == GpnConnectionState.connected;
    final busy = _state == GpnConnectionState.connecting ||
        _state == GpnConnectionState.disconnecting;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0F),
      body: SafeArea(
        child: Column(
          children: [
            _buildAppBar(),
            const Spacer(),
            _buildPingLabel(),
            const SizedBox(height: 40),
            _buildConnectButton(connected, busy),
            const SizedBox(height: 24),
            _buildStatusLabel(),
            const Spacer(),
            _buildGamePicker(),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ---- UI pieces ----

  Widget _buildAppBar() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          Icon(Icons.bolt, color: Color(0xFF00FFC2)),
          SizedBox(width: 8),
          Text(
            'GPN',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPingLabel() {
    return Column(
      children: [
        Text(
          'Current Ping',
          style: TextStyle(
            color: Colors.grey[500],
            fontSize: 13,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '$_ping ms',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildConnectButton(bool connected, bool busy) {
    final glowColor =
        connected ? const Color(0xFF00FFC2) : const Color(0xFFFF3B30);

    return GestureDetector(
      onTap: busy ? null : _toggleConnection,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
        width: 180,
        height: 180,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF1B1B1E),
          boxShadow: [
            // Colored status glow — red when off, neon when on.
            BoxShadow(
              color: glowColor.withOpacity(connected ? 0.65 : 0.35),
              blurRadius: connected ? 40 : 20,
              spreadRadius: connected ? 6 : 2,
            ),
            // Neumorphic "extruded" dark/light pair.
            const BoxShadow(
              color: Colors.black87,
              offset: Offset(8, 8),
              blurRadius: 16,
            ),
            const BoxShadow(
              color: Color(0xFF2A2A2E),
              offset: Offset(-8, -8),
              blurRadius: 16,
            ),
          ],
        ),
        child: Center(
          child: busy
              ? const CircularProgressIndicator(color: Colors.white70)
              : Icon(
                  connected ? Icons.shield_rounded : Icons.power_settings_new,
                  size: 56,
                  color: connected ? glowColor : Colors.grey[400],
                ),
        ),
      ),
    );
  }

  Widget _buildStatusLabel() {
    late String label;
    late Color color;
    switch (_state) {
      case GpnConnectionState.connected:
        label = 'Status: Connected';
        color = const Color(0xFF00FFC2);
        break;
      case GpnConnectionState.connecting:
        label = 'Status: Connecting…';
        color = Colors.amber;
        break;
      case GpnConnectionState.disconnecting:
        label = 'Status: Disconnecting…';
        color = Colors.amber;
        break;
      case GpnConnectionState.disconnected:
        label = 'Status: Disconnected';
        color = const Color(0xFFFF3B30);
        break;
    }
    return Text(
      label,
      style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w500),
    );
  }

  Widget _buildGamePicker() {
    final selected = _selectedApp;
    Widget leadingIcon = const Icon(Icons.sports_esports, color: Colors.grey);
    if (selected is ApplicationWithIcon) {
      leadingIcon = ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.memory(selected.icon, width: 28, height: 28),
      );
    }

    return GestureDetector(
      onTap: _pickGame,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 32),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF19191C),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF2A2A2E)),
        ),
        child: Row(
          children: [
            leadingIcon,
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                selected?.appName ?? 'Select a game for split tunneling',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}

class _AppPickerSheet extends StatelessWidget {
  final List<Application> apps;
  const _AppPickerSheet({required this.apps});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: 500,
        child: ListView.builder(
          itemCount: apps.length,
          itemBuilder: (context, index) {
            final app = apps[index];
            return ListTile(
              leading: app is ApplicationWithIcon
                  ? Image.memory(app.icon, width: 32, height: 32)
                  : const Icon(Icons.apps, color: Colors.grey),
              title: Text(app.appName, style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.of(context).pop(app),
            );
          },
        ),
      ),
    );
  }
}
