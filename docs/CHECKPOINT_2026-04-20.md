# Session Checkpoint — 2026-04-20

> **Hi future Claude.** Carl will greet you with "Where were we?" in a fresh session.
> Read this doc + `CLAUDE.md` first. This is the state at handoff.

## One-sentence status

**Mobile + portal are both live, converged on a client-spine IA, offline-first queue landed, line-drawing aesthetic is locked at v6, and Carl is in active device QA — next work items are backlog not bugs.**

## The arc of this session

The session started with MVP-push cleanup (dead-code cleanup PR, credit_ledger hardening, mobile Settings/password, referral backend + portal, portal account settings, mobile referral share card — all merged early). Then shifted into active device QA + design iteration:

1. **PayFast sandbox debug** — merchant credentials + passphrase (`jt7NOE43FZPn` for public sandbox) + `return_url` now carries `?practice=` so the Clients nav link works post-return.
2. **Multi-practice testing setup** — Carl asked to wire `@me.com` as a practitioner-role member of `@icloud.com`'s practice for testing. SQL executed live. Both practices renamed via SQL to `carlhein@me.com Practice` / `carlhein@icloud.com Practice`.
3. **RLS bug fix** — `listMyPractices` was returning 3 rows (peer's owner row leaked because the policy allows seeing all members of shared practices); both portal + mobile now explicitly filter by `trainer_id = auth.uid()`.
4. **Dashboard redesign (R-12)** — new design rule in `components.md`; dashboard is 5 stat tiles (Members owner-only); new `/network` page; nav expanded to 6 items.
5. **"Free publishes" → "Free credits"** copy sweep — one currency, across portal + mobile.
6. **Mobile IA shift** — Home is now the clients list. Tap client → per-client sessions page. "New Session" only from within a client. R-11 twin of portal `/clients` + `/clients/[id]`.
7. **Renaming bug chain** — session rename wrote to `clientName`, session card read `title`. Fixed: Studio writes `title`, reads `title ?? clientName` as the initial value.
8. **Local sessions not migrating to renamed clients** — `sessions.client_id` was null on pre-v16 rows; on Home load we now backfill from cloud's `plans.client_id` mapping.
9. **Line-drawing tuning saga (6 iterations)** — LOCKED at v6: `edgeThresholdLo=1, edgeThresholdHi=0.88, lineAlpha=0.96, backgroundDim=0.70`. Critical fix during this arc: BGRA byte-order bug in vImage's Planar8toARGB8888 was masquerading as a "purple-blue tint". Final: clean pencil grey on white.
10. **Offline-first (Phase 2)** — full cache + pending-sync queue. `SyncService` orchestrates pulls/flushes. `connectivity_plus` listener. `upsert_client_with_id` RPC in Supabase. All reads cached; all client writes queued. Publish stays online-only.

## What's on device right now

- **iPhone CHM SHA**: `fa3efa7` — the offline-first merge. Carl testing now.
- **Production Vercel**: same SHA. Both portal + web player deployed.
- **`main`** is `fa3efa7`. No branches ahead of main (bisect/studio-circuit-header is at the same SHA).

## What's on the DB

Key live migrations (all applied):

- `schema_milestone_e_revoke_credit_ledger_writes.sql` — credit_ledger is RPC-write-only.
- `schema_milestone_f_referral_loop.sql` — `referral_codes` / `practice_referrals` / `referral_rebate_ledger` + single-tier trigger.
- `schema_milestone_g_three_treatment.sql` — `clients` table, `video_consent` jsonb, private `raw-archive` bucket, `get_plan_full` extended with signed URLs.
- `schema_milestone_h_list_practice_sessions.sql` — sessions listing RPC.
- `schema_milestone_i_list_sessions_for_client.sql` — per-client sessions RPC.
- `schema_milestone_j_rename_client.sql` — `rename_client` RPC (patched to use IN-subquery on SETOF).
- `schema_milestone_k_upsert_client_with_id.sql` — client-generated UUID support for offline-first creates.

**Vault secret `supabase_jwt_secret`** is populated — grayscale/original signed URLs resolve properly.

## Account / practice setup for testing

| Email | User ID | Practice | Practice ID | Role | Balance |
|---|---|---|---|---|---|
| `carlhein@icloud.com` | `e85dc9ef-35d8-459e-8ed8-225db7490a3f` | carlhein@icloud.com Practice | `98d0dbdd-6f94-4c92-94b2-094b9effab4e` | owner | 0 |
| `carlhein@me.com` | `468093bb-aa37-4239-9b0b-a6ef6e7e435f` | carlhein@me.com Practice | `d0d3ea08-8354-4c5a-baae-16664773726a` | owner | ≥2 |
| `carlhein@me.com` | ↑ same user | carlhein@icloud.com Practice | ↑ same practice | practitioner | — |

**`@me.com`** is in TWO practices, so the practice switcher shows. **`@icloud.com`** is in one.

## Vercel env (portal: `homefit-web-portal`)

```
NEXT_PUBLIC_SUPABASE_URL         = https://yrwcofhovrcydootivjx.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY    = sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3
SUPABASE_SERVICE_ROLE_KEY        = (secret)
APP_URL                          = https://manage.homefit.studio
PAYFAST_MERCHANT_ID              = 10000100           ← public sandbox
PAYFAST_MERCHANT_KEY             = 46f0cd694581a      ← public sandbox
PAYFAST_PASSPHRASE               = jt7NOE43FZPn       ← NEEDED for public sandbox (not optional!)
PAYFAST_SANDBOX                  = true
PAYFAST_SANDBOX_OPTIMISTIC       = true               ← bypasses ITN for sandbox flow
```

## Design rules in force

| # | Rule | Where documented |
|---|---|---|
| R-01 | No confirmation modals. Destructive = SnackBar undo. | `components.md` |
| R-02 | Header purity — no competing actions in header. | `components.md` |
| R-06 | "Practitioner" vocabulary — never trainer/bio/physio/coach in user-visible text. | `CLAUDE.md` |
| R-09 | Defaults must be obvious. No behavioural inference. | `components.md` |
| R-10 | **Player parity is non-negotiable.** Mobile + web player ship together. | `components.md` |
| R-11 | Account / billing / settings features land on mobile + portal as twins. | `components.md` |
| R-12 | **Portal dashboard hygiene.** Every tile clickable; no orphaned functionality; nav covers every destination. | `components.md` |
| — (locked aesthetic) | **Line-drawing v6 is locked.** Do NOT tinker with `lineAlpha` / `backgroundDim` / edge thresholds without explicit Carl sign-off. | `VideoConverterChannel.swift` top-of-file comment. |

## Vocabulary conventions

- **Credits** — one currency. Bought credits + free credits share the same name.
- **Practitioner** — always. Never trainer, bio, physio, coach in user-visible copy.
- **"Network rebate"** — referral earnings surface.
- **Peer-to-peer** — referral copy. NEVER "earn rewards / commission / cash / payout / downline / MLM".
- **Client consent** — inline in voice: "What can {Name} see as?" — never "consent" / "POPIA" / "withdraw" / "legal" / "rights" in user-visible strings.
- **homefit.studio** — lowercase, one word. Never "HomeFit" / "HomeFit Studio".

## What's left (not urgent — nothing is currently broken)

From the MVP backlog + flagged items:

1. **Publish-screen practice picker polish (D2)** — mobile. Today the practice context is implicit via the chip; a formal picker on the publish screen was in MVP plan but not explicitly done.
2. **Three-treatment end-to-end validation** — vault secret is set, publish path uploads raw archive; need a real-device round-trip (capture → publish → open in portal /r/{code} preview → switch to B&W with consent granted).
3. **Referral loop end-to-end** — create account via /r/{code}, make sandbox purchase, verify +10/+10 signup bonus + 5% lifetime rebate rows in `referral_rebate_ledger`.
4. **POPIA privacy page + terms of service** — links from portal footer + sign-up gate. Legal copy pending.
5. **PayFast production cutover** — blocked on Carl's real merchant account.
6. **Dead-code sweep** — PR #10 flagged a list of unused elements; skipped during the MVP push. `_PrepFlashWrapper`, `_TimerRingPainter`, `_PulseMarkPainter`, etc.
7. **`supabase/schema.sql` refresh** — still at POV state; regenerate via `supabase db dump`.
8. **Portal `/clients` as the R-11 twin for mobile** — SHIPPED. Portal has `/clients` + `/clients/[id]`; mobile has Home + ClientSessionsScreen.
9. **Test plan Phase 1** — no tests exist for business-logic RPCs yet. Flagged in PR #10's cross-cutting review.

**Blocked on Carl:**
- PayFast production merchant account
- Apple Developer Program activation (flip `_appleEnabled = true` + restore Apple button)
- Legal review of privacy + TOS copy

## How to resume

1. Read `CLAUDE.md` (project brief).
2. Read this doc (this checkpoint).
3. Optionally read `docs/design/project/components.md` (design rules) if doing UI work.
4. Ask Carl what he wants to pick up. The open candidates are the items above; most are Carl-blocked.

**Carl's preferred working style**:
- Delegate multi-file coding to sub-agents in isolated worktrees. Base every agent off `origin/bisect/studio-circuit-header` (now same as main). Earlier in today's session multiple agents shipped against a stale local ref — the lesson is to `git fetch origin && git checkout -b <branch> origin/bisect/studio-circuit-header` as step 1.
- Push to `bisect/studio-circuit-header` AND fast-forward `main` after each landing, so his `./install-device.sh` picks it up.
- When Carl asks for a tweak, prefer inline if it's <3 files, spawn an agent otherwise.
- Voice + brand constraints are binding — R-06 / R-11 / R-12 are frequently checked.

## Today's merge list (reverse chronological)

```
fa3efa7  merge: PR #21 offline-first (cache + queue)
12e8905  docs(ios): lock line-drawing v6 as aesthetic baseline
ef5ccf8  fix(ios): v6 — expose backgroundDim 0.35 → 0.70
0003ab6  fix(mobile): Studio rename writes title not clientName
a39a49f  fix(ios): v5 +50% darker
a410a8c  feat(mobile): leading icon badges + revert session title + v4
... then earlier today: PR #20 mobile clients-spine, PR #19 portal R-12,
... PR #17 portal /clients, PR #16 portal /sessions (retired by #17),
... credit-row rename sweep, practice switcher, password auth, etc.
```

## The one thing Carl almost always asks next

"How is {some piece of UX} looking" or "make this X percent {darker/lighter/bigger}" — expect quick visual-iteration requests on the hand-drawn treatment or dashboard tiles. The iteration loop is: Swift / TSX / Dart edit → commit → push to both branches → `./install-device.sh` (mobile) or wait for Vercel (portal).
