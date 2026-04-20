'use client';

import { CopyButton } from './CopyButton';
import { OgPreview } from './OgPreview';
import {
  buildWhatsAppOneToOne,
  type ShareKitSlots,
} from '@/lib/share-kit/templates';

/**
 * WhatsAppOneToOne — a copy-ready one-to-one message with an
 * auto-filled `{Colleague}` slot and the practitioner's referral link.
 *
 * The rendered message body is visually styled to resemble the
 * recipient's WhatsApp view (surface-raised card + brand-tint chip for
 * the `{Colleague}` placeholder + coral link). Clicking the Copy
 * button drops the unrendered template string onto the clipboard
 * — ie. `{Colleague}` is preserved so the practitioner can swap the
 * name in once they paste into WhatsApp.
 *
 * Phase 1 stops at clipboard. Phase 2 will add a secondary "Open in
 * WhatsApp" button that fires a `wa.me/?text=...` intent.
 */
export function WhatsAppOneToOne({ slots }: { slots: ShareKitSlots }) {
  const rendered = buildWhatsAppOneToOne(slots);

  return (
    <article className="flex flex-col gap-4 rounded-lg border border-surface-border bg-surface-base p-6">
      <header className="flex items-center gap-2.5">
        <FormatIcon>
          <WhatsAppGlyph />
        </FormatIcon>
        <div>
          <h3 className="m-0 font-heading text-base font-bold tracking-tight">
            WhatsApp · one-to-one
          </h3>
          <p className="m-0 -mt-0.5 text-xs text-ink-dim">
            Short personal message
          </p>
        </div>
        <span className="ml-auto font-mono text-[11px] uppercase tracking-wider text-ink-dim">
          Copy
        </span>
      </header>

      {/* Pre-rendered message body — we display a "pretty" version with
          the {Colleague} slot highlighted and the URL coloured as a
          link. The actual clipboard payload is the plain template
          string (via `buildWhatsAppOneToOne`). Copy is the Phase 1b
          product-pitch voice — keep in sync with buildWhatsAppOneToOne
          in templates.ts. */}
      <div className="whitespace-pre-wrap rounded-md border border-surface-border bg-surface-raised px-[18px] py-4 text-sm leading-relaxed text-ink">
        Hey <SlotChip>{`{Colleague}`}</SlotChip>, try homefit.studio —
        home care plans my clients actually follow. Created in-session,
        delivered on WhatsApp before they leave. Sign up through this and
        you land with 8 free credits on me:{' '}
        <LinkText>{slots.referralLink}</LinkText>
      </div>

      <div className="flex flex-wrap items-center gap-3">
        <CopyButton
          getText={() => rendered}
          label="Copy message"
          copiedLabel="Copied!"
          ariaLabel="Copy WhatsApp one-to-one message"
        />
      </div>

      {/* OG unfurl preview — static visual, not interactive. */}
      <OgPreview
        kicker={`From ${slots.fullName}`}
        title="Your first 8 credits are on me."
        sub="homefit.studio — visual home-exercise programmes"
      />
    </article>
  );
}

function FormatIcon({ children }: { children: React.ReactNode }) {
  return (
    <span className="inline-flex h-8 w-8 items-center justify-center rounded-sm bg-brand-tint-bg text-brand">
      {children}
    </span>
  );
}

function SlotChip({ children }: { children: React.ReactNode }) {
  return (
    <span className="inline-block rounded-sm border border-dashed border-brand-tint-border bg-brand-tint-bg px-1.5 py-0.5 font-mono text-xs tracking-wide text-brand-light">
      {children}
    </span>
  );
}

function LinkText({ children }: { children: React.ReactNode }) {
  return (
    <span className="break-all font-mono text-[13px] text-brand">
      {children}
    </span>
  );
}

function WhatsAppGlyph() {
  return (
    <svg
      viewBox="0 0 18 18"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      className="h-[18px] w-[18px]"
    >
      <path d="M9 1.5a7.5 7.5 0 0 0-6.6 11.1L1.5 16.5l4-0.9A7.5 7.5 0 1 0 9 1.5Z" />
      <path
        d="M6.2 6.5c0.3-0.7 0.9-0.8 1.3-0.5 0.5 0.4 0.8 1.5 0.3 2 -0.3 0.3-0.4 0.5-0.3 0.7 0.4 1 1.3 1.9 2.3 2.3 0.2 0.1 0.4 0 0.7-0.3 0.5-0.5 1.6-0.2 2 0.3 0.3 0.4 0.2 1-0.5 1.3-1.6 0.6-4-0.9-5.2-2.2-1.1-1.2-2.2-3-1.6-4.6Z"
        opacity="0.6"
      />
    </svg>
  );
}
