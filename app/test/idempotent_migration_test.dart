// Idempotent ADD COLUMN regression — see PR landing this test.
//
// Bug: Carl's TestFlight v1 install (1.0.0+1, build SHA f6f7bce) hit
// a fatal `DatabaseException: duplicate column name: hero_crop_offset`
// on the v37 → v38 migration. A prior `studio.homefit.app` dev install
// had left a `Documents/raidme.db` behind whose user_version was < 38
// but where the `hero_crop_offset` column was already present. The
// raw `ALTER TABLE … ADD COLUMN` in the v38 branch crashed; the app
// is unbootable past splash.
//
// Fix: route every ADD COLUMN through `_addColumnIfMissing`, which
// reads `PRAGMA table_info` and only issues the ADD when the column
// isn't already there. The migration result is identical for healthy
// DBs; the half-state case now no-ops the redundant ADD and lets the
// version bump to 38 land cleanly.
//
// This test simulates the half-state by:
//   1. Opening the DB at v37 (older schema, no `hero_crop_offset`).
//   2. Manually `ALTER TABLE exercises ADD COLUMN hero_crop_offset REAL`
//      to mirror what the broken on-disk DB looked like.
//   3. Closing + reopening at v38 so onUpgrade fires.
// The reopen MUST succeed (used to throw "duplicate column name").

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:raidme/services/local_storage_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('LocalStorageService — idempotent ADD COLUMN', () {
    test(
      'reopen at v38 survives a pre-existing hero_crop_offset column',
      () async {
        // Need a stable named in-memory DB so the v37 → v38 reopen
        // actually triggers the migration. The `:memory:` URI in
        // sqflite_ffi maps to a per-handle DB, so we can't share it
        // across open/close cycles — use SQLite's shared-cache idiom.
        const dbPath =
            'file:idempotent_migration_test?mode=memory&cache=shared';
        final factory = databaseFactoryFfi;

        // Step 1 — create the DB at v37 with an `exercises` table that
        // does NOT yet have `hero_crop_offset`. We only need the table
        // shape to be plausible; subsequent migrations from v37 → v38
        // touch the v38 branch alone, which only ALTERs the
        // `hero_crop_offset` column on `exercises`. Other tables /
        // columns are immaterial.
        var db = await factory.openDatabase(
          dbPath,
          options: OpenDatabaseOptions(
            version: 37,
            onCreate: (db, _) async {
              await db.execute('''
                CREATE TABLE exercises (
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL,
                  position INTEGER NOT NULL,
                  raw_file_path TEXT NOT NULL,
                  media_type INTEGER NOT NULL,
                  created_at INTEGER NOT NULL
                )
              ''');
            },
          ),
        );

        // Step 2 — simulate the half-state: column already exists on
        // disk but user_version is still 37. This is what Carl's
        // upgrade-over-dev-install DB looked like.
        await db.execute(
          'ALTER TABLE exercises ADD COLUMN hero_crop_offset REAL',
        );
        await db.close();

        // Step 3 — reopen via the production service at the current
        // _dbVersion (v38). Without the idempotent helper this throws
        // `DatabaseException: duplicate column name: hero_crop_offset`.
        // With the helper, the v38 branch sees the column already
        // present and no-ops the ADD; user_version stamps to 38.
        final svc = await LocalStorageService.openForTest(
          path: dbPath,
          factory: factory,
        );

        // Sanity: the column is still there.
        final info = await svc.db.rawQuery('PRAGMA table_info(exercises)');
        final hasHeroCropOffset = info.any(
          (row) => row['name'] == 'hero_crop_offset',
        );
        expect(
          hasHeroCropOffset,
          isTrue,
          reason: 'hero_crop_offset must remain present after the migration '
              'no-ops the redundant ADD',
        );

        // Sanity: user_version landed at the current schema version.
        final version = await svc.db.rawQuery('PRAGMA user_version');
        expect(version.first['user_version'], 39);

        await svc.close();
      },
    );

    test(
      'fresh open at current version succeeds (no half-state regression)',
      () async {
        // Smoke: a clean open via the production factory at v38 still
        // works. Guards against an accidental break of the helper that
        // would only surface on upgraded installs.
        final svc = await LocalStorageService.openForTest(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        final version = await svc.db.rawQuery('PRAGMA user_version');
        expect(version.first['user_version'], 39);

        // Spot-check a few of the columns the v3+ migration branches
        // touch — they must all be present after _createTables.
        final info = await svc.db.rawQuery('PRAGMA table_info(exercises)');
        final names = info.map((row) => row['name']).toSet();
        expect(names, contains('thumbnail_path'));
        expect(names, contains('circuit_id'));
        expect(names, contains('hero_crop_offset'));
        expect(names, contains('focus_frame_offset_ms'));
        expect(names, contains('body_focus'));

        await svc.close();
      },
    );
  });
}
