#!/usr/bin/env bash
# Shared payload manifest and apply helpers for export.sh and scripts/agentic-flow.
#
# This file is sourced, not executed. Keep Bash 3.2-compatible: no associative arrays,
# no mapfile, and guard array access under set -u.

# shellcheck disable=SC2034 # Result globals are consumed by scripts that source this file.

# The 0.19 upgrader sources this library after fetching and confirming. Its
# diff/status callers keep using the library without handing off execution.
if [ "${FUNCNAME[2]:-}" = upgrade_cmd ] && [ "${PAYLOAD_ENTRY:-}" != 2 ]; then
  payload_bridge_args=(upgrade --bridged-from "$FETCH_PARENT" --confirmed)
  [ "${force:-false}" = false ] || payload_bridge_args+=(--force)
  [ -z "${override_ref:-}" ] || payload_bridge_args+=(--ref "$override_ref")
  exec "$source/scripts/agentic-flow" "${payload_bridge_args[@]}"
fi

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

payload_valid_scope() {
  case "$1" in core|claude|codex|opencode|ci|docs) return 0 ;; esac
  return 1
}

payload_has_word() { # <word> <space-separated-list>
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}

payload_relative_path() { # reject traversal and characters that cannot be recorded
  local LC_ALL=C
  case "/$1/" in *//*|*/./*|*/../*|*\\*) return 1 ;; esac
  [[ "$1" != *[[:cntrl:]]* ]]
}

payload_safe_path() { # <root> <relative-path>; also reject symlink components
  local rel="$2" part current="$1" rest
  payload_relative_path "$rel" || return 1
  printf '%s' "$rel" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || return 1
  rest="$rel"
  while :; do
    part=${rest%%/*}
    current="$current/$part"
    [ ! -L "$current" ] || return 1
    [ "$rest" = "$part" ] && break
    rest=${rest#*/}
  done
}

payload_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 < "$1" | cut -d ' ' -f 1
  fi
}

