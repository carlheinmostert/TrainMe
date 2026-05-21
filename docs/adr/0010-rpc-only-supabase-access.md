# All Supabase access goes through enumerated SECURITY DEFINER RPCs

Each surface has a single typed access layer — `app/lib/services/api_client.dart`, `web-portal/src/lib/supabase/api.ts`, `web-player/api.js` — that calls explicit SECURITY DEFINER RPCs. No client calls `from('table').select()` directly. RLS still enforces tenancy as defence-in-depth, and adding a new RPC is a deliberate, reviewable surface-area decision.
