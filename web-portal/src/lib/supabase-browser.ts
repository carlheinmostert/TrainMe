'use client';

import { createBrowserClient } from '@supabase/ssr';

// Fallbacks prevent `next build` from crashing when env vars aren't present
// (e.g. during Vercel's first-time project creation, before env is set).
// At runtime, real env vars must be configured or auth will fail.
const SUPABASE_URL =
  process.env.NEXT_PUBLIC_SUPABASE_URL ??
  'https://yrwcofhovrcydootivjx.supabase.co';

const SUPABASE_ANON_KEY =
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? 'placeholder-anon-key';

export function getBrowserClient() {
  return createBrowserClient(SUPABASE_URL, SUPABASE_ANON_KEY);
}
