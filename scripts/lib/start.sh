#!/usr/bin/env bash
# Local plan worktree creation and post-merge cleanup.

plan_worktree_path() { # <absolute git-common-dir> <plan-id>
  local root=${AGENTIC_WORKTREE_ROOT:-$1/agentic-flow/worktrees}
  case "$root" in /*) ;; *) root="$PWD/$root" ;; esac
  printf '%s/%s\n' "${root%/}" "$2"
}

plan_error() { printf '%s: %s\n' "$action" "$*" >&2; }
plan_id_valid() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ && ${#1} -le 80 ]]; }
plan_branch_valid() { [[ "$1" != -* ]] && git check-ref-format "refs/heads/$1"; }
plan_path_exists() { [ -e "$1" ] || [ -L "$1" ]; }

plan_fetch() {
  local timeout=${AGENTIC_FLOW_FETCH_TIMEOUT:-120}
  if ! [[ "$timeout" =~ ^[0-9]*[1-9][0-9]*$ && ${#timeout} -le 9 ]]; then
    plan_error 'AGENTIC_FLOW_FETCH_TIMEOUT must be a positive integer in seconds'
    return 2
  fi
  run_with_timeout "$timeout" "$@" || { plan_error "remote lookup or fetch failed for origin/$base"; return 5; }
}

plan_doc_paths() { # conventional launch and close-out paths, in either project layout
  printf '%s\n' "docs/inprogress/feature-$1.md" "docs/inprogress/security-$1.md" \
    "docs/done/feature-$1.md" "docs/done/security-$1.md" "docs/done/security/security-$1.md"
}

plan_fill_template() {
  local today
  today=$(date +%F) || return 1
  awk -v id="$id" -v branch="$branch" -v base="$base" -v today="$today" '
    /^<!-- TRIAGE \(first pass · YYYY-MM-DD\) -->$/ {
      $0="<!-- TRIAGE (first pass · " today ") -->"; dates++
    }
    /^##? / {section=($0=="## Branch")}
    section && /^Base: `<base branch>`\./ {
      $0="Base: `" base "`." substr($0,length("Base: `<base branch>`.")+1); bases++
    }
    /^```agentic-flow-plan$/ {block=1; blocks++}
    /^```$/ {
      if (block && !formats) print "format: 2"
      block=0
    }
    block && /^format:/ {formats++; if ($0!="format: 2") invalid_format=1}
    block && $0=="id: <stable-plan-id>" {$0="id: " id; ids++}
    block && $0=="branch: <branch>" {$0="branch: " branch; branches++}
    {print}
    END {if (dates!=1 || bases!=1 || blocks!=1 || block || ids!=1 || branches!=1 || formats>1 || invalid_format) exit 1}
  ' "$1"
}

plan_record() { # status, branch, base. Publish atomically for interrupted-clean recovery.
  local temporary
  if plan_path_exists "$record" && { [ ! -f "$record" ] || [ -L "$record" ]; }; then return 1; fi
  mkdir -p -- "${record%/*}" || return 1
  temporary=$(mktemp "$record.XXXXXX") || return 1
  if ! (printf '%s\t%s\t%s\n' "$1" "$branch" "$base" > "$temporary" &&
        mv -f -- "$temporary" "$record"); then
    rm -f -- "$temporary"
    return 1
  fi
}

plan_worktree_lock() {
  local path="$common/agentic-flow/worktree-locks/$id" interrupted=false
  mkdir -p -- "${path%/*}" || { plan_error "cannot create worktree lock parent: ${path%/*}"; return 3; }
  # Defer interrupts until the EXIT trap knows whether mkdir acquired the lock.
  trap 'interrupted=true' INT TERM
  if (trap '' INT TERM; exec mkdir -- "$path") 2>/dev/null; then lock=$path; fi
  trap 'exit 3' INT TERM
  [ "$interrupted" = false ] || return 3
  if [ -z "$lock" ]; then
    plan_error "cannot acquire worktree lock: $path"
    plan_error "If the lock exists, confirm no agentic-flow start or clean for $id is running."
    plan_error 'Check the PID in owner with ps -p <pid> when present and list processes for agentic-flow start or clean on any host sharing the repository.'
    plan_error "Then remove $path/owner if present and rmdir $path."
    return 3
  fi
  printf '%s\n' "$$" > "$lock/owner" || { plan_error "cannot record worktree lock owner: $lock"; return 3; }
}

plan_worktree_cleanup() {
  trap '' INT TERM
  if [ "$action" = start ]; then plan_start_rollback; fi
  if [ -n "$scratch" ]; then rm -rf -- "$scratch"; fi
  if [ -n "$lock" ] && ! { rm -f -- "$lock/owner" && rmdir -- "$lock"; }; then
    plan_error "could not release worktree lock: $lock"
  fi
}

plan_start_rollback() {
  if [ "$made_worktree" = true ]; then
    # The directory was reserved with mkdir, so it belongs to this invocation.
    if ! git worktree remove --force --force -- "$worktree" 2>/dev/null; then
      rm -rf -- "$worktree" || plan_error "could not roll back worktree $worktree"
    fi
  fi
  if [ "$made_branch" = true ]; then
    git update-ref -d "$branch_ref" "$tip" --no-deref || plan_error "could not roll back $branch_ref"
  fi
}

plan_start() {
  local remote_branch="refs/remotes/origin/$branch"
  local base_ref="refs/heads/$base" remote_base="refs/remotes/origin/$base"
  local listing path paths template doc interrupted=false
  branch_ref="refs/heads/$branch"
  plan_branch_valid "$branch" || { plan_error "invalid branch name $branch"; return 3; }
  plan_branch_valid "$base" || { plan_error "invalid base name $base"; return 3; }
  if git show-ref --verify --quiet "$branch_ref" ||
     { [ "$fetch" = false ] && git show-ref --verify --quiet "$remote_branch"; }; then
    plan_error "branch already exists locally or on origin: $branch"; return 3
  fi
  if plan_path_exists "$worktree"; then plan_error "worktree path already exists: $worktree"; return 3; fi
  if plan_path_exists "$record"; then
    local status recorded_branch recorded_base
    plan_read_record || { plan_error "invalid worktree record for $id"; return 3; }
    if [ "$status" = pending ] ||
       { [ "$status" = open ] && git show-ref --verify --quiet "refs/heads/$recorded_branch"; }; then
      plan_error "plan already exists: $id"; return 3
    fi
  fi
  paths=$(plan_doc_paths "$id") || return 3
  while IFS= read -r path; do
    if plan_path_exists "$path"; then plan_error "plan doc already exists: $path"; return 3; fi
  done <<< "$paths"

  if [ "$fetch" = true ]; then
    listing=$(plan_fetch git ls-remote --refs origin "$base_ref" "$branch_ref") || return $?
    if printf '%s\n' "$listing" | cut -f2 | grep -Fxq "$branch_ref"; then
      plan_error "branch already exists on origin: $branch"; return 3
    fi
    if ! printf '%s\n' "$listing" | cut -f2 | grep -Fxq "$base_ref"; then
      plan_error "unknown base: origin/$base"; return 3
    fi
    plan_fetch git fetch --quiet --no-tags --no-recurse-submodules origin "+$base_ref:$remote_base" || return $?
  fi
  if ! tip=$(git rev-parse --verify --quiet "$remote_base^{commit}"); then
    if [ "$fetch" = true ] || ! tip=$(git rev-parse --verify --quiet "$base_ref^{commit}"); then
      plan_error "unknown base: $base"; return 3
    fi
  fi
  while IFS= read -r path; do
    if git cat-file -e "$tip:$path" 2>/dev/null; then plan_error "plan doc already exists on $base: $path"; return 3; fi
  done <<< "$paths"

  # Record ownership before interrupt handling can roll back either creation.
  trap 'interrupted=true' INT TERM
  if ! (trap '' INT TERM; exec git update-ref "$branch_ref" "$tip" ""); then
    plan_error "could not create $branch_ref"; return 3
  fi
  made_branch=true
  [ "$interrupted" = false ] || return 3
  if ! mkdir -p -- "${worktree%/*}" || ! (trap '' INT TERM; exec mkdir -- "$worktree"); then
    plan_error "could not reserve worktree directory: $worktree"; return 3
  fi
  made_worktree=true
  trap 'exit 3' INT TERM
  [ "$interrupted" = false ] || return 3
  if ! git worktree add --quiet -- "$worktree" "$branch"; then
    plan_error "could not add worktree: $worktree"; return 3
  fi
  case "$type" in
    feature) template=docs/templates/feature-analysis.md ;;
    security) template=docs/templates/security-review.md ;;
  esac
  doc=docs/inprogress/$type-$id.md
  if ! (
    cd "$worktree" &&
    [ -d docs ] && [ ! -L docs ] &&
    [ -d docs/templates ] && [ ! -L docs/templates ] &&
    [ -d docs/inprogress ] && [ ! -L docs/inprogress ] &&
    [ -f "$template" ] && [ ! -L "$template" ] &&
    [ -f docs/README.md ] && [ ! -L docs/README.md ] &&
    (set -o noclobber; plan_fill_template "$template" > "$doc") &&
    AGENTIC_PROJECT_ROOT="$worktree" "$cli_dir/docs-index.sh" >/dev/null &&
    git add -- "$doc" docs/README.md
  ); then
    plan_error "could not write and stage $doc from $template"; return 3
  fi
  # Once the record is published, its branch and worktree belong to the plan.
  trap 'interrupted=true' INT TERM
  (trap '' INT TERM; plan_record open) || { plan_error 'could not record the plan worktree'; return 3; }
  made_branch=false made_worktree=false
  trap 'exit 3' INT TERM
  [ "$interrupted" = false ] || return 3
  printf 'Worktree: %s\nDoc: %s\nNext:\n  cd %q\n  vi %q\n' "$worktree" "$doc" "$worktree" "$doc"
}

plan_clean_doc() { # <tip> <branch> <plan-id> -> base; 1 absent, 2 invalid or ambiguous
  local paths path found='' fields
  paths=$(plan_doc_paths "$3") || return 2
  while IFS= read -r path; do
    git cat-file -e "$1:$path" 2>/dev/null || continue
    [ -z "$found" ] || return 2
    found=$path
  done <<< "$paths"
  [ -n "$found" ] || return 1
  fields=$(git cat-file -s "$1:$found") && [ "$fields" -le 1048576 ] || return 2
  git cat-file blob "$1:$found" | awk -v id="$3" -v branch="$2" '
    /^```agentic-flow-plan$/ {block=1; blocks++; next}
    /^```$/ {block=0}
    block && /^id: / {doc_id=substr($0,5); ids++}
    block && /^branch: / {doc_branch=substr($0,9); branches++}
    block && /^base: / {base=substr($0,7); bases++}
    /^##? / {section=($0=="## Branch")}
    section && /^Base: / {
      branch_bases++
      if (match($0, /^Base: `[^[:space:]]+`(\.[[:space:]]|[[:space:]]|\.$|$)/)) {
        doc_base=substr($0,8,RLENGTH-8); sub(/`\.?[[:space:]]?$/, "", doc_base)
      }
    }
    END {
      if (blocks!=1 || block || ids!=1 || doc_id!=id || branches!=1 || doc_branch!=branch ||
          bases>1 || branch_bases>1 || (branch_bases && doc_base=="") ||
          (base!="" && doc_base!="" && base!=doc_base)) exit 2
      print (base!="" ? base : (doc_base!="" ? doc_base : "main"))
    }
  '
}

plan_find_branch() { # Scan bounded local refs when the worktree and record are both absent.
  local refs candidate sha candidate_base
  refs=$(git for-each-ref --count=1001 --format='%(objectname) %(refname:lstrip=2)' refs/heads/) || return 1
  [ "$(printf '%s\n' "$refs" | wc -l)" -le 1000 ] || { plan_error 'too many local branches to identify the plan'; return 1; }
  while read -r sha candidate; do
    [ -n "$candidate" ] || continue
    candidate_base=$(plan_clean_doc "$sha" "$candidate" "$id") || continue
    [ -z "$branch" ] || { plan_error "multiple local branches match plan $id"; return 1; }
    branch=$candidate base=$candidate_base tip=$sha
  done <<< "$refs"
  [ -n "$branch" ]
}

plan_clean_dry_base() {
  local object_dir format url
  object_dir=$(git rev-parse --path-format=absolute --git-path objects) || return 3
  format=$(git rev-parse --show-object-format) || return 3
  url=$(git remote get-url origin) || { plan_error 'cannot locate origin'; return 5; }
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/agentic-clean.XXXXXX") || return 3
  git -c init.templateDir= init --quiet --bare --object-format="$format" "$scratch" || return 3
  printf '%s\n' "$object_dir" > "$scratch/objects/info/alternates" || return 3
  # Keep the fetched objects, refs, and FETCH_HEAD out of the caller's repo.
  plan_fetch env GIT_DIR="$scratch" git fetch --quiet --no-tags --no-recurse-submodules -- "$url" \
    "+refs/heads/$base:refs/remotes/origin/$base"
}

plan_read_record() {
  local extra=''
  [ -f "$record" ] && [ ! -L "$record" ] &&
    [ "$(wc -c < "$record")" -le 4096 ] &&
    IFS=$'\t' read -r status recorded_branch recorded_base extra < "$record" &&
    [[ "$status" =~ ^(open|pending|closed)$ ]] && [ -z "$extra" ] &&
    plan_branch_valid "$recorded_branch" && plan_branch_valid "$recorded_base"
}

plan_salvage_refs() { # git ref output format
  local refs
  refs=$(git for-each-ref --count=1001 --format="$1" "$salvage") || return 3
  [ "$(printf '%s\n' "$refs" | wc -l)" -le 1000 ] || { plan_error "too many salvage refs under $salvage"; return 3; }
  printf '%s' "$refs"
}

plan_require_missing_branch() {
  local rc=0
  git show-ref --exists "$branch_ref" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && return 0
  plan_error "cannot resolve branch $branch"
  if [ "$rc" = 129 ]; then plan_error 'Git 2.43 or newer is required to recover this record'; fi
  return 3
}

plan_check_other_worktrees() {
  local listing
  listing=$(git worktree list --porcelain) || return 3
  if grep -Fxq "branch $branch_ref" <<< "$listing"; then
    plan_error "$branch is checked out in another worktree"; return 3
  fi
}

plan_recover_open_record() {
  local refs message='Would mark record closed'
  plan_require_missing_branch || return 3
  refs=$(plan_salvage_refs '%(refname)') || return 3
  if ! plan_read_record || [ "$status" != open ] || [ "$recorded_branch" != "$branch" ] ||
     [ "$recorded_base" != "$base" ] || plan_path_exists "$worktree"; then
    plan_error "worktree or record changed during recovery for $id"; return 3
  fi
  plan_check_other_worktrees && plan_require_missing_branch || return 3
  if [ "$dry_run" = false ]; then
    # The salvage refs may be the only pointers to unshipped work.
    plan_record closed || { plan_error 'could not record completed cleanup'; return 3; }
    message='Marked record closed'
  fi
  printf '%s; salvage refs preserved: %s\n' "$message" "${refs:-none}"
}

plan_clean() {
  local status='' recorded_branch='' recorded_base='' tip='' doc_base rc
  local worktree_present=false top wt_common dirty branch_ref base_ref base_tip refs listing
  local salvage="refs/agentic-flow/salvage/$id/"
  if plan_path_exists "$record" && ! plan_read_record; then
    plan_error "invalid worktree record for $id"; return 3
  fi
  if plan_path_exists "$worktree"; then
    if [ -L "$worktree" ] || ! top=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null) ||
       [ "$top" != "$(cd "$worktree" && pwd -P)" ] ||
       ! wt_common=$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir) ||
       [ "$(cd "$wt_common" && pwd -P)" != "$common" ]; then
      plan_error "path is not this repository's plan worktree: $worktree"; return 3
    fi
    local cwd
    cwd=$(pwd -P) || return 3
    if [ "$cwd" = "$top" ]; then plan_error "run from another checkout to remove $worktree"; return 3; fi
    branch=$(git -C "$worktree" symbolic-ref --quiet HEAD) || { plan_error "detached plan worktree: $worktree"; return 3; }
    case "$branch" in refs/heads/*) branch=${branch#refs/heads/} ;; *) return 3 ;; esac
    if [ -n "$recorded_branch" ] && [ "$status" != closed ] && [ "$branch" != "$recorded_branch" ]; then
      plan_error "branch checked out at $worktree differs from $recorded_branch"; return 3
    fi
    dirty=$(GIT_OPTIONAL_LOCKS=0 git -C "$worktree" status --porcelain --untracked-files=all --ignore-submodules=none) || return 3
    [ -z "$dirty" ] || { plan_error "worktree is dirty: $worktree"; return 3; }
    worktree_present=true
  elif [ "$status" = closed ]; then
    printf 'Nothing to remove for %s.\n' "$id"; return 0
  elif [ -n "$recorded_branch" ]; then
    branch=$recorded_branch
  else
    plan_find_branch || { plan_error "unknown plan: $id"; return 3; }
  fi

  branch_ref="refs/heads/$branch"
  if [ -z "$tip" ]; then tip=$(git rev-parse --verify --quiet "$branch_ref^{commit}") || tip=''; fi
  if [ -n "$tip" ]; then
    if doc_base=$(plan_clean_doc "$tip" "$branch" "$id"); then
      base=$doc_base
    else
      rc=$?
      if [ "$rc" != 1 ]; then plan_error "invalid or ambiguous plan doc on $branch"; return 3; fi
      base=${recorded_base:-main}
    fi
    plan_branch_valid "$base" || { plan_error "invalid base name $base"; return 3; }
    if [ "$branch" = "$base" ]; then plan_error "refusing to remove base branch $base"; return 3; fi
    base_ref="refs/remotes/origin/$base"
    if [ "$fetch" = true ]; then
      if [ "$dry_run" = true ]; then
        plan_clean_dry_base || return $?
      else
        plan_fetch git fetch --quiet --no-tags --no-recurse-submodules origin "+refs/heads/$base:$base_ref" || return $?
      fi
    fi
    local -a base_git
    base_git=(git)
    if [ -n "$scratch" ]; then base_git=(git --git-dir="$scratch"); fi
    base_tip=$("${base_git[@]}" rev-parse --verify --quiet "$base_ref^{commit}") || { plan_error "unknown base: $base_ref"; return 3; }
    if ! "${base_git[@]}" merge-base --is-ancestor "$tip" "$base_tip"; then
      plan_error "$branch is not an ancestor of origin/$base. Squash merges do not preserve branch ancestry."
      return 3
    fi
    if [ "$worktree_present" = false ]; then
      plan_check_other_worktrees || return 3
    fi
  elif [ "$status" = open ] && [ "$worktree_present" = false ]; then
    base=$recorded_base
    plan_recover_open_record
    return $?
  elif [ "$status" != pending ] || [ "$worktree_present" = true ]; then
    plan_error "cannot resolve branch $branch"; return 3
  else
    base=$recorded_base
  fi

  refs=$(plan_salvage_refs '%(refname) %(objectname)') || return 3
  if [ "$dry_run" = true ]; then
    if [ "$worktree_present" = true ]; then printf 'Would remove worktree %s\n' "$worktree"; fi
    if [ -n "$tip" ]; then printf 'Would delete %s\n' "$branch_ref"; fi
    if [ -n "$refs" ]; then printf '%s\n' "$refs" | awk '{print "Would delete " $1}'; fi
    return 0
  fi

  plan_record pending || { plan_error 'could not record pending cleanup'; return 3; }
  if [ "$worktree_present" = true ]; then
    git worktree remove -- "$worktree" || { plan_error "could not remove $worktree; branch and salvage refs kept"; return 3; }
    printf 'Removed worktree %s\n' "$worktree"
  fi
  if [ -n "$tip" ]; then
    listing=$(git worktree list --porcelain) || return 3
    if grep -Fxq "branch $branch_ref" <<< "$listing" ||
       ! git update-ref -d "$branch_ref" "$tip" --no-deref; then
      plan_error "could not delete $branch_ref; branch and salvage refs kept"; return 3
    fi
    printf 'Deleted %s\n' "$branch_ref"
  fi
  if [ -n "$refs" ]; then
    if ! printf '%s\n' "$refs" | awk '{print "option no-deref\ndelete " $0}' | git update-ref --stdin; then
      plan_error "could not delete salvage refs under $salvage"; return 3
    fi
    printf 'Deleted salvage refs under %s\n' "$salvage"
  fi
  plan_record closed || { plan_error 'could not record completed cleanup'; return 3; }
}

plan_worktree_cmd() {
  local action=$1 id type=feature base=main branch='' fetch=true dry_run=false root common worktree record cli_dir
  local lock='' scratch='' tip='' branch_ref='' made_branch=false made_worktree=false result=0
  shift
  if [ "$#" -eq 0 ]; then usage; return 2; fi
  case "$1" in -h|--help) usage; return 0 ;; --*) usage; return 2 ;; esac
  id=$1; shift
  [ "$action" != start ] || branch=$id
  plan_id_valid "$id" || { plan_error "invalid plan id: $id"; return 3; }
  while [ "$#" -gt 0 ]; do
    case "$action:$1" in
      *:--no-fetch) fetch=false; shift ;;
      clean:--dry-run) dry_run=true; shift ;;
      start:--type|start:--base|start:--branch)
        [ "$#" -ge 2 ] && [[ "$2" != --* ]] || { usage; return 2; }
        case "$1" in --type) type=$2 ;; --base) base=$2 ;; --branch) branch=$2 ;; esac
        shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  case "$type" in feature|security) ;; *) plan_error "unknown plan type: $type"; return 2 ;; esac
  cli_dir=$(cd "$(dirname "$0")" && pwd -P) || return 3
  root=$(git rev-parse --show-toplevel) && cd "$root" || return 3
  common=$(git rev-parse --path-format=absolute --git-common-dir) && common=$(cd "$common" && pwd -P) || return 3
  worktree=$(plan_worktree_path "$common" "$id")
  record="$common/agentic-flow/plans/$id"
  trap plan_worktree_cleanup EXIT
  trap 'exit 3' INT TERM
  if [ "$dry_run" = false ]; then plan_worktree_lock || exit 3; fi
  if [ "$action" = start ]; then
    plan_start || result=$?
  else
    plan_clean || result=$?
  fi
  exit "$result"
}
