# Wave 39.4 — Hotfix Plan

**Status:** Locked **2026-04-28**. Two parallel agents (mobile + portal). Closes Wave 39 device QA. Wave 40 fires after this lands.

**Source:** Wave 39 device-QA results at [docs/test-scripts/2026-04-28-wave39-bundle.results.json](test-scripts/2026-04-28-wave39-bundle.results.json) — items 1, 2 (could not test), 4, 14, 15. Plus the promoted timestamp fix from [BACKLOG.md](BACKLOG.md) Wave 39.3 (Dart UTC + per-viewer TZ render).

**Backfill decision (Carl, 2026-04-28):** No backfill. Fix the wire format going forward; SA-only cohort means existing audit rows render identically before and after.

---

## Mobile fixes (`app/lib/`)

### M1 · Sticky defaults — Pacing fields propagation (Item 1)

QA: "Thr Dose values propagated. The Pacing values did not."

Root cause: `StickyDefaults` only carries the seven Wave-8-era fields. Wave 24 added `videoRepsPerLoop` and Wave 28 added `interSetRestSeconds` — neither was added to the sticky-defaults pipeline, so practitioner overrides on those fields don't propagate to the next capture.

**Files:**
- [app/lib/services/client_defaults_api.dart](../app/lib/services/client_defaults_api.dart) — add `fVideoRepsPerLoop = 'video_reps_per_loop'` and `fInterSetRestSeconds = 'inter_set_rest_seconds'` constants; add both to `allFields`.
- [app/lib/services/sticky_defaults.dart](../app/lib/services/sticky_defaults.dart) — re-export the two new wire constants; extend `prefillCapture` to copy both fields onto a fresh `ExerciseCapture` (mirror the existing `??`-guarded pattern); extend `recordAllDeltas` (and `recordStudioSliderGroup` if those fields are mutated by the slider group) to fan out deltas for the two new fields.

**RPC:** No schema change. `set_client_exercise_default` writes any key into the `client_exercise_defaults` JSONB without an allowlist — the new keys land silently.

### M2 · Photo last-exercise refresh — proper fix (Item 4)

QA: "Fail. I again had to go out of studio and then when coming back in it was done." — the Wave 39 force-refresh-on-listener-miss didn't hold on device.

