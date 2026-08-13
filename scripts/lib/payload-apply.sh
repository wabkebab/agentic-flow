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

# Scopes this export/upgrade leaves out, space-separated (e.g. "codex opencode" for a
# Claude-only project). Set before payload_load_manifest; deliberately NOT cleared by
# payload_reset_manifest so a caller sets it once. The scope column was validated and then
# discarded, which is why --claude-only used to ship every Codex and OpenCode file anyway;
# consuming it here is what makes the flag mean what its name says.
PAYLOAD_EXCLUDED_SCOPES="${PAYLOAD_EXCLUDED_SCOPES:-}"

payload_scope_excluded() { # <scope>
  local s
  for s in $PAYLOAD_EXCLUDED_SCOPES; do
    [ "$s" = "$1" ] && return 0
  done
  return 1
}

payload_reset_manifest() {
  EXCLUDE_BASENAMES=( settings.local.json .DS_Store )
  EXCLUDE_PATHS=()
  ITEM_SRCS=()
  ITEM_DSTS=()
  ITEM_POLICIES=()
  FILES=()
  DESTS=()
  FILE_POLICIES=()
}

# Deep-merge the scaffold's JSON into an existing file, printing the result. Adopter values
# win on scalar conflict — the scaffold adds what is missing, it does not redecide what the
# project already stated — while hook arrays are unioned so the scaffold's guards are present
# without dropping the adopter's own. Entries are deduped so repeated upgrades don't stack.
# Non-zero exit means "not mergeable", and the caller falls back to a .agentic-new candidate.
payload_merge_json() { # <incoming-src> <existing-dst>
  command -v jq >/dev/null 2>&1 || return 1
  jq -e . "$1" >/dev/null 2>&1 || return 1
  jq -e . "$2" >/dev/null 2>&1 || return 1
  jq -s '
    def dedupe: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
    .[0] as $incoming | .[1] as $existing
    | ($incoming * $existing) as $base
    | ($incoming.hooks // {}) as $ih
    | ($existing.hooks // {}) as $eh
    | if ($ih | length) == 0 and ($eh | length) == 0 then $base
      else $base + { hooks: (
             reduce ((($ih | keys_unsorted) + ($eh | keys_unsorted)) | unique)[] as $event
               ({}; .[$event] = ((($eh[$event] // []) + ($ih[$event] // [])) | dedupe)))
           }
      end
  ' "$1" "$2"
}

payload_load_manifest() { # <manifest-path>
  local manifest="$1" src_item dst_item scope merge_policy disposition
  payload_reset_manifest
  [ -f "$manifest" ] || payload_die "payload manifest not found: $manifest"
  while IFS="$(printf '\t')" read -r src_item dst_item scope merge_policy disposition; do
    case "${src_item:-}" in ""|\#*) continue ;; esac
    [ -n "${dst_item:-}" ] || payload_die "manifest entry has no destination: $src_item"
    case "${merge_policy:-}" in preserve|merge|force|none) ;; *)
      payload_die "manifest entry has invalid merge policy '$merge_policy': $src_item" ;;
    esac
    [ -n "${scope:-}" ] || payload_die "manifest entry has no scope: $src_item"
    case "${disposition:-}" in
      export)
        # An excluded scope is treated as source-only: kept out of the copy list AND out of
        # directory walks, so a parent entry cannot sweep it back in.
        if payload_scope_excluded "$scope"; then
          EXCLUDE_PATHS+=("$src_item")
        else
          ITEM_SRCS+=("$src_item")
          ITEM_DSTS+=("$dst_item")
          ITEM_POLICIES+=("$merge_policy")
        fi
        ;;
      source-only)
        EXCLUDE_PATHS+=("$src_item")
        ;;
      *)
        payload_die "manifest entry has invalid disposition '${disposition:-}': $src_item"
        ;;
    esac
  done < "$manifest"
}

payload_is_excluded() { # <relative-source-path>
  local rel="$1" base x i
  base=$(basename "$rel")
  for x in "${EXCLUDE_BASENAMES[@]}"; do [ "$base" = "$x" ] && return 0; done
  i=0
  while [ "$i" -lt "${#EXCLUDE_PATHS[@]}" ]; do
    x="${EXCLUDE_PATHS[$i]}"
    i=$((i + 1))
    case "$rel" in "$x"|"$x"/*) return 0 ;; esac
  done
  return 1
}

payload_destination_files() { # <root>
  local root="$1"
  local manifest="$root/config/payload.tsv" source destination _scope _merge disposition file rel suffix
  [ -f "$manifest" ] || return 0
  while IFS="$(printf '\t')" read -r source destination _scope _merge disposition; do
    case "${source:-}" in ""|\#*) continue ;; esac
    [ "${disposition:-}" = export ] || continue
    if [ -f "$root/$destination" ]; then
      printf '%s\n' "$destination"
    elif [ -d "$root/$destination" ]; then
      while IFS= read -r file; do
        rel="${file#"$root"/}"
        printf '%s\n' "$rel"
      done < <(find "$root/$destination" -type f | sort)
    elif [ -d "$root/$source" ]; then
      while IFS= read -r file; do
        rel="${file#"$root/$source"/}"
        if [ "$source" = "$destination" ]; then
          printf '%s/%s\n' "$destination" "$rel"
        else
          suffix="${rel#"$source"/}"
          printf '%s/%s\n' "$destination" "$suffix"
        fi
      done < <(find "$root/$source" -type f | sort)
    else
      printf '%s\n' "$destination"
    fi
  done < "$manifest" | sort -u
}

payload_ignored_paths() { # <root>
  local root="$1" path
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if git -C "$root" check-ignore -q -- "$path" 2>/dev/null; then
      printf '%s\n' "$path"
    fi
  done < <(payload_destination_files "$root")
}

payload_expand_files() { # <src-root>
  local src_root="$1" manifest_i src_item dst_item policy f rel suffix
  FILES=()
  DESTS=()
  FILE_POLICIES=()
  manifest_i=0
  while [ "$manifest_i" -lt "${#ITEM_SRCS[@]}" ]; do
    src_item="${ITEM_SRCS[$manifest_i]}"
    dst_item="${ITEM_DSTS[$manifest_i]}"
    policy="${ITEM_POLICIES[$manifest_i]:-preserve}"
    manifest_i=$((manifest_i + 1))

    if [ -f "$src_root/$src_item" ]; then
      payload_queue_file "$src_item" "$dst_item" "$policy"
    elif [ -d "$src_root/$src_item" ]; then
      while IFS= read -r f; do
        rel="${f#"$src_root"/}"
        if [ "$src_item" = "$dst_item" ]; then
          payload_queue_file "$rel" "$rel" "$policy"
        else
          suffix="${rel#"$src_item"/}"
          payload_queue_file "$rel" "$dst_item/$suffix" "$policy"
        fi
      done < <(find "$src_root/$src_item" -type f | sort)
    else
      payload_die "manifest source does not exist: $src_item"
    fi
  done
}

payload_queue_file() { # <source-rel> <dest-rel> [merge-policy]
  local src_rel="$1" dst_rel="$2" policy="${3:-preserve}" i
  i=0
  while [ "$i" -lt "${#DESTS[@]}" ]; do
    [ "${DESTS[$i]}" = "$dst_rel" ] && return 0
    i=$((i + 1))
  done
  FILES+=("$src_rel")
  DESTS+=("$dst_rel")
  FILE_POLICIES+=("$policy")
}

payload_apply_entry() { # <src> <dst> <mode> [merge-policy]
  local src="$1" dst="$2" mode="$3" policy="${4:-preserve}" candidate content_id merged
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

    # A `merge` row reconciles in place instead of handing the adopter two files to
    # diff by hand. Only reached when the destination already exists and differs; any
    # failure (no jq, invalid JSON either side) falls through to the candidate path
    # below, so this can degrade but never lose the adopter's file.
    if [ "$policy" = merge ]; then
      merged="$dst.agentic-merge.$$"
      if payload_merge_json "$src" "$dst" > "$merged" 2>/dev/null && [ -s "$merged" ]; then
        if cmp -s "$merged" "$dst"; then
          rm -f "$merged"
          PAYLOAD_RESULT_CLASSIFICATION=same
          printf '%s\n' same
          return
        fi
        if [ "${PAYLOAD_DRY:-false}" = true ]; then
          rm -f "$merged"
        else
          cat "$merged" > "$dst"
          rm -f "$merged"
        fi
        PAYLOAD_RESULT_PATH="$dst"
        PAYLOAD_RESULT_CLASSIFICATION=merged
        printf '%s\n' merged
        return
      fi
      rm -f "$merged"
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
