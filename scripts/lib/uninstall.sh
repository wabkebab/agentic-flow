#!/usr/bin/env bash
# Read-only uninstall planning. The report data is streamed as NUL-delimited fields.
# shellcheck source=scripts/lib/payload-apply.sh
. "$(dirname "${BASH_SOURCE[0]}")/payload-apply.sh"
# shellcheck source=scripts/lib/start.sh
. "$(dirname "${BASH_SOURCE[0]}")/start.sh"
UNINSTALL_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

uninstall_git() {
  git -C "$uninstall_top" -c core.fsmonitor=false "$@"
}

uninstall_quote() { printf '%q' "$1"; }
uninstall_refuse() { printf '%s\0' refusal "$1" "$2" "${3:-}"; }
uninstall_keep() { printf '%s\0' kept "$1" "$2" "${3:-}"; }

uninstall_check_plans() {
  local records id status branch plan_dir field path='' branch_ref='' worktree_count=0 command detail
  if ! records=$(plan_uninstall_records "$uninstall_common"); then
    uninstall_refuse plan-open "$uninstall_common/agentic-flow/plans (invalid or unreadable plan records)" \
      'git worktree list'
  fi
  if [ -n "$records" ]; then
    while IFS=$'\t' read -r id status branch; do
      [ "$status" = closed ] || uninstall_refuse plan-open "$id" "agentic-flow clean $id"
    done <<< "$records"
  fi
  while IFS= read -r -d '' field; do
    case "$field" in
      'worktree '*) path=${field#worktree } ;;
      'branch '*) branch_ref=${field#branch } ;;
      '')
        [ -n "$path" ] || continue
        worktree_count=$((worktree_count + 1))
        if [ "$worktree_count" -gt 2000 ]; then
          uninstall_refuse plan-open 'too many Git worktrees to inspect' 'git worktree list'
          return
        fi
        if [ "$worktree_count" -gt 1 ] && [ "$path" != "$uninstall_top" ]; then
          command="git worktree remove -- $(uninstall_quote "$path")"
          detail=$path
          if [ -n "$records" ]; then
            while IFS=$'\t' read -r id status branch; do
              plan_dir=$(plan_worktree_path "$uninstall_common" "$id")
              if [ "$plan_dir" = "$path" ] || [ "refs/heads/$branch" = "$branch_ref" ]; then
                # The open record is already listed with its clean command.
                detail=''
                if [ "$status" = closed ]; then
                  detail=$path
                  command="agentic-flow clean $id"
                fi
                break
              fi
            done <<< "$records"
          fi
          if [ -n "$detail" ]; then
            plan_dir=$(plan_worktree_path "$uninstall_common" "${path##*/}")
            if [ "$path" = "$plan_dir" ] && plan_id_valid "${path##*/}"; then
              command="agentic-flow clean ${path##*/}"
            fi
            uninstall_refuse plan-open "$detail" "$command"
          fi
        fi
        path='' branch_ref='' ;;
      end) return 0 ;;
      'HEAD '*|bare|detached|locked*|prunable*) ;;
      *) uninstall_refuse git-read-failed 'unexpected worktree list entry' 'git worktree list' ;;
    esac
  done < <(uninstall_git worktree list --porcelain -z && printf 'end\0')
  # Git's porcelain ends each worktree with a blank record. The sentinel also
  # distinguishes a failed Git read from a complete or empty stream.
  uninstall_refuse git-read-failed 'could not read Git worktrees' 'git worktree list'
}

