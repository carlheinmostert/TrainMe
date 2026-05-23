import Link from 'next/link';
import { HomefitLogoLockup } from './HomefitLogo';
import { HeaderIdentityStack } from './HeaderIdentityStack';
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
 *   - Identity stack stays anchored to the top-right corner via absolute
 *     positioning, so the centred lockup is free of layout pressure.
 *   - Header min-height of 160px gives the lockup breathing room.
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
 * + tenant-context. No page titles, breadcrumbs, or action buttons.
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
      <div className="relative mx-auto flex max-w-5xl items-center justify-center px-6 py-1">
        <Link
          href="/"
          className="block text-ink transition hover:opacity-90"
          aria-label="homefit.studio home"
        >
          <HomefitLogoLockup className="h-24 w-auto" />
        </Link>

        {showSignOut && (
          <div className="absolute right-6 top-2">
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
