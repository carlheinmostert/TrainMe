# Data Access Seam Exceptions

This file documents temporary carve-outs for `tools/enforce_data_access_seams.py`.
The CI rule blocks any *new* direct Supabase usage outside seam files, while this
list tracks known legacy exceptions that still need cleanup.

## Approved seam files

- `app/lib/services/api_client.dart`
- `web-player/api.js`
- `web-portal/src/lib/supabase/api.ts`

## Current exceptions (2026-05-01)

### Flutter (`Supabase.instance.client` outside `api_client.dart`)

- None currently. Flutter app access now routes through `ApiClient`.

### Web player (`/rest/v1/` outside `api.js`)

- `web-player/middleware.js`
  - Edge middleware fetches plan metadata RPC for OG response shaping.
- `web-player/sw.js`
  - Service worker checks `/rest/v1/` path to apply network-first policy.

## Policy

- New direct-access occurrences fail CI immediately.
- Existing exceptions must stay listed in
  `tools/data_access_seam_exceptions.json` until removed in code.
- If you remove an exception in code, also remove its allowlist entry.
- If a new exception is absolutely required, document the reason in this file
  and add the exact allowlist entry in the JSON file in the same PR.
