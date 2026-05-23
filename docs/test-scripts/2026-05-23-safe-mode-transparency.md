# Safe Mode Transparency — staging QA (2026-05-23)

**Branch:** `feat/safe-mode-transparency` (PR #433 merged) + `fix/safe-mode-report-vault-secrets` (PR #436 merged)
**Build:** Phases A (identity gate) · B (live page + heartbeat) · C (QR poster) · D (reporting + escalation)
**Spec:** `docs/specs/2026-05-22-safe-mode-transparency.md`

**Staging surfaces:**
- Portal: https://staging.manage.homefit.studio
- Web player: https://staging.session.homefit.studio
- Mobile: install via `./install-device.sh staging` on iPhone CHM

**Staging Supabase project:** `vadjvkmldtoeyspyoqbx`. `safe-mode-report` edge function deployed; `RESEND_API_KEY` + `supabase_service_role_key` vault entry both in place.

How to use: tick each box as you go. Drop fails in chat ("12 fails — face-detect won't reject blank wall"). Passing items get struck through inline. New requirements appended at the end of section H — never re-numbered, never inserted mid-list.

---

## A. Setup

- [ ] 1. Run `./install-device.sh staging` from repo root. Build completes, installs to iPhone CHM, app launches.
- [ ] 2. Footer of Home renders the new git SHA (the merge-commit short SHA from `git rev-parse --short origin/staging`).
- [ ] 3. Sign in as a practice owner. Practice switcher chip top-left shows the practice name + credit count.

## B. Mobile — Public profile Settings

- [ ] 4. Open Settings → scroll to **Public profile** section. Heading + sub-line explains "appears on every venue's live transparency page". Section shows three fields: circular avatar slot, First name, Last name.
- [ ] 5. Tap **Update photo** on the avatar slot. Front camera fires (selfie). Snap a clear shot of your face. Preview appears in the slot.
- [ ] 6. Try **Update photo** again but point at a blank wall / ceiling. Save attempted. Rejection toast: "We need a clear photo of your face. Try again." (Face-detect via VNDetectFaceRectanglesRequest.)
- [ ] 7. With a valid selfie loaded but BEFORE first ever save, attempting Save fires the full-screen disclosure card: "Heads up — this becomes public" + the trade explainer + `Got it` / `Cancel`.
- [ ] 8. Tap **Cancel** on the disclosure card. Returns to Settings. Nothing persisted yet (next Safe Mode attempt should still gate).
- [ ] 9. Retry Save → disclosure card again → **Got it** → save proceeds. "Saved ✓" toast.
- [ ] 10. Type a 60-char first name. Save succeeds. Type a 61-char first name. Save rejects with "first_name too long (max 60)".
- [ ] 11. Force-quit the app and relaunch. Settings → Public profile shows the persisted name + avatar.
- [ ] 12. Edit the first name only and Save. No disclosure card this time (only fires before the very first save).

## C. Mobile — Safe Mode 6-point gate

- [ ] 13. Sign in as a practitioner whose `practitioners` row is INCOMPLETE (no avatar). Try to start Safe Mode capture in an enforced premises. Gate screen surfaces: "Add your name and photo in Settings to record in Safe Mode zones."
- [ ] 14. Gate screen has an **Open Settings** button. Tap → routes to Settings → Public profile section.
- [ ] 15. Sign in as a practitioner whose row IS complete BUT whose practice has `public_slug` / `public_blurb` / `public_profile_listed` missing. Gate screen surfaces: "Your practice's public profile is incomplete. Ask your owner to set it up at manage.homefit.studio/public-profile."
- [ ] 16. Gate screen has an **Open Portal** button. Tap → opens the portal `/public-profile` URL in the in-app Safari View Controller.
- [ ] 17. With BOTH practitioner + practice complete, Safe Mode activates as normal — no gate.

## D. Mobile — Heartbeat lifecycle

- [ ] 18. Start Safe Mode capture in an enforced polygon. Within 5s, the staging DB row appears: `SELECT * FROM active_capture_sessions WHERE trainer_id = '<your-uid>' AND ended_at IS NULL` returns one row.
- [ ] 19. Wait 20–25s. Re-query — `last_heartbeat_at` has advanced (heartbeat ticker firing).
- [ ] 20. End the capture session (back out of camera). DB row is stamped `ended_at = <now>`.
- [ ] 21. Restart capture → hard-kill the app from the iOS app switcher (don't end gracefully). Within 75s, the staging row's `last_heartbeat_at` ages past the 60s window — the row stays but `get_live_sessions` filters it out.
- [ ] 22. Restart the app + capture again. The previous orphan row is auto-stamped `ended_at = now()` by `start_capture_session`'s pre-insert sweep.

## E. Portal — Public profile notice

- [ ] 23. Sign in as an owner whose practice has incomplete public profile fields. Navigate to `/public-profile`. Coral-bordered notice at the top: "Important: Complete the fields below to enable Safe Mode recording in enforced premises. Without these, your practitioners cannot record in any private space."
- [ ] 24. Fill in `public_slug`, `public_blurb`, tick `public_profile_listed`, Save. Notice disappears on next render.
- [ ] 25. Untick `public_profile_listed` and Save. Notice re-appears.

## F. Portal — Premises poster

- [ ] 26. Navigate to `/premises`. Each premises row has a **Download poster** button (or similar — surface inline with edit/delete).
- [ ] 27. Tap **Download poster** → opens `/premises/{id}/poster?print=1` in a new tab → browser print dialog auto-fires → preview shows A4 light-mode poster with QR code, "Recording is happening here", practice name + location, caveat box, trust strip.
- [ ] 28. Save to PDF from the print dialog. Resulting PDF is single-page, no chrome, no browser headers/footers, QR code crisp.
- [ ] 29. Visit `/premises/{id}/poster` WITHOUT `?print=1`. Page renders as preview — no auto-print fires. Same visual layout.
- [ ] 30. Scan the QR code with iPhone camera. Routes to `https://staging.session.homefit.studio/v/{slug}/now`.
- [ ] 31. Sign in as a NON-owner member. Try to visit `/premises/{id}/poster` for that practice — page renders (owner-authenticated check might not enforce on members; if not, file a fail).

## G. Web player — Live transparency page

- [ ] 32. Open `https://staging.session.homefit.studio/v/<slug>/now` in mobile Safari. Top bar shows practice name + location + matrix logo.
- [ ] 33. Hero block: "Recording right now" with pulsing coral dot. Sub-line explains Safe Mode. "Updated Xs ago" timestamp.
- [ ] 34. SVG map renders the enforced polygon outline (dashed coral). Aspect ratio ~4:5. If practice has multiple enforced premises, all polygons visible.
- [ ] 35. With ZERO active capture sessions, the map shows polygons only. No floating cards. Sub-text reads something like "No one recording right now" (or equivalent empty state).
- [ ] 36. Have someone start a Safe Mode capture on the mobile (section D step 18). Within ~15s, the live page poll picks them up. Floating card appears, anchored to their GPS position inside the polygon. Card shows avatar (40px), full name (Montserrat 700), duration, premises label, Report button.
- [ ] 37. Card has a coral border with soft pulsing glow ring.
- [ ] 38. End the capture (section D step 20). Within ~15s the floating card disappears.
- [ ] 39. Grant geolocation when Safari prompts. Sage "you are here" dot appears on the SVG map (anchored to your GPS).
- [ ] 40. Deny geolocation. No sage dot. No error toast — graceful degrade.
- [ ] 41. Tap the practitioner card body (not the Report button). Navigates to `/v/{slug}` (the public profile root).

## H. End-to-end — bystander reports

- [ ] 42. Tap **Report** on a practitioner card. Modal opens. Title: "Report {practitioner name}". Sub-line: "This report will be sent to: {practice name} via {contact_email}". Textarea for reason, max 500 chars.
- [ ] 43. Tap **Send report** with an empty reason. Validation error: reason required.
- [ ] 44. Type a 501-char reason. Submit blocked, char counter goes red.
- [ ] 45. Type a normal reason (~50 chars) → **Send report**. Success toast. Modal closes.
- [ ] 46. Verify staging DB: `SELECT * FROM safe_mode_session_reports ORDER BY reported_at DESC LIMIT 1` shows the row with `practice_notified_at` populated (the edge function ran).
- [ ] 47. Check `noreply@homefit.studio` Resend dashboard (or the practice owner's inbox if that contact_email is monitored) — email arrived from "homefit Safe Mode" with the reason, practitioner name, session start time.
- [ ] 48. Submit a second Report for the same session from the same browser within an hour. Friendly error: "Reports for the same session are accepted at most once per hour per device."
- [ ] 49. Submit a Report from a DIFFERENT browser (or Safari private mode → different localStorage fingerprint) for the same session. Succeeds — rate limit is per-(session, fingerprint).
- [ ] 50. Manually clear `localStorage.homefit.fingerprint` in the browser DevTools. Re-submit. Succeeds (new fingerprint).
