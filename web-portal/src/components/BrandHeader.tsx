import Link from 'next/link';
import { HomefitLogo } from './HomefitLogo';
import { HeaderRightCluster } from './HeaderRightCluster';
import type { PracticeWithRole } from '@/lib/supabase/api';

type Props = {
  /** Show the right-cluster (practice switcher + account menu chip).
   *  False on auth landing pages where there's no signed-in user yet. */
  showSignOut?: boolean;
  /** Current practice context, passed through so the switcher carries the
   *  selection. Optional because pages without a resolved practice (sign-up,
   *  some auth states) still want to render the email chip. */
  practiceId?: string;
  /** True when the caller is an owner of the current practice. Retained
   *  on the prop surface for backwards compatibility with existing callers,
   *  but no longer drives any rendering — Wave 40 P1 retired the nav links
   *  that gated on this flag. The dashboard tiles ARE the menu. */
  isOwner?: boolean;
  /** Signed-in user's email (Wave 40 P2). Surfaced as the right-cluster
   *  chip label so the practitioner can confirm-at-a-glance which account
   *  is active. Empty string when no user is signed in. */
  userEmail?: string;
  /** Every practice the caller belongs to (Wave 40 P3). Powers the
   *  practice-switcher chip in the header right-cluster. Empty array
   *  when there's no signed-in user or the caller hasn't been bootstrapped
   *  into a practice yet. */
  practices?: PracticeWithRole[];
};

/**
 * Top-of-page header for the web portal.
 *
 * Wave 40 P1 retires the nav menu (Clients · Credits · Network · Audit ·
 * Members · Account) that previously sat in the header. The dashboard's
 * clickable stat tiles ARE the navigation; duplicating them here was
 * redundant chrome that crowded the right-cluster identity affordances.
 *
 * What's left in the header:
 *   - Logo + wordmark on the left → home link.
 *   - Right cluster: practice switcher chip + account menu chip
 *     (Wave 40 P2 / P3). The chips render on every signed-in surface so
 *     practitioners can switch context or sign out without bouncing
 *     through the dashboard.
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
  const accountHref = practiceId
    ? `/account?practice=${practiceId}`
    : '/account';

  return (
    <header className="border-b border-surface-border bg-surface-base/80 backdrop-blur">
      <div className="mx-auto flex max-w-5xl items-center justify-between gap-4 px-6 py-4">
        <Link
          href="/"
          className="flex items-center gap-3 text-ink hover:text-brand-light transition"
          aria-label="homefit.studio home"
        >
          <HomefitLogo className="h-7 w-auto" />
          <span className="font-heading text-lg font-semibold">
            homefit.studio
          </span>
        </Link>

        {showSignOut && (
          <HeaderRightCluster
            email={userEmail}
            practices={practices}
            selectedId={practiceId ?? null}
            accountHref={accountHref}
          />
        )}
      </div>
    </header>
  );
}
