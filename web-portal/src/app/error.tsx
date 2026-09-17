'use client';

import Link from 'next/link';

/**
 * App-level error boundary for Next.js App Router.
 *
 * Catches unhandled errors in any Server Component beneath the root
 * layout — including Promise.all rejections from API calls in page
 * server components. Without this file, Next.js renders its own
 * unstyled error page. This gives a branded fallback and a recovery
 * path (retry or back to dashboard) instead of a dead end.
 *
 * `global-error.tsx` would additionally catch errors inside the root
 * layout itself; not added here because the layout is thin wiring code
 * unlikely to throw.
 */
export default function Error({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center px-6 py-16 text-center">
      <h1 className="font-heading text-2xl font-bold">Something went wrong</h1>
      <p className="mt-3 max-w-sm text-sm text-ink-muted">
        {error.message || 'An unexpected error occurred loading this page.'}
      </p>
      <div className="mt-8 flex gap-4">
        <button
          onClick={reset}
          className="rounded-md bg-brand px-4 py-2 text-sm font-medium text-white hover:bg-brand/90"
        >
          Try again
        </button>
        <Link
          href="/dashboard"
          className="rounded-md border border-ink-muted/30 px-4 py-2 text-sm font-medium hover:border-ink-muted/60"
        >
          Back to dashboard
        </Link>
      </div>
      {error.digest && (
        <p className="mt-6 font-mono text-xs text-ink-muted/50">
          {error.digest}
        </p>
      )}
    </main>
  );
}
