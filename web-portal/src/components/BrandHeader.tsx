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
 *
 * iPhone-portrait fix (2026-05-25):
 *   - `pt-[env(safe-area-inset-top)]` on the header pushes content
 *     below the iOS status bar zone (otherwise the brand lockup paints
 *     into the time / wifi / battery indicators in standalone Safari
 *     and PWA installs). Combined with `viewport-fit=cover` in the
 *     root layout's Viewport metadata, the inset resolves to a real
 *     pixel value on iPhone.
 *   - Lockup height is now responsive: `h-14 sm:h-16 md:h-20 lg:h-24`.
 *     On a 390px iPhone-portrait viewport the original `h-24` (96px)
 *     lockup left no room for the right-side identity cluster to sit
 *     alongside without overlap.
 *   - On `< md` the right-edge identity slot inside the brand row is
 *     hidden, and a sibling row below the brand renders the identity
 *     stack inline against the right edge instead. On `md+` the
 *     original absolute-right layout returns. Same `HeaderIdentityStack`
 *     instance in both placements so the practice-switcher / sign-out
 *     behaviour is identical.
 *   - Horizontal padding shrinks to `px-4` on narrow viewports so the
 *     back-link + brand lockup get a touch more horizontal real estate
 *     before truncation kicks in; the absolute back-link slot follows
 *     suit (`left-4 sm:left-6`).
 */
export function BrandHeader({
  showSignOut = false,
  practiceId,
  userEmail = '',
  practices = [],
}: Props) {
  return (
    <header className="border-b border-surface-border bg-surface-base/80 pt-[env(safe-area-inset-top)] backdrop-blur">
      {/* Brand row — preserves the original desktop layout exactly:
          relative container with absolute left back-link slot, centred
          lockup, and absolute right identity slot. The only narrow-
          viewport changes here are (a) the lockup shrinks (h-14 on
          `< sm`, h-16 on `< md`, h-20 on `< lg`, h-24 on `lg+`), and
          (b) the right identity slot hides on `< md` because the
          narrow-only identity row below renders it inline instead. */}
      <div className="relative mx-auto flex max-w-5xl items-center justify-center px-4 py-3 sm:px-6 sm:py-4">
        <div className="absolute inset-y-0 left-4 flex items-center sm:left-6">
          <Suspense fallback={null}>
            <HeaderBackLink />
          </Suspense>
        </div>

        <Link
          href="/"
          className="block text-ink transition hover:opacity-90"
          aria-label="homefit.studio home"
        >
          <HomefitLogoLockup className="h-14 w-auto sm:h-16 md:h-20 lg:h-24" />
        </Link>

        {showSignOut && (
          <div className="absolute inset-y-0 right-6 hidden items-center md:flex">
            <HeaderIdentityStack
              email={userEmail}
              practices={practices}
              selectedId={practiceId ?? null}
            />
          </div>
        )}
      </div>

      {/* Narrow-viewport identity row — surfaces below the brand on
          `< md` so the practitioner can still see who's signed in,
          switch practice, and sign out from iPhone-portrait. Hidden
          on `md+` where the absolute-right slot inside the brand row
          takes over. Same component renders both placements so the
          practice-switcher behaviour is identical. */}
      {showSignOut && (
        <div className="mx-auto flex max-w-5xl justify-end px-4 pb-3 sm:px-6 md:hidden">
          <HeaderIdentityStack
            email={userEmail}
            practices={practices}
            selectedId={practiceId ?? null}
          />
        </div>
      )}
    </header>
  );
}
