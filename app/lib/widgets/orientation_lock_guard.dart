import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Per-screen orientation lock with a lifecycle-race-safe stack.
///
/// Naive `setPreferredOrientations` push-on-initState / restore-on-dispose
/// has a well-known race: when navigating from screen A → B, Flutter calls
/// B.initState BEFORE A.dispose. If A.dispose then "restores" the global
/// default, it overwrites B's just-installed lock — B effectively never
/// got to set its preference. The opposite-direction pop has the same
/// hazard with reversed ownership.
///
/// The fix: maintain a static stack of `Set<DeviceOrientation>` entries
/// keyed by guard instance. `initState` pushes; `dispose` pops the
/// instance's own entry (not the top — the popping guard may not be on
/// top by the time it disposes). After every push/pop the *current top*
/// of stack is what we re-apply to `SystemChrome`. If the stack drains,
/// the global default ([_globalDefault]) takes over — the app's "what
/// orientations does the OS allow when nothing else has an opinion"
/// answer.
///
/// Pair with [OrientationLockGuardScope.setGlobalDefault] in `main.dart`
/// so the empty-stack fallback matches whatever the app considers the
/// canonical baseline (portrait-only for homefit.studio).
class OrientationLockGuard extends StatefulWidget {
  final Set<DeviceOrientation> allowed;
  final Widget child;

  const OrientationLockGuard({
    super.key,
    required this.child,
    this.allowed = const {DeviceOrientation.portraitUp},
  });

  @override
  State<OrientationLockGuard> createState() => _OrientationLockGuardState();
}

class _OrientationLockGuardState extends State<OrientationLockGuard> {
  late final _StackEntry _entry;

  @override
  void initState() {
    super.initState();
    _entry = _StackEntry(widget.allowed);
    OrientationLockGuardScope._push(_entry);
  }

  @override
  void didUpdateWidget(covariant OrientationLockGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_setEquals(oldWidget.allowed, widget.allowed)) {
      _entry.allowed = widget.allowed;
      OrientationLockGuardScope._reapplyTop();
    }
  }

  @override
  void dispose() {
    OrientationLockGuardScope._remove(_entry);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;

  static bool _setEquals(
    Set<DeviceOrientation> a,
    Set<DeviceOrientation> b,
  ) {
    if (a.length != b.length) return false;
    for (final v in a) {
      if (!b.contains(v)) return false;
    }
    return true;
  }
}

class _StackEntry {
  Set<DeviceOrientation> allowed;
  _StackEntry(this.allowed);
}

/// Static control surface for the guard's stack. Exposed so `main.dart`
/// can register the global default once at startup, and tests can clear
/// state between cases.
class OrientationLockGuardScope {
  OrientationLockGuardScope._();

  static final List<_StackEntry> _stack = <_StackEntry>[];
  static Set<DeviceOrientation> _globalDefault =
      const {DeviceOrientation.portraitUp};

  /// Set the orientation set applied when the stack is empty. Idempotent;
  /// re-applies to `SystemChrome` only if the stack is currently empty
  /// (otherwise the active lock at the top of the stack stays in force).
  static Future<void> setGlobalDefault(Set<DeviceOrientation> orientations) {
    _globalDefault = orientations;
    if (_stack.isEmpty) {
      return SystemChrome.setPreferredOrientations(orientations.toList());
    }
    return Future.value();
  }

  static void _push(_StackEntry entry) {
    _stack.add(entry);
    _reapplyTop();
  }

  static void _remove(_StackEntry entry) {
    _stack.remove(entry);
    _reapplyTop();
  }

  static void _reapplyTop() {
    final orientations =
        _stack.isEmpty ? _globalDefault : _stack.last.allowed;
    // Fire-and-forget: `setPreferredOrientations` returns a Future but
    // the iOS bridge applies the change synchronously enough for our
    // purposes — the next frame already reflects the new lock.
    SystemChrome.setPreferredOrientations(orientations.toList());
  }
}
