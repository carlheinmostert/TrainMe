import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Call once per test file (inside `setUpAll`) to initialise sqflite_ffi
/// for the host (non-Flutter) test runner.
void setUpSqfliteFfi() {
  sqfliteFfiInit();
}