payload_scope_for_destination() { # <manifest> <destination> <active-scopes>
  local manifest="$1" wanted="$2" active="$3" src dst scope merge disposition
  local source_root=${1%/config/payload.tsv}
  while IFS=$'\t' read -r src dst scope merge disposition; do
    [ "$disposition" = export ] || continue
    payload_has_word "$scope" "$active" || continue
    if [ -d "$source_root/$src" ]; then
      case "$wanted" in "$dst"/*) return 0 ;; esac
    else
      [ "$wanted" = "$dst" ] && return 0
    fi
  done < "$manifest"
  return 1
}

# Read the old exclusion record first. A new record wins only when both agree. The
# source manifest is passed explicitly so upgrades validate before copying any file.
payload_resolve_installation() { # <target-root> <source-manifest> [requested-exclusions]
  local LC_ALL=C
  local root="$1" manifest="$2" requested="${3:-}" state="$1/.agentic-flow-installation"
  local legacy="$1/.agentic-flow-scopes-excluded" line key value number=0 version_seen=false
  local scopes="" files=0 path digest old_excluded="" scope all_scopes="" src dst merge disposition seen nul_line duplicate
  PAYLOAD_STATE_FILES=()
  PAYLOAD_STATE_DIGESTS=()
  PAYLOAD_STATE_LINES=()
  PAYLOAD_STATE_PRESENT=false
  while IFS=$'\t' read -r src dst scope merge disposition; do
    case "$src" in ''|\#*) continue ;; esac
    payload_valid_scope "$scope" || [ "$scope" = source-only ] \
      || payload_die "unknown manifest scope '$scope': $src"
    [ "$disposition" = export ] || continue
    payload_has_word "$scope" "$all_scopes" || all_scopes="${all_scopes}${all_scopes:+ }$scope"
  done < "$manifest"
  for scope in $requested; do
    if ! payload_valid_scope "$scope" || ! payload_has_word "$scope" "$all_scopes"; then
      payload_die "unknown requested exclusion scope: $scope"
    fi
  done
  if [ -f "$legacy" ]; then
    while IFS= read -r scope || [ -n "$scope" ]; do
      if ! payload_valid_scope "$scope" || ! payload_has_word "$scope" "$all_scopes"; then
        payload_die "invalid excluded scope in $legacy: $scope"
      fi
      payload_has_word "$scope" "$old_excluded" \
        && payload_die "duplicate excluded scope in $legacy: $scope"
      old_excluded="${old_excluded}${old_excluded:+ }$scope"
    done < "$legacy"
  fi
  if [ -f "$state" ]; then
    PAYLOAD_STATE_PRESENT=true
    nul_line=$(LC_ALL=C od -An -v -tu1 "$state" | awk '
      BEGIN { line=1 }
      { for (i=1; i<=NF; i++) { if ($i == 0 && !found) found=line; if ($i == 10) line++ } }
      END { if (found) print found }
    ')
    [ -z "$nul_line" ] || payload_die "$state line $nul_line: NUL byte"
    while IFS= read -r line || [ -n "$line" ]; do
      number=$((number + 1))
      [ "${#line}" -le 4096 ] || payload_die "$state line $number exceeds 4096 bytes"
      key=${line%%=*}; value=${line#*=}
      case "$key" in
        version)
          [ "$version_seen" = false ] && [ "$value" = 1 ] \
            || payload_die "$state line $number: invalid or duplicate version"
          version_seen=true ;;
        scope)
          if ! payload_valid_scope "$value" || ! payload_has_word "$value" "$all_scopes"; then
            payload_die "$state line $number: unknown scope '$value'"
          fi
          payload_has_word "$value" "$scopes" \
            && payload_die "$state line $number: duplicate scope '$value'"
          scopes="${scopes}${scopes:+ }$value" ;;
        file)
          files=$((files + 1))
          [ "$files" -le 2000 ] || payload_die "$state line $number: more than 2000 files"
          digest=${value%%  *}; path=${value#*'  '}
          [ "${#digest}" -eq 64 ] && [[ "$digest" =~ ^[0-9a-f]+$ ]] \
            && [ "$value" = "$digest  $path" ] \
            || payload_die "$state line $number: malformed file digest or separator"
          payload_safe_path "$root" "$path" \
            || payload_die "$state line $number: unsafe file path '$path'"
          PAYLOAD_STATE_FILES+=("$path"); PAYLOAD_STATE_DIGESTS+=("$digest")
          PAYLOAD_STATE_LINES+=("$number") ;;
        *) payload_die "$state line $number: unknown or malformed key '$key'" ;;
      esac
    done < "$state"
    [ "$version_seen" = true ] || payload_die "$state: missing version"
    duplicate=$(printf '%s\n' "${PAYLOAD_STATE_FILES[@]+"${PAYLOAD_STATE_FILES[@]}"}" \
      | LC_ALL=C sort | uniq -d)
    if [ -n "$duplicate" ]; then
      duplicate=${duplicate%%$'\n'*}
      seen=false
      files=0
      while [ "$files" -lt "${#PAYLOAD_STATE_FILES[@]}" ]; do
        if [ "${PAYLOAD_STATE_FILES[$files]}" = "$duplicate" ]; then
          if [ "$seen" = true ]; then
            payload_die "$state line ${PAYLOAD_STATE_LINES[$files]}: duplicate file path '$duplicate'"
          fi
          seen=true
        fi
        files=$((files + 1))
      done
    fi
    files=0
    while [ "$files" -lt "${#PAYLOAD_STATE_FILES[@]}" ]; do
      path=${PAYLOAD_STATE_FILES[$files]}
      payload_scope_for_destination "$manifest" "$path" "$scopes" \
        || payload_die "$state line ${PAYLOAD_STATE_LINES[$files]}: file outside recorded scopes: $path"
      files=$((files + 1))
    done
    for scope in $all_scopes; do
      if ! payload_has_word "$scope" "$scopes"; then
        payload_has_word "$scope" "$old_excluded" || [ ! -f "$legacy" ] \
          || payload_die "$state conflicts with $legacy: $scope"
      else
        ! payload_has_word "$scope" "$old_excluded" \
          || payload_die "$state conflicts with $legacy: $scope"
      fi
    done
  else
    for scope in $all_scopes; do
      payload_has_word "$scope" "$old_excluded" \
        || scopes="${scopes}${scopes:+ }$scope"
    done
    if [ ! -f "$legacy" ] && [ -f "$root/.agentic-flow-version" ]; then
      echo 'warning: installation scope state absent; using all manifest scopes' >&2
    fi
  fi
  if [ -n "$requested" ]; then
    for scope in $all_scopes; do
      if payload_has_word "$scope" "$requested"; then
        if [ "$PAYLOAD_STATE_PRESENT" = true ] || [ -f "$legacy" ]; then
          payload_has_word "$scope" "$scopes" \
            && payload_die "requested exclusions conflict with installed scopes: $scope"
        fi
      elif [ "$PAYLOAD_STATE_PRESENT" = true ] || [ -f "$legacy" ]; then
        payload_has_word "$scope" "$scopes" \
          || payload_die "requested scopes conflict with installed scopes: $scope"
      fi
    done
    if [ "$PAYLOAD_STATE_PRESENT" = false ] && [ ! -f "$legacy" ]; then
      scopes=""
      for scope in $all_scopes; do
        payload_has_word "$scope" "$requested" || scopes="${scopes}${scopes:+ }$scope"
      done
    fi
  fi
  for scope in core docs; do
    if payload_has_word "$scope" "$all_scopes" && ! payload_has_word "$scope" "$scopes"; then
      payload_die "required scope cannot be excluded: $scope"
    fi
  done
  PAYLOAD_ACTIVE_SCOPES="$scopes"
  PAYLOAD_EXCLUDED_SCOPES=""
  for scope in $all_scopes; do
    payload_has_word "$scope" "$scopes" \
      || PAYLOAD_EXCLUDED_SCOPES="${PAYLOAD_EXCLUDED_SCOPES}${PAYLOAD_EXCLUDED_SCOPES:+ }$scope"
  done
}

payload_write_installation() { # <target-root> <manifest>; after successful apply only
  local root="$1" manifest="$2" tmp path digest i=0 scope
  tmp=$(mktemp "$root/.agentic-flow-installation.XXXXXX")
  printf 'version=1\n' > "$tmp"
  for scope in core claude codex opencode ci docs; do
    payload_has_word "$scope" "$PAYLOAD_ACTIVE_SCOPES" && printf 'scope=%s\n' "$scope" >> "$tmp"
  done
  while [ "$i" -lt "${#DESTS[@]}" ]; do
    path=${DESTS[$i]}; i=$((i + 1))
    payload_is_excluded "${FILES[$((i - 1))]}" && continue
    payload_safe_path "$root" "$path" || payload_die "unsafe installed path: $path"
    [ -f "$root/$path" ] || payload_die "installed file missing: $path"
    digest=$(payload_sha256 "$root/$path")
    printf 'file=%s  %s\n' "$digest" "$path"
  done | LC_ALL=C sort -t ' ' -k3 >> "$tmp"
  mv "$tmp" "$root/.agentic-flow-installation"
  tmp=$(mktemp "$root/.agentic-flow-scopes-excluded.XXXXXX")
  for scope in $PAYLOAD_EXCLUDED_SCOPES; do printf '%s\n' "$scope"; done > "$tmp"
  mv "$tmp" "$root/.agentic-flow-scopes-excluded"
}

payload_scope_excluded() { # <scope>
  local s
  for s in $PAYLOAD_EXCLUDED_SCOPES; do
    [ "$s" = "$1" ] && return 0
  done
  return 1
}

payload_required_destinations() { # <manifest-path>; one path per active export row
  local source destination scope merge disposition
  while IFS="$(printf '\t')" read -r source destination scope merge disposition; do
    case "${source:-}" in ''|\#*) continue ;; esac
    [ "$disposition" = export ] || continue
    payload_has_word "$scope" "$PAYLOAD_ACTIVE_SCOPES" && printf '%s\n' "$destination"
  done < "$1" | LC_ALL=C sort -u
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
    case "${merge_policy:-}" in preserve|force|none) ;; *)
      payload_die "manifest entry has invalid merge policy '$merge_policy': $src_item" ;;
    esac
    payload_valid_scope "${scope:-}" || [ "$scope" = source-only ] \
      || payload_die "manifest entry has unknown scope '$scope': $src_item"
    case "${disposition:-}" in
      export)
        # An excluded scope is treated as source-only: kept out of the copy list AND out of
        # directory walks, so a parent entry cannot sweep it back in.
        if payload_scope_excluded "$scope"; then
          EXCLUDE_PATHS+=("$src_item")
        else
          ITEM_SRCS+=("$src_item")
          ITEM_DSTS+=("$dst_item")
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
  base=${rel##*/}
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
  local root="$1" i source destination scope _merge disposition
  local manifest="$root/config/payload.tsv"
  [ -f "$manifest" ] || return 0
  payload_resolve_installation "$root" "$manifest"
  if [ "$PAYLOAD_STATE_PRESENT" = true ]; then
    printf '%s\n' "${PAYLOAD_STATE_FILES[@]}"
  elif [ -f "$root/scripts/export.sh" ]; then
    payload_load_manifest "$manifest"
    payload_expand_files "$root"
    i=0
    while [ "$i" -lt "${#DESTS[@]}" ]; do
      payload_is_excluded "${FILES[$i]}" || printf '%s\n' "${DESTS[$i]}"
      i=$((i + 1))
    done
  else
    while IFS="$(printf '\t')" read -r source destination scope _merge disposition; do
      [ "$disposition" = export ] && payload_has_word "$scope" "$PAYLOAD_ACTIVE_SCOPES" \
        && [ -f "$root/$destination" ] && printf '%s\n' "$destination"
    done < "$manifest"
  fi
  return 0
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
  local src_root="$1" manifest_i src_item dst_item f rel suffix
  PAYLOAD_SRC_ROOT="$src_root"
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
  local LC_ALL=C
  local src_rel="$1" dst_rel="$2" i
  case "$dst_rel" in .agentic-flow-upstream|.agentic-flow-upstream/*)
    payload_die "upstream state cannot be a payload destination" ;;
  esac
  payload_safe_path "$PAYLOAD_SRC_ROOT" "$src_rel" \
    || payload_die "unsafe manifest source path: $src_rel"
  payload_safe_path "${PAYLOAD_DST_ROOT:-$PAYLOAD_SRC_ROOT}" "$dst_rel" \
    || payload_die "unsafe manifest destination path: $dst_rel"
  i=0
  while [ "$i" -lt "${#DESTS[@]}" ]; do
    [ "${DESTS[$i]}" = "$dst_rel" ] && return 0
    i=$((i + 1))
  done
  FILES+=("$src_rel")
  DESTS+=("$dst_rel")
  [ "${#DESTS[@]}" -le 2000 ] || payload_die "payload exceeds 2000 installed files"
  [ "$(( ${#dst_rel} + 72 ))" -le 4096 ] \
    || payload_die "installed path exceeds installation line bound: $dst_rel"
}

PAYLOAD_UPSTREAM_MODE=

payload_upstream_lookup() { # <destination>; return its array index (or the next free index)
  PAYLOAD_UPSTREAM_INDEX=0
  while [ "$PAYLOAD_UPSTREAM_INDEX" -lt "${#PAYLOAD_UPSTREAM_PATHS[@]}" ]; do
    [ "${PAYLOAD_UPSTREAM_PATHS[$PAYLOAD_UPSTREAM_INDEX]}" != "$1" ] || return 0
    PAYLOAD_UPSTREAM_INDEX=$((PAYLOAD_UPSTREAM_INDEX + 1))
  done
}

payload_upstream_load() { # <target-root> <upgrade|export|acknowledge>
  local LC_ALL=C
  local state="$1/.agentic-flow-upstream" line row=0 key value digest path index bytes nonnul_bytes
  local max_paths=2000 max_line=4100 max_rows
  max_rows=$((2 * max_paths))
  PAYLOAD_UPSTREAM_MODE="$2"
  PAYLOAD_UPSTREAM_PRESENT=false
  PAYLOAD_UPSTREAM_PATHS=()
  PAYLOAD_UPSTREAM_ACCEPTED=()
  PAYLOAD_UPSTREAM_OFFERED=()
  PAYLOAD_UPSTREAM_NEXT=()
  [ -e "$state" ] || [ -L "$state" ] || return 0
  [ -f "$state" ] && [ ! -L "$state" ] || payload_die "$state must be a regular file"
  # Two hashes per installed path. Allow for the longer accepted= and offered= keys.
  bytes=$(wc -c < "$state")
  [ "$bytes" -le "$((max_rows * (max_line + 1)))" ] || payload_die "$state exceeds the record size limit"
  nonnul_bytes=$(LC_ALL=C tr -d '\000' < "$state" | wc -c)
  [ "$bytes" -eq "$nonnul_bytes" ] || payload_die "$state contains a NUL byte"
  iconv -f UTF-8 -t UTF-8 "$state" >/dev/null 2>&1 || payload_die "$state is not UTF-8"
  PAYLOAD_UPSTREAM_PRESENT=true
  while IFS= read -r line || [ -n "$line" ]; do
    row=$((row + 1))
    [ "$row" -le "$max_rows" ] && [ "${#line}" -le "$max_line" ] || payload_die "$state line $row exceeds record limits"
    key=${line%%=*}; value=${line#*=}
    digest=${value%%  *}; path=${value#*'  '}
    [ "${#digest}" -eq 64 ] && [[ "$digest" =~ ^[0-9a-f]+$ ]] && [ "$value" = "$digest  $path" ] \
      || payload_die "$state line $row: malformed hash or separator"
    # An obsolete path may now be a symlink. Check record syntax here, before
    # active paths get their filesystem checks from the manifest or --merged.
    payload_relative_path "$path" || payload_die "$state line $row: unsafe path '$path'"
    payload_upstream_lookup "$path"
    index=$PAYLOAD_UPSTREAM_INDEX
    [ "$index" -lt "$max_paths" ] || payload_die "$state line $row: more than $max_paths paths"
    PAYLOAD_UPSTREAM_PATHS[index]="$path"
    case "$key" in
      accepted)
        [ -z "${PAYLOAD_UPSTREAM_ACCEPTED[$index]:-}" ] || payload_die "$state line $row: duplicate accepted hash for '$path'"
        PAYLOAD_UPSTREAM_ACCEPTED[index]="$digest" ;;
      offered)
        [ -z "${PAYLOAD_UPSTREAM_OFFERED[$index]:-}" ] || payload_die "$state line $row: duplicate offered hash for '$path'"
        PAYLOAD_UPSTREAM_OFFERED[index]="$digest" ;;
      *) payload_die "$state line $row: unknown record key" ;;
    esac
  done < "$state"
}

payload_upstream_append() { # <destination> <accepted> <offered>
  [ -z "$2" ] || PAYLOAD_UPSTREAM_NEXT+=("accepted=$2  $1")
  [ -z "$3" ] || PAYLOAD_UPSTREAM_NEXT+=("offered=$3  $1")
}

payload_upstream_write() { # <target-root>
  [ "${PAYLOAD_DRY:-false}" = false ] || return 0
  local state="$1/.agentic-flow-upstream" tmp
  tmp=$(mktemp "$state.XXXXXX")
  if ! { { [ "${#PAYLOAD_UPSTREAM_NEXT[@]}" -eq 0 ] || printf '%s\n' "${PAYLOAD_UPSTREAM_NEXT[@]}"; } > "$tmp" &&
    mv -f -- "$tmp" "$state"; }; then
    rm -f -- "$tmp"
    payload_die "could not write $state"
  fi
}

payload_find_candidates() { # <absolute destination>
  local file
  PAYLOAD_CANDIDATES=()
  for file in "$1".agentic-new*; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    PAYLOAD_CANDIDATES+=("$file")
    [ "${#PAYLOAD_CANDIDATES[@]}" -le 2000 ] || payload_die "too many merge candidates: $1"
  done
}

payload_acknowledge_merge() { # <target-root> <destination>
  local root="$1" path="$2" index i=0 candidate
  local PAYLOAD_DRY=false
  payload_safe_path "$root" "$path" || payload_die "unsafe --merged path: $path"
  payload_upstream_load "$root" acknowledge
  payload_find_candidates "$root/$path"
  [ "${#PAYLOAD_CANDIDATES[@]}" -gt 0 ] || payload_die "no candidate for '$path'"
  payload_upstream_lookup "$path"
  index=$PAYLOAD_UPSTREAM_INDEX
  [ -n "${PAYLOAD_UPSTREAM_OFFERED[$index]:-}" ] || payload_die "no recorded offer for '$path'; run upgrade first"
  PAYLOAD_UPSTREAM_ACCEPTED[index]="${PAYLOAD_UPSTREAM_OFFERED[$index]}"
  PAYLOAD_UPSTREAM_OFFERED[index]=""
  for candidate in "${PAYLOAD_CANDIDATES[@]}"; do
    rm -- "$candidate"
    printf '  removed    %s\n' "${candidate#"$root"/}"
  done
  while [ "$i" -lt "${#PAYLOAD_UPSTREAM_PATHS[@]}" ]; do
    payload_upstream_append "${PAYLOAD_UPSTREAM_PATHS[$i]}" "${PAYLOAD_UPSTREAM_ACCEPTED[$i]:-}" "${PAYLOAD_UPSTREAM_OFFERED[$i]:-}"
    i=$((i + 1))
  done
  payload_upstream_write "$root"
}

payload_candidate_matches() { # <source> <candidate>
  [ -f "$2" ] && [ ! -L "$2" ] && cmp -s "$1" "$2"
}

payload_apply_candidate() { # <src> <dst> <existing candidate paths...>
  local src="$1" dst="$2" candidate content_id existing
  shift 2
  for existing in "$@"; do
    if payload_candidate_matches "$src" "$existing"; then
      PAYLOAD_RESULT_CANDIDATE_ACTION=pending
      PAYLOAD_RESULT_PATH="$existing"
      return
    fi
  done
  candidate="$dst.agentic-new"
  if { [ -e "$candidate" ] || [ -L "$candidate" ]; } && ! payload_candidate_matches "$src" "$candidate"; then
    candidate="$dst.agentic-new.${PAYLOAD_VERSION:-unknown}"
  fi
  if { [ -e "$candidate" ] || [ -L "$candidate" ]; } && ! payload_candidate_matches "$src" "$candidate"; then
    content_id=$(git hash-object "$src" 2>/dev/null | cut -c1-12)
    [ -n "$content_id" ] || content_id=$(cksum "$src" | awk '{print $1}')
    candidate="$dst.agentic-new.${PAYLOAD_VERSION:-unknown}.$content_id"
  fi
  if [ -e "$candidate" ] || [ -L "$candidate" ]; then
    payload_candidate_matches "$src" "$candidate" \
      || payload_die "refusing to overwrite occupied merge candidate: ${candidate#"$PAYLOAD_DST_ROOT"/}"
    PAYLOAD_RESULT_CANDIDATE_ACTION=pending
  else
    [ "${PAYLOAD_DRY:-false}" = true ] || { mkdir -p "$(dirname "$candidate")"; cp -p "$src" "$candidate"; }
    PAYLOAD_RESULT_CANDIDATE_ACTION=candidate
  fi
  PAYLOAD_RESULT_PATH="$candidate"
}

payload_apply_entry() { # <src> <dst> <mode>
  local src="$1" dst="$2" mode="$3" path accepted='' offered='' upstream='' pending=false
  PAYLOAD_RESULT_PATH=""
  PAYLOAD_RESULT_CANDIDATE_ACTION=""
  PAYLOAD_RESULT_CLASSIFICATION=""
  case "$mode" in apply|dry-run|force) ;; *)
    payload_die "invalid payload apply mode: $mode" ;;
  esac
  [ ! -e "$dst" ] || [ -f "$dst" ] || payload_die "expected a file at $dst"

  PAYLOAD_CANDIDATES=()
  if [ -n "$PAYLOAD_UPSTREAM_MODE" ]; then
    path=${dst#"$PAYLOAD_DST_ROOT"/}
    payload_upstream_lookup "$path"
    accepted=${PAYLOAD_UPSTREAM_ACCEPTED[$PAYLOAD_UPSTREAM_INDEX]:-}
    offered=${PAYLOAD_UPSTREAM_OFFERED[$PAYLOAD_UPSTREAM_INDEX]:-}
    upstream=$(payload_sha256 "$src")
    payload_find_candidates "$dst"
    if [ "${#PAYLOAD_CANDIDATES[@]}" -gt 0 ]; then
      pending=true
    elif [ -n "$offered" ]; then
      accepted=$offered
      offered=''
    fi
  fi

  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    PAYLOAD_RESULT_CLASSIFICATION=same
  elif [ "$mode" != force ] && [ "$PAYLOAD_UPSTREAM_MODE" = upgrade ] &&
    [ "$PAYLOAD_UPSTREAM_PRESENT" = true ] && [ "$pending" = true ]; then
    payload_apply_candidate "$src" "$dst" "${PAYLOAD_CANDIDATES[@]}"
    PAYLOAD_RESULT_CLASSIFICATION=pending
  elif [ ! -e "$dst" ]; then
    [ "${PAYLOAD_DRY:-false}" = true ] || { mkdir -p "$(dirname "$dst")"; cp -p "$src" "$dst"; }
    PAYLOAD_RESULT_CLASSIFICATION=create
  elif [ "$mode" = force ]; then
    [ "${PAYLOAD_DRY:-false}" = true ] || cp -p "$src" "$dst"
    PAYLOAD_RESULT_CLASSIFICATION=overwrite
  elif [ "$PAYLOAD_UPSTREAM_MODE" = upgrade ] && [ "$upstream" = "$accepted" ]; then
    PAYLOAD_RESULT_CLASSIFICATION=kept
  elif [ "$PAYLOAD_UPSTREAM_MODE" = upgrade ] && [ -n "$accepted" ] &&
    [ "$(payload_sha256 "$dst")" = "$accepted" ]; then
    [ "${PAYLOAD_DRY:-false}" = true ] || cp -p "$src" "$dst"
    PAYLOAD_RESULT_CLASSIFICATION=overwrite
  else
    payload_apply_candidate "$src" "$dst"
    PAYLOAD_RESULT_CLASSIFICATION=$PAYLOAD_RESULT_CANDIDATE_ACTION
  fi

  if [ -n "$PAYLOAD_UPSTREAM_MODE" ]; then
    case "$PAYLOAD_RESULT_CLASSIFICATION" in
      same|create|overwrite) accepted=$upstream ;;
      candidate|pending) offered=$upstream ;;
    esac
    payload_upstream_append "$path" "$accepted" "$offered"
  fi
  printf '%s\n' "$PAYLOAD_RESULT_CLASSIFICATION"
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
