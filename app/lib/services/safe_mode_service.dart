import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'api_client.dart';
import 'auth_service.dart';

/// Camera-sticky service that tracks whether the camera surface is
/// operating inside a Safe-Mode-enforcing premises.
///
/// Lifecycle (updated 2026-05-22 — camera-sticky, no longer session-sticky):
///   1. On camera mount, the screen calls [reset] then [checkLocation].
///      [checkLocation] requests `whenInUse` location permission, gets one
///      GPS fix, and asks the server's `find_premises_at` RPC if the
///      point lies inside an enforcing polygon.
///   2. If a match is returned, [isActive] becomes true. If not, a
///      one-shot retry is scheduled 30 seconds later — GPS fixes
///      improve as the device sits still and the practitioner has
///      typically only just walked in.
///   3. On camera dispose, the screen calls [cancelRetry] to stop a
///      pending retry timer. State is NOT cleared on dispose so a
///      manual toggle from Studio survives the Camera ↔ Studio swipe.
///   4. On session end (the camera surface is torn down entirely),
///      [reset] returns to `unchecked`.
///
/// Deactivation hysteresis (2026-05-22):
///   GPS fixes near the polygon edge can drift; a single "no match"
///   reply does NOT immediately drop the active state. Instead, once
///   [SafeModeCheckStatus.active] has been entered, a miss starts a
///   trailing window:
///     * The state stays `active` and [isTrailing] flips to true.
///     * Retries accelerate to [kTrailingRetryInterval] (15s).
///     * After [kDeactivationMissThreshold] consecutive misses (i.e. ~60s
///       of "no match" replies), the state finally transitions to
///       `notInZone`. A single in-zone match anywhere during the trailing
///       window resets the miss counter back to zero.
///   Transient errors (RPC failure, GPS timeout, permission revocation
///   mid-session) explicitly do NOT count toward the miss threshold —
///   only an explicit RPC reply of "no enforcing match" does. This
///   prevents flaky network from triggering a false deactivation.
///
/// Manual override:
///   * [forceActive] flips the service into `active` with a synthetic
///     `premisesName: 'Manual'` (and `premisesId: null`). Used by the
///     Studio "Safe Mode" toggle row so the practitioner can opt in
///     without a GPS match. Cancels any pending retry. Manual mode
///     bypasses the deactivation hysteresis entirely.
///
/// Consumers (one each, no recursion):
///   * Capture UI (banner display via [isActive] / [premisesName]).
///   * Conversion service (passes `safeModeEnabled` to native channel).
///   * Upload service (stamps `safe_mode_active` + `captured_in_premises_id`
///     on every exercise in the published session). `premisesId` is
///     NULL for manual mode — the RPC handles NULL gracefully.
///
/// Singleton because the active session has at most one Safe Mode
/// state, and threading the state through every capture pathway is
/// noisy. `SafeModeService.instance` is set up in `main()`.
class SafeModeService extends ChangeNotifier {
  SafeModeService._(this._api);

  /// Number of CONSECUTIVE no-match replies while already active that
  /// must accumulate before the state actually transitions to
  /// `notInZone`. At [kTrailingRetryInterval] = 15s per retry, this
  /// translates to a ~60s grace window for GPS drift at the polygon
  /// edge before the banner is dropped.
  static const int kDeactivationMissThreshold = 4;

  /// Retry cadence during the trailing window (consecutive misses
  /// observed while still active). Tighter than the normal cadence so
  /// the threshold resolves within ~60s rather than ~2 minutes.
  static const Duration kTrailingRetryInterval = Duration(seconds: 15);

  /// Default retry cadence — used while NOT in the trailing window
  /// (e.g. waiting for the first match after a fresh camera mount).
  static const Duration kNormalRetryInterval = Duration(seconds: 30);

  /// Safe Mode Transparency — Phase B (2026-05-22).
  /// Cadence at which `heartbeat_capture_session` is called while a
  /// live capture session is active. The server filters out sessions
  /// whose last heartbeat is older than 60s, so this gives roughly
  /// 3 chances to land in any one 60s window.
  static const Duration kHeartbeatInterval = Duration(seconds: 20);

