# Public Profile v2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the Public Profile v2 design — practice-level branding (logo + brand color) cascaded into the client-facing Web Player, plus an "advertising-grade" `/v/{slug}` page and a new editor at `/public-profile`. Single PR against `staging` on branch `feat/public-profile-v2`.

**Architecture:** Six new nullable columns on `practices` + widened RPCs (preserving every existing `RETURNS TABLE` column per the column-shadowing rule). New portal page at `/public-profile` with two collapsed `<details>` sections (Branding, Identity & directory) plus a new dashboard tile. Web Player reads `brand_color` + `public_logo_url` from `get_plan_full` and sets CSS variables before paint; persistent top-bar logo slot in the plan bar. R-10 mobile twin in `plan_preview_screen.dart` + Studio Preview tab so client preview parity is preserved.

**Tech Stack:** Supabase PostgreSQL 17 + Branching, Next.js 15 App Router (web-portal), vanilla JS + CSS variables (web-player), Flutter (mobile), Vercel deploy.

**Spec:** [docs/specs/2026-05-21-public-profile-v2-design.md](../specs/2026-05-21-public-profile-v2-design.md)
**Mockup:** [docs/design/mockups/public-profile-v2.html](../design/mockups/public-profile-v2.html)

---

## File structure

### New files
- `supabase/migrations/20260521150000_public_profile_v2.sql` — migration: 6 columns + constraints + RPC widenings.
- `web-portal/src/app/public-profile/page.tsx` — owner-edit page route (collapsed accordions).
- `web-portal/src/app/public-profile/BrandingPanel.tsx` — branding accordion contents.
- `web-portal/src/app/public-profile/IdentityPanel.tsx` — identity & directory accordion contents.
- `web-portal/src/app/public-profile/LogoUploader.tsx` — drag-drop + replace + remove.
- `web-portal/src/app/public-profile/BrandColorPicker.tsx` — color picker + live preview strip + WCAG tip.
- `web-portal/src/app/public-profile/SpecialtiesEditor.tsx` — chip add/remove.
- `web-portal/src/app/public-profile/SaveBar.tsx` — explicit Save button + inline pill confirmation.
- `web-portal/src/components/PublicProfileTile.tsx` — dashboard tile.
- `docs/plans/2026-05-21-public-profile-v2-plan.md` — this file.

### Modified files
- `web-portal/src/lib/supabase/api.ts` — extend `PortalApi` with `getPublicProfile`, widen `setPracticePublicProfile`.
- `web-portal/src/lib/supabase/database.types.ts` — regenerate after migration applies on staging.
- `web-portal/src/app/dashboard/page.tsx` — slot in `PublicProfileTile`.
- `web-portal/src/components/PremisesListPanel.tsx` — remove the Public profile `<details>` block.
- `web-player/styles.css` — `#FF6B35` literal sweep → `var(--c-brand)`; new `--c-brand-soft` + `--c-brand-strong` defaults.
- `web-player/api.js` — `get_plan_full` response now includes `brand_color` + `public_logo_url`; expose in payload.
- `web-player/app.js` — set CSS variables on plan load; populate top-bar logo slot.
- `web-player/index.html` (or template) — add `<img class="plan-bar-logo">` slot.
- `web-player/v.html` + `web-player/v.js` + `web-player/styles.css` (v-* block) — hero CTA + tagline + specialties + contact list + practitioners section.
- `app/lib/screens/plan_preview_screen.dart` — Flutter player parity: brand color override + top-bar logo.
- `app/lib/services/unified_preview_scheme_bridge.dart` (or equivalent) — pass `brand_color` + `public_logo_url` into the WebView payload.
- `docs/test-scripts/2026-05-21-safe-mode.md` — append section J (Public Profile v2).

---

## Task 0: Pre-flight discovery

**Files:** none modified — capture state only.

This task gathers the ground-truth state from the live staging DB + the current codebase so the migration and CSS edits don't blow up later. The column-preservation rule (CLAUDE.md gotchas) bites when an RPC body in a migration drops fields that exist in production today.

- [ ] **Step 1: Capture `get_plan_full` signature from staging**

Run via Supabase MCP `execute_sql` against project `vadjvkmldtoeyspyoqbx`:

```sql
SELECT pg_get_functiondef(p.oid)
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public' AND p.proname = 'get_plan_full';
```

Save the output verbatim. The full column list in `RETURNS TABLE(...)` is what the migration must preserve in Task 1.

- [ ] **Step 2: Capture `get_practice_profile` signature**

Same approach:

```sql
SELECT pg_get_functiondef(p.oid)
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public' AND p.proname = 'get_practice_profile';
```

- [ ] **Step 3: Capture `set_practice_public_profile` signature**

```sql
SELECT pg_get_functiondef(p.oid)
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public' AND p.proname = 'set_practice_public_profile';
```

- [ ] **Step 4: Inventory `#FF6B35` literals in the web player**

```bash
grep -nE "#FF6B35|#ff6b35" web-player/styles.css web-player/v.html web-player/v.js web-player/app.js web-player/lobby.js
```

Note every line. Task 10 turns each into `var(--c-brand)` (or `var(--c-brand-soft)` / `var(--c-brand-strong)` for rgba variants).

- [ ] **Step 5: Inventory `--c-brand` already in use**

```bash
grep -n "c-brand" web-player/styles.css
```

Some sites may already use the variable. Task 10 only converts the literal sites; existing var sites stay.

- [ ] **Step 6: Inventory current dashboard tiles**

```bash
cat web-portal/src/app/dashboard/page.tsx | head -100
ls web-portal/src/components/ | grep -i tile
```

This tells us the existing tile grid order so Task 8 can place the new Public Profile tile sensibly.

- [ ] **Step 7: Verify `media` bucket storage policies cover `branding/`**

```sql
SELECT policyname, cmd, qual
FROM pg_policies
WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname LIKE '%media%';
```

If no policy covers `branding/{practice_id}/*` writes, Task 1 adds one.

- [ ] **Step 8: Commit a "pre-flight notes" doc**

```bash
mkdir -p .claude/state/agent-notes
# Save captured RPC signatures + literal-counts to .claude/state/agent-notes/public-profile-v2-preflight.md
git add .claude/state/agent-notes/public-profile-v2-preflight.md
git commit -m "chore: pre-flight discovery for public-profile-v2"
```

---

## Task 1: Database migration

**Files:**
- Create: `supabase/migrations/20260521150000_public_profile_v2.sql`

This is the single most load-bearing file in the plan. It adds 6 columns, 6 constraints, and re-creates 3 SECURITY DEFINER RPCs. Every `RETURNS TABLE` column from the pre-flight discovery must be present verbatim in the new function bodies. Column-shadowing trap (42702) — qualify every WHERE clause against `practice_members` etc. with an alias.

- [ ] **Step 1: Write the column-add header**

```sql
-- ============================================================================
-- Public Profile v2 — branding columns + widened RPCs
-- ============================================================================
-- Adds practice-level branding (brand_color, tagline, specialties, contact
-- email/whatsapp/website) and widens get_plan_full / get_practice_profile /
-- set_practice_public_profile to read + write them.
--
-- Every existing column in each RPC's RETURNS TABLE is preserved verbatim
-- per the schema-migration-column-preservation rule (CLAUDE.md gotchas).
-- Pre-flight signatures captured in .claude/state/agent-notes/
-- public-profile-v2-preflight.md.
--
-- Spec: docs/specs/2026-05-21-public-profile-v2-design.md
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.practices
  ADD COLUMN IF NOT EXISTS brand_color text,
  ADD COLUMN IF NOT EXISTS tagline text,
  ADD COLUMN IF NOT EXISTS specialties text[],
  ADD COLUMN IF NOT EXISTS contact_email text,
  ADD COLUMN IF NOT EXISTS contact_whatsapp text,
  ADD COLUMN IF NOT EXISTS contact_website text;
```

- [ ] **Step 2: Add check constraints**

```sql
-- ---------------------------------------------------------------------------
-- 2. Check constraints — keep data within UI limits at the DB layer too.
-- ---------------------------------------------------------------------------
ALTER TABLE public.practices
  ADD CONSTRAINT practices_brand_color_hex
    CHECK (brand_color IS NULL OR brand_color ~ '^#[0-9A-Fa-f]{6}$'),
  ADD CONSTRAINT practices_tagline_length
    CHECK (tagline IS NULL OR length(tagline) <= 60),
  ADD CONSTRAINT practices_specialties_max
    CHECK (specialties IS NULL OR array_length(specialties, 1) <= 8),
  ADD CONSTRAINT practices_contact_email_length
    CHECK (contact_email IS NULL OR length(contact_email) <= 120),
  ADD CONSTRAINT practices_contact_whatsapp_length
    CHECK (contact_whatsapp IS NULL OR length(contact_whatsapp) <= 20),
  ADD CONSTRAINT practices_contact_website_length
    CHECK (contact_website IS NULL OR length(contact_website) <= 200);
```

- [ ] **Step 3: Re-create `set_practice_public_profile` with new params**

