#!/bin/bash
# Wave 7 / Milestone Q — ban bare empty-body `catch` blocks in Dart.
#
# Context: the design review at docs/design-reviews/silent-failures-2026-04-20.md
# traces every major outage in the last month to the same shape:
#
#   try { ... } catch (e) { debugPrint(e) }
#   try { ... } catch (_) {}
#
# `debugPrint` is stripped from release builds and empty bodies never
# produce any signal at all. This hook rejects NEW instances of the
# empty-body variant at commit time. Swallow sites must route through
# `app/lib/services/loud_swallow.dart` instead.
#
# Scope:
#   * .dart files only.
#   * Only files staged in the current commit — pre-existing bare catches
#     in un-touched files don't block unrelated work.
#
# The regex matches any `catch (...)` whose body is entirely whitespace:
#
#   catch\s*\([^)]+\)\s*\{\s*\}
#
# This includes both `catch (e) {}` and `catch (_) {}`. A site that
# genuinely needs to swallow (log-of-log; cleanup in a catch-all) must
# put SOMETHING inside the braces — even a one-line comment satisfies
# the check — so the reader immediately sees the editorial intent.
#
# Two invocation modes:
#
# 1. **Manual / native git pre-commit**: invoked directly by `git commit`
#    (wire via: `ln -s ../../.claude/hooks/ban-bare-catch.sh
#     .git/hooks/pre-commit`, or copy the file there). Reads staged files
#    and rejects if any have offences.
#
# 2. **Claude Code PreToolUse**: registered in `.claude/settings.json`
#    under `hooks.PreToolUse` with matcher=Bash. On each Bash tool call,
#    peeks at the command string via stdin JSON; only runs the staged-
#    files check if the command looks like a `git commit`. Other Bash
#    calls (ls, cat, builds) pass through instantly.
#
# Exit codes:
#   0 — no offences, or not a git commit. Proceed.
#   1 — at least one offence in staged Dart files. Reject.
#
# Emergency bypass (rare): HOMEFIT_ALLOW_BARE_CATCH=1 git commit ...

set -u

if [[ "${HOMEFIT_ALLOW_BARE_CATCH:-0}" == "1" ]]; then
  exit 0
fi

# Claude Code PreToolUse mode: stdin carries a JSON envelope with the
# tool call. If present, filter to git-commit invocations only.
if [[ ! -t 0 ]]; then
  # Read the whole envelope; bail quietly on any parse error.
  payload=$(cat || true)
  if [[ -n "$payload" ]]; then
    # Cheap jq-free extraction of `tool_input.command`. The matcher is
    # already scoped to Bash upstream, so we only look for git-commit-
    # ish substrings.
    if echo "$payload" | grep -qE '"tool_name"\s*:\s*"Bash"'; then
      if ! echo "$payload" | grep -qE 'git\s+commit|git\s+c\s'; then
        # Bash call, but not a commit — pass through.
        exit 0
      fi
    fi
  fi
fi

# Staged Dart files only. `--diff-filter=ACMR` excludes deletions.
staged=$(git diff --cached --diff-filter=ACMR --name-only 2>/dev/null | grep -E '\.dart$' || true)
if [[ -z "$staged" ]]; then
  exit 0
fi

offences=""
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  [[ ! -f "$file" ]] && continue
  # Empty-body catch: catch(...)<ws>{<ws>}. Matches whether the args are
  # a named var (`e`), the explicit-ignore (`_`), or any type-prefixed
  # form (`on PlatformException catch (e)` shares the same empty-body
  # footprint).
  hits=$(grep -nE 'catch\s*\([^)]+\)\s*\{\s*\}' "$file" || true)
  if [[ -n "$hits" ]]; then
    offences+="${file}:\n${hits}\n"
  fi
done <<< "$staged"

if [[ -n "$offences" ]]; then
  echo "" >&2
  echo "Bare empty-body \`catch\` blocks rejected (Wave 7 / Milestone Q)" >&2
  echo "==================================================================" >&2
  echo "" >&2
  echo -e "$offences" >&2
  echo "" >&2
  echo "Fix: route the swallow through app/lib/services/loud_swallow.dart" >&2
  echo "" >&2
  echo "  await loudSwallow(" >&2
  echo "    () => risky()," >&2
  echo "    kind: 'something_failed'," >&2
  echo "    source: 'ClassName.methodName'," >&2
  echo "    severity: 'warn'," >&2
  echo "    swallow: true," >&2
  echo "  );" >&2
  echo "" >&2
  echo "Or rethrow and let the caller decide." >&2
  echo "" >&2
  echo "If the catch site is a genuine log-of-log (writing to a fallback" >&2
  echo "log file that's itself failing), add a 1-line comment inside the" >&2
  echo "braces explaining why — that's enough to pass the check AND make" >&2
  echo "the editorial decision visible to the reader." >&2
  echo "" >&2
  echo "Emergency bypass (last resort): HOMEFIT_ALLOW_BARE_CATCH=1 git commit ..." >&2
  exit 1
fi

exit 0
