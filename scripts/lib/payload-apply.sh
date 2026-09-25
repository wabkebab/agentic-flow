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

payload_valid_scope() {
  case "$1" in core|claude|codex|opencode|ci|docs) return 0 ;; esac
  return 1
}

payload_has_word() { # <word> <space-separated-list>
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}

payload_safe_path() { # <root> <relative-path>; reject traversal and symlink components
  local root="$1" rel="$2" part current="$1" rest
  [ -n "$rel" ] || return 1
  case "$rel" in /*|*\\*|*'//'*) return 1 ;; esac
  LC_ALL=C printf '%s' "$rel" | grep -q '[[:cntrl:]]' && return 1
  printf '%s' "$rel" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || return 1
  rest="$rel"
  while :; do
    part=${rest%%/*}
    case "$part" in ''|.|..) return 1 ;; esac
    current="$current/$part"
    [ ! -L "$current" ] || return 1
    [ "$rest" = "$part" ] && break
    rest=${rest#*/}
  done
}

payload_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  else
    sha256sum "$1" | cut -d ' ' -f 1
  fi
}

payload_scope_for_destination() { # <manifest> <destination> <active-scopes>
  local manifest="$1" wanted="$2" active="$3" src dst scope merge disposition
  local source_root=${1%/config/payload.tsv}
  while IFS="$(printf '\t')" read -r src dst scope merge disposition; do
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
  while IFS="$(printf '\t')" read -r src dst scope merge disposition; do
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
