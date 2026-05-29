# manage-issues — `init` (the reconciler)

Run as `/manage-issues init [owner/repo]` (defaults to the current repo). Makes a
repo ready for the managed-issues system by reconciling it to the desired state
this skill carries: **check each thing, create what's missing, update what's
drifted, report, and be safe to re-run.** Nothing here is destructive — it only
adds/updates.

This is the foundation the sweep and the intake skill read. The sweep refuses to
run on a repo that hasn't been init'd (it reads `.github/managed-issues.json`).

## Prerequisites

- `gh` authenticated with the `project` scope (check: `gh auth status` shows
  `project` in token scopes; if not, `gh auth refresh -s project`).
- Write access to the repo and to the owner's Projects.

## Desired state (the canonical definitions)

- **Labels** (status track): `status:needs-info`, `status:awaiting-design-approval`,
  `status:awaiting-fix-approval`, `status:building`, `status:awaiting-pr`,
  `status:awaiting-merge`, `status:awaiting-validation`, `status:hold` — plus the
  native `bug`, `enhancement`, `help wanted`.
- **Board**: a Projects v2 board with a single-select **"Stage"** field whose
  options are the columns `Triage` · `Needs you` · `Building` · `Hold` · `Done`.
  (We create our own field because the default "Status" field's options can't be
  edited via API.)
- **Memory rule**: a managed section in the repo's `CLAUDE.md` carrying the
  always-on intake trigger.
- **Config**: `.github/managed-issues.json` capturing the wiring + a `version`.

## Step 1 — labels

Idempotent create-or-update (this moves out of the sweep into init):

```bash
for L in "status:needs-info|fbca04|Bot is waiting on the issue author for more detail" \
         "status:awaiting-design-approval|5319e7|Feature spec drafted; awaiting Carl's approval" \
         "status:awaiting-fix-approval|8a2be2|Bug diagnosed; proposed fix awaiting Carl's go-ahead" \
         "status:building|0e8a16|Coding sub-agent producing the branch (in-run guard)" \
         "status:awaiting-pr|0052cc|Branch pushed + verified; PR-open pending" \
         "status:awaiting-merge|1d76db|PR open and assigned; awaiting Carl's merge" \
         "status:awaiting-validation|d4c5f9|Merged + deployed; awaiting Carl's test/validation" \
         "status:hold|e4e669|Bot: hands off this issue"; do
  IFS='|' read -r name color desc <<< "$L"
  gh label create "$name" --color "$color" --description "$desc" --repo "$REPO" 2>/dev/null \
    || gh label edit "$name" --color "$color" --description "$desc" --repo "$REPO" 2>/dev/null || true
done
```

## Step 2 — the Projects board

1. **Resolve owner id:**
   ```bash
   OWNER_ID=$(gh api graphql -f query='{ repositoryOwner(login:"OWNER"){ id } }' --jq '.data.repositoryOwner.id')
   ```
2. **Find or create the project** (title = `Managed Issues — <repo>`):
   ```bash
   # find:
   gh project list --owner OWNER --format json --jq '.projects[] | select(.title=="Managed Issues — REPO") | {number,id}'
   # create if absent:
   gh project create --owner OWNER --title "Managed Issues — REPO"
   ```
   Capture the project **number** and **node id** (`gh project view NUMBER --owner OWNER --format json --jq '{number,id}'`).
3. **Link the project to the repo** so issues can be added easily:
   ```bash
   gh project link NUMBER --owner OWNER --repo OWNER/REPO 2>/dev/null || true
   ```
4. **Ensure the "Stage" single-select field** with our columns. Look for it first
   (`gh project field-list NUMBER --owner OWNER --format json`); if absent, create
   it (options inlined because the list arg is awkward to pass otherwise):
   ```bash
   gh api graphql -f query='
   mutation {
     createProjectV2Field(input:{
       projectId:"PROJECT_NODE_ID",
       dataType:SINGLE_SELECT,
       name:"Stage",
       singleSelectOptions:[
         {name:"Triage",    color:GRAY,   description:"Bot classifying / waiting for budget"},
         {name:"Needs you", color:YELLOW, description:"Your inbox: approve / merge / test / reply"},
         {name:"Building",  color:BLUE,   description:"Bot building (or you advanced it here to approve)"},
         {name:"Hold",      color:ORANGE, description:"Parked — hands off"},
         {name:"Done",      color:GREEN,  description:"Resolved"}
       ]
     }){ projectV2Field { ... on ProjectV2SingleSelectField { id name options { id name } } } }
   }'
   ```
   If it already exists, reconcile any missing options with `updateProjectV2Field`
   (the option input accepts an `id`, so existing options are preserved and new
   ones appended).
5. **Capture** the field id and each option id from the response.

## Step 3 — the CLAUDE.md memory rule

Write/refresh a marked managed section in the repo's `CLAUDE.md` so the proactive
intake trigger is always loaded (and travels to the cloud Routine). Idempotent:
replace everything between the markers, leave the rest untouched.

```
<!-- managed-issues:intake start -->
## Issue intake discipline (managed-issues)

During any working session in this repo, do not let new features/bugs/ideas
derail the task at hand. When something raised is a **distinct, scope-expanding
unit of work** (not a clarification or sub-step of what we're doing):

- Dispatch the **intake skill in a background sub-agent** to file it as a GitHub
  issue with a rich, front-loaded body, then carry on — announce it in one line
  ("Filed #N — parking it, back to X"). A one-word veto from Carl pulls it back
  (close the issue).
- Explicit triggers `park` / `stack` / `log` also file on demand.
- Never block the conversation to ask permission first; file + notice + continue.

See the intake skill for the issue shape; it complies with the manage-issues
state machine (lands bare in TRIAGE).
<!-- managed-issues:intake end -->
```

If the repo has no `CLAUDE.md`, create one with just this section.

## Step 4 — the config file

Write `.github/managed-issues.json` (the wiring + the init marker the sweep
checks). Commit it.

```jsonc
{
  "version": 1,
  "owner": "OWNER",
  "integrationBranch": "staging",      // read from CLAUDE.md/AGENTS.md if stated, else default branch
  "project": {
    "number": 0,
    "id": "PROJECT_NODE_ID",
    "stageFieldId": "FIELD_ID",
    "options": {
      "Triage": "OPT_ID", "Needs you": "OPT_ID", "Building": "OPT_ID",
      "Hold": "OPT_ID", "Done": "OPT_ID"
    }
  },
  "phoneCursorPath": "docs/phone-build.json",
  "queueCeiling": 15,
  "maxNewPrsPerSweep": 5
}
```

Commit direct to the default branch (config is repo wiring, like a spec). For
TrainMe, integration branch is `staging` per `CLAUDE.md`.

## Step 5 — report

Print what was created vs already-present vs updated, the board URL, and the
config path. Re-running should report mostly "already present" — that's the
idempotency check.

## Notes / gotchas

- `gh project` needs the `project` token scope.
- The default board "Status" field is left untouched; the board view should be
  **grouped by "Stage"**.
- `updateProjectV2ItemFieldValue` is known to sometimes lag the board-view
  grouping index when changing an existing item's value — the data is correct; a
  view refresh fixes the display. Not a bug in our flow.
- Adding an issue to the board: `addProjectV2ItemById(projectId, contentId)` then
  set its Stage with `updateProjectV2ItemFieldValue(..., value:{singleSelectOptionId})`.
  These are two calls — you can't add+set in one.
