import Link from 'next/link';
import { HomefitLogo } from './HomefitLogo';

type Props = {
  /** Show the authenticated nav (Account link). Sign-out lives INSIDE
   *  the Account page — one destination for all account-level actions
   *  rather than a duplicate sign-out affordance in the header. */
  showSignOut?: boolean;
  /** Current practice context, passed through so nav links keep the selection. */
  practiceId?: string;
};

export function BrandHeader({ showSignOut = false, practiceId }: Props) {
  const accountHref = practiceId ? `/account?practice=${practiceId}` : '/account';

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
          <nav aria-label="Account">
            <Link
              href={accountHref}
              className="text-sm text-ink-muted transition hover:text-ink"
            >
              Account
            </Link>
          </nav>
        )}
      </div>
    </header>
  );
}