  static SafeModeService? _instance;
  static SafeModeService get instance {
    final svc = _instance;
    if (svc == null) {
      throw StateError(
        'SafeModeService.initialize() must be called before .instance',
      );
    }
    return svc;
  }

  /// Wire up the singleton at app launch. Idempotent — repeated calls
  /// reuse the existing instance.
  static void initialize(ApiClient api) {
    _instance ??= SafeModeService._(api);
  }

  final ApiClient _api;

  /// One-shot retry scheduled when the initial check returns anything
  /// other than `active`. Helps when GPS hadn't settled at camera
  /// mount but a fix lands a few seconds later.
  Timer? _retryTimer;

  /// Safe Mode Transparency — Phase B (2026-05-22).
  /// Live-capture-session id returned by `start_capture_session`. Set
  /// the moment Safe Mode goes active; cleared when the session ends.
  /// Survives the Camera ↔ Studio swipe so swiping back doesn't open
  /// a fresh row in active_capture_sessions.
  String? _liveSessionId;

  /// 20s heartbeat ticker. Only runs while [_liveSessionId] is set.
  Timer? _heartbeatTimer;

  /// Last GPS fix seen during a heartbeat tick — used as the position
  /// payload on each beat. Updated by [checkLocation] whenever a fresh
  /// fix lands. Falls back to the most recent [_lastLatitude] /
  /// [_lastLongitude] when unset.
  ///
  /// Public read so the live-page integration tests can sanity-check
  /// the position lineage; never expected to be set directly.
  String? get liveSessionId => _liveSessionId;

  /// True iff the active surface is inside an enforcing premises OR a
  /// manual toggle has been engaged.
  bool get isActive => _state.isActive;

  /// True iff [forceActive] is the reason we're active. UI can show a
  /// different sub-line ("Manual" vs the premises name) when needed.
  bool get isManual => _state.isManual;

  /// The premises id stamped on every exercise captured in this
  /// session for the `exercises.captured_in_premises_id` audit column.
  /// Null in manual mode (the RPC's S-H3 validation NULL-strips
  /// unknown ids — manual mode reuses that safely).
  String? get premisesId => _state.premisesId;

  /// Display name of the enforcing premises (shown in the capture
  /// banner / toast). Defaults to "this venue" when missing.
  String get premisesName =>
      _state.premisesName?.isNotEmpty == true
          ? _state.premisesName!
          : 'this venue';

  /// Latest check status — useful for showing the "checking…" spinner
  /// or the "permission denied" fallback in the capture screen.
  SafeModeCheckStatus get status => _state.status;

  /// True iff at least one consecutive miss has been observed while
  /// still in the active state, but the threshold has not yet been
  /// reached. Manual mode never enters the trailing window.
  ///
  /// The banner uses this to swap its sub-line to a "Leaving …"
  /// countdown so the practitioner sees that the banner is about to
  /// drop.
  bool get isTrailing =>
      _consecutiveMissesWhileActive > 0
          && _state.isActive
          && !_state.isManual;

  /// Approximate seconds remaining in the trailing window. Zero if
  /// not currently trailing. Decreases from
  /// [kDeactivationMissThreshold] × [kTrailingRetryInterval] toward 0
  /// across the window and clamps so it never goes negative.
  ///
  /// This is a wall-clock estimate, not the precise time-to-next-RPC —
  /// the banner uses it for a per-second visible countdown so the
  /// number feels alive.
  int get remainingTrailingSeconds {
    if (!isTrailing || _trailingStartedAt == null) return 0;
    final elapsed = DateTime.now().difference(_trailingStartedAt!).inSeconds;
    final total =
        kDeactivationMissThreshold * kTrailingRetryInterval.inSeconds;
    return (total - elapsed).clamp(0, total).toInt();
  }

