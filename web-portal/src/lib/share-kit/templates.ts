/**
 * Share-kit message templates — Wave 6 Phase 1.
 *
 * Pure, deterministic string builders for the three share formats the
 * practitioner can copy to clipboard from the `/network` page. Kept in a
 * `lib/` module (not in a component) so they're:
 *
 *   - Trivially unit-testable (no React, no browser APIs).
 *   - Reusable by Phase 2 (wa.me intents, mailto: links) without
 *     duplicating the copy.
 *
 * Voice (R-06 + voice.md): peer-to-peer. Copy mirrors the mockup at
 * `docs/design/mockups/network-share-kit.html` exactly — no "referral",
 * "commission", "rebate", "payout", "downline". We use "free credits",
 * "on me", "visual home-exercise programmes".
 *
 * Intentionally NOT in scope for Phase 1:
 *   - Intent hrefs (wa.me / mailto:) — Phase 2.
 *   - Rendered email HTML — Phase 3 or later (mailto: is text-only anyway).
 *   - PNG captions — Phase 3.
 */

export type ShareKitSlots = {
  /** Practitioner's first name. Falls back to the email prefix if no
   *  display name is available on the Supabase user. Never empty — the
   *  page-level server component is responsible for the fallback. */
  firstName: string;
  /** Full practitioner name (first + last). Used in the email sign-off.
   *  Falls back to firstName if we can't derive a last name. */
  fullName: string;
  /** Practice display name (e.g. "carlhein@me.com Practice"). Used in
   *  the email sign-off line under the sender name. */
  practiceName: string;
  /** Full referral link, e.g. `https://manage.homefit.studio/r/K3JT7QR`. */
  referralLink: string;
};

/**
 * WhatsApp · one-to-one — short personal message.
 *
 * Shape mirrors the mockup msg-body verbatim. We deliberately leave the
 * `{Colleague}` slot as a literal placeholder (surrounded by curly braces)
 * so the practitioner can paste-and-replace in WhatsApp — Phase 2 may
 * wire a per-contact send flow that pre-fills it, but Phase 1 just
 * copies the message.
 *
 * A single newline at the end is omitted on purpose: WhatsApp's web
 * unfurl uses the trailing URL as the preview source, and trailing
 * whitespace sometimes breaks that on iOS.
 */
export function buildWhatsAppOneToOne(slots: ShareKitSlots): string {
  // The name is pulled for future expansion (e.g. "Hey, from {firstName}")
  // but the current mockup copy only uses it in the OG unfurl, not the
  // message body. Reference it so linters don't flag it as unused.
  void slots.firstName;
  return `Hey {Colleague}, try homefit.studio — home care plans my clients actually follow. Created in-session, delivered on WhatsApp before they leave. Sign up through this and you land with 8 free credits on me: ${slots.referralLink}`;
}

/**
 * WhatsApp · status / broadcast — punchier, unaddressed.
 *
 * Mirrors the mockup. No name slot. Short enough to fit inside a
 * WhatsApp status caption (140 chars) after the URL, which is the
 * primary surface this line is written for.
 */
export function buildWhatsAppBroadcast(slots: ShareKitSlots): string {
  return `Stop chasing clients on adherence. Let them see the plan. ${slots.referralLink}`;
}

/**
 * Email · subject line. Plain text, no trailing period. Matches the
 * mockup's email header field exactly.
 */
export function buildEmailSubject(): string {
  return `The tool I've been using for home programmes`;
}

/**
 * Email · body (plain-text). Hand-composed paragraphs from the mockup.
 *
 * `{Colleague}` stays as a literal placeholder in the greeting so the
 * practitioner can personalise once pasted into their mail client.
 *
 * Sign-off is built in: "Warmly," → `fullName` → `practiceName`. We
 * don't inject a blank line between the sign-off block and the practice
 * name because the mockup renders them as a tight trio.
 *
 * Line endings: `\n`. Gmail + Apple Mail both handle LF bodies fine
 * when pasted. We do NOT emit `\r\n` — Phase 2's mailto: intent would
 * URL-encode it identically, but LF is simpler in the clipboard.
 */
