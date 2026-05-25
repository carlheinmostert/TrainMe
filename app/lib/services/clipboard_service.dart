import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/exercise_capture.dart';
import '../models/session.dart';
import 'auth_service.dart';
import 'conversion_service.dart';

/// A single item in the in-memory exercise clipboard (2026-05-25).
///
/// Carries pointers to the source row plus a thin display snapshot used
/// for chip + sheet rendering without re-reading SQLite. The full deep
/// copy of the underlying media + sets happens at paste time (D2 in
/// `docs/specs/2026-05-25-exercise-clipboard.md`).
class ClipboardItem {
  /// Local-only UUID for this clipboard entry. Distinct from the source
  /// exercise id so listeners can address an entry uniquely even if the
  /// same source is re-copied (we de-dupe on add, but the API contract
  /// stays clean if that policy ever loosens).
  final String id;

  /// The source exercise row this clipboard entry points at. Used by:
  ///  1. De-duplication on add — same source id is a no-op.
  ///  2. Reactive pruning on delete (E1) — wired through
  ///     `notifySourceDeleted`.
  ///  3. The paste path — looked up at paste time to source media + sets.
  final String sourceExerciseId;

  /// The session the source row belonged to at copy time. Pure pointer
  /// metadata — not authoritative at paste time, since the source
  /// session may have been renamed or deleted. The deep-copy machinery
  /// reads from the *current* exercise row, not from this snapshot.
  final String sourceSessionId;

  /// The practice the source row belonged to at copy time. Stamped from
  /// the source session's `practiceId` (or, if the session row has none
  /// — the local SQLite mirror drops it per
  /// `gotcha_session_practice_id_local_only` — from
  /// `AuthService.currentPracticeId` as a fallback). Drives the D1
  /// single-practice-scope guard: only items whose `practiceId` matches
  /// the active practice are visible in the chip / paste sheet.
  /// Null is treated as "no scope" and always visible — defensive for
  /// edge cases where neither the session nor the auth layer can
  /// supply a practice id (signed-out test fixtures, etc.).
  final String? practiceId;

  /// Practitioner-facing label captured at copy time. Render-only — if
  /// the source row's name changes after copy, the chip + sheet keep
  /// showing the older label until clipboard clear. That's deliberate:
  /// the clipboard is a transient tool (D3); editing the source mid-
  /// clipboard is a corner case not worth fresh-fetching against.
  final String? displayName;

  /// Relative path (via [PathResolver]) to the source's hero/thumbnail.
  /// Same staleness contract as [displayName]. Null when the source
  /// hasn't generated a thumbnail yet (a brand-new capture that hasn't
  /// finished its line-drawing conversion + hero extraction).
  final String? displayThumbPath;

  /// Hero-crop offset captured at copy time. Mirrors
  /// `ExerciseCapture.heroCropOffset` — needed so the chip's thumbnail
  /// uses the same crop window the source row shows in Studio. Null
  /// falls through to centred (0.5) per `ExerciseCapture` semantics.
  final double? displayHeroCropOffset;

  /// Media type of the source — used by the paste sheet to render a
  /// rest-period exclusion guard rail (rest is never copyable, but the
  /// model keeps the field for symmetry with thumbnail rendering when
  /// previous-session exercises light up future media types).
  final MediaType displayMediaType;

  /// When the practitioner copied the exercise. Sorts FIFO at paste
  /// time (oldest copied → first pasted).
  final DateTime copiedAt;

  ClipboardItem({
    required this.id,
    required this.sourceExerciseId,
    required this.sourceSessionId,
    required this.copiedAt,
    required this.displayMediaType,
    this.practiceId,
    this.displayName,
    this.displayThumbPath,
    this.displayHeroCropOffset,
  });

  @override
  String toString() => 'ClipboardItem(${displayName ?? sourceExerciseId})';
}

/// In-memory, transient holding area for copied exercises.
///
/// Singleton (matches the project's `AuthService` / `ConversionService` /
/// `SafeModeService` pattern — bare `ChangeNotifier`, no Provider /
/// Riverpod). Owned for the entire app lifetime; never disposed. Clears
/// on cold-start by virtue of being in-memory only (D3).
///
/// Scope at v1: single-practice only (D1). Each [ClipboardItem] stamps
/// the `practiceId` it was copied under (preferring the source session's
/// id, falling back to [AuthService.currentPracticeId]). The public
/// [items] / [count] views filter to the ACTIVE practice — items copied
/// in practice A become invisible (but stay in memory) when the
/// practitioner switches to practice B, then reappear when they switch
/// back. Switching practices is NOT a clipboard clear; the spec is
/// explicit that the clipboard is transient by lifecycle (D3) but not by
/// practice-switch.
///
/// The service subscribes to [AuthService.currentPracticeId] in its
/// constructor so a practice switch fires [notifyListeners] / the
/// [countStream] without needing every consumer to listen to two
/// notifiers.
///
/// See `docs/specs/2026-05-25-exercise-clipboard.md` for the full
/// design + locked decisions.
class ClipboardService extends ChangeNotifier {
  ClipboardService._() {
    // Bridge practice switches into the chip / sheet's rebuild path so
    // the visible-count flips immediately when the practitioner picks a
    // different practice in the switcher.
    AuthService.instance.currentPracticeId.addListener(_onPracticeChanged);
  }

