# Studio Preview artifact picker + no Publish credit subtitle — device QA (2026-05-27)

Two Studio bottom-toolbar changes (mobile-only — Studio config, not
client consumption, so no R-10 web parity):

1. **Preview artifact picker** — tapping PREVIEW in the Studio workflow
   pill now opens a single-select picker (Workout player / Take-home
   handout / future "Soon" kinds) instead of jumping straight to the
   workout-plan card deck. The handout preview renders the LOCALLY
   BUNDLED handout assets via the `homefit-local://` scheme, bypassing
   the device's stale remote handout cache.
2. **Publish credit subtitle removed** — the "FREE / 1 CR / 2 CR"
   caption that used to sit under the PUBLISH label is gone. The running
   credit total still appears inside the publish gate sheet.

Branch: `feat/studio-preview-artifact-picker`
Files: `app/lib/screens/studio_mode_screen.dart`,
`app/lib/widgets/preview_artifact_picker_sheet.dart`,
`app/lib/screens/handout_web_view_screen.dart`,
`app/ios/Runner/UnifiedPlayerSchemeHandler.swift`,
`app/lib/widgets/studio_bottom_bar.dart`

## Pre-flight

- [ ] Build is the staging tip (this branch merged into staging).
      Confirm via the build chip — short SHA on the Home `HomefitLogo`.
- [ ] Open a session in Studio with at least 1-2 non-rest exercises
      (capture or reuse an existing draft). The session does NOT need to
      be published — the picker previews from local session data.

## Publish cell — credit subtitle gone

- [ ] 1. In Studio, look at the PUBLISH cell in the bottom workflow
      pill. There is NO small "1 CR" / "FREE" / "2 CR" caption beneath
      the "PUBLISH" label. Only the cloud-upload glyph + "PUBLISH" text.
- [ ] 2. Tap PUBLISH to open the publish gate sheet. The sheet still
      shows the credit balance line + the big "Total now" running total
      at the bottom (credit math was NOT removed — only the toolbar
      caption). Back out without publishing.

## Preview picker — appears

- [ ] 3. Tap PREVIEW in the workflow pill. A bottom-sheet card slides
      up titled "Preview" with the sub-line about previewing from this
      session. It does NOT jump straight to the workout card deck.
- [ ] 4. The picker lists, top to bottom: "Workout handout" (page glyph)
      and "Workout player" (play glyph) as tappable rows each with a
      right-chevron, then "Poster" and "Reel" as muted rows with a
      "Soon" chip and NO chevron (not tappable).
- [ ] 5. The card visual matches the publish gate's row idiom (same
      rounded cards, same glyph tiles, same surface tones) — reads as a
      sibling sheet, not a new style.
- [ ] 6. Tapping a "Soon" row (Poster / Reel) does nothing — the sheet
      stays open, no navigation.
- [ ] 7. Swipe the sheet down / tap outside to dismiss without picking.
      You return to Studio unchanged (no preview opened).

## Preview picker — Workout player

- [ ] 8. Tap PREVIEW -> "Workout player". The existing workout-plan
      preview opens (swipeable card deck, 15s prep countdown, pill
      matrix) exactly as it did before this change. Close it (top-left
      X) to return to Studio.

## Preview picker — Take-home handout (local bundled)

- [ ] 9. Tap PREVIEW -> "Workout handout". A WebView opens with an
      AppBar titled "Handout preview". The handout page renders: the
      homefit.studio lockup, the plan title, the Line/B&W/Original
      treatment toggle, and the exercise list with reps/sets/hold/notes.
- [ ] 10. The handout shows the CURRENT session's exercises (the ones
      in this Studio session), proving the local plan data resolved.
- [ ] 11. The handout does NOT get stuck on "Loading your plan…" — it
      renders the page. (This is the whole point: the bundled handout.js
      from THIS build runs, not a stale cached copy.)
- [ ] 12. Toggle the treatment segmented control (Line / B&W /
      Original). Consent-gated options behave the same as the published
      handout — unconsented treatments are not selectable.
- [ ] 13. Back-arrow out of the handout preview returns to Studio.

## Regression — published handout (remote path unchanged)

- [ ] 14. For a PUBLISHED session that has a handout artifact, open the
      handout from its usual entry point (ClientSessions / My Workouts
      artifact card -> handout). It still loads the REMOTE published
      handout at `session.homefit.studio/h/{planId}` (AppBar title
      "Workout handout", not "Handout preview"). This path was not
      changed.
