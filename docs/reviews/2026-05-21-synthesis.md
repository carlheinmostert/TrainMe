# 2026-05-21 Review synthesis — must-fix before consolidated test

Synthesises findings from four parallel reviews:
- [Code review](2026-05-21-code-review.md) — spec-vs-implementation
- [Security review](2026-05-21-security-review.md)
- [Frontend review](2026-05-21-frontend-review.md)
- [Quality review](2026-05-21-quality-review.md)

Totals: **4 critical, 13 high, 18 medium, 21 low**. Dedup applied — items flagged by multiple reviewers collapsed.

## Table of contents

- [Must-fix before testing](#must-fix-before-testing) — 4 critical + 3 high
- [Should-fix this week](#should-fix-this-week) — 10 high
- [Backlog](#backlog) — mediums + lows summary

---

## Must-fix before testing

These either break a test flow you're about to run, or silently violate a load-bearing contract (Safe Mode, RLS). One PR per fix is fine; can also bundle as `fix/post-review-criticals`.

### 1. Storage policy for `branding/{practice_id}/` is broken or unscoped — `S-C1`

**File:** `supabase/migrations/20260521150000_public_profile_v2.sql` (or a new migration).
**Symptom:** logo upload from `LogoUploader.tsx:55` writes to `branding/{practiceId}/logo.{ext}`. The existing `media` bucket policy at `supabase/migrations/20260515135502_storage_bucket_policies_recovery.sql:75` requires `(storage.foldername(name))[1]::uuid IN (SELECT id FROM plans)`. The cast `'branding'::uuid` raises `22P02` — so either uploads currently fail with a confusing error, OR a catch-all bypass exists and anyone authenticated can write anywhere in the bucket.
**Fix (~10 LOC migration):**

```sql
CREATE POLICY "Media branding owner write"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'media'
    AND (storage.foldername(name))[1] = 'branding'
    AND (storage.foldername(name))[2]::uuid IN (
      SELECT practice_id FROM practice_members
      WHERE trainer_id = auth.uid() AND role = 'owner'
    )
    AND coalesce(metadata->>'mimetype', '') IN ('image/png', 'image/jpeg')
  );
-- + parallel UPDATE + DELETE policies, same predicate.
```

**Effort:** 20 min. Drop SVG from MIME allow-list while you're there (covers M1 too).

### 2. Safe Mode republish leak — `S-C2`

**File:** `app/lib/services/upload_service.dart:2156` + `:2197` + photo paths `:2453, :2470`.
**Symptom:** the fast-path early-returns when `rawArchiveUploadedAt != null`. If a capture was published WITHOUT Safe Mode, then the polygon is added and re-publish happens, the existing rows skip upload — cloud retains the un-blurred raw forever.
**Fix:**

```dart
final useSafeVariant = exercise.safeModeActive == true
    && exercise.safeRawFilePath != null;
// Force re-upload when safe variant should override the current cloud blob.
if (useSafeVariant) {
  // ignore existing rawArchiveUploadedAt; upsert via the safe path
} else if (exercise.rawArchiveUploadedAt != null) {
  continue; // existing fast-path behaviour
}
```

**Effort:** 30 min including a paired video + photo branch test.

### 3. Photo Safe Mode silent un-blurred fallback — `Q-C1`

**File:** `app/lib/services/upload_service.dart:2429`.
**Symptom:** `absRaw = useSafeVariant ? (exercise.absoluteSafeRawFilePath ?? exercise.absoluteRawFilePath) : exercise.absoluteRawFilePath;` — when the safe file is set in SQLite but missing on disk (iCloud-offloaded, manual prune, converter wrote DB but failed to flush), this silently uploads the un-blurred photo. Video sibling at `:2178` correctly skips.
**Fix:** drop the `??` fallback. Mirror the video branch:

```dart
final absRaw = useSafeVariant
    ? exercise.absoluteSafeRawFilePath
    : exercise.absoluteRawFilePath;
if (absRaw == null || !await File(absRaw).exists()) {
  debugPrint('skip photo upload: safe variant missing');
  continue;
}
```

**Effort:** 15 min.

### 4. Literal `{' '}` JSX-escape text on `/v/{slug}` — `F-C1`

**File:** `web-player/v.html:90-91`.
**Symptom:** the fine-print paragraph reads literally `… have bystanders automatically obscured. See{' '} <a …>what we share</a>{' '} for the full privacy story.` Visible regression on every public profile page.
**Fix:** replace each `{' '}` with a single space character. One commit.
**Effort:** 2 min.

### 5. LogoUploader race + no success state + swallowed errors — `Q-H4` + `F-H2`

**File:** `web-portal/src/app/public-profile/LogoUploader.tsx:53-71`.
**Symptom:** two-file race (later upload wins on storage, but indicator may reflect the first one); no "Uploaded ✓" toast; `supabase.storage.upload` rejection lands in no catch.
**Fix:**

```tsx
const inflight = useRef<{ token: number } | null>(null);
const handleFile = async (file: File) => {
  const token = Date.now();
  inflight.current = { token };
  try {
    const { error } = await supabase.storage.from('media').upload(path, file, ...);
    if (error) throw error;
    if (inflight.current?.token !== token) return; // a newer pick won
    const url = `${pub.publicUrl}?v=${token}`;
    onUploaded(url);
    setSavedAt(token); // SaveBar-style inline pill
  } catch (e) {
    setError(e instanceof Error ? e.message : 'Upload failed');
    console.error('[LogoUploader]', e);
  }
};
```

**Effort:** 30 min.

### 6. PremisesPolygonEditor drag closes over stale `vertices` — `F-H6`

**File:** `web-portal/src/components/PremisesPolygonEditor.tsx:177`.
**Symptom:** drag handler captures the `vertices` array at handler-creation time. Single-pin drags work, but `Clear` / `Undo` / programmatic mutation mid-drag desyncs.
**Fix:**

```tsx
const verticesRef = useRef(vertices);
useEffect(() => { verticesRef.current = vertices; }, [vertices]);
// inside marker.on('drag'):
const live = verticesRef.current.map(...);
```

**Effort:** 15 min.

### 7. Slug regex permits 1-char, hint promises "3-40" — `F-H1`

**File:** `web-portal/src/app/public-profile/IdentityPanel.tsx:21`.
**Fix:** `^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$` (mandatory tail).
**Effort:** 2 min.

**Subtotal for must-fix before testing: ~2 hours of focused work, all small + isolated.**

---

## Should-fix this week

Won't block your test but worth landing before the next staging→main promotion.

### Frontend (`F-*`)

- **F-H3** — Save flows use exception-driven control flow. Let unknown errors bubble; toast only typed `PublicProfileError`. Log unknown to console.
- **F-H4** — `TopProgressBar` click handler races pathname effect → flicker on instant-paint routes. Skip the "to 0" reset when already animating.
- **F-H5** — `v-logo` initials fallback has no `aria-label`. Set `setAttribute('aria-label', `${practiceName} logo`)` when rendering initials.

### Quality / error handling (`Q-*`)

- **Q-H2** — `hydrateTeam` swallows errors silently. Wrap in try/catch + `console.error` + show "Team unavailable" placeholder when RPC fails.
- **Q-H3** — `/v/{slug}` outer catch collapses 404 / 5xx / network into "not found". Distinguish 404 from transient errors.

### Security (`S-*`)

- **S-H1** — `find_premises_at` enables anonymous geofence enumeration. Drop `practice_id` from the return shape (mobile only needs the boolean + name); cap calls per IP at the Edge.
- **S-H2** — `report_premises` has no rate limit. Add a per-`premises_id`-per-IP cap via `reporter_fingerprint` + unique partial index on last 1h, OR move behind an Edge function with token-bucket rate-limit.
- **S-H3** — `captured_in_premises_id` is client-supplied + unvalidated. Inside `replace_plan_exercises`, validate `IN (SELECT id FROM practice_premises WHERE practice_id = v_practice_id)` per row.

---

## Backlog

Mediums + lows worth queueing into the next polish wave. Pasting headlines only — read the individual review docs for details.

**Security mediums:** drop SVG from `LogoUploader` ACCEPT (`S-M1`); `get_practice_public_members` falls back to email local-parts when display_name missing — POPIA-adjacent, change to `'Practitioner'` (`S-M2`); `delete_premises` / `upsert_premises` allow any member, tighten to owner-only to match `set_practice_public_profile` (`S-M3`); `contact_website` hero CTA missing `rel="noopener noreferrer nofollow"` (`S-M4`).

**Frontend mediums:** Specialties chip Tab order skips chips (`F-M1`); HTML5 color picker hover thrashes parent state — debounce 100ms or commit on blur (`F-M2`); WCAG 4.5:1 threshold misapplied to large-text contexts — split into 3:1 hard floor + 4.5:1 soft hint (`F-M3`); map mount fires 4 tile-server requests with no lazy gating (`F-M4`); `/public-profile` page lacks `force-dynamic` (defensive after May 17 env.ts incident) (`F-M5`); `mailto:` href not CR/LF-stripped (`F-M6`); `v.js` report-modal timers not cleared on navigation (`F-M7`).

**Quality mediums:** empty `catch (_) {}` with no logging at `upload_service.dart:1241, 2154` and `api.ts:2094-2099` — add debug logs (`Q-M1, Q-M2`); `BrandColorPicker` doesn't validate values from DB before binding (`Q-M3`); single-frame photo Safe Mode = binary pass/fail — UX-acceptable but document (`Q-M4`); `SafeModeRejection` doesn't emit on `_updateController` — Studio may show ghost rows until refresh (`Q-M5`).

**Code review mediums:** `api.ts`/`api_client.dart` `practice_members` direct selects pre-date V2 but were extended in this wave — introduce `list_my_practices_with_branding` RPC (`CR-M1`); orphaned `PracticeProfilePanel.tsx` — delete in next cleanup wave (`CR-M2`).

**Test-script clean-ups:** items 84/86/91 in section K require Supabase Studio + shell access — flag as technical-verifier-only in the script preamble (`CR-L3` + `Q-L1`).

**Lows / observations** (21 items): pre-existing CSP `'unsafe-inline'`, screen-reader announcements on consent banner, focus-visible rings on contact rows, bundle size note on `v.html`/`v.js` in `app/assets/web-player/`, idempotent_migration_test missing v40→v44 skip-path coverage, SafeModeRejection as typed exception is defensible, R-10 mobile parity goes via WebView (spec wording could be tightened). All deferred.

---

## Recommended dispatch

I can spawn one sub-agent with the 7 must-fix items as a single PR (`fix/post-review-criticals`) targeting `staging`. ~2 hours wall time. After it lands, the consolidated test list in `docs/test-scripts/2026-05-21-safe-mode.md` is the entry surface.

Alternative: skip the synthesis-spawned fix and start testing now, taking the 4 criticals as known-fail items to walk through deliberately. Slower but you'd see the bugs first-hand which is useful for verifying the fixes later.

Which way?
