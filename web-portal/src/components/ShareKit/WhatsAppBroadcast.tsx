'use client';

import { CopyButton } from './CopyButton';
import { OgPreview } from './OgPreview';
import {
  OpenInAppButton,
  WhatsAppOutboundGlyph,
} from './OpenInAppButton';
import type { LogShareEvent } from './useShareAnalytics';
import {
  buildWhatsAppBroadcast,
  buildWhatsAppBroadcastUrl,
  type ShareKitSlots,
} from '@/lib/share-kit/templates';

/**
 * WhatsAppBroadcast — copy-ready punchier line for WhatsApp status /
 * broadcast list use. No name slot; the referral link is appended
 * verbatim at the end.
 *
 * Visually mirrors the one-to-one card so the /network grid reads as
 * a set. The OG unfurl preview is shared with the one-to-one variant
 * but with a different kicker/title pair.
 *
 * **Phase 2 addition** — a secondary "Open in WhatsApp" CTA sits
 * beside the copy button. It fires `wa.me/?text=…` with the broadcast
 * body pre-filled; the practitioner picks the destination (status
 * caption / broadcast list / group) on-device.
 */
export function WhatsAppBroadcast({
  slots,
  logEvent,
}: {
  slots: ShareKitSlots;
  /**
   * Wave 10 Phase 3 analytics callback. See `<WhatsAppOneToOne/>` for
   * the same pattern. Optional — the card works fine without it.
   */
  logEvent?: LogShareEvent;
}) {
  const rendered = buildWhatsAppBroadcast(slots);

  return (
    <article className="flex flex-col gap-4 rounded-lg border border-surface-border bg-surface-base p-6">
      <header className="flex items-center gap-2.5">
        <FormatIcon>
          <BroadcastGlyph />
        </FormatIcon>
        <div>
          <h3 className="m-0 font-heading text-base font-bold tracking-tight">
            WhatsApp · status / broadcast
          </h3>
          <p className="m-0 -mt-0.5 text-xs text-ink-dim">
            Punchier, no name slot
          </p>
        </div>
        <span className="ml-auto font-mono text-[11px] uppercase tracking-wider text-ink-dim">
          Copy
        </span>
      </header>

      <div className="whitespace-pre-wrap rounded-md border border-surface-border bg-surface-raised px-[18px] py-4 text-sm leading-relaxed text-ink">
        Stop chasing clients on adherence. Let them see the plan.{' '}
        <LinkText>{slots.referralLink}</LinkText>
      </div>

      <div className="flex flex-wrap items-center gap-3">
        <CopyButton
          getText={() => rendered}
          label="Copy message"
          copiedLabel="Copied!"
          ariaLabel="Copy WhatsApp broadcast message"
          onCopy={
            logEvent ? () => logEvent('whatsapp_broadcast', 'copy') : undefined
          }
        />
        <OpenInAppButton
          getHref={() => buildWhatsAppBroadcastUrl(slots)}
          label="Open in WhatsApp"
          ariaLabel="Open WhatsApp with this message pre-filled"
          glyph={<WhatsAppOutboundGlyph />}
          target="_blank"
          rel="noopener noreferrer"
          onOpen={
            logEvent
              ? () => logEvent('whatsapp_broadcast', 'open_intent')
              : undefined
          }
        />
      </div>

      <OgPreview
        kicker="Visual programmes"
        title="Let them see the plan."
        sub="homefit.studio — capture once, share anywhere"
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

function LinkText({ children }: { children: React.ReactNode }) {
  return (
    <span className="break-all font-mono text-[13px] text-brand">
      {children}
    </span>
  );
}

function BroadcastGlyph() {
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
      <path d="M3 6v6M3 9h6l6-4v10L9 12M14 6v6" />
    </svg>
  );
}
