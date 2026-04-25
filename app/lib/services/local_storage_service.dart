import 'dart:io';
import 'package:flutter/foundation.dart';
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
  static const _dbVersion = 29;

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

  /// Test-only factory — opens the DB at a caller-supplied path with the
  /// same onCreate hook as production. Used by the regression suite
  /// under `app/test/` to spin up an in-memory SQLite instance (via
  /// `sqflite_common_ffi`) without dragging path_provider into the test
  /// harness.
  @visibleForTesting
  static Future<LocalStorageService> openForTest({
    required String path,
    required DatabaseFactory factory,
  }) async {
    final svc = LocalStorageService();
    svc._db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _dbVersion,
        onCreate: svc._createTables,
        onUpgrade: svc._migrateTables,
      ),
    );
    return svc;
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
        last_content_edit_at INTEGER,
        last_publish_error TEXT,
        publish_attempt_count INTEGER NOT NULL DEFAULT 0,
        created_by_user_id TEXT,
        client_id TEXT,
        crossfade_lead_ms INTEGER,
        crossfade_fade_ms INTEGER,
        unlock_credit_prepaid_at INTEGER
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
        segmented_raw_file_path TEXT,
        mask_file_path TEXT,
        inter_set_rest_seconds INTEGER,
        start_offset_ms INTEGER,
        end_offset_ms INTEGER,
        video_reps_per_loop INTEGER,
        aspect_ratio REAL,
        rotation_quarters INTEGER,
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
        client_exercise_defaults TEXT NOT NULL DEFAULT '{}',
        consent_confirmed_at INTEGER,
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
    if (oldVersion < 20) {
      // Three-state publish indicator (Q1 polish batch).
      //
      // Track the most recent content edit so the session card can
      // distinguish "published & clean" from "published with pending
      // changes". Stamped by StudioModeScreen on every structural /
      // content mutation (reps, sets, hold, notes, name, add / delete /
      // reorder, circuit change, treatment, prep, muted, custom duration,
      // session title). Pure-UI state (scroll, expand/collapse) does NOT
      // stamp this.
      //
      // Legacy rows migrate as NULL — the card treats null as "clean"
      // so historic sessions don't all light up as dirty on upgrade.
      await db.execute(
        'ALTER TABLE sessions ADD COLUMN last_content_edit_at INTEGER',
      );
    }
    if (oldVersion < 21) {
      // Sticky per-client exercise defaults (Milestone R / Wave 8).
      //
      // JSON string (sqlite has no native jsonb), decoded at read time
      // by CachedClient.fromMap. Holds the practitioner's most-recent
      // edit of the seven sticky fields — reps, sets, hold_seconds,
      // include_audio, preferred_treatment, prep_seconds,
      // custom_duration_seconds. Forward-only: next new capture for
      // this client pre-fills from this map; overriding a field writes
      // back the new value.
      //
      // Existing rows default to '{}' — the first capture after upgrade
      // simply uses StudioDefaults (no previous sticky values to apply).
      //
      // Supabase has a matching column in
      // schema_milestone_r_sticky_defaults.sql; the cloud stores jsonb,
      // we mirror as a serialised TEXT on the SQLite side. Writes go
      // through the pending-op queue via `set_client_exercise_default`.
      await db.execute(
        "ALTER TABLE cached_clients ADD COLUMN client_exercise_defaults TEXT NOT NULL DEFAULT '{}'",
      );
    }
    if (oldVersion < 22) {
      // Dual-output segmented-color raw variant (Option 1-augment).
      //
      // The native AVAssetReader/Writer pass now produces TWO outputs
      // from a single Vision person-segmentation pass: the classic
      // line drawing (unchanged) AND a segmented-color mp4 that reuses
      // the same mask to pop the body through pristine while dimming
      // the background via the v7 backgroundDim LUT. The new file is
      // written alongside the line drawing, stored as a relative path
      // here, and best-effort uploaded to the private `raw-archive`
      // bucket at `{practice_id}/{plan_id}/{exercise_id}.segmented.mp4`
      // by UploadService. The web player's Color + B&W treatments
      // prefer the segmented file via `get_plan_full` and fall back
      // to the untouched original when it's missing (pre-v22 rows +
      // exercises captured before this ships).
      //
      // Nullable — legacy + new-capture-without-segmented both tolerate
      // NULL. No backfill; forward-only.
      await db.execute(
        'ALTER TABLE exercises ADD COLUMN segmented_raw_file_path TEXT',
      );
    }
    if (oldVersion < 23) {
      // Person-segmentation mask sidecar (Milestone P2).
      //
      // The native dual-output pass now emits a THIRD file: the Vision
      // mask itself, written out as a grayscale H.264 mp4. Same resolution
      // + fps as the line-drawing + segmented outputs so the mask is
      // pixel-perfect aligned with both. Stored as a relative path here
      // and best-effort uploaded to the private `raw-archive` bucket at
      // `{practice_id}/{plan_id}/{exercise_id}.mask.mp4` by UploadService.
      //
      // Insurance for future playback-time compositing — today the mask
      // has NO consumer. Storing it now means published plans will have
      // the data when tunable backgroundDim / other effects land, without
      // needing to re-capture.
      //
      // Nullable — legacy + new-capture-without-mask both tolerate NULL
      // (mask writer failure is non-fatal; line-drawing + segmented still
      // succeed). No backfill; forward-only.
      await db.execute(
        'ALTER TABLE exercises ADD COLUMN mask_file_path TEXT',
      );
    }
    if (oldVersion < 24) {
      // Per-exercise inter-set rest "Post Rep Breather" (Milestone Q).
      //
      // Semantics:
      //   * NULL → no breather (legacy rows, pre-migration).
      //   * 0    → practitioner explicitly disabled.
      //   * > 0  → breather seconds between sets on the web player.
      //
      // Fresh captures seed to 15 via
      // ExerciseCapture.withPersistenceDefaults() (the same helper that
      // stamps sets=3 / reps=10). Existing rows stay NULL — no backfill
      // per the brief, so pre-Q captures simply play without inter-set
      // rest on the web player.
      //
      // Supabase has a matching column in
      // schema_milestone_q_inter_set_rest.sql — the mobile column stays
      // in lockstep so publish + sync can round-trip the field without
      // any translation.
      await db.execute(
        'ALTER TABLE exercises ADD COLUMN inter_set_rest_seconds INTEGER',
      );
    }
    if (oldVersion < 25) {
      // Per-exercise soft-trim window (Wave 20 / Milestone X).
      //
      // Semantics:
      //   * Both NULL → no trim, full clip plays. Pre-feature behaviour
      //     for every existing row.
      //   * Both set → playback (mobile preview AND web player) clamps
      //     `currentTime` to [start, end] and loops within that window.
      //
      // The same trim applies across all three treatments (Line / B&W /
      // Original) since they share source timing. NO re-conversion — the
      // underlying media file stays full-length; trim is purely a
      // playback metadata pair.
      //
      // Supabase has matching columns in schema_milestone_x_soft_trim.sql;
      // round-trip via the wire encoding on `replace_plan_exercises`.
      await db.execute(
        'ALTER TABLE exercises ADD COLUMN start_offset_ms INTEGER',
      );
      await db.execute(
        'ALTER TABLE exercises ADD COLUMN end_offset_ms INTEGER',
      );
    }
    if (oldVersion < 26) {
      // Wave 24 — number of repetitions captured in the source video.
      //
      // Semantics:
      //   * NULL → legacy / pre-migration row. Player treats as 1 rep
      //     per loop (preserves pre-Wave-24 playback math).
      //   * INT > 0 → practitioner-set or persistence-default count.
      //     Fresh mobile captures seed 3 via
      //     ExerciseCapture.withPersistenceDefaults().
      //
      // Drives per-rep / per-set time on both mobile preview and the
      // web player:
      //   per_rep = video_duration_ms/1000 / video_reps_per_loop
      //   per_set = target_reps × per_rep
      //
      // Replaces the manual `custom_duration_seconds` override in the
      // UI; the DB column lives on for backwards-compatible reads.
      // Supabase mirror: schema_wave24_video_reps_per_loop.sql.
      await db.execute(
        'ALTER TABLE exercises ADD COLUMN video_reps_per_loop INTEGER',
      );
    }
    if (oldVersion < 27) {
      // Wave 27 — per-plan dual-video crossfade timing.
      //
      // Both nullable; NULL means "use the surface default" (lead 250 ms,
      // fade 200 ms). The _MediaViewer tuner writes through here; on
      // publish the values land on `plans.crossfade_lead_ms` /
      // `crossfade_fade_ms` and flow back to the web player via
      // `to_jsonb(plan_row)` in `get_plan_full`.
      await db.execute(
        'ALTER TABLE sessions ADD COLUMN crossfade_lead_ms INTEGER',
      );
      await db.execute(
        'ALTER TABLE sessions ADD COLUMN crossfade_fade_ms INTEGER',
      );
    }
    if (oldVersion < 28) {
      // Wave 28 — landscape orientation metadata.
      //
      //   * aspect_ratio (REAL) — effective playback aspect after any
      //     practitioner rotation. NULL = consumer derives at first
      //     paint (legacy / pre-migration).
      //   * rotation_quarters (INTEGER) — practitioner rotation in 90°
      //     clockwise quarters (0/1/2/3). NULL treated as 0.
      //
      // Both flow through `replace_plan_exercises` on publish and back
      // through `get_plan_full` to the web player. Supabase mirror:
      // schema_wave28_landscape_metadata.sql.
      await db.execute(
        'ALTER TABLE exercises ADD COLUMN aspect_ratio REAL',
      );
      await db.execute(
        'ALTER TABLE exercises ADD COLUMN rotation_quarters INTEGER',
      );
    }
    if (oldVersion < 29) {
      // Wave 29 — explicit unlock-for-edit + consent confirmation gate.
      //
      //   * sessions.unlock_credit_prepaid_at (INTEGER, epoch-ms) —
      //     stamped when the practitioner pre-pays a credit on a
      //     post-lock plan. consume_credit reads + clears it on the next
      //     publish so the republish is free.
      //
      //   * cached_clients.consent_confirmed_at (INTEGER, epoch-ms) —
      //     mirror of the cloud column. Publish gates on non-NULL so a
      //     fresh client always surfaces the consent sheet first.
      //
      // Supabase mirror: schema_wave29_unlock_plan.sql.
      await db.execute(
        'ALTER TABLE sessions ADD COLUMN unlock_credit_prepaid_at INTEGER',
      );
      await db.execute(
        'ALTER TABLE cached_clients ADD COLUMN consent_confirmed_at INTEGER',
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
  ///
  /// Wave 18 — also stamps the parent session's [Session.lastContentEditAt]
  /// inside the same transaction WHEN any persisted user-content field
  /// actually changed. This closes a class of bugs where a write path
  /// (camera-mode capture, media-viewer mute toggle, treatment pref)
  /// updated the exercise row but never touched the session timestamp,
  /// leaving [Session.hasUnpublishedContentChanges] false and the Studio
  /// publish indicator stuck on "Published" even though the plan was
  /// dirty. See `StudioModeScreen._touchAndPush` for the original
  /// Studio-side stamp — both paths exist belt-and-braces.
  ///
  /// Critically, pure conversion-progress updates
  /// ([ExerciseCapture.conversionStatus], [convertedFilePath],
  /// [thumbnailPath], [videoDurationMs], [archiveFilePath], [archivedAt],
  /// [rawArchiveUploadedAt]) are NOT user edits and MUST NOT dirty the
  /// session; the line-drawing pipeline writes these many times per
  /// capture and every one of those would re-open the publish-locked
  /// window. The field-delta check below enumerates exactly which
  /// columns count as user content.
  Future<void> saveExercise(ExerciseCapture exercise) async {
    await db.transaction((txn) async {
      final existingRows = await txn.query(
        'exercises',
        where: 'id = ?',
        whereArgs: [exercise.id],
        limit: 1,
      );
      final existing = existingRows.isEmpty
          ? null
          : ExerciseCapture.fromMap(existingRows.first);

      // Option 1 (2026-04-22 player-grammar discussion) — on the FIRST
      // insert of an exercise row, backfill sets=3 / reps=10 for
      // practitioners who captured without explicitly touching those
      // fields. Scoped to brand-new rows only: existing null columns on
      // pre-existing rows stay null (no retroactive backfill). See
      // [ExerciseCapture.withPersistenceDefaults] for the isometric +
      // rest-row exceptions.
      final toPersist = existing == null
          ? exercise.withPersistenceDefaults()
          : exercise;

      await txn.insert(
        'exercises',
        toPersist.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      // Brand-new row (e.g. a fresh Camera capture) counts as a user
      // content edit — even without a prior row to compare against, the
      // act of adding an exercise must flag the session dirty. Existing
      // rows only flip the stamp when a content-shaped field actually
      // changed; conversion-status churn alone is a no-op.
      final contentChanged =
          existing == null || _isUserContentDelta(existing, toPersist);
      final sessionId = toPersist.sessionId;
      if (contentChanged && sessionId != null && sessionId.isNotEmpty) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        await txn.update(
          'sessions',
          {'last_content_edit_at': nowMs},
          where: 'id = ?',
          whereArgs: [sessionId],
        );
      }
    });
  }

  /// Returns true when [next] differs from [prev] in any field that the
  /// practitioner would recognise as a user-authored edit to plan content.
  ///
  /// Included: name, position, reps, sets, holdSeconds, mediaType,
  /// customDurationSeconds, prepSeconds, includeAudio, preferredTreatment,
  /// notes, circuitId.
  ///
  /// Excluded (deliberately): conversionStatus, convertedFilePath,
  /// thumbnailPath, videoDurationMs, archiveFilePath, archivedAt,
  /// rawArchiveUploadedAt, rawFilePath. These are pipeline byproducts
  /// and fire many times during conversion; treating them as edits
  /// would perma-dirty every session mid-capture.
  static bool _isUserContentDelta(
    ExerciseCapture prev,
    ExerciseCapture next,
  ) {
    if (prev.name != next.name) return true;
    if (prev.position != next.position) return true;
    if (prev.reps != next.reps) return true;
    if (prev.sets != next.sets) return true;
    if (prev.holdSeconds != next.holdSeconds) return true;
    if (prev.mediaType != next.mediaType) return true;
    if (prev.customDurationSeconds != next.customDurationSeconds) {
      return true;
    }
    if (prev.prepSeconds != next.prepSeconds) return true;
    if (prev.interSetRestSeconds != next.interSetRestSeconds) return true;
    if (prev.includeAudio != next.includeAudio) return true;
    if (prev.preferredTreatment != next.preferredTreatment) return true;
    if ((prev.notes ?? '') != (next.notes ?? '')) return true;
    if (prev.circuitId != next.circuitId) return true;
    // Wave 24 — changing the number of reps captured in the source
    // video is a semantic content edit; it shifts the per-rep / per-set
    // playback math on both surfaces.
    if (prev.videoRepsPerLoop != next.videoRepsPerLoop) return true;
    // Wave 28 — practitioner rotation flips playback orientation on
    // both surfaces. Aspect-ratio writes that accompany a rotation are
    // covered by the same delta. The first capture-time aspect-ratio
    // write (no prior row) already counts as a fresh insert and dirties
    // the session via the `existing == null` branch in `saveExercise`.
    if (prev.rotationQuarters != next.rotationQuarters) return true;
    if (prev.aspectRatio != next.aspectRatio) return true;
    return false;
  }

  /// Batch insert or update multiple exercises in a single transaction.
  /// Far cheaper than calling [saveExercise] in a loop — ~10-100x faster
  /// for large batches because a single fsync amortises the cost.
  ///
  /// Unlike [saveExercise], the batch path does NOT pre-read each row to
  /// decide whether to apply the Option 1 persistence defaults — callers
  /// should pass exercises already in their desired persisted shape. The
  /// first-ever save of a freshly-captured exercise always goes through
  /// [saveExercise] (capture and camera flows both do so individually);
  /// this batch path is reserved for reorders and other operations that
  /// re-save pre-existing rows.
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

  /// Every cached client name for a practice, INCLUDING soft-deleted
  /// rows (recycle bin). Used by the "New client" default-name picker
  /// so we don't mint a name that collides with a soft-deleted client
  /// — the server-side unique index on `(practice_id, name)` ignores
  /// `deleted_at`, so an auto-picked name that happens to match a
  /// recycle-bin row explodes at publish time.
  Future<Set<String>> getAllCachedClientNamesForPractice(String practiceId) async {
    final rows = await db.query(
      'cached_clients',
      columns: ['name'],
      where: 'practice_id = ?',
      whereArgs: [practiceId],
    );
    return rows.map((r) => r['name'] as String).toSet();
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

  /// Fetch a single cached client by id. Returns null when the row is
  /// missing or tombstoned — callers read this as "no extra consent
  /// signals available, fall back to the line-drawing default".
  ///
  /// Added for Wave 4 Phase 1 (unified player prototype): the in-process
  /// LocalPlayerServer needs per-plan consent flags to build a
  /// shape-identical `get_plan_full` payload out of the local DB.
  Future<CachedClient?> getCachedClientById(String id) async {
    final rows = await db.query(
      'cached_clients',
      where: 'id = ? AND deleted = 0',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return CachedClient.fromMap(rows.first);
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
