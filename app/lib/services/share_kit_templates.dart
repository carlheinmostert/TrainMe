// Share-kit message templates — Wave 11 (mobile R-11 twin).
//
// **Source of truth:** `web-portal/src/lib/share-kit/templates.ts`. Every
// string in this file must be byte-identical to that module — the portal
// and the mobile app share the same share copy so the practitioner never
// sees drift between surfaces (R-10 + R-11).
//
// **Don't edit here.** Edit the portal's `templates.ts` first, then mirror
// the diff back into this file in the same branch / PR.
//
// Pure, deterministic string builders for the three share formats the
// practitioner can copy to clipboard from the mobile share-kit screen. No
// Flutter imports — keeps this file trivially testable and reusable from
// any Dart context.
//
// Voice (R-06 + voice.md): peer-to-peer. Copy mirrors the mockup at
// `docs/design/mockups/network-share-kit.html` exactly — no "referral",
// "commission", "rebate", "payout", "downline". We use "free credits",
// "on me", "visual home-exercise programmes".

/// Slots the share-kit templates interpolate.
///
/// Field meanings mirror the portal's `ShareKitSlots` 1:1:
///   * [firstName] — practitioner first name (falls back to email prefix).
///   * [fullName] — full name (falls back to [firstName]).
///   * [practiceName] — practice display name (e.g. "carlhein@me.com Practice").
///   * [referralLink] — full referral URL (e.g.
///     `https://manage.homefit.studio/r/K3JT7QR`).
class ShareKitSlots {
  final String firstName;
  final String fullName;
  final String practiceName;
  final String referralLink;

  const ShareKitSlots({
    required this.firstName,
    required this.fullName,
    required this.practiceName,
    required this.referralLink,
  });
}

/// WhatsApp · one-to-one — short personal message.
///
/// If [colleagueName] is supplied (and non-blank), `{Colleague}` is replaced
/// inline so the body lands fully personalised. Otherwise the literal
/// placeholder is preserved so the practitioner can paste-and-edit.
///
/// Shape mirrors the mockup `msg-body` verbatim. No trailing newline —
/// WhatsApp's unfurl uses the trailing URL as the preview source and
/// trailing whitespace sometimes breaks that on iOS.
String buildWhatsAppOneToOne(
  ShareKitSlots slots, {
  String? colleagueName,
}) {
  // Reference firstName so future copy additions that want it don't forget
  // it's already in scope — matches the portal's `void slots.firstName`.
  // ignore: unused_local_variable
  final _ = slots.firstName;
  final body =
      'Hey {Colleague}, try homefit.studio — home care plans my clients actually follow. '
      'Created in-session, delivered on WhatsApp before they leave. '
      'Sign up through this and you land with 8 free credits on me: ${slots.referralLink}';
  return substituteColleagueName(body, colleagueName);
}

/// WhatsApp · status / broadcast — punchier, unaddressed.
///
/// Short enough to fit inside a WhatsApp status caption (140 chars) after
/// the URL, which is the primary surface this line is written for.
String buildWhatsAppBroadcast(ShareKitSlots slots) {
  return 'Stop chasing clients on adherence. Let them see the plan. ${slots.referralLink}';
}

/// Email · subject line. Plain text, no trailing period. Matches the
/// mockup's email header field exactly.
String buildEmailSubject() {
  return "The tool I've been using for home programmes";
}

/// Email · body (plain-text). Hand-composed paragraphs from the mockup.
///
/// `{Colleague}` stays as a literal placeholder in the greeting so the
/// practitioner can personalise once pasted into their mail client.
///
/// Sign-off is built in: "Warmly," → [ShareKitSlots.fullName] →
/// [ShareKitSlots.practiceName]. We don't inject a blank line between the
/// sign-off block and the practice name — the mockup renders them as a
/// tight trio.
///
/// Line endings: `\n`. Gmail + Apple Mail both handle LF bodies fine when
/// pasted. We do NOT emit `\r\n`.
String buildEmailBody(ShareKitSlots slots) {
  return [
    'Hi {Colleague},',
    '',
    "I've been using a tool called homefit.studio for the home programmes I send clients between sessions, and I thought you might get value from it too. It records the actual exercise during the session, converts it into a clean visual demo on the phone, and sends the client a link that works in any browser — no app install.",
    '',
    "The part that's made the biggest difference for me is that clients actually see what I'm asking them to do, instead of reading a list of names on paper. Adherence has genuinely improved. It also lets me check which plans have been opened, so I can tell who's keeping up before their next visit.",
    '',
    'If you want to try it, you can sign up through my link and the first 8 credits are on me:',
    '',
    slots.referralLink,
    '',
    "Happy to walk you through it if you'd like — a quick call is usually enough to see whether it fits your practice.",
    '',
    'Warmly,',
    slots.fullName,
    slots.practiceName,
  ].join('\n');
}

