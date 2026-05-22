import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';

import 'api_client.dart';

/// App-wide service that tracks whether the practitioner is currently
/// inside a Safe-Mode-enforcing premises polygon. Drives the persistent
/// top-of-app banner (PR #413) across every screen.
///
/// Lifecycle (updated 2026-05-22 — app-wide, no longer camera-bound):
///   1. On app launch, `main()` calls [maybeInitialCheck] right after
///      [initialize]. If location permission is already granted, the
///      service runs one [checkLocation] so the banner is accurate
///      from the first frame. If permission isn't granted yet,
///      [maybeInitialCheck] no-ops — the camera screen is the gating
///      surface that prompts (S-6).
///   2. If [checkLocation] returns anything other than `active`, a
///      one-shot retry is scheduled 30 seconds later. GPS fixes
///      improve as the device sits still and the practitioner has
///      typically only just walked into the venue.
///   3. The retry keeps re-running every 30s while the app is in the
///      foreground and the state is `notInZone` or `unavailable`. The
///      moment state becomes `active` (auto or manual), the retry
///      cancels itself. If the practitioner walks OUT of a polygon
///      again, [checkLocation] will need to be re-triggered manually
///      (the active state is sticky for the surface lifetime).
///   4. App background / paused: the timer is cancelled. App resumed:
///      we re-run [checkLocation] immediately (and schedule another
///      retry if needed).
///   5. Camera mount still calls [reset] + [checkLocation] for the
///      legacy camera-mount semantics — a manual toggle survives the
///      Camera ↔ Studio page swipe because [reset] clears state but
///      the immediate re-check fires before any rendering uses it.
///
/// Manual override:
///   * [forceActive] flips the service into `active` with a synthetic
///     `premisesName: 'Manual'` (and `premisesId: null`). Used by the
///     Studio "Safe Mode" toggle row so the practitioner can opt in
///     without a GPS match. Cancels any pending retry.
///
/// Consumers (one each, no recursion):
///   * Persistent banner (app-wide via [isActive] / [premisesName]).
///   * Capture UI (additional in-viewfinder cues).
///   * Conversion service (passes `safeModeEnabled` to native channel).
///   * Upload service (stamps `safe_mode_active` + `captured_in_premises_id`
///     on every exercise in the published session). `premisesId` is
///     NULL for manual mode — the RPC handles NULL gracefully.
///
/// Battery note: while the app is foreground AND state is not active,
/// the retry runs one GPS fix + one RPC every 30s — ~120/hour. That's
/// acceptable for the bystander-privacy promise (banner must stay
/// accurate as the practitioner moves between rooms / venues). If
/// real-world telemetry shows pressure, revisit with exponential
/// backoff (30s → 1m → 2m → 5m cap).
///
/// Singleton because the active session has at most one Safe Mode
/// state, and threading the state through every capture pathway is
/// noisy. `SafeModeService.instance` is set up in `main()`.
class SafeModeService extends ChangeNotifier with WidgetsBindingObserver {
  SafeModeService._(this._api);

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
  /// reuse the existing instance. On first call we register a
  /// [WidgetsBindingObserver] so the service can pause/resume the retry
  /// timer with app lifecycle (foreground → run, background → cancel).
  static void initialize(ApiClient api) {
    if (_instance != null) return;
    final svc = SafeModeService._(api);
    WidgetsBinding.instance.addObserver(svc);
    _instance = svc;
  }

  final ApiClient _api;

  /// One-shot retry scheduled when the initial check returns anything
  /// other than `active`. Helps when GPS hadn't settled at camera
  /// mount but a fix lands a few seconds later.
  Timer? _retryTimer;

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

  _SafeModeState _state = const _SafeModeState.unchecked();

  /// App-launch convenience: run [checkLocation] iff the OS has already
  /// granted location permission. Never prompts — the camera screen
  /// remains the gating surface for the first-time permission ask
  /// (S-6). Safe to call from `main()` before the first frame is
  /// painted; it's fire-and-forget.
  ///
  /// Rationale: with the persistent banner visible app-wide (PR #413),
  /// the practitioner expects the banner to be accurate from the
  /// moment the app opens — not only after they visit the camera.
  /// Practitioners with prior permission grants get an immediate
  /// check; everyone else gets the existing camera-gated flow.
  Future<void> maybeInitialCheck() async {
    if (_state.isManual) return;
    final hasService = await Geolocator.isLocationServiceEnabled();
    if (!hasService) return;
    final permission = await Geolocator.checkPermission();
    if (permission != LocationPermission.whileInUse
        && permission != LocationPermission.always) {
      // No prompt, no state change — the camera surface owns that.
      return;
    }
    await checkLocation();
  }

