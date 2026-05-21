import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'api_client.dart';

/// Session-scoped service that tracks whether the current capture
/// session is operating inside a Safe-Mode-enforcing premises.
///
/// Lifecycle:
///   1. On session start (camera screen mount / first capture),
///      [checkLocation] is called. It requests `whenInUse` location
///      permission (no-op if already granted), gets one GPS fix, and
///      asks the server's `find_premises_at` RPC if the point lies
///      inside an enforcing polygon.
///   2. If a match is returned, [isActive] becomes true and stays true
///      for the rest of the session — Carl's chosen "session-sticky
///      grace" semantics. Walking outside the polygon mid-session does
///      NOT flip Safe Mode off.
///   3. On explicit [reset] (session end / new session), state clears.
///
/// Consumers (one each, no recursion):
///   * Capture UI (banner display via [isActive] / [premisesName]).
///   * Conversion service (passes `safeModeEnabled` to native channel).
///   * Upload service (stamps `safe_mode_active` + `captured_in_premises_id`
///     on every exercise in the published session).
///
/// Singleton because the active session has at most one Safe Mode
/// state, and threading the state through every capture pathway is
/// noisy. `SafeModeService.instance` is set up in `main()`.
class SafeModeService extends ChangeNotifier {
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
  /// reuse the existing instance.
  static void initialize(ApiClient api) {
    _instance ??= SafeModeService._(api);
  }

  final ApiClient _api;

  /// True iff the active session is inside an enforcing premises.
  bool get isActive => _state.isActive;

  /// The premises id stamped on every exercise captured in this
  /// session for the `exercises.captured_in_premises_id` audit column.
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

  _SafeModeState _state = const _SafeModeState.unchecked();

  /// One-shot query: get a GPS fix, ask the server which (if any)
  /// premises contains it. Caller passes a [skipIfChecked] flag so
  /// session-sticky semantics are honoured — once a session has its
  /// answer (active OR explicitly not active), we don't re-query on
  /// every capture.
  ///
  /// Failure modes are NOT errors — they're outcomes:
  ///   - permission denied / restricted → Safe Mode stays off, banner
  ///     shows nothing (silent — practitioner doesn't need to know).
  ///   - location unavailable / timed out → Safe Mode stays off.
  ///   - point lies outside every enforcing polygon → Safe Mode off.
  ///   - point lies inside ≥1 enforcing polygon → Safe Mode on,
  ///     state stamped with the smallest matching premises.
  Future<void> checkLocation({bool skipIfChecked = true}) async {
    if (skipIfChecked && _state.status != SafeModeCheckStatus.unchecked) {
      return;
    }

    _setState(const _SafeModeState.checking());

    final hasService = await Geolocator.isLocationServiceEnabled();
    if (!hasService) {
      _setState(const _SafeModeState.unavailable());
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
      _setState(const _SafeModeState.unavailable());
      return;
    }

    final match = await _api.findPremisesAt(
      latitude: position.latitude,
      longitude: position.longitude,
    );

    if (match == null || !match.safeModeEnforced) {
      _setState(const _SafeModeState.notInZone());
      return;
    }

    _setState(_SafeModeState.active(
      premisesId: match.premisesId,
      premisesName: match.premisesName,
    ));
  }

  /// Clear the state. Called when a session ends so the next session
  /// starts from `unchecked` and re-queries.
  void reset() {
    _setState(const _SafeModeState.unchecked());
  }

  void _setState(_SafeModeState next) {
    if (_state == next) return;
    _state = next;
    notifyListeners();
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
  /// on for the rest of the session.
  active,
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

  bool get isActive => status == SafeModeCheckStatus.active;

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