/// Full email as one copy-to-clipboard string (subject + body joined).
///
/// Email clients don't share a single copy-subject-and-body shortcut, so
/// the "Copy full email" button copies a plain-text block with a `Subject:`
/// header at the top. The practitioner can split once pasted.
///
/// The "Open in mail client" intent fires a real
/// `mailto:?subject=...&body=...` intent via [buildEmailMailtoUri] — that
/// path bypasses this string entirely and encodes subject + body
/// separately.
String buildEmailFullCopy(ShareKitSlots slots) {
  return 'Subject: ${buildEmailSubject()}\n\n${buildEmailBody(slots)}';
}

/// Substitute the literal `{Colleague}` slot in a body with a real first
/// name. If [name] is empty / whitespace / null, the placeholder is
/// preserved verbatim so the practitioner can edit post-paste.
///
/// Exported so UI surfaces can mirror the substitution in rendered
/// previews.
String substituteColleagueName(String body, String? name) {
  final trimmed = name?.trim() ?? '';
  if (trimmed.isEmpty) return body;
  return body.split('{Colleague}').join(trimmed);
}

// ----------------------------------------------------------------------------
//  Intent URI builders
// ----------------------------------------------------------------------------

/// WhatsApp · one-to-one intent URL.
///
/// Produces `https://wa.me/?text=<encoded body>`. No phone number: the
/// `wa.me` contact picker lets the practitioner pick the colleague
/// on-device, so the intent is agnostic to which conversation receives the
/// message.
///
/// If [colleagueName] is passed, the `{Colleague}` placeholder in the body
/// is substituted before URL-encoding — the intent lands fully
/// personalised. When it's empty / absent, the literal placeholder remains
/// in the encoded body so the practitioner can edit in-app.
///
/// We deliberately use `wa.me` rather than
/// `https://api.whatsapp.com/send?text=…` — `api.whatsapp.com` routes
/// through a web splash page on desktop browsers that feels sluggish next
/// to the native-app hand-off `wa.me` gives us.
Uri buildWhatsAppOneToOneUri(
  ShareKitSlots slots, {
  String? colleagueName,
}) {
  final body = buildWhatsAppOneToOne(slots, colleagueName: colleagueName);
  return Uri.parse('https://wa.me/?text=${Uri.encodeComponent(body)}');
}

/// WhatsApp · status / broadcast intent URL.
///
/// Same `wa.me/?text=...` shape as the one-to-one variant. The broadcast
/// body has no name slot so no substitution is needed.
Uri buildWhatsAppBroadcastUri(ShareKitSlots slots) {
  final body = buildWhatsAppBroadcast(slots);
  return Uri.parse('https://wa.me/?text=${Uri.encodeComponent(body)}');
}

/// Email · `mailto:` intent URL with subject + body pre-filled.
///
/// Shape: `mailto:?subject=<enc subject>&body=<enc body>`. No recipient is
/// populated — the practitioner picks the contact on-device.
///
/// Subject and body are URL-encoded separately because `encodeComponent`
/// would otherwise double-encode the `&` delimiter and the `=` signs.
/// Newlines survive via `%0A` which every mail client reconstructs into
/// real line breaks.
Uri buildEmailMailtoUri(ShareKitSlots slots) {
  final subject = Uri.encodeComponent(buildEmailSubject());
  final body = Uri.encodeComponent(buildEmailBody(slots));
  return Uri.parse('mailto:?subject=$subject&body=$body');
}
