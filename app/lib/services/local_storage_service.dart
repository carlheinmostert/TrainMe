import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../config.dart';
import '../models/exercise_capture.dart';
import '../models/session.dart';
import 'auth_service.dart';
import 'path_resolver.dart';

/// SQLite-backed local persistence for sessions and exercises.
///
/// All captures and session state are saved to disk immediately so that
/// a crash or app kill loses nothing. On restart, the app restores from
/// this database and re-queues any unconverted captures.
class LocalStorageService {
  static const _dbName = 'raidme.db';
  static const _dbVersion = 15;

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
        circuit_cycles TEXT,
        preferred_rest_interval INTEGER,
        version INTEGER NOT NULL DEFAULT 0,
        last_published_at INTEGER,
        last_publish_error TEXT,
        publish_attempt_count INTEGER NOT NULL DEFAULT 0,
        created_by_user_id TEXT
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
        custom_duration INTEGER,
        video_duration_ms INTEGER,
        archive_file_path TEXT,
        archived_at INTEGER,
        raw_archive_uploaded_at INTEGER,
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
    if (oldVersion < 7) {
      await db.execute(
        'ALTER TABLE sessions ADD COLUMN preferred_rest_interval INTEGER',
      );
    }
    if (oldVersion < 8) {
      await db.execute(
        'ALTER TABLE exercises ADD COLUMN custom_duration INTEGER',
      );
    }
    if (oldVersion < 9) {
      // Convert absolute file paths to relative (relative to Documents dir).
      // This makes the database survive app reinstalls where the container
      // ID changes on iOS.
      final docsDir = PathResolver.docsDir;
      final prefix = '$docsDir/';

      // Update raw_file_path
      await db.rawUpdate(
        "UPDATE exercises SET raw_file_path = REPLACE(raw_file_path, ?, '') "
        "WHERE raw_file_path LIKE ?",
        [prefix, '$prefix%'],
      );
      // Update converted_file_path
      await db.rawUpdate(
        "UPDATE exercises SET converted_file_path = REPLACE(converted_file_path, ?, '') "
        "WHERE converted_file_path LIKE ?",
        [prefix, '$prefix%'],
      );
      // Update thumbnail_path
      await db.rawUpdate(
        "UPDATE exercises SET thumbnail_path = REPLACE(thumbnail_path, ?, '') "
        "WHERE thumbnail_path LIKE ?",
        [prefix, '$prefix%'],
      );
    }
    if (oldVersion < 10) {
      await db.execute(
        'ALTER TABLE sessions ADD COLUMN version INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE sessions ADD COLUMN last_published_at INTEGER',
      );
    }
    if (oldVersion < 11) {
      // Publish tracking columns. Consumed by upload_service.dart.
      // last_published_at already added in v10 migration above.
      await db.execute(
        'ALTER TABLE sessions ADD COLUMN last_publish_error TEXT',
      );
      await db.execute(
        'ALTER TABLE sessions ADD COLUMN publish_attempt_count INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 12) {
      // Per-exercise video duration in ms. Used so estimatedDurationSeconds
      // can treat one rep = one video length for video exercises instead of
      // the hardcoded 3s default.
      await db.execute(
        'ALTER TABLE exercises ADD COLUMN video_duration_ms INTEGER',
      );
    }
    if (oldVersion < 13) {
      // Local raw-video archive: every captured video gets compressed to a
      // 720p H.264 copy in {Documents}/archive/, tracked here so we can
      // re-run better line-drawing filters against the original footage
      // later, and ultimately upload to a private Supabase bucket once auth
      // lands. Archives older than 90 days are purged on startup.
      await db.execute(
        'ALTER TABLE exercises ADD COLUMN archive_file_path TEXT',
      );
      await db.execute(
        'ALTER TABLE exercises ADD COLUMN archived_at INTEGER',
      );
    }
    if (oldVersion < 14) {
      // Per-user session scoping. Sessions created under account A must
      // not leak into account B's Home list when they sign in on the same
      // device. Tag every session row with the Supabase auth uid of the
      // practitioner who created it.
      //
      // Column stays NULL for:
      //   - rows that existed before v14 — claimed on first Home load by
      //     the currently signed-in user (see [claimOrphanSessions]).
      //   - rows drafted while signed out (edge case; AuthGate normally
      //     blocks the Home screen pre-auth).
      //
      // The migration is naturally idempotent: sqflite only runs it when
      // crossing the v13 → v14 boundary, and the inline backfill below
      // only touches rows where `created_by_user_id IS NULL`, so a
      // re-launch after a successful upgrade is a no-op.
      await db.execute(
        'ALTER TABLE sessions ADD COLUMN created_by_user_id TEXT',
      );

      // Best-effort inline backfill. If Supabase has already restored a
      // session by the time this runs (it's initialized before
      // LocalStorageService.init in main.dart), claim every pre-v14
      // session for the current user. If no user is signed in yet, leave
      // the rows NULL and let [claimOrphanSessions] pick them up on the
      // first signed-in Home load.
      final uid = AuthService.instance.currentUserId;
      if (uid != null) {
        await db.update(
          'sessions',
          {'created_by_user_id': uid},
          where: 'created_by_user_id IS NULL',
        );
      }
    }
    if (oldVersion < 15) {
      // Three-treatment video model — track successful cloud uploads of the
      // raw archive (720p H.264 compressed). Set to `DateTime.now()` epoch ms
      // once the corresponding object lands in the private `raw-archive`
      // Supabase bucket. Allows the publish flow to skip already-uploaded
      // exercises on re-publish, so network flakes don't re-transfer large
      // video blobs.
      await db.execute(
        'ALTER TABLE exercises ADD COLUMN raw_archive_uploaded_at INTEGER',
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

  /// All sessions that are not soft-deleted, newest first.
  /// Published sessions remain active so the trainer can update and
  /// re-publish them.
  ///
  /// This is the un-scoped variant — returns every active row regardless of
  /// which practitioner created it. The Home screen calls
  /// [getSessionsForUser] instead so sessions stay scoped to the signed-in
  /// account.
  Future<List<Session>> getActiveSessions() async {
    final rows = await db.query(
      'sessions',
      where: 'deleted_at IS NULL',
      orderBy: 'created_at DESC',
    );
    return _hydrateSessionsWithExercises(rows);
  }

  /// Active sessions scoped to a practitioner's Supabase auth uid.
  ///
  /// When [userId] is non-null, returns rows whose `created_by_user_id`
  /// matches OR is NULL. Orphan rows (NULL) are rows that existed before the
  /// v14 migration ran, or were drafted while signed out; they appear in the
  /// current user's list until [claimOrphanSessions] permanently tags them.
  ///
  /// When [userId] is null (nobody signed in — shouldn't normally happen,
  /// AuthGate blocks Home pre-auth), falls back to [getActiveSessions] so
  /// any pre-auth UI paths keep working.
  Future<List<Session>> getSessionsForUser(String? userId) async {
    if (userId == null) return getActiveSessions();
    final rows = await db.query(
      'sessions',
      where:
          'deleted_at IS NULL AND (created_by_user_id = ? OR created_by_user_id IS NULL)',
      whereArgs: [userId],
      orderBy: 'created_at DESC',
    );
    return _hydrateSessionsWithExercises(rows);
  }

  /// Tag every orphan session (`created_by_user_id IS NULL`) with [userId].
  ///
  /// Called by the Home screen on load so pre-v14 rows and sessions drafted
  /// while signed out get permanently attached to the first signed-in user
  /// who sees them. Subsequent account switches on the same device will
  /// then see only their own sessions — no cross-account leakage.
  ///
  /// Returns the number of rows updated. Safe to call on every load — a
  /// no-op once the orphans have been claimed.
  Future<int> claimOrphanSessions(String userId) async {
    return db.update(
      'sessions',
      {'created_by_user_id': userId},
      where: 'created_by_user_id IS NULL',
    );
  }

  /// Delete a session and all its exercises. Also removes associated media
  /// files from disk.
  Future<void> deleteSession(String id) async {
    // Gather file paths before deleting rows — resolve to absolute for disk I/O
    final exercises = await _getExercisesForSession(id);
    for (final ex in exercises) {
      _deleteFileIfExists(PathResolver.resolve(ex.rawFilePath));
      if (ex.convertedFilePath != null) {
        _deleteFileIfExists(PathResolver.resolve(ex.convertedFilePath!));
      }
      if (ex.thumbnailPath != null) {
        _deleteFileIfExists(PathResolver.resolve(ex.thumbnailPath!));
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
    return _hydrateSessionsWithExercises(rows);
  }

  /// Fetch exercises for every session id in a single query, then bucket them
  /// back into their owning session. Replaces the prior N+1 pattern that
  /// queried exercises once per session.
  Future<List<Session>> _hydrateSessionsWithExercises(
      List<Map<String, Object?>> sessionRows) async {
    if (sessionRows.isEmpty) return const [];

    final sessionIds =
        sessionRows.map((r) => r['id'] as String).toList(growable: false);
    final placeholders = List.filled(sessionIds.length, '?').join(',');

    final exerciseRows = await db.query(
      'exercises',
      where: 'session_id IN ($placeholders)',
      whereArgs: sessionIds,
      orderBy: 'session_id, position ASC',
    );

    // Bucket exercises by session_id.
    final bySession = <String, List<ExerciseCapture>>{
      for (final id in sessionIds) id: <ExerciseCapture>[],
    };
    for (final row in exerciseRows) {
      final sid = row['session_id'] as String;
      (bySession[sid] ??= <ExerciseCapture>[]).add(ExerciseCapture.fromMap(row));
    }

    return sessionRows
        .map((row) => Session.fromMap(
              row,
              exercises: bySession[row['id'] as String] ?? const [],
            ))
        .toList(growable: false);
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

  /// Delete archived raw-video copies older than [retention] (default 90
  /// days) and clear the corresponding columns on the exercise rows. Called
  /// fire-and-forget on app startup to keep `{Documents}/archive/` bounded.
  ///
  /// The exercise rows themselves are preserved — only [archiveFilePath] and
  /// [archivedAt] are nulled out. Returns the number of archives purged.
  Future<int> purgeOldArchives({
    Duration retention = const Duration(days: 90),
  }) async {
    final cutoff = DateTime.now().subtract(retention).millisecondsSinceEpoch;

    final rows = await db.query(
      'exercises',
      columns: ['id', 'archive_file_path'],
      where: 'archive_file_path IS NOT NULL AND archived_at < ?',
      whereArgs: [cutoff],
    );

    if (rows.isEmpty) return 0;

    final purgedIds = <String>[];
    for (final row in rows) {
      final relPath = row['archive_file_path'] as String?;
      if (relPath == null || relPath.isEmpty) continue;
      try {
        final file = File(PathResolver.resolve(relPath));
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // Best-effort — if we can't delete the file, still clear the row
        // so we don't keep retrying on every startup.
      }
      purgedIds.add(row['id'] as String);
    }

    if (purgedIds.isEmpty) return 0;

    final placeholders = List.filled(purgedIds.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE exercises '
      'SET archive_file_path = NULL, archived_at = NULL '
      'WHERE id IN ($placeholders)',
      purgedIds,
    );
    return purgedIds.length;
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

  /// Batch insert or update multiple exercises in a single transaction.
  /// Far cheaper than calling [saveExercise] in a loop — ~10-100x faster
  /// for large batches because a single fsync amortises the cost.
  Future<void> saveExercises(Iterable<ExerciseCapture> exercises) async {
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final ex in exercises) {
        batch.insert(
          'exercises',
          ex.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
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
      _deleteFileIfExists(PathResolver.resolve(ex.rawFilePath));
      if (ex.convertedFilePath != null) {
        _deleteFileIfExists(PathResolver.resolve(ex.convertedFilePath!));
      }
      if (ex.thumbnailPath != null) {
        _deleteFileIfExists(PathResolver.resolve(ex.thumbnailPath!));
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
