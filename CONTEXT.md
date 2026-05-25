# homefit.studio

The trainer-facing app, the client-facing web player, and the practice-owner-facing web portal of homefit.studio — a multi-tenant SaaS where biokineticists, physiotherapists, and fitness trainers capture exercises during a session, the device converts them into clean line-drawing demonstrations, and the practitioner shares a plan with the client via a WhatsApp-friendly link.

## Language

### Tenancy & people

**Practice**:
The top-level tenancy boundary; every practitioner-owned row carries a `practice_id`.
_Avoid_: account, org, organization, team

**Practitioner**:
An authenticated user who creates plans and consumes credits.
_Avoid_: trainer, bio, biokineticist (as a generic), physio, coach, fitness trainer

**Practice member**:
A practitioner-in-practice with a role (`owner` or `practitioner`).

**Owner**:
A practice member who can invite other practitioners and purchase credits.

**Client**:
The recipient of a plan; never authenticated; accesses plans via an unguessable Plan URL.
_Avoid_: user, customer, patient

**Self-client**:
A Client row whose `user_id` column references the publishing User themselves (`clients.user_id = auth.uid()`). Exactly one per User, living in their personal practice (the auto-bootstrapped practice every User gets at first sign-in). Created lazily on Public profile save (the moment the user uploads their reference selfie and opts into self-trainer features). Default name is "Me". Hidden from the Practice mode Clients tab — addressed only via the My Workouts surface. Plans owned by a Self-client are credit-exempt at Publish time when all exercises pass self-verification. Self-clients do NOT exist in non-personal practices — a practitioner demonstrating a movement at "Sarah's Physio" captures inside that client's session, not as a separate self-capture.
_Avoid_: me-client, owner-client, self-subject

**User**:
An `auth.users` row (i.e. a practitioner or self-trainer). Never used to refer to the client.
_Avoid_: account

**Self-trainer** (provisional term — not locked):
A `User` whose practice contains exactly one Client: themselves. They capture their own workouts (vanity / form study) using Safe Mode inside gyms. Schematically identical to a Practitioner (same `auth.users` row, same `practice_members` row in an auto-created personal practice, same `clients` row with the user as the subject), but credit-exempt as long as captures pass on-device face verification against a reference selfie registered in Settings. Safe Mode for self-trainers is a paid subscription (separate SKU from per-publish credits).
_Avoid_: athlete, gym-goer, influencer, end-user, prosumer (until term is locked)

**Self-verification**:
On-device MobileFaceNet check that the largest face in a captured frame matches the embedding of the user's registered Public-profile selfie. Verified → exercise row stamped `self_verified = true`. Unverified (mismatch OR no face detected) → `self_verified = false`. Capture is never blocked by verification failure — the flag feeds the credit decision at publish time, not the capture flow itself. A practitioner snapping a gym machine for reference is not punitive.
_Avoid_: identity check, owner check, face match

**Self-reference selfie**:
The front-camera selfie a user registers in Settings → Public profile. Already captured today for Safe Mode transparency (first name + last name + face); the self-trainer wave adds a MobileFaceNet embedding column to the existing `practitioners` row so the same selfie powers both transparency and self-verification. Re-registration is manual (re-take button in Settings, always available); no scheduled prompts.
_Avoid_: identity photo, reference frame

### Plans & sessions

**Session**:
Internally, the workout-plan object the practitioner creates (Flutter `Session` model; legacy DB context).
_Avoid_: workout, plan (when speaking trainer-side)

**Plan**:
The client-facing presentation of the same object; "Plan URL" is what gets shared.
_Avoid_: program, routine, workout (when speaking client-side)

**Plan URL**:
The unguessable UUID-bearing link a client opens to view their plan.

**Exercise / ExerciseCapture**:
One item in a session; carries `mediaType` of photo, video, or rest.
_Avoid_: move, drill, step

**Circuit**:
A group of consecutive exercises sharing a `circuitId`, repeated `circuitCycles` times.
_Avoid_: superset, round-set, block

**Rest period**:
A special exercise with `mediaType: rest`; rendered as a compact inline bar between exercise cards.
_Avoid_: break, pause, intermission

**Plan version**:
The integer that increments on each Publish; the Plan URL stays the same and the client always sees the latest.

