/**
 * Validate a `?next=` query param before treating it as a post-sign-in
 * destination.
 *
 * Must be a same-origin app path: starts with a single `/` and is not a
 * protocol-relative URL (`//evil.example`). Anything else collapses to
 * the supplied fallback (defaults to /dashboard) so an attacker can't
 * smuggle a redirect through the `next` query param.
 *
 * Shared by:
 *   - `src/app/page.tsx`           (signed-in branch — Wave 32 fix)
 *   - `src/components/SignInGate.tsx` (post-password / magic-link)
 *   - `src/app/auth/callback/route.ts` (OAuth/PKCE callback)
 *
 * Keep these three call sites in lockstep — the credits-chip redirect
 * chain depends on every step honouring `?next=` identically.
 */
export function safeNext(
  raw: string | null | undefined,
  fallback: string = '/dashboard',
): string {
  if (!raw) return fallback;
  if (!raw.startsWith('/')) return fallback;
  if (raw.startsWith('//')) return fallback;
  return raw;
}
