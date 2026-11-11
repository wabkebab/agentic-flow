#!/usr/bin/env bash
# Shell inventory: scaffold sources, recorded files, or recordless adopter destinations.
set -euo pipefail

root=${AGENTIC_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
manifest="$root/config/payload.tsv"
[ -f "$manifest" ] || { echo "shell inventory: missing $manifest" >&2; exit 1; }

shell_sources() {
  local source destination scope _merge disposition file rel excluded adopted=false
  if [ -f "$root/.agentic-flow-installation" ]; then
    # shellcheck disable=SC1091 # Installed library is resolved from the project root.
    . "$root/scripts/lib/payload-apply.sh"
    payload_resolve_installation "$root" "$manifest"
    printf '%s\n' "${PAYLOAD_STATE_FILES[@]}"
    return
  fi
  if [ ! -f "$root/scripts/export.sh" ]; then
    adopted=true
    # shellcheck disable=SC1091 # Installed library is resolved from the project root.
    . "$root/scripts/lib/payload-apply.sh"
    payload_resolve_installation "$root" "$manifest" "${PAYLOAD_EXCLUDED_SCOPES:-}"
  fi
  while IFS="$(printf '\t')" read -r source destination scope _merge disposition; do
    case "${source:-}" in ''|\#*) continue ;; esac
    if [ "$adopted" = true ]; then
      [ "$disposition" = export ] || continue
      payload_has_word "$scope" "$PAYLOAD_ACTIVE_SCOPES" || continue
      source=$destination
      [ -e "$root/$source" ] || {
        echo "shell inventory: missing installed file $destination; run scripts/doctor.sh" >&2
        return 1
      }
    fi
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
    if [ ! -f "$root/$rel" ]; then
      [ -f "$root/.agentic-flow-installation" ] \
        && { echo "shell inventory: recorded file missing: $rel" >&2; return 1; }
      continue
    fi
    IFS= read -r first < "$root/$rel" || true
    case "$first" in '#!'*'/bash'|'#!'*'/sh'|'#!'*'env bash'|'#!'*'env sh')
      printf '%s\n' "$rel" ;;
    esac
  done <<< "$sources"
}

case "${1:---list}" in
  --scope-state)
    case "${2:-}" in core|claude|codex|opencode|ci|docs) ;; *)
      echo 'shell inventory: unknown scope' >&2; exit 2 ;;
    esac
    # shellcheck disable=SC1091 # Installed library is resolved from the project root.
    . "$root/scripts/lib/payload-apply.sh"
    payload_resolve_installation "$root" "$manifest"
    if payload_has_word "$2" "$PAYLOAD_ACTIVE_SCOPES"; then
      echo active
    else
      echo inactive
    fi ;;
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
  *) echo 'usage: shell-inventory.sh --list|--syntax|--lint|--scope-state SCOPE' >&2; exit 2 ;;
esac
