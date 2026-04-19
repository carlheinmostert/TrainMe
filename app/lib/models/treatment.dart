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
}
