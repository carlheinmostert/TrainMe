import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Practitioner-wide custom preset values for Reps / Sets / Hold / Rest.
///
/// Stored device-local (SharedPreferences) because the values are a
/// personal muscle-memory thing, not plan data — the practitioner
/// typically returns to "their" numbers (e.g. 13 reps, 45s hold) for a
/// specific modality, and jumping between clients shouldn't reset the
/// chip row to canonical defaults.
///
/// Storage key:  `homefit.practitioner.custom_presets`
/// Shape:        a JSON map `{ "reps": [7, 13], "sets": [], "hold": [45], "rest": [] }`
/// MRU cap:      3 values per controlKey. Adding a 4th evicts the
///               least-recently-used (head of the list).
/// Write path:   [add] and [remove]. Both notify listeners on success.
/// Read path:    [get]. Returns an empty list when nothing is stored for
///               the control (fresh installs / newly-added control keys).
///
/// [init] must be called once at startup before any read; widgets can
/// listen to [onChange] to rebuild whenever the store mutates.
class PractitionerCustomPresets {
  PractitionerCustomPresets._();

  static const _prefsKey = 'homefit.practitioner.custom_presets';
  static const _maxPerKey = 3;

  static SharedPreferences? _prefs;

  /// In-memory cache of the stored map. Seeded by [init]; kept in sync
  /// with SharedPreferences on every write so repeated reads are cheap.
  static final Map<String, List<num>> _cache = <String, List<num>>{};

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
    if (raw == null || raw.isEmpty) return;
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

  /// Values currently stored for [controlKey]. Returns an empty list
  /// when nothing's been added yet. Callers receive an unmodifiable
  /// view so external mutation can't corrupt the cache.
  static List<num> get(String controlKey) {
    final list = _cache[controlKey];
    if (list == null || list.isEmpty) return const <num>[];
    return List<num>.unmodifiable(list);
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
    await _persist();
    onChange.value = onChange.value + 1;
  }

  /// Remove [value] from [controlKey]'s MRU. No-op when missing.
  static Future<void> remove(String controlKey, num value) async {
    final existing = _cache[controlKey];
    if (existing == null || existing.isEmpty) return;
    final before = existing.length;
    existing.remove(value);
    if (existing.length == before) return;
    if (existing.isEmpty) {
      _cache.remove(controlKey);
    }
    await _persist();
    onChange.value = onChange.value + 1;
  }

  /// Wipe every stored preset. Used by debug tooling; not wired to any
  /// production surface.
  @visibleForTesting
  static Future<void> debugClear() async {
    _cache.clear();
    await _persist();
    onChange.value = onChange.value + 1;
  }

  static Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final serialised = <String, List<num>>{};
    _cache.forEach((key, value) {
      if (value.isNotEmpty) serialised[key] = value;
    });
    await prefs.setString(_prefsKey, json.encode(serialised));
  }
}
