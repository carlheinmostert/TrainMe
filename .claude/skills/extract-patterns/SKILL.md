---
name: extract-patterns
description: Use at the end of implementation sessions to identify reusable patterns that emerged during the work. Triggers when the user says things like "extract patterns", "what patterns did we create", "identify reusable patterns", "update specs with patterns", "what should we document from this session", or any request to capture learnings from implementation work into spec documents. Also use proactively when a session involved significant UI/UX iteration, new component patterns, or architectural decisions that aren't yet in the specs.
---

# Extract Patterns

## Purpose

Implementation sessions often produce reusable patterns that are buried in specific files. This skill surfaces those patterns, checks if they're already documented in specs, and proposes updates to close the gaps. The goal: every pattern discovered once gets documented so it's never re-invented.

## When This Runs

- End of an implementation session with significant UI/UX or architectural work
- After iterating on a component pattern across multiple test cycles
- When the user explicitly asks to extract or identify patterns
- Before starting a new phase, to capture learnings from the previous one

## Process

### Step 1: Catalog Changes

Review what changed in this session by examining:

1. **Git diff** -- `git diff --stat` and `git diff --name-only` to see all modified files
2. **Conversation context** -- What problems were solved, what iterations happened, what the user approved vs rejected
3. **New/modified components** -- Any Blazor components, CSS classes, or JS interop added

For each change, classify it:
- **Entity-specific** -- Only applies to one entity (e.g., "Goal weight defaults to 100"). Skip these.
- **Pattern candidate** -- Could apply to other entities or future phases. Keep these.

### Step 2: Identify Patterns

For each pattern candidate, determine:

1. **Pattern name** -- Short, descriptive (e.g., "Free-Form Date Input", "Post-Creation List Highlight")
2. **Problem it solves** -- What UX or technical issue prompted it
3. **Solution** -- The approach taken (components, CSS, JS interop, etc.)
4. **Reuse scope** -- Where else in the project this applies (list the specific future phases/entities)
5. **Key decisions** -- What alternatives were considered and why this approach won
6. **Gotchas** -- Pitfalls discovered during implementation (e.g., "preventDefault blocks typing", "MudDatePicker Editable mode doesn't support spaces")

### Step 3: Check Existing Specs

Read the current specs to find gaps:

- **S3** (CRUD Entity Form Standard) -- `docs/superpowers/specs/S3-*.md` -- Primary home for UI component patterns
- **S1** (PMS Design Spec) -- `docs/superpowers/specs/S1-*.md` -- Home for architectural principles and UI principles
- **T1** (Test Acceptance) -- `docs/superpowers/plans/T1-*.md` -- May need new test criteria for new patterns

For each identified pattern, check:
- Is it already documented? If yes, does it need updating?
- Is it missing entirely? If yes, which spec should it go in?
- Does it conflict with anything documented? If yes, flag for user decision.

### Step 4: Propose Updates

Present findings to the user as a numbered table:

| # | Pattern | Spec | Status | Proposed Action |
|---|---------|------|--------|-----------------|
| 1 | Free-Form Date | S3 | Missing | Add as Pattern 6 |
| 2 | List Highlight | S3 | Missing | Add as Pattern 7 |
| 3 | Click-to-Edit | S3 | Outdated | Update with keyboard-first rules |

Ask the user: "Which of these should I update? (e.g., 'all', '1,3,5', 'skip 2')"

### Step 5: Execute Updates

For each approved update:
1. Add version history entry to the spec
2. Add/update the pattern section with: problem, solution, component API, CSS classes, reuse scope, gotchas
3. Update the Table of Contents
4. Ensure all headings have TOC back-links (project convention)
5. Use ASCII only (project convention)

Use subagents for the actual edits (per project convention: always implement in subagents).

### Step 6: Summary

Output a brief summary of what was documented and where, so the user has a record.

## Pattern Categories

When classifying patterns, use these categories:

- **Input Patterns** -- How users enter data (free-form date, click-to-edit, inline child editor)
- **Feedback Patterns** -- How the UI communicates state (error indicators, dirty markers, placeholder text, highlight after action)
- **Navigation Patterns** -- How users move between views (post-creation redirect, same-component navigation, query param passing)
- **Layout Patterns** -- How forms and lists are structured (field order, section dividers, grid filters)
- **Interaction Principles** -- Cross-cutting rules (keyboard-first, Immediate binding, preventDefault ban)

## Output

The skill produces:
1. A numbered list of identified patterns with reuse scope
2. Updates to the relevant spec documents
3. A summary of what was added/changed
