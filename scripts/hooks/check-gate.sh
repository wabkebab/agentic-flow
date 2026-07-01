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

# No Makefile / no real `check` target → nothing to gate on; allow.
if [ ! -f Makefile ] || ! grep -Eq '^check:' Makefile; then
  exit 0
fi

if make check >/tmp/agentic-check-gate.log 2>&1; then
  exit 0
fi

if [ "$active" = "true" ]; then
  echo "Warning: \`make check\` still failing, but allowing stop to avoid a loop. See /tmp/agentic-check-gate.log" >&2
  exit 0
fi

echo "Stop blocked: \`make check\` failed. Fix type/lint errors before ending the turn." >&2
echo "--- make check output ---" >&2
tail -n 40 /tmp/agentic-check-gate.log >&2
exit 2
