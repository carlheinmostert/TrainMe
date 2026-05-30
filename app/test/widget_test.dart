// Smoke-level widget tests for the two highest-risk user flows, per
// issue #579. Replaces the prior `expect(1 + 1, 2)` placeholder.
//
// Both tests drive the REAL [ClientSessionsScreen] — the mobile twin of
// the portal's `/clients/[id]` page and the per-client drill-in from the
// Clients-as-Home spine. We seed an in-memory SQLite database through the
// production [LocalStorageService.openForTest] seam (sqflite_common_ffi),
// exactly as the existing regression suite does (see
// `capture_defaults_test.dart`, `studio_delete_rollback_test.dart`), so
// the screen reads its data the same way it does in production.
//
// Hermeticity notes:
//   * No user is signed in. `AuthService.instance.currentUserId` returns
//     null, so [LocalStorageService.getSessionsForUser] falls through to
//     [getActiveSessions] (pure SQLite, no network).
//   * Seeded sessions are UNPUBLISHED (version 0, no plan URL). The
//     screen's analytics + artifact-status fetches are gated on
//     `session.isPublished`, so neither fires — no Supabase RPC is hit.
//   * The seeded client has `consentExplicitlySetAt` set, so the
//     auto-open consent sheet (which would call ApiClient) stays closed.
//   * The seeded client has no `avatarPath`, so ClientAvatarGlyph renders
//     the initials monogram instead of fetching a signed URL.
//
// Supabase is initialised with a dummy local URL so the lazy
// `Supabase.instance.client` accessor (reached via `Session.create`'s
// AuthService read and the unauthenticated `currentUserId` getter) does
// not throw. No network connection is made — the client only connects on
// an actual RPC/auth call, none of which the unauthenticated + unpublished
// paths exercised here trigger.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// Hide gotrue's `Session` (re-exported by supabase_flutter) so the app's
// own `raidme/models/session.dart` `Session` resolves unambiguously below.
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import 'package:raidme/models/cached_client.dart';
import 'package:raidme/models/client.dart';
import 'package:raidme/models/session.dart';
import 'package:raidme/screens/client_sessions_screen.dart';
import 'package:raidme/services/local_storage_service.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    // Supabase persists its session via SharedPreferences; seed an empty
    // store so initialize() doesn't reach the platform channel.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // Dummy local config — the client is lazy and only connects on an
    // actual RPC/auth call, which the unauthenticated + unpublished paths
    // under test never make.
    await Supabase.initialize(
      url: 'http://localhost:54321',
      anonKey: 'test-anon-key',
    );
  });

  /// A client whose consent has been explicitly set (so the consent sheet
  /// does not auto-open) and which has no avatar (so the avatar glyph
  /// renders initials, not a signed-URL image).
  PracticeClient seededClient({
    String id = 'client-1',
    String practiceId = 'practice-1',
    String name = 'Jordan Vance',
  }) {
    return PracticeClient(
      id: id,
      practiceId: practiceId,
      name: name,
      consentExplicitlySetAt: DateTime(2026, 5, 1).millisecondsSinceEpoch,
    );
  }

  Future<LocalStorageService> openSeededStorage() async {
    final storage = await LocalStorageService.openForTest(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    return storage;
  }

  Future<void> pumpClientScreen(
    WidgetTester tester, {
    required LocalStorageService storage,
    required PracticeClient client,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ClientSessionsScreen(client: client, storage: storage),
      ),
    );
    // Drive frames until the async _loadSessions() resolves and the
    // loading spinner clears. We can't use pumpAndSettle() here: while
    // _loading is true the screen shows a CircularProgressIndicator,
    // whose rotation is an indefinite animation that never settles, so
    // pumpAndSettle spins until the 10-minute test timeout. Pump a
    // bounded number of explicit frames instead — _loadSessions only
    // awaits in-memory SQLite reads (no user signed in → no network),
    // so it resolves within a couple of microtask turns; 30 × 100 ms is
    // generous head-room.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }
  }

  testWidgets(
    'client screen loads and renders a seeded session row from the '
    'in-memory LocalStorageService',
    (tester) async {
      final storage = await openSeededStorage();
      addTearDown(storage.close);

      final client = seededClient();
      // Mirror the cache the Home screen would have populated.
      await storage.upsertCachedClient(
        CachedClient(
          id: client.id,
          practiceId: client.practiceId,
          name: client.name,
          consentExplicitlySetAt: client.consentExplicitlySetAt,
        ),
      );

      // Seed one UNPUBLISHED session bound to the client. A recognisable
      // title lets us assert it rendered in the session card. Orphan
      // (created_by_user_id NULL) so it surfaces for the signed-out
      // getActiveSessions() read path.
      const sessionTitle = 'Knee rehab · 19 Apr 2026';
      await storage.saveSession(
        Session(
          id: 'session-1',
          clientName: client.name,
          clientId: client.id,
          title: sessionTitle,
          createdAt: DateTime(2026, 4, 19, 17, 9),
        ),
      );

      await pumpClientScreen(tester, storage: storage, client: client);

      // The client identity (AppBar avatar + name) renders.
      expect(find.text(client.name), findsWidgets);
      // The seeded session row renders its title.
      expect(find.text(sessionTitle), findsOneWidget);
      // The empty-state copy must NOT be present when a session exists.
      expect(find.textContaining('No sessions for'), findsNothing);
    },
  );

  testWidgets(
    'New Session affordance is present and tappable on the client screen',
    (tester) async {
      final storage = await openSeededStorage();
      addTearDown(storage.close);

      final client = seededClient(name: 'Sam Okoro');
      await storage.upsertCachedClient(
        CachedClient(
          id: client.id,
          practiceId: client.practiceId,
          name: client.name,
          consentExplicitlySetAt: client.consentExplicitlySetAt,
        ),
      );

      await pumpClientScreen(tester, storage: storage, client: client);

      // The empty client shows the "No sessions" prompt steering the
      // practitioner to the New Session CTA.
      expect(find.textContaining('No sessions for Sam Okoro'), findsOneWidget);

      // The "New Session" CTA (a FilledButton) is present and enabled
      // (tappable). We assert the affordance rather than driving the tap
      // end-to-end, because the tap pushes the heavy, native-coupled
      // SessionShellScreen which is out of scope for a hermetic smoke
      // test (per the issue's stated minimum). A non-null onPressed is
      // the real, load-bearing signal that the affordance is wired to
      // _startNewSession.
      final newSessionButton = find.widgetWithText(FilledButton, 'New Session');
      expect(newSessionButton, findsOneWidget);
      final button = tester.widget<FilledButton>(newSessionButton);
      expect(
        button.onPressed,
        isNotNull,
        reason: 'New Session button must be tappable',
      );

      // The seeded client begins with zero sessions — sanity-check the
      // storage seam the screen reads from agrees.
      final sessions = await storage.getActiveSessions();
      expect(sessions, isEmpty);
    },
  );
}
