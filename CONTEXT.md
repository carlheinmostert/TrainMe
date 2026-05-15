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

**User**:
An `auth.users` row (i.e. a practitioner). Never used to refer to the client.
_Avoid_: account

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

**Client session**:
One row per unique visitor session on a published plan (analytics surface). Distinct from a workout Session.

### Capture & playback

**Capture mode**:
The camera-viewfinder pane of the trainer-app session shell.

**Studio mode**:
The editor pane of the trainer-app session shell.

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

### Billing & credits

**Credit**:
A unit of publishing capacity; 1 for plans ≤75min estimated duration, 2 for plans >75min.
_Avoid_: token, point, charge

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

## Flagged ambiguities

- **"Session" vs "Plan"** — the same object. Trainer-facing UI says "session"; client-facing UI says "plan". The Flutter model class is `Session`; the DB table is `plans`. Don't try to unify — the surfaces are linguistically separate on purpose. Reserved verbs: a practitioner *creates a session*; a client *opens a plan*.
- **"Trainer" vs "Practitioner"** — UI copy is always "practitioner" (R-06). The legacy DB column `plans.trainer_id` is retained for schema stability; renaming would cascade through every RLS policy and helper fn. New columns adopt `practitioner_id` or `user_id`.
- **"Client session" vs "Session"** — `client_sessions` rows are visitor sessions on the web player. A workout Session is a Session. Never refer to one as the other.
- **"Account"** — not used in product. If you mean Practice, say Practice. If you mean User, say practitioner.
