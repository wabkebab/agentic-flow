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

# No Makefile / no real check target means there is no project gate.
if [ ! -f Makefile ] || ! grep -Eq '^check:' Makefile; then
  exit 0
fi

# Hash the committed tree and all visible staged, unstaged and untracked content.
# Failure disables reuse; an unborn repository still hashes its staged content.
state_hash() (
  set -e
  tree=$(git rev-parse --verify 'HEAD^{tree}' 2>/dev/null) || {
    if git symbolic-ref -q HEAD >/dev/null && ! git rev-parse --verify HEAD >/dev/null 2>&1; then
      tree=unborn
    else
      exit 1
    fi
  }
  snapshot=$(mktemp "${TMPDIR:-/tmp}/agentic-gate-state.XXXXXX") || exit 1
  trap 'rm -f "$snapshot" "$snapshot.files"' EXIT
  {
    printf '%s\n' "$tree"
    git status --porcelain || exit 1
    if [ "$tree" = unborn ]; then
      git diff --cached || exit 1
      git diff || exit 1
    else
      git diff HEAD || exit 1
    fi
    git ls-files --others --exclude-standard -z > "$snapshot.files" || exit 1
    while IFS= read -r -d '' f; do
      git hash-object -- "$f" || exit 1
    done < "$snapshot.files"
  } > "$snapshot" || exit 1
  git hash-object --stdin < "$snapshot"
)

# Probe atomic writes before trusting either record. Read-only metadata must never
# turn an old record into permission to skip the gate.
write_record() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  if (umask 077; printf '%s\n' "$2" > "$1.tmp.$$") 2>/dev/null; then
    mv -f "$1.tmp.$$" "$1" 2>/dev/null && return 0
  fi
  rm -f "$1.tmp.$$" 2>/dev/null
  return 1
}
STAMP=""
RED=""
gitdir=$(git rev-parse --git-dir 2>/dev/null) || gitdir=""
STATE=$(state_hash 2>/dev/null) || STATE=""
if [ "${AGENTIC_CHECK_GATE_NO_CACHE:-0}" != 1 ] && [ -n "$gitdir" ]; then
  probe="$gitdir/agentic-flow-check-gate-probe.$$"
  if write_record "$probe" "$STATE"; then
    rm -f "$probe"
    STAMP="$gitdir/agentic-flow-check-gate-state"
    RED="$gitdir/agentic-flow-check-gate-red"
    if [ "$STATE" = "$(cat "$STAMP" 2>/dev/null)" ]; then exit 0; fi
    if [ "$STATE" = "$(cat "$RED" 2>/dev/null)" ]; then
      echo "Warning: previously acknowledged failing or changing state; allowing stop to avoid a loop." >&2
      exit 0
    fi
  fi
fi

# Unique log per invocation. A fixed path (this used to be /tmp/agentic-check-gate.log)
# is clobbered by any concurrent run — a second session, or another project entirely —
# so the agent could be shown someone else's failures and "fix" the wrong repo. The path
# is echoed below, so uniqueness costs nothing in usability.
LOG=$(mktemp "${TMPDIR:-/tmp}/agentic-check-gate.XXXXXX") || LOG="${TMPDIR:-/tmp}/agentic-check-gate.$$.log"

# A green run may have edited the tree. Verify that new state once, bounded.
for attempt in 1 2; do
  if ! make check >"$LOG" 2>&1; then break; fi
  FINAL=$(state_hash 2>/dev/null) || FINAL=""
  if [ -n "$STATE" ] && [ "$STATE" = "$FINAL" ]; then
    write_record "$STAMP" "$FINAL" || true
    rm -f "$LOG"
    exit 0
  fi
  STATE="$FINAL"
  if [ "$attempt" = 2 ]; then
    echo 'the tree changed during make check; stop editing before ending the turn' > "$LOG"
  fi
done

if [ "$active" = "true" ]; then
  FINAL=$(state_hash 2>/dev/null) || FINAL=""
  write_record "$RED" "$FINAL" || true
  echo "Warning: \`make check\` still failing or the tree changed during verification, but allowing stop to avoid a loop. See $LOG" >&2
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
