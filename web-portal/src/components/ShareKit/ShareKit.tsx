'use client';

import { EmailCard } from './EmailCard';
import { PngShareCard } from './PngShareCard';
import { TaglineHelper } from './TaglineHelper';
import { WhatsAppBroadcast } from './WhatsAppBroadcast';
import { WhatsAppOneToOne } from './WhatsAppOneToOne';
import { useShareAnalytics } from './useShareAnalytics';
import type { ShareKitSlots } from '@/lib/share-kit/templates';

/**
 * ShareKit — Wave 6 Phase 1 surface on `/network`.
 *
 * Composes three copy-ready pitch templates (WhatsApp 1:1, WhatsApp
 * broadcast, Email) and the Phase 3 PNG share card. The hero "share
 * code chip" + "your network" heading live on the page shell so this
 * component stays focused on the formats.
 *
 * **Phase scope:**
 *   - Phase 1: render templates, copy-to-clipboard, toast.
 *   - Phase 2: wa.me / mailto: intents + per-channel "Open in app" buttons.
 *   - Phase 3 (Wave 10): PNG render + QR code + download + clipboard-image,
 *     plus `share_events` analytics on every share action.
 *
 * Now a client component so every card can share a single
 * `useShareAnalytics` hook handle — analytics events are fire-and-forget
 * per the Wave 10 brief.
 *
 * Voice lock: peer-to-peer R-06. Copy inherited from the mockup at
 * `docs/design/mockups/network-share-kit.html` — do not paraphrase
 * without running it through voice.md.
 */
export function ShareKit({
  slots,
  practiceId,
  referralCode,
  practitionerFullName,
  practiceName,
}: {
  slots: ShareKitSlots;
  practiceId: string;
  referralCode: string | null;
  practitionerFullName: string;
  practiceName: string;
}) {
  const logEvent = useShareAnalytics(practiceId);
  return (
    <div className="space-y-12">
      {/* Section 01 — WhatsApp formats side by side */}
      <section aria-labelledby="share-kit-whatsapp">
        <SectionHead
          eyebrow="Section 01"
          id="share-kit-whatsapp"
          title="Best for quick WhatsApp sends"
          description="Two WhatsApp formats — a short personal message for a colleague you know by name, or a punchier line for your status / broadcast list. Copy, paste, send. The unfurl preview is what they'll see."
        />
        <div className="grid grid-cols-1 gap-5 lg:grid-cols-2">
          <WhatsAppOneToOne slots={slots} logEvent={logEvent} />
          <WhatsAppBroadcast slots={slots} logEvent={logEvent} />
        </div>
      </section>

      {/* Section 02 — Email */}
      <section aria-labelledby="share-kit-email">
        <SectionHead
          eyebrow="Section 02"
          id="share-kit-email"
          title="When you want to write something longer"
          description="A four-paragraph introduction for colleagues you'd rather email than message. Full copy pre-written — subject line, body, and sign-off auto-filled from your profile."
        />
        <EmailCard slots={slots} logEvent={logEvent} />
      </section>

      {/* Section 03 — PNG share card (Wave 10 Phase 3) */}
      <section aria-labelledby="share-kit-png">
        <SectionHead
          eyebrow="Section 03"
          id="share-kit-png"
          title="Print · social · profile"
          description="A branded image card with your name, practice, and QR code. Download it as PNG for a WhatsApp status, an Instagram story, a business-card reprint, or your email signature."
        />
        <PngShareCard
          practiceId={practiceId}
          practitionerName={practitionerFullName}
          practiceName={practiceName}
          referralCode={referralCode}
          referralLink={slots.referralLink}
        />

        {/* Tagline helper — small surface below the PNG, for places a
            full image won't fit (email footer, forum profile, etc.). */}
        <TaglineHelper referralLink={slots.referralLink} logEvent={logEvent} />
      </section>
    </div>
  );
}

function SectionHead({
  eyebrow,
  id,
  title,
  description,
}: {
  eyebrow: string;
  id: string;
  title: string;
  description: string;
}) {
  return (
    <div className="mb-5">
      <div className="text-[11px] font-semibold uppercase tracking-wider text-brand">
        {eyebrow}
      </div>
      <h2
        id={id}
        className="mt-1 font-heading text-[22px] font-bold tracking-tight text-ink"
      >
        {title}
      </h2>
      <p className="mt-1 max-w-[640px] text-sm text-ink-muted">
        {description}
      </p>
    </div>
  );
}
