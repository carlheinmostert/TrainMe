# homefit.studio — Web portal

Next.js 15 App Router portal for practice owners and practitioners. Sign in with Google, manage credits, inspect the audit log, and invite teammates.

Target deployment: **https://manage.homefit.studio** (DNS pending).

## Stack

- Next.js 15 (App Router, React Server Components)
- TypeScript strict mode
- Tailwind CSS with brand tokens mirroring `app/lib/theme.dart` and `web-player/styles.css`
- `@supabase/ssr` for cookies-based auth on both server and client
- Deployed to Vercel (static pages + Node runtime for auth routes)

## Local setup

```bash
cd web-portal
npm install
cp .env.example .env.local   # then fill in any secrets (anon key is public)
npm run dev                  # http://localhost:3000
```

Useful scripts:

| Command              | What it does                                     |
| -------------------- | ------------------------------------------------ |
| `npm run dev`        | Local dev server with hot reload                 |
| `npm run build`      | Production build (type-checks and bundles)      |
| `npm run start`      | Serves the production build                      |
| `npm run typecheck`  | `tsc --noEmit` — fast type check, no bundling   |
| `npm run lint`       | Next.js/ESLint                                   |

## Environment variables

See `.env.example`. Highlights:

- `NEXT_PUBLIC_SUPABASE_URL` — Supabase project URL. Safe to expose.
- `NEXT_PUBLIC_SUPABASE_ANON_KEY` — Publishable anon key. Safe to expose.
- `PAYFAST_*` — Empty until Milestone D4 lands the real checkout flow.

**Never** put the Supabase service role key in a `NEXT_PUBLIC_*` variable. Server-only secrets should live in plain `VAR_NAME` entries.

## Deployment (Vercel)

1. Create a new Vercel project pointed at this repo, root directory `web-portal/`.
2. Framework preset: **Next.js** (auto-detected).
3. Environment variables: copy from `.env.example` and set production values in the Vercel dashboard.
4. Deploy. Vercel picks up `vercel.json` for security headers.

### DNS for `manage.homefit.studio`

At Hostinger, add a CNAME record:

```
Host:   manage
Target: <the target Vercel gives you after linking>  (e.g. cname.vercel-dns.com or xyz.vercel-dns-017.com)
TTL:    3600
```

Then add `manage.homefit.studio` as a custom domain in Vercel. Cert issues automatically.

## Architecture notes

- **Auth:** Supabase OAuth (Google). PKCE flow with the code exchanged at `/auth/callback`. Sessions are cookie-backed; both server components and route handlers read/write them via `getServerClient()`.
- **Practice selection:** Carried as `?practice=<uuid>` in the URL. No global state library. When the user has only one practice, it's auto-selected.
- **Credit balance:** `rpc('practice_credit_balance', { p_practice_id })`.
- **RLS:** The portal only ever queries its own practices' data via the logged-in user's JWT. Milestone C's per-practice policies on `practice_members`, `plans`, `plan_issuances`, and `credit_ledger` all allow these queries naturally.

## Milestone D4 TODO (PayFast)

The "Buy credits" surface is scaffolded but the checkout is stubbed.

- [ ] Replace `src/app/credits/purchase/route.ts` with real PayFast signed-request generation.
- [ ] Create a `bundles` Supabase table + policy; read prices from there instead of the hardcoded `BUNDLES` array in `src/app/credits/page.tsx`.
- [ ] Implement the PayFast ITN webhook (separate route, `/payfast/itn`) that credits the `credit_ledger` on verified notification — never trust the browser redirect.
- [ ] Add `/credits/success` and `/credits/cancel` landing pages.
- [ ] Remove the yellow "Milestone D4 TODO" banner on `/credits`.
- [ ] Wire the "Invite member" form on `/members` to a real endpoint + Supabase magic-link invite.

## Related surfaces

- `app/` — Flutter capture/edit tool (trainer-facing)
- `web-player/` — anonymous client player at `session.homefit.studio`
- `supabase/schema*.sql` — database migrations
