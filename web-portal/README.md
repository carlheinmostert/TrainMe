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
- `SUPABASE_SERVICE_ROLE_KEY` — Server-only. Used by `/credits/purchase` to insert `pending_payments` intents. **Never** expose this to the browser.
- `APP_URL` — Public origin (e.g. `https://manage.homefit.studio`). Used to build PayFast `return_url` / `cancel_url`. Defaults to `http://localhost:3000`.
- `PAYFAST_MERCHANT_ID`, `PAYFAST_MERCHANT_KEY` — From the PayFast dashboard. `.env.example` ships the public sandbox credentials.
- `PAYFAST_PASSPHRASE` — Optional. Must match whatever you've set on your PayFast merchant profile. Leave empty for sandbox unless you explicitly set one.
- `PAYFAST_SANDBOX` — `true` routes checkout + ITN validation to `sandbox.payfast.co.za`. Flip to `false` for production.

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

## Milestone D4 — PayFast (shipped)

Credit purchases are wired end-to-end through PayFast (sandbox by default).

**Flow**

1. Buyer clicks **Buy _Bundle_** on `/credits`. The portal `POST`s to `/credits/purchase` with `{bundleKey, practiceId}`.
2. `/credits/purchase` (server-only) verifies membership, writes a `pending_payments` intent row with a fresh `m_payment_id`, computes the PayFast signature, and returns a signed checkout URL.
3. Browser redirects to PayFast. The buyer pays with their sandbox test card.
4. PayFast sends an **ITN** (Instant Transaction Notification) to the Supabase edge function `payfast-webhook`. The function performs four-step verification:
   - recompute MD5 signature on the received fields (in order) + passphrase,
   - check source IP against PayFast's published CIDR blocks,
   - echo the body back to PayFast's `/eng/query/validate` endpoint and expect `VALID`,
   - cross-check `amount_gross` against `pending_payments.amount_zar`.
5. On success it inserts a `credit_ledger` row (`type = 'purchase'`, `delta = +credits`) and marks the intent `complete`. The dashboard's credit balance RPC picks up the change on next refresh.
6. PayFast redirects the buyer to `/credits/return`. Credits may not be visible instantly — the ITN is eventually-consistent but usually arrives within a couple of seconds.

**Sandbox test card**

- Card number: `4000 0000 0000 0002`
- Expiry: any future month/year
- CVV: any 3 digits

Full walkthrough:

```bash
cd web-portal
cp .env.example .env.local   # defaults are sandbox-safe
npm install
npm run dev                  # http://localhost:3000
# sign in with Google → Create practice → /credits → Buy Starter
# use the sandbox card above → PayFast bounces back to /credits/return
# watch pending_payments + credit_ledger in the Supabase dashboard
```

**Production notes**

- Set `APP_URL` to your deployed origin (`https://manage.homefit.studio`) before switching `PAYFAST_SANDBOX=false`. PayFast rejects checkout requests whose `return_url` / `cancel_url` domain doesn't match the merchant's configured return-URL pattern.
- The ITN webhook deploys as a Supabase edge function (`supabase/functions/payfast-webhook`). Deploy with `supabase functions deploy payfast-webhook`. Set `PAYFAST_SANDBOX`, `PAYFAST_PASSPHRASE`, and the standard Supabase env vars as function secrets.
- The edge function whitelists PayFast's published IP blocks by default. Set `PAYFAST_SKIP_IP_CHECK=true` only for ngrok-style local testing, never in prod.

## Still outstanding

- [ ] Wire the "Invite member" form on `/members` to a real endpoint + Supabase magic-link invite.

## Related surfaces

- `app/` — Flutter capture/edit tool (trainer-facing)
- `web-player/` — anonymous client player at `session.homefit.studio`
- `supabase/schema*.sql` — database migrations