Copy the pre-flight-captured definition verbatim, then add 6 new parameters at the END of the signature (positional compatibility for any existing callers). Update the body to also write the new columns:

```sql
-- ---------------------------------------------------------------------------
-- 3. set_practice_public_profile — widened. Existing params keep their
--    position; new params append at the end. Owner-only enforcement
--    unchanged. Function body now writes all 11 fields (original 5 +
--    6 new). Returns void unchanged.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_practice_public_profile(
  p_practice_id uuid,
  p_slug text,
  p_logo_url text,
  p_blurb text,
  p_listed boolean,
  -- New params (V2):
  p_brand_color text DEFAULT NULL,
  p_tagline text DEFAULT NULL,
  p_specialties text[] DEFAULT NULL,
  p_contact_email text DEFAULT NULL,
  p_contact_whatsapp text DEFAULT NULL,
  p_contact_website text DEFAULT NULL
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'set_practice_public_profile requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'set_practice_public_profile: only the practice owner can edit'
      USING ERRCODE = '42501';
  END IF;

  -- Normalise empty strings to NULL so the constraints behave consistently.
  UPDATE public.practices
     SET public_slug         = nullif(btrim(coalesce(p_slug, '')), ''),
         public_logo_url     = nullif(btrim(coalesce(p_logo_url, '')), ''),
         public_blurb        = nullif(btrim(coalesce(p_blurb, '')), ''),
         public_profile_listed = coalesce(p_listed, false),
         public_profile_updated_at = now(),
         brand_color         = nullif(btrim(coalesce(p_brand_color, '')), ''),
         tagline             = nullif(btrim(coalesce(p_tagline, '')), ''),
         specialties         = p_specialties,
         contact_email       = nullif(btrim(coalesce(p_contact_email, '')), ''),
         contact_whatsapp    = nullif(btrim(coalesce(p_contact_whatsapp, '')), ''),
         contact_website     = nullif(btrim(coalesce(p_contact_website, '')), '')
   WHERE id = p_practice_id;
END;
$function$;
```

- [ ] **Step 4: Re-create `get_practice_profile` with new RETURNS TABLE fields**

The pre-flight gave you the existing column list. Append the new fields at the END of the `RETURNS TABLE`. Body's `SELECT` widens to include them. **Every existing column stays exactly as-is.**

```sql
-- ---------------------------------------------------------------------------
-- 4. get_practice_profile — anon RPC. RETURNS TABLE widened to include
--    new V2 fields. Pre-existing columns (practice_id, practice_name, slug,
--    logo_url, blurb, premises jsonb) preserved verbatim.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_practice_profile(p_slug text)
 RETURNS TABLE(
   -- Existing (DO NOT REORDER — clients may bind by position):
   practice_id uuid,
   practice_name text,
   slug text,
   logo_url text,
   blurb text,
   premises jsonb,
   -- New V2 fields:
   brand_color text,
   tagline text,
   specialties text[],
   contact_email text,
   contact_whatsapp text,
   contact_website text
 )
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_slug text := btrim(lower(coalesce(p_slug, '')));
BEGIN
  IF v_slug = '' THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    p.id,
    p.name,
    p.public_slug,
    p.public_logo_url,
    p.public_blurb,
    -- Premises jsonb aggregate (preserve existing shape) — copy from
    -- the pre-flight signature; if the existing body builds this with
    -- ST_AsGeoJSON etc., keep that block verbatim.
    coalesce(
      (SELECT jsonb_agg(jsonb_build_object(
                'id', pp.id,
                'name', pp.name,
                'address', pp.address,
                'safe_mode_enforced', pp.safe_mode_enforced,
                'centroid_lat', extensions.ST_Y(extensions.ST_Centroid(pp.polygon))::double precision,
                'centroid_lng', extensions.ST_X(extensions.ST_Centroid(pp.polygon))::double precision
              ) ORDER BY pp.created_at ASC)
       FROM public.practice_premises pp
       WHERE pp.practice_id = p.id AND pp.deleted_at IS NULL),
      '[]'::jsonb
    ),
    -- New V2 fields:
    p.brand_color,
    p.tagline,
    p.specialties,
    p.contact_email,
    p.contact_whatsapp,
    p.contact_website
  FROM public.practices p
  WHERE p.public_slug = v_slug
    AND p.public_profile_listed = true;
END;
$function$;
```

**IMPORTANT:** Before pasting this body, compare against the pre-flight Step 2 capture. If the existing function builds the `premises` jsonb differently (e.g. it joins differently, or includes extra fields), copy that block verbatim — do not rewrite it.

- [ ] **Step 5: Re-create `get_plan_full` with new RETURNS TABLE fields**

This is the player surface. Pre-flight Step 1 has the existing signature. Append two new fields at the end: `brand_color text, public_logo_url text`. Body's outer SELECT joins to `practices` (likely already does for `practice_id` / `practice_name`) — add the new columns to the projection.

```sql
-- ---------------------------------------------------------------------------
-- 5. get_plan_full — anon RPC. RETURNS TABLE widened with brand_color +
--    public_logo_url so the Web Player can cascade them at render time.
--    Both are already public via /v/{slug}; this just saves a round-trip.
--
--    EVERY existing column in the pre-flight capture MUST be in the new
--    RETURNS TABLE in the SAME ORDER. Append new fields at the END only.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_plan_full(p_plan_id uuid)
 RETURNS TABLE(
   -- ... PASTE EVERY EXISTING COLUMN HERE FROM PRE-FLIGHT STEP 1 ...
   -- (do not edit or reorder)
   --
   -- New V2 fields at the very end:
   brand_color text,
   public_logo_url text
 )
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- ... PASTE EVERY EXISTING STATEMENT FROM PRE-FLIGHT STEP 1 ...
  -- ...except where it does RETURN QUERY SELECT, add to the SELECT:
  --   p.brand_color,
  --   p.public_logo_url
  -- joining `public.practices p ON p.id = <plan>.practice_id` if not
  -- already joined.
END;
$function$;
```

**Do not write speculative code here** — copy the existing body from pre-flight, add the two new SELECT projections to the existing RETURN QUERY, leave everything else alone.

