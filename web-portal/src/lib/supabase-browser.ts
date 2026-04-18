'use client';

import { createBrowserClient } from '@supabase/ssr';
import type { Database } from './supabase/database.types';

// Fallbacks prevent `next build` from crashing when env vars aren't present
// (e.g. during Vercel's first-time project creation, before env is set).
// At runtime, real env vars must be configured or auth will fail.
const SUPABASE_URL =
  process.env.NEXT_PUBLIC_SUPABASE_URL ??
  'https://yrwcofhovrcydootivjx.supabase.co';

const SUPABASE_ANON_KEY =
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? 'placeholder-anon-key';

// Typing the client with `Database` means `supabase.from('plans')` returns a
// typed row shape and `supabase.rpc('consume_credit', { ... })` rejects
// unknown parameter names at compile time. The 2026-04-18 `plan_id` →
// `p_plan_id` rename would have been a typecheck error here instead of a
// silent 500.
export function getBrowserClient() {
  return createBrowserClient<Database>(SUPABASE_URL, SUPABASE_ANON_KEY);
}
