#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Scans STAGED content for credentials before a commit
# is allowed, implementing docs/reference/engineering-standards.md §11.1 "secret scanning at the commit boundary".
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

# shellcheck source=scripts/lib/staged-secrets.sh
. "$(dirname "$0")/../lib/staged-secrets.sh"

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
  scan_index
}

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
