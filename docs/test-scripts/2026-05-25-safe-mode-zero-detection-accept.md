# Safe Mode — accept zero-detection captures + telemetry + orphan-row fix (2026-05-25)

**Branch:** `fix/safe-mode-accept-zero-detection` (PR targets `staging`, drafted as `[QA-blocked]`).
**Build:** profile mode, install via `homefit-install-device` skill AFTER Carl explicitly approves.
**Bundle:** `studio.homefit.app.dev` (staging build).

This wave bundles three changes that share the Safe Mode rejection code path:

1. **Accept zero-detection captures.** Captures where Vision detected no humans in any frame (empty room, equipment, outdoor landscape) are now accepted instead of rejected. They contain no personal information by definition.
2. **Telemetry.** Each accepted-empty capture writes one row to `capture_audit_events` (kind `safe_mode_accepted_empty`) with a numerics-only scene fingerprint (mean RGB, grayscale entropy, complexity score). Surfaced in the portal audit feed at `manage.homefit.studio/audit` and counted in the live-page 24h drawer aggregate.
3. **Orphan-exercise-after-rejection fix.** Middle-band Safe Mode rejections now drop the in-memory card synchronously alongside the SQLite delete (was: stuck `converting` spinner until app restart). Diagnosed as hypothesis 2 from the spec — no removal signal reached Studio / ClientSessions listeners.

## Table of contents

- [Prerequisites](#prerequisites)
- [A. Accept-empty captures](#a-accept-empty-captures)
- [B. Existing accept + reject behaviour preserved](#b-existing-accept--reject-behaviour-preserved)
- [C. Orphan-exercise-after-rejection fix](#c-orphan-exercise-after-rejection-fix)
- [D. Telemetry surfaces](#d-telemetry-surfaces)

## Prerequisites

Set up the following state on staging (project `vadjvkmldtoeyspyoqbx`) before running:

- One enforcing premises polygon centered on your current location. Open Settings → Practice → Premises, create or edit one premises so its polygon contains the device's GPS coordinate, and toggle `enforced = true`.
- One client bound to the active session with face enrolment complete (any of the multi-reference enrolment flows from Wave-D). Without enrolment the Safe Mode v2 path short-circuits to `missingFaceEmbedding` and you can't get to the miss-rate-driven branches.
- Sign-in confirmed (refresh tokens last 30 days; if you land on the Sign-In screen, use the credentials in `.env.test`).

## A. Accept-empty captures

These are the new acceptances. Each should land as a normal exercise card in Studio with no rejection toast, and surface one `accepted-empty` row in the portal audit feed.

- [ ] **1. Empty-room photo inside enforcing polygon** — point the camera at a blank gym wall (no person in frame), short-press to capture. Studio card lands with a thumbnail of the wall. No coral rejection toast.
- [ ] **2. Equipment-only photo inside enforcing polygon** — point the camera at a dumbbell rack, kettlebell pile, or stationary bike. Capture. Card lands.
- [ ] **3. Outdoor landscape inside enforcing polygon** — if the polygon includes an outdoor area, point at trees / sky / pavement with no people. Capture. Card lands.
- [ ] **4. Empty-room video inside enforcing polygon** — long-press, hold for 5+ seconds aiming at the empty wall, release. Card lands with a video thumbnail of the empty frame. No coral toast.

## B. Existing accept + reject behaviour preserved

Acceptance criterion 5 in the spec: photos and videos share the same code branch. Acceptance criterion 4: fully-detected captures unchanged. Acceptance criterion 3: partial-detection captures still rejected.

- [ ] **5. Selfie inside enforcing polygon (just the practitioner)** — capture a selfie. Behaviour unchanged from staging tip: Vision finds a human, safe variant produced (no bystanders to paint coral, but the variant still writes), exercise lands.
- [ ] **6. Practitioner + bystander photo inside enforcing polygon** — ask a colleague to walk into frame, snap the photo. Behaviour unchanged: safe variant produced, bystander painted coral in the saved file, exercise lands. Practitioner stays sharp.
- [ ] **7. Backlit / partial-detection video** — record a video with the subject in front of a bright window or with very dark / inconsistent lighting. Aim for a setup where Vision intermittently misses (the miss-rate lands in 5–100%). Behaviour unchanged: card disappears mid-conversion, **NEW toast copy** reads "Couldn't track everyone in the shot — try a different angle."

## C. Orphan-exercise-after-rejection fix

This is the load-bearing fix. Pre-2026-05-25, a middle-band rejection deleted the SQLite row but left a stuck `converting` spinner in Studio. The new `onExerciseRemoved` stream wires the cleanup into list-rendering screens so the card disappears in the same paint.

- [ ] **8. Middle-band rejection leaves no orphan in Studio** — repeat item 7 (backlit / partial-detection video). When the coral toast fires on the capture screen, swipe back to Studio. The exercise card MUST NOT be present in any state — no stuck spinner, no empty placeholder, no "0 reps" card.
- [ ] **9. Middle-band rejection leaves no orphan in ClientSessions** — back out to the client detail screen (`ClientSessionsScreen`). The pending-conversions count and the session card filmstrip MUST NOT show the rejected exercise. Tap into the session — the rejected card is absent from the Studio list.
- [ ] **10. Cold-start guard** — kill the app (swipe up in app switcher) and reopen. Land on Clients → tap into the client → tap into the session. Studio renders the surviving exercises correctly with no ghost spinner. (Pre-fix this was the ONLY way to clear the orphan; post-fix the orphan never existed in the first place, but the cold-start path stays clean.)

## D. Telemetry surfaces

The accepted-empty rows write to `capture_audit_events` via the new `record_safe_mode_capture_event` RPC. The portal audit feed surfaces them as a coral chip labelled `Accepted (empty)`; the live-page 24h drawer aggregates them in the per-trainer event count without rendering a visual dot.

- [ ] **11. Portal audit feed surfaces the accepted-empty rows** — open `https://staging.manage.homefit.studio/audit` in a browser, scope to the QA practice, scope to the practitioner who ran items 1–4 above. Four rows should appear with kind chip `Accepted (empty)` (coral). The description column shows "Accepted empty photo (complexity 0.xx)" or "Accepted empty video (complexity 0.xx)" — complexity numerics reflect the scene (low for the blank wall, higher for the equipment / outdoor shots). Practitioner + timestamp populated.

## Out of scope for this wave

- Native pipeline changes (`SafeModeProcessor`, `processPhotoSafeMode`, `applySafeModeV2ToPhoto`) — none made.
- Per-event drill-in modal on the audit feed (the chip is tappable but doesn't open a metadata modal yet; the description column carries the complexity numeric for at-a-glance scanning).
- Live-page drawer chip for accepted-empty events — by design, the drawer only renders photo/video dots; accepted-empty is roll-up only.
- Mobile Safe Mode top banner — no copy or behaviour change.
