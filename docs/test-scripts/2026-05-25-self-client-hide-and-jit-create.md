# Self-client hide + JIT create — test script

Branch: `fix/self-client-hide-and-jit-create-2` (PR target: `staging`)

Two concerns, both about the Self-client (the practitioner-as-client row
introduced in PR #502 / #508 of the self-trainer wave):

1. **Hide Self-clients from the regular Clients tab** — they belong on
   the My Workouts surface only.
2. **JIT-heal the Self-client when missing or soft-deleted** — the My
   Workouts FAB should silently restore-or-create instead of wedging
   the user on "Try again in a moment".

Run against a build off this branch on iPhone CHM and the portal preview
deployment for this PR.

## Checks

- [ ] **Mobile Clients tab** — open Home, switch to the Clients tab. The
  "Me" row (the Self-client) does NOT appear in the list. Real clients
  still render in alphabetical order.

- [ ] **Portal /clients** — sign into `manage.homefit.studio` (preview
  deployment for this PR), open Clients. The "Me" row does NOT appear in
  the grid. The count in the header subtitle matches the number of real
  clients only.

- [ ] **JIT-heal (soft-deleted Self-client)** — on the staging Supabase
  project, soft-delete your Self-client with:
  ```sql
  UPDATE clients
     SET deleted_at = now(), deleted_by_user_id = '<your-user-id>'
   WHERE user_id = '<your-user-id>' AND deleted_at IS NULL;
  ```
  Force-quit + relaunch the app to bust the cache. Open My Workouts and
  tap the FAB. Expected: no "Try again in a moment" toast; the consent
  sheet does NOT re-trigger (your face stamp is still in place); a fresh
  session opens in Camera mode bound to the restored Self-client. Verify
  in Supabase that `deleted_at` is now NULL and the row keeps its
  original id.

- [ ] **JIT-heal (missing Self-client, no embedding yet)** — hard-delete
  the Self-client with:
  ```sql
  DELETE FROM clients WHERE user_id = '<your-user-id>';
  UPDATE practitioners SET face_embedding = NULL,
                           face_embedding_consented_at = NULL,
                           face_embedding_computed_at = NULL
   WHERE user_id = '<your-user-id>';
  ```
  Force-quit + relaunch. Tap the FAB on My Workouts. Expected: the
  existing consent sheet path runs (selfie + consent re-stamp), then
  a fresh session opens. Verify a brand-new Self-client row exists with
  a fresh uuid + `user_id = your-auth-uid`.

- [ ] **JIT-heal idempotence** — without deleting anything, tap the FAB
  three times in a row (allow each session to open + back-out). Each
  tap should succeed and reuse the SAME Self-client uuid (no duplicate
  rows in `clients` for your user_id).

- [ ] **Conflict surface (parallel agent)** — if the Mobile-stack PR
  (`fix/mobile-stack-2026-05-25`) lands first, rebase this PR and
  verify the `home_screen.dart` changes still apply cleanly on top of
  the AppBar layout + empty-state copy changes.