uninstall_check_locks() (
  local dir path count=0
  shopt -s nullglob dotglob
  if [ -L "$uninstall_common/agentic-flow" ]; then
    uninstall_refuse lock-present "$uninstall_common/agentic-flow (symlink)" \
      "ls -ld -- $(uninstall_quote "$uninstall_common/agentic-flow")"
    return
  fi
  for dir in "$uninstall_common/agentic-flow/"{locks,worktree-locks}; do
    if [ -L "$dir" ] || { [ -e "$dir" ] && { [ ! -d "$dir" ] || [ ! -r "$dir" ] || [ ! -x "$dir" ]; }; }; then
      uninstall_refuse lock-present "$dir (invalid lock directory)" "ls -ld -- $(uninstall_quote "$dir")"
      continue
    fi
    for path in "$dir"/*; do
      count=$((count + 1))
      if [ "$count" -gt 2000 ]; then
        uninstall_refuse lock-present "additional entries under $dir" "ls -la -- $(uninstall_quote "$dir")"
        break
      fi
      uninstall_refuse lock-present "$path" "ls -ld -- $(uninstall_quote "$path")"
    done
  done
)

uninstall_git_report() {
  local hooks ref refs status=0 command='git config --local --unset core.hooksPath'
  hooks=$(uninstall_git config --local --get-all core.hooksPath) || status=$?
  [ "$status" -le 1 ] || return "$status"
  if [[ $'\n'"$hooks"$'\n' == *$'\nscripts/git-hooks\n'* ]]; then
    if [ "$hooks" != scripts/git-hooks ]; then
      command='git config --local --fixed-value --unset-all core.hooksPath scripts/git-hooks'
    fi
    printf '%s\0' git core.hooksPath scripts/git-hooks "$command"
  fi
  refs=$(uninstall_git for-each-ref --count=2001 --format='%(refname)' refs/agentic-flow/salvage/)
  if [ -n "$refs" ]; then
    while IFS= read -r ref; do
      printf '%s\0' git salvage-ref "$ref" "git update-ref -d $(uninstall_quote "$ref")"
    done <<< "$refs"
    if [ "$(printf '%s\n' "$refs" | wc -l)" -gt 2000 ]; then
      uninstall_refuse git-read-failed 'additional salvage refs' 'git for-each-ref refs/agentic-flow/salvage/'
    fi
  fi
}

uninstall_staged_change() {
  uninstall_keep "$1" uncommitted-change
  uninstall_refuse uncommitted-install "$1" "git status -- $(uninstall_quote "$1")"
}

uninstall_git_entry() { # <literal path> <ls-files|ls-tree> [args...]
  local path=$1
  shift
  # A literal directory pathspec can still match descendants.
  uninstall_git --literal-pathspecs "$@" -- "$path" |
    perl -0ne 'BEGIN { $path = shift @ARGV } if (/\A([^\t]*)\t\Q$path\E\0\z/) { print "$1\n" }' -- "$path"
}

uninstall_classify() { # <path> <kind> [expected sha256] [why]
  local path=$1 kind=$2 expected=${3:-} why=${4:-created} file="$uninstall_root/$1"
  local digest index_entry head_entry index_mode head_mode index_hash head_hash blob worktree_mode
  if [[ "/$path/" == *'/.'[gG][iI][tT]'/'* ]] || ! payload_safe_path "$uninstall_root" "$path"; then
    uninstall_keep "$path" unsafe-path
    return
  fi
  index_entry=$(uninstall_git_entry "$path" ls-files -z --stage)
  [ -e "$file" ] || [ -n "$index_entry" ] || return 0
  if [ "$kind" = project ] && [ "$remove_project_state" = false ]; then
    uninstall_keep "$path" project-state-kept
    return
  fi
  if [ "$kind" = payload ] && [ "$keep_docs" = true ]; then
    case "$path" in docs/*|METHODOLOGY.md|ADOPTION.md) uninstall_keep "$path" keep-docs; return ;; esac
  fi
  case "$why" in
    created|claimed) ;;
    *) uninstall_keep "$path" "$why"; return ;;
  esac
  if [ ! -f "$file" ]; then
    uninstall_keep "$path" edited
    return
  fi
  digest=$(payload_sha256 "$file")
  if [ -n "$expected" ] && [ "$digest" != "$expected" ]; then
    if [ "$kind" = candidate ]; then
      uninstall_keep "$path" edited-candidate
    else
      uninstall_keep "$path" edited
    fi
    return
  fi
  head_entry=''
  if [ -n "$uninstall_head" ]; then
    head_entry=$(uninstall_git_entry "$path" ls-tree -z "$uninstall_head")
  fi
  if [ -z "$index_entry" ]; then
    if [ -n "$head_entry" ] && [[ "$head_entry" == 100* ]]; then
      uninstall_staged_change "$path"
    else
      uninstall_keep "$path" untracked "rm -- $(uninstall_quote "$path")"
    fi
    return
  fi
  if ! [[ "$index_entry" =~ ^(100644|100755)\ ([0-9a-f]+)\ 0$ ]]; then
    uninstall_staged_change "$path"
    return
  fi
  index_mode=${BASH_REMATCH[1]} index_hash=${BASH_REMATCH[2]}
  if ! [[ "$head_entry" =~ ^(100644|100755)\ blob\ ([0-9a-f]+)$ ]]; then
    uninstall_staged_change "$path"
    return
  fi
  head_mode=${BASH_REMATCH[1]} head_hash=${BASH_REMATCH[2]}
  blob=$(uninstall_git hash-object --no-filters --stdin < "$file")
  if [ "$blob" != "$index_hash" ] || [ "$blob" != "$head_hash" ]; then
    if [ "$kind" = payload ] || [ "$kind" = candidate ]; then
      uninstall_staged_change "$path"
    else
      uninstall_keep "$path" edited
    fi
    return
  fi
  worktree_mode=$index_mode
  if [ "$uninstall_file_mode" = true ]; then
    worktree_mode=$(perl -e 'my @s = lstat $ARGV[0]; die "could not stat file\n" unless @s; print ($s[2] & 0100 ? "100755" : "100644")' "$file")
  fi
  if [ "$index_mode" != "$head_mode" ] || [ "$worktree_mode" != "$index_mode" ]; then
    uninstall_keep "$path" mode-changed
    return
  fi
  printf '%s\0' remove "$path" "$kind" "$why" "$digest" "$head_mode"
}

uninstall_adoption() {
  local commits shallow
  [ "$claim_adoption" = true ] && [ "$PAYLOAD_OWNERSHIP_ORIGIN" != export ] || return 0
  if [ "$PAYLOAD_UPSTREAM_PRESENT" = false ]; then
    printf '%s\0' notice 'Run agentic-flow upgrade first to record upstream hashes before claiming adoption.'
    return
  fi
  [ "$PAYLOAD_OWNERSHIP_ORIGIN" = upgrade ] && [ -n "$uninstall_head" ] || return 0
  shallow=$(uninstall_git rev-parse --is-shallow-repository)
  if [ "$shallow" = true ]; then
    printf '%s\0' notice 'Use a checkout with complete Git history before claiming adoption.'
    return
  fi
  commits=$(uninstall_git --literal-pathspecs log --full-history --topo-order --reverse \
    --max-count=2001 --format=%H --no-show-signature --no-notes --no-decorate \
    --no-renames --diff-filter=A "$uninstall_head" -- .agentic-flow-version)
  if [ "$(printf '%s\n' "$commits" | wc -l)" -gt 2000 ]; then
    uninstall_refuse git-read-failed 'too many adoption commits to inspect' 'git log -- .agentic-flow-version'
    return
  fi
  uninstall_adoption_commit=${commits%%$'\n'*}
  [ -z "$uninstall_adoption_commit" ] || printf '%s\0' adoption_commit "$uninstall_adoption_commit"
}

uninstall_payload() {
  local path=$1 created accepted offered why=created claim_entry
  payload_ownership_lookup "$path"
  created=${PAYLOAD_OWNERSHIP_CREATED[$PAYLOAD_OWNERSHIP_INDEX]:-}
  if [ -z "$created" ]; then
    why=no-ownership
    if [ -n "$uninstall_adoption_commit" ]; then
      claim_entry=$(uninstall_git --literal-pathspecs diff-tree --root --no-commit-id -r \
        --no-renames --name-only --diff-filter=A -z "$uninstall_adoption_commit" -- "$path" |
        perl -0ne 'BEGIN { $path = shift @ARGV } print "added" if $_ eq "$path\0"' -- "$path")
      [ "$claim_entry" != added ] || why=claimed
    fi
  fi
  payload_upstream_lookup "$path"
  accepted=${PAYLOAD_UPSTREAM_ACCEPTED[$PAYLOAD_UPSTREAM_INDEX]:-}
  offered=${PAYLOAD_UPSTREAM_OFFERED[$PAYLOAD_UPSTREAM_INDEX]:-}
  if [ "$why" != no-ownership ]; then
    if [ -n "$offered" ]; then why='pending-offer'
    elif [ -z "$accepted" ]; then why=edited
    fi
  fi
  uninstall_classify "$path" payload "$accepted" "$why"
}

uninstall_is_legacy_candidate() {
  local path=$1 base suffix version
  while [[ "$path" == *.agentic-new* ]]; do
    base=${path%.agentic-new*}
    suffix=${1#"$base".agentic-new}
    if [[ "$uninstall_installed_paths" == *$'\n'"$base"$'\n'* ]]; then
      [ -n "$suffix" ] || return 0
      for version in "$uninstall_version" "$uninstall_pending_version" unknown; do
        [ -n "$version" ] || continue
        if [ "$suffix" = ".$version" ] ||
          { [[ "$suffix" == ".$version."* ]] && [[ "${suffix#".$version."}" =~ ^([0-9a-f]{12}|[0-9]{1,10})$ ]]; }; then
          return 0
        fi
      done
      # Older versioned candidates can survive later upgrades and stamp changes.
      [[ "$suffix" =~ ^\.[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9._+-]+)?\+([0-9a-f]+|unknown)(\.([0-9a-f]{12}|[0-9]{1,10}))?$ ]] && return 0
    fi
    path=$base
  done
  return 1
}

uninstall_paths() {
  local path index candidate why seen=$'\n' count=0
  local uninstall_installed_paths=$'\n' uninstall_adoption_commit=''
  local stamp_paths='.agentic-flow-version .agentic-flow-source .agentic-flow-source-applied .agentic-flow-candidate-version .agentic-flow-installation .agentic-flow-upstream .agentic-flow-scopes-excluded .agentic-flow-stack-candidate .agentic-flow-ownership'
  local project_paths='.agentic-flow-assurance .agentic-flow-assurance-audit .agentic-flow-roles .agentic-flow-stack .agentic-flow-review-policy .agentic-flow/config'
  uninstall_adoption
  for path in ${PAYLOAD_STATE_FILES[@]+"${PAYLOAD_STATE_FILES[@]}"}; do
    uninstall_installed_paths="$uninstall_installed_paths$path"$'\n'
  done
  for path in $stamp_paths; do
    seen="$seen$path"$'\n'
    uninstall_classify "$path" stamp
  done
  for path in $project_paths; do
    seen="$seen$path"$'\n'
    uninstall_classify "$path" project
  done
  for path in ${PAYLOAD_OWNERSHIP_PATHS[@]+"${PAYLOAD_OWNERSHIP_PATHS[@]}"} \
    ${PAYLOAD_STATE_FILES[@]+"${PAYLOAD_STATE_FILES[@]}"}; do
    [[ "$seen" != *$'\n'"$path"$'\n'* ]] || continue
    seen="$seen$path"$'\n'
    payload_ownership_lookup "$path"
    index=$PAYLOAD_OWNERSHIP_INDEX
    candidate=${PAYLOAD_OWNERSHIP_CANDIDATES[$index]:-}
    if [ -n "$candidate" ]; then
      uninstall_classify "$path" candidate "$candidate"
    elif [[ "${path##*/}" != *.agentic-new* ]]; then
      uninstall_payload "$path"
    elif [ -e "$uninstall_root/$path" ] || [ -L "$uninstall_root/$path" ]; then
      why=unrecognized-candidate
      uninstall_is_legacy_candidate "$path" && why='legacy-candidate'
      uninstall_keep "$path" "$why"
    fi
  done
  while IFS= read -r -d '' path; do
    [ -n "$path" ] || return 0
    [[ "$seen" != *$'\n'"$path"$'\n'* ]] || continue
    count=$((count + 1))
    if [ "$count" -gt 2000 ]; then
      uninstall_refuse git-read-failed 'too many candidate files to inspect' "git ls-files --cached --others -- ':(glob)**/*.agentic-new*'"
      return
    fi
    # Never follow a symlink while reporting a discovered candidate.
    why=unrecognized-candidate
    uninstall_is_legacy_candidate "$path" && why='legacy-candidate'
    uninstall_keep "$path" "$why"
    seen="$seen$path"$'\n'
  done < <(uninstall_git ls-files -z --cached --others -- ':(glob)**/*.agentic-new*' && printf '\0')
  uninstall_refuse git-read-failed 'could not read candidate paths' 'git ls-files'
}

