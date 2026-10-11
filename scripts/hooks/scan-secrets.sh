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
# shellcheck disable=SC2329
set -uo pipefail
# shellcheck source=scripts/lib/hook-command.sh
. "$(dirname "$0")/../lib/hook-command.sh"

raw=$(head -c 65537)
if ! hook_read_command "$raw"; then
  if hook_maybe_protected "$raw" commit raw; then
    echo 'Blocked: could not parse a protected command.' >&2
    exit 2
  fi
  exit 0
fi
[ -n "$HOOK_COMMAND" ] || exit 0

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

scan_error() {
  echo "Blocked: could not scan the invoked Git repository ($1)." >&2
  exit 2
}

git_scan() {
  (cd "$SCAN_CWD" && env "${SCAN_ENV[@]+"${SCAN_ENV[@]}"}" git "${HOOK_GIT_ARGS[@]+"${HOOK_GIT_ARGS[@]}"}" "$@")
}

prepare_scan() {
  local entry name value arg i
  [ -n "$HOOK_CWD" ] || scan_error 'working directory'
  SCAN_CWD=$HOOK_CWD
  EFFECTIVE_CWD=$HOOK_CWD
  # Git applies -C before resolving relative paths supplied through GIT_*.
  for ((i=0; i<${#HOOK_GIT_ARGS[@]}; i++)); do
    arg=${HOOK_GIT_ARGS[i]}
    case "$arg" in
      -C) i=$((i+1)); value=${HOOK_GIT_ARGS[i]:-} ;;
      -C?*) value=${arg#-C} ;;
      *) continue ;;
    esac
    EFFECTIVE_CWD=$(cd "$EFFECTIVE_CWD" && cd "$value" && pwd -P) \
      || scan_error 'working directory'
  done
  SCAN_ENV=()
  for entry in "${HOOK_ENV[@]+"${HOOK_ENV[@]}"}"; do
    case "$entry" in -i|--ignore-environment|-u|--unset)
      scan_error 'unsupported env option' ;;
    esac
    name=${entry%%=*}; value=${entry#*=}
    case "$name" in
      GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE)
        case "$value" in /*) ;; *) value="$EFFECTIVE_CWD/$value" ;; esac
        SCAN_ENV+=("$name=$value") ;;
      GIT_*) scan_error "unsupported $name" ;;
      AGENTIC_ALLOW_SECRET)
        [ "$value" = 1 ] && SCAN_ENV+=("$entry") ;;
      *) SCAN_ENV+=("$entry") ;;
    esac
  done
  [ -z "$HOOK_ERROR" ] || scan_error "$HOOK_ERROR"
}

scan_commit() {
  local diff staged gl_failed=0 pattern_failed=0 hit pat repo git_dir index_path status
  case "$HOOK_KIND:$HOOK_VERB" in
    cd:)
      if [ "${#HOOK_WORDS[@]}" -ne 2 ]; then
        HOOK_CWD=''
      else
        HOOK_CWD=$(cd "$HOOK_CWD" && cd "${HOOK_WORDS[1]}" && pwd -P 2>/dev/null) \
          || HOOK_CWD=''
      fi
      return 0 ;;
    ambiguous_git:commit) scan_error 'unsupported command prefix' ;;
    git:commit) ;;
    *) return 0 ;;
  esac
  prepare_scan
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

hook_walk "$HOOK_COMMAND" scan_commit
status=$?
if [ "$status" -eq 1 ]; then
  if hook_maybe_protected "$HOOK_COMMAND" commit; then
    echo 'Blocked: could not parse a protected command.' >&2
    exit 2
  fi
  exit 0
fi
exit "$status"
