import { cookies } from 'next/headers';
import { ACTIVE_PRACTICE_COOKIE } from './active-practice';

/**
 * Resolve the active practice ID for a server page.
 *
 * Resolution order:
 *   1. Explicit `?practice=` query-param (set by in-portal Links and the
 *      mobile-app deeplink before middleware strips it).
 *   2. `hf_active_practice` cookie set by edge middleware on the last
 *      app→portal handoff.
 *
 * Returns an empty string when neither source has a value — callers are
 * expected to redirect to /dashboard in that case so a practice can be
 * selected.
 *
 * This extracts the three-line cookie-resolution pattern that was
 * duplicated verbatim in clients/, clients/[id]/, audit/, members/,
 * credits/, and dashboard/ pages.
 */
export async function resolveActivePractice(
  practiceFromParam: string | undefined,
): Promise<string> {
  const cookieStore = await cookies();
  const cookiePractice = cookieStore.get(ACTIVE_PRACTICE_COOKIE)?.value ?? '';
  return practiceFromParam ?? cookiePractice;
}
