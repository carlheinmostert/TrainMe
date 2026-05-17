'use client';

import { createBrowserClient } from '@supabase/ssr';
import type { Database } from './supabase/database.types';
import { supabaseAnonKey, supabaseUrl } from './env';

// A5 + C7 (HARDCODED-AUDIT-2026-05-12) — strict-fail. The previous
// `?? 'https://yrwcofhovrcydootivjx.supabase.co'` /
// `?? 'placeholder-anon-key'` fallbacks silently routed misconfigured
// staging deploys to prod. `requireEnv` returns a build-phase placeholder
// during `next build` so first-time Vercel project creation still
// succeeds; runtime evaluation throws if either var is missing.
const SUPABASE_URL = supabaseUrl();
const SUPABASE_ANON_KEY = supabaseAnonKey();

// Typing the client with `Database` means `supabase.from('plans')` returns a
// typed row shape and `supabase.rpc('consume_credit', { ... })` rejects
// unknown parameter names at compile time. The 2026-04-18 `plan_id` →
// `p_plan_id` rename would have been a typecheck error here instead of a
// silent 500.
export function getBrowserClient() {
  return createBrowserClient<Database>(SUPABASE_URL, SUPABASE_ANON_KEY);
}
