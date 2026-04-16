import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/exercise_capture.dart';
import '../models/session.dart';

/// SQLite-backed local persistence for sessions and exercises.
///
/// All captures and session state are saved to disk immediately so that
/// a crash or app kill loses nothing. On restart, the app restores from
/// this database and re-queues any unconverted captures.
class LocalStorageService {
  static const _dbName = 'raidme.db';
  static const _dbVersion = 1;

  Database? _db;

  /// The database instance. Throws if [init] hasn't been called.
  Database get db {
    final database = _db;
    if (database == null) {
      throw StateError('LocalStorageService.init() must be called first');
    }
    return database;
  }

  /// Initialize the database. Call once at app startup before any other method.
  Future<void> init() async {
    final documentsDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(documentsDir.path, _dbName);

    _db = await openDatabase(
      dbPath,
      version: _dbVersion,
      onCreate: _createTables,
      onUpgrade: _migrateTables,
    );
  }

  /// Create the schema on first launch.
  Future<void> _createTables(Database db, int version) async {
    await db.execute('''
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        client_name TEXT NOT NULL,
        title TEXT,
        created_at INTEGER NOT NULL,
        sent_at INTEGER,
        plan_url TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE exercises (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        raw_file_path TEXT NOT NULL,
        converted_file_path TEXT,
        media_type INTEGER NOT NULL,
        conversion_status INTEGER NOT NULL DEFAULT 0,
        reps INTEGER,
        sets INTEGER,
        hold_seconds INTEGER,
        notes TEXT,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
      )
    ''');

    // Index for the most common query: "get exercises for a session, in order"
    await db.execute('''
      CREATE INDEX idx_exercises_session
      ON exercises(session_id, position)
    ''');
  }

  /// Placeholder for future schema migrations.
  Future<void> _migrateTables(Database db, int oldVersion, int newVersion) async {
    // Add migration steps here as the schema evolves.
    // Example: if (oldVersion < 2) { await db.execute('ALTER TABLE ...'); }
  }

  // ---------------------------------------------------------------------------
  // Sessions
  // ---------------------------------------------------------------------------

  /// Insert or update a session. Exercises are saved separately via
  /// [saveExercise].
  Future<void> saveSession(Session session) async {
    await db.insert(
      'sessions',
      session.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Load a session by ID, including all its exercises sorted by position.
  /// Returns null if not found.
  Future<Session?> getSession(String id) async {
    final rows = await db.query('sessions', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;

    final exercises = await _getExercisesForSession(id);
    return Session.fromMap(rows.first, exercises: exercises);
  }

  /// All sessions that haven't been sent yet, newest first.
  /// These are the bio's "in-progress" sessions.
  Future<List<Session>> getActiveSessions() async {
    final rows = await db.query(
      'sessions',
      where: 'sent_at IS NULL',
      orderBy: 'created_at DESC',
    );

    final sessions = <Session>[];
    for (final row in rows) {
      final exercises = await _getExercisesForSession(row['id'] as String);
      sessions.add(Session.fromMap(row, exercises: exercises));
    }
    return sessions;
  }

  /// Delete a session and all its exercises. Also removes associated media
  /// files from disk.
  Future<void> deleteSession(String id) async {
    // Gather file paths before deleting rows
    final exercises = await _getExercisesForSession(id);
    for (final ex in exercises) {
      _deleteFileIfExists(ex.rawFilePath);
      if (ex.convertedFilePath != null) {
        _deleteFileIfExists(ex.convertedFilePath!);
      }
    }

    await db.delete('exercises', where: 'session_id = ?', whereArgs: [id]);
    await db.delete('sessions', where: 'id = ?', whereArgs: [id]);
  }

  // ---------------------------------------------------------------------------
  // Exercises
  // ---------------------------------------------------------------------------

  /// Insert or update a single exercise capture.
  Future<void> saveExercise(ExerciseCapture exercise) async {
    await db.insert(
      'exercises',
      exercise.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get all exercises for a session, ordered by position.
  Future<List<ExerciseCapture>> _getExercisesForSession(
      String sessionId) async {
    final rows = await db.query(
      'exercises',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'position ASC',
    );
    return rows.map((r) => ExerciseCapture.fromMap(r)).toList();
  }

  /// Find all exercises across all sessions that still need conversion.
  /// Used on app restart to re-populate the conversion queue.
  Future<List<ExerciseCapture>> getUnconvertedExercises() async {
    final rows = await db.query(
      'exercises',
      where: 'conversion_status IN (?, ?)',
      whereArgs: [
        ConversionStatus.pending.index,
        ConversionStatus.converting.index,
      ],
      orderBy: 'created_at ASC',
    );
    return rows.map((r) => ExerciseCapture.fromMap(r)).toList();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Best-effort file deletion. Failures are silently ignored — the file
  /// may have been cleaned up by the OS or a previous attempt.
  void _deleteFileIfExists(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {
      // Non-critical — log in production, ignore during POV.
    }
  }

  /// Close the database. Call on app dispose if needed.
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
