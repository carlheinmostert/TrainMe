'use client';

import { CopyButton } from './CopyButton';
import type { LogShareEvent } from './useShareAnalytics';

/**
 * TaglineHelper — small surface below the PNG share card for places an
 * image won't fit. Matches `.tagline-helper` in
 * `docs/design/mockups/network-share-kit.html`: label + tagline text +
 * copy button, on a single row that wraps on mobile.
 *
 * The copy payload is the Phase 1b-locked tagline string, followed by
 * the practitioner's referral link separated by an em-dash. That means
 * a colleague pasting it into a LinkedIn bio / WhatsApp "About" / email
 * signature gets both the pitch AND the destination in one line.
 *
 * Wave 10 analytics: on copy, fires `tagline_copy` / `copy`. No
 * open-intent pair because the tagline isn't tied to any specific
 * messaging app — it's the "any-surface" text. `code_copy` + `link_copy`
 * channels are reserved for hero-chip / direct-link copies when those
 * get wired in a future Wave.
 */
export function TaglineHelper({
  referralLink,
  logEvent,
}: {
  referralLink: string;
  logEvent: LogShareEvent;
}) {
  const taglineText = `Plans your client will love and follow. Ready before they leave. — ${referralLink.replace(/^https?:\/\//, '')}`;

  return (
    <div className="mt-5 flex flex-wrap items-center justify-between gap-3 rounded-md border border-surface-border bg-surface-raised px-4 py-3">
      <span className="font-mono text-[11px] uppercase tracking-wider text-ink-muted">
        Tagline
      </span>
      <span className="min-w-[200px] flex-1 text-sm text-ink">
        {taglineText}
      </span>
      <CopyButton
        getText={() => taglineText}
        label="Copy"
        copiedLabel="Copied!"
        variant="secondary"
        ariaLabel="Copy tagline with referral link"
        onCopy={() => logEvent('tagline_copy', 'copy')}
      />
    </div>
  );
}