  static final ClipboardService _instance = ClipboardService._();

  /// The singleton instance. Lives for the entire app lifetime.
  static ClipboardService get instance => _instance;

  /// Internal raw store — holds items from EVERY practice the
  /// practitioner has touched in this session. Public views filter to
  /// the active practice; switching practices doesn't drop rows here.
  final List<ClipboardItem> _items = <ClipboardItem>[];
  final _countController = StreamController<int>.broadcast();

  /// Stream subscription on [ConversionService.onExerciseRemoved], owned
  /// by [bindToConversionService] so a re-bind is idempotent (we cancel
  /// the prior subscription before re-subscribing).
  StreamSubscription<ExerciseRemoval>? _conversionRemovalSub;

  /// Snapshot of the clipboard contents, oldest-first (FIFO), filtered
  /// to the active practice per D1. Returns an unmodifiable view so
  /// listeners can iterate safely.
  List<ClipboardItem> get items =>
      List<ClipboardItem>.unmodifiable(_visibleItems());

  /// Number of items in the clipboard visible to the active practice.
  /// Chip visibility flips at the 0 → 1 transition of this filtered count.
  int get count => _visibleItems().length;

  /// Whether the clipboard currently holds any items visible to the
  /// active practice. Equivalent to `count > 0` — surfaced so chip-
  /// visibility callsites read naturally.
  bool get isNotEmpty => count > 0;

  /// Broadcast stream of the visible item count. Emits the latest
  /// active-practice-filtered count on every mutation OR practice
  /// switch. Used by `ClipboardChip` to drive a fade-in / fade-out
  /// transition without forcing every consumer to subscribe as a
  /// listener.
  Stream<int> get countStream => _countController.stream;

  /// Apply the D1 practice filter to the raw store. Items whose
  /// [ClipboardItem.practiceId] is null are treated as scope-less and
  /// always visible — defensive for fixtures and pre-stamp legacy rows
  /// that won't exist in production but might in tests.
  List<ClipboardItem> _visibleItems() {
    final activePracticeId = AuthService.instance.currentPracticeId.value;
    if (activePracticeId == null) {
      // Signed-out / unbootstrapped — show everything; there's no
      // practice boundary to enforce yet.
      return _items;
    }
    return _items.where((item) {
      // Null practiceId on the item = scope-less, always visible.
      // Match on string equality otherwise.
      return item.practiceId == null || item.practiceId == activePracticeId;
    }).toList(growable: false);
  }

  /// React to the practitioner picking a different practice in the
  /// switcher. Doesn't mutate `_items`; just re-emits so the chip /
  /// sheet rebuild against the new visible slice.
  void _onPracticeChanged() {
    _emit();
  }

  /// Subscribe to [ConversionService.onExerciseRemoved] so Safe Mode
  /// rejections (and any other future removal events) prune the
  /// clipboard immediately, even when no Studio screen is mounted to
  /// dispatch [notifySourceDeleted] itself.
  ///
  /// Idempotent — calling twice cancels the prior subscription before
  /// re-subscribing, so accidental double-binding from a hot-reload or
  /// a defensively-called bootstrap path won't double-fire the prune.
  /// Wired once at app startup from `main.dart` after
  /// [ConversionService] is initialized.
  void bindToConversionService(ConversionService conversionService) {
    _conversionRemovalSub?.cancel();
    _conversionRemovalSub =
        conversionService.onExerciseRemoved.listen((removal) {
      notifySourceDeleted(removal.exerciseId);
    });
  }