  /// Diagnostic fields (added 2026-05-22 to debug the "banner-not-rendering
  /// despite being inside the polygon" report). Populated by [checkLocation]
  /// right before the state transition. Cleared on [reset]. These are NOT
  /// part of the service's contract — UI consumers should treat them as
  /// best-effort breadcrumbs for the HUD overlay, not load-bearing data.
  ///
  /// `lastLatitude` / `lastLongitude` — the GPS fix the RPC was asked
  /// about, or null if no fix has landed since reset.
  /// `lastMatchEnforced` — whether the most recent RPC response carried
  /// `safe_mode_enforced=true`. Null if the RPC has not run since reset,
  /// returned no match (point outside every polygon), or failed.
  /// `lastMatchName` — display name of the most recent polygon match,
  /// or null if no match.
  double? get lastLatitude => _lastLatitude;
  double? get lastLongitude => _lastLongitude;
  bool? get lastMatchEnforced => _lastMatchEnforced;
  String? get lastMatchName => _lastMatchName;

  double? _lastLatitude;
  double? _lastLongitude;
  bool? _lastMatchEnforced;
  String? _lastMatchName;

  /// Safe Mode Transparency — Phase A (2026-05-22).
  /// Snapshot of the most recent six-point gate result. Set by
  /// [refreshProfileGate]. When non-null and not-ok, callers should
  /// route the practitioner to the gate screen INSTEAD of any
  /// auto-enabled banner — Safe Mode cannot engage until the missing
  /// items are filled in.
  ///
  /// `null` means "never checked" — treat as permissive (don't block).
  /// Empty `missing` list with `ok = true` means cleared.
  SafeModeGateResult? _gate;

  /// Practice id this gate result was fetched against. Cleared on
  /// [reset]. Used to invalidate stale gate snapshots when the active
  /// practice changes.
  String? _gatePracticeId;

  /// Latest cached gate snapshot. Null = not yet queried; consumers
  /// treat null as "unknown, allow optimistic operation". Non-null
  /// + `!ok` = the six-point gate failed and Safe Mode must NOT
  /// engage (auto or manual) until [missingGateItems] is empty.
  SafeModeGateResult? get gate => _gate;

  /// Practice id the cached gate result corresponds to. UI should
  /// re-query [refreshProfileGate] whenever the active practice
  /// changes.
  String? get gatePracticeId => _gatePracticeId;

  /// True iff the cached gate snapshot says the practitioner is
  /// blocked from Safe Mode for the active practice. False when
  /// the gate has not been queried OR when it explicitly cleared.
  bool get isProfileBlocked => _gate?.ok == false;

  /// Stable identifier strings naming the missing gate items, or
  /// empty if the gate has not been queried / is clear.
  List<String> get missingGateItems =>
      _gate?.missing ?? const <String>[];

  /// Consecutive `no-enforcing-match` RPC replies observed while the
  /// service is still in the active state. Resets to 0 on any clean
  /// match or on a hard transition to `notInZone`. Transient errors
  /// (RPC failure, GPS timeout, etc.) do NOT increment this counter.
  int _consecutiveMissesWhileActive = 0;

  /// Wall-clock moment when the trailing window opened (the first
  /// miss while still active). Null when not trailing.
  DateTime? _trailingStartedAt;

  _SafeModeState _state = const _SafeModeState.unchecked();