export function buildEmailBody(slots: ShareKitSlots): string {
  return [
    `Hi {Colleague},`,
    ``,
    `I've been using a tool called homefit.studio for the home programmes I send clients between sessions, and I thought you might get value from it too. It records the actual exercise during the session, converts it into a clean visual demo on the phone, and sends the client a link that works in any browser — no app install.`,
    ``,
    `The part that's made the biggest difference for me is that clients actually see what I'm asking them to do, instead of reading a list of names on paper. Adherence has genuinely improved. It also lets me check which plans have been opened, so I can tell who's keeping up before their next visit.`,
    ``,
    `If you want to try it, you can sign up through my link and the first 8 credits are on me:`,
    ``,
    slots.referralLink,
    ``,
    `Happy to walk you through it if you'd like — a quick call is usually enough to see whether it fits your practice.`,
    ``,
    `Warmly,`,
    slots.fullName,
    slots.practiceName,
  ].join('\n');
}

/**
 * Full email as one copy-to-clipboard string (subject + body joined).
 *
 * Email clients don't share a single copy-subject-and-body shortcut, so
 * the "Copy full email" button in the mockup copies a plain-text block
 * with a `Subject:` header at the top. The practitioner can split once
 * pasted.
 *
 * The Phase 2 "Open in mail client" button fires a real
 * `mailto:?subject=...&body=...` intent via `buildEmailMailtoUrl` — that
 * path bypasses this string entirely and encodes subject + body
 * separately.
 */
export function buildEmailFullCopy(slots: ShareKitSlots): string {
  return `Subject: ${buildEmailSubject()}\n\n${buildEmailBody(slots)}`;
}

/* ------------------------------------------------------------------ */
/*  Phase 2 — intent URL builders                                     */
/* ------------------------------------------------------------------ */

/**
 * Substitute the literal `{Colleague}` slot in a body with a real first
 * name. If `name` is empty / whitespace / undefined, the placeholder is
 * preserved verbatim so the practitioner can edit post-paste (or the
 * live preview keeps showing the slot chip).
 *
 * Exported so UI surfaces can mirror the substitution in rendered
 * previews — not a primary public API.
 */
export function substituteColleagueName(body: string, name?: string): string {
  const trimmed = name?.trim() ?? '';
  if (trimmed.length === 0) return body;
  return body.split('{Colleague}').join(trimmed);
}

/**
 * WhatsApp · one-to-one intent URL.
 *
 * Produces `https://wa.me/?text=<encoded body>`. No phone number: the
 * `wa.me` contact picker lets the practitioner pick the colleague
 * on-device, so the intent is agnostic to which conversation receives
 * the message.
 *
 * If `colleagueName` is passed, the `{Colleague}` placeholder in the
 * body is substituted before URL-encoding — the intent lands fully
 * personalised. When it's empty / absent, the literal placeholder
 * remains in the encoded body so the practitioner can edit in-app.
 *
 * We deliberately use `wa.me` rather than the
 * `https://api.whatsapp.com/send?text=…` variant — `api.whatsapp.com`
 * routes through a web splash page on desktop browsers that feels
 * sluggish next to the native-app hand-off `wa.me` gives us.
 */
export function buildWhatsAppOneToOneUrl(
  slots: ShareKitSlots,
  colleagueName?: string,
): string {
  const body = substituteColleagueName(
    buildWhatsAppOneToOne(slots),
    colleagueName,
  );
  return `https://wa.me/?text=${encodeURIComponent(body)}`;
}

/**
 * WhatsApp · status / broadcast intent URL.
 *
 * Same `wa.me/?text=...` shape as the one-to-one variant. The broadcast
 * body has no name slot so no substitution is needed.
 *
 * The caller may paste this into a WhatsApp status caption after the
 * contact picker, or into a broadcast list. Either way the body is the
 * payload.
 */
export function buildWhatsAppBroadcastUrl(slots: ShareKitSlots): string {
  const body = buildWhatsAppBroadcast(slots);
  return `https://wa.me/?text=${encodeURIComponent(body)}`;
}

/**
 * Email · `mailto:` intent URL with subject + body pre-filled.
 *
 * Shape: `mailto:?subject=<enc subject>&body=<enc body>`. No recipient
 * is populated — the practitioner picks the contact on-device.
 *
 * Subject and body are URL-encoded separately (not as one combined
 * `?subject=…&body=…` string) because `encodeURIComponent` would
 * otherwise double-encode the `&` delimiter and the `=` signs. Newlines
 * survive via `%0A` which every mail client reconstructs into real
 * line breaks.
 */
export function buildEmailMailtoUrl(slots: ShareKitSlots): string {
  const subject = encodeURIComponent(buildEmailSubject());
  const body = encodeURIComponent(buildEmailBody(slots));
  return `mailto:?subject=${subject}&body=${body}`;
}
