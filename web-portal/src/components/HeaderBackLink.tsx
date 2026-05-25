'use client';

import Link from 'next/link';
import { usePathname, useSearchParams } from 'next/navigation';

/**
 * HeaderBackLink — left-slot back arrow in BrandHeader.
 *
 * Hoists the per-page "<- Home" / "<- Premises" / "<- Credits" link out
 * of each page body and into the top bar. Mirror-symmetric to the
 * right-side HeaderIdentityStack:
 *
 *   [<- Back]                    [centered brand]                    [identity stack]
 *
 * The mapping is small enough to live inline. Routes not in
 * BACK_TARGETS render nothing in the left slot (the dashboard root has
 * no back link by design — there's nowhere to go back to).
 *
 * Practice context preservation: when the current URL carries a
 * `?practice=<id>` query string, the back href appends the same param
 * so the destination opens in the same practice context. This matches
 * the previous inline pattern in members/credits/account/network/
 * premises pages, and is harmless on pages that don't read the param
 * (the cookie carries the practice as a fallback).
 *
 * Prefix matching: /premises/[id] (any sub-route under /premises that
 * isn't /premises itself) routes back to /premises with label
 * "Premises" rather than "Home". Today only the one detail route
 * matches; new sub-routes get the same treatment automatically.
 *
 * Why a separate client component instead of inlining into BrandHeader:
 * BrandHeader is a server component (no 'use client' directive) so it
 * can stay in the server-render path and avoid shipping the practice-
 * switcher import chain twice. Keeping the pathname/searchParams hook
 * read in its own client island leaves the rest of the header
 * server-rendered.
 */

type BackTarget = { href: string; label: string };

/** Static map of path-to-back-target. */
const BACK_TARGETS: Record<string, BackTarget> = {
  '/premises': { href: '/dashboard', label: 'Home' },
  '/public-profile': { href: '/dashboard', label: 'Home' },
  '/safe-mode': { href: '/dashboard', label: 'Home' },
  '/privacy': { href: '/dashboard', label: 'Home' },
  '/getting-started': { href: '/dashboard', label: 'Home' },
  '/members': { href: '/dashboard', label: 'Home' },
  '/terms': { href: '/dashboard', label: 'Home' },
  '/credits': { href: '/dashboard', label: 'Home' },
  '/help/credits': { href: '/dashboard', label: 'Home' },
  '/account': { href: '/dashboard', label: 'Home' },
  '/network': { href: '/credits', label: 'Credits' },
};

/** Resolve the back target for the current pathname. */
function resolveBackTarget(pathname: string | null): BackTarget | null {
  if (!pathname) return null;

  // Exact match first (covers all the non-dynamic routes above).
  const exact = BACK_TARGETS[pathname];
  if (exact) return exact;

  // Prefix match for /premises/[id] — anything under /premises that
  // isn't /premises itself routes back to /premises.
  if (pathname.startsWith('/premises/') && pathname !== '/premises') {
    return { href: '/premises', label: 'Premises' };
  }

  // Anything else: no back link. Includes /, /dashboard, /clients,
  // /audit, /auth/*, /sign-up/*, /r/* — all of which either are root
  // surfaces or carry their own internal navigation.
  return null;
}

export function HeaderBackLink() {
  const pathname = usePathname();
  const search = useSearchParams();
  const target = resolveBackTarget(pathname);

  if (!target) return null;

  // Preserve the active practice query param across the back nav so
  // the destination opens in the same practice context. The cookie
  // is the long-term source of truth, but the URL param wins on the
  // initial server render.
  const practice = search?.get('practice');
  const href = practice
    ? `${target.href}?practice=${encodeURIComponent(practice)}`
    : target.href;

  return (
    <Link
      href={href}
      className="inline-flex items-center gap-1 truncate text-xs text-ink-muted transition hover:text-brand focus-visible:outline-none focus-visible:text-brand"
      aria-label={`Back to ${target.label}`}
    >
      <span aria-hidden="true">&larr;</span>
      <span>{target.label}</span>
    </Link>
  );
}
