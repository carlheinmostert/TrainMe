import Link from 'next/link';
import { PULSE_MARK_PATH, PULSE_MARK_VIEWBOX } from '@/lib/theme';

type Props = {
  /** Show the sign-out link (only on authenticated pages). */
  showSignOut?: boolean;
};

export function BrandHeader({ showSignOut = false }: Props) {
  return (
    <header className="border-b border-surface-border bg-surface-base/80 backdrop-blur">
      <div className="mx-auto flex max-w-5xl items-center justify-between px-6 py-4">
        <Link
          href="/"
          className="flex items-center gap-3 text-ink hover:text-brand-light transition"
          aria-label="homefit.studio home"
        >
          <svg
            viewBox={PULSE_MARK_VIEWBOX}
            className="h-7 w-10 text-brand"
            xmlns="http://www.w3.org/2000/svg"
            aria-hidden="true"
          >
            <path
              d={PULSE_MARK_PATH}
              fill="none"
              stroke="currentColor"
              strokeWidth="2.5"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
          <span className="font-heading text-lg font-semibold">
            homefit.studio
          </span>
        </Link>

        {showSignOut && (
          <form action="/auth/sign-out" method="post">
            <button
              type="submit"
              className="text-sm text-ink-muted hover:text-ink transition"
            >
              Sign out
            </button>
          </form>
        )}
      </div>
    </header>
  );
}
