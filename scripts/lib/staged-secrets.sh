#!/usr/bin/env bash
# Shared staged-index scanner for the Git hook and legacy PreToolUse adapter.

block() {
  echo 'agentic-flow: staged credential blocked' >&2
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

scan_error() {
  echo "Blocked: could not scan the invoked Git repository ($1)." >&2
  exit 2
}

git_scan() {
  (cd "$SCAN_CWD" && env "${SCAN_ENV[@]+"${SCAN_ENV[@]}"}" git "${HOOK_GIT_ARGS[@]+"${HOOK_GIT_ARGS[@]}"}" "$@")
}

scan_index() {
  local diff staged gl_failed=0 pattern_failed=0 hit pat repo git_dir index_path status
  local -a GL_ENV
  # Deliberate false-positive override, visible in the invoking command or hook environment.
  [ "${AGENTIC_ALLOW_SECRET:-0}" = 1 ] && return 0
  for pat in "${SCAN_ENV[@]+"${SCAN_ENV[@]}"}"; do [ "$pat" = AGENTIC_ALLOW_SECRET=1 ] && return 0; done
  command -v git >/dev/null 2>&1 || scan_error 'git unavailable'
  repo=$(git_scan rev-parse --show-toplevel 2>/dev/null) || scan_error 'repository resolution'
  [ -n "$repo" ] || scan_error 'repository resolution'
  git_dir=$(git_scan rev-parse --absolute-git-dir 2>/dev/null) || scan_error 'Git directory resolution'
  index_path=$(git_scan rev-parse --git-path index 2>/dev/null) || scan_error 'index resolution'
  case "$index_path" in /*) ;; *) index_path="$EFFECTIVE_CWD/$index_path" ;; esac
  # gitleaks invokes Git itself. Pin all three paths to the resolved invocation
  # so changing its cwd to the worktree cannot switch it to a different index.
  GL_ENV=("${SCAN_ENV[@]+"${SCAN_ENV[@]}"}" "GIT_DIR=$git_dir" "GIT_WORK_TREE=$repo" "GIT_INDEX_FILE=$index_path")
  git_scan diff --cached --quiet 2>/dev/null
  status=$?
  case "$status" in 0) return 0 ;; 1) ;; *) scan_error 'staged index' ;; esac
  diff=$(git_scan diff --cached --unified=0 2>/dev/null | head -c 4194305) \
    || scan_error 'staged diff'
  [ "${#diff}" -le 4194304 ] || scan_error 'staged diff exceeds scan bound'
  staged=$(printf '%s\n' "$diff" | grep -E '^\+' | grep -Ev '^\+\+\+') || staged=''

  # Both scanners inspect the same resolved repository and index. Their output
  # is never included in the hook diagnostic because it may contain credentials.
  if [ "${AGENTIC_SKIP_GITLEAKS:-0}" != 1 ] && command -v gitleaks >/dev/null 2>&1; then
    if gitleaks git --help >/dev/null 2>&1; then
      (cd "$repo" && env "${GL_ENV[@]}" gitleaks git --staged --no-banner --redact --timeout 12) \
        >/dev/null 2>&1 || gl_failed=1
    else
      (cd "$repo" && env "${GL_ENV[@]}" gitleaks protect --staged --no-banner --redact --timeout 12) \
        >/dev/null 2>&1 || gl_failed=1
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
[ -n "$staged" ] || {
  [ "$gl_failed" -eq 0 ] || block '  gitleaks did not clear the staged index.'
  return 0
}

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
    pattern_failed=1
    break
  fi
done

# Hardcoded assignment of a secret-ish name to a literal string. Higher false-positive rate
# than the formats above, so obvious placeholders are excluded rather than reported.
ASSIGN="$(printf '(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token)%s' '["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{8,}["'"'"']')"
PLACEHOLDER='(example|changeme|change-me|placeholder|redacted|dummy|sample|your[-_]|xxx|\.\.\.|<[^>]*>|\$\{|\$\(|process\.env|os\.environ|getenv|secrets\.)'

if hit=$(printf '%s' "$staged" | grep -Ei -- "$ASSIGN" | grep -Eiv -- "$PLACEHOLDER" | head -1); then
  if [ -n "$hit" ]; then
    pattern_failed=1
  fi
fi

if [ "$pattern_failed" -eq 1 ]; then
  block '  staged diff matches a known credential pattern.'
fi
[ "$gl_failed" -eq 0 ] || block '  gitleaks did not clear the staged index.'
return 0
}