uninstall_exit_report() { # Convert an unexpected read failure to a structured refusal.
  local status=$?
  if [ "$status" -ne 0 ]; then
    uninstall_refuse "$uninstall_read_reason" "$uninstall_read_subject" "$uninstall_read_command"
    exit 0
  fi
}

uninstall_stamp() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  head -c 4101 "$1" | sed -n '1p'
}

uninstall_collect() {
  local uninstall_root uninstall_top uninstall_common='' git_dir='' uninstall_head='' status=0
  local uninstall_file_mode='' uninstall_version uninstall_pending_version
  # Variables used by the EXIT trap need shell scope after this function unwinds.
  uninstall_read_reason=git-read-failed
  uninstall_read_subject='could not read Git state'
  uninstall_read_command='git status'
  trap 'uninstall_exit_report' EXIT
  uninstall_top=$(git rev-parse --show-toplevel 2>/dev/null) || uninstall_top=''
  uninstall_root=$(find_root) || uninstall_root=${uninstall_top:-$(pwd -P)}
  uninstall_version=$(uninstall_stamp "$uninstall_root/.agentic-flow-version")
  printf '%s\0' root "$uninstall_root" version "$uninstall_version"
  if [ -z "$uninstall_top" ] || [ "$uninstall_top" != "$uninstall_root" ]; then
    uninstall_refuse not-git-toplevel "$uninstall_root" 'git rev-parse --show-toplevel'
  fi
  if [ -n "$uninstall_top" ]; then
    uninstall_common=$(uninstall_git rev-parse --path-format=absolute --git-common-dir)
    git_dir=$(uninstall_git rev-parse --absolute-git-dir)
    printf '%s\0' common "$uninstall_common"
    if [ "$git_dir" != "$uninstall_common" ]; then
      uninstall_refuse linked-worktree "$uninstall_top" 'git worktree list'
    fi
    uninstall_git diff --cached --no-ext-diff --no-textconv --ignore-submodules=none --quiet -- || status=$?
    case "$status" in
      1) uninstall_refuse staged-changes 'Review staged changes. For an interrupted uninstall, run the undo command printed by apply.' 'git diff --cached' ;;
      0) ;;
      *) uninstall_refuse git-read-failed 'could not inspect staged changes' 'git diff --cached' ;;
    esac
    uninstall_check_plans
    uninstall_check_locks
    uninstall_git_report
  fi
  if [ ! -f "$uninstall_root/.agentic-flow-installation" ] || [ -L "$uninstall_root/.agentic-flow-installation" ]; then
    uninstall_refuse no-installation "$uninstall_root/.agentic-flow-installation" 'agentic-flow upgrade'
  fi
  if [ "$uninstall_top" = "$uninstall_root" ]; then
    uninstall_read_reason=invalid-record
    uninstall_read_subject='could not read the installation or ownership records'
    uninstall_read_command='git status'
    if [ ! -L "$uninstall_root/.agentic-flow-installation" ]; then
      payload_read_installation "$uninstall_root"
      payload_upstream_load "$uninstall_root" inspect
      printf '%s\0' origin "${PAYLOAD_OWNERSHIP_ORIGIN:-none}"
      uninstall_read_reason=git-read-failed
      uninstall_read_subject='could not compare the installation with Git'
      uninstall_head=$(uninstall_git rev-parse --verify -q 'HEAD^{commit}') || uninstall_head=''
      status=0
      uninstall_file_mode=$(uninstall_git config --type=bool --get core.fileMode) || status=$?
      [ "$status" -le 1 ] || return "$status"
      uninstall_file_mode=${uninstall_file_mode:-true}
      uninstall_pending_version=$(uninstall_stamp "$uninstall_root/.agentic-flow-candidate-version")
      uninstall_paths
    fi
  fi
  trap - EXIT
}

