---
name: homefit:resolve-test-script-index
description: Resolve git merge-conflict cascades in docs/test-scripts/index.html — the multi-region kind that has shipped to main twice. Use when Carl says "resolve test-scripts conflict", "fix index.html conflict", "fix the test-scripts cascade", or after a merge surfaces conflict markers in the test-scripts index.
---

# homefit:resolve-test-script-index

`docs/test-scripts/index.html` is a recurring merge-conflict hotspot — wave entries land in parallel branches, and when two waves merge in the same window the index gets a multi-region cascade. Two real incidents shipped conflict markers to main (PR #202 cascade on 2026-05-03, PR #301 docs/CI.md incident on 2026-05-11) because the resolver did not re-grep after staging.

This skill resolves the cascade with a multi-region resolver and ALWAYS re-greps before commit. Encodes `gotcha_test_scripts_index_cascade.md`.

## Inputs

- File: `docs/test-scripts/index.html` (repo-relative).
- Current branch HEAD context (so we know "ours") — read from `git rev-parse --abbrev-ref HEAD`.

## Workflow

### 1. Detect conflict markers — bail early if none

Run from the repo root:

```
grep -cE "^(<{7}|={7}|>{7})" docs/test-scripts/index.html
```

If the count is `0`, BAIL with a one-line message: "No conflict markers in `docs/test-scripts/index.html` — nothing to resolve." Do not proceed.

### 2. Read the file

Use the Read tool to load the full file. The cascade is typically 2-5 disjoint regions, each demarcated by `<<<<<<<`, `=======`, `>>>>>>>`.

### 3. Resolve via multi-region regex — NOT a single-pass sed

The pattern that fails: agents try `sed -i` with a single `s/<<<<<<<.*>>>>>>>/keep/s` and lose every region but the first because of greedy / single-line matching.

The pattern that works: a Python (or compatible) `re.findall` walk over the file content with `re.DOTALL`, capturing each region's `<ours>` and `<theirs>` blocks separately. Sketch:

```python
import re
pattern = re.compile(
    r"<{7}[^\n]*\n(?P<ours>.*?)\n={7}\n(?P<theirs>.*?)\n>{7}[^\n]*",
    re.DOTALL,
)
for match in pattern.finditer(content):
    ours = match.group("ours")
    theirs = match.group("theirs")
    # decide per-region resolution (see step 4)
```

Build the resolved file by substituting each region's chosen text back via `pattern.sub(...)` with a per-match callback.

### 4. Per-region resolution policy

For each region, the choice is:

- **Carl's current-branch (ours)** by default — that's the branch he's working on.
- **Incoming (theirs) only if** the incoming version has new `<li>` entries the ours version is missing.
- **Interleave both** when both sides have new entries — the entries are list items in either "Test these now" or "Past waves", not exclusive. Merge by date-descending order if the entries carry `data-date` or visible `YYYY-MM-DD` tokens; otherwise keep `ours` first then append unique `theirs` entries below.

Parse `<li>` entries with a forgiving regex (`<li[^>]*>.*?</li>` with `re.DOTALL`); compare by inner text or `data-slug` attribute to dedupe.

### 5. Write the resolved file

Use the Write tool with the resolved content. Do NOT introduce extra whitespace or reorder unrelated sections — only the conflict regions should differ from `ours`.

### 6. Re-grep — LOAD-BEARING CHECK

```
grep -cE "^(<{7}|={7}|>{7})" docs/test-scripts/index.html
```

This MUST return `0`. If it does not:

- Surface the remaining markers' line numbers.
- DO NOT stage. DO NOT commit.
- Either re-run the resolver with the missed region pattern or escalate to Carl.

This step is the entire reason the skill exists. Git accepts commits based on index state (resolved via `git add`), NOT file content — markers will silently ship if you skip the post-resolve grep. Two real incidents.

### 7. Renumber the "Test these now" actives

Open the resolved file. Within the "Test these now" / "Order · test these now" section, walk the `<li>` entries and renumber the visible numbers (1, 2, 3, ...) so they form an unbroken sequence. Leave "Past waves" alone — those keep their historical numbering.

### 8. Stage and commit

```
git add docs/test-scripts/index.html
git commit -m "chore(test-scripts): resolve index.html conflict — <short description of waves involved>"
```

Use a HEREDOC so the message format is clean. Co-author footer per the system prompt's git protocol.

### 9. Final confirmation

End the reply with:

- Lines added / lines removed (from `git diff HEAD~1 --stat docs/test-scripts/index.html`).
- "Markers remaining: 0" (re-greps and confirms).
- The wave entries kept on each side after merge, briefly.
- Carl will push (or not) — do NOT auto-push.

## Critical safety rules

- NEVER skip the post-resolve grep. Two real incidents shipped markers because of this.
- NEVER use single-pass sed — the cascade is multi-region.
- NEVER overwrite Carl's "ours" entries blind — the default is to keep ours and interleave theirs only when theirs has new entries.
- NEVER touch other files — this skill is scoped to `docs/test-scripts/index.html`. If the cascade extends to other test-script HTML files, surface that and ask Carl how to proceed.
- NEVER auto-commit if the resolved file shows weird structural damage (e.g. unbalanced `<ul>` tags). Surface the diff and ask Carl.

## Don'ts

- Don't try to resolve via `git checkout --ours` or `--theirs` — that wipes one side wholesale. The cascade often needs interleave.
- Don't auto-push. Carl pushes when he is ready.
- Don't tag the commit. The auto-tag workflow handles tagging on merges to main.
- Don't ship if the resolved file is shorter than the smaller of (ours, theirs) — that's a sign the regex ate content. Re-run.

## Encodes

- `gotcha_test_scripts_index_cascade.md` — the multi-region resolver requirement + load-bearing post-grep + two real shipped-marker incidents (PR #202 cascade, PR #301 docs/CI.md).
- The git-protocol "create new commit, never amend" rule from the system prompt (we commit fresh; no `--amend`).
