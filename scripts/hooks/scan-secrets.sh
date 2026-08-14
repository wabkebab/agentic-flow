#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Scans STAGED content for credentials before a commit
# is allowed, implementing METHODOLOGY.md §11 "secret scanning at the commit boundary".
#
# Why here and not only in CI: a secret that reaches a commit is already burned. Rewriting
# history does not un-leak it — the credential must be rotated. CI catches it one step too
# late; this catches it while the fix is still `git restore --staged`.
#
# Two layers, both always applied: gitleaks (broad, curated rules) when installed, AND the
# high-signal pattern set below. The patterns are not a fallback — gitleaks allowlists
# documented sample credentials, so the local set is what keeps behaviour identical whether
# or not the tool is present. Reads the tool-call JSON on stdin.
# Exit 2 = block the call and show stderr to the agent; exit 0 = allow.
set -uo pipefail

# jq is the documented requirement and the clean path. Without it the guard used to exit 0,
# which is a silent allow (only exit 2 blocks). Degrade to scanning the raw payload instead.
#
# The two modes need different delimiters, and conflating them is a live false positive: in
# the raw payload the command is JSON-quoted, so a double quote has to count as a boundary —
# in the extracted command it does not, and treating it as one blocks a command that merely
# mentions the string, e.g. rg for it in a doc. Keep the loose delimiters to the degraded path.
raw=$(cat 2>/dev/null || true)
if command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$raw" | jq -r '.tool_input.command // ""' 2>/dev/null) || cmd=""
  LEAD='(^|[[:space:];&|(])'
  TAIL='([[:space:]]|$)'
else
  cmd=$raw
  LEAD='(^|[[:space:];&|("])'
  TAIL='([[:space:]"]|$)'
fi
[ -n "$cmd" ] || exit 0

# Only interested in commit commands (git, or the git-claude / git-codex wrappers,
# with intervening -C/-c args).
printf '%s' "$cmd" \
  | grep -Eq "$LEAD"'(git|git-claude|git-codex)([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|--?[A-Za-z][-A-Za-z0-9]*(=[^[:space:]]*)?))*[[:space:]]+commit'"$TAIL" \
  || exit 0

# Deliberate escape hatch. False positives are inevitable in a pattern-based scanner, and a
# gate with no override gets disabled wholesale — which is strictly worse than one that is
# occasionally bypassed on purpose. Bypasses are visible in the transcript.
if [ "${AGENTIC_ALLOW_SECRET:-0}" = "1" ]; then
  exit 0
fi

command -v git >/dev/null 2>&1 || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Nothing staged: let git produce its own "nothing to commit" error.
git diff --cached --quiet 2>/dev/null && exit 0

block() {
  echo "Blocked: staged changes look like they contain a credential." >&2
  echo "" >&2
  echo "$1" >&2
  echo "" >&2
  echo "A committed secret is a leaked secret — rewriting history does not un-leak it;" >&2
  echo "the credential has to be rotated. Fix it now, while it is still only staged:" >&2
  echo "  git restore --staged <file>   # unstage, then remove the literal" >&2
  echo "Move the value to config/env and commit a reference to it instead." >&2
  echo "" >&2
  echo "If this is a false positive (a fixture, a placeholder, a public sample key)," >&2
  echo "re-run the commit with AGENTIC_ALLOW_SECRET=1 prefixed." >&2
  exit 2
}

# --- layer 1: gitleaks -------------------------------------------------------------------
# ADDITIVE, not an alternative. An earlier version returned gitleaks' verdict and skipped
# the patterns below, which made the hook *weaker* on a machine that had gitleaks: its
# default config allowlists documented sample credentials, so a staged AWS example key came
# back clean and nothing else ran. Behaviour must not depend on which tools are installed.
if [ "${AGENTIC_SKIP_GITLEAKS:-0}" != "1" ] && command -v gitleaks >/dev/null 2>&1; then
  # `gitleaks git --staged` is the modern spelling; `protect --staged` is the pre-8.19 one.
  if gitleaks git --help >/dev/null 2>&1; then
    gl_out=$(gitleaks git --staged --no-banner --redact 2>&1) || block "$gl_out"
  else
    gl_out=$(gitleaks protect --staged --no-banner --redact 2>&1) || block "$gl_out"
  fi
fi

# --- layer 2: high-signal patterns -------------------------------------------------------
# Always runs, gitleaks present or not.
# High-signal only: these have a shape that essentially cannot occur by accident. A noisy
# scanner trains people to bypass it, which costs more than the leaks it catches.
#
# Patterns are ASSEMBLED, never written literally, so that staging THIS file does not trip
# the hook against its own source. Same reason scripts/self-test.sh builds its placeholder
# pattern with printf — a self-matching guard is a guard that cries wolf forever.
staged=$(git diff --cached --unified=0 2>/dev/null | grep -E '^\+' | grep -Ev '^\+\+\+') || staged=""
[ -n "$staged" ] || exit 0

AWS_KEY="$(printf 'AKIA%s' '[0-9A-Z]{16}')"
PRIV_KEY="$(printf -- '-----BEGIN[A-Z ]*PRIVATE %s-----' 'KEY')"
GH_TOKEN="$(printf 'gh[pousr]_%s' '[A-Za-z0-9]{36,}')"
SLACK="$(printf 'xox[baprs]-%s' '[A-Za-z0-9-]{10,}')"
STRIPE="$(printf 'sk_live_%s' '[A-Za-z0-9]{16,}')"
GOOGLE="$(printf 'AIza%s' '[0-9A-Za-z_-]{35}')"
ANTHROPIC="$(printf 'sk-ant-%s' '[A-Za-z0-9_-]{20,}')"
OPENAI="$(printf 'sk-proj-%s' '[A-Za-z0-9_-]{20,}')"

for pat in "$AWS_KEY" "$PRIV_KEY" "$GH_TOKEN" "$SLACK" "$STRIPE" "$GOOGLE" "$ANTHROPIC" "$OPENAI"; do
  # `--` matters: the private-key pattern starts with dashes and would otherwise be
  # parsed as grep options (silently matching nothing, i.e. a guard that never fires).
  if hit=$(printf '%s' "$staged" | grep -Eo -- "$pat" | head -1); then
    [ -n "$hit" ] || continue
    # Show the shape, not the value — hook stderr goes into the transcript.
    block "  staged line matches a known credential format: $(printf '%s' "$hit" | cut -c1-8)…"
  fi
done

# Hardcoded assignment of a secret-ish name to a literal string. Higher false-positive rate
# than the formats above, so obvious placeholders are excluded rather than reported.
ASSIGN="$(printf '(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token)%s' '["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{8,}["'"'"']')"
PLACEHOLDER='(example|changeme|change-me|placeholder|redacted|dummy|sample|your[-_]|xxx|\.\.\.|<[^>]*>|\$\{|\$\(|process\.env|os\.environ|getenv|secrets\.)'

if hit=$(printf '%s' "$staged" | grep -Ei -- "$ASSIGN" | grep -Eiv -- "$PLACEHOLDER" | head -1); then
  if [ -n "$hit" ]; then
    block "  staged line hardcodes a secret-looking value:
    $(printf '%s' "$hit" | sed -E 's/([:=][[:space:]]*["'"'"']).{4,}/\1…/' | cut -c1-100)"
  fi
fi

exit 0
