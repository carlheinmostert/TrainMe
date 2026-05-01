# T2 Device QA Outcomes — 2026-05-01

Use this sheet on Carl's iPhone to record final T2 hardening verification.

- Device: `00008150-001A31D40E88401C`
- Build / SHA under test: `____________`
- Tester: `____________`
- Date/time: `____________`

---

## Result legend

- ✅ Pass — behavior matches expected outcome
- ⚠️ Partial — behavior visible but copy/timing/edge conditions differ
- ❌ Fail — behavior missing or incorrect
- N/A — not exercised in this run

---

## Scenario 1 — Consent preflight skipped warning (success path)

**Goal:** if Step 0 consent preflight RPC is skipped/fails open, publish still succeeds and warns.

### Steps
1. Start with a publishable session (no missing files, valid credits).
2. Introduce transient network disruption around publish start (or force RPC unavailability).
3. Trigger publish.

### Expected
- `Published ✓` appears.
- Follow-up warning appears:
  - "Published, but treatment-consent pre-check was skipped (...)"
  - "Server guard still enforced consent."

### Outcome
- Result: `✅ / ⚠️ / ❌ / N/A`  
- Notes: `______________________________________________`

---

## Scenario 2 — Optional artifact-failure warning (success path)

**Goal:** main publish remains successful while optional raw sidecar uploads warn.

### Steps
1. Publish a session where core media/exercise write succeeds.
2. Induce optional raw-archive sidecar upload failures/intermittency.

### Expected
- `Published ✓` appears.
- Follow-up warning appears:
  - "Published, but some optional treatment files are still processing (...)"
  - "Line treatment is live now; retry publish later to backfill."

### Outcome
- Result: `✅ / ⚠️ / ❌ / N/A`  
- Notes: `______________________________________________`

---

## Scenario 3 — Refund-unconfirmed warning (network failure after debit)

**Goal:** when publish fails after debit and refund is unconfirmed, practitioner sees explicit warning.

### Steps
1. Trigger a publish failure after `consume_credit` path (late-stage network interruption).
2. Observe failure UX.

### Expected
- `Publish failed: ...` snackbar appears.
- Additional warning appears:
  - "Credits may still be deducted. Check balance and contact support if it does not auto-reconcile."

### Outcome
- Result: `✅ / ⚠️ / ❌ / N/A`  
- Notes: `______________________________________________`

---

## Scenario 4 — Version-drift warning (failure after remote version bump)

**Goal:** make post-step-4 ambiguity visible when cloud version may already be ahead.

### Steps
1. Trigger failure after remote plan version bump but before full completion.
2. Observe failure UX.

### Expected
- `Publish failed: ...` snackbar appears.
- Additional version warning appears:
  - "Cloud may already be on vN. Share link may already point to this version."
  - (or equivalent "cloud version may already be ahead" wording)

### Outcome
- Result: `✅ / ⚠️ / ❌ / N/A`  
- Notes: `______________________________________________`

---

## Scenario 5 — Regression sanity checks

### 5a. Missing media preflight
- Expected: missing-media snackbar + scroll to broken card
- Result: `✅ / ⚠️ / ❌ / N/A`

### 5b. Unconsented treatment gate
- Expected: consent unblock sheet path still works
- Result: `✅ / ⚠️ / ❌ / N/A`

### 5c. Clean success baseline
- Expected: normal success UX without unexpected warning snackbars
- Result: `✅ / ⚠️ / ❌ / N/A`

Notes: `______________________________________________`

---

## Sign-off

- Overall result: `✅ Ready / ⚠️ Needs polish / ❌ Blocked`
- Follow-up issues created: `____________`
- Signed by: `____________`