Root cause hypothesis: `_listenToConversions` at [app/lib/screens/studio_mode_screen.dart:353](../app/lib/screens/studio_mode_screen.dart) only fires `_refreshSession()` when the row is missing from `_session.exercises`. Two failure modes survive:
1. The listener finds the row (parent's `onCapturesChanged` won the race) but the row found is stale (still `converting`); the index-based replace plants the conversion event's payload but a subsequent `didUpdateWidget` (line 215-219) overwrites `_session` with the parent's older snapshot.
2. The conversion event arrives mid-page-swipe to Studio; `mounted` is true but the parent's `onCapturesChanged` propagation hasn't completed.

**Fix:** make the listener pull from SQLite unconditionally on every `done` event (not only on the missing-row path), and merge the conversion payload onto the SQLite snapshot so the in-memory state always matches storage. This makes `_session` self-healing against any racing `widget.session` push from the parent.

Pseudocode:
```dart
_conversionService.onConversionUpdate.listen((updated) async {
  if (!mounted) return;
  final fresh = await widget.storage.getSession(_session.id);
  if (!mounted || fresh == null) return;
  final merged = _mergeExercise(fresh, updated); // keep `updated` for the row
  setState(() => _pushSession(merged));
});
```

Verify after writing that `didUpdateWidget`'s parent-push doesn't clobber a newer `_session`. If it does, gate the `widget.session` adoption on a `lastUpdatedAt` comparison or a sequence number.

### M3 · Reachability drop-pill — latch persists until manual untoggle (Item 14)

QA: "If I'm activating this feature, I would like to be able to work at that reachability until I manually untoggle it myself."

Today: card tap unlatches; upward scroll > 20pt unlatches.
Want: ONLY the pill itself toggles the latch. Card taps and scroll do nothing to the latch state.

**Files:** [app/lib/screens/studio_mode_screen.dart](../app/lib/screens/studio_mode_screen.dart)
- Delete `_resetReachability()` and every call site (the function exists at line 273; remove call sites in card `onTap` paths).
- Strip the unlatch-on-upscroll branch inside `_onReachabilityScroll` (lines 263-266 — the `if (_isReachabilityLatched && (_lastReachabilityScrollPx - px) > 20)` block).
- Keep the `_canShowReachabilityPill` gate (lines 257-262) and the `didChangeAppLifecycleState` resume reset (line 239) — both are correct.

### M4 · Reachability drop-pill — clip content above toolbar when latched (Item 15)

QA: "When this is activated, the bottom of the screen shows scrolling content below the actual toolbar, which is very confusing."

When latched, the list slides down ~50%. The bottom toolbar floats above and content underneath remains visible. The fix: opaque mask under the toolbar OR clip the list view to a height that ends at the toolbar's top edge.

Recommend: wrap the list in a `ClipRect` (or apply a `BoxDecoration` with the same `--bg` colour as the toolbar's container) so anything below the toolbar's top edge is invisible.

Find the slide-down `Transform.translate` (or equivalent) in studio_mode_screen.dart and apply the clip on the parent. Match the toolbar's exact pixel height so the mask aligns to the toolbar's top edge.

### M5 · Dart wire timestamps → UTC

Source of truth for the bug: [docs/BACKLOG.md](BACKLOG.md) "Wave 39.3" entry.

**Files:**
- [app/lib/services/upload_service.dart](../app/lib/services/upload_service.dart) — four sites:
  - line 615: `'created_at': session.createdAt.toUtc().toIso8601String()`
  - line 681: same
  - line 682: `'sent_at': DateTime.now().toUtc().toIso8601String()`
  - line 856: `'issued_at': DateTime.now().toUtc().toIso8601String()`
- Grep `app/lib/` for any other `toIso8601String` that targets a Postgres `timestamptz`. Excluded (log-only, not Postgres-bound):
  - `diagnostics_screen.dart:413` — diagnostic dump
  - `capture_mode_screen.dart:619` — haptic-tick log
  - `loud_swallow.dart:257` — internal log payload
  - `unified_preview_scheme_bridge.dart:122-126` — local in-process bridge to the WebView player

**Quick audit:** also re-check `Session` and `ExerciseCapture` constructors. If any `createdAt`/`sentAt` field is initialised from `DateTime.now()` (not UTC), the `.toUtc()` chain at the wire emission site fixes it — but flag any remaining cases.

---

## Portal fix (`web-portal/`)

### P1 · Per-viewer-TZ rendering on audit + dashboard subtitles

Today: [web-portal/src/app/audit/page.tsx:550](../web-portal/src/app/audit/page.tsx) `fmtDate()` pins to `timeZone: 'UTC'` (Wave 39.2 revert). Browser-local rendering is what the practitioner expects; UTC-pin made sense as a stopgap when the Dart side was emitting unmarked-local strings.

**Scope:**
- New client component `web-portal/src/components/ClientTime.tsx`:
  ```tsx
  'use client';
  export function ClientTime({ ts }: { ts: string }) {
    const [text, setText] = useState(() => fmtDateUTC(ts)); // SSR fallback
    useEffect(() => {
      try {
        setText(new Date(ts).toLocaleString(navigator.language, {
          dateStyle: 'medium', timeStyle: 'short',
        }));
      } catch { /* keep SSR fallback */ }
    }, [ts]);
    return <>{text}</>;
  }
  ```
- Replace the three call sites in `audit/page.tsx`:
  - line 292: `<ClientTime ts={row.ts} />` (the table row TS cell)
  - line 360: `<>Prepaid via unlock at <ClientTime ts={prepaid} /></>` (subtitle)
  - line 370: `<>Used at <ClientTime ts={publishTsForUnlock} /></>` (subtitle)
- Keep `fmtDate` in `audit/page.tsx` as the SSR pre-hydration fallback (referenced inside `ClientTime` initial state, OR exported from a shared util).
- If `dashboard/page.tsx` previews recent audit events, port the same component there.

**Why a client component instead of server-side TZ inference:** the browser is the only place the user's TZ is actually known. Cookie-driven TZ propagation is more code for the same outcome.

---

## Test bundle

`docs/test-scripts/2026-04-29-wave39.4-hotfix.html`. Sections:
- **A · Sticky defaults — Pacing fields** (M1) — 2 items: edit `videoRepsPerLoop` on ex 1, capture ex 2 → inherits; same for `interSetRestSeconds`.
- **B · Photo last-exercise refresh** (M2) — 2 items: capture photo as LAST exercise → spinner clears in-place ≤ 1.5s; mid-list capture still works.
- **C · Reachability drop-pill latch** (M3, M4) — 4 items: latch persists across card tap; latch persists across upward scroll; only pill tap unlatches; content does NOT scroll under the toolbar when latched.
- **D · Timestamps** (M5, P1) — 2 items: publish a plan, immediately open it, look at audit → `plan.publish` and `plan.opened` both render in browser-local TZ within 60s of each other; mobile and portal agree.
- **E · Re-test sticky-defaults isolation per client** (was QA item 2) — 1 item.

Promote to slot 1 in [docs/test-scripts/index.html](test-scripts/index.html); demote Wave 39 bundle to "Past waves".

---

## Out-of-scope (intentional)

- Configurable system defaults in app Settings — already scoped as Wave 40 S1.
- Audit always-have-actor + dedicated Client column — already scoped as Wave 40 S2.
- Backfilling existing `plan_issuances.issued_at` — Carl's call: leave history as-is.

---

## Implementation order

Two agents fire in parallel (no file overlap):
1. **Mobile agent** — M1–M5, all in `app/lib/`. Builds simulator + device, requests Carl install when ready.
2. **Portal agent** — P1, all in `web-portal/`. Vercel auto-deploys on push.

Both author their slice of the test bundle in the same file (one PR commits the bundle once both agents have written their sections — handled by the agent that finishes second).

When both PRs merge → Wave 40 unblocks.
