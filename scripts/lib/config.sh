#!/usr/bin/env bash
# Resolve the parser path before callers change directories.
CONFIG_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/roles.sh
. "$CONFIG_LIB/roles.sh"

config_operator_path() { # root; a local-only checkout or a station without HOME has no operator layer
  local base slug
  base=${XDG_CONFIG_HOME:-}
  if [ -z "$base" ] && [ -n "${HOME:-}" ]; then base="$HOME/.config"; fi
  [ -n "$base" ] || return 0
  slug=$(roles_repository_slug "$1" 2>/dev/null) || return 0
  printf '%s/agentic-flow/config/%s.conf\n' "$base" "$slug"
}

config_load() { # root [local|ci]; CONFIG_JSON contains values, sources and tiers
  local mode=${2:-local} operator
  CONFIG_JSON=
  case "$mode" in local|ci) ;; *) return 2 ;; esac
  if [ "${CI:-}" = true ]; then mode=ci; fi
  operator=$(config_operator_path "$1")
  CONFIG_JSON=$(perl "$CONFIG_LIB/config-data.pl" "$1" "$operator" "$mode" list --json)
}

config_get() { # key
  jq -er --arg key "$1" '.[$key].value' <<< "$CONFIG_JSON"
}

config_pin() { # root [revision]
  local root=$1
  shift
  perl "$CONFIG_LIB/config-data.pl" "$root" '' local pin "$@"
}

config_diagnose() { # root
  perl "$CONFIG_LIB/config-data.pl" "$1" '' local diagnose
}

config_cmd() { # root command arguments; adoption supplies the target before a stamp exists
  local root=$1 operator='' mode=local
  shift
  case "${1:-list}" in list|--json|get|explain|set|unset) operator=$(config_operator_path "$root") ;; esac
  if [ "${CI:-}" = true ]; then mode=ci; fi
  perl "$CONFIG_LIB/config-data.pl" "$root" "$operator" "$mode" "$@"
}
