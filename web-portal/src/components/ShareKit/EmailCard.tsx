'use client';

import { CopyButton } from './CopyButton';
import {
  buildEmailBody,
  buildEmailFullCopy,
  buildEmailSubject,
  type ShareKitSlots,
} from '@/lib/share-kit/templates';

/**
 * EmailCard — four-paragraph professional introduction with
 * subject / body / signature auto-filled.
 *
 * Visually mirrors the mockup's `.email-block`: a two-column grid of
 * `To / Subject / Body` labels + values, followed by an action row.
 * Phase 1 ships one action — "Copy full email" — that drops a
 * `Subject: ...\n\n...body...` block onto the clipboard. Phase 2 adds
 * the "Open in mail client" button that fires a real mailto: intent
 * with subject + body pre-filled.
 *
 * `{Colleague}` / `{Colleague email}` slots are preserved literally in
 * both the display and clipboard output so the practitioner can
 * personalise once pasted.
 */
export function EmailCard({ slots }: { slots: ShareKitSlots }) {
  const body = buildEmailBody(slots);
  const subject = buildEmailSubject();
  const fullCopy = buildEmailFullCopy(slots);

  return (
    <article className="overflow-hidden rounded-lg border border-surface-border bg-surface-base">
      <header className="flex items-center gap-3 border-b border-surface-border p-5">
        <FormatIcon>
          <EmailGlyph />
        </FormatIcon>
        <div className="min-w-0 flex-1">
          <h3 className="m-0 font-heading text-base font-bold tracking-tight">
            Email · professional introduction
          </h3>
          <p className="m-0 mt-0.5 text-xs text-ink-dim">
            Subject + body + signature auto-filled
          </p>
        </div>
        <span className="font-mono text-[11px] uppercase tracking-wider text-ink-dim">
          Copy
        </span>
      </header>

      <div className="grid grid-cols-1 gap-x-5 gap-y-1 p-6 sm:grid-cols-[100px_1fr]">
        <FieldLabel>To</FieldLabel>
        <div className="text-sm text-ink-muted">
          <SlotChip>{`{Colleague email}`}</SlotChip>
        </div>

        <FieldLabel>Subject</FieldLabel>
        <div className="text-[15px] font-semibold text-ink">{subject}</div>

        <FieldLabel>Body</FieldLabel>
        <div className="space-y-3 text-sm leading-relaxed text-ink">
          {/* We render the body as hand-built paragraphs so the
              {Colleague} slot gets the chip treatment + the link gets
              its mono/coral styling. The actual clipboard string is
              the plain-text `body` built by `buildEmailBody`. */}
          <p>
            Hi <SlotChip>{`{Colleague}`}</SlotChip>,
          </p>
          <p>
            I&apos;ve been using a tool called homefit.studio for the home
            programmes I send clients between sessions, and I thought you
            might get value from it too. It records the actual exercise
            during the session, converts it into a clean visual demo on
            the phone, and sends the client a link that works in any
            browser — no app install.
          </p>
          <p>
            The part that&apos;s made the biggest difference for me is
            that clients actually <em>see</em> what I&apos;m asking them
            to do, instead of reading a list of names on paper. Adherence
            has genuinely improved. It also lets me check which plans
            have been opened, so I can tell who&apos;s keeping up before
            their next visit.
          </p>
          <p>
            If you want to try it, you can sign up through my link and
            the first 8 credits are on me:
          </p>
          <p>
            <span className="break-all font-mono text-[13px] text-brand">
              {slots.referralLink}
            </span>
          </p>
          <p>
            Happy to walk you through it if you&apos;d like — a quick
            call is usually enough to see whether it fits your practice.
          </p>
          <div className="border-t border-dashed border-surface-border pt-3 text-sm text-ink-muted">
            <p className="m-0">Warmly,</p>
            <p className="m-0 font-semibold text-ink">{slots.fullName}</p>
            <p className="m-0 text-xs text-ink-dim">{slots.practiceName}</p>
          </div>
          {/* Screen-reader-only copy of the plain-text body so users
              who need to select-and-copy manually have the raw text
              available without the chip markup. Hidden visually but
              selectable. */}
          <textarea
            readOnly
            value={body}
            aria-label="Email body plain text"
            className="sr-only"
          />
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-3 border-t border-surface-border bg-surface-raised/35 px-6 py-4">
        <CopyButton
          getText={() => fullCopy}
          label="Copy full email"
          copiedLabel="Copied!"
          ariaLabel="Copy full email (subject + body)"
        />
        <span className="font-mono text-[11px] uppercase tracking-wider text-ink-dim">
          Includes subject + body + signature
        </span>
      </div>
    </article>
  );
}

function FormatIcon({ children }: { children: React.ReactNode }) {
  return (
    <span className="inline-flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-sm bg-brand-tint-bg text-brand">
      {children}
    </span>
  );
}

function FieldLabel({ children }: { children: React.ReactNode }) {
  return (
    <div className="pt-1.5 font-mono text-[11px] uppercase tracking-wider text-ink-dim">
      {children}
    </div>
  );
}

function SlotChip({ children }: { children: React.ReactNode }) {
  return (
    <span className="inline-block rounded-sm border border-dashed border-brand-tint-border bg-brand-tint-bg px-1.5 py-0.5 font-mono text-xs tracking-wide text-brand-light">
      {children}
    </span>
  );
}

function EmailGlyph() {
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
      <rect x="2.5" y="4" width="13" height="10" rx="1.5" />
      <path d="M2.5 5 L9 10 L15.5 5" />
    </svg>
  );
}
