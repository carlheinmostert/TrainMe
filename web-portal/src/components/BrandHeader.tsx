import Link from 'next/link';
import { HomefitLogo } from './HomefitLogo';

type Props = {
  /** Show the authenticated nav. Sign-out lives INSIDE the Account page —
   *  one destination for all account-level actions rather than a duplicate
   *  sign-out affordance in the header. */
  showSignOut?: boolean;
  /** Current practice context, passed through so nav links keep the selection. */
  practiceId?: string;
  /** True when the caller is an owner of the current practice. Gates the
   *  Members link (owner-only per the tenancy model). Pages that don't
   *  compute the role default to false, hiding the link — safe fallback
   *  per R-12.3 (nav hides features the caller can't use). */
  isOwner?: boolean;
};

/**
 * Top-of-page header for the web portal.
 *
 * R-02 (header purity): the only interactive content in the header is
 * the home link + primary nav. No page titles, breadcrumbs, or
 * action buttons — those live inside each page.
 *
 * R-12.3 (primary nav covers every destination): the nav enumerates
 * Clients, Credits, Network, Audit, Members, Account. Members is
 * gated to owners because practitioners can't invite. Every other
 * destination surfaces for every signed-in user.
 *
 * Practice propagation: nav links carry `?practice=<id>` when a
 * practice is selected so the destination opens in the same context.
 * Links fall back to the bare path when there's no practice (fresh
 * sign-in edge case).
 */
export function BrandHeader({
  showSignOut = false,
  practiceId,
  isOwner = false,
}: Props) {
  const qs = practiceId ? `?practice=${practiceId}` : '';

  // Clients is the primary workspace — sessions roll up beneath each
  // client on /clients/[id]. Without a practice, route through the
  // dashboard which redirects to a default selection.
  const clientsHref = practiceId ? `/clients${qs}` : '/dashboard';
  const creditsHref = practiceId ? `/credits${qs}` : '/credits';
  const networkHref = practiceId ? `/network${qs}` : '/dashboard';
  const auditHref = practiceId ? `/audit${qs}` : '/dashboard';
  const membersHref = practiceId ? `/members${qs}` : '/dashboard';
  const accountHref = practiceId ? `/account${qs}` : '/account';

  return (
    <header className="border-b border-surface-border bg-surface-base/80 backdrop-blur">
      <div className="mx-auto flex max-w-5xl items-center justify-between px-6 py-4">
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
          <nav
            aria-label="Primary"
            className="flex flex-wrap items-center gap-x-5 gap-y-2"
          >
            <NavLink href={clientsHref}>Clients</NavLink>
            <NavLink href={creditsHref}>Credits</NavLink>
            <NavLink href={networkHref}>Network</NavLink>
            <NavLink href={auditHref}>Audit</NavLink>
            {isOwner && <NavLink href={membersHref}>Members</NavLink>}
            <NavLink href={accountHref}>Account</NavLink>
          </nav>
        )}
      </div>
    </header>
  );
}

function NavLink({
  href,
  children,
}: {
  href: string;
  children: React.ReactNode;
}) {
  return (
    <Link
      href={href}
      className="text-sm text-ink-muted transition hover:text-ink"
    >
      {children}
    </Link>
  );
}