  /// One-shot query: get a GPS fix, ask the server which (if any)
  /// premises contains it.
  ///
  /// Pass [skipIfChecked] = true to honour camera-sticky semantics —
  /// once a surface has its answer (active OR explicitly not active),
  /// the caller can decide whether to re-query. Default is `false` so
  /// explicit caller intent is required to skip.
  ///
  /// When the check returns anything other than `active`, a retry is
  /// scheduled — at [kTrailingRetryInterval] if we're inside the
  /// deactivation hysteresis window, otherwise [kNormalRetryInterval].
  ///
  /// Manual mode (set via [forceActive]) is preserved — [checkLocation]
  /// no-ops while manual is engaged. Call [reset] first if you need
  /// the auto-check to override manual.
  ///
  /// Failure modes are NOT errors — they're outcomes:
  ///   - permission denied / restricted → Safe Mode stays off, banner
  ///     shows nothing (silent — practitioner doesn't need to know).
  ///   - location unavailable / timed out → Safe Mode stays off
  ///     UNLESS we were already active; in that case the trailing
  ///     window does not progress (transient error, not a miss).
  ///   - point lies outside every enforcing polygon → counts as a
  ///     miss; the hysteresis window decides whether to deactivate.
  ///   - point lies inside ≥1 enforcing polygon → Safe Mode on,
  ///     state stamped with the smallest matching premises, miss
  ///     counter reset to zero.
  Future<void> checkLocation({bool skipIfChecked = false}) async {
    // Don't override an explicit manual toggle.
    if (_state.isManual) {
      return;
    }
    if (skipIfChecked && _state.status != SafeModeCheckStatus.unchecked) {
      return;
    }

    final wasActive = _state.status == SafeModeCheckStatus.active;

    // Only emit the transient `checking` state when we're NOT already
    // active. Flipping an active state to `checking` would drop the
    // banner mid-check — exactly the kind of flicker the hysteresis
    // contract forbids.
    if (!wasActive) {
      _setState(const _SafeModeState.checking());
    }

    final hasService = await Geolocator.isLocationServiceEnabled();
    if (!hasService) {
      _handleTransientError(wasActive);
      return;
    }

    // Request `whenInUse` — never escalate to `always`.
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied
        || permission == LocationPermission.deniedForever) {
      // Permission revocation is a hard transition (it won't fix
      // itself) — drop state immediately even if we were active.
      _consecutiveMissesWhileActive = 0;
      _trailingStartedAt = null;
      _setState(const _SafeModeState.unavailable());
      cancelRetry();
      return;
    }

