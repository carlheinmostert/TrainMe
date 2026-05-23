# Per-premises transparency URLs + premises-list redesign — device QA (2026-05-23)

**Branch:** `feat/per-premises-transparency-urls`
**Build:** Stack items 5 + 6 from `docs/test-scripts/2026-05-23-stack.md` — Live transparency URL becomes `/v/{practice-slug}/{premises-slug}/now` (was `/v/{practice-slug}/now`), and the portal premises list surfaces Live + Poster as collection-level row actions.

**Spec:** `docs/specs/2026-05-22-safe-mode-transparency.md` ([Schema (v2) section](../specs/2026-05-22-safe-mode-transparency.md#schema-v2--per-premises-public-slugs-2026-05-23)).

**URLs (after merge to `staging`):**
- Portal: https://staging.manage.homefit.studio
- Web player: https://staging.session.homefit.studio

How to use: tick each box as you go. Drop fail notes in chat ("3 fail — slug field is read-only"). Pre-condition: the practice has at least one Safe-Mode-enforced premises with a polygon drawn AND a public profile slug set on `/public-profile`.

---

## A. Migration sanity

- [ ] 1. After staging deploy, `select id, name, public_slug, first_poster_downloaded_at from practice_premises where deleted_at is null limit 5;` returns rows with non-null `public_slug` (slugified from name, e.g. "Studio Floor" → `studio-floor`).
- [ ] 2. Each pre-existing premises has `first_poster_downloaded_at` NULL (lock hasn't been engaged yet).

## B. Portal — premises list

- [ ] 3. Navigate to `/premises`. Each Safe-Mode-enforced row shows a "Live" button (eye icon) + "Poster" button (coral, download icon) on the right.
- [ ] 4. Registered-only rows show "Live" but NOT "Poster" (poster has no meaning without enforcement).
- [ ] 5. A thin vertical rule separates Live + Poster (public actions) from Edit + Delete (private actions).
- [ ] 6. Click "Live" on a Safe-Mode-enforced row → opens `staging.session.homefit.studio/v/{practice-slug}/{premises-slug}/now` in a new tab.
- [ ] 7. Click "Poster" on a Safe-Mode-enforced row → opens `/premises/{id}/poster?print=1` in a new tab; browser print dialog auto-fires.
- [ ] 8. Page-level "Live view" button at the TOP of the premises list is GONE (the practice-wide rollup is retired).
- [ ] 9. Live + Poster do NOT appear on Draft rows (no polygon drawn yet) — the URL would land on an empty map.
- [ ] 10. Shrink the browser window to mobile width. Live + Poster collapse into a "Public ▾" dropdown; Edit + Delete stay visible inline.
- [ ] 11. If the practice has NO public profile slug set on `/public-profile`, Live + Poster are hidden from EVERY row (the URL can't resolve without the practice slug).

## C. Portal — premises detail editor

- [ ] 12. Open a premises detail page (`/premises/{id}`). Section "Public URL slug" renders below Safe Mode toggle, above Transparency poster.
- [ ] 13. URL preview reads `staging.session.homefit.studio/v/{practice-slug}/{premises-slug}/now`; the practice-slug prefix is non-editable text; the premises slug is a typeable input.
- [ ] 14. Type uppercase / special chars → input filters to lowercase letters/digits/hyphens only, max 40 chars.
- [ ] 15. Blur with a valid slug → autosaves; "URL slug saved." appears briefly.
- [ ] 16. Try to save an empty slug → either the blur is a no-op or "Slug must be 3-40 chars…" error.
- [ ] 17. Try to save a slug that's already in use on another premises in the same practice → "That URL slug is already in use…" error.
- [ ] 18. Use the Poster Download button at least once on this premises. The slug field becomes disabled + greyed; helper copy reads "Locked — printed QR codes depend on this slug. Generate a new premises if you need a new slug."
- [ ] 19. Reload the page. Slug field stays disabled (the lock is persistent — `first_poster_downloaded_at` is stamped server-side).

## D. Web player — live page route

- [ ] 20. Visit `https://staging.session.homefit.studio/v/{practice-slug}/{premises-slug}/now` (substitute real slugs). Page renders: header with practice name, map polygon, "Recording right now" hero. No console errors.
- [ ] 21. Visit `https://staging.session.homefit.studio/v/{practice-slug}/{wrong-premises-slug}/now`. Page renders the empty / not-found state.
- [ ] 22. Visit `https://staging.session.homefit.studio/v/{wrong-practice-slug}/{any-slug}/now`. Page renders the empty / not-found state (anon RPC never leaks slug existence).
- [ ] 23. Visit the OLD shape `https://staging.session.homefit.studio/v/{practice-slug}/now`. Browser lands on the practice profile page `/v/{practice-slug}` (the public profile), NOT the live page. (The practice-wide rollup is retired; old QR codes / bookmarks land somewhere useful.)
- [ ] 24. Start a Safe Mode capture session in the iPhone app while inside the polygon. Within ~30s the live page (item 20) shows the practitioner's card with avatar + name + Report button.
- [ ] 25. Active session in a DIFFERENT premises of the same practice does NOT appear on this premises' live page (per-premises isolation is the whole point of this wave).

## E. Poster QR

- [ ] 26. On a Safe-Mode-enforced premises detail page, click "Preview" (not print). Page renders the A4 poster. The QR-code caption URL reads `staging.session.homefit.studio/v/{practice-slug}/{premises-slug}/now` (per-premises shape).
- [ ] 27. Scan the QR with a phone camera → it links to the same URL as the caption. Visiting it loads the live page for THIS premises.
- [ ] 28. Click "Download poster" (the `?print=1` variant). Print dialog auto-fires. After printing / cancelling, navigate back to the premises detail page — the slug field is now locked (item 18).

## F. Edge cases

- [ ] 29. Soft-delete a Safe-Mode-enforced premises via the list's Delete button. Wait the 7s undo window. Visit its old live URL `/v/{practice-slug}/{premises-slug}/now` — page renders the empty / not-found state.
- [ ] 30. Restore that premises via Undo. Its live URL renders again with the original slug intact.
- [ ] 31. Soft-deleted premises' slug is freed: create a new premises and try to type the freed slug → save succeeds (the unique constraint is partial on `deleted_at IS NULL`).