- [ ] **Step 6: Storage policy for `branding/` prefix (only if Step 7 of Task 0 showed it's missing)**

If pre-flight Step 7 showed no policy covers `branding/{practice_id}/*`, add one. Otherwise skip this step.

```sql
-- ---------------------------------------------------------------------------
-- 6. Storage: allow practice members to write to branding/{practice_id}/*
--    in the media bucket. Reads stay public (bucket-level public-read).
-- ---------------------------------------------------------------------------
CREATE POLICY "Branding writes by practice member"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'media'
    AND (storage.foldername(name))[1] = 'branding'
    AND (storage.foldername(name))[2]::uuid IN (
      SELECT pm.practice_id FROM public.practice_members pm
      WHERE pm.trainer_id = auth.uid()
    )
  );

CREATE POLICY "Branding overwrites by practice member"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'media'
    AND (storage.foldername(name))[1] = 'branding'
    AND (storage.foldername(name))[2]::uuid IN (
      SELECT pm.practice_id FROM public.practice_members pm
      WHERE pm.trainer_id = auth.uid()
    )
  );

CREATE POLICY "Branding deletes by practice member"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'media'
    AND (storage.foldername(name))[1] = 'branding'
    AND (storage.foldername(name))[2]::uuid IN (
      SELECT pm.practice_id FROM public.practice_members pm
      WHERE pm.trainer_id = auth.uid()
    )
  );
```

- [ ] **Step 7: Close the transaction**

```sql
COMMIT;
```

- [ ] **Step 8: Apply the migration locally against CI Postgres image**

The CI workflow `.github/workflows/migration-check.yml` already exercises this. Locally:

```bash
docker run --rm -d --name pp-v2-test -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=test -p 5499:5432 postgis/postgis:17-3.5
sleep 8
PGPASSWORD=postgres psql -h localhost -p 5499 -U postgres -d test -f supabase/migrations/20260521150000_public_profile_v2.sql
docker rm -f pp-v2-test
```

If anything errors, fix and re-run before committing.

- [ ] **Step 9: Commit**

```bash
git add supabase/migrations/20260521150000_public_profile_v2.sql
git commit -m "feat(db): add Public Profile v2 columns + widen RPCs"
```

---

## Task 2: TypeScript types + PortalApi extension

**Files:**
- Modify: `web-portal/src/lib/supabase/api.ts`
- Modify: `web-portal/src/lib/supabase/database.types.ts` (or regenerate)

- [ ] **Step 1: Define the V2 shape in `api.ts`**

Find the existing `PracticePublicProfile` type. Extend it:

```ts
export type PracticePublicProfile = {
  practiceId: string;
  practiceName: string;
  // Existing fields (V1):
  slug: string | null;
  logoUrl: string | null;
  blurb: string | null;
  listed: boolean;
  // V2 fields:
  brandColor: string | null;          // hex '#RRGGBB' or null = default coral
  tagline: string | null;             // ≤ 60 chars
  specialties: string[] | null;       // 0-8 entries
  contactEmail: string | null;
  contactWhatsapp: string | null;
  contactWebsite: string | null;
};
```

- [ ] **Step 2: Widen `getPracticePublicProfile`**

```ts
async getPracticePublicProfile(
  practiceId: string,
): Promise<PracticePublicProfile | null> {
  // Reuse existing RPC; new columns surface in the projection.
  const { data, error } = await this.supabase.rpc('get_practice_profile_owner', {
    p_practice_id: practiceId,
  });
  if (error || !data) return null;
  const row = Array.isArray(data) ? data[0] : data;
  if (!row) return null;
  return {
    practiceId: row.practice_id,
    practiceName: row.practice_name,
    slug: row.slug ?? null,
    logoUrl: row.logo_url ?? null,
    blurb: row.blurb ?? null,
    listed: row.listed ?? false,
    brandColor: row.brand_color ?? null,
    tagline: row.tagline ?? null,
    specialties: row.specialties ?? null,
    contactEmail: row.contact_email ?? null,
    contactWhatsapp: row.contact_whatsapp ?? null,
    contactWebsite: row.contact_website ?? null,
  };
}
```

If `get_practice_profile_owner` doesn't exist yet (the public `get_practice_profile` is gated by `public_profile_listed=true`), add a new owner-readable RPC in Task 1's migration that returns the same shape unconditionally for the calling user's practice. Owner-only check inside; no listed-filter.

- [ ] **Step 3: Widen `setPracticePublicProfile`**

```ts
type SetPracticePublicProfileInput = {
  practiceId: string;
  slug: string | null;
  logoUrl: string | null;
  blurb: string | null;
  listed: boolean;
  brandColor: string | null;
  tagline: string | null;
  specialties: string[] | null;
  contactEmail: string | null;
  contactWhatsapp: string | null;
  contactWebsite: string | null;
};

async setPracticePublicProfile(input: SetPracticePublicProfileInput): Promise<void> {
  const { error } = await this.supabase.rpc('set_practice_public_profile', {
    p_practice_id: input.practiceId,
    p_slug: input.slug,
    p_logo_url: input.logoUrl,
    p_blurb: input.blurb,
    p_listed: input.listed,
    p_brand_color: input.brandColor,
    p_tagline: input.tagline,
    p_specialties: input.specialties,
    p_contact_email: input.contactEmail,
    p_contact_whatsapp: input.contactWhatsapp,
    p_contact_website: input.contactWebsite,
  });
  if (error) {
    const code = (error as { code?: string }).code ?? '';
    const message = error.message ?? '';
    if (code === '42501') {
      throw new Error('Only the practice owner can edit branding & profile.');
    }
    if (code === '23514') {
      // Check constraint violation — map to user-friendly messages.
      if (/brand_color_hex/.test(message)) throw new Error('Brand color must be a 6-digit hex code.');
      if (/tagline_length/.test(message)) throw new Error('Tagline must be 60 characters or fewer.');
      if (/specialties_max/.test(message)) throw new Error('Maximum 8 specialties.');
      if (/contact_/.test(message)) throw new Error('Contact field is too long.');
    }
    throw new Error(message || 'Save failed.');
  }
}
```

- [ ] **Step 4: Regenerate `database.types.ts` (or hand-edit)**

If the Supabase CLI is set up locally:

```bash
supabase gen types typescript --project-id vadjvkmldtoeyspyoqbx --schema public > web-portal/src/lib/supabase/database.types.ts
```

If not, hand-edit the `practices` Row / Insert / Update interfaces to add the six new fields as nullable.

- [ ] **Step 5: Commit**

```bash
git add web-portal/src/lib/supabase/api.ts web-portal/src/lib/supabase/database.types.ts
git commit -m "feat(portal): PortalApi types for public-profile-v2 fields"
```

---

## Task 3: `/public-profile` page skeleton

**Files:**
- Create: `web-portal/src/app/public-profile/page.tsx`

Mirror the structure of `web-portal/src/app/premises/page.tsx` — server component, gets `user`, looks up `practices`, picks active via cookie + ?practice= param.

- [ ] **Step 1: Create the route file**

```tsx
import { cookies } from 'next/headers';
import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { ACTIVE_PRACTICE_COOKIE } from '@/lib/active-practice';
import { PublicProfileEditor } from './PublicProfileEditor';

type SearchParams = { practice?: string; section?: 'branding' | 'identity' };

export default async function PublicProfilePage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const supabase = await getServerClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/');

  const api = createPortalApi(supabase);
  const params = await searchParams;
  const practices = await api.listMyPractices();
  if (practices.length === 0) redirect('/dashboard');

  const cookieStore = await cookies();
  const cookiePractice = cookieStore.get(ACTIVE_PRACTICE_COOKIE)?.value;
  const cookieFallback =
    cookiePractice && practices.some((p) => p.id === cookiePractice)
      ? cookiePractice
      : practices[0].id;
  const selectedId = params.practice ?? cookieFallback;
  const selected = practices.find((p) => p.id === selectedId) ?? practices[0];
  const qs = `?practice=${selected.id}`;

  const [role, profile] = await Promise.all([
    api.getCurrentUserRole(selected.id, user.id),
    api.getPracticePublicProfile(selected.id),
  ]);
  const isOwner = role === 'owner';

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader
        showSignOut
        practiceId={selected.id}
        isOwner={isOwner}
        userEmail={user.email ?? ''}
        practices={practices}
      />
      <div className="mx-auto w-full max-w-3xl flex-1 px-6 py-10">
        <nav className="mb-4 text-sm text-ink-muted">
          <Link href={`/dashboard${qs}`} className="hover:text-brand">
            ← Dashboard
          </Link>
        </nav>

        <div className="mb-6 flex flex-col gap-2">
          <h1 className="font-heading text-3xl font-bold">Public profile</h1>
          <p className="text-sm text-ink-muted">
            What clients see at <code>session.homefit.studio/v/{profile?.slug ?? 'your-slug'}</code>.
            Logo + brand color also cascade into every plan you publish.
          </p>
          {profile?.slug && profile.listed && (
            <a
              href={`https://session.homefit.studio/v/${profile.slug}`}
              target="_blank"
              rel="noopener noreferrer"
              className="self-start rounded-md border border-surface-border bg-surface-raised px-3 py-1.5 text-xs text-ink hover:border-brand hover:text-brand"
            >
              Preview your page ↗
            </a>
          )}
        </div>

        <PublicProfileEditor
          practiceId={selected.id}
          isOwner={isOwner}
          initial={profile}
          initialSection={params.section}
        />
      </div>
    </main>
  );
}
```

- [ ] **Step 2: Create `PublicProfileEditor` client component shell**

```tsx
// web-portal/src/app/public-profile/PublicProfileEditor.tsx
'use client';

import { useState } from 'react';
import type { PracticePublicProfile } from '@/lib/supabase/api';
import { BrandingPanel } from './BrandingPanel';
import { IdentityPanel } from './IdentityPanel';

type Props = {
  practiceId: string;
  isOwner: boolean;
  initial: PracticePublicProfile | null;
  initialSection?: 'branding' | 'identity';
};

export function PublicProfileEditor({ practiceId, isOwner, initial, initialSection }: Props) {
  const [profile, setProfile] = useState<PracticePublicProfile | null>(initial);

  return (
    <div className="flex flex-col gap-3">
      {!isOwner && (
        <div className="rounded-md border border-surface-border bg-surface-raised px-4 py-3 text-sm text-ink-muted">
          Only the practice owner can edit branding &amp; profile. You can view what
          they have set.
        </div>
      )}
      <BrandingPanel
        practiceId={practiceId}
        isOwner={isOwner}
        profile={profile}
        onSaved={setProfile}
        defaultOpen={initialSection === 'branding'}
      />
      <IdentityPanel
        practiceId={practiceId}
        isOwner={isOwner}
        profile={profile}
        onSaved={setProfile}
        defaultOpen={initialSection === 'identity'}
      />
    </div>
  );
}
```

- [ ] **Step 3: Verify the route compiles**

```bash
cd web-portal && npx next lint --dir src/app/public-profile
```

(Lint will fail until `BrandingPanel` and `IdentityPanel` exist — that's fine, they come in Tasks 4-6.)

- [ ] **Step 4: Commit**

```bash
git add web-portal/src/app/public-profile/page.tsx web-portal/src/app/public-profile/PublicProfileEditor.tsx
git commit -m "feat(portal): /public-profile route + editor shell"
```

---

## Task 4: Logo uploader component

**Files:**
- Create: `web-portal/src/app/public-profile/LogoUploader.tsx`

- [ ] **Step 1: Create the component**

```tsx
'use client';

import { useRef, useState } from 'react';
import { getBrowserClient } from '@/lib/supabase-browser';

type Props = {
  practiceId: string;
  isOwner: boolean;
  currentUrl: string | null;
  onUploaded: (url: string) => void;
  onRemoved: () => void;
};

const MAX_BYTES = 1_048_576; // 1 MB
const ACCEPT = 'image/png,image/jpeg,image/svg+xml';