    Position position;
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 8),
        ),
      );
    } catch (e) {
      debugPrint('SafeModeService.getCurrentPosition failed: $e');
      _lastLatitude = null;
      _lastLongitude = null;
      _lastMatchEnforced = null;
      _lastMatchName = null;
      _handleTransientError(wasActive);
      return;
    }

    // Stamp diagnostic breadcrumbs BEFORE the RPC so a slow/failing RPC
    // still leaves a fix visible in the HUD.
    _lastLatitude = position.latitude;
    _lastLongitude = position.longitude;

    // NOTE: `ApiClient.findPremisesAt` already catches its own
    // exceptions and returns null. That means at this layer we cannot
    // distinguish a transient RPC failure from a clean "no enforcing
    // match" reply — both arrive as `null`. We treat both as a miss;
    // the only transient-error paths the hysteresis explicitly
    // excludes are GPS-fix failures and location-service-off, which
    // are detected BEFORE we ever call the RPC.
    final SafeModeMatch? match = await _api.findPremisesAt(
      latitude: position.latitude,
      longitude: position.longitude,
    );
    _lastMatchEnforced = match?.safeModeEnforced;
    _lastMatchName = match?.premisesName;

    final isMatch = match != null && match.safeModeEnforced;

    if (isMatch) {
      // Clean match — reset the miss counter, end any trailing window,
      // schedule no further retry.
      _consecutiveMissesWhileActive = 0;
      _trailingStartedAt = null;
      // Safe Mode Transparency Phase A: if the profile gate is failed,
      // we still know we're in the polygon but cannot engage Safe Mode.
      // Surface as `blocked` so the camera UI shows the identity-gate
      // screen instead of the regular banner.
      if (isProfileBlocked) {
        _setState(const _SafeModeState.blocked());
      } else {
        _setState(_SafeModeState.active(
          premisesId: match.premisesId,
          premisesName: match.premisesName,
        ));
      }
      cancelRetry();
      return;
    }

    // No-match RPC reply. Branch on prior state.
    if (wasActive) {
      _consecutiveMissesWhileActive += 1;
      _trailingStartedAt ??= DateTime.now();

      if (_consecutiveMissesWhileActive < kDeactivationMissThreshold) {
        // Still inside the hysteresis window — keep the banner up,
        // notify listeners so the trailing sub-line / countdown
        // re-renders, schedule the aggressive retry.
        _setState(_state, forceNotify: true);
        _scheduleRetry(interval: kTrailingRetryInterval);
        return;
      }

      // Threshold hit — actually transition out.
      _consecutiveMissesWhileActive = 0;
      _trailingStartedAt = null;
      _setState(const _SafeModeState.notInZone());
      _scheduleRetry(interval: kNormalRetryInterval);
      return;
    }

    // Fresh miss while not already active — normal cadence.
    _consecutiveMissesWhileActive = 0;
    _trailingStartedAt = null;
    _setState(const _SafeModeState.notInZone());
    _scheduleRetry(interval: kNormalRetryInterval);
  }

  /// Handle outcomes that are NEITHER a clean match NOR an explicit
  /// no-match RPC reply. Examples: location services off, GPS timed
  /// out. (RPC failures arrive as null from [ApiClient.findPremisesAt]
  /// and are indistinguishable from "no match" at this layer — see
  /// the note in [checkLocation].) The contract here is "do not
  /// progress the trailing window" — transient errors must not
  /// falsely deactivate.
  ///
  /// If we were already active, we keep the active state visible
  /// (banner stays up) and schedule a retry at whichever cadence
  /// matches the trailing window (aggressive if already mid-trail,
  /// normal otherwise). If we were not already active, we land on
  /// `unavailable` so the HUD reflects the failure mode.
  void _handleTransientError(bool wasActive) {
    if (wasActive) {
      // Don't increment misses; don't move state. Notify so the HUD
      // can rerender with the failure breadcrumbs, then keep retrying
      // at whichever cadence applies.
      _setState(_state, forceNotify: true);
      final interval = _consecutiveMissesWhileActive > 0
          ? kTrailingRetryInterval
          : kNormalRetryInterval;
      _scheduleRetry(interval: interval);
      return;
    }
    _setState(const _SafeModeState.unavailable());
    _scheduleRetry(interval: kNormalRetryInterval);
  }

  /// Manually engage Safe Mode. Used by the Studio "Safe Mode" toggle
  /// row when a practitioner wants the bystander pass without a GPS
  /// match (e.g. capturing in a busy public space that isn't
  /// registered as a premises).
  ///
  /// Cancels any pending retry timer and stamps the state with
  /// `premisesId: null` (audit row will show NULL for
  /// `captured_in_premises_id` — the RPC's S-H3 validation handles
  /// NULL gracefully) + the supplied display label. Resets the
  /// deactivation hysteresis counters so a subsequent Auto switch
  /// starts clean.
  ///
  /// Safe Mode Transparency Phase A: when the cached profile gate
  /// says the practitioner is blocked, [forceActive] transitions to
  /// [SafeModeCheckStatus.blocked] instead of `manual`. The camera
  /// surface watches for that status and shows the identity-gate
  /// screen, preventing manual capture in any space until the
  /// missing items are filled in.
  void forceActive({String premisesName = 'Manual'}) {
    cancelRetry();
    _consecutiveMissesWhileActive = 0;
    _trailingStartedAt = null;
    if (isProfileBlocked) {
      _setState(const _SafeModeState.blocked());
      return;
    }
    _setState(_SafeModeState.manual(premisesName: premisesName));
  }

  /// Safe Mode Transparency — Phase A (2026-05-22).
  /// Query the six-point identity gate for the supplied (trainer,
  /// practice) pair and cache the result. Callers should run this
  /// from any surface that may engage Safe Mode — typically the
  /// camera screen on mount + whenever the active practice changes.
  ///
  /// Returns the cached snapshot; null on RPC failure. A null result
  /// is permissive (don't block) because we don't want a flaky
  /// network to suppress Safe Mode for a fully compliant trainer.
  ///
  /// When the gate returns `ok = false` AND the current state is
  /// `active` or `manual`, the state transitions to `blocked` so
  /// the camera UI swaps to the gate screen on the next frame.
  Future<SafeModeGateResult?> refreshProfileGate({
    required String trainerId,
    required String practiceId,
  }) async {
    final result = await _api.canUseSafeMode(
      trainerId: trainerId,
      practiceId: practiceId,
    );
    _gate = result;
    _gatePracticeId = practiceId;

    if (result != null && !result.ok) {
      // Force-transition out of any optimistic active/manual state.
      // We don't touch `notInZone` or `unavailable` — the gate is a
      // SEPARATE concern from "are you geographically inside a
      // polygon"; a not-in-zone trainer with a missing avatar is
      // still not-in-zone, and the camera surface can suppress the
      // banner uniformly when isProfileBlocked is true.
      if (_state.status == SafeModeCheckStatus.active
          || _state.status == SafeModeCheckStatus.manual) {
        cancelRetry();
        _consecutiveMissesWhileActive = 0;
        _trailingStartedAt = null;
        _setState(const _SafeModeState.blocked());
      } else {
        // Notify so UI consumers that only watch isProfileBlocked /
        // missingGateItems can re-render even if the status enum
        // didn't change.
        _setState(_state, forceNotify: true);
      }
    } else if (result != null && result.ok) {
      // Gate just cleared. If we're currently in the `blocked` state
      // (left over from a previous run), drop back to `unchecked` so
      // the next checkLocation can re-evaluate cleanly.
      if (_state.status == SafeModeCheckStatus.blocked) {
        _setState(const _SafeModeState.unchecked());
      } else {
        _setState(_state, forceNotify: true);
      }
    }

    return result;
  }

  /// Clear the state. Called when a surface tears down completely so
  /// the next mount starts from `unchecked` and re-queries.
  void reset() {
    cancelRetry();
    _lastLatitude = null;
    _lastLongitude = null;
    _lastMatchEnforced = null;
    _lastMatchName = null;
    _consecutiveMissesWhileActive = 0;
    _trailingStartedAt = null;
    _gate = null;
    _gatePracticeId = null;
    // _setState transitions out of active → triggers _closeLiveSession
    // automatically. No need to call it directly here.
    _setState(const _SafeModeState.unchecked());
  }

  /// Cancel any pending retry. Called from camera dispose so the timer
  /// doesn't fire after the screen is gone.
  void cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _scheduleRetry({Duration interval = kNormalRetryInterval}) {
    cancelRetry();
    _retryTimer = Timer(interval, () {
      _retryTimer = null;
      // No await — fire-and-forget. checkLocation handles its own
      // state transitions.
      checkLocation(skipIfChecked: false);
    });
  }

  void _setState(_SafeModeState next, {bool forceNotify = false}) {
    final identical = _state == next;
    final wasActive = _state.isActive;
    _state = next;
    final nowActive = next.isActive;
    if (!identical) {
      if (!wasActive && nowActive) {
        // Transitioning INTO an active state — open a live capture
        // session + start the heartbeat ticker. Fire-and-forget; the
        // session id lands a few hundred ms later, no need to block UI.
        unawaited(_openLiveSession());
      } else if (wasActive && !nowActive) {
        // Transitioning OUT — close the row + cancel the ticker.
        unawaited(_closeLiveSession());
      }
    }
    if (!identical || forceNotify) {
      notifyListeners();
    }
  }

  /// Safe Mode Transparency — Phase B (2026-05-22).
  /// Open a live capture session for the current trainer + practice.
  /// Idempotent — if one is already open, this is a no-op so a
  /// re-entrant transition (e.g. notifyListeners in flight) doesn't
  /// duplicate the DB row.
  Future<void> _openLiveSession() async {
    if (_liveSessionId != null) return;
    final practiceId = AuthService.instance.currentPracticeId.value;
    if (practiceId == null) {
      debugPrint('SafeModeService: cannot open live session — no practice');
      return;
    }
    try {
      final id = await _api.startCaptureSession(
        practiceId: practiceId,
        premisesId: _state.premisesId,
        latitude: _lastLatitude,
        longitude: _lastLongitude,
        manual: _state.isManual,
      );
      if (id == null) return;
      _liveSessionId = id;
      _startHeartbeatTimer();
    } catch (e) {
      debugPrint('SafeModeService._openLiveSession failed: $e');
    }
  }

  /// Stamp ended_at on the live session row + cancel the ticker.
  Future<void> _closeLiveSession() async {
    final id = _liveSessionId;
    _liveSessionId = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    if (id == null) return;
    try {
      await _api.endCaptureSession(sessionId: id);
    } catch (e) {
      debugPrint('SafeModeService._closeLiveSession failed: $e');
    }
  }

  void _startHeartbeatTimer() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(kHeartbeatInterval, (_) {
      final id = _liveSessionId;
      if (id == null) return;
      unawaited(_api.heartbeatCaptureSession(
        sessionId: id,
        latitude: _lastLatitude,
        longitude: _lastLongitude,
      ));
    });
  }

  @override
  void dispose() {
    cancelRetry();
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    final id = _liveSessionId;
    _liveSessionId = null;
    if (id != null) {
      unawaited(_api.endCaptureSession(sessionId: id));
    }
    super.dispose();
  }
}

