#!/usr/bin/env bash
# Shared payload manifest and apply helpers for export.sh and scripts/agentic-flow.
#
# This file is sourced, not executed. Keep Bash 3.2-compatible: no associative arrays,
# no mapfile, and guard array access under set -u.

# shellcheck disable=SC2034 # Result globals are consumed by scripts that source this file.

payload_die() {
  echo "error: $*" >&2
  exit 1
}

payload_reset_manifest() {
  EXCLUDE_BASENAMES=( settings.local.json .DS_Store )
  EXCLUDE_PATHS=()
  ITEM_SRCS=()
  ITEM_DSTS=()
  FILES=()
  DESTS=()
}

payload_load_manifest() { # <manifest-path>
  local manifest="$1" src_item dst_item scope merge_policy disposition
  payload_reset_manifest
  [ -f "$manifest" ] || payload_die "payload manifest not found: $manifest"
  while IFS="$(printf '\t')" read -r src_item dst_item scope merge_policy disposition; do
    case "${src_item:-}" in ""|\#*) continue ;; esac
    [ -n "${dst_item:-}" ] || payload_die "manifest entry has no destination: $src_item"
    case "${disposition:-}" in
      export)
        ITEM_SRCS+=("$src_item")
        ITEM_DSTS+=("$dst_item")
        ;;
      source-only)
        EXCLUDE_PATHS+=("$src_item")
        ;;
      *)
        payload_die "manifest entry has invalid disposition '${disposition:-}': $src_item"
        ;;
    esac
    case "${merge_policy:-}" in preserve|force|none) ;; *)
      payload_die "manifest entry has invalid merge policy '$merge_policy': $src_item" ;;
    esac
    [ -n "${scope:-}" ] || payload_die "manifest entry has no scope: $src_item"
  done < "$manifest"
}

payload_is_excluded() { # <relative-source-path>
  local rel="$1" base x
  base=$(basename "$rel")
  for x in "${EXCLUDE_BASENAMES[@]}"; do [ "$base" = "$x" ] && return 0; done
  for x in "${EXCLUDE_PATHS[@]}"; do
    case "$rel" in "$x"|"$x"/*) return 0 ;; esac
  done
  return 1
}

payload_expand_files() { # <src-root>
  local src_root="$1" manifest_i src_item dst_item f rel suffix
  FILES=()
  DESTS=()
  manifest_i=0
  while [ "$manifest_i" -lt "${#ITEM_SRCS[@]}" ]; do
    src_item="${ITEM_SRCS[$manifest_i]}"
    dst_item="${ITEM_DSTS[$manifest_i]}"
    manifest_i=$((manifest_i + 1))

    if [ -f "$src_root/$src_item" ]; then
      payload_queue_file "$src_item" "$dst_item"
    elif [ -d "$src_root/$src_item" ]; then
      while IFS= read -r f; do
        rel="${f#"$src_root"/}"
        if [ "$src_item" = "$dst_item" ]; then
          payload_queue_file "$rel" "$rel"
        else
          suffix="${rel#"$src_item"/}"
          payload_queue_file "$rel" "$dst_item/$suffix"
        fi
      done < <(find "$src_root/$src_item" -type f | sort)
    else
      payload_die "manifest source does not exist: $src_item"
    fi
  done
}

payload_queue_file() { # <source-rel> <dest-rel>
  local src_rel="$1" dst_rel="$2" i
  i=0
  while [ "$i" -lt "${#DESTS[@]}" ]; do
    [ "${DESTS[$i]}" = "$dst_rel" ] && return 0
    i=$((i + 1))
  done
  FILES+=("$src_rel")
  DESTS+=("$dst_rel")
}

payload_apply_entry() { # <src> <dst> <mode>
  local src="$1" dst="$2" mode="$3" candidate content_id
  PAYLOAD_RESULT_PATH=""
  PAYLOAD_RESULT_CANDIDATE_ACTION=""
  PAYLOAD_RESULT_CLASSIFICATION=""
  case "$mode" in apply|dry-run|force) ;; *)
    payload_die "invalid payload apply mode: $mode" ;;
  esac

  if [ -e "$dst" ]; then
    if cmp -s "$src" "$dst"; then
      PAYLOAD_RESULT_CLASSIFICATION=same
      printf '%s\n' same
      return
    fi
    if [ "$mode" = force ]; then
      [ "${PAYLOAD_DRY:-false}" = true ] || { mkdir -p "$(dirname "$dst")"; cp -p "$src" "$dst"; }
      PAYLOAD_RESULT_CLASSIFICATION=overwrite
      printf '%s\n' overwrite
      return
    fi

    candidate="$dst.agentic-new"
    if [ -e "$candidate" ] && ! cmp -s "$src" "$candidate"; then
      candidate="$dst.agentic-new.${PAYLOAD_VERSION:-unknown}"
    fi
    if [ -e "$candidate" ] && ! cmp -s "$src" "$candidate"; then
      content_id=$(git hash-object "$src" 2>/dev/null | cut -c1-12)
      [ -n "$content_id" ] || content_id=$(cksum "$src" | awk '{print $1}')
      candidate="$dst.agentic-new.${PAYLOAD_VERSION:-unknown}.$content_id"
    fi
    if [ -e "$candidate" ]; then
      cmp -s "$src" "$candidate" \
        || payload_die "refusing to overwrite occupied merge candidate: ${candidate#"$PAYLOAD_DST_ROOT"/}"
      PAYLOAD_RESULT_CANDIDATE_ACTION=pending
      PAYLOAD_RESULT_PATH="$candidate"
      PAYLOAD_RESULT_CLASSIFICATION=pending
      printf '%s\n' pending
    else
      [ "${PAYLOAD_DRY:-false}" = true ] || { mkdir -p "$(dirname "$candidate")"; cp -p "$src" "$candidate"; }
      PAYLOAD_RESULT_CANDIDATE_ACTION=candidate
      PAYLOAD_RESULT_PATH="$candidate"
      PAYLOAD_RESULT_CLASSIFICATION=candidate
      printf '%s\n' candidate
    fi
  else
    [ "${PAYLOAD_DRY:-false}" = true ] || { mkdir -p "$(dirname "$dst")"; cp -p "$src" "$dst"; }
    PAYLOAD_RESULT_CLASSIFICATION=create
    printf '%s\n' create
  fi
}

payload_compute_version() { # <src-root>
  local src_root="$1" semver sha
  semver=$(sed -n '1p' "$src_root/VERSION" 2>/dev/null || true)
  [ -n "$semver" ] || semver="0.0.0"
  sha=$(git -C "$src_root" rev-parse --short HEAD 2>/dev/null || printf '%s\n' unknown)
  printf '%s+%s\n' "$semver" "$sha"
}

payload_stamp_version() { # <src-root> <dst-root> <pending-count>
  local src_root="$1" dst_root="$2" pending_count="$3" version
  version=${PAYLOAD_VERSION:-$(payload_compute_version "$src_root")}
  if [ "${PAYLOAD_DRY:-false}" = false ]; then
    if [ "${PAYLOAD_FORCE:-false}" = true ] || [ "$pending_count" -eq 0 ]; then
      printf '%s\n' "$version" > "$dst_root/.agentic-flow-version"
      rm -f "$dst_root/.agentic-flow-candidate-version"
    else
      printf '%s\n' "$version" > "$dst_root/.agentic-flow-candidate-version"
    fi
  fi
}
