#!/usr/bin/env bash
# Template copied into the receipt after the recorded checkout and index assignments.
# shellcheck disable=SC2154 # The receipt supplies top, branch, commit, and index above this template.
set -euo pipefail
export GIT_OPTIONAL_LOCKS=0 GIT_NO_LAZY_FETCH=1
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX

undo_git() { git --literal-pathspecs -c core.fsmonitor=false "$@"; }

undo_check_checkout() {
  local current_branch status=0
  current_branch=$(undo_git symbolic-ref -q HEAD) || status=$?
  [ "$status" -le 1 ] && [ "$current_branch" = "$branch" ] &&
    [ "$(undo_git rev-parse --show-toplevel)" = "$top" ] &&
    [ "$(undo_git rev-parse --absolute-git-dir)" = "${index%/agentic-flow/*}" ] &&
    [ "$(undo_git rev-parse --verify -q 'HEAD^{commit}')" = "$commit" ]
}

undo_moved() {
  printf 'Undo refused: the recorded checkout, branch, or HEAD moved. Restore selected paths manually with git checkout %q -- <path>.\n' "$commit" >&2
  exit 3
}

undo_file_state() {
  local path=$1 expected_mode=$2 expected_blob=$3 parent=. rest=$1 part diff status=0
  worktree=changed
  while [[ "$rest" == */* ]]; do
    part=${rest%%/*}
    rest=${rest#*/}
    parent="$parent/$part"
    [ ! -L "$parent" ] || return 0
    if [ ! -e "$parent" ]; then worktree=missing; return 0; fi
    [ -d "$parent" ] && [ -x "$parent" ] || return 0
  done
  [ ! -L "./$path" ] || return 0
  if [ ! -e "./$path" ]; then worktree=missing; return 0; fi
  [ -f "./$path" ] || return 0
  [ "$(undo_git hash-object --no-filters --stdin < "./$path")" = "$expected_blob" ] || return 0
  if [ "$file_mode" = true ]; then
    # Git's raw no-index diff reports the Git mode, using the owner executable bit.
    diff=$(undo_git diff --no-index --raw --no-ext-diff --no-textconv -- /dev/null "./$path") || status=$?
    [ "$status" = 1 ] && [[ "$diff" == ":000000 $expected_mode "* ]] || return 0
  fi
  worktree=recorded
}

undo_index_entry() {
  local row entry=''
  while IFS= read -r -d '' row; do
    if [ -z "$row" ]; then printf '%s' "$entry"; return 0; fi
    if [ -n "$entry" ]; then printf 'multiple entries'; return 0; fi
    entry=$row
  done < <(undo_git ls-files -z --stage -- "$1" && printf '\0')
  return 1
}

undo_classify() {
  local i path entry current worktree
  local unsafe=0
  for ((i=0; i<${#paths[@]}; i++)); do
    path=${paths[i]} entry=${entries[i]}
    if ! current=$(undo_index_entry "$path"); then
      printf 'Undo could not read the index for %q.\n' "$path" >&2
      unsafe=1
      continue
    fi
    if [ -n "$current" ] && [ "$current" != "${entry%%$'\t'*} 0"$'\t'"$path" ]; then
      printf 'Undo found a changed index entry for %q.\n' "$path" >&2
      unsafe=1
      continue
    fi
    undo_file_state "$path" "${entry%% *}" "${entry#* }"
    if [ "$worktree" = changed ]; then
      printf 'Undo found different content or mode at %q. Inspect it before retrying.\n' "$path" >&2
      unsafe=1
      continue
    fi
    if [ "$1" = verify ]; then
      if [ -z "$current" ] || [ "$worktree" = missing ]; then
        local index_state=restored file_state=restored
        [ -n "$current" ] || index_state=missing
        [ "$worktree" != missing ] || file_state=missing
        printf 'Partial undo at %q (index %s, file %s).\n' "$path" "$index_state" "$file_state" >&2
        unsafe=1
      fi
      continue
    fi
    [ -n "$current" ] || index_missing+=("$entry"$'\t'"$path")
    [ "$worktree" != missing ] || files_missing+=("$path")
  done
  return "$unsafe"
}

cd -- "$top" || undo_moved
undo_check_checkout || undo_moved

file_mode='' config_status=0
file_mode=$(undo_git config --type=bool --get core.fileMode) || config_status=$?
if [ "$config_status" -gt 1 ]; then
  printf 'Undo refused: could not read core.fileMode.\n' >&2
  exit 3
fi
file_mode=${file_mode:-true}

paths=() entries=() index_missing=() files_missing=()
count=0 LC_ALL=C
entry_pattern='^(100644|100755) ([0-9a-f]{40}|[0-9a-f]{64})'$'\t''([^[:cntrl:]]+)$'
if [ ! -f "$index" ] || [ -L "$index" ]; then
  printf 'Undo refused: the receipt index is missing or unsafe.\n' >&2
  exit 3
fi
while IFS= read -r -d '' entry || [ -n "$entry" ]; do
  count=$((count + 1))
  if [ "$count" -gt 2000 ] || ! [[ "$entry" =~ $entry_pattern ]]; then
    printf 'Undo refused: invalid receipt index.\n' >&2
    exit 3
  fi
  path=${BASH_REMATCH[3]}
  case "/$path/" in
    *//*|*/./*|*/../*|*/.[gG][iI][tT]/*|*\\*)
      printf 'Undo refused: unsafe receipt path %q.\n' "$path" >&2
      exit 3 ;;
  esac
  paths+=("$path") entries+=("${entry%%$'\t'*}")
done < "$index"
if [ "$count" = 0 ]; then
  printf 'Undo refused: empty receipt index.\n' >&2
  exit 3
fi
if ! undo_classify prepare; then
  printf 'Undo refused. Review the listed paths before retrying.\n' >&2
  exit 3
fi
undo_check_checkout || undo_moved

updated=true
if [ "${#index_missing[@]}" -gt 0 ]; then
  printf '%s\0' "${index_missing[@]}" | undo_git update-index -z --index-info || updated=false
fi
if [ "$updated" = true ] && [ "${#files_missing[@]}" -gt 0 ]; then
  printf '%s\0' "${files_missing[@]}" | undo_git checkout-index --stdin -z || :
fi
if ! undo_classify verify || ! undo_check_checkout; then
  printf 'Partial undo. Fix the cause, then run this undo again. If HEAD moved, restore selected paths manually from %q.\n' "$commit" >&2
  exit 4
fi
printf 'Restored %s uninstall paths against %s.\n' "$count" "$commit"