uninstall_cmd() {
  local json=false claim_adoption=false keep_docs=false remove_project_state=false report
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=true ;;
      --claim-adoption) claim_adoption=true ;;
      --keep-docs) keep_docs=true ;;
      --remove-project-state) remove_project_state=true ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown uninstall flag: $1" ;;
    esac
    shift
  done
  # Suppress index refresh, promisor fetching and configured filesystem monitors.
  local GIT_OPTIONAL_LOCKS=0 GIT_NO_LAZY_FETCH=1
  export GIT_OPTIONAL_LOCKS GIT_NO_LAZY_FETCH
  report=$(set -e; uninstall_collect | perl "$UNINSTALL_LIB/uninstall-report.pl")
  if [ "$json" = true ]; then
    printf '%s\n' "$report"
  else
    jq -r '
      def rows(heading; values): heading, (values[] | "  " + .);
      def cmd: if .command == null then "" else "  " + .command end;
      "agentic-flow uninstall (dry run)",
      (if .refusals == [] then empty else rows("Refusals"; [.refusals[] | "\(.reason)  \(.subject)" + cmd]) end),
      rows("Will remove (staged by git rm)"; [.remove[] | "\(.path)  (\(.why))"]),
      rows("Kept — finish by hand"; [.kept[] | "\(.path)  (\(.why))" + cmd]),
      rows("Still referencing removed files"; [.dangling_references[] | "\(.file):\(.line): \(.ref)"]),
      (if .dangling_references == [] then empty else "  Review these references. make check and CI may fail after removal." end),
      (if .dangling_truncated == 0 then empty else "  \(.dangling_truncated) additional matching lines omitted." end),
      rows("Git config and refs"; [.git[] | "\(.what)  \(.detail)  \(.command)"]),
      rows("Shared Git state (not removed)"; [.git_state[] | "\(.dir)  \(.entries) entries  \(.bytes) bytes  \(.class)  \(.command)" +
        (if (.dir | endswith("/ledger")) then "  (only copy of the plan journal)" else "" end)]),
      rows("Outside the repository"; .outside)
      | gsub("[\u0000-\u001f\u007f]"; "?")
    ' <<< "$report"
  fi
  if jq -e '.refusals | length > 0' <<< "$report" >/dev/null; then return 3; fi
}