  /// Add an exercise to the clipboard. De-duplicates by
  /// `sourceExerciseId` — re-copying the same source is a no-op (the
  /// chip still pulses on the caller side so the gesture is
  /// acknowledged, but the count doesn't bump). Rest periods are
  /// ignored — copy doesn't apply to session-structural rows.
  ///
  /// Stamps the item's [ClipboardItem.practiceId] from the source
  /// session, falling back to [AuthService.currentPracticeId] when the
  /// session row's `practiceId` is null (the local SQLite mirror drops
  /// it per `gotcha_session_practice_id_local_only`).
  ///
  /// Returns the newly-added [ClipboardItem], or `null` when the call
  /// was a no-op (duplicate / rest period).
  ClipboardItem? addItem(ExerciseCapture source, Session sourceSession) {
    if (source.isRest) return null;
    final existing = _items.indexWhere(
      (item) => item.sourceExerciseId == source.id,
    );
    if (existing >= 0) {
      // De-dupe per D7 / D8 — no count bump on re-copy. Listeners can
      // still drive a chip pulse off their own gesture handler.
      return null;
    }
    final item = ClipboardItem(
      id: const Uuid().v4(),
      sourceExerciseId: source.id,
      sourceSessionId: sourceSession.id,
      practiceId: sourceSession.practiceId ??
          AuthService.instance.currentPracticeId.value,
      copiedAt: DateTime.now(),
      displayMediaType: source.mediaType,
      displayName: source.name,
      displayThumbPath: source.thumbnailPath,
      displayHeroCropOffset: source.heroCropOffset,
    );
    _items.add(item);
    _emit();
    return item;
  }

  /// Remove a single item by its clipboard id (NOT the source exercise
  /// id). Wired for completeness — the v1 UI has no per-item delete
  /// (D7), but the API stays clean for reactive pruning and any future
  /// trash affordance.
  void removeItem(String itemId) {
    final before = _items.length;
    _items.removeWhere((item) => item.id == itemId);
    if (_items.length != before) {
      _emit();
    }
  }

  /// React to an exercise deletion event by removing every clipboard
  /// item that pointed at the now-gone row (E1 — reactive pruning).
  ///
  /// Driven by [bindToConversionService] which subscribes to
  /// [ConversionService.onExerciseRemoved] once at app startup so the
  /// pruning fires globally, not just when Studio is mounted.
  /// Idempotent — passing an id with no matching items is a no-op, so
  /// it's safe to call from multiple sources (the Safe Mode rejection
  /// path + the Studio delete path both feed in).
  void notifySourceDeleted(String sourceExerciseId) {
    final before = _items.length;
    _items.removeWhere(
      (item) => item.sourceExerciseId == sourceExerciseId,
    );
    if (_items.length != before) {
      _emit();
    }
  }

  /// React to a session deletion event by removing every clipboard item
  /// that pointed at exercises in that session. Exposed for future
  /// session-delete paths — not wired today because session deletion is
  /// a soft-delete with a 7-day recycle window (R-01) and pasted rows
  /// can still be revived. If the recycle window passes without
  /// restore, the per-exercise deletion event fires and notifies via
  /// [notifySourceDeleted].
  void notifySourceSessionDeleted(String sourceSessionId) {
    final before = _items.length;
    _items.removeWhere(
      (item) => item.sourceSessionId == sourceSessionId,
    );
    if (_items.length != before) {
      _emit();
    }
  }

  /// Clear every item visible to the active practice. Wired to the
  /// chip's `×` button and the paste sheet's `× Clear all` header
  /// control. Items copied under OTHER practices stay intact — clearing
  /// the chip in practice A doesn't dump practice B's clipboard.
  void clearAll() {
    final activePracticeId = AuthService.instance.currentPracticeId.value;
    final before = _items.length;
    if (activePracticeId == null) {
      // No active practice — clear everything (signed-out edge / tests).
      if (_items.isEmpty) return;
      _items.clear();
    } else {
      _items.removeWhere((item) =>
          item.practiceId == null || item.practiceId == activePracticeId);
    }
    if (_items.length != before) {
      _emit();
    }
  }

  /// Lookup helper — null when the id doesn't match. Searches the raw
  /// store, not the filtered view, so callers holding an id from a
  /// prior practice still resolve it. The visible-items filter is a
  /// UI affordance; the deep-copy machinery on paste is allowed to see
  /// any item whose id was previously surfaced.
  ClipboardItem? itemById(String itemId) {
    for (final item in _items) {
      if (item.id == itemId) return item;
    }
    return null;
  }

  void _emit() {
    if (!_countController.isClosed) {
      _countController.add(count);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    // Defensive — singleton lives for the app's lifetime, but keep the
    // contract honest in case tests construct + tear down siblings.
    AuthService.instance.currentPracticeId.removeListener(_onPracticeChanged);
    _conversionRemovalSub?.cancel();
    _countController.close();
    super.dispose();
  }
}
