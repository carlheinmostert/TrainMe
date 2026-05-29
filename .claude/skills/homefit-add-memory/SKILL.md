---
name: homefit-add-memory
description: Capture a session learning as a typed memory file under /Users/chm/.claude/projects/-Users-chm-dev-TrainMe/memory/, append a one-liner pointer to MEMORY.md, and commit direct-to-main via an ephemeral worktree. Use when Carl says "add a memory", "remember this", "save as gotcha", "save as feedback", "save as project memory", "log this learning", "capture this rule", or after a moment in the session that surfaced a rule worth keeping. Default the type to `feedback` when it's a behavior correction or a validated approach; ask if ambiguous.
---

# homefit-add-memory

## Purpose

Carl's project-level memory lives at `/Users/chm/.claude/projects/-Users-chm-dev-TrainMe/memory/`. Each rule, gotcha, or fact is a separate `<type>_<slug>.md` file, and `MEMORY.md` is the one-line index. This skill captures a learning the right way the first time: typed, deduped, indexed, committed direct-to-main, and pulled back into Carl's current worktree.

## When to invoke

- Carl says any of: "add a memory", "remember this", "save as gotcha/feedback/project", "log this learning", "capture this rule", "memory: ..."
- Proactively at the end of a session that surfaced a load-bearing rule (with Carl's confirmation before writing)
- After a bug post-mortem that produces a rule worth not re-learning

## Memory types

- `feedback` — behavior correction or validated approach (default if unclear)
- `gotcha` — an environment / library / platform trap with a concrete reproduction
- `project` — a fact about how homefit.studio works (architecture, conventions, current state)
- `user` — a fact about Carl (preferences, context, working style)
- `reference` — a link or external resource worth remembering

## Workflow

### Step 1: Type + slug

Ask Carl which type if not implicit. Default to `feedback`.

Generate a slug from the rule's core noun phrase. Examples:
- "Always grep for conflict markers before push" → `gotcha_grep_conflict_markers_before_push`
- "Specs go direct to main" → `feedback_specs_direct_to_main`
- "Carl prefers plain-English explanations" → `feedback_explanation_level`

The slug pattern is `<type>_<short_snake_case>` matching existing files in the folder.

### Step 2: Dedupe check (critical)

**Before writing, grep `MEMORY.md` for similar entries.** Carl has 55+ memory entries already — duplicates are the #1 risk.

```sh
grep -i "<key noun>\|<related verb>" /Users/chm/.claude/projects/-Users-chm-dev-TrainMe/memory/MEMORY.md
```

If a match exists, UPDATE the existing file (Edit tool on the matched memory file + its `MEMORY.md` line if the hook changed) rather than creating a new one. Tell Carl what you found and propose the merge.

### Step 3: Write the memory file

Format (matches existing files in the folder):

```
---
name: <Short title under 80 chars>
description: <One-sentence summary that would surface as a memory hint to a future Claude session>
type: <feedback|gotcha|project|user|reference>
originSessionId: <current session id if available, else leave blank>
---
<Lead with the rule/fact in 1-3 sentences. Bold the rule words.>

**Why:** <Why the rule exists — the incident, the cost, the trade-off>

**How to apply:**
- <Concrete bullet 1>
- <Concrete bullet 2>
- <Anti-patterns to reject>

<Optional: related memory files, detection commands, code examples>
```

For `feedback` / `project` types, the **Why:** and **How to apply:** sections are load-bearing — they're how a future Claude pattern-matches the rule to a new situation.

For `gotcha` types, lead with the symptom + reproduction, then root cause, then workaround.

Write to: `/Users/chm/.claude/projects/-Users-chm-dev-TrainMe/memory/<type>_<slug>.md`

### Step 4: Append to MEMORY.md index

Format (matches existing lines):

```
- [<Short title>](<filename>.md) — <one-line hook, under ~140 chars>
```

Append at the end of `/Users/chm/.claude/projects/-Users-chm-dev-TrainMe/memory/MEMORY.md` (Edit tool, add after the last existing line).

### Step 5: Index health check

Count lines in `MEMORY.md` after append. If approaching ~200 lines (the truncation threshold per the auto-memory spec), flag to Carl: "Index is at N lines — consider running `anthropic-skills:consolidate-memory` to merge duplicates."

### Step 6: Commit direct-to-main via ephemeral worktree

This follows `feedback_specs_direct_to_main.md` — memory files are documentation, never PRs.

```sh
# From any cwd
SLUG=add-memory-$(date +%s)
git worktree add /tmp/$SLUG main
cp /Users/chm/.claude/projects/-Users-chm-dev-TrainMe/memory/<file>.md /tmp/$SLUG/   # if memory was in repo; SKIP this — memory lives outside repo
```

**Correction:** The memory folder is at `/Users/chm/.claude/projects/-Users-chm-dev-TrainMe/memory/` which is NOT inside the TrainMe repo. Memory files are written directly to that path; no git commit is needed for the memory files themselves — they're in Carl's `~/.claude/` config tree, not the project repo.

So Step 6 simplifies to: **no repo commit needed**. The files Carl wrote are picked up by Claude Code's memory loader on the next session.

Skip the worktree dance entirely for memory work. Confirm to Carl with the file path and the index line you appended.

### Step 7: Confirmation

Report to Carl:
- Memory file: `/Users/chm/.claude/projects/-Users-chm-dev-TrainMe/memory/<file>.md`
- Index entry appended to `MEMORY.md`
- Current index size: N / 200 lines

## Anti-patterns

- Creating a new memory file when an existing one covers 80% of the same rule — UPDATE the existing one
- Vague slugs like `feedback_fix.md` — slug should encode the rule's distinct concept
- Putting code-only details in a memory rule that Carl will read — keep the prose plain-English (per `feedback_explanation_level.md`)
- Writing memory files into the TrainMe repo — they live in `~/.claude/projects/`
- Skipping the dedupe grep — Carl's index is 55+ entries; duplicates dilute trigger accuracy

## Related rules encoded

- `feedback_specs_direct_to_main` — but memory is outside the repo, so no commit needed
- `feedback_explanation_level` — memory files target Carl as the reader; plain-English by default
- `feedback_markdown_toc` — does NOT apply to short memory files
