#!/usr/bin/env bash
# Scaffold-only shell inventory. Walk manifest source paths, never adopter destinations.
set -euo pipefail

root=${AGENTIC_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
manifest="$root/config/payload.tsv"
[ -f "$manifest" ] || { echo "shell inventory: missing $manifest" >&2; exit 1; }

shell_sources() {
  local source _destination scope _merge disposition file rel excluded
  while IFS="$(printf '\t')" read -r source _destination scope _merge disposition; do
    case "${source:-}" in ''|\#*) continue ;; esac
    excluded=false
    if [ "$disposition" = export ]; then
      case " ${PAYLOAD_EXCLUDED_SCOPES:-} " in *" $scope "*) excluded=true ;; esac
    fi
    [ "$excluded" = false ] || continue
    [ "$disposition" = export ] || [ "$disposition" = source-only ] || continue
    if [ -f "$root/$source" ]; then
      printf '%s\n' "$source"
    elif [ -d "$root/$source" ]; then
      while IFS= read -r file; do
        rel=${file#"$root"/}
        printf '%s\n' "$rel"
      done < <(find "$root/$source" -type f | sort)
    else
      [ "$disposition" = source-only ] || {
        echo "shell inventory: missing manifest source $source" >&2
        return 1
      }
    fi
  done < "$manifest"
}

shell_files() {
  local rel first sources
  sources=$(shell_sources | sort -u) || return 1
  while IFS= read -r rel; do
    [ -f "$root/$rel" ] || continue
    IFS= read -r first < "$root/$rel" || true
    case "$first" in '#!'*'/bash'|'#!'*'/sh'|'#!'*'env bash'|'#!'*'env sh')
      printf '%s\n' "$rel" ;;
    esac
  done <<< "$sources"
}

case "${1:---list}" in
  --list) shell_files ;;
  --syntax)
    inventory=$(shell_files) || exit 1
    [ -n "$inventory" ] || { echo 'shell inventory: no shell files' >&2; exit 1; }
    while IFS= read -r rel; do bash -n "$root/$rel"; done <<< "$inventory" ;;
  --lint)
    inventory=$(shell_files) || exit 1
    files=()
    while IFS= read -r rel; do [ -n "$rel" ] && files+=("$root/$rel"); done <<< "$inventory"
    [ "${#files[@]}" -gt 0 ] || { echo 'shell inventory: no shell files' >&2; exit 1; }
    shellcheck "${files[@]}" ;;
  *) echo 'usage: shell-inventory.sh --list|--syntax|--lint' >&2; exit 2 ;;
esac