enum SafeModeCheckStatus {
  /// Initial state. Hasn't asked the OS / server yet.
  unchecked,

  /// In-flight RPC. The banner can show a spinner during this window
  /// if it wants to.
  checking,

  /// Either: location services off, permission denied, GPS timed out,
  /// or geolocation simply not available (simulator without location
  /// faking). Safe Mode stays off; capture proceeds normally.
  unavailable,

  /// Got a fix, asked the server, point did not fall inside any
  /// enforcing polygon. Safe Mode stays off.
  notInZone,

  /// Got a fix, server returned an enforcing premises. Safe Mode is
  /// on for the surface (camera-sticky).
  active,

  /// Practitioner explicitly engaged Safe Mode from Studio settings.
  /// `premisesId` is null; audit stamps NULL on `captured_in_premises_id`.
  manual,

  /// Safe Mode Transparency — Phase A (2026-05-22).
  /// The six-point identity gate failed. `missingGateItems` lists the
  /// stable identifier strings the camera surface maps to UI copy
  /// + a deep link into Settings (practitioner-level gaps) or the
  /// portal (practice-level gaps).
  blocked,
}

@immutable
class _SafeModeState {
  final SafeModeCheckStatus status;
  final String? premisesId;
  final String? premisesName;

  const _SafeModeState._({
    required this.status,
    this.premisesId,
    this.premisesName,
  });

