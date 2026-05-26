# Wave 5 — Share sheet + managed email (artifact-system)

Final wave of the artifact-system rollout (2026-05-26). Lands `clients.email` +
verified-claim supersession, the `send-artifact-email` Supabase Edge Function,
and the two-path Studio share sheet (managed email vs. OS share).

**Carl-side action required before items 4 onwards run:**

1. Set the Resend HTTP-API key on the staging Edge Function secret store:
   ```
   supabase secrets set RESEND_API_KEY=re_... --project-ref vadjvkmldtoeyspyoqbx
   ```
   (Same Resend account as the SMTP relay per `docs/RESEND_SETUP.md`. Either
   reuse the existing key or mint a new one — both will work; the SMTP path
   is unaffected.)
2. Deploy the function:
   ```
   supabase functions deploy send-artifact-email --project-ref vadjvkmldtoeyspyoqbx
   ```

Until both are done, items 4-9 surface `send_failed` in the share sheet; the
OS share path (item 10) still works.

## Table of Contents

- [Migration smoke tests](#migration-smoke-tests)
- [Mobile share sheet](#mobile-share-sheet)
- [Edge function](#edge-function)
- [Claim flow supersession](#claim-flow-supersession)

## Migration smoke tests

- [ ] **1.** On staging, `select column_name from information_schema.columns where table_name='clients' and column_name in ('email','email_verified_at')` returns both rows.
- [ ] **2.** `select public.set_client_email('<client_id>', 'bad-email')` returns `{"ok": false, "reason": "invalid_email"}` (no DB write).
- [ ] **3.** `select public.set_client_email('<client_id>', 'test@example.com')` returns `{"ok": true}` AND `select email, email_verified_at from clients where id='<client_id>'` shows the address with NULL `email_verified_at`.
- [ ] **4.** Re-running #3 with the same value returns `{"ok": true, "noop": true}` (idempotency).
- [ ] **5.** `select public.set_client_email('<client_id>', '')` clears both columns + emits an `audit_events` row of kind `client.email.set` with `meta = {"cleared": true, "from_present": true, "to_present": false}`.
- [ ] **6.** `set_client_email` from a non-member account returns `{"ok": false, "reason": "forbidden"}`.

## Mobile share sheet

- [ ] **7.** Studio toolbar Share button opens the new bottom sheet with two CTAs (`Share link` + `Send by email`) and the plan title in the header.
- [ ] **8.** Tapping `Share link` closes the sheet and surfaces the iOS share UI with the plan URL (same behaviour as pre-Wave-5).
- [ ] **9.** Tapping `Send by email` reveals the email + message form. The email field is pre-filled from `cached_clients.email` if a prior send happened for this client; otherwise blank with placeholder copy.
- [ ] **10.** Typing a bogus address (`foo`) and tapping Send surfaces the coral error chip "That doesn't look like an email." — no network round-trip.
- [ ] **11.** Sending a real email shows the spinner state, then flips to the green-check "Email sent" chip + auto-dismisses after ~2s.
- [ ] **12.** A second Studio Share → Send opens with the previously-typed address pre-filled (verifying the `set_client_email` round-trip + cache pull).
- [ ] **13.** Legacy session with `client_id = NULL` opens the OS share directly (no bottom sheet) — verified by creating a session via the legacy code path or nulling `client_id` on a row in staging.

## Edge function

- [ ] **14.** Curl with no `Authorization` header → 401 `{"ok": false, "reason": "unauthenticated"}`.
- [ ] **15.** Curl with a valid JWT but a `plan_id` belonging to a different practice → 403 `{"ok": false, "reason": "forbidden"}`.
- [ ] **16.** Curl with mismatched `plan_id` / `client_id` → 400 `{"ok": false, "reason": "client_mismatch"}`.
- [ ] **17.** Carl checks the recipient inbox after item 11: branded email arrives with the practice name in the header, the `Open your workout` button links to `https://session.homefit.studio/h/{plan_id}`, and the practitioner's typed message (if any) appears under "Your practitioner says".
- [ ] **18.** With `email_verified_at` set on the client row via SQL, sending an email leaves both `clients.email` AND `clients.email_verified_at` unchanged (response shows `verified_email_preserved: true, email_stamped: false`).

## Claim flow supersession

- [ ] **19.** Pre-condition: a client with a practitioner-typed email (`email_verified_at IS NULL`). Magic-link claim the plan from a different address. Confirm: `clients.email` now holds the claimer's auth.users.email, `clients.email_verified_at` is `now()`, and an `audit_events` row of kind `client.email.verified` exists.
- [ ] **20.** After #19, the share sheet's email field pre-fills with the verified address; sending an email returns `{ok: true, verified_email_preserved: true}` and `clients.email` stays unchanged on retry.