  /// One-shot query: get a GPS fix, ask the server which (if any)
  /// premises contains it.
  ///
  /// Pass [skipIfChecked] = true to honour camera-sticky semantics —
  /// once a surface has its answer (active OR explicitly not active),
  /// the caller can decide whether to re-query. Default is `false` so
  /// explicit caller intent is required to skip.
  ///
  /// When the check returns anything other than `active`, a one-shot
  /// retry is scheduled 30s later. The retry passes
  /// `skipIfChecked: false` so it actually re-runs.
  ///
  /// Manual mode (set via [forceActive]) is preserved — [checkLocation]
  /// no-ops while manual is engaged. Call [reset] first if you need
  /// the auto-check to override manual.
  ///
  /// Failure modes are NOT errors — they're outcomes:
  ///   - permission denied / restricted → Safe Mode stays off, banner
  ///     shows nothing (silent — practitioner doesn't need to know).
  ///   - location unavailable / timed out → Safe Mode stays off.
  ///   - point lies outside every enforcing polygon → Safe Mode off.
  ///   - point lies inside ≥1 enforcing polygon → Safe Mode on,
  ///     state stamped with the smallest matching premises.
  Future<void> checkLocation({bool skipIfChecked = false}) async {
    // Don't override an explicit manual toggle.
    if (_state.isManual) {
      return;
    }
    if (skipIfChecked && _state.status != SafeModeCheckStatus.unchecked) {
      return;
    }

    _setState(const _SafeModeState.checking());

    final hasService = await Geolocator.isLocationServiceEnabled();
    if (!hasService) {
      _setState(const _SafeModeState.unavailable());
      _scheduleRetry();
      return;
    }

    // Request `whenInUse` — never escalate to `always`.
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied
        || permission == LocationPermission.deniedForever) {
      _setState(const _SafeModeState.unavailable());
      // No retry — permission won't change by itself.
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
      _setState(const _SafeModeState.unavailable());
      _scheduleRetry();
      return;
    }

    // Stamp diagnostic breadcrumbs BEFORE the RPC so a slow/failing RPC
    // still leaves a fix visible in the HUD.
    _lastLatitude = position.latitude;
    _lastLongitude = position.longitude;

    final match = await _api.findPremisesAt(
      latitude: position.latitude,
      longitude: position.longitude,
    );

    _lastMatchEnforced = match?.safeModeEnforced;
    _lastMatchName = match?.premisesName;

    if (match == null || !match.safeModeEnforced) {
      _setState(const _SafeModeState.notInZone());
      _scheduleRetry();
      return;
    }

    _setState(_SafeModeState.active(
      premisesId: match.premisesId,
      premisesName: match.premisesName,
    ));
    // We're active — no retry needed.
    cancelRetry();
  }

  /// Manually engage Safe Mode. Used by the Studio "Safe Mode" toggle
  /// row when a practitioner wants the bystander pass without a GPS
  /// match (e.g. capturing in a busy public space that isn't
  /// registered as a premises).
  ///
  /// Cancels any pending retry timer and stamps the state with
  /// `premisesId: null` (audit row will show NULL for
  /// `captured_in_premises_id` — the RPC's S-H3 validation handles
  /// NULL gracefully) + the supplied display label.
  void forceActive({String premisesName = 'Manual'}) {
    cancelRetry();
    _setState(_SafeModeState.manual(premisesName: premisesName));
  }

  /// Clear the state. Called when a surface tears down completely so
  /// the next mount starts from `unchecked` and re-queries.
  void reset() {
    cancelRetry();
    _lastLatitude = null;
    _lastLongitude = null;
    _lastMatchEnforced = null;
    _lastMatchName = null;
    _setState(const _SafeModeState.unchecked());
  }

  /// Cancel any pending one-shot retry. Called from camera dispose so
  /// the timer doesn't fire after the screen is gone.
  void cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _scheduleRetry() {
    cancelRetry();
    _retryTimer = Timer(const Duration(seconds: 30), () {
      _retryTimer = null;
      // No await — fire-and-forget. checkLocation handles its own
      // state transitions.
      checkLocation(skipIfChecked: false);
    });
  }

  void _setState(_SafeModeState next) {
    if (_state == next) return;
    _state = next;
    notifyListeners();
  }

  /// App lifecycle hook — keeps the 30s retry timer aligned with
  /// foreground state.
  ///
  /// * paused / inactive / hidden → cancel the retry. A GPS poll while
  ///   the app is backgrounded would burn battery for a banner that
  ///   nobody can see.
  /// * resumed → if state is not active and not manual, re-run
  ///   [checkLocation] immediately (which itself schedules the next
  ///   30s retry). This catches the practitioner walking into a
  ///   polygon while the phone was locked.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        cancelRetry();
        break;
      case AppLifecycleState.resumed:
        if (!_state.isActive && !_state.isManual) {
          // Fire-and-forget — checkLocation owns its own state
          // transitions + retry scheduling.
          unawaited(checkLocation());
        }
        break;
    }
  }

  @override
  void dispose() {
    cancelRetry();
    WidgetsBinding.instance.removeObserver(this);
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
