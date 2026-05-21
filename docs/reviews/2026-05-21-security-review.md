# Security Review — 2026-05-21 (staging vs main)

Scope: PRs #389–#402 (Safe Mode + Public Profile v2 + map editor UX). Diff
range `origin/main..origin/staging` (commits a7d39c8 ← b219370).

## Table of Contents

- [Critical](#critical)
- [High](#high)
- [Medium](#medium)
- [Low / observation](#low--observation)

## Critical

**C1. `media` bucket has no INSERT policy for the `branding/{practice_id}/` prefix — logo upload is broken and/or unscoped.** `supabase/migrations/20260515135502_storage_bucket_policies_recovery.sql:75` requires `(storage.foldername(name))[1]::uuid IN (SELECT id FROM plans WHERE ...)`. `web-portal/src/app/public-profile/LogoUploader.tsx:55` uploads to `branding/{practiceId}/logo.{ext}`. Cast `'branding'::uuid` raises `22P02`. Either uploads fail closed (broken feature) or a service-role bypass exists somewhere that we haven't audited. Add a dedicated `CREATE POLICY "Media branding owner write"` keyed on `(storage.foldername(name))[1] = 'branding' AND (storage.foldername(name))[2]::uuid IN (SELECT practice_id FROM practice_members WHERE trainer_id = auth.uid() AND role = 'owner')`. Also require `metadata->>'mimetype' IN ('image/png','image/jpeg')` to drop SVG at the storage layer.

**C2. Safe Mode upload-swap can leak un-blurred raw to cloud.** `app/lib/services/upload_service.dart:2156` — the loop early-returns when `rawArchiveUploadedAt != null`. A capture published WITHOUT Safe Mode, then re-published after Safe Mode was enforced (e.g. premises polygon was added or `safe_mode_active` flipped), will skip the upload entirely; the cloud keeps the unblurred raw at `{practice}/{plan}/{exercise}.mp4` forever. Same bug at `:2197` and photo path `:2453,2470`. Fix: when `useSafeVariant && rawArchiveUploadedAt != null`, force re-upload (overwrite via `upsert: true`) rather than skipping. Equivalently, clear `rawArchiveUploadedAt` whenever `safe_mode_active` transitions true.

## High

**H1. `find_premises_at` enables anonymous geofence enumeration.** `supabase/migrations/20260521120000_safe_mode.sql:601` is granted to `anon` and returns `practice_id + premises_name` for ANY lat/lng inside an enforcing polygon. An attacker can grid-scan and harvest the full set of practice premises (name + practice_id + approximate bounds) — useful for client/competitor reconnaissance. Mitigations: drop the `practice_id` from the return shape (mobile only needs the boolean + name); cap calls per IP at the Edge (Vercel middleware or pg_net rate-limit table); or move behind `authenticated` and accept that anon mobile capture-time check breaks.

**H2. `report_premises` has no rate limit — report-spam DoS.** `supabase/migrations/20260521120000_safe_mode.sql:708` grants EXECUTE to `anon`; comment line 706 says "Rate-limited only by HTTP layer for MVP" but no HTTP layer rate-limit exists. A single attacker can fill `premises_reports` with millions of rows (500-char reason × unlimited). Add a per-`premises_id`-per-IP cap via a `reporter_fingerprint text` column + unique partial index on the last 1 hour, or move report submission behind an Edge Function with token-bucket rate-limiting.

**H3. `captured_in_premises_id` is client-supplied and unvalidated.** `supabase/migrations/20260521160000_safe_mode_completion.sql:133` accepts the value verbatim from `p_rows`. The FK in `20260521120000_safe_mode.sql:125` references `practice_premises(id)` globally — a member of practice A can stamp practice B's premises_id on their exercise (it just has to exist). Audit-trail integrity issue. Fix: inside `replace_plan_exercises`, validate `captured_in_premises_id IN (SELECT id FROM practice_premises WHERE practice_id = v_practice_id)` per row, or NULL it out.

## Medium

**M1. SVG logo upload allowed — script-bearing payload stored in public bucket.** `LogoUploader.tsx:16` accepts `image/svg+xml`. SVGs can carry `<script>` + event handlers. Rendered via `<img src>` they don't execute, BUT anyone who opens the raw `/storage/v1/object/public/media/branding/.../logo.svg` URL directly executes it in their browser origin (Supabase storage CDN origin). Drop SVG from `ALLOWED_MIMES` + `ACCEPT`; require raster (`image/png`, `image/jpeg`) only.

**M2. `get_practice_public_members` exposes email local-parts to anon.** `supabase/migrations/20260521151000_practice_public_members.sql:53` falls back to `split_part(u.email, '@', 1)` when `display_name` is missing. A practitioner who signed up as `john.smith.physio@gmail.com` and never set display_name surfaces "john.smith.physio" on the public `/v/{slug}` page. POPIA-adjacent. Fix: fall back to `'Practitioner'` (line 56's third coalesce arm) instead of the email local-part — drop the middle arm.

**M3. `delete_premises` / `upsert_premises` allow any practice member (not owner-only).** `supabase/migrations/20260521120000_safe_mode.sql:284,400` check `user_practice_ids()` membership, not `user_is_practice_owner`. UI is owner-gated but the RPC isn't. A practitioner with direct-API access can delete or rewrite their practice owner's premises. Tighten the membership check to owner-only to match `set_practice_public_profile`.

**M4. `contact_website` URL written to `<a href>` with permissive regex.** `web-player/v.js:88,92` accepts `^https?:\/\/` (no end-anchor, no scheme allow-list beyond http/https). A practitioner submitting `https://example.com` passes; the migration CHECK at `set_practice_public_profile` does the same regex. Combined with the lack of any path/host validation, an owner can set a phishing target as their "Visit" CTA on the public profile page. Add `nofollow noopener` to the rel attribute (line 140 has `noopener noreferrer` — but `noreferrer` is set on `c.href.startsWith('http')` not on `hero-cta`; line 88-94 sets `cta.href` without setting `rel`). Add `cta.rel = 'noopener noreferrer nofollow'` and `cta.target = '_blank'` explicitly.

## Low / observation

**L1. `'unsafe-inline'` on `script-src` in portal CSP.** `web-portal/vercel.json:11` — pre-existing, not introduced today, but worth noting now that the portal hosts an editor accepting practitioner-supplied URLs/text. Move inline Next.js bootstrap scripts to a hashed/nonced policy when feasible.

**L2. `get_plan_full` always emits `practice_name + brand_color + public_logo_url` even when `public_profile_listed=false`.** `supabase/migrations/20260521150000_public_profile_v2.sql:409` skips the listed filter intentionally. Fine for the canonical plan flow, but be aware that an unlisted practice's `brand_color` + raw `practice_name` are visible to any client who has a plan link. Intentional per design comment but should be documented in the privacy page.

**L3. Premises 1 km² + 12-vertex caps make ST_Contains cheap.** `find_premises_at` is safe from polygon-DoS even at scale; GIST index + small bbox = constant-time per call. No action.

**L4. `mailto:`/`wa.me/` URLs accept whatever DB stores.** `web-player/v.js:118,127` builds `mailto:` and `wa.me/` from `contact_email` / `contact_whatsapp`. DB only enforces length, not email shape. A practitioner storing `safe@x.com?subject=evil&body=...` lands a pre-filled mail composer. Limited blast radius (mailto). Add a basic `@` + dot check at the DB CHECK constraint level.
