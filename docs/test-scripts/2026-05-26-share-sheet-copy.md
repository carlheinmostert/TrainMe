# Test script — Share sheet heading names the product (M28)

**PR:** `fix/share-practitioner-sheet-copy` → `staging`
**Stack item:** M28 from `docs/test-scripts/2026-05-25-stack.md`
**File touched:** `app/lib/widgets/network_share_sheet.dart`

## What this PR ships

Renames the "Share with another practitioner" sheet heading to
**"Share homefit.studio with another practitioner"** so a newbie can
immediately tell what's being shared (the platform, not a plan / client /
session). Wordmark rendered in canonical brand split — `homefit` in
textOnDark + `.studio` in coral — matching `app/lib/widgets/homefit_logo.dart`.

The Home AppBar tooltip on the person-add icon is left alone (it's a
tooltip, not the sheet's own heading).

## Test items

Run on staging (`./install-sim-keep-auth.sh staging`) with the agent QA
test account (`qa@homefit.studio`).

- [ ] **1. Sheet opens from Home AppBar.** Land on Home (Clients). Tap the person-add icon top-left of the AppBar. The "Share homefit.studio" bottom sheet slides up. (Drag handle visible, dark surface, rounded top corners — no regression to existing chrome.)
- [ ] **2. Heading reads the new copy.** First line of the sheet content reads exactly: `Share homefit.studio with another practitioner`. No double-space around the wordmark.
- [ ] **3. `.studio` renders in coral.** The `.studio` portion of the wordmark (including the leading dot) renders in coral `#FF6B35`. The word `homefit` stays in the same near-white textOnDark colour as the rest of the heading. The trailing `with another practitioner` is the same near-white as `homefit`.

## Pre-merge checks (Mac-side)

- [ ] `flutter analyze lib/widgets/network_share_sheet.dart` — No issues found.
- [ ] `grep -rn '<<<<<<<\|>>>>>>>' app/lib/widgets/network_share_sheet.dart docs/test-scripts/2026-05-26-share-sheet-copy.md` returns zero matches.

## Notes

- Mobile-only change (R-10 N/A) — the share-kit sheet is a Flutter-only surface.
- No copy in `.studio` / `homefit` should be split across lines — short heading; no wrap expected at typical iPhone widths.
