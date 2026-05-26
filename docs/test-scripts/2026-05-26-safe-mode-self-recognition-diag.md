# Safe Mode self-recognition diagnostic — Wave M41 (2026-05-26)

Tests for the non-destructive Safe Mode match-probe Diagnostics action +
the per-face cosSim logging toggle. Lets you confirm whether the
enrolled face embeddings actually match what the Safe Mode matcher
generates from a fresh photo of you — without having to take a real
Safe Mode capture inside a premises polygon.

## What changed

- **New diagnostic action**: Diagnostics → "Test self-recognition".
  Takes a selfie via the system camera, runs the SAME face-detect +
  embed + cosSim pipeline that Safe Mode uses, compares against your
  Self-client's enrolled embeddings, surfaces the result in a bottom
  sheet.
- **New diagnostic toggle**: Diagnostics → "Log Safe Mode match
  details". When ON, every Safe Mode photo capture appends per-face
  cosSim values to `conversion_error.log` (readable via the long-press
  on the Studio "N failed" pill).
- **No Safe Mode behaviour change**: the production matcher is
  unchanged; the diagnostic is a separate non-destructive code path.

## Setup

1. Make sure your Self-client (the "Me" client in the My Workouts
   flow) has a face enrolled. If you haven't enrolled yet, do that
   first — the diagnostic will toast "No face enrolled yet" otherwise.
2. Open Settings → tap the homefit logo 7 times to unlock the hidden
   Diagnostics entry → Diagnostics.

## Active wave

- [ ] **1.** Diagnostics screen renders. New rows visible: "Log Safe
  Mode match details" toggle in the Debug toggles group; "Test
  self-recognition" action in the Actions group.

- [ ] **2.** Tap "Test self-recognition" with NO face enrolled on the
  Self-client. Toast says "No face enrolled yet on the Self-client.
  Enrol first via the client detail screen, then re-run this check."

- [ ] **3.** Enrol your face on the Self-client (6-angle sweep as
  before). After enrolment completes (you see the 6 quality scores),
  return to Diagnostics and tap "Test self-recognition" again. System
  camera opens with front camera preferred.

- [ ] **4.** Take a clean selfie (face centred, well-lit, looking at
  camera). Diagnostic runs and a bottom sheet appears. Read the
  Verdict row.

  - **If Verdict = "Recognised" (coral)**: the enrolment pipeline is
    producing embeddings that match what the matcher generates from a
    fresh photo. Self-recognition works. (`bestSim` should be ~0.45+.)
  - **If Verdict = "Recognised (low)"**: faces match but barely
    (bestSim 0.10-0.45). Pipeline working; consider re-enrolling for
    more pose variety.
  - **If Verdict = "NOT recognised" (red)** with branch=`solo-floor`:
    THIS IS THE BUG — Vision saw your face but cosSim is below the
    floor. The enrolled embeddings don't match the matcher's
    capture-time embedding for the SAME face. Pipeline mismatch.

- [ ] **5.** Take a selfie of someone else (or a printed photo of a
  random face). Diagnostic should report `NOT recognised` with low
  bestSim — confirms the diagnostic distinguishes the bound client
  from random faces.

- [ ] **6.** Toggle "Log Safe Mode match details" ON. Take a Safe Mode
  self-photo inside an enforcing premises polygon (or via the mock
  flow). Once it converts, long-press the "N failed" pill on the
  session card (or use the conversion-error log reader). The log
  should contain a `[SafeMode match diag]` line with per-face cosSim
  values + bestSim + branch.

- [ ] **7.** Toggle "Log Safe Mode match details" OFF. Take another
  Safe Mode self-photo. The log should NOT receive a new
  `[SafeMode match diag]` line for this capture.

## What we're learning

The diagnostic surfaces the **cosSim score the production matcher
would compute for your face** against your own enrolled embeddings.
If self-recognition fails on a 6-slot well-scored enrolment, the
embedding pipeline is broken — the enrolment-time face crop and the
capture-time face crop are feeding MobileFaceNet different sub-images
of the same face, producing incompatible embeddings.

The diagnostic does NOT fix the bug; it confirms whether the bug is
present and gives a reproducible measurement for the fix author to
verify against.
