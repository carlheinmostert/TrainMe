import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../config.dart';
import '../models/cached_client.dart';
import '../models/cached_practice.dart';
import '../models/exercise_capture.dart';
import '../models/pending_op.dart';
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
  static const _dbVersion = 19;

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
        created_by_user_id TEXT,
        client_id TEXT
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
        preferred_treatment TEXT,
        prep_seconds INTEGER,
        FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
      )
    ''');

    // Index for the most common query: "get exercises for a session, in order"
    await db.execute('''
      CREATE INDEX idx_exercises_session
      ON exercises(session_id, position)
    ''');

    // Offline-first cache tables (schema v17). See docs/CLAUDE.md and
    // the SyncService for how these are populated / drained. Keep the
    // CREATE + ALTER migration paths in lockstep — fresh installs get
    // these directly; upgrading installs run the v17 branch in
    // [_migrateTables].
    await _createOfflineFirstTables(db);
  }

  /// Shared DDL for the v17 cache tables. Called from both
  /// [_createTables] (fresh installs) and [_migrateTables] (existing
  /// installs crossing v16 → v17).
  Future<void> _createOfflineFirstTables(Database db) async {
    // cached_clients — mirror of cloud `clients` + sync metadata.
    //
    // `video_consent` is stored as a JSON string (sqlite has no native
    // jsonb), decoded at read time by CachedClient.fromMap. The UNIQUE
    // constraint on (practice_id, name) mirrors the cloud constraint so
    // an offline-create that collides with an existing local row fails
    // fast (the UI surfaces the duplicate-name error before the sync
    // queue even runs).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cached_clients (
        id TEXT PRIMARY KEY,
        practice_id TEXT NOT NULL,
        name TEXT NOT NULL,
        video_consent TEXT NOT NULL,
        synced_at INTEGER,
        dirty INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0,
        UNIQUE(practice_id, name)
      )
    ''');
    // Index for the most common read: "all clients under this practice".
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_cached_clients_practice
      ON cached_clients(practice_id)
    ''');

    // cached_practices — mirror of cloud practice_members + practice
    // name + joined_at. One row per membership. Pull deletes stale rows
    // so the switcher doesn't list practices the user left.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cached_practices (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        role TEXT NOT NULL,
        joined_at INTEGER NOT NULL,
        synced_at INTEGER NOT NULL
      )
    ''');

    // cached_credit_balance — per-practice last-known balance. One row
    // per practice the user is in. `synced_at` anchors the "last synced
    // X ago" hint in Settings.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cached_credit_balance (
        practice_id TEXT PRIMARY KEY,
        balance INTEGER NOT NULL,
        synced_at INTEGER NOT NULL
      )
    ''');

    // pending_ops — FIFO queue of writes awaiting sync.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_ops (
        id TEXT PRIMARY KEY,
        op_type TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_attempt_at INTEGER,
        last_error TEXT
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_pending_ops_created
      ON pending_ops(created_at)
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
    if (oldVersion < 16) {
      // Clients-as-Home-spine IA shift. Session rows get a nullable
      // `client_id` pointing at `clients.id` in Supabase. New sessions
      // (created via ClientSessionsScreen) populate both client_id and
      // clientName from the chosen client. Legacy rows keep client_id
      // NULL; ClientSessionsScreen filters by (client_id OR clientName)
      // so they still appear under the right client without a backfill.
      await db.execute(
        'ALTER TABLE sessions ADD COLUMN client_id TEXT',
      );
    }
    if (oldVersion < 17) {
      // Offline-first foundation: cache tables + pending-op queue.
      // Creates cached_clients, cached_practices, cached_credit_balance,
      // and pending_ops. All four are safe to add empty — SyncService
      // populates them on the next successful pullAll and no read path
      // breaks if they're empty (callers always fall through to an
      // empty list).
      await _createOfflineFirstTables(db);
    }
    if (oldVersion < 18) {
      // Per-exercise sticky treatment preference (Milestone O).
      //
      // Values: 'line' / 'grayscale' / 'original' / NULL.
      // NULL means "no explicit choice — render as Line" (the de-
      // identifying default); every existing row migrates to NULL, which
      // preserves the pre-feature behaviour (everything renders Line on
      // first open). New writes land via copyWith(preferredTreatment:...)
      // from the media viewer / plan preview / studio card tiles.
      //
      // Supabase has a matching column in
      // schema_milestone_o_exercise_preferred_treatment.sql — the mobile
      // column stays in lockstep so publish + sync can round-trip the
      // field without any translation layer.
      await db.execute(
        'ALTER TABLE exercises ADD COLUMN preferred_treatment TEXT',
      );
    }
    if (oldVersion < 19) {
      // Per-exercise prep-countdown override (Wave 3 / Milestone P).
      //
      // Global default now shrinks from 15s → 5s (see _kPrepSeconds in
      // plan_preview_screen.dart + PREP_SECONDS in web-player/app.js).
      // Practitioners can override per exercise via the Studio card's
      // "Prep seconds" inline field. NULL = use the 5s default.
      //
      // Supabase has a matching column in
      // schema_milestone_p_prep_seconds.sql — publish round-trips via the
      // `prep_seconds` column on the `exercises` table.
      await db.execute(
        'ALTER TABLE exercises ADD COLUMN prep_seconds INTEGER',
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

  /// Backfill `sessions.client_id` from a list of cloud (plan_id, client_id)
  /// pairs. Pre-v16 sessions had no `client_id` column; the v16 migration
  /// added it with a null default and did NOT backfill. Legacy sessions
  /// therefore rely on name-match (`session.clientName == client.name`) to
  /// connect to their client — which breaks the moment the client is
  /// renamed. This method is the one-shot fix: for every (plan_id,
  /// client_id) pair the cloud knows about, find the local session with
  /// that id and stamp its client_id.
  ///
  /// Idempotent — rows whose `client_id` already matches are untouched
  /// (the WHERE clause on the UPDATE filters by null/mismatch). Safe to
  /// call on every Home load; runs are O(N) where N is the number of
  /// pairs passed in.
  ///
  /// Returns the number of session rows actually updated — useful for
  /// diagnostic logs ("synced X legacy sessions to client ids") but
  /// callers can ignore it.
  Future<int> backfillSessionClientIds(
    List<({String planId, String clientId})> pairs,
  ) async {
    if (pairs.isEmpty) return 0;
    var updated = 0;
    for (final link in pairs) {
      final rows = await db.update(
        'sessions',
        {'client_id': link.clientId},
        // Only touch rows that are missing or wrong — skip up-to-date rows.
        where: 'id = ? AND (client_id IS NULL OR client_id != ?)',
        whereArgs: [link.planId, link.clientId],
      );
      updated += rows;
    }
    return updated;
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

  // ---------------------------------------------------------------------------
  // Offline-first — cached_clients
  // ---------------------------------------------------------------------------

  /// All non-deleted cached clients for a practice. Read by HomeScreen
  /// to render the clients list without touching the network. Returns
  /// rows in alphabetical name order (insertion order would leak the
  /// offline-create tail at the bottom, which would be confusing).
  Future<List<CachedClient>> getCachedClientsForPractice(String practiceId) async {
    final rows = await db.query(
      'cached_clients',
      where: 'practice_id = ? AND deleted = 0',
      whereArgs: [practiceId],
      orderBy: 'LOWER(name) ASC',
    );
    return rows.map((r) => CachedClient.fromMap(r)).toList(growable: false);
  }

  /// Upsert a single cached client row. Used by SyncService on both
  /// cloud pulls (`dirty=0`) and local mutations (`dirty=1`).
  Future<void> upsertCachedClient(CachedClient client) async {
    await db.insert(
      'cached_clients',
      client.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Replace every cached client for a practice with [clients]. Used
  /// by the full-refresh pull path: any row not in [clients] is deleted,
  /// so clients removed cloud-side disappear locally too.
  ///
  /// DIRTY rows are preserved — they're mid-sync and haven't been
  /// written to the cloud yet; the pull would incorrectly remove them.
  Future<void> replaceCachedClientsForPractice({
    required String practiceId,
    required Iterable<CachedClient> clients,
  }) async {
    await db.transaction((txn) async {
      // Gather dirty ids under this practice so the DELETE-then-replace
      // doesn't nuke offline-created rows that haven't synced yet.
      final dirtyRows = await txn.query(
        'cached_clients',
        columns: ['id'],
        where: 'practice_id = ? AND dirty = 1',
        whereArgs: [practiceId],
      );
      final dirtyIds = dirtyRows
          .map((r) => r['id'] as String)
          .toSet();

      // Delete all non-dirty rows for this practice. Dirty rows survive
      // and get re-upserted if the cloud has them (otherwise they
      // remain as local-only + will flush on next drain).
      await txn.delete(
        'cached_clients',
        where: 'practice_id = ? AND dirty = 0',
        whereArgs: [practiceId],
      );

      final batch = txn.batch();
      for (final c in clients) {
        if (dirtyIds.contains(c.id)) {
          // Row is mid-sync locally — don't clobber the user's pending
          // edit with the server's stale view. SyncService will flush
          // and then another pull will overwrite cleanly.
          continue;
        }
        batch.insert(
          'cached_clients',
          c.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Delete a cached_clients row outright. Used when SyncService
  /// rewires after a server-side name conflict (the local id loses —
  /// references move to the server-side id, and this one is purged).
  Future<void> deleteCachedClient(String id) async {
    await db.delete('cached_clients', where: 'id = ?', whereArgs: [id]);
  }

  /// Soft-delete a cached client and cascade-tombstone every local
  /// session that belongs to that client (matched via `client_id`, or
  /// falling back to `clientName == client.name` for legacy sessions).
  ///
  /// The tombstone timestamp is returned so the caller (SyncService)
  /// can stash it alongside the pending `delete_client` op. Restoring
  /// uses the same timestamp to match-and-revert the cascaded sessions
  /// — plans soft-deleted earlier at another timestamp stay deleted.
  ///
  /// All writes run in a single SQLite transaction; a restart mid-
  /// operation leaves either the entire cascade in place or none of it.
  /// The cached_clients row is marked `deleted=1` + `dirty=1` so
  /// [replaceCachedClientsForPractice] skips it on the next pull and
  /// the pending op still has something to flush against.
  Future<int> softDeleteClientCascade({
    required String clientId,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'cached_clients',
        where: 'id = ?',
        whereArgs: [clientId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final client = CachedClient.fromMap(rows.first);

      await txn.update(
        'cached_clients',
        <String, Object?>{
          'deleted': 1,
          'dirty': 1,
        },
        where: 'id = ?',
        whereArgs: [clientId],
      );

      // Cascade: every local session whose client_id matches OR whose
      // clientName matches (legacy rows predating Milestone H's
      // backfill) — stamp the SAME nowMs. restoreClientCascade uses
      // equality on this timestamp to undo exactly what we cascaded.
      await txn.rawUpdate(
        'UPDATE sessions '
        'SET deleted_at = ? '
        'WHERE deleted_at IS NULL '
        '  AND (client_id = ? OR (client_id IS NULL AND client_name = ?))',
        [nowMs, clientId, client.name],
      );
    });
    return nowMs;
  }

  /// Reverse a [softDeleteClientCascade]. Clears the `deleted` flag on
  /// the cached_clients row and restores every session whose
  /// `deleted_at` matches [cascadeTimestampMs] exactly. Sessions
  /// soft-deleted at another timestamp (e.g. manual delete before the
  /// client was removed) stay deleted — the "undo what we cascaded"
  /// invariant mirrors the server-side `restore_client` semantics.
  Future<void> restoreClientCascade({
    required String clientId,
    required int cascadeTimestampMs,
  }) async {
    await db.transaction((txn) async {
      await txn.update(
        'cached_clients',
        <String, Object?>{
          'deleted': 0,
          'dirty': 1,
        },
        where: 'id = ?',
        whereArgs: [clientId],
      );

      await txn.rawUpdate(
        'UPDATE sessions SET deleted_at = NULL '
        'WHERE deleted_at = ? '
        '  AND (client_id = ? OR client_id IS NULL AND client_name IN '
        '      (SELECT name FROM cached_clients WHERE id = ?))',
        [cascadeTimestampMs, clientId, clientId],
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Offline-first — cached_practices
  // ---------------------------------------------------------------------------

  /// All cached practice memberships for the current user, ordered by
  /// joined_at ascending so the first practice joined is [0] (matches
  /// the cloud's `listMyPractices` ordering for R-11 parity).
  Future<List<CachedPractice>> getCachedPractices() async {
    final rows = await db.query(
      'cached_practices',
      orderBy: 'joined_at ASC',
    );
    return rows.map((r) => CachedPractice.fromMap(r)).toList(growable: false);
  }

  /// Replace every cached practice with [practices]. Rows the cloud no
  /// longer returns are removed, so the switcher sheet doesn't
  /// surface practices the user left or was removed from.
  Future<void> replaceCachedPractices(Iterable<CachedPractice> practices) async {
    await db.transaction((txn) async {
      await txn.delete('cached_practices');
      final batch = txn.batch();
      for (final pr in practices) {
        batch.insert(
          'cached_practices',
          pr.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  // ---------------------------------------------------------------------------
  // Offline-first — cached_credit_balance
  // ---------------------------------------------------------------------------

  /// Get the last-known credit balance for [practiceId], or null if
  /// the cache is cold for this practice.
  Future<CachedCreditBalance?> getCachedCreditBalance(String practiceId) async {
    final rows = await db.query(
      'cached_credit_balance',
      where: 'practice_id = ?',
      whereArgs: [practiceId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return CachedCreditBalance._fromMap(rows.first);
  }

  /// Upsert the credit balance for [practiceId]. Stamps `synced_at` to
  /// [nowMs] so the UI can render "last synced X ago".
  Future<void> upsertCachedCreditBalance({
    required String practiceId,
    required int balance,
    required int nowMs,
  }) async {
    await db.insert(
      'cached_credit_balance',
      <String, Object?>{
        'practice_id': practiceId,
        'balance': balance,
        'synced_at': nowMs,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ---------------------------------------------------------------------------
  // Offline-first — pending_ops
  // ---------------------------------------------------------------------------

  /// Insert a new pending op. Caller has already constructed the op
  /// via one of [PendingOp]'s factory helpers.
  Future<void> enqueuePendingOp(PendingOp op) async {
    await db.insert(
      'pending_ops',
      op.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// FIFO read of every pending op, oldest first. Used by SyncService
  /// to drain the queue.
  Future<List<PendingOp>> getPendingOps() async {
    final rows = await db.query(
      'pending_ops',
      orderBy: 'created_at ASC',
    );
    return rows.map((r) => PendingOp.fromMap(r)).toList(growable: false);
  }

  /// Count of pending ops. Cheap scalar used for the "N pending" chip
  /// on Home without loading the full queue.
  Future<int> countPendingOps() async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM pending_ops');
    if (rows.isEmpty) return 0;
    final c = rows.first['c'];
    if (c is int) return c;
    if (c is num) return c.toInt();
    return 0;
  }

  /// Delete a pending op after a successful flush.
  Future<void> deletePendingOp(String id) async {
    await db.delete('pending_ops', where: 'id = ?', whereArgs: [id]);
  }

  /// Persist a failed-attempt bump (increment `attempts`, set
  /// `last_attempt_at`, stash `last_error`). Leaves the op in place so
  /// the next flush retries it.
  Future<void> markPendingOpFailed({
    required String id,
    required String error,
    required int nowMs,
  }) async {
    await db.rawUpdate(
      '''
      UPDATE pending_ops
      SET attempts = attempts + 1,
          last_attempt_at = ?,
          last_error = ?
      WHERE id = ?
      ''',
      [nowMs, error, id],
    );
  }

  /// Close the database. Call on app dispose if needed.
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}

/// Row shape returned by [LocalStorageService.getCachedCreditBalance].
/// Kept trivial — just the balance + staleness stamp.
class CachedCreditBalance {
  final int balance;
  final int syncedAt;

  const CachedCreditBalance({required this.balance, required this.syncedAt});

  static CachedCreditBalance _fromMap(Map<String, dynamic> row) {
    return CachedCreditBalance(
      balance: row['balance'] as int,
      syncedAt: row['synced_at'] as int,
    );
  }
}
