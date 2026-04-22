import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Practitioner-wide preset values for Reps / Sets / Hold / Rest chip rows.
///
/// Stored device-local (SharedPreferences) because the values are a
/// personal muscle-memory thing, not plan data — the practitioner
/// typically returns to "their" numbers (e.g. 13 reps, 45s hold) for a
/// specific modality, and jumping between clients shouldn't reset the
/// chip row.
///
/// **Wave 18.1** — the store now holds the FULL chip list per control,
/// not just the custom additions. On the first read for a control the
/// store merges the caller-supplied canonical seeds with whatever legacy
/// custom values are stored, dedups, and writes back. This migrates
/// Wave 18 users to the unified model without data loss: anyone who had
/// 3 custom values and 5 canonical defaults ends up with one 8-chip
/// list they can long-press to edit. Long-press on a SEED value removes
/// it just like any other chip (the distinction is gone).
///
/// A persistent sidecar key (`homefit.practitioner.presets_migrated_v1`)
/// records which controls have already been seeded so subsequent app
/// launches don't re-seed a control whose seed values the practitioner
/// deliberately removed.
///
/// Storage key:  `homefit.practitioner.custom_presets`
///               (kept for migration — the key name no longer matches the
///                semantics, but renaming would orphan Wave 18 data)
/// Shape:        a JSON map `{ "reps": [5,8,10,12,15], "sets": [...], ... }`
/// Cap:          8 values per controlKey. Adding a 9th evicts the
///               least-recently-used (head of the list).
/// Write path:   [add] and [remove]. Both notify listeners on success.
/// Read path:    [get] (legacy caller) / [getMerged] (chip-row caller —
///               seeds on first read and returns the unified list).
///
/// [init] must be called once at startup before any read; widgets can
/// listen to [onChange] to rebuild whenever the store mutates.
class PractitionerCustomPresets {
  PractitionerCustomPresets._();

  static const _prefsKey = 'homefit.practitioner.custom_presets';

  /// Sidecar key that records which controlKeys have been migrated to
  /// the Wave 18.1 unified-list model. Once a key appears here, we
  /// never re-seed its canonical values — removals are permanent.
  /// Shape: `["reps", "sets", ...]` (JSON array).
  static const _migratedKey = 'homefit.practitioner.presets_migrated_v1';
  static const _maxPerKey = 8;

  static SharedPreferences? _prefs;

  /// In-memory cache of the stored map. Seeded by [init]; kept in sync
  /// with SharedPreferences on every write so repeated reads are cheap.
  static final Map<String, List<num>> _cache = <String, List<num>>{};

  /// Control keys that have been seeded with canonical defaults at
  /// least once. Persisted via [_migratedKey] so a process restart
  /// doesn't re-seed the canonicals the practitioner deliberately
  /// removed.
  static final Set<String> _migrated = <String>{};

  /// Notifier bumped after every successful [add] / [remove]. Widgets
  /// that render chip rows subscribe to this so a write from elsewhere
  /// in the tree rebuilds them without prop-drilling.
  static final ValueNotifier<int> onChange = ValueNotifier<int>(0);

