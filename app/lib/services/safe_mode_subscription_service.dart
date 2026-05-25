import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'auth_service.dart';

/// Local cache + refresh policy for the Safe Mode subscription gate.
///
/// Spec: docs/sub-agent-briefs/08-safe-mode-subscription-gate.md — "Sub
/// status check must be cached locally to avoid network round-trip on
/// every camera entry; refresh on app launch + every 1 hour while app
/// is foreground."
///
/// Design:
///   * Single ChangeNotifier instance, accessible via [instance].
///   * Initial state is `unknown` — the capture-entry gate may proceed
///     optimistically (we'd rather let a user capture and surface the
///     paywall on the NEXT entry than block a paying user on a fresh
///     app launch). The first refresh runs as soon as auth is ready.
///   * `refresh()` calls `is_in_active_safe_mode_sub(auth.uid())` and
///     stamps the result + the wall-clock fetch time in memory and in
///     SharedPreferences. Survives app kill.
///   * `refreshIfStale()` is the cheap check call sites should use:
///     a no-op if the cached value is < 1 hour old; a real network
///     fetch otherwise. The capture-entry path calls this with `await`
///     so the first launch after kill picks up the answer before the
///     paywall renders, but the network round-trip is skipped if the
///     cache is fresh.
///   * `WidgetsBindingObserver.didChangeAppLifecycleState` triggers a
///     `refreshIfStale()` on every resume; combined with the hourly
///     freshness window this gives "refresh on app launch + every 1
///     hour while foreground" without per-tick polling.
///
/// Failure modes:
///   * Network failure → cached value is left untouched. If never
///     queried, `hasAccess` stays at the optimistic `null` answer.
///   * Auth gap → `currentUserId` is null; service silently no-ops.
///
/// Cache key:
///   `safe_mode_sub_cache_v1::{userId}` → JSON-ish three-field string
///   `"{hasAccess}|{fetchedAtMs}"`. A simple format because the data
///   is two values; no need for jsonEncode overhead.
class SafeModeSubscriptionService extends ChangeNotifier
    with WidgetsBindingObserver {
  SafeModeSubscriptionService._(this._api);

  static SafeModeSubscriptionService? _instance;
  static SafeModeSubscriptionService get instance {
    final svc = _instance;
    if (svc == null) {
      throw StateError(
        'SafeModeSubscriptionService.initialize() must be called before .instance',
      );
    }
    return svc;
  }

  /// One-time wire-up at app launch. Idempotent — repeated calls
  /// reuse the existing instance. Registers the lifecycle observer
  /// so the foreground-resume hook can refresh the cache.
  static void initialize(ApiClient api) {
    if (_instance != null) return;
    final svc = SafeModeSubscriptionService._(api);
    WidgetsBinding.instance.addObserver(svc);
    _instance = svc;
  }

  /// Cached freshness window. After this many seconds the cache is
  /// "stale" and the next `refreshIfStale()` will hit the network.
  /// Aligned with the brief's "every 1 hour while app is foreground".
  static const Duration kCacheFreshness = Duration(hours: 1);

  /// SharedPreferences key prefix. The full key is per-user so a
  /// quick account switch doesn't leak the previous user's answer.
  static const String _kPrefsKeyPrefix = 'safe_mode_sub_cache_v1::';

  final ApiClient _api;

  /// In-memory cached gate value.
  ///   null  → never queried this session (and no persisted answer).
  ///   true  → the user has active sub / trial / grandfathered access.
  ///   false → the user does NOT have access.
  bool? _hasAccess;

  /// Wall-clock instant the cached value was fetched. Null when
  /// [_hasAccess] is null. Used to compute freshness for
  /// [refreshIfStale].
  DateTime? _fetchedAt;

  /// Cached user id the [_hasAccess] / [_fetchedAt] were fetched
  /// against. Used to invalidate the cache on user change.
  String? _cachedUserId;

  /// True iff an inflight refresh is currently running. Prevents
  /// hammering the RPC from multiple concurrent gate checks.
  bool _refreshing = false;

  /// The cached gate answer. `null` means "unknown" — capture-entry
  /// callers should treat this as optimistic-allow (the paywall would
  /// otherwise appear on every cold launch before the first RPC).
  bool? get hasAccess => _hasAccess;

  /// Wall-clock moment the cache was last populated. Null when
  /// `hasAccess` is null. UI surfaces (subscription chip on the
  /// banner) can show "last checked …s ago" if needed.
  DateTime? get fetchedAt => _fetchedAt;

  /// True if the cache is older than [kCacheFreshness] (or has never
  /// been populated). False if the cache is fresh.
  bool get isStale {
    if (_fetchedAt == null) return true;
    return DateTime.now().difference(_fetchedAt!) > kCacheFreshness;
  }

  /// Capture-entry gate decision. Returns the cached value if fresh;
  /// otherwise fires a refresh + waits up to [networkTimeout] for the
  /// answer. On timeout or network failure, returns the previous
  /// cached value (or null if none) — fail-open for paying users.
  ///
  /// Callers should `await` this on the camera-open hot path.
  Future<bool?> readForCapture({
    Duration networkTimeout = const Duration(seconds: 3),
  }) async {
    final currentUid = AuthService.instance.currentUserId;
    if (currentUid == null) return null;

    // User switched since last fetch — invalidate.
    if (_cachedUserId != null && _cachedUserId != currentUid) {
      _hasAccess = null;
      _fetchedAt = null;
      _cachedUserId = null;
    }

    if (!isStale && _hasAccess != null) {
      return _hasAccess;
    }

    // Cache miss or stale — hydrate from prefs first.
    if (_hasAccess == null) {
      await _hydrateFromPrefs(currentUid);
    }

    // Fresh after prefs hydrate? Use it.
    if (!isStale && _hasAccess != null) {
      return _hasAccess;
    }

    // Network refresh; bounded so the camera UI doesn't hang.
    try {
      await refresh().timeout(networkTimeout);
    } on TimeoutException {
      debugPrint('SafeModeSubscriptionService.readForCapture: timed out');
    }
    return _hasAccess;
  }

  /// Non-blocking refresh trigger — fires a background fetch if the
  /// cache is stale; returns immediately. Safe to call from
  /// `didChangeDependencies` / build paths.
  void refreshIfStale() {
    if (_refreshing) return;
    if (!isStale && _hasAccess != null) return;
    unawaited(refresh());
  }

  /// Force a fresh RPC fetch + persist the result. Notifies listeners
  /// on any state change. Coalesces concurrent calls — a second call
  /// while the first is inflight returns the same Future-completion
  /// (no extra round-trip).
  Future<void> refresh() async {
    if (_refreshing) return;
    final uid = AuthService.instance.currentUserId;
    if (uid == null) {
      _hasAccess = null;
      _fetchedAt = null;
      _cachedUserId = null;
      notifyListeners();
      return;
    }

    _refreshing = true;
    try {
      // Hydrate from prefs first so we don't blow away a persisted
      // value before the network answers.
      if (_cachedUserId != uid) {
        await _hydrateFromPrefs(uid);
      }

      final result = await _api.isInActiveSafeModeSub(userId: uid);
      final now = DateTime.now();
      final changed = _hasAccess != result;
      _hasAccess = result;
      _fetchedAt = now;
      _cachedUserId = uid;

      // Best-effort persist; failure to write prefs must not break
      // the in-memory cache for this session.
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          '$_kPrefsKeyPrefix$uid',
          '$result|${now.millisecondsSinceEpoch}',
        );
      } catch (e) {
        debugPrint('SafeModeSubscriptionService prefs write failed: $e');
      }

      if (changed) notifyListeners();
    } finally {
      _refreshing = false;
    }
  }

  /// Drop the cache entirely (e.g. on sign-out). Removes the
  /// SharedPreferences row too so a different user signing in on the
  /// same device starts clean.
  Future<void> clearForUser(String? userId) async {
    _hasAccess = null;
    _fetchedAt = null;
    _cachedUserId = null;
    notifyListeners();
    if (userId == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_kPrefsKeyPrefix$userId');
    } catch (e) {
      debugPrint('SafeModeSubscriptionService prefs clear failed: $e');
    }
  }

  Future<void> _hydrateFromPrefs(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_kPrefsKeyPrefix$userId');
      if (raw == null || raw.isEmpty) return;
      final parts = raw.split('|');
      if (parts.length != 2) return;
      final access = parts[0] == 'true'
          ? true
          : (parts[0] == 'false' ? false : null);
      final ms = int.tryParse(parts[1]);
      if (access == null || ms == null) return;
      _hasAccess = access;
      _fetchedAt = DateTime.fromMillisecondsSinceEpoch(ms);
      _cachedUserId = userId;
    } catch (e) {
      debugPrint('SafeModeSubscriptionService prefs read failed: $e');
    }
  }

  // --- Lifecycle hooks -------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Refresh on foreground resume, but only if the cache is stale.
    if (state == AppLifecycleState.resumed) {
      refreshIfStale();
    }
  }
}
