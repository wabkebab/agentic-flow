#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Enforces the step issue label state machine in
# CLAUDE.md: an implementor must comment the commit sha + title on the step issue before
# flipping it to needs-review, and closing a step issue requires a verdict comment first.
# Reads the tool-call JSON on stdin. Exit 2 = block the call and show stderr to the agent;
# exit 0 = allow.
set -uo pipefail

raw=$(cat 2>/dev/null || true)
if command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$raw" | jq -r '.tool_input.command // ""' 2>/dev/null) || cmd=""
else
  cmd=$raw
fi
[ -n "$cmd" ] || exit 0

# Without gh there is nothing to check against; let the command fail on its own.
command -v gh >/dev/null 2>&1 || exit 0

issue_number() {
  printf '%s' "$1" | grep -Eo '[0-9]+' | head -n1
}

last_comment() {
  gh issue view "$1" --json comments --jq '.comments[-1].body // ""' 2>/dev/null || printf ''
}

# Handoff: implementor -> reviewer. `gh issue edit <N> --add-label "...needs-review..."`
# AGENTS.md step 5 requires a comment naming the sha + what changed before this runs.
if printf '%s' "$cmd" | grep -Eq 'gh[[:space:]]+issue[[:space:]]+edit[[:space:]]+[0-9]+.*--add-label[[:space:]]+"?[^"]*needs-review'; then
  n=$(issue_number "$(printf '%s' "$cmd" | grep -Eo 'issue[[:space:]]+edit[[:space:]]+[0-9]+')")
  last=$(last_comment "$n")
  if ! printf '%s' "$last" | grep -Eiq 'implemented in' || ! printf '%s' "$last" | grep -Eq '[0-9a-f]{7,40}'; then
    echo "Blocked: comment the commit sha + title on issue #$n before moving it to needs-review (AGENTS.md step 5)." >&2
    exit 2
  fi
fi

# Bounce-back: reviewer -> implementor. `gh issue edit <N> --add-label "...needs-execution..."`
# on an issue that already carries needs-review means a findings comment must exist first.
if printf '%s' "$cmd" | grep -Eq 'gh[[:space:]]+issue[[:space:]]+edit[[:space:]]+[0-9]+.*--add-label[[:space:]]+"?[^"]*needs-execution'; then
  n=$(issue_number "$(printf '%s' "$cmd" | grep -Eo 'issue[[:space:]]+edit[[:space:]]+[0-9]+')")
  labels=$(gh issue view "$n" --json labels --jq '.labels[].name' 2>/dev/null || printf '')
  if printf '%s' "$labels" | grep -Fxq 'needs-review'; then
    last=$(last_comment "$n")
    if ! printf '%s' "$last" | grep -Eiq 'changes requested|finding'; then
      echo "Blocked: comment the findings on issue #$n before sending it back to needs-execution (code-reviewer.md)." >&2
      exit 2
    fi
  fi
fi

# Approval: reviewer closing a step issue. `gh issue close <N>`
if printf '%s' "$cmd" | grep -Eq 'gh[[:space:]]+issue[[:space:]]+close[[:space:]]+[0-9]+'; then
  n=$(issue_number "$(printf '%s' "$cmd" | grep -Eo 'issue[[:space:]]+close[[:space:]]+[0-9]+')")
  last=$(last_comment "$n")
  if ! printf '%s' "$last" | grep -Eiq 'approved'; then
    echo "Blocked: post the review verdict as a comment on issue #$n before closing it (code-reviewer.md)." >&2
    exit 2
  fi
fi

exit 0
