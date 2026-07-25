#!/usr/bin/env bash
# Stop / SubagentStop hook. Runs the fast sanity gate (`make check`) so an agent can't end
# a turn with red type-check/lint. See METHODOLOGY.md §8.
# Exit 2 = block the turn from ending and feed the failure back to the agent; exit 0 = allow.
#
# Loop safety: if we're already inside a stop-hook continuation (stop_hook_active), allow the
# stop through with a warning rather than blocking forever.
set -uo pipefail

input=$(cat 2>/dev/null || true)
if command -v jq >/dev/null 2>&1; then
  active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
else
  active=false
fi

# Clean working tree → nothing uncommitted that this turn could have broken; skip. This
# keeps pre-existing red state (someone else's broken commit) from holding unrelated,
# no-edit turns hostage, and spares read-only subagents a pointless gate run.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
   && [ -z "$(git status --porcelain 2>/dev/null)" ]; then
  exit 0
fi

# No Makefile / no real `check` target → nothing to gate on; allow.
if [ ! -f Makefile ] || ! grep -Eq '^check:' Makefile; then
  exit 0
fi

# Unique log per invocation. A fixed path (this used to be /tmp/agentic-check-gate.log)
# is clobbered by any concurrent run — a second session, or another project entirely —
# so the agent could be shown someone else's failures and "fix" the wrong repo. The path
# is echoed below, so uniqueness costs nothing in usability.
LOG=$(mktemp "${TMPDIR:-/tmp}/agentic-check-gate.XXXXXX") || LOG="${TMPDIR:-/tmp}/agentic-check-gate.$$.log"

if make check >"$LOG" 2>&1; then
  rm -f "$LOG"
  exit 0
fi

if [ "$active" = "true" ]; then
  echo "Warning: \`make check\` still failing, but allowing stop to avoid a loop. See $LOG" >&2
  exit 0
fi

if grep -Eq 'docs index OUT OF DATE|docs index out of date' "$LOG"; then
  echo "Stop blocked: docs index is stale. Run: scripts/docs-index.sh" >&2
  exit 2
fi

echo "Stop blocked: \`make check\` failed. Fix type/lint errors before ending the turn." >&2
echo "--- make check output ($LOG) ---" >&2
tail -n 40 "$LOG" >&2
exit 2