export function LogoUploader({ practiceId, isOwner, currentUrl, onUploaded, onRemoved }: Props) {
  const fileRef = useRef<HTMLInputElement>(null);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [dragOver, setDragOver] = useState(false);

  const handleFile = async (file: File) => {
    setError(null);
    if (file.size > MAX_BYTES) {
      setError(`Logo too large (${(file.size / 1048576).toFixed(1)} MB, max 1 MB).`);
      return;
    }
    if (!['image/png', 'image/jpeg', 'image/svg+xml'].includes(file.type)) {
      setError('Logo must be PNG, JPG, or SVG.');
      return;
    }
    setUploading(true);
    try {
      const ext = file.name.split('.').pop()?.toLowerCase() ?? 'png';
      const path = `branding/${practiceId}/logo.${ext}`;
      const supabase = getBrowserClient();
      const { error: uploadError } = await supabase.storage
        .from('media')
        .upload(path, file, { upsert: true, contentType: file.type });
      if (uploadError) throw uploadError;
      const { data: pub } = supabase.storage.from('media').getPublicUrl(path);
      // Cache-bust so the browser fetches the new bytes immediately.
      const url = `${pub.publicUrl}?v=${Date.now()}`;
      onUploaded(url);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Upload failed.');
    } finally {
      setUploading(false);
    }
  };

  const onPick = () => fileRef.current?.click();
  const onChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) void handleFile(file);
    e.target.value = '';
  };
  const onDrop = (e: React.DragEvent) => {
    e.preventDefault();
    setDragOver(false);
    const file = e.dataTransfer.files?.[0];
    if (file) void handleFile(file);
  };
  const onDragOver = (e: React.DragEvent) => {
    e.preventDefault();
    if (isOwner) setDragOver(true);
  };
  const onDragLeave = () => setDragOver(false);

  return (
    <div className="flex flex-col gap-2">
      <input
        type="file"
        accept={ACCEPT}
        ref={fileRef}
        onChange={onChange}
        className="hidden"
        disabled={!isOwner}
      />
      <div
        onClick={isOwner ? onPick : undefined}
        onDrop={isOwner ? onDrop : undefined}
        onDragOver={isOwner ? onDragOver : undefined}
        onDragLeave={isOwner ? onDragLeave : undefined}
        className={`flex items-center gap-4 rounded-lg border-2 border-dashed px-4 py-4 ${
          dragOver
            ? 'border-brand bg-brand/5'
            : 'border-surface-border bg-surface-bg'
        } ${isOwner ? 'cursor-pointer hover:border-brand/60' : 'cursor-not-allowed opacity-60'}`}
      >
        {currentUrl ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={currentUrl} alt="Logo" className="h-14 w-14 rounded object-contain bg-surface-base" />
        ) : (
          <div className="flex h-14 w-14 items-center justify-center rounded bg-surface-base text-2xl text-ink-muted">
            🏷
          </div>
        )}
        <div className="flex-1">
          <div className="text-sm text-ink">
            {currentUrl ? 'Replace logo' : 'Upload a logo'}
          </div>
          <div className="text-xs text-ink-muted">
            PNG, JPG, or SVG · ≤ 1 MB · square or landscape works
          </div>
        </div>
        {currentUrl && isOwner && (
          <button
            type="button"
            onClick={(e) => {
              e.stopPropagation();
              onRemoved();
            }}
            className="text-xs text-ink-muted underline decoration-dotted hover:text-error"
          >
            Remove
          </button>
        )}
      </div>
      {uploading && <p className="text-xs text-ink-muted">Uploading…</p>}
      {error && <p className="text-xs text-error">{error}</p>}
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add web-portal/src/app/public-profile/LogoUploader.tsx
git commit -m "feat(portal): logo uploader for /public-profile"
```

---

## Task 5: Brand color picker + live preview

**Files:**
- Create: `web-portal/src/app/public-profile/BrandColorPicker.tsx`

- [ ] **Step 1: Create the component**

```tsx
'use client';

import { useMemo } from 'react';

type Props = {
  value: string | null;
  onChange: (hex: string | null) => void;
  isOwner: boolean;
};

const CORAL = '#FF6B35';

export function BrandColorPicker({ value, onChange, isOwner }: Props) {
  const active = value ?? CORAL;
  const isDefault = value === null;

  const contrast = useMemo(() => contrastAgainstDarkBg(active), [active]);
  const lowContrast = contrast < 4.5; // WCAG AA threshold for normal text

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center gap-3">
        <input
          type="color"
          value={active}
          onChange={(e) => onChange(e.target.value.toUpperCase())}
          disabled={!isOwner}
          className="h-10 w-10 cursor-pointer rounded-md border border-surface-border bg-transparent disabled:cursor-not-allowed disabled:opacity-50"
          aria-label="Brand color"
        />
        <code className="text-sm text-ink">{active}</code>
        {!isDefault && isOwner && (
          <button
            type="button"
            onClick={() => onChange(null)}
            className="text-xs text-ink-muted underline decoration-dotted hover:text-brand"
          >
            Reset to coral
          </button>
        )}
      </div>
      {/* Live preview strip — mimics the player's pill matrix + countdown. */}
      <div
        className="rounded-lg border border-surface-border bg-surface-bg p-3"
        style={{ ['--c-brand' as string]: active } as React.CSSProperties}
      >
        <div className="mb-2 text-[10px] uppercase tracking-wide text-ink-muted">
          Live preview
        </div>
        <div className="flex items-center gap-1.5">
          {[0, 1, 2, 3, 4].map((i) => (
            <div
              key={i}
              className="h-2.5 flex-1 rounded-full"
              style={{
                background:
                  i < 2
                    ? 'var(--c-brand)'
                    : i === 2
                    ? 'transparent'
                    : 'rgba(255,255,255,0.08)',
                border:
                  i === 2 ? '2px solid var(--c-brand)' : '1px solid rgba(255,255,255,0.06)',
              }}
            />
          ))}
        </div>
        <div className="mt-3 text-center text-xs">
          <div className="text-ink-muted">Workout starts in</div>
          <div className="text-3xl font-bold" style={{ color: 'var(--c-brand)' }}>
            5
          </div>
        </div>
      </div>
      {lowContrast && (
        <p className="text-xs text-ink-muted">
          Tip: this color may be hard to read on dark surfaces. Contrast {contrast.toFixed(1)}:1
          is below the WCAG AA threshold (4.5:1). You can still save.
        </p>
      )}
    </div>
  );
}

// Relative luminance per WCAG 2.x.
function luminance(hex: string): number {
  const r = parseInt(hex.slice(1, 3), 16) / 255;
  const g = parseInt(hex.slice(3, 5), 16) / 255;
  const b = parseInt(hex.slice(5, 7), 16) / 255;
  const ch = (c: number) => (c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
  return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b);
}

function contrastAgainstDarkBg(hex: string): number {
  // Dark surface = #0F1117 → luminance ≈ 0.0066
  const L_bg = 0.0066;
  const L_fg = luminance(hex);
  const [lighter, darker] = L_fg > L_bg ? [L_fg, L_bg] : [L_bg, L_fg];
  return (lighter + 0.05) / (darker + 0.05);
}
```

- [ ] **Step 2: Commit**

```bash
git add web-portal/src/app/public-profile/BrandColorPicker.tsx
git commit -m "feat(portal): brand color picker with live preview + WCAG tip"
```

---

## Task 6: Specialties chip editor

**Files:**
- Create: `web-portal/src/app/public-profile/SpecialtiesEditor.tsx`

- [ ] **Step 1: Create the component**

```tsx
'use client';

import { useState, type KeyboardEvent } from 'react';

const MAX_CHIPS = 8;

type Props = {
  value: string[];
  onChange: (next: string[]) => void;
  isOwner: boolean;
};