**Plan issuance**:
An append-only audit row recording each publish event.

**Publish**:
The universal verb for converting a captured session into one or more durable cloud-rendered artifacts. Identical action for every User (Practitioner publishing for a Client, Self-trainer publishing their own session). Cost is determined at publish time, not by the action itself: 0 credits if (the session's Client is the User themselves AND every exercise has `self_verified = true`); otherwise 1 credit (≤75 min estimated duration) or 2 credits (>75 min). Safe Mode subscription is a separate gate at capture time, orthogonal to publish cost.
_Avoid_: save (when speaking of publish), share (publish is what makes sharing possible; the actions are distinct)

**Plan artifact**:
One of N durable outputs produced by a Publish. Today there is only one kind: the **Plan URL** at `session.homefit.studio/p/{uuid}`. The artifact axis is designed to accommodate future kinds (e.g. a Reel artifact — downloadable vertical MP4 for social posting) without forking the publish flow. PDF handout (currently on-device only) is a candidate to migrate into the artifact model retroactively.
_Avoid_: output, deliverable, render

**Client session**:
One row per unique visitor session on a published plan (analytics surface). Distinct from a workout Session.

### Capture & playback

**Capture mode**:
The camera-viewfinder pane of the trainer-app session shell.

**Studio mode**:
The editor pane of the trainer-app session shell.

**Demo**:
The captured-asset editing surface for one exercise — trim window, Hero frame, treatment, body focus, audio. Lives as the default tab of the exercise editor sheet. The word echoes "line-drawing demonstrations" in the product narrative.
_Avoid_: preview (reserved for the workflow Preview step), media, clip, footage

**Preview**:
The full-session walkthrough step in the trainer-app CAPS workflow chain (Capture → Adjust → Preview → Publish → Share). Mounts the same web-player bundle the client sees. Session-scoped, never per-exercise.
_Avoid_: walkthrough, run-through

**Treatment**:
The visual rendering of a captured video: Line, B&W, or Original.
_Avoid_: filter, style, variant, mode (when referring to rendering)

**Line drawing**:
The on-device-generated black-and-white outline rendering of an exercise video; the core IP.
_Avoid_: sketch, pencil drawing, outline (in product copy)

**Body focus**:
A practitioner-toggled segmentation that pops the body and dims the background. Practitioner-controlled, not client-controlled.
_Avoid_: enhanced background, blur background, segmentation

**Hero frame**:
The static thumbnail frame picked from a captured video clip for use in cards and previews.

**Soft-trim**:
A practitioner-set in/out window on a captured clip (`start_offset_ms` + `end_offset_ms`).
_Avoid_: trim, clip, crop (when referring to time)

**Hold position**:
A three-mode ENUM on a set controlling where a hold timer lands: `per_rep`, `end_of_set`, `end_of_exercise`.

**Pill matrix**:
The visual progress indicator (one pill per rep + a sage rest block per set). Used on the workout-preview screen and the client web player.
_Avoid_: progress bar, dots

**Rep stack**:
The vertical block stack used on the client web player; reps stack bottom-up with rest blocks between sets.

**PDF handout**:
The static printable multi-page PDF derived from a plan's lobby content — exercises, reps, sets, hold positions, Hero frames, practitioner notes, plus a QR code linking to the live plan. Generated on-device, free, available pre-publish and post-publish from the Preview step (mobile) or the lobby's Share button (web). Some practitioners ship only PDFs and never publish.
_Avoid_: printout, snapshot, lobby PNG (the PNG-modal path was superseded by PDF)

**Lobby export**:
Internal/technical name for the on-device PDF generation pipeline (`web-player/lobby.js` jsPDF rasterisation + multi-page assembly) and the iOS shell bridge (`unified_preview_screen.dart` `share_file` MessageChannel). Surfaced to practitioners as **PDF handout**.

**Clipboard**:
An in-memory, transient, single-practice-scoped holding area for copied exercises. Items are pointers to source exercise rows (not snapshots); the deep copy of media files + row materialisation happens at paste time. Items clear on app cold-start, crash, or process termination — there is no SQLite table and no individual-item management surface. Surfaced as a coral chip at the top-right of the Studio AppBar when count ≥ 1; tapping opens a bottom sheet where items are selected-by-default for batch paste at the end of the current session. Long right-swipe on a Studio card is the dominant copy gesture (partial swipe reveals `[Copy] [Duplicate]`); the per-exercise editor sheet also exposes a Copy button in its reachability-inverted bottom AppBar. Not to be confused with the iOS pasteboard — the homefit Clipboard never touches the OS clipboard. See ADR-0023 for why transient was chosen over persistent.
_Avoid_: stash, tray, pasteboard, exercise bank (when speaking of the in-app feature)

### Billing & credits

**Credit**:
A unit of publishing capacity; 1 for plans ≤75min estimated duration, 2 for plans >75min.
_Avoid_: token, point, charge

**Safe Mode subscription**:
A 30-day per-User unlock that permits capture inside any Safe Mode enforcing geofence. **Credit-denominated** — purchased by debiting 4 credits / month (R100 at the locked R25/credit rate) from the same `credit_ledger` that powers per-publish credit consumption. New ledger `kind = 'safe_mode_month'`. Orthogonal to publish credits: subscription gates the *Capture* step (working inside protected spaces); credits gate the *Publish* step (for-others artifact creation). Independent of role — a practitioner coaching at a gym needs it the same way a self-trainer working out there does. A practitioner who stays in their private clinic never crosses a geofence and never sees the gate. First subscription includes a one-time 3-day free trial (33 days total for the cost of 30; no debit until day 4); future renewals + subs are full-priced from day 1. Renewal is **manual** at v1 — push notification at day 25, re-up via Settings → Subscription. Lapse only gates future in-premises captures; existing captures and already-published Plan URLs stay accessible forever ("honor what you sold"). Subscribing via `manage.homefit.studio` (Reader-App compliance — no in-app prices or Subscribe buttons in the mobile app). Activates the referral-rebate flywheel for self-trainers: gym people refer gym people; the 5% lifetime rebate on referee credit purchases gives the rebate ledger a consumer-side sink (previously only practitioner-spendable on publishes).
_Avoid_: gym pass, premium tier, plus plan, monthly pass

**Bundle**:
A pack of credits sold on the web portal via PayFast.

**Credit ledger**:
The append-only RPC-write-only table that records every credit movement (purchase, consumption, refund, adjustment, signup bonus, referral rebate).

**Goodwill floor**:
The 1-credit clamp applied to the referrer's first rebate from each referee when raw 5% rounds to less than 1.

**Signup bonus**:
Credits granted at signup time: +3 organic; +5 additional on referral claim (8 total for referred signups).

**Lifetime rebate**:
The 5% of credits-bought that is credited to the referrer for every referee purchase, indefinitely.

### Referrals

**Referral code**:
The opaque 7-character slug a practice can hand out; unambiguous alphabet.

**Referee**:
A practice that signed up using a referral code.

**Referrer**:
A practice that owns the referral code a referee used.

**Single-tier**:
The DB-enforced constraint that a referrer cannot itself be a referee of another practice; A→B→C pays A nothing from C.

### Analytics

**Plan analytics event**:
An append-only event emitted from the web player during a client's visit (13 event types).

**Analytics opt-out**:
A per-plan client-initiated record that stops all future event recording for that plan.

**`analytics_allowed`**:
The consent key in the client's `video_consent` jsonb that gates analytics collection.

### Surfaces

**Trainer app**:
The Flutter iOS mobile app — the practitioner's tool.

**My Workouts** (tab / `HomeScope.workouts`):
The user-scoped home surface containing the User's own self-captures (Plans owned by their Self-client, living in their personal practice) UNION inbound Plans shared by other practitioners via the `plan_invitations` pipeline. The possessive ("My") is load-bearing — it signals identity ownership of the surface, distinguishing it from the for-others Practice mode. Body copy ("Your workouts") and chip label ("My Workouts") together make the personal pronoun explicit in both first and second person. The bottom-right "New Session" FAB mints a session bound to the Self-client and navigates straight into Session shell with Camera as the default mode. **Home chrome was stripped 2026-05-22** — no practice chip, no credits chip, no identity row. Everything status-related lives in Settings (practice in Account; credits on the portal dashboard). My Workouts inherits this minimal chrome with no per-scope additions other than the FAB. Subscription status surfaces contextually inside the Safe Mode active banner when the user is inside an enforcing geofence; outside geofences it's never shown on Home (information appears precisely when actionable). The "Updated N min ago" sync hint and the sync-failed banner — both today Clients-scope-only — are extended to My Workouts as part of this wave (the personal-practice pull cycle is the same machinery).
_Avoid_: Workouts (alone — drops the identity signal), Library, Solo, Mine

**Web player**:
The client-facing read-only surface at `session.homefit.studio/p/{planId}`.

**Web portal**:
The practice-owner-facing portal at `manage.homefit.studio` — credits, audit, members.

**Lobby**:
The entry screen of the web player, before the client taps Start Workout.

### States

**Soft-delete**:
A tombstoned row with `deleted_at` set; recoverable from the 7-day recycle bin.
_Avoid_: archive, hide, remove

**Conversion status**:
The per-exercise pipeline state (pending, converting, ready, failed).

**`pending_op`**:
A queued offline-first write awaiting connectivity to flush to the cloud.

## Relationships

- A **Practice** has many **Practice members** with roles owner | practitioner
- A **Practitioner** can belong to many **Practices** (multi-tenancy from day one)
- A **Practice** has many **Clients**; **Plans** are scoped by practice through the client
- A **Client** belongs to exactly one **Practice** (unique on `(practice_id, name)`)
- A **Session** (trainer-side) is one **Plan** (client-side) — same object, two surfaces
- A **Session** has many **Exercises**, optionally grouped into **Circuits** and separated by **Rest periods**
- A **Circuit** is `circuitCycles`-many repeated **Exercises** sharing a `circuitId`
- Each publish increments the **Plan version** and writes one **Plan issuance** row
- Each publish consumes 1 or 2 **Credits** atomically via `consume_credit`
- A **Client session** is one visitor session on the web player; emits **Plan analytics events**
- A referee's **Referrer** receives a **Lifetime rebate** of 5% of every referee purchase, with the **Goodwill floor** clamping the first sub-1-credit rebate up to 1

## Example dialogue

> **Practitioner:** "I want to update Melissa's plan — she opened it last week and I noticed the squat form needs a rep count tweak."
> **Carl:** "That's a non-structural edit on the same Plan URL, so it's free; she'll see version N+1 when she opens it again."
> **Practitioner:** "What if I want to swap one exercise for a different one?"
> **Carl:** "That's a structural edit. You have a 14-day grace from her first open — past that, the Plan locks and you'll need to unlock for 1 credit to republish."

## Flagged doc drift

- **The Home scope chip currently reads "Workouts"; `docs/CLIENT_WORKOUTS_AND_CLASSES.md` (canonical) calls it "My Workouts".** The doc is correct; the shipped chip needs to be renamed as part of the self-trainer wave. This is a one-line label change in `home_screen.dart`'s `HomeScopeSegmented` plus a sweep for any "Workouts" string literals on the right capsule. The `HomeScope.workouts` enum name itself can stay (internal symbol).

- **`docs/CLIENT_WORKOUTS_AND_CLASSES.md` describes an "Identity row" of chips (Practice + Offline + Credits) below the scope row.** That row was retired 2026-05-22 — practice picker moved to Settings → Account, credits pill removed in favour of the portal dashboard tile. The doc's chrome-rules table is stale; only the brand lockup, scope row, "Updated N min ago" hint (Clients-scope), and the corner icons (Help / Settings / Network-share) actually render on Home today. Sweep the doc when the self-trainer wave lands.

## Flagged ambiguities

- **"Session" vs "Plan"** — the same object. Trainer-facing UI says "session"; client-facing UI says "plan". The Flutter model class is `Session`; the DB table is `plans`. Don't try to unify — the surfaces are linguistically separate on purpose. Reserved verbs: a practitioner *creates a session*; a client *opens a plan*.
- **"Trainer" vs "Practitioner"** — UI copy is always "practitioner" (R-06). The legacy DB column `plans.trainer_id` is retained for schema stability; renaming would cascade through every RLS policy and helper fn. New columns adopt `practitioner_id` or `user_id`.
- **"Client session" vs "Session"** — `client_sessions` rows are visitor sessions on the web player. A workout Session is a Session. Never refer to one as the other.
- **"Account"** — not used in product. If you mean Practice, say Practice. If you mean User, say practitioner.
