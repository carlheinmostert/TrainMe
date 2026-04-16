import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../config.dart';
import '../models/exercise_capture.dart';
import '../models/session.dart';

/// SQLite-backed local persistence for sessions and exercises.
///
/// All captures and session state are saved to disk immediately so that
/// a crash or app kill loses nothing. On restart, the app restores from
/// this database and re-queues any unconverted captures.
class LocalStorageService {
  static const _dbName = 'raidme.db';
  static const _dbVersion = 6;

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
        plan_url TEXT,
        deleted_at INTEGER,
        circuit_cycles TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE exercises (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        raw_file_path TEXT NOT NULL,
        converted_file_path TEXT,
        thumbnail_path TEXT,
        media_type INTEGER NOT NULL,
        conversion_status INTEGER NOT NULL DEFAULT 0,
        reps INTEGER,
        sets INTEGER,
        hold_seconds INTEGER,
        notes TEXT,
        name TEXT,
        created_at INTEGER NOT NULL,
        circuit_id TEXT,
        include_audio INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
      )
    ''');

    // Index for the most common query: "get exercises for a session, in order"
    await db.execute('''
      CREATE INDEX idx_exercises_session
      ON exercises(session_id, position)
    ''');
  }

  /// Schema migrations for database upgrades.
  Future<void> _migrateTables(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE sessions ADD COLUMN deleted_at INTEGER');
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE exercises ADD COLUMN thumbnail_path TEXT');
    }
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE exercises ADD COLUMN circuit_id TEXT');
      await db.execute('ALTER TABLE sessions ADD COLUMN circuit_cycles TEXT');
    }
    if (oldVersion < 5) {
      await db.execute('ALTER TABLE exercises ADD COLUMN name TEXT');
    }
    if (oldVersion < 6) {
      await db.execute(
        'ALTER TABLE exercises ADD COLUMN include_audio INTEGER NOT NULL DEFAULT 0',
      );
    }
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

  /// All sessions that haven't been sent yet and are not soft-deleted,
  /// newest first. These are the bio's "in-progress" sessions.
  Future<List<Session>> getActiveSessions() async {
    final rows = await db.query(
      'sessions',
      where: 'sent_at IS NULL AND deleted_at IS NULL',
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
      if (ex.thumbnailPath != null) {
        _deleteFileIfExists(ex.thumbnailPath!);
      }
    }

    await db.delete('exercises', where: 'session_id = ?', whereArgs: [id]);
    await db.delete('sessions', where: 'id = ?', whereArgs: [id]);
  }

  /// Soft-delete a session by setting its deleted_at timestamp.
  /// The session remains in the database and can be restored.
  Future<void> softDeleteSession(String id) async {
    await db.update(
      'sessions',
      {'deleted_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Restore a soft-deleted session by clearing its deleted_at timestamp.
  Future<void> restoreSession(String id) async {
    await db.update(
      'sessions',
      {'deleted_at': null},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Return all soft-deleted sessions, newest deletion first.
  Future<List<Session>> getDeletedSessions() async {
    final rows = await db.query(
      'sessions',
      where: 'deleted_at IS NOT NULL',
      orderBy: 'deleted_at DESC',
    );

    final sessions = <Session>[];
    for (final row in rows) {
      final exercises = await _getExercisesForSession(row['id'] as String);
      sessions.add(Session.fromMap(row, exercises: exercises));
    }
    return sessions;
  }

  /// Permanently delete sessions that were soft-deleted more than
  /// [retentionDays] ago. Called on app startup to keep the recycle bin tidy.
  Future<void> purgeExpiredSessions({
    int retentionDays = AppConfig.recycleBinRetentionDays,
  }) async {
    final cutoff = DateTime.now()
        .subtract(Duration(days: retentionDays))
        .millisecondsSinceEpoch;

    // Find expired sessions so we can clean up their media files
    final rows = await db.query(
      'sessions',
      columns: ['id'],
      where: 'deleted_at IS NOT NULL AND deleted_at < ?',
      whereArgs: [cutoff],
    );

    for (final row in rows) {
      final id = row['id'] as String;
      await deleteSession(id);
    }
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

  /// Delete a single exercise by ID. Also removes its media files from disk.
  Future<void> deleteExercise(String exerciseId) async {
    final rows = await db.query(
      'exercises',
      where: 'id = ?',
      whereArgs: [exerciseId],
    );
    if (rows.isNotEmpty) {
      final ex = ExerciseCapture.fromMap(rows.first);
      _deleteFileIfExists(ex.rawFilePath);
      if (ex.convertedFilePath != null) {
        _deleteFileIfExists(ex.convertedFilePath!);
      }
      if (ex.thumbnailPath != null) {
        _deleteFileIfExists(ex.thumbnailPath!);
      }
    }
    await db.delete('exercises', where: 'id = ?', whereArgs: [exerciseId]);
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