export function SpecialtiesEditor({ value, onChange, isOwner }: Props) {
  const [draft, setDraft] = useState('');

  const add = () => {
    const trimmed = draft.trim();
    if (!trimmed) return;
    if (value.includes(trimmed)) {
      setDraft('');
      return;
    }
    if (value.length >= MAX_CHIPS) return;
    onChange([...value, trimmed]);
    setDraft('');
  };

  const remove = (chip: string) => {
    onChange(value.filter((c) => c !== chip));
  };

  const onKey = (e: KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      add();
    }
    if (e.key === 'Backspace' && draft === '' && value.length > 0) {
      remove(value[value.length - 1]);
    }
  };

  return (
    <div className="flex flex-col gap-2">
      <div className="flex flex-wrap gap-2">
        {value.map((chip) => (
          <span
            key={chip}
            className="inline-flex items-center gap-2 rounded-full border border-surface-border bg-surface-raised px-3 py-1 text-sm text-ink"
          >
            {chip}
            {isOwner && (
              <button
                type="button"
                onClick={() => remove(chip)}
                className="text-ink-muted hover:text-error"
                aria-label={`Remove ${chip}`}
              >
                ×
              </button>
            )}
          </span>
        ))}
      </div>
      {isOwner && (
        <div className="flex items-center gap-2">
          <input
            type="text"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={onKey}
            placeholder={value.length >= MAX_CHIPS ? 'Max 8 reached' : 'Add a specialty + Enter'}
            disabled={value.length >= MAX_CHIPS}
            className="flex-1 rounded-md border border-surface-border bg-surface-bg px-3 py-2 text-sm text-ink placeholder:text-ink-muted focus:border-brand focus:outline-none disabled:opacity-50"
          />
          <span className="text-xs text-ink-muted">{value.length} / {MAX_CHIPS}</span>
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add web-portal/src/app/public-profile/SpecialtiesEditor.tsx
git commit -m "feat(portal): specialties chip editor"
```

---

## Task 7: BrandingPanel + IdentityPanel + SaveBar

**Files:**
- Create: `web-portal/src/app/public-profile/BrandingPanel.tsx`
- Create: `web-portal/src/app/public-profile/IdentityPanel.tsx`
- Create: `web-portal/src/app/public-profile/SaveBar.tsx`

- [ ] **Step 1: Create `SaveBar`**

```tsx
'use client';

import { useEffect, useState } from 'react';

type Props = {
  pending: boolean;
  error: string | null;
  savedAt: number | null;
  onSave: () => void;
  disabled?: boolean;
  label?: string;
};

export function SaveBar({ pending, error, savedAt, onSave, disabled, label }: Props) {
  const [visibleConfirm, setVisibleConfirm] = useState<number | null>(savedAt);
  useEffect(() => {
    if (!savedAt) return;
    setVisibleConfirm(savedAt);
    const t = setTimeout(() => setVisibleConfirm(null), 3000);
    return () => clearTimeout(t);
  }, [savedAt]);

  return (
    <div className="mt-4 flex items-center gap-3">
      <button
        type="button"
        onClick={onSave}
        disabled={pending || disabled}
        className="rounded-md bg-brand px-4 py-2 text-sm font-semibold text-surface-bg hover:bg-brand-light disabled:cursor-not-allowed disabled:opacity-50"
      >
        {pending ? 'Saving…' : label ?? 'Save'}
      </button>
      {visibleConfirm && !error && (
        <span className="text-xs text-ink-muted">
          Saved · {new Date(visibleConfirm).toLocaleTimeString()}
        </span>
      )}
      {error && <span className="text-xs text-error">{error}</span>}
    </div>
  );
}
```

- [ ] **Step 2: Create `BrandingPanel`**

```tsx
'use client';

import { useState } from 'react';
import { getBrowserClient } from '@/lib/supabase-browser';
import { createPortalApi, type PracticePublicProfile } from '@/lib/supabase/api';
import { BrandColorPicker } from './BrandColorPicker';
import { LogoUploader } from './LogoUploader';
import { SaveBar } from './SaveBar';

type Props = {
  practiceId: string;
  isOwner: boolean;
  profile: PracticePublicProfile | null;
  onSaved: (next: PracticePublicProfile) => void;
  defaultOpen?: boolean;
};

export function BrandingPanel({ practiceId, isOwner, profile, onSaved, defaultOpen }: Props) {
  const [logoUrl, setLogoUrl] = useState<string | null>(profile?.logoUrl ?? null);
  const [brandColor, setBrandColor] = useState<string | null>(profile?.brandColor ?? null);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [savedAt, setSavedAt] = useState<number | null>(null);

  const save = async () => {
    setError(null);
    setPending(true);
    try {
      const api = createPortalApi(getBrowserClient());
      await api.setPracticePublicProfile({
        practiceId,
        slug: profile?.slug ?? null,
        logoUrl,
        blurb: profile?.blurb ?? null,
        listed: profile?.listed ?? false,
        brandColor,
        tagline: profile?.tagline ?? null,
        specialties: profile?.specialties ?? null,
        contactEmail: profile?.contactEmail ?? null,
        contactWhatsapp: profile?.contactWhatsapp ?? null,
        contactWebsite: profile?.contactWebsite ?? null,
      });
      onSaved({
        ...(profile ?? {
          practiceId,
          practiceName: '',
          slug: null,
          listed: false,
          blurb: null,
          tagline: null,
          specialties: null,
          contactEmail: null,
          contactWhatsapp: null,
          contactWebsite: null,
          logoUrl: null,
          brandColor: null,
        }),
        logoUrl,
        brandColor,
      });
      setSavedAt(Date.now());
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Save failed.');
    } finally {
      setPending(false);
    }
  };

  return (
    <details
      className="group rounded-lg border border-surface-border bg-surface-base p-5"
      open={defaultOpen}
    >
      <summary className="cursor-pointer text-base font-semibold text-ink">
        Branding
      </summary>
      <div className="mt-4 flex flex-col gap-5">
        <div>
          <div className="mb-2 text-sm font-medium text-ink">Logo</div>
          <LogoUploader
            practiceId={practiceId}
            isOwner={isOwner}
            currentUrl={logoUrl}
            onUploaded={setLogoUrl}
            onRemoved={() => setLogoUrl(null)}
          />
        </div>
        <div>
          <div className="mb-2 text-sm font-medium text-ink">Brand color</div>
          <BrandColorPicker
            value={brandColor}
            onChange={setBrandColor}
            isOwner={isOwner}
          />
        </div>
        {isOwner && (
          <SaveBar
            pending={pending}
            error={error}
            savedAt={savedAt}
            onSave={save}
            label="Save branding"
          />
        )}
      </div>
    </details>
  );
}
```

- [ ] **Step 3: Create `IdentityPanel`**

```tsx
'use client';

import { useState } from 'react';
import { getBrowserClient } from '@/lib/supabase-browser';
import { createPortalApi, type PracticePublicProfile } from '@/lib/supabase/api';
import { SpecialtiesEditor } from './SpecialtiesEditor';
import { SaveBar } from './SaveBar';

type Props = {
  practiceId: string;
  isOwner: boolean;
  profile: PracticePublicProfile | null;
  onSaved: (next: PracticePublicProfile) => void;
  defaultOpen?: boolean;
};

const SLUG_RX = /^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])?$/;

export function IdentityPanel({ practiceId, isOwner, profile, onSaved, defaultOpen }: Props) {
  const [slug, setSlug] = useState(profile?.slug ?? '');
  const [tagline, setTagline] = useState(profile?.tagline ?? '');
  const [blurb, setBlurb] = useState(profile?.blurb ?? '');
  const [specialties, setSpecialties] = useState<string[]>(profile?.specialties ?? []);
  const [email, setEmail] = useState(profile?.contactEmail ?? '');
  const [whatsapp, setWhatsapp] = useState(profile?.contactWhatsapp ?? '');
  const [website, setWebsite] = useState(profile?.contactWebsite ?? '');
  const [listed, setListed] = useState(profile?.listed ?? false);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [savedAt, setSavedAt] = useState<number | null>(null);

  const slugInvalid = slug !== '' && !SLUG_RX.test(slug);
  const wantsListed = listed && (slug === '' || slugInvalid);

  const save = async () => {
    setError(null);
    if (wantsListed) {
      setError('Pick a valid slug before listing in the directory.');
      return;
    }
    if (tagline.length > 60) {
      setError('Tagline must be 60 characters or fewer.');
      return;
    }
    if (blurb.length > 280) {
      setError('Blurb must be 280 characters or fewer.');
      return;
    }
    if (website && !/^https?:\/\//.test(website)) {
      setError('Website must start with https://');
      return;
    }
    setPending(true);
    try {
      const api = createPortalApi(getBrowserClient());
      await api.setPracticePublicProfile({
        practiceId,
        slug: slug || null,
        logoUrl: profile?.logoUrl ?? null,
        blurb: blurb || null,
        listed,
        brandColor: profile?.brandColor ?? null,
        tagline: tagline || null,
        specialties: specialties.length > 0 ? specialties : null,
        contactEmail: email || null,
        contactWhatsapp: whatsapp || null,
        contactWebsite: website || null,
      });
      const next: PracticePublicProfile = {
        practiceId,
        practiceName: profile?.practiceName ?? '',
        slug: slug || null,
        logoUrl: profile?.logoUrl ?? null,
        blurb: blurb || null,
        listed,
        brandColor: profile?.brandColor ?? null,
        tagline: tagline || null,
        specialties: specialties.length > 0 ? specialties : null,
        contactEmail: email || null,
        contactWhatsapp: whatsapp || null,
        contactWebsite: website || null,
      };
      onSaved(next);
      setSavedAt(Date.now());
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Save failed.');
    } finally {
      setPending(false);
    }
  };

  return (
    <details
      className="group rounded-lg border border-surface-border bg-surface-base p-5"
      open={defaultOpen}
    >
      <summary className="cursor-pointer text-base font-semibold text-ink">
        Identity &amp; directory
      </summary>
      <div className="mt-4 flex flex-col gap-4">
        <Field label="Tagline" hint={`${tagline.length} / 60`}>
          <input
            type="text"
            value={tagline}
            maxLength={60}
            onChange={(e) => setTagline(e.target.value)}
            disabled={!isOwner}
            placeholder="Short marketing line"
            className="rounded-md border border-surface-border bg-surface-bg px-3 py-2 text-sm text-ink placeholder:text-ink-muted focus:border-brand focus:outline-none disabled:opacity-60"
          />
        </Field>
        <Field label="Blurb" hint={`${blurb.length} / 280`}>
          <textarea
            value={blurb}
            maxLength={280}
            onChange={(e) => setBlurb(e.target.value)}
            disabled={!isOwner}
            rows={3}
            placeholder="A paragraph describing your practice."
            className="rounded-md border border-surface-border bg-surface-bg px-3 py-2 text-sm text-ink placeholder:text-ink-muted focus:border-brand focus:outline-none disabled:opacity-60"
          />
        </Field>
        <Field label="Specialties" hint={`${specialties.length} / 8`}>
          <SpecialtiesEditor value={specialties} onChange={setSpecialties} isOwner={isOwner} />
        </Field>
        <Field label="Email">
          <input
            type="email"
            value={email}
            maxLength={120}
            onChange={(e) => setEmail(e.target.value)}
            disabled={!isOwner}
            placeholder="hello@example.com"
            className="rounded-md border border-surface-border bg-surface-bg px-3 py-2 text-sm text-ink placeholder:text-ink-muted focus:border-brand focus:outline-none disabled:opacity-60"
          />
        </Field>
        <Field label="WhatsApp">
          <input
            type="tel"
            value={whatsapp}
            maxLength={20}
            onChange={(e) => setWhatsapp(e.target.value)}
            disabled={!isOwner}
            placeholder="+27 82 123 4567"
            className="rounded-md border border-surface-border bg-surface-bg px-3 py-2 text-sm text-ink placeholder:text-ink-muted focus:border-brand focus:outline-none disabled:opacity-60"
          />
        </Field>
        <Field label="Website">
          <input
            type="url"
            value={website}
            maxLength={200}
            onChange={(e) => setWebsite(e.target.value)}
            disabled={!isOwner}
            placeholder="https://yourpractice.co.za"
            className="rounded-md border border-surface-border bg-surface-bg px-3 py-2 text-sm text-ink placeholder:text-ink-muted focus:border-brand focus:outline-none disabled:opacity-60"
          />
        </Field>
        <Field label="Slug" hint="lowercase letters, digits, hyphens · 3–40 chars">
          <input
            type="text"
            value={slug}
            onChange={(e) => setSlug(e.target.value.toLowerCase())}
            disabled={!isOwner}
            placeholder="your-practice"
            className="rounded-md border border-surface-border bg-surface-bg px-3 py-2 text-sm text-ink placeholder:text-ink-muted focus:border-brand focus:outline-none disabled:opacity-60"
          />
          {slugInvalid && (
            <p className="mt-1 text-xs text-error">
              Slug must be 3–40 lowercase letters, digits, or hyphens.
            </p>
          )}
        </Field>
        <label className="flex items-center gap-2 text-sm text-ink">
          <input
            type="checkbox"
            checked={listed}
            onChange={(e) => setListed(e.target.checked)}
            disabled={!isOwner}
            className="h-4 w-4 accent-brand"
          />
          List in the directory at <code>session.homefit.studio/v/{slug || 'your-slug'}</code>
        </label>
        {isOwner && (
          <SaveBar
            pending={pending}
            error={error}
            savedAt={savedAt}
            onSave={save}
            label="Save profile"
          />
        )}
      </div>
    </details>
  );
}

function Field({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <label className="flex flex-col gap-1 text-sm">
      <div className="flex items-baseline justify-between">
        <span className="font-medium text-ink">{label}</span>
        {hint && <span className="text-xs text-ink-muted">{hint}</span>}
      </div>
      {children}
    </label>
  );
}
```

- [ ] **Step 4: Commit**

```bash
git add web-portal/src/app/public-profile/BrandingPanel.tsx web-portal/src/app/public-profile/IdentityPanel.tsx web-portal/src/app/public-profile/SaveBar.tsx
git commit -m "feat(portal): branding + identity panels for /public-profile"
```

---

## Task 8: Dashboard tile

**Files:**
- Create: `web-portal/src/components/PublicProfileTile.tsx`
- Modify: `web-portal/src/app/dashboard/page.tsx`

- [ ] **Step 1: Create the tile component**

```tsx
import Link from 'next/link';
import type { PracticePublicProfile } from '@/lib/supabase/api';

type Props = {
  practiceId: string;
  profile: PracticePublicProfile | null;
};

export function PublicProfileTile({ practiceId, profile }: Props) {
  const setFields = [
    profile?.logoUrl,
    profile?.brandColor,
    profile?.tagline,
    profile?.blurb,
    profile?.specialties && profile.specialties.length > 0 ? 'specialties' : null,
    profile?.contactEmail,
    profile?.contactWhatsapp,
    profile?.contactWebsite,
  ].filter((v) => v !== null && v !== '').length;
  const configured = setFields > 0;
  const slug = profile?.slug ?? null;
  const listed = profile?.listed ?? false;

  return (
    <Link
      href={`/public-profile?practice=${practiceId}`}
      className="block rounded-xl border border-surface-border bg-surface-base p-5 hover:border-brand"
    >
      <div className="text-xs uppercase tracking-wide text-ink-muted">
        Public profile
      </div>
      <div className="mt-2 text-lg font-semibold text-ink">
        {configured ? `${profile?.practiceName ?? 'Practice'}` : 'Not configured'}
      </div>
      <div className="mt-1 text-xs text-ink-muted">
        {configured
          ? `${setFields} field${setFields === 1 ? '' : 's'} set`
          : 'Set your branding & directory listing'}
      </div>
      {slug && listed && (
        <div
          className="mt-3 inline-block text-xs text-brand underline decoration-dotted"
          onClick={(e) => {
            e.preventDefault();
            window.open(`https://session.homefit.studio/v/${slug}`, '_blank', 'noopener');
          }}
        >
          session.homefit.studio/v/{slug} ↗
        </div>
      )}
    </Link>
  );
}
```

- [ ] **Step 2: Wire into dashboard**

Open `web-portal/src/app/dashboard/page.tsx`. Add to the data-fetch block:

```ts
const [/* existing fetches */, publicProfile] = await Promise.all([
  /* existing */,
  api.getPracticePublicProfile(selected.id),
]);
```

Add `<PublicProfileTile practiceId={selected.id} profile={publicProfile} />` in the tile grid (place after Clients per spec).

- [ ] **Step 3: Commit**

```bash
git add web-portal/src/components/PublicProfileTile.tsx web-portal/src/app/dashboard/page.tsx
git commit -m "feat(portal): Public Profile dashboard tile"
```

---

## Task 9: Remove the Public profile block from /premises

**Files:**
- Modify: `web-portal/src/components/PremisesListPanel.tsx`

- [ ] **Step 1: Find the existing block**

```bash
grep -n "Public profile\|public_profile\|public_slug\|public_blurb" web-portal/src/components/PremisesListPanel.tsx
```

- [ ] **Step 2: Delete the block + its imports + its state hooks**

Remove the `<details>` block, the slug/blurb/logo/listed state, the import of any now-unused types, and the call to `getPracticePublicProfile` if it lived here.

- [ ] **Step 3: Verify the page still compiles**

```bash
cd web-portal && npx next lint
```

- [ ] **Step 4: Commit**

```bash
git add web-portal/src/components/PremisesListPanel.tsx web-portal/src/app/premises/page.tsx
git commit -m "refactor(portal): move Public Profile editing off /premises"
```

---

## Task 10: Web Player CSS variable migration

**Files:**
- Modify: `web-player/styles.css`

- [ ] **Step 1: Define defaults in `:root`**

Find the existing `:root { ... }` block. Add (if not present):

```css
:root {
  --c-brand: #FF6B35;
  --c-brand-soft: rgba(255, 107, 53, 0.18);
  --c-brand-strong: rgba(255, 107, 53, 0.9);
}
```

- [ ] **Step 2: Replace literal `#FF6B35`**

For each line in the pre-flight Step 4 inventory, replace the literal with `var(--c-brand)`. For `rgba(255,107,53, X)` literals:

- `X ≤ 0.25` → `var(--c-brand-soft)`
- `X ≥ 0.85` → `var(--c-brand-strong)`
- otherwise (mid-opacity, e.g. 0.5) → expand the `:root` block with an additional variable for that exact opacity (e.g. `--c-brand-mid: rgba(255, 107, 53, 0.5);`) and reference it. JS-side override (Task 11) sets all three variables on plan load. This avoids `color-mix` which has spotty Safari support.

- [ ] **Step 3: Re-test the default visual unchanged**

Open `web-player/index.html` against staging with a default-coral plan. Side-by-side with the merged staging tip — nothing should look different. The override mechanism is dormant until a practice sets `brand_color`.

- [ ] **Step 4: Commit**

```bash
git add web-player/styles.css
git commit -m "refactor(player): migrate coral literals to CSS variable"
```

---

## Task 11: Web Player brand_color cascade (JS)

**Files:**
- Modify: `web-player/api.js`
- Modify: `web-player/app.js`

- [ ] **Step 1: Expose new fields from the `get_plan_full` wrapper**

Open `web-player/api.js`. Find the wrapper around `get_plan_full`. Confirm the response handler does NOT filter / project specific keys (it should pass the full row through). If it builds an explicit return object, add `brand_color: row.brand_color ?? null` and `public_logo_url: row.public_logo_url ?? null` to it. Add a JSDoc comment listing the two new keys so future readers know they're part of the contract.

- [ ] **Step 2: Set CSS variables on plan load**

Open `web-player/app.js`. Find where the plan payload becomes available (likely an `init()` or `loadPlan()` function). Add:

```js
function applyPracticeBranding(plan) {
  if (plan?.brand_color && /^#[0-9A-Fa-f]{6}$/.test(plan.brand_color)) {
    const root = document.documentElement;
    root.style.setProperty('--c-brand', plan.brand_color);
    root.style.setProperty('--c-brand-soft', toRgba(plan.brand_color, 0.18));
    root.style.setProperty('--c-brand-strong', toRgba(plan.brand_color, 0.9));
  }
}

function toRgba(hex, alpha) {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}
```

Call `applyPracticeBranding(plan)` immediately after the plan payload arrives, BEFORE any DOM that uses brand color is painted (i.e. early in init).

- [ ] **Step 3: Commit**

```bash
git add web-player/api.js web-player/app.js
git commit -m "feat(player): cascade practice brand_color into CSS variables"
```

---

## Task 12: Web Player top-bar logo slot

**Files:**
- Modify: `web-player/index.html` (or wherever the plan-bar template lives)
- Modify: `web-player/app.js`
- Modify: `web-player/styles.css`

- [ ] **Step 1: Add the slot in the plan-bar HTML**

Find the `<header class="plan-bar">` (or equivalent). Add a logo `<img>` slot to the left of the existing text:

```html
<header class="plan-bar">
  <img class="plan-bar-logo" alt="" />
  <div class="plan-bar-text">…existing children…</div>
</header>
```

- [ ] **Step 2: Style the slot**

In `web-player/styles.css`:

```css
.plan-bar { display: flex; align-items: center; gap: 12px; }
.plan-bar-logo {
  max-height: 32px;
  max-width: 96px;
  object-fit: contain;
  display: none; /* hidden until JS sets src */
}
.plan-bar-logo[src] { display: inline-block; }
```

- [ ] **Step 3: Populate from JS**

In `web-player/app.js` (or wherever `applyPracticeBranding` lives — extend it):

```js
function applyPracticeBranding(plan) {
  // ... existing color logic ...
  const logoEl = document.querySelector('.plan-bar-logo');
  if (logoEl) {
    if (plan?.public_logo_url) {
      logoEl.src = plan.public_logo_url;
      logoEl.alt = `${plan.practice_name ?? 'Practice'} logo`;
      logoEl.onerror = () => { logoEl.removeAttribute('src'); };
    } else {
      logoEl.removeAttribute('src');
    }
  }
}
```

- [ ] **Step 4: Commit**

```bash
git add web-player/index.html web-player/app.js web-player/styles.css
git commit -m "feat(player): top-bar logo slot for practice branding"
```

---

## Task 13: `/v/{slug}` advertising-page expansion

**Files:**
- Modify: `web-player/v.html`
- Modify: `web-player/v.js`
- Modify: `web-player/styles.css` (the `v-*` block)

The mockup at `docs/design/mockups/public-profile-v2.html` is the visual reference. Mirror its structure.

- [ ] **Step 1: Add hero CTA**

In `v.html`, after the blurb element, add (rendered conditionally by JS):

```html
<a class="v-hero-cta" id="hero-cta" target="_blank" rel="noopener" hidden></a>
```

- [ ] **Step 2: Add tagline element**

Above the blurb in the hero:

```html
<div class="v-tagline" id="hero-tagline" hidden></div>
```

- [ ] **Step 3: Add specialties section**

After the premises section:

```html
<section class="v-section" id="specialties-section" hidden>
  <h2>What we do</h2>
  <div class="v-chips" id="specialties-chips"></div>
</section>
```

- [ ] **Step 4: Add team section**

After specialties:

```html
<section class="v-section" id="team-section" hidden>
  <h2>Who you'll see</h2>
  <div class="v-team-grid" id="team-grid"></div>
</section>
```

- [ ] **Step 5: Add contact section**

After team:

```html
<section class="v-section" id="contact-section" hidden>
  <h2>Get in touch</h2>
  <div class="v-contact-list" id="contact-list"></div>
</section>
```

- [ ] **Step 6: Populate from JS**

In `v.js`, find where the profile payload arrives. After hydrating the existing fields:

```js
function hydrateExtras(profile) {
  // Brand color cascade — same pattern as the plan player.
  if (profile.brand_color && /^#[0-9A-Fa-f]{6}$/.test(profile.brand_color)) {
    document.documentElement.style.setProperty('--c-brand', profile.brand_color);
    const r = parseInt(profile.brand_color.slice(1,3),16);
    const g = parseInt(profile.brand_color.slice(3,5),16);
    const b = parseInt(profile.brand_color.slice(5,7),16);
    document.documentElement.style.setProperty('--c-brand-soft', `rgba(${r},${g},${b},0.18)`);
  }

  // Tagline
  if (profile.tagline) {
    const el = document.getElementById('hero-tagline');
    el.textContent = profile.tagline;
    el.hidden = false;
  }

  // Hero CTA — website
  if (profile.contact_website && /^https?:\/\//.test(profile.contact_website)) {
    const cta = document.getElementById('hero-cta');
    const display = profile.contact_website.replace(/^https?:\/\/(www\.)?/, '');
    cta.textContent = `Visit ${display} →`;
    cta.href = profile.contact_website;
    cta.hidden = false;
  }

  // Specialties
  if (Array.isArray(profile.specialties) && profile.specialties.length > 0) {
    const list = document.getElementById('specialties-chips');
    profile.specialties.forEach((s) => {
      const span = document.createElement('span');
      span.className = 'v-chip';
      span.textContent = s;
      list.appendChild(span);
    });
    document.getElementById('specialties-section').hidden = false;
  }

  // Contact list (email + whatsapp; website is hero CTA, not duplicated here)
  const contacts = [];
  if (profile.contact_email) {
    contacts.push({ label: 'Email', value: profile.contact_email, href: `mailto:${profile.contact_email}` });
  }
  if (profile.contact_whatsapp) {
    const digits = profile.contact_whatsapp.replace(/[^\d]/g, '');
    contacts.push({ label: 'WhatsApp', value: profile.contact_whatsapp, href: `https://wa.me/${digits}` });
  }
  if (contacts.length > 0) {
    const list = document.getElementById('contact-list');
    contacts.forEach((c) => {
      const a = document.createElement('a');
      a.className = 'v-contact-row';
      a.href = c.href;
      a.target = '_blank';
      a.rel = 'noopener';
      a.innerHTML = `<div><div class="v-contact-label">${c.label}</div><div class="v-contact-value">${escapeHtml(c.value)}</div></div>`;
      list.appendChild(a);
    });
    document.getElementById('contact-section').hidden = false;
  }
}

