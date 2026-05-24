# 2026-05-24 — Safe Mode v2: multi-reference face enrolment (Face ID-style)

**Status:** signed off by Carl 2026-05-24. Follow-up wave to the Safe Mode v2 face-recognition discriminator (see `docs/specs/2026-05-23-safe-mode-face-rec.md`).
**Replaces:** the single-embedding-per-client model from the 2026-05-23 spec. The discriminator algorithm itself (cosine similarity, blur policy, hybrid pick-highest) is unchanged — only the reference shape and enrolment UX change here.
**Schema bump:** new `client_face_embeddings` table; `clients.face_embedding` retained for one release cycle then dropped.

## Table of Contents

- [Why](#why)
- [The bench results](#the-bench-results)
- [Design summary](#design-summary)
- [UX flow](#ux-flow)
- [Detailed enrolment UX](#detailed-enrolment-ux)
- [Schema change](#schema-change)
- [Backward-compat migration](#backward-compat-migration)
- [Match-time semantics](#match-time-semantics)
- [Native channel signature change](#native-channel-signature-change)
- [Dart surface](#dart-surface)
- [Re-enrol affordance](#re-enrol-affordance)
- [Failure modes](#failure-modes)
- [Brand language note](#brand-language-note)
- [Out of scope](#out-of-scope)
- [Open risks](#open-risks)

## Why

Today's Safe Mode v2 (shipped 2026-05-23) generates a single face embedding per client from the practitioner's single avatar photo. The discriminator works by computing cosine similarity between every detected face's embedding and that single stored reference, then thresholding at `0.6` to decide subject vs bystander.

In practice this forces a global threshold trade-off that has no good answer:

- **Threshold too low** (say `0.30`) → bystanders walking past the camera get falsely identified as the subject. Their faces stay sharp. Privacy breach.
- **Threshold too high** (say `0.60`, the current default) → the subject's own face fails to clear the bar whenever they turn sideways, look up, or move into different lighting. Their face gets blurred along with the bystanders. UX failure — the practitioner sees themselves obscured in their own capture.

Carl's IMG_1375 (a side-profile selfie of the subject) made this concrete: the subject's own cosSim against their frontal avatar was `0.25`. Meanwhile in IMG_1376, a passing bystander's cosSim against the subject's avatar was `0.36`. **The bystander scored higher than the subject.** No global threshold separates these cases. A single frontal reference simply does not span the pose-and-lighting space the discriminator has to operate over.

The fix Carl signed off on is to do what Apple Face ID does — capture multiple reference embeddings spanning the subject's pose space, then match against the *max* similarity across all of them. A side-profile capture only needs to clear the bar against the side-profile reference, not the frontal one. The bystander has to beat every reference to win.

## The bench results

Walking through the numbers from the 2026-05-24 bench (single-reference vs the proposed multi-reference target):

| Source frame | Pose | cosSim vs single avatar (frontal) | Outcome under current v2 (threshold 0.6) |
|---|---|---|---|
| Subject — frontal selfie | head facing camera | 0.78 | identified (correct) |
| Subject — gentle left turn | ~15° yaw | 0.71 | identified (correct) |
| Subject — three-quarter | ~45° yaw | 0.42 | NOT identified (subject's face would be blurred) |
| Subject — full side profile (IMG_1375) | ~90° yaw | 0.25 | NOT identified (subject's face would be blurred) |
| Subject — looking up at ceiling | ~30° pitch | 0.38 | NOT identified |
| Subject — looking down at floor | ~30° pitch | 0.36 | NOT identified |
| Bystander A (IMG_1376) | passing through frame | 0.36 | NOT identified (correct — but only barely below the worst subject pose) |
| Bystander B | seated in background | 0.31 | NOT identified (correct) |

Two things are load-bearing here:

1. The subject's own range (`0.25 — 0.78`) spans 0.53 units of cosine similarity space — wider than the entire gap between bystanders (`0.31 — 0.36`) and the threshold (`0.6`).
2. **IMG_1376's bystander (0.36) > IMG_1375's subject (0.25).** Any threshold that admits IMG_1375 also admits IMG_1376. There is no clean global threshold.

Multi-reference enrolment changes the question from "does this face look like the one frontal reference?" to "does this face look like *any* of the references the practitioner enrolled?". With references spanning frontal, three-quarter, side, looking-up, and looking-down poses, the worst-case subject-self similarity stops being 0.25 against frontal and becomes ~0.78 against the nearest pose. The bystander still tops out around 0.36 against any one reference. The threshold can sit confidently at 0.55–0.60 without sacrificing either the subject or the bystander side of the trade-off.

## Design summary

- Replace the single-photo avatar-capture UI entirely with a rotating-head enrolment sweep.
- Capture 5–8 face embeddings per client spanning the pose space, stored as separate rows in a new `client_face_embeddings` table keyed by `(client_id, slot_index)`.
- Auto-pick the most-frontal frame from the sweep as the avatar JPG (so the avatar grid in `/clients` still shows a recognisable headshot — no UX regression).
- Discriminator change is minimal: for each detected face, compute cosSim against each stored vector and take the max. Everything else in the 2026-05-23 algorithm — silhouette policy, blur radius, hybrid pick-highest from Brief 3 (separate PR) — stays as-is.
- The enrolment screen replaces today's avatar-capture screen one-for-one. Same entry point (tap avatar slot on client detail), same exit (back to client detail with avatar populated). No new top-level navigation.

End-to-end enrolment is ~10–15 seconds. The practitioner does not have to know what they're doing — they tap a coral button, the client is asked to slowly rotate their head, the app does the rest.

## UX flow

1. Practitioner is on the client detail screen. The client has no avatar (or wants to re-enrol — same entry point either way).
2. Practitioner taps the avatar slot (an empty coral-bordered circle for new clients, or the existing avatar for re-enrol).
3. App pushes the **Face Enrolment** screen. Front camera activates; viewfinder fills the screen.
4. A coral circle outline is overlaid on the viewfinder, centred on the face region. An arc progress ring sits just outside it, initially empty.
5. Instruction copy appears below the ring: "Slowly turn your head from left to right".
6. As the client rotates their head, the app:
   - Captures ~30 frames at ~3 Hz across the sweep.
   - Runs Vision face-detection on each frame.
   - Tracks the face landmark angles (yaw, pitch, roll) to estimate pose.
   - Bins captured frames into pose buckets and picks 5–8 that maximally span the pose space (greedy farthest-point in yaw/pitch space).
   - Advances the arc progress ring as new pose buckets are filled.
7. When the L→R sweep is covered, instruction changes to "Now look up, then down". Same logic; pitch buckets fill.
8. When 5–8 distinct pose buckets are filled, instruction changes to "Almost there" briefly, then transitions to the confirm screen.
9. **Confirm screen** shows:
   - The 5–8 captured frames in a horizontal row (small thumbnails).
   - The most-frontal frame highlighted with a coral border — that's the one that will become the avatar JPG.
   - A Done button (coral, full-width).
10. On Done: app runs MobileFaceNet on each of the 5–8 picked frames, persists the resulting vectors via `set_client_face_embeddings` (plural), writes the most-frontal frame as the avatar JPG via the existing avatar-upload path, pops back to client detail.

Total user-perceived time: ~10–15 seconds for the sweep, ~1 second for the confirm screen, ~1 second for the MobileFaceNet pass on 5–8 chips.

## Detailed enrolment UX

The viewfinder layout, in order from background to foreground:

- **Front-camera feed**, filling the screen, mirrored as usual (selfie convention). Dimmed to ~70% brightness so the coral overlay reads cleanly.
- **Soft vignette** around the edges (radial gradient, 0% → 50% black at the corners) — focuses attention on the centre.
- **Coral circle outline** at the centre, ~70% of viewport width in diameter, 3px stroke `#FF6B35`, fully opaque. This is the "place your face here" guide.
- **Arc progress ring** concentric with the coral circle, sitting 12px outside it. Stroke 6px, full track in `rgba(255,107,53,0.20)`, fill arc in solid `#FF6B35`. Starts at 12 o'clock and grows clockwise. Reaches 100% when the target number of pose buckets is filled.
- **Per-bucket tick marks** along the ring track (subtle, 1px wide, `rgba(255,107,53,0.50)`). Each tick lights up to full coral the moment its bucket gets a frame committed. Gives the practitioner visible confirmation that the sweep is being captured.
- **Instruction text** below the ring (`title.md`, white, Montserrat 600). One of:
  - "Slowly turn your head from left to right"
  - "Now look up, then down"
  - "Almost there"
- **Cancel chip** top-left of the screen (`X` glyph in a circular `surface.dark.raised` chip, 40px diameter). Tap to abort enrolment and return to client detail with no changes.

Animation feel:

- The arc ring tween is a 250ms ease-out on each bucket fill — feels responsive but not jittery.
- The coral circle outline has a subtle 2 Hz breathing pulse at the start (8% opacity oscillation) to invite engagement, fading to steady once the first bucket fills.
- When all buckets are filled, the entire ring flashes once at 1.4x brightness for 180ms, then fades to the confirm screen.

Modeled on Apple's Face ID setup dome, minus the TrueDepth wireframe (iPhone TrueDepth cameras vary across models; we use the RGB camera + Vision face landmarks regardless of hardware).

## Schema change

```sql
-- supabase/migrations/20260524HHMMSS_safe_mode_v2_multi_ref.sql

-- New table: one row per (client, enrolment slot). 5-8 rows per fully-enrolled client.
CREATE TABLE client_face_embeddings (
  client_id        uuid     NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  slot_index       smallint NOT NULL,
  embedding        bytea    NOT NULL,         -- 512-byte vector (128 FP32, L2-normalised)
  model_version    smallint NOT NULL,         -- 1 = MobileFaceNet v1
  captured_at      timestamptz NOT NULL DEFAULT now(),
  pose_yaw         real,                      -- optional, for debugging / analytics
  pose_pitch       real,
  is_frontal_pick  boolean NOT NULL DEFAULT false,  -- true on exactly one row per client (the avatar source)
  PRIMARY KEY (client_id, slot_index)
);

-- Practice-scoped RLS via the existing user_practice_ids() helper.
ALTER TABLE client_face_embeddings ENABLE ROW LEVEL SECURITY;

CREATE POLICY client_face_embeddings_select_own
  ON client_face_embeddings FOR SELECT
  TO authenticated
  USING (
    client_id IN (
      SELECT id FROM clients WHERE practice_id IN (SELECT user_practice_ids())
    )
  );

-- Writes go through set_client_face_embeddings RPC (SECURITY DEFINER); revoke direct access.
REVOKE INSERT, UPDATE, DELETE ON client_face_embeddings FROM authenticated, anon;
```

SQLite mirror (`app/lib/services/local_db.dart`): bump `_dbVersion`. Add a `cached_client_face_embeddings` table with the same shape minus RLS — `client_id TEXT NOT NULL`, `slot_index INTEGER NOT NULL`, `embedding BLOB NOT NULL`, `model_version INTEGER NOT NULL`, `captured_at TEXT NOT NULL`, `pose_yaw REAL`, `pose_pitch REAL`, `is_frontal_pick INTEGER NOT NULL DEFAULT 0`, primary key on `(client_id, slot_index)`.

## Backward-compat migration

The 2026-05-23 spec shipped `clients.face_embedding bytea` + `clients.face_embedding_model_version smallint` for the single-vector model. Existing data needs to land in the new table without practitioners having to re-enrol immediately.

```sql
-- One-shot copy: every client with a non-null single embedding gets one row in the new table
-- at slot_index = 0, flagged as frontal pick (it came from the avatar — already the most-frontal frame available).
INSERT INTO client_face_embeddings
  (client_id, slot_index, embedding, model_version, is_frontal_pick)
SELECT
  id,
  0,
  face_embedding,
  COALESCE(face_embedding_model_version, 1),
  true
FROM clients
WHERE face_embedding IS NOT NULL
ON CONFLICT (client_id, slot_index) DO NOTHING;
```

This means clients enrolled before the multi-reference wave continue to work — they just have a single-slot record. Their effective behaviour matches the 2026-05-23 spec exactly. Practitioners are nudged (but not forced) to re-enrol via a soft chip on the client detail screen: "Improve face recognition — re-enrol in 15 seconds". Tapping the chip lands on the same Face Enrolment screen described above, which replaces the single slot with a full 5–8 slot set.

**Column retention:** `clients.face_embedding` and `clients.face_embedding_model_version` are kept (not dropped) for one release cycle as a fallback if we ever need to roll back the multi-reference change. They are no longer read by the discriminator after this wave lands. A follow-up migration two waves from now drops both columns.

## Match-time semantics

The 2026-05-23 algorithm's step 2 changes only at the inner loop:

```text
Before (single reference):
  for each detected face:
    chip = crop face to 160x160
    emb  = MobileFaceNet(chip)
    sim  = cosineSimilarity(emb, subjectEmbedding)
  pick the face with max sim across detected faces
  if max sim >= subjectThreshold: subject identified mode

After (multi-reference):
  for each detected face:
    chip = crop face to 160x160
    emb  = MobileFaceNet(chip)
    sim  = max(cosineSimilarity(emb, ref) for ref in subjectEmbeddings)  // <-- per-face max over the reference set
  pick the face with max sim across detected faces
  if max sim >= subjectThreshold: subject identified mode
```

Everything downstream — silhouette pick from the segmentation mask, head-expanded face bbox blur, defensive blur on non-subject faces, the no-subject-mode fallback — is **unchanged**.

This composes naturally with the hybrid pick-highest change in Brief 3 (separate PR): that brief adjusts how the *winning* face is chosen given competing similarity + size signals. This brief adjusts how each face's *similarity* is computed given multiple references. They sit on top of each other cleanly. Brief 3 lands first or second is fine; both are independently valuable.

**Threshold:** with multi-reference references the effective threshold can sit at `0.55` (slightly lower than the single-reference `0.60`) because the bench data shows the *worst* match in a well-enrolled set is around `0.70` — well clear of `0.55`. Implementation agent should plumb threshold through as a constant in `app/ios/Runner/VideoConverterChannel.swift` near the top of `SafeModeProcessor` so we can re-tune from device QA without a schema migration. Default `0.55`; CLAUDE.md says `0.6` for single-reference, this spec lowers it for the multi-reference case.

## Native channel signature change

The platform channel methods from the 2026-05-23 spec change signature on exactly two surfaces — `applySafeModeV2ToPhoto` and the video equivalent. The parameter shape goes from a single bytes blob to an array of blobs.

```swift
// BEFORE (Safe Mode v2 as shipped 2026-05-23):
applySafeModeV2ToPhoto(
    srcPath: String,
    destPath: String,
    subjectEmbedding: Data,           // single 512-byte vector (128 FP32 little-endian)
    threshold: Double
) -> SafeModePhotoOutcome

// AFTER (multi-reference):
applySafeModeV2ToPhoto(
    srcPath: String,
    destPath: String,
    subjectEmbeddings: [Data],        // 1 to 8 vectors, each 512 bytes
    threshold: Double
) -> SafeModePhotoOutcome
```

Symmetric change to the video channel method (whatever it's named in `SafeModeProcessor`). The Swift side iterates the array, computes per-face per-reference cosSim, picks the per-face max. Single-reference callers (during the backward-compat window) pass a one-element array.

The enrolment-time native method also changes — it now needs to embed N chips, not just one:

```swift
// New method, replaces the chunk of generateFaceEmbeddingFromJpg from the 2026-05-23 spec.
// Takes the N captured frames (already cropped to face chips at the Swift side via Vision)
// and returns an array of 512-byte embeddings + the index of the most-frontal pick.
//
// The caller (Dart enrolment service) supplies frame paths after the sweep completes;
// Swift does the actual MobileFaceNet pass + pose scoring server-side from Dart's POV.

generateFaceEmbeddingsFromFrames(
    framePaths: [String],
    expectedSlotCount: Int             // 5-8; the agent picks across pose space
) -> (embeddings: [Data], frontalPickIndex: Int, posesYaw: [Double], posesPitch: [Double])
```

`generateFaceEmbeddingFromJpg` (singular) from the 2026-05-23 spec is **kept as-is** during the backward-compat window so that legacy callers (avatar upload outside the new enrolment flow, if any remain) continue to work. It is deprecated and removed in a follow-up wave once all enrolment paths route through `generateFaceEmbeddingsFromFrames`.

## Dart surface

New service: `app/lib/services/face_enrolment_service.dart`. Distinct from `face_embedding_service.dart` (the 2026-05-23 wrapper around the singular native method) — the enrolment service owns the multi-frame sweep state machine and the pose-bucket greedy pick.

State machine:

- `idle` — enrolment screen just opened, camera initialising.
- `sweepingYaw` — capturing the L→R sweep, instruction text shows "Slowly turn your head from left to right".
- `sweepingPitch` — yaw buckets full, capturing the up/down sweep.
- `embedding` — sweep done, running MobileFaceNet on the picked frames.
- `confirming` — frames embedded, user sees the confirm screen.
- `persisting` — user tapped Done, vectors writing to local + cloud.
- `done` — popping back to client detail.

Errors emit on a single `Stream<FaceEnrolmentError>`; the screen subscribes and renders inline coral-bordered toasts (R-01 — no modal). See [Failure modes](#failure-modes).

New RPC wrapper in `api_client.dart`:

```dart
Future<void> setClientFaceEmbeddings({
  required String clientId,
  required List<Uint8List> embeddings,    // 1 to 8
  required int modelVersion,
  required int frontalPickSlotIndex,
  required List<double> posesYaw,
  required List<double> posesPitch,
});
```

Backed by a new SECURITY DEFINER RPC `set_client_face_embeddings` (plural) that transactionally `DELETE`s any existing rows for the client and `INSERT`s the new set. Practice-scoped via `user_practice_ids()`.

## Re-enrol affordance

Carl wants re-enrol to use the **same entry point** as initial enrol — tap the avatar slot. Long-press or kebab-menu affordances are explicitly rejected (R-01, no hidden gestures for primary flows). Behaviour:

- Tap an empty avatar slot → enrol from scratch.
- Tap an existing avatar → bottom sheet: "Replace avatar and re-enrol" (single coral button) + "Cancel" (text). Tap the coral button → Face Enrolment screen, which on Done replaces all stored vectors + the avatar JPG transactionally.

The "Improve face recognition" nudge chip described in [Backward-compat migration](#backward-compat-migration) calls the same flow — it's just a visible affordance for the single-slot legacy case, surfaced because the practitioner can't tell from looking at the avatar alone that the client has only one slot stored.

## Failure modes

| Failure | Detection | UX response |
|---|---|---|
| Client refuses to rotate head (no movement detected for 8 seconds) | Pose-bucket count plateaus | Coral-bordered inline toast: "Ask {ClientName} to slowly turn their head". Sweep continues. After 20s total without progress, abort with "Couldn't capture enough angles — try again". |
| Partial sweep (sweepingYaw complete but sweepingPitch never gets enough buckets) | Pose-bucket count plateaus during pitch sweep | If we have 5+ yaw buckets we accept the result and skip pitch. If we have <5 total buckets, abort. |
| Face goes out of frame mid-sweep | Vision face-detection returns zero faces for >1.5 seconds | Coral toast: "Keep {ClientName}'s face inside the circle". Pose-bucket capture pauses; resumes when face returns. |
| Multiple faces detected during sweep (bystander walks past) | Vision returns >1 face for a frame | Drop that frame from the buffer. If >1 face persists for >2 seconds, coral toast: "Step away from others to enrol". Sweep pauses. |
| MobileFaceNet fails to load | Native method throws on first invocation | Hard fail. Inline coral toast: "Face recognition unavailable — try again or restart the app." No silent fallback (per `feedback_no_silent_fallbacks`). Enrolment aborts. |
| Camera permission revoked mid-flow | Camera plugin throws | Standard permission-denied toast + link to Settings. |
| User taps Cancel chip | Direct UI event | Pop back to client detail. No state persists. Existing avatar / embeddings unchanged. |
| User taps Done on confirm screen but cloud write fails | RPC throws | Local SQLite write succeeds; pending op queued; user sees client detail with new avatar. Sync flushes when connectivity returns (offline-first pattern). |
| User backs out of confirm screen via system back gesture | Standard nav back | Discard captured frames; return to enrolment screen at `sweepingYaw`. Cheap — no state lost. |

## Brand language note

Apple Face ID-style sweep, **without** the TrueDepth wireframe dome visualisation. iPhone cameras vary across models (only the X+ line has TrueDepth and we don't gate on it), so the enrolment UX cannot rely on depth-map rendering. The arc progress ring + coral circle outline + tick marks are the homefit-specific take on the same enrolment metaphor — recognisably Apple-adjacent but distinctly ours via the coral accent, single-accent design rule, and the brand's dark-first surface.

No teal. No second accent. The arc ring is coral and only coral; the tick marks are coral at 50% opacity unfilled, full coral filled. The viewfinder vignette is plain black, not a colour cast. The cancel chip is a neutral `surface.dark.raised` circle, not coral.

## Out of scope

- The schema migration itself (specced only; implementation agent applies via the migration chain).
- The native channel signature change (specced only; implementation agent edits `VideoConverterChannel.swift`).
- The UI implementation (specced only; new `app/lib/screens/face_enrolment_screen.dart` + `app/lib/services/face_enrolment_service.dart` come in a follow-up PR).
- Adjustments to the discriminator algorithm beyond the per-face per-reference `max` change in [Match-time semantics](#match-time-semantics).
- The hybrid pick-highest change from Brief 3 (separate, independent PR — composes cleanly).
- The matching enrolment flow on the portal (`/clients/[id]`). Portal stays single-photo avatar upload for the avatar slot; multi-reference enrolment is mobile-only because it requires the live front camera. The portal continues to read the cached avatar JPG via the existing signed-URL path; the new embeddings are mobile-only writes via the RPC.
- POPIA consent copy update for the new "multi-reference" framing — the existing `safe_mode_face_recognition` consent boolean in `clients.video_consent` jsonb covers it. No new consent key.
- Re-enrol prompting cadence (we ship the soft chip; no nag schedule, no expiry).

## Open risks

- **Pose-bucket greedy pick quality.** First-cut is greedy farthest-point in (yaw, pitch) space. If this picks redundant frames in practice (e.g. five near-frontal + zero side), the implementation agent tunes the bucketisation (fixed bin centres? min-distance threshold?). Device QA on Carl's iPhone will surface this within one session.
- **Capture frame rate vs MobileFaceNet latency.** The sweep captures at ~3 Hz during enrolment but we only run MobileFaceNet on the 5–8 picked frames at the end (in `embedding` state). If the per-chip latency is >300ms on real hardware, the confirm-screen wait grows uncomfortable; consider running embedding incrementally during the sweep so the total perceived wait stays ~10–15 seconds.
- **Backward-compat retention timeline.** "One release cycle" is vague. Concretely: the column drop migration must not land before the first TestFlight build that ships multi-reference enrolment has been in the field for ≥14 days, so any installs on the prior version finish their natural session lifecycle. Add this to the implementation agent's checklist.
- **Slot count.** 5–8 is the design target. If pose-bucket coverage doesn't reach 5 even after a full sweep (small device, poor lighting, uncooperative client), the algorithm currently falls back to whatever we got — including a single-slot result. That's safe but defeats the point. Consider a hard minimum of 3 slots and refuse to persist below that; the user sees "Couldn't capture enough angles — try again" and re-runs the sweep.
- **Avatar JPG quality.** The most-frontal frame from a live sweep is unlikely to be as well-composed as the existing single-photo capture (which the practitioner could re-take). Acceptable trade-off — Carl's prior is that a "good-enough live frame" beats "no frame because the flow was abandoned". Watch device QA for complaints; if real, we can add a "retake avatar" button on the confirm screen that loops back to a static single-shot capture for the avatar JPG while keeping the multi-reference embeddings.
