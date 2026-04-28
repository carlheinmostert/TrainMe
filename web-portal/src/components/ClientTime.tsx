'use client';

import { useEffect, useState } from 'react';

/**
 * ClientTime — render an ISO timestamp in the practitioner's browser-local TZ.
 *
 * Wave 39.4 P1: previously the audit page pinned timestamps to UTC via
 * `fmtDate()` because the Dart side was emitting unmarked-local strings.
 * Once Dart emits proper UTC (Wave 39.4 M5 — companion mobile PR), the
 * portal should render in the practitioner's browser-local TZ — that's
 * what they expect when reading their wall clock.
 *
 * SSR + first-paint fallback uses the same UTC formatter the audit page
 * shipped before, so the pre-hydration window matches what users were
 * already seeing. Once hydrated, we re-render in browser-local TZ.
 *
 * No new dependencies — `Intl.DateTimeFormat` does this natively.
 */
export function ClientTime({ ts }: { ts: string }) {
  const [text, setText] = useState(() => fmtUtcFallback(ts));
  useEffect(() => {
    try {
      setText(
        new Date(ts).toLocaleString(navigator.language, {
          dateStyle: 'medium',
          timeStyle: 'short',
        }),
      );
    } catch {
      // Keep SSR fallback on Intl errors.
    }
  }, [ts]);
  return <>{text}</>;
}

function fmtUtcFallback(iso: string): string {
  try {
    return new Date(iso).toLocaleString('en-ZA', {
      dateStyle: 'medium',
      timeStyle: 'short',
      timeZone: 'UTC',
    });
  } catch {
    return iso;
  }
}