function escapeHtml(s) {
  const div = document.createElement('div');
  div.textContent = s;
  return div.innerHTML;
}
```

Call `hydrateExtras(profile)` after the existing hydration runs.

- [ ] **Step 7: Add CSS for the new sections**

Append to the `v-*` block in `web-player/styles.css`:

```css
.v-tagline {
  font-size: 17px;
  color: var(--c-brand);
  font-weight: 600;
  text-align: center;
  margin-top: 4px;
}
.v-hero-cta {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  margin: 20px auto 0;
  padding: 12px 22px;
  border-radius: 999px;
  border: 1.5px solid var(--c-brand);
  color: var(--c-brand);
  background: var(--c-brand-soft);
  text-decoration: none;
  font-weight: 600;
  font-size: 15px;
}
.v-hero-cta:hover { background: var(--c-brand); color: var(--c-surface-bg); }
.v-section { margin-top: 48px; }
.v-section h2 {
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.18em;
  color: var(--c-ink-muted);
  margin-bottom: 16px;
}
.v-chips { display: flex; flex-wrap: wrap; gap: 8px; }
.v-chip {
  background: var(--c-surface-base);
  border: 1px solid var(--c-surface-border);
  border-radius: 999px;
  padding: 6px 14px;
  font-size: 13px;
}
.v-team-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px; }
.v-contact-list { display: grid; gap: 10px; }
.v-contact-row {
  background: var(--c-surface-base);
  border: 1px solid var(--c-surface-border);
  border-radius: 12px;
  padding: 14px 16px;
  display: flex;
  align-items: center;
  text-decoration: none;
  color: var(--c-ink);
}
.v-contact-label { font-size: 11px; color: var(--c-ink-muted); text-transform: uppercase; letter-spacing: 0.1em; }
.v-contact-value { font-size: 15px; }
```

- [ ] **Step 8: Commit**

```bash
git add web-player/v.html web-player/v.js web-player/styles.css
git commit -m "feat(player): /v/{slug} advertising-page sections"
```

---

## Task 14: Web Player `/v/{slug}` team (practitioner) cards

**Files:**
- Modify: `web-player/v.js`

The spec says: practitioner avatars on the page pull from existing `practice_members` rows + each member's display name. The current `get_practice_profile` RPC doesn't return members. Decide between (a) extending the RPC to include members, or (b) a separate anon RPC `get_practice_members(p_practice_id)` that's safe to expose (returns display_name + initials only — never email or trainer_id).

- [ ] **Step 1: Add team RPC OR extend the existing one**

For minimum surface area, add a small anon RPC `get_practice_public_members(p_practice_id)` in a follow-up migration `supabase/migrations/20260521151000_practice_public_members.sql` — that's a small additive thing, leave the main migration's RPCs alone.

```sql
BEGIN;

