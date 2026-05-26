'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import { getBrowserClient } from '@/lib/supabase-browser';
import {
  createPortalApi,
  EMPTY_BRAND_SKIN_STATE,
  type BrandSkinState,
} from '@/lib/supabase/api';

type Props = {
  practiceId: string;
};

/**
 * Top-of-page banner that surfaces only while the practice's brand-skin
 * subscription is in its 7-day grace window (past day 30, before day 37).
 *
 * Wave 4 / ADR-0029. Render shape:
 *   - Coral background, ink-primary text, single inline CTA "Renew now"
 *     pointing at /brand-skin/subscribe.
 *   - Hides itself when state.inGrace !== true. Hides when state.active
 *     is true (subscription is still healthy) or when state.active is
 *     false but in_grace is also false (full revert already happened —
 *     the chrome is already default coral so no banner needed).
 *
 * Loads state via `PortalApi.getBrandSkinState` on mount. Failures
 * resolve to the empty state, hiding the banner — silent because a
 * network blip should not paint a wrong "you're about to lapse" warning.
 *
 * Mounted by BrandHeader on every authenticated page so the warning
 * reaches the practitioner regardless of which surface they land on.
 */
export function BrandSkinLapseBanner({ practiceId }: Props) {
  const [state, setState] = useState<BrandSkinState>(EMPTY_BRAND_SKIN_STATE);
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    if (!practiceId) {
      setLoaded(true);
      return;
    }
    let cancelled = false;
    (async () => {
      try {
        const supabase = getBrowserClient();
        const portal = createPortalApi(supabase);
        const res = await portal.getBrandSkinState(practiceId);
        if (!cancelled) setState(res);
      } catch {
        // Silent fall-through to EMPTY_BRAND_SKIN_STATE — see component
        // docstring above.
      } finally {
        if (!cancelled) setLoaded(true);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [practiceId]);

  if (!loaded) return null;
  if (!state.inGrace) return null;

  const days = state.daysUntilLapse ?? 0;
  const dayLabel = days === 1 ? 'day' : 'days';

  return (
    <div className="border-b border-brand/40 bg-brand/10">
      <div className="mx-auto flex max-w-5xl flex-wrap items-center gap-3 px-4 py-3 text-sm sm:px-6">
        <span className="font-semibold text-brand">
          Your brand chrome reverts in {days} {dayLabel}.
        </span>
        <span className="text-ink-muted">
          Top up to keep your brand on every artifact you&rsquo;ve shared.
        </span>
        <Link
          href={`/brand-skin/subscribe?practice=${practiceId}`}
          className="ml-auto rounded-full bg-brand px-4 py-1.5 text-xs font-semibold text-surface-bg shadow hover:bg-brand-dark"
        >
          Renew now
        </Link>
      </div>
    </div>
  );
}
