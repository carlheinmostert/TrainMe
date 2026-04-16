import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/local_storage_service.dart';
import 'services/conversion_service.dart';
import 'screens/home_screen.dart';

/// Raidme — Exercise plan capture and sharing for biokineticists.
///
/// App entry point. Initializes local storage and the background conversion
/// service, then hands off to the home screen.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait — exercise demos are filmed vertically
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Initialize local storage (SQLite)
  final storage = LocalStorageService();
  await storage.init();

  // Initialize the conversion service and restore any queued items
  // from a previous session (crash recovery)
  final conversion = ConversionService(storage: storage);
  await conversion.restoreQueue();

  runApp(RaidmeApp(storage: storage, conversion: conversion));
}

class RaidmeApp extends StatelessWidget {
  final LocalStorageService storage;
  final ConversionService conversion;

  const RaidmeApp({
    super.key,
    required this.storage,
    required this.conversion,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Raidme',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        // Clean, minimal theme: white background, dark text
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.black,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black87,
          elevation: 0,
          centerTitle: true,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.black87,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.grey.shade50,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        useMaterial3: true,
      ),
      home: HomeScreen(storage: storage),
    );
  }
}
