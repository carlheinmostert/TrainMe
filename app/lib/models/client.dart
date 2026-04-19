/// A client (the person receiving the plan) — one row per client in a
/// practice. Owns the `video_consent` record that governs which treatments
/// the web player surfaces when the client opens their plan URL.
///
/// Line drawing is always allowed (platform baseline; de-identifies the
/// subject). Grayscale and original-colour viewing are per-client opt-ins;
/// the practitioner captures them via the consent sheet.
///
/// Backend: `clients` table (added via the three-treatment-backend migration).
class PracticeClient {
  final String id;
  final String practiceId;
  final String name;

  /// Can the client be shown the original colour footage?
  final bool colourAllowed;

  /// Can the client be shown the grayscale (saturation-zero) version?
  final bool grayscaleAllowed;

  /// Line drawing is the platform baseline — never off. Represented here so
  /// the consent sheet can render it as a disabled, always-on row without
  /// branching on a constant.
  bool get lineAllowed => true;

  const PracticeClient({
    required this.id,
    required this.practiceId,
    required this.name,
    this.colourAllowed = false,
    this.grayscaleAllowed = false,
  });

  /// Hydrate from the JSON shape returned by the `list_practice_clients`
  /// RPC. Tolerant of missing keys so we stay compatible with both the
  /// pre-consent and post-consent schema snapshots.
  factory PracticeClient.fromJson(Map<String, dynamic> json) {
    final consent = json['video_consent'];
    final consentMap = consent is Map ? Map<String, dynamic>.from(consent) : const <String, dynamic>{};
    return PracticeClient(
      id: json['id'] as String,
      practiceId: (json['practice_id'] ?? '') as String,
      name: (json['name'] ?? '') as String,
      colourAllowed: consentMap['original'] == true || consentMap['colour'] == true,
      grayscaleAllowed: consentMap['grayscale'] == true,
    );
  }

  PracticeClient copyWith({
    String? name,
    bool? colourAllowed,
    bool? grayscaleAllowed,
  }) {
    return PracticeClient(
      id: id,
      practiceId: practiceId,
      name: name ?? this.name,
      colourAllowed: colourAllowed ?? this.colourAllowed,
      grayscaleAllowed: grayscaleAllowed ?? this.grayscaleAllowed,
    );
  }
}
