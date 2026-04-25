import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';
import 'theme.dart';
import 'theme/flags.dart';
import 'services/local_storage_service.dart';
import 'services/conversion_service.dart';
import 'services/path_resolver.dart';
import 'services/practitioner_custom_presets.dart';
import 'services/sync_service.dart';
import 'services/unified_preview_scheme_bridge.dart';
import 'screens/auth_gate.dart';
import 'widgets/orientation_lock_guard.dart';

/// TrainMe — Exercise plan capture and sharing for biokineticists.
///
/// App entry point. Initializes local storage and the background conversion
/// service, then hands off to the home screen.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize path resolver before anything that touches file paths
  await PathResolver.initialize();

  // Wave 28: portrait-only global default. Camera mode and the media
  // viewer push their own landscape allowance via OrientationLockGuard;
  // every other surface stays portrait. The guard's empty-stack
  // fallback re-applies this baseline.
  await OrientationLockGuardScope.setGlobalDefault(
    const {DeviceOrientation.portraitUp},
  );

  // Initialize Supabase for cloud storage and plan sharing
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseAnonKey,
  );

  try {
    // Initialize local storage (SQLite)
    final storage = LocalStorageService();
    await storage.init();

    // Clean up sessions that have been in the recycle bin too long
    await storage.purgeExpiredSessions();

    // Fire-and-forget: purge archived raw videos older than 90 days so the
    // local archive/ directory doesn't grow without bound. Non-blocking —
    // the bio shouldn't wait on disk I/O at launch.
    unawaited(storage.purgeOldArchives());

    // Initialize the conversion service singleton and restore any queued
    // items from a previous session (crash recovery)
    final conversion = ConversionService.initialize(storage);
    await conversion.restoreQueue();

    // Offline-first sync layer. Reads come from the SQLite cache;
    // writes land locally first, then the pending-op queue flushes to
    // the cloud as connectivity permits. Non-blocking: start() only
    // wires the connectivity listener and seeds the pending-count
    // notifier — nothing waits on the network.
    SyncService.configure(storage);
    unawaited(SyncService.instance.start());

    // Wave 4 Phase 2 — install the method-call handler for the native
    // `homefit-local://` scheme. The Swift handler will call into Dart
    // as soon as the WebView starts resolving its bundle; the channel
    // must be wired up BEFORE the first UnifiedPreviewScreen mounts.
    UnifiedPreviewSchemeBridge.instance.install();

    // Wave 18 — seed the practitioner-wide custom preset store so
    // PresetChipRow instances render the MRU chips on first paint
    // without waiting for an async load.
    await PractitionerCustomPresets.init();

    runApp(TrainMeApp(storage: storage));
  } catch (e, stack) {
    debugPrint('FATAL: App initialization failed: $e');
    debugPrint('$stack');
    runApp(MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              'Startup error:\n$e',
              style: const TextStyle(color: Colors.red, fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    ));
  }
}

class TrainMeApp extends StatelessWidget {
  final LocalStorageService storage;

  const TrainMeApp({
    super.key,
    required this.storage,
  });

  @override
  Widget build(BuildContext context) {
    // D-08: light theme tokens exist as a mirror but the app stays dark-first
    // until the second-bio onboarding polish lands. Flip kEnableLightTheme in
    // theme/flags.dart to unlock light mode.
    return MaterialApp(
      title: 'TrainMe',
      debugShowCheckedModeBanner: false,
      theme: kEnableLightTheme ? AppTheme.light : AppTheme.dark,
      darkTheme: AppTheme.dark,
      themeMode: kEnableLightTheme ? ThemeMode.system : ThemeMode.dark,
      // AuthGate is the root router: unauthenticated → SignInScreen,
      // authenticated → HomeScreen. Session persistence is handled by
      // Supabase's default secure storage (Keychain on iOS).
      home: AuthGate(storage: storage),
    );
  }
}
