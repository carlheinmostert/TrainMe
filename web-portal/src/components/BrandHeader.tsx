import { Suspense } from 'react';
import Link from 'next/link';
import { HomefitLogoLockup } from './HomefitLogo';
import { HeaderIdentityStack } from './HeaderIdentityStack';
import { HeaderBackLink } from './HeaderBackLink';
import type { PracticeWithRole } from '@/lib/supabase/api';

type Props = {
  /** Show the right-side identity stack (practitioner email + active
   *  practice + sign-out link). False on auth landing pages where
   *  there's no signed-in user yet. */
  showSignOut?: boolean;
  /** Current practice context, passed through so the switcher carries the
   *  selection. Optional because pages without a resolved practice (sign-up,
   *  some auth states) still want to render the email line. */
  practiceId?: string;
  /** True when the caller is an owner of the current practice. Retained
   *  on the prop surface for backwards compatibility with existing callers,
   *  but no longer drives any rendering — Wave 40 P1 retired the nav links
   *  that gated on this flag. The dashboard tiles ARE the menu. */
  isOwner?: boolean;
  /** Signed-in user's email. Rendered on the top line of the identity
   *  stack so the practitioner can confirm-at-a-glance which account is
   *  active. Empty string when no user is signed in. */
  userEmail?: string;
  /** Every practice the caller belongs to. Powers the practice-name
   *  chevron switcher in the identity stack. Empty array when there's
   *  no signed-in user or the caller hasn't been bootstrapped into a
   *  practice yet. */
  practices?: PracticeWithRole[];
};

/**
 * Top-of-page header for the web portal.
 *
 * Cosmetic pass (2026-05-22, centred-lockup iteration):
 *   - Lockup is pulled to the centre of the header and rendered large
 *     enough to be the visual hero of the strip. The brand mark earns
 *     the real-estate; nothing else competes with it on the centre line.
 *   - Identity stack stays anchored to the right edge via absolute
 *     positioning, vertically centred against the header height so the
 *     centred lockup is free of layout pressure and the right-side
 *     cluster optically aligns with the brand mark's midline.
 *   - Header padding equalised top + bottom (py-4) so the lockup has
 *     matching breathing room above and below (a tight bottom rule was
 *     reading as the lockup "sitting on" the divider).
 *
 * Signed off at `docs/design/mockups/portal-header-options.html`
 * (Option 1b · Final).
 *
 * Earlier pass kept the lockup top-left in a justify-between row; the
 * right side felt visually heavy and the centre was a void. Centring
 * the brand mark balances the header without inventing new graphic
 * language (the lockup IS the brand language).
 *
 * R-02 (header purity): the only interactive content remains identity
 * + tenant-context + the back-arrow shortcut. No page titles,
 * breadcrumbs, or action buttons.
 *
 * Back-arrow hoist (2026-05-25): the per-page `<- Home` / `<- Premises`
 * / `<- Credits` link previously rendered as inline JSX below the
 * header has been hoisted into the header's left slot, mirror-symmetric
 * to the right-side identity stack. The link target is resolved from
 * `usePathname()` inside `HeaderBackLink` — pages no longer need to
 * pass any prop. The dashboard root and auth surfaces render nothing
 * in the left slot (no back target).
 *
 * Practice propagation: callers that want their internal links to carry
 * the active practice append `?practice=<id>` themselves at the body
 * level; the header is now identity-only and doesn't render
 * practice-aware anchors.
 */
export function BrandHeader({
  showSignOut = false,
  practiceId,
  userEmail = '',
  practices = [],
}: Props) {
  return (
    <header className="border-b border-surface-border bg-surface-base/80 backdrop-blur">
      <div className="relative mx-auto flex max-w-5xl items-center justify-center px-6 py-4">
        {/* Left slot — back arrow. Mirror-symmetric to the right-side
            identity stack. HeaderBackLink decides per-route whether to
            render (dashboard root + auth surfaces render nothing).
            Wrapped in Suspense because HeaderBackLink reads
            useSearchParams() and statically-rendered pages (like
            /help/credits, /privacy, /terms) would otherwise fail
            prerender per the Next.js missing-suspense-with-csr-bailout
            rule. */}
        <div className="absolute inset-y-0 left-6 flex items-center">
          <Suspense fallback={null}>
            <HeaderBackLink />
          </Suspense>
        </div>

        <Link
          href="/"
          className="block text-ink transition hover:opacity-90"
          aria-label="homefit.studio home"
        >
          <HomefitLogoLockup className="h-24 w-auto" />
        </Link>

        {showSignOut && (
          <div className="absolute inset-y-0 right-6 flex items-center">
            <HeaderIdentityStack
              email={userEmail}
              practices={practices}
              selectedId={practiceId ?? null}
            />
          </div>
        )}
      </div>
    </header>
  );
}