  const _SafeModeState.unchecked() : this._(status: SafeModeCheckStatus.unchecked);
  const _SafeModeState.checking() : this._(status: SafeModeCheckStatus.checking);
  const _SafeModeState.unavailable() : this._(status: SafeModeCheckStatus.unavailable);
  const _SafeModeState.notInZone() : this._(status: SafeModeCheckStatus.notInZone);
  const _SafeModeState.active({
    required String premisesId,
    required String premisesName,
  }) : this._(
          status: SafeModeCheckStatus.active,
          premisesId: premisesId,
          premisesName: premisesName,
        );
  const _SafeModeState.manual({required String premisesName})
      : this._(
          status: SafeModeCheckStatus.manual,
          premisesId: null,
          premisesName: premisesName,
        );
  const _SafeModeState.blocked()
      : this._(status: SafeModeCheckStatus.blocked);

  bool get isActive =>
      status == SafeModeCheckStatus.active
          || status == SafeModeCheckStatus.manual;
  bool get isManual => status == SafeModeCheckStatus.manual;

  @override
  bool operator ==(Object other) =>
      identical(this, other)
      || (other is _SafeModeState
          && other.status == status
          && other.premisesId == premisesId
          && other.premisesName == premisesName);

  @override
  int get hashCode => Object.hash(status, premisesId, premisesName);
}
