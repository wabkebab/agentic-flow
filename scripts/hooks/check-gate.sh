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

# Skip a re-run when nothing has changed since the last green gate. The clean-tree exit
# above keys on tree-cleanliness, not on who is stopping, so a fan-out of subagents against
# one dirty worktree re-ran the whole of `make check` per subagent plus once more for the
# parent turn — the same validation, several times, for one logical change.
#
# The stamp records the tree state at the moment `make check` last passed. It lives in
# $GIT_DIR, so it is never committed and a `worktree`-isolated subagent gets its own.
#
# The id must be content-sensitive, not just `git status --porcelain`: a file edited but
# still listed as "M" produces identical porcelain output, and keying on that would skip a
# gate that should run. `git diff HEAD` covers tracked content (staged and unstaged) and
# each untracked file is hashed explicitly. Anything unexpected yields an empty id, which
# disables the cache rather than trusting it.
STAMP=""
STATE=""
if [ "${AGENTIC_CHECK_GATE_NO_CACHE:-0}" != "1" ] && git rev-parse --git-dir >/dev/null 2>&1; then
  STAMP="$(git rev-parse --git-dir)/agentic-flow-check-gate-state"
  STATE=$(
    {
      git status --porcelain
      git diff HEAD 2>/dev/null
      while IFS= read -r -d '' f; do
        [ -f "$f" ] && git hash-object "$f" 2>/dev/null
      done < <(git ls-files --others --exclude-standard -z 2>/dev/null)
    } | git hash-object --stdin 2>/dev/null
  ) || STATE=""
  if [ -n "$STATE" ] && [ -f "$STAMP" ] \
     && [ "$STATE" = "$(cat "$STAMP" 2>/dev/null)" ]; then
    exit 0
  fi
fi

# Unique log per invocation. A fixed path (this used to be /tmp/agentic-check-gate.log)
# is clobbered by any concurrent run — a second session, or another project entirely —
# so the agent could be shown someone else's failures and "fix" the wrong repo. The path
# is echoed below, so uniqueness costs nothing in usability.
LOG=$(mktemp "${TMPDIR:-/tmp}/agentic-check-gate.XXXXXX") || LOG="${TMPDIR:-/tmp}/agentic-check-gate.$$.log"

if make check >"$LOG" 2>&1; then
  rm -f "$LOG"
  # Record the state this green verdict belongs to. Written atomically: several subagents
  # can finish at once, and a half-written stamp would either skip a needed gate or, worse,
  # match nothing forever. A stale stamp is never dangerous on its own — it only ever
  # matches a tree state that did pass, so reverting to a known-green state skips correctly.
  if [ -n "$STAMP" ] && [ -n "$STATE" ]; then
    if printf '%s\n' "$STATE" > "$STAMP.tmp.$$" 2>/dev/null; then
      mv -f "$STAMP.tmp.$$" "$STAMP" 2>/dev/null || rm -f "$STAMP.tmp.$$" 2>/dev/null
    else
      rm -f "$STAMP.tmp.$$" 2>/dev/null
    fi
  fi
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
