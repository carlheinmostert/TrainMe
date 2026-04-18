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
import 'screens/auth_gate.dart';

/// TrainMe — Exercise plan capture and sharing for biokineticists.
///
/// App entry point. Initializes local storage and the background conversion
/// service, then hands off to the home screen.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize path resolver before anything that touches file paths
  await PathResolver.initialize();

  // Lock to portrait — exercise demos are filmed vertically
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

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
