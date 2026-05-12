import { createServerClient, type CookieOptions } from '@supabase/ssr';
import { cookies } from 'next/headers';
import type { Database } from './supabase/database.types';
import { supabaseAnonKey, supabaseUrl } from './env';

type CookieToSet = { name: string; value: string; options?: CookieOptions };

// A5 + C7 (HARDCODED-AUDIT-2026-05-12) — strict-fail at request runtime.
// `next build` gets a placeholder so the build doesn't crash before env
// vars are wired; the first request after a misconfigured deploy throws.
const SUPABASE_URL = supabaseUrl();
const SUPABASE_ANON_KEY = supabaseAnonKey();

// Factory for Server Components and Route Handlers. The `cookies()` call
// must stay inside the factory so each request gets a fresh binding.
export async function getServerClient() {
  const cookieStore = await cookies();

  // Typed with `Database` so `.from(...)` rows and `.rpc(...)` params are
  // compile-time checked. See the comment in `supabase-browser.ts` for the
  // 2026-04-18 rename that motivated this.
  return createServerClient<Database>(SUPABASE_URL, SUPABASE_ANON_KEY, {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet: CookieToSet[]) {
        try {
          for (const { name, value, options } of cookiesToSet) {
            cookieStore.set(name, value, options);
          }
        } catch {
          // setAll can throw in Server Components (read-only context).
          // That's fine — middleware will refresh the session on the next request.
        }
      },
    },
  });
}
