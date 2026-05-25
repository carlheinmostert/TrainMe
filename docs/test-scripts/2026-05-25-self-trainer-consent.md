# Self-trainer wave PR #4 — Public profile consent UI + lazy backfill + Self-client creation

**Branch:** `feat/self-trainer-consent` → `staging`
**Spec:** `docs/sub-agent-briefs/04-self-trainer-consent.md`
**Wave doc:** `docs/SELF_TRAINER_WAVE.md` § "Persona onboarding" / § "POPIA compliance" / § "Migration plan"

POPIA copy in the consent sheet and Settings row is marked `[carl-review:]` in code and must be blessed before merge.

## Test these now

- [ ] **1. Cold launch — no selfie, no prompt.** Fresh install + sign in for a user whose `practitioners` row has `avatar_url IS NULL`. Land on My Workouts. No bottom sheet appears.
- [ ] **2. Launch with existing selfie, no consent — prompt appears once.** Sign in as a user with an existing avatar selfie but no `face_embedding_consented_at`. On Home's first post-frame, the consent bottom sheet slides up. Title reads "Use your photo for self-verification too?". Two actions: "Not now" (left, outlined) and "Yes, use it" (right, coral filled).
- [ ] **3. "Not now" dismisses cleanly.** Tap "Not now" on the sheet. Sheet dismisses. No SnackBar. Re-launching the app does NOT re-prompt (one-shot SharedPreferences flag held).
- [ ] **4. "Yes, use it" → register success.** Re-clear the prompt flag (debug helper or fresh user). Tap "Yes, use it". Inline spinner replaces the button. On success, sheet dismisses silently. Settings → Public profile now shows "Face verification: ON" with a coral verified-shield glyph and a red-outlined "Stop using face verification" button.
- [ ] **5. "Yes, use it" → no face in selfie.** Force a no-face outcome (use a selfie with no clear face, or stub `computeForImage` to return null). Sheet stays open. Inline coral-bordered error reads "We couldn't find a clear face in your selfie. Try taking a new one in Public profile." User can tap "Not now" to bail.
- [ ] **6. Settings → Stop using face verification.** With consent stamped, tap "Stop using face verification" on the Public profile screen. NO modal confirmation (R-01). SnackBar shows "Face verification removed" with an "Undo" action. Refresh Public profile — section flips to "Face verification: OFF" with a "Turn on" button.
- [ ] **7. Undo restores via re-consent.** Tap "Undo" on the SnackBar from item 6. The consent sheet re-opens. Tapping "Yes, use it" re-registers. Section flips back to ON. (Undo is NOT silent — POPIA Q14.1 requires explicit re-consent.)
- [ ] **8. Settings → Turn on (OFF → ON).** With consent revoked (or a never-consented user with an existing selfie), tap "Turn on" in the Public profile section. Consent sheet opens with the same copy as the lazy backfill prompt. Yes flow lands the same result as item 4.
- [ ] **9. FAB tap without consent surfaces consent inline.** On My Workouts, with a saved selfie but no consent stamp, tap the "Record your first workout" FAB. The consent sheet opens BEFORE any session is minted. Tap "Yes, use it" → sheet dismisses → existing "Coming in PR #9" toast appears (PR #9 will swap the toast for the actual session-mint flow).
- [ ] **10. FAB tap with no selfie at all.** Same scenario but `avatar_url IS NULL`. Tapping the FAB shows a SnackBar pointing to Settings > Public profile. No consent sheet opens.
- [ ] **11. FAB tap with consent already stamped.** Tap the FAB. No consent sheet. Direct "Coming in PR #9" toast.
- [ ] **12. Revoke RPC idempotency.** Tap "Stop using face verification" twice in a row (after the first SnackBar). Second tap shows "Face verification was already off" (no Undo). No crash; no error.
- [ ] **13. RPC throws on network failure surfaces inline.** Air-plane mode on. Tap "Yes, use it" on the consent sheet. Inline error reads "Couldn't save: [error]". Sheet stays open. User can retry once connectivity returns.
- [ ] **14. POPIA copy review.** All strings tagged `[carl-review:]` in code:
   - Consent sheet title + body (2 strings)
   - Consent sheet button labels ("Not now", "Yes, use it")
   - Settings ON copy ("Face verification: ON" + "Captures of you are free to publish.")
   - Settings OFF copy ("Face verification: OFF" + "Turn it on to make captures of yourself free.")
   - Action labels ("Stop using face verification", "Turn on")

   Walk through each in Public profile + the consent sheet and red-pen.
