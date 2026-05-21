# Frontend Review — 2026-05-21 (`staging`)

Scope: `origin/main...origin/staging` for `web-portal/` + `web-player/`. Public Profile v2, premises Leaflet editor, TopProgressBar, web player branding cascade + `/v/{slug}` page.

## Table of Contents

- [Critical](#critical)
- [High](#high)
- [Medium](#medium)
- [Low / observation](#low--observation)

## Critical

- **`web-player/v.html:90-91` — JSX `{' '}` escapes leak as literal text on `/v/{slug}`.** `<p class="v-fine-print">` reads `… have bystanders automatically obscured. See{' '} <a …>what we share</a>{' '} for the full privacy story.` HTML renders the curly-braces verbatim. Fix: replace both `{' '}` with a single space character.

## High

- **`web-portal/src/app/public-profile/IdentityPanel.tsx:21` — slug regex allows 1–2 chars but the hint promises "3–40".** `^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])?$` matches `"a"`. RPC may reject; UI says fine. Fix: `^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$` (mandatory tail).
- **`LogoUploader.tsx:60-71` — no success affordance, no race protection, no replace-state, dirty file input on error.** After upload the dashed dropzone re-renders with the new URL but there is no "Uploaded ✓" toast or visible state change beyond the swapped `<img>`. If a user picks two files in quick succession the second `handleFile` runs while the first is still uploading; both will resolve, the later `onUploaded(url)` wins, but the indicator only reflects the last call. Also: `setUploading(true)` is inside `try` but `setError(null)` was already cleared — a thrown network error from `supabase.storage.upload` lands in the global catch (there isn't one), so the promise rejects silently. Fix: wrap the supabase call itself in try/catch, surface success via `savedAt`-style state, guard with an `inflightRef` token, reject the second file with "Upload in progress…".
- **`BrandingPanel.tsx:47-79` + `IdentityPanel.tsx:54-119` — exception-driven control flow on save.** The `try { await api.set… } catch (e) { setError(messageForKind(e)) }` pattern violates `feedback_no_exception_control_flow.md`. The RPC already returns typed `PublicProfileError`; the catch ladder re-discriminates on `instanceof`. Acceptable for typed errors only — but the bare `else if (e instanceof Error)` swallowing-everything branch hides programmer errors as save toasts. Fix: let unknown errors bubble; toast only the typed `PublicProfileError`. Logging the unknown branch to console at minimum.
- **`TopProgressBar.tsx:36-42` — internal-link click handler races with pathname effect on instant-paint routes.** Click handler sets `width: 40` then the pathname effect sets `width: 0` 16ms later → visible flicker on fast nav. Fix: only run the pathname-effect "to 0" reset when `visible` is currently false; if already animating, jump to 70% directly.
- **`v.html` + `v.js` — logo `<img alt="">` plus `aria-hidden` on the wrapper is fine, but `v-logo` initials fallback has no `aria-label`.** Screen readers announce nothing for the practice mark when no logo is set. Fix: when rendering initials, set `elLogo.setAttribute('aria-label', profile.practiceName + ' logo')` and `aria-hidden="false"`.
- **`PremisesPolygonEditor.tsx:177` — `marker.on('drag')` reads stale `vertices` closure.** Inside the `vertices.forEach((v, idx) => { … marker.on('drag', () => { const live = vertices.map(…) … }) … })` the inner `vertices` is captured per-render. Each drag tick rebuilds `setLatLngs` from the array snapshot at handler creation — fine for single-pin drags, broken if two vertex positions get committed between drag start and drag end (e.g. a programmatic `setVertices` from `Clear`/`Undo` mid-drag, or rapid second-pin grab in touch). Fix: use a `verticesRef` updated on each `setVertices` and read from the ref inside drag.

## Medium

- **`SpecialtiesEditor.tsx:62-86` — chip `×` button is unlabeled visually + lacks keyboard removal beyond Backspace-empty.** `aria-label={\`Remove ${chip}\`}` ✓, but Tab order skips chips entirely (only the input is tab-focusable). Keyboard-only users can't remove the third chip without first deleting the two after it. Fix: make each chip a `<button>` element OR add `tabIndex={0}` + an `onKeyDown` (Delete/Backspace) to remove.
- **`BrandColorPicker.tsx:91-93` — WCAG threshold 4.5:1 is correct for normal body text, but the brand color is used for large headings + large countdown numerals + 1.5px borders.** WCAG AA permits 3:1 for ≥ 18pt or 14pt-bold. Treating all 4.5:1 misses are over-strict + drives users away from valid coral derivatives. Fix: surface as "this color may be hard to read for small body text" (clarify scope) OR split into 3:1 hard floor + 4.5:1 soft hint.
- **`BrandColorPicker.tsx:60` — `onChange={(e) => onChange(e.target.value.toUpperCase())}` doesn't debounce.** HTML5 `<input type="color">` fires on every native-picker hover preview on macOS. Every hover triggers a parent re-render + Save state mutation (`brandColor` !== `profile.brandColor` evaluation). Fix: debounce 100ms or commit on `onBlur` / native `change` event only.
- **`PremisesPolygonEditor.tsx:113-117` — three Esri tile layers + OSM tiles fetch on map mount with no `loading="lazy"` and no offline fallback.** First-paint network burst on `/premises` open. Fix: don't `street.addTo(map)` until first user gesture, or preload the visible viewport only.
- **`public-profile/page.tsx` — no `export const dynamic = 'force-dynamic'`.** Server component does `auth.getUser()` + cookie reads — Next 15 should treat as dynamic, but app router has bitten us before (e.g. `env.ts` Webpack inline). Defensive add per the May 17 PM checkpoint pattern.
- **`v.js:104-106` — `profile.contactEmail` is not sanitised before `mailto:` href.** A `"foo@bar.com\nBcc:victim@x.com"` value (unlikely but DB allows newlines in unconstrained TEXT) would forge headers via mailto. Fix: strip CR/LF before composing href.
- **`SaveBar.tsx:30` — `setTimeout` for "Saved · …" auto-fade is not cleared if `savedAt` changes mid-fade.** Mostly a minor UX glitch (one trailing fade-out from the previous save). The cleanup function does clear it via the return arrow — actually this is fine, ignore.
- **`v.js:296-299` — `setTimeout(() => closeReportModal(), 1200)` and another `setTimeout(…, 1500)` aren't cleared.** If the user navigates between submit and the timeout firing, the timer fires on a disposed page. Low-impact but a leak; clear timer in `closeReportModal`.

## Low / observation

- `BrandingPanel.tsx` + `IdentityPanel.tsx` both use `<details>` for accordions — works without JS but `aria-expanded` is not surfaced. Most modern screen readers do announce `<details>` state natively; keep as-is.
- `LogoUploader.tsx:130-132` "Remove" is a text link styled as underline — make it a `<button>` semantically (already is `<button type="button">` ✓ — confirmed, no action needed).
- `LogoUploader.tsx:108-112` `<img alt="Logo">` is generic; use `alt={\`${practiceName} logo\`}` if practiceName is threaded down.
- `TopProgressBar.tsx:71-73` z-index 9999 is fine but conflicts with any future toast/modal stack — document or move to a CSS variable.
- `v.html:127` `<noscript>` fallback message is inline-styled — fine for a single-use no-JS message.
- `applyPracticeBranding(plan)` in `app.js:5677` fires after `fetchPlan` — there's a brief window during the coral-default loading screen where a custom brand wouldn't apply yet. Acceptable: the loading screen is universally homefit-coral by design.
- `web-portal/package.json` adds `leaflet@^1.9.4` (~150 KB gzipped) — dynamically imported via `next/dynamic({ssr:false})` so it doesn't enter the root bundle. ✓
- `v.js` has no IIFE leak guard for `currentProfile` — module-level mutable state, but the script is page-scoped so fine.
- Contact list rows are anchor elements with no visible focus ring — Tailwind base style strips it; add `focus-visible:ring-2 ring-brand` on `.v-contact-row:focus-visible`.
