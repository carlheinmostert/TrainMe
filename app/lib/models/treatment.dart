/// How a client sees the exercise video in the web player (and here in the
/// practitioner's preview).
///
/// [line] — the on-device line drawing conversion. De-identifies the client
/// by abstracting body + face into strokes. Always available; never gated.
///
/// [grayscale] — the original footage with saturation pulled to zero. Shows
/// the real person in black & white. Requires the client to have said yes to
/// grayscale viewing.
///
/// [original] — the unmodified colour footage. Requires the client to have
/// said yes to original-colour viewing.
///
/// Gated treatments are hidden from the client by the backend returning null
/// URLs; the UI mirrors that null into a disabled segment here.
enum Treatment { line, grayscale, original }

extension TreatmentX on Treatment {
  /// Short label rendered in the segmented control.
  String get shortLabel {
    switch (this) {
      case Treatment.line:
        return 'Line';
      case Treatment.grayscale:
        return 'B&W';
      case Treatment.original:
        return 'Original';
    }
  }

  /// Canonical wire encoding used for both SQLite (`exercises.preferred_treatment`)
  /// and the Supabase `exercises.preferred_treatment` column. Keeping the two
  /// stores on a shared string vocabulary means sync can round-trip the field
  /// without any translation layer — the payload map is identical on both
  /// sides.
  ///
  ///   Treatment.line      → 'line'
  ///   Treatment.grayscale → 'grayscale'
  ///   Treatment.original  → 'original'
  String get wireValue {
    switch (this) {
      case Treatment.line:
        return 'line';
      case Treatment.grayscale:
        return 'grayscale';
      case Treatment.original:
        return 'original';
    }
  }
}

/// Decode a wire-string (SQLite TEXT column or Supabase JSON) back into a
/// [Treatment], or null when the value is absent / unrecognised.
///
/// A null return is the explicit "use the Line-drawing default" signal —
/// callers map that back to [Treatment.line] at render time. Unrecognised
/// strings are also treated as null so a future server-side value never
/// crashes the mobile app mid-parse.
Treatment? treatmentFromWire(Object? raw) {
  if (raw is! String) return null;
  switch (raw) {
    case 'line':
      return Treatment.line;
    case 'grayscale':
      return Treatment.grayscale;
    case 'original':
      return Treatment.original;
    default:
      return null;
  }
}
