import { cookies } from 'next/headers';
import { ACTIVE_PRACTICE_COOKIE } from '@/lib/active-practice';

/**
 * Resolve the active practice ID from a search param and/or the cookie
 * set by middleware on the most recent app→portal handoff.
 *
 * Resolution order:
 *   1. Explicit `?practice=<uuid>` search param (in-portal link, mobile deep-link)
 *   2. `hf_active_practice` cookie (set + pinned by middleware once it strips
 *      the `?practice=` param — this is the load-bearing fallback for the
 *      `/dashboard tile → page` navigation chain)
 *
 * Returns `null` when neither source provides a value; callers should
 * redirect to `/dashboard` rather than issue RPCs with an empty ID.
 *
 * Previously each page inlined the same three-line resolution block.
 * This function is the single definition — update it here and all pages
 * pick up the change.
 */
export async function resolvePracticeId(
  practiceParam: string | undefined,
): Promise<string | null> {
  if (practiceParam) return practiceParam;
  const cookieStore = await cookies();
  return cookieStore.get(ACTIVE_PRACTICE_COOKIE)?.value ?? null;
}
