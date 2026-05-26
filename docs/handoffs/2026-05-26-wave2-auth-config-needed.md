# Wave 2 — Supabase Auth config Carl needs to apply

**Status:** BLOCKER for end-to-end claim flow testing. Wave 2 schema + code
landed but the consumer magic-link path won't reach `/me` until Carl applies
the two Supabase Auth config changes below.

**Why a handoff doc and not auto-applied:** the sub-agent doesn't have the
Supabase Personal Access Token in scope, and these changes touch the live
prod project (`yrwcofhovrcydootivjx`). Per `feedback_use_apis_not_dashboards.md`
the preferred path is the Management API one-liner (below) — but Carl needs
to run it from a shell where his PAT is set.

## What needs to change

The Supabase Auth project today has:

- **Site URL:** `https://manage.homefit.studio` (practitioner portal).
- **Redirect allowlist:** `https://manage.homefit.studio/**`,
  `http://localhost:3000/**`, `studio.homefit.app://login-callback`,
  `studio.homefit.app://**`.

Wave 2 routes the consumer magic-link callback at
`https://session.homefit.studio/me` (the page parses the
`#access_token=...` fragment on landing). For that to work, Supabase must
accept that URL on the redirect allowlist.

We are **not** changing the Site URL — the practitioner portal still owns
that. We are **adding** the consumer host to the redirect allowlist.

## Add to redirect allowlist

Two entries:

- `https://session.homefit.studio/me`
- `https://session.homefit.studio/me/**`

The second covers any future sub-routes (`/me/data`, future `/me/settings`)
that might need to receive an auth callback. Today only `/me` is used as the
`emailRedirectTo`.

For staging completeness, also add the staging twin:

- `https://staging.session.homefit.studio/me`
- `https://staging.session.homefit.studio/me/**`

Local-dev (Vercel `vercel dev`) typically lands on
`http://localhost:3000/...`, which is already on the allowlist, so the
existing entries cover local testing.

## How to apply (preferred — Management API)

Run this from a shell where `SUPABASE_ACCESS_TOKEN` is set (Carl's PAT
from `supabase login` is in the macOS Keychain — `security find-generic-password
-s 'supabase' -w` lifts it):

```bash
PROJECT_REF="yrwcofhovrcydootivjx"  # prod
# PROJECT_REF="vadjvkmldtoeyspyoqbx"  # staging — run BOTH

# Fetch current config first so you can see the existing allowlist
curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth" \
  | jq '.uri_allow_list'

# Then PATCH with the union of existing + new entries. Replace the
# value below with the actual list after eyeballing the GET.
curl -X PATCH -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth" \
  -d '{
    "uri_allow_list": "https://manage.homefit.studio/**,http://localhost:3000/**,studio.homefit.app://login-callback,studio.homefit.app://**,https://session.homefit.studio/me,https://session.homefit.studio/me/**,https://staging.session.homefit.studio/me,https://staging.session.homefit.studio/me/**"
  }'
```

The Management API allowlist is a comma-separated string. The existing four
entries plus the four new ones = eight total.

## Or via dashboard (fallback)

If the Management API path is awkward:

1. Open Supabase dashboard → project `homefit-studio-prod` →
   Authentication → URL Configuration.
2. Under "Redirect URLs", click **Add URL** and paste each of the four new
   entries above (one at a time; the dashboard validates each).
3. Save.
4. Repeat for `homefit-studio-staging` (`vadjvkmldtoeyspyoqbx`).

## What you can verify after applying

1. Open `https://session.homefit.studio/me` in an anonymous tab.
2. Submit your email in the magic-link form.
3. Check your inbox for the `noreply@homefit.studio` email (it should
   render with the dark + coral template — that's already wired).
4. The link in the email looks like
   `https://yrwcofhovrcydootivjx.supabase.co/auth/v1/verify?token=...&type=magiclink&redirect_to=https%3A%2F%2Fsession.homefit.studio%2Fme`.
5. Clicking it should land you on `/me` with `#access_token=...` in the
   URL hash; the page parses it, persists the session in localStorage,
   and renders the signed-in My Workouts list.

If the redirect_to is rejected, Supabase falls back to the Site URL —
which means the user lands on `manage.homefit.studio` instead. That's
how you know the allowlist update didn't take.

## After this is applied

- The `claim_plan` RPC + the `/me` + `/me/data` pages all work end-to-end.
- The Wave 2 test checklist in the PR body can be ticked through.
- No other config changes are needed for Wave 2. Apple / Google OAuth is
  deferred (Wave 5+).

— Wave 2 schema migration:
`supabase/migrations/20260526173515_artifact_system_claim.sql`
— Web routes: `web-player/me.html`, `web-player/me-data.html`
— Vercel rewrites: `web-player/vercel.json`
