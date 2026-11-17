#!/usr/bin/env bash
# Local advisory records. The journal, never this ledger, authorizes transitions.
LEDGER_HELPER=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/ledger.pl
ledger_init() { # [worktree]; all worktrees share one ledger directory
  local root=${1:-$PWD} common
  common=$(git -C "$root" rev-parse --git-common-dir) || return 2
  case "$common" in /*) ;; *) common="$root/$common" ;; esac
  common=$(cd "$common" && pwd -P) || return 2
  LEDGER_DIR="$common/agentic-flow/ledger"
  LEDGER_STATE_DIR="$common/agentic-flow/state"
}
ledger_backend() {
  [ -n "${LEDGER_DIR:-}" ] || ledger_init || return 2
  perl "$LEDGER_HELPER" "$LEDGER_DIR" "$@"
}
ledger_read() { ledger_backend read "$@"; }             # plan -> records JSON
ledger_chains() { ledger_backend chains "$@"; }         # plan [context JSON file]
ledger_generation() { ledger_backend generation "$@"; } # plan issue seq station
ledger_body() { ledger_backend body "$@"; }             # plan run -> verified bytes
ledger_append() { ledger_backend append "$@"; }         # kind plan record JSON file
ledger_intent() { ledger_append intent "$@"; }
ledger_session() { ledger_append session "$@"; }
ledger_station() { ledger_append station "$@"; }
ledger_verify() { ledger_append verify "$@"; }
ledger_decision() { ledger_append decision "$@"; }
ledger_handoff() { ledger_append handoff "$@"; }
ledger_salvage() { ledger_append salvage "$@"; }
ledger_end() { ledger_append end "$@"; }
ledger_hold() { ledger_append hold "$@"; }
ledger_clear() { ledger_append clear "$@"; }
ledger_ship() { ledger_append ship "$@"; }
metrics_cmd() {
  local plan='' since='' json=false root
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --plan|--since)
        [ "$#" -ge 2 ] || { echo "metrics: $1 requires a value" >&2; return 2; }
        case "$1" in --plan) plan=$2 ;; --since) since=$2 ;; esac
        shift 2 ;;
      --json) json=true; shift ;;
      *) echo "metrics: unknown argument $1" >&2; return 2 ;;
    esac
  done
  root=$(git rev-parse --show-toplevel) || return 2
  ledger_init "$root" || return 2
  ledger_backend metrics "$plan" "$since" "$json" "$LEDGER_STATE_DIR"
}
