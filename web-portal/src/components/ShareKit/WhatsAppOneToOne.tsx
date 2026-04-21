'use client';

import { useState } from 'react';

import { CopyButton } from './CopyButton';
import { OgPreview } from './OgPreview';
import {
  OpenInAppButton,
  WhatsAppOutboundGlyph,
} from './OpenInAppButton';
import type { LogShareEvent } from './useShareAnalytics';
import {
  buildWhatsAppOneToOne,
  buildWhatsAppOneToOneUrl,
  substituteColleagueName,
  type ShareKitSlots,
} from '@/lib/share-kit/templates';

/**
 * WhatsAppOneToOne — a copy-ready one-to-one message with an
 * auto-filled `{Colleague}` slot and the practitioner's referral link.
 *
 * The rendered message body is visually styled to resemble the
 * recipient's WhatsApp view (surface-raised card + brand-tint chip for
 * the `{Colleague}` placeholder + coral link). Clicking the Copy
 * button drops the message string onto the clipboard; "Open in
 * WhatsApp" fires a `wa.me/?text=…` intent.
 *
 * **Phase 2 addition** — a compact "Colleague's first name (optional)"
 * input sits above the action row. When populated, it substitutes the
 * `{Colleague}` slot live in both the rendered preview + the intent
 * URL + the clipboard payload; when empty, the literal placeholder
 * stays so the practitioner can edit post-paste. Voice-locked (R-06):
 * the label reads "Colleague's first name (optional)", never
 * "Recipient" / "Friend" / "Contact".
 */
export function WhatsAppOneToOne({
  slots,
  logEvent,
}: {
  slots: ShareKitSlots;
  /**
   * Wave 10 Phase 3 analytics callback. Omitted on surfaces that don't
   * want telemetry (unit tests, storybook); always passed from the main
   * `/network` composition. Optional so the component stays trivially
   * mockable.
   */
  logEvent?: LogShareEvent;
}) {
  const [name, setName] = useState('');

  // Trimmed view used for substitution — doesn't mutate the controlled
  // input value (so trailing spaces while typing don't wipe the cursor
  // position), just the derived payload.
  const trimmed = name.trim();
  const baseBody = buildWhatsAppOneToOne(slots);
  const rendered = substituteColleagueName(baseBody, trimmed);

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
          the {Colleague} slot highlighted (or substituted) and the URL
          coloured as a link. The clipboard / intent payload always
          tracks the live-substituted string. Copy is the Phase 1b
          product-pitch voice — keep in sync with buildWhatsAppOneToOne
          in templates.ts. */}
      <div className="whitespace-pre-wrap rounded-md border border-surface-border bg-surface-raised px-[18px] py-4 text-sm leading-relaxed text-ink">
        Hey{' '}
        {trimmed.length > 0 ? (
          <NameText>{trimmed}</NameText>
        ) : (
          <SlotChip>{`{Colleague}`}</SlotChip>
        )}
        , try homefit.studio — home care plans my clients actually follow.
        Created in-session, delivered on WhatsApp before they leave. Sign up
        through this and you land with 8 free credits on me:{' '}
        <LinkText>{slots.referralLink}</LinkText>
      </div>

      {/* Colleague's first name — optional live-substitution input.
          Kept compact (single row, 240px max) per the Phase 2 brief. */}
      <div className="flex flex-col gap-1.5">
        <label
          htmlFor="share-kit-colleague-name"
          className="font-mono text-[11px] uppercase tracking-wider text-ink-dim"
        >
          Colleague&apos;s first name (optional)
        </label>
        <input
          id="share-kit-colleague-name"
          type="text"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Sarah"
          maxLength={40}
          autoComplete="off"
          spellCheck={false}
          className="w-full max-w-[240px] rounded-md border border-surface-border bg-surface-raised px-3 py-2 text-sm text-ink placeholder:text-ink-dim focus:border-brand-tint-border focus:outline-none focus-visible:ring-2 focus-visible:ring-brand/40"
        />
      </div>

      <div className="flex flex-wrap items-center gap-3">
        <CopyButton
          getText={() => rendered}
          label="Copy message"
          copiedLabel="Copied!"
          ariaLabel="Copy WhatsApp one-to-one message"
          onCopy={
            logEvent
              ? () =>
                  logEvent('whatsapp_one_to_one', 'copy', {
                    colleague_name_substituted: trimmed.length > 0,
                  })
              : undefined
          }
        />
        <OpenInAppButton
          getHref={() => buildWhatsAppOneToOneUrl(slots, trimmed)}
          label="Open in WhatsApp"
          ariaLabel="Open WhatsApp with this message pre-filled"
          glyph={<WhatsAppOutboundGlyph />}
          target="_blank"
          rel="noopener noreferrer"
          onOpen={
            logEvent
              ? () =>
                  logEvent('whatsapp_one_to_one', 'open_intent', {
                    colleague_name_substituted: trimmed.length > 0,
                  })
              : undefined
          }
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

/**
 * Substituted name rendering — same chip footprint as <SlotChip/> but
 * solid-filled and un-mono, so the practitioner sees the personalised
 * message as "settled" rather than "still a placeholder".
 */
function NameText({ children }: { children: React.ReactNode }) {
  return (
    <span className="inline-block rounded-sm border border-brand-tint-border bg-brand-tint-bg px-1.5 py-0.5 text-sm font-semibold text-brand-light">
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