  /// Load the store from SharedPreferences. Idempotent — a second call
  /// is a no-op (the singleton is process-wide, not per-screen).
  static Future<void> init() async {
    if (_prefs != null) return;
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = json.decode(raw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (key is! String) return;
            if (value is! List) return;
            final values = <num>[];
            for (final v in value) {
              if (v is num) {
                values.add(v);
              } else if (v is String) {
                final parsed = num.tryParse(v);
                if (parsed != null) values.add(parsed);
              }
            }
            _cache[key] = values;
          });
        }
      } catch (_) {
        // Malformed JSON — start with an empty store. Non-fatal; writes
        // will rebuild the key and save it fresh.
        _cache.clear();
      }
    }

    // Load the migration sidecar so a restart doesn't re-seed canonicals.
    final migratedRaw = prefs.getString(_migratedKey);
    if (migratedRaw != null && migratedRaw.isNotEmpty) {
      try {
        final decoded = json.decode(migratedRaw);
        if (decoded is List) {
          for (final v in decoded) {
            if (v is String) _migrated.add(v);
          }
        }
      } catch (_) {
        // Malformed — treat as a fresh install; [getMerged] will migrate
        // each control on its first read.
        _migrated.clear();
      }
    }
  }

  /// Raw values currently stored for [controlKey] with NO seed merging.
  /// Returns an empty list when nothing's been stored yet.
  ///
  /// Prefer [getMerged] from chip-row callers — that one handles the
  /// Wave 18 → 18.1 migration by seeding canonical defaults on first
  /// read.
  static List<num> get(String controlKey) {
    final list = _cache[controlKey];
    if (list == null || list.isEmpty) return const <num>[];
    return List<num>.unmodifiable(list);
  }

  /// Unified preset list for [controlKey], guaranteed to hold at least
  /// the supplied [canonicalSeeds] on the practitioner's first-ever
  /// read of this control.
  ///
  /// Migration semantics:
  ///   * First ever read for a control (not in `_migrated` and array
  ///     absent OR array missing canonicals) → merge [canonicalSeeds]
  ///     with whatever's stored, dedup, persist, return sorted. Mark
  ///     the control as migrated so subsequent reads respect any
  ///     deliberate removals.
  ///   * Already migrated → return the stored list verbatim, sorted
  ///     numerically. Removed seeds stay removed.
  static List<num> getMerged(String controlKey, List<num> canonicalSeeds) {
    if (!_migrated.contains(controlKey)) {
      final existing = _cache[controlKey] ?? const <num>[];
      final merged = <num>{...existing, ...canonicalSeeds}.toList();
      merged.sort((a, b) => a.compareTo(b));
      _cache[controlKey] = merged;
      _migrated.add(controlKey);
      // Fire-and-forget persist — the cache is already correct so
      // subsequent reads in the same frame see the merged shape even
      // if the write hasn't flushed yet.
      _persist();
    }
    final list = _cache[controlKey] ?? const <num>[];
    final sorted = List<num>.from(list);
    sorted.sort((a, b) => a.compareTo(b));
    return List<num>.unmodifiable(sorted);
  }

  /// Append [value] to [controlKey]'s MRU array.
  ///
  /// MRU semantics:
  ///   - If [value] is already in the list, move it to the end (most
  ///     recently used). No duplicates.
  ///   - If the list is at [_maxPerKey], drop the head (least recently
  ///     used) before appending.
  ///
  /// Persists immediately and bumps [onChange].
  static Future<void> add(String controlKey, num value) async {
    final existing = List<num>.from(_cache[controlKey] ?? const <num>[]);
    existing.remove(value);
    existing.add(value);
    while (existing.length > _maxPerKey) {
      existing.removeAt(0);
    }
    _cache[controlKey] = existing;
    _migrated.add(controlKey);
    await _persist();
    onChange.value = onChange.value + 1;
  }

  /// Remove [value] from [controlKey]'s list. No-op when missing. This
  /// works for canonical seed values too — once removed, they stay gone
  /// (the migration flag in [_migrated] blocks re-seeding on subsequent
  /// reads / launches).
  static Future<void> remove(String controlKey, num value) async {
    final existing = _cache[controlKey];
    if (existing == null || existing.isEmpty) return;
    final before = existing.length;
    existing.remove(value);
    if (existing.length == before) return;
    // Keep the (possibly empty) list in place — an explicit empty state
    // is meaningful. Marking as migrated blocks re-seeding.
    _migrated.add(controlKey);
    await _persist();
    onChange.value = onChange.value + 1;
  }

  /// Wipe every stored preset. Used by debug tooling; not wired to any
  /// production surface.
  @visibleForTesting
  static Future<void> debugClear() async {
    _cache.clear();
    _migrated.clear();
    await _persist();
    onChange.value = onChange.value + 1;
  }

  static Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final serialised = <String, List<num>>{};
    _cache.forEach((key, value) {
      // Persist even empty arrays — an explicit empty state is meaningful
      // post-Wave 18.1 (the practitioner deliberately removed everything)
      // and must NOT be re-seeded on next read.
      serialised[key] = value;
    });
    await prefs.setString(_prefsKey, json.encode(serialised));
    await prefs.setString(_migratedKey, json.encode(_migrated.toList()));
  }
}
