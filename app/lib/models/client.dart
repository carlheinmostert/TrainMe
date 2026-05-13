/// A client (the person receiving the plan) — one row per client in a
/// practice. Owns the `video_consent` record that governs which treatments
/// the web player surfaces when the client opens their plan URL.
///
/// Line drawing is always allowed (platform baseline; de-identifies the
/// subject). Grayscale and original-colour viewing are per-client opt-ins;
/// the practitioner captures them via the consent sheet.
///
/// Wave 30 — adds [avatarPath] (relative path inside the private
/// `raw-archive` bucket) and an `avatar` consent flag.
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

  /// Wave 30 — has the practitioner been granted permission to capture
  /// + store a body-focus avatar still for this client? Default false.
  /// Gates the avatar-capture entry point on the client detail view; if
  /// false the slot opens the consent sheet instead of the camera.
  final bool avatarAllowed;

  /// Wave 17 — has the practitioner allowed anonymous usage analytics for
  /// this client's plans? Default true (MVP needs data; opt-out via UI).
  /// When false, the web player skips the consent banner and no analytics
  /// events are recorded.
  final bool analyticsAllowed;

  /// Relative path inside the `raw-archive` bucket
  /// (`<practiceId>/<clientId>/avatar.png`). Null = no avatar yet —
  /// UI falls back to the initials monogram.
  final String? avatarPath;

  /// 2026-05-13 — epoch-ms of the first-ever `set_client_video_consent`
  /// call for this client. NULL means the practitioner has never
  /// explicitly toggled consent for this client. ClientSessionsScreen
  /// auto-opens the consent sheet on entry when this is NULL (covers
  /// both newly-created clients AND legacy clients whose consent was
  /// never explicitly set). Stamped server-side AND locally on
  /// `SyncService.queueSetConsent` so the suppression is immediate.
  final int? consentExplicitlySetAt;

  /// True when the practitioner has explicitly toggled consent for this
  /// client at least once. Drives the ClientSessionsScreen auto-open of
  /// the consent sheet — NULL → open; non-NULL → don't.
  bool get consentExplicitlySet => consentExplicitlySetAt != null;

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
    this.avatarAllowed = false,
    this.analyticsAllowed = true,
    this.avatarPath,
    this.consentExplicitlySetAt,
  });

  /// Hydrate from the JSON shape returned by the `list_practice_clients`
  /// RPC. Tolerant of missing keys so we stay compatible with both the
  /// pre-consent and post-consent schema snapshots.
  factory PracticeClient.fromJson(Map<String, dynamic> json) {
    final consent = json['video_consent'];
    final consentMap = consent is Map ? Map<String, dynamic>.from(consent) : const <String, dynamic>{};
    final pathRaw = json['avatar_path'];
    final explicit = json['consent_explicitly_set_at'];
    int? explicitMs;
    if (explicit is String) {
      explicitMs = DateTime.tryParse(explicit)?.millisecondsSinceEpoch;
    } else if (explicit is int) {
      explicitMs = explicit;
    }
    return PracticeClient(
      id: json['id'] as String,
      practiceId: (json['practice_id'] ?? '') as String,
      name: (json['name'] ?? '') as String,
      colourAllowed: consentMap['original'] == true || consentMap['colour'] == true,
      grayscaleAllowed: consentMap['grayscale'] == true,
      avatarAllowed: consentMap['avatar'] == true,
      analyticsAllowed: consentMap['analytics_allowed'] != false,
      avatarPath: pathRaw is String && pathRaw.isNotEmpty ? pathRaw : null,
      consentExplicitlySetAt: explicitMs,
    );
  }

  PracticeClient copyWith({
    String? name,
    bool? colourAllowed,
    bool? grayscaleAllowed,
    bool? avatarAllowed,
    bool? analyticsAllowed,
    String? avatarPath,
    bool clearAvatarPath = false,
    int? consentExplicitlySetAt,
  }) {
    return PracticeClient(
      id: id,
      practiceId: practiceId,
      name: name ?? this.name,
      colourAllowed: colourAllowed ?? this.colourAllowed,
      grayscaleAllowed: grayscaleAllowed ?? this.grayscaleAllowed,
      avatarAllowed: avatarAllowed ?? this.avatarAllowed,
      analyticsAllowed: analyticsAllowed ?? this.analyticsAllowed,
      avatarPath: clearAvatarPath ? null : (avatarPath ?? this.avatarPath),
      consentExplicitlySetAt:
          consentExplicitlySetAt ?? this.consentExplicitlySetAt,
    );
  }
}