CREATE OR REPLACE FUNCTION public.get_practice_public_members(p_practice_id uuid)
 RETURNS TABLE(
   display_name text,
   role text
 )
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_listed boolean;
BEGIN
  SELECT public_profile_listed INTO v_listed
  FROM public.practices WHERE id = p_practice_id;
  IF NOT coalesce(v_listed, false) THEN
    RETURN;
  END IF;
  RETURN QUERY
  SELECT
    coalesce(u.raw_user_meta_data->>'display_name', u.email) AS display_name,
    pm.role
  FROM public.practice_members pm
  JOIN auth.users u ON u.id = pm.trainer_id
  WHERE pm.practice_id = p_practice_id
  ORDER BY pm.role DESC, display_name ASC;  -- owners first
END;
$function$;

REVOKE ALL ON FUNCTION public.get_practice_public_members(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_practice_public_members(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_practice_public_members(uuid) TO authenticated;

COMMIT;
```

- [ ] **Step 2: Call from v.js + render**

```js
async function hydrateTeam(practiceId) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/get_practice_public_members`, {
    method: 'POST',
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ p_practice_id: practiceId }),
  });
  if (!r.ok) return;
  const rows = await r.json();
  if (!Array.isArray(rows) || rows.length === 0) return;
  const grid = document.getElementById('team-grid');
  rows.forEach((m) => {
    const initials = (m.display_name || '?')
      .split(/\s+/)
      .map((w) => w[0]?.toUpperCase() ?? '')
      .slice(0, 2)
      .join('');
    const card = document.createElement('div');
    card.className = 'v-team-card';
    card.innerHTML = `
      <div class="v-team-avatar">${escapeHtml(initials)}</div>
      <div class="v-team-name">${escapeHtml(m.display_name || 'Practitioner')}</div>
      <div class="v-team-role">${escapeHtml(m.role === 'owner' ? 'Practice owner' : 'Practitioner')}</div>
    `;
    grid.appendChild(card);
  });
  document.getElementById('team-section').hidden = false;
}
```

- [ ] **Step 3: Append CSS for team cards**

```css
.v-team-card {
  background: var(--c-surface-base);
  border: 1px solid var(--c-surface-border);
  border-radius: 14px;
  padding: 16px;
  text-align: center;
}
.v-team-avatar {
  width: 64px;
  height: 64px;
  border-radius: 999px;
  background: var(--c-surface-bg);
  border: 2px solid var(--c-brand-soft);
  margin: 0 auto 10px;
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--c-brand);
  font-weight: 700;
  font-size: 20px;
}
.v-team-name { font-size: 14px; font-weight: 600; }
.v-team-role { font-size: 11px; color: var(--c-ink-muted); margin-top: 2px; }
```

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260521151000_practice_public_members.sql web-player/v.js web-player/styles.css
git commit -m "feat(player): practitioner cards on /v/{slug}"
```

---

## Task 15: Flutter mobile twin (R-10)

**Files:**
- Modify: `app/lib/services/unified_preview_scheme_bridge.dart`
- Modify: `app/lib/screens/plan_preview_screen.dart` (and any embedding screens)

Because the web player IS the unified player on mobile (embedded via WebView), the changes ALREADY cascade via Task 11 + 12 — the player JS reads from the plan payload regardless of host. What needs explicit Flutter work is the BRIDGE that builds the plan payload for the WebView.

- [ ] **Step 1: Inventory the bridge**

```bash
grep -n "brand_color\|public_logo_url\|practice_name" app/lib/services/unified_preview_scheme_bridge.dart
```

- [ ] **Step 2: Extend the bridge to include the two new fields**

When the bridge constructs the plan JSON for the WebView, add `brand_color` and `public_logo_url` to the payload. Source them from the cached `practices` row (if the local DB has these columns — check `local_storage_service.dart` for the `cached_practices` schema).

- [ ] **Step 3: Add columns to the local cache if missing**

If `cached_practices` doesn't have `brand_color` / `public_logo_url`, add them via a SQLite migration bump in `app/lib/services/local_storage_service.dart`:

```dart
if (oldVersion < 43) {
  // 2026-05-21 — practice branding cache for offline preview parity.
  await _addColumnIfMissing(db, 'cached_practices', 'brand_color', 'TEXT');
  await _addColumnIfMissing(db, 'cached_practices', 'public_logo_url', 'TEXT');
}
```

Also bump `_dbVersion` to 43 and update `idempotent_migration_test.dart`.

- [ ] **Step 4: Extend `SyncService` pull branch**

Find where the practices cache is filled from the cloud. Include the new columns in the SELECT + UPSERT.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/unified_preview_scheme_bridge.dart app/lib/services/local_storage_service.dart app/test/idempotent_migration_test.dart app/lib/services/sync_service.dart
git commit -m "feat(mobile): cascade practice branding into embedded preview"
```

---

## Task 16: Test section J + index update

**Files:**
- Modify: `docs/test-scripts/2026-05-21-safe-mode.md`

Per the live-editing rule, the test file is the source of truth.

- [ ] **Step 1: Append section J**

```markdown
## J. PR feat/public-profile-v2 — branding + advertising page

- [ ] 72. Open `/public-profile` with no fields set → page renders, both accordions expand on click, no error.
- [ ] 73. Set `brand_color` to `#10B981` → live preview strip tints green; click Save → revisit `/v/{slug}` shows green tagline + green hero CTA border + green Safe Mode badges.
- [ ] 74. Open an existing published plan in the Web Player → coral elements are now green (active pill, prep countdown, treatment switcher active border, timer chip).
- [ ] 75. Upload a square logo (256×256 PNG) → appears in the hero AND in the player's top-bar within ~1s of save.
- [ ] 76. Upload a landscape logo (500×120 SVG) → renders correctly in both surfaces (CSS `object-fit: contain`).
- [ ] 77. Fill every contact field → hero shows website CTA, contact list shows email + WhatsApp rows.
- [ ] 78. Toggle `public_profile_listed` off → `/v/{slug}` returns Practice not found; toggle back on → page reappears with all fields intact.
- [ ] 79. Sign in as a non-owner member → `/public-profile` shows view-only UI with the info note; Save buttons absent.
- [ ] 80. Dashboard tile reflects "{N} fields set" correctly after each save. Empty state shows "Not configured · set your branding & directory listing".
- [ ] 81. `/premises` no longer shows the Public profile `<details>` block.
- [ ] 82. Practitioner cards on `/v/{slug}` show practice members with initials avatars + role labels.
```

- [ ] **Step 2: Commit**

```bash
git add docs/test-scripts/2026-05-21-safe-mode.md
git commit -m "docs(test-scripts): section J for public-profile-v2"
```

---

## Task 17: Open the PR

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feat/public-profile-v2
```

- [ ] **Step 2: Open draft PR**

```bash
gh pr create --base staging --draft \
  --title "feat(portal+player+mobile): Public Profile v2 — branding + advertising page" \
  --body "$(cat <<'EOF'
## Summary
Per spec at \`docs/specs/2026-05-21-public-profile-v2-design.md\`.

Six new columns on \`practices\` (brand_color, tagline, specialties, contact_email/whatsapp/website). Widened RPCs preserve every existing OUT column. New \`/public-profile\` portal page with two collapsed accordions (Branding, Identity & directory) + a new dashboard tile. Web Player cascades brand color via CSS variables + persistent top-bar logo. R-10 mobile twin: embedded WebView gets the same payload through the bridge + a local cache version bump.

## Test plan
See section J in \`docs/test-scripts/2026-05-21-safe-mode.md\` (items 72–82).
EOF
)"
```

- [ ] **Step 3: Watch CI**

`gh pr checks <number> --watch` until portal lint+build + migration-check + Vercel pass. Flag any failures.

---

## Self-review notes

This plan is large. If executed by a single sub-agent, expect 4-6 hours wall time. Recommend the subagent-driven approach with checkpoints after Task 1 (migration applies cleanly), Task 7 (editor functional locally), Task 12 (player cascade visible), Task 15 (mobile bridge updated). At each checkpoint, the dispatching agent reviews the diff before proceeding.

If sub-agents stall, Task 13 + 14 + 15 are the most isolated and can be deferred to a follow-up PR — the V1 launch needs only Tasks 0-12 + 16-17. Task 13 + 14 are the advertising-page polish; Task 15 is mobile parity. Carl can ship a portal-only V1 first and follow up.
