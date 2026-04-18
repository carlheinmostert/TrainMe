# homefit.studio — Voice & Tone

One page. Healthcare-professional, warm not clinical, South African English.

---

## Principle

We sound like a **trusted bio who's good at their job** — confident, direct, respectful. Not a chatbot, not a Silicon Valley growth hacker, not a medical device UI.

Three knobs:
- **Confident**, never hedging
- **Warm**, never cute
- **Precise**, never clinical

---

## Spelling & vocabulary (South African English)

Always use:

| Use | Not |
|---|---|
| colour, favourite, organise | color, favorite, organize |
| exercise | workout, movement |
| plan | program, routine, regimen |
| credits | tokens, points, coins |
| trainer / practitioner / bio | coach, user |
| client / patient | customer, athlete |
| capture / Studio | record / edit |
| share | send, publish, post |

"bio" is acceptable shorthand when talking to trainers. Never to patients.

---

## Tone by surface

**Flutter app (trainer-facing):** peer-to-peer, terse. The trainer is mid-session, hands half-busy. Short labels, verbs first.
> "Capture exercise" · "Add rest" · "Share plan"

**Web player (patient-facing):** warm, instructional, calm. The patient may be anxious, post-op, or unsure. Full sentences, encouraging.
> "You've got this. Take it at your own pace."
> "If something hurts, stop and message your bio."

**Web portal (practice-owner-facing):** business-like, transparent. Numbers, receipts, clarity.
> "You have 42 credits remaining." · "Credits never expire."

---

## Onboarding copy (first-run)

**Welcome screen:**
- Title: `Capture once. Share anywhere.`
- Body: `Turn your session into a plan your client can follow at home. Works on any phone, no app needed.`
- CTA: `Get started`

**Permissions ask (camera):**
- Title: `Camera access`
- Body: `We need your camera to capture exercises. Videos stay on your device until you publish a plan.` *(honest about POPIA + data path)*
- CTA: `Allow camera` / `Not now`

**First session empty state:**
- Title: `No sessions yet`
- Body: `Start a session to capture your first exercise.`
- CTA: `New session`

---

## WhatsApp share message template

Auto-filled when the trainer taps "Share plan". Editable before send.

```
Hi {ClientName},

Here's your plan from today's session:
{PlanURL}

{ExerciseCount} exercises · {TotalDuration} min
Open the link to see the demos.

— {TrainerName}
```

**Rules:**
- No emoji. Professional tone.
- Plan URL is the full `session.homefit.studio/p/{id}` — never a shortener.
- Sign-off uses the trainer's first name, not "homefit.studio".

---

## Client-facing plan intro (what the patient sees first)

Rendered at the top of every published plan.

> **Your plan from {TrainerName}**
> {ExerciseCount} exercises · approximately {TotalDuration} minutes
>
> Watch each demo, then do the exercise. Take breaks when you need them. If anything causes sharp pain, stop and message {TrainerName}.

Never claim clinical outcomes ("this will fix your back"). Describe the *activity*, not the *result*.

---

## Healthcare-adjacent caution copy (POPIA-safe)

When we touch anything medical-sounding, we say less, not more.

**Allowed:**
- "Exercises captured by your bio."
- "For best results, do this plan {N} times per week, as your bio recommends."
- "If something hurts, stop and message your bio."

**Banned:**
- "Rehabilitation", "recovery", "treatment", "therapy" as product-level claims. *(OK in trainer-side copy when quoting the trainer.)*
- "Clinically proven", "doctor-recommended", "approved by…" — unless we have signed evidence.
- Diagnostic language: "your condition", "your injury", "your symptoms" — the app doesn't know. Only the bio knows.

**POPIA data copy:**
- "Videos stay on your device until you publish a plan. Once published, the client sees only the line-drawing version."
- "We store plans, not people. Line drawings don't identify you."

---

## Error messages

Formula: **what happened · what they can do · (optional) why.**

**Good:**
- "Couldn't load this plan. Check your connection and try again."
- "Plan not found. The link may have expired."
- "Not enough credits. Top up to publish this plan."

**Bad:**
- "Oops! Something went wrong 😔" *(no info, cutesy)*
- "Error 503: Upstream gateway timeout" *(server-speak)*
- "We're sorry for the inconvenience." *(fills space, says nothing)*

---

## Button & CTA labels

Verbs first. One verb if possible.

| Use | Not |
|---|---|
| Save | Save changes |
| Publish | Publish plan |
| Share | Share with client |
| Top up | Buy more credits |
| Try again | Retry |
| New session | Create a new session |

Exception: destructive actions keep the object ("Delete plan", not "Delete"). The friction is the point.

---

## Do / don't quick reference

| Do | Don't |
|---|---|
| "You've got this." | "Let's crush it! 💪" |
| "Published." | "Hooray! Your plan is live 🎉" |
| "Not enough credits." | "Oh no! You've run out of credits." |
| "Message your bio." | "Contact your healthcare provider." |
| "Watch the demo, then try it." | "Observe the demonstration and replicate." |
| "Rest — 30 seconds." | "Recovery period: thirty (30) seconds." |
