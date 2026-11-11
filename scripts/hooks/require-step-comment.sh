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
  local root roles
  root=$(git rev-parse --show-toplevel) || exit 2
  # shellcheck disable=SC1091
  . "$root/scripts/lib/review-policy.sh"
  if ! read_review_policy "$root"; then
    echo "Blocked: fix $root/.agentic-flow-review-policy; reviewer, executor and approver logins are required." >&2
    return 1
  fi
  roles=$REVIEW_REVIEWERS
  [ "${2:-reviewer}" != executor ] || roles=$REVIEW_EXECUTORS
  gh issue view "$1" --json comments 2>/dev/null |
    jq -r --arg roles "$roles" '[.comments[] | select(.author.login as $login | ($roles | split(" ") | index($login)) != null)] | last | .body // ""'
}

# Handoff: implementor -> reviewer. `gh issue edit <N> --add-label "...needs-review..."`
# AGENTS.md step 5 requires a comment naming the sha + what changed before this runs.
if printf '%s' "$cmd" | grep -Eq 'gh[[:space:]]+issue[[:space:]]+edit[[:space:]]+[0-9]+.*--add-label[[:space:]]+"?[^"]*needs-review'; then
  n=$(issue_number "$(printf '%s' "$cmd" | grep -Eo 'issue[[:space:]]+edit[[:space:]]+[0-9]+')")
  last=$(last_comment "$n" executor) || exit 2
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
    last=$(last_comment "$n") || exit 2
    if ! printf '%s' "$last" | grep -Eiq 'changes requested|finding'; then
      echo "Blocked: comment the findings on issue #$n before sending it back to needs-execution (code-reviewer.md)." >&2
      exit 2
    fi
  fi
fi

# Standard review handoff: the sole work issue stays open until close-out.
if printf '%s' "$cmd" | grep -Eq 'gh[[:space:]]+issue[[:space:]]+edit[[:space:]]+[0-9]+.*--add-label[[:space:]]+"?[^"]*needs-closing'; then
  n=$(issue_number "$(printf '%s' "$cmd" | grep -Eo 'issue[[:space:]]+edit[[:space:]]+[0-9]+')")
  body=$(gh issue view "$n" --json body --jq .body 2>/dev/null || printf '')
  if printf '%s\n' "$body" | grep -Fxq '<!-- agentic-flow:topology:standard -->'; then
    last=$(last_comment "$n") || exit 2
    if ! printf '%s\n' "$last" | grep -Eq '^[[:space:]]*agentic-flow-review: status=approved; step=[a-z0-9][a-z0-9._-]*; head=[0-9a-f]{40}; role=reviewer$'; then
      echo "Blocked: post the approving structured step verdict on Standard work issue #$n before needs-closing." >&2
      exit 2
    fi
  fi
fi

# Approval: reviewer closing a step issue. `gh issue close <N>`
if printf '%s' "$cmd" | grep -Eq 'gh[[:space:]]+issue[[:space:]]+close[[:space:]]+[0-9]+'; then
  n=$(issue_number "$(printf '%s' "$cmd" | grep -Eo 'issue[[:space:]]+close[[:space:]]+[0-9]+')")
  body=$(gh issue view "$n" --json body --jq .body 2>/dev/null || printf '')
  if printf '%s\n' "$body" | grep -Fxq '<!-- agentic-flow:topology:standard -->'; then
    labels=$(gh issue view "$n" --json labels --jq '.labels[].name' 2>/dev/null || printf '')
    if ! printf '%s\n' "$labels" | grep -Fxq needs-closing; then
      echo "Blocked: Standard work issue #$n must reach needs-closing before close-out." >&2
      exit 2
    fi
    last=$(last_comment "$n") || exit 2
    if ! printf '%s\n' "$last" | grep -Eq '^[[:space:]]*agentic-flow-review: status=approved; pr=[1-9][0-9]*; head=[0-9a-f]{40}; run=https://github.com/[^/]+/[^/]+/actions/runs/[1-9][0-9]*; attempt=[1-9][0-9]*; role=reviewer$'; then
      echo "Blocked: Standard work issue #$n needs final-head approval before close-out." >&2
      exit 2
    fi
    exit 0
  fi
  last=$(last_comment "$n") || exit 2
  if ! printf '%s' "$last" | grep -Eiq 'approved'; then
    echo "Blocked: post the review verdict as a comment on issue #$n before closing it (code-reviewer.md)." >&2
    exit 2
  fi
fi

exit 0
