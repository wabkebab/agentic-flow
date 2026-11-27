#!/usr/bin/env bash
# Offline status. The controller lock and the journal remain authoritative.
# shellcheck disable=SC1091,SC2016 # Runtime library paths and jq expressions.
STATUS_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$STATUS_LIB/brief.sh"
. "$STATUS_LIB/ledger.sh"
. "$STATUS_LIB/start.sh"
. "$STATUS_LIB/workflow.sh"

status_jq() {
  local filter=$1; shift
  jq -L "$STATUS_LIB" "$@" "include \"status\"; $filter"
}

status_doc_valid() {
  [[ "$1" =~ ^docs/(inprogress|done)(/[A-Za-z0-9_.-]+)+\.md$ && "$1" != *'/../'* && "$1" != *'/./'* ]]
}

status_source() { # file byte cap jq validator [jq arguments]
  local file=$1 cap=$2 filter=$3; shift 3
  perl "$STATUS_LIB/status-files.pl" read "$file" "$cap" | status_jq "$filter" -c "$@"
}

status_probe_doc() { # immutable commit path [expected plan]; 1 absent, 3 invalid, 4 over cap
  local tip=$1 doc=$2 expected=${3:-} object size
  object=$(git ls-tree --full-tree "$tip" -- "$doc" 2>/dev/null) || return 1
  [ -n "$object" ] || return 1
  case "$object" in '100644 blob '*|'100755 blob '*) ;; *) return 3 ;; esac
  size=$(git cat-file -s "$tip:$doc" 2>/dev/null) || return 3
  [ "$size" -le 1048576 ] || return 4
  git show "$tip:$doc" 2>/dev/null | brief_parse - "$doc" "$tip" 2>/dev/null |
    jq -ec --arg expected "$expected" '
      select($expected == "" or .id == $expected) |
      {id,profile,branch,policy,steps:[.steps[] | {id}]}' || return 3
}

status_resolve_doc() { # requested path or id, optional heartbeat doc
  local request=$1 hint=$2 docs='' doc refs tip branch named_tip spec match='' rc state=absent expected='' known_doc='' remaining=200
  if status_doc_valid "$request"; then
    docs=$request
  else
    expected=$request
    docs=$(plan_doc_paths "$request")
    [ -z "$hint" ] || docs="$hint"$'\n'"$docs"
  fi
  refs=$(git for-each-ref --count=1000 --format='%(objectname)' refs/heads/) || return 1
  # HEAD can be detached, and can hold a closed doc after the plan branch is deleted.
  tip=$(git rev-parse --verify HEAD 2>/dev/null) || tip=''
  refs=$({ printf '%s\n%s\n' "$tip" "$refs"; } | awk 'NF && !seen[$0]++')
  while IFS= read -r tip; do
    while IFS= read -r doc; do
      rc=0
      spec=$(status_probe_doc "$tip" "$doc" "$expected") || rc=$?
      case "$rc" in
        4) state=over_limit; known_doc=$doc; continue ;;
        3) if [ "$state" = absent ]; then state=missing; known_doc=$doc; fi; continue ;;
        0) ;;
        *) continue ;;
      esac
      branch=$(printf '%s\n' "$spec" | jq -r .branch)
      git check-ref-format "refs/heads/$branch" || continue
      named_tip=$(git rev-parse --verify "refs/heads/$branch" 2>/dev/null) || named_tip=''
      if [ "$named_tip" = "$tip" ]; then
        printf '%s\n' "$spec" | jq -c --arg doc "$doc" '{state:"ok",value:.,doc:$doc}'
        return
      fi
      if [ -z "$match" ] && { [ -z "$named_tip" ] || [[ "$doc" == docs/done/* ]]; }; then
        match=$(printf '%s\n' "$spec" | jq -c --arg doc "$doc" '{state:"ok",value:.,doc:$doc}')
      fi
    done <<< "$docs"
  done <<< "$refs"
  if [ -n "$match" ]; then printf '%s\n' "$match"; return; fi
  # A document passed to run can use a different basename from its plan id.
  # Search a bounded set of tracked Markdown files when no conventional path resolves.
  if [ -n "$expected" ] && [ -z "$hint" ] && [ "$state" = absent ]; then
    while IFS= read -r tip && [ "$remaining" -gt 0 ]; do
      while IFS= read -r doc && [ "$remaining" -gt 0 ]; do
        remaining=$((remaining-1))
        status_doc_valid "$doc" || continue
        spec=$(status_probe_doc "$tip" "$doc" "$expected") || continue
        branch=$(printf '%s\n' "$spec" | jq -r .branch)
        git check-ref-format "refs/heads/$branch" || continue
        named_tip=$(git rev-parse --verify "refs/heads/$branch" 2>/dev/null) || named_tip=''
        if [ -n "$named_tip" ] && [ "$tip" != "$named_tip" ] && [[ "$doc" != docs/done/* ]]; then
          spec=$(status_probe_doc "$named_tip" "$doc" "$expected") || continue
        fi
        printf '%s\n' "$spec" | jq -c --arg doc "$doc" '{state:"ok",value:.,doc:$doc}'
        return
      done < <(git ls-tree -r --full-tree --name-only "$tip" -- docs/inprogress docs/done | head -n "$remaining")
    done <<< "$refs"
  fi
  jq -nc --arg state "$state" --arg doc "$known_doc" '{state:$state,doc:$doc}'
}

status_liveness() { # heartbeat, owner, claimant
  local beat=$1 owner=$2 claimant=$3 state=unknown host pid start current local_host
  if IFS=$'\t' read -r host pid < <(
    printf '%s\n' "$beat" | jq -r '.value | select(. != null) | [.host,.pid] | @tsv'
  ); then
    local_host=$(perl "$STATUS_LIB/recovery.pl" host "$status_common" 2>/dev/null) || local_host=''
    if [ -z "$local_host" ]; then state=unknown
    elif [ "$local_host" != "$host" ]; then state=other-host
    elif [ ! -e "$status_lock" ] && [ ! -L "$status_lock" ]; then state=stopped
    else
      state=$(printf '%s\n' "$beat" "$owner" "$claimant" | jq -rs '
        def matches($beat): .state=="ok" and .value.pid==$beat.pid and .value.start==$beat.start;
        .[0].value as $beat |
        if $beat.ownership=="recovering" and (.[2] | matches($beat)) then "recovering"
        elif .[1] | matches($beat) then "alive"
        elif .[2] | matches($beat) then "recovering"
        elif (if $beat.ownership=="owner" then .[1] else .[2] end).state=="ok" then "stopped"
        else "unknown" end')
      case "$state" in
        alive|recovering)
          if current=$(perl "$STATUS_LIB/recovery.pl" process "$pid" 2>/dev/null); then
            start=$(printf '%s\n' "$beat" | jq -r .value.start)
            if [ "$current" != "$start" ] || printf '%s\n' "$beat" | jq -e '.value.phase == "stopped"' >/dev/null; then
              state=stopped
            fi
          else state=unknown; fi ;;
      esac
    fi
  fi
  printf '%s\n' "$beat" | status_jq 'controller_view(.value; $state)' -c --arg state "$state"
}

status_snapshot() { # populates status_view and caches the projected ledger for watch
  local source spec doc plan hint='' hb owner claimant workflow stamp ledger_file valid_dirs=true
  local status_state="$status_flow/state" status_locks="$status_flow/locks" status_lock
  if [ -L "$status_flow" ] || [ -L "$status_state" ]; then status_state=/dev/null; fi
  if [ -L "$status_flow" ] || [ -L "$status_locks" ]; then status_locks=/dev/null; fi
  plan=$status_request
  if status_doc_valid "$status_request"; then
    spec=$(status_resolve_doc "$status_request" '') || return 3
    plan=$(printf '%s\n' "$spec" | jq -r '.value.id // empty')
    if [ -z "$plan" ]; then
      plan=${status_request##*/}; plan=${plan%.md}; plan=${plan#feature-}; plan=${plan#security-}
      plan_id_valid "$plan" || return 3
    fi
  fi
  status_lock="$status_locks/controller-$plan"
  hb=$(status_source "$status_state/$plan.controller.json" 4096 'json_source | valid(heartbeat($plan))' --arg plan "$plan")
  if ! status_doc_valid "$status_request"; then
    hint=$(printf '%s\n' "$hb" | jq -r '.value.doc // empty')
    spec=$(status_resolve_doc "$plan" "$hint") || return 3
  fi
  doc=$(printf '%s\n' "$spec" | jq -r '.doc // empty')
  if [ -z "$doc" ]; then
    if status_doc_valid "$status_request"; then doc=$status_request
    else doc=${hint:-docs/inprogress/feature-$plan.md}; fi
  fi
  ledger_file="$LEDGER_DIR/$plan.jsonl"
  if [ "$(printf '%s\n' "$spec" | jq -r .state)" = absent ]; then
    source=false
    local path
    for path in "$status_state/$plan."{controller.json,tsv,holds.json,metrics.json} "$status_lock" "$ledger_file"; do
      if [ -e "$path" ] || [ -L "$path" ]; then source=true; break; fi
    done
    [ "$source" = true ] || return 3
  fi

  owner='{"state":"missing"}'; claimant=$owner
  if [ -d "$status_lock" ] && [ ! -L "$status_lock" ]; then
    owner=$(status_source "$status_lock/owner.json" 4096 'json_source | valid(lock_owner(false))')
    if [ -d "$status_lock/recover" ] && [ ! -L "$status_lock/recover" ]; then
      claimant=$(status_source "$status_lock/recover/owner.json" 4096 'json_source | valid(lock_owner(true))')
    fi
  fi
  workflow='{}'
  if [ ! -L "$status_root/config/workflow.tsv" ] && workflow_load "$status_root" 2>/dev/null; then
    workflow=$(printf '%s' "$WORKFLOW_DATA" | status_jq 'workflow_rules' -Rsc)
  fi

  [ ! -L "$LEDGER_DIR" ] && [ ! -L "$status_flow" ] || valid_dirs=false
  stamp=null
  if [ "$valid_dirs" = true ]; then
    stamp=$(perl "$STATUS_LIB/status-files.pl" stamp "$ledger_file")
  fi
  if [ "$stamp" != null ]; then
    if [ "$status_ledger_stamp" != "$stamp" ] || [ "$status_ledger_plan" != "$plan" ]; then
      status_ledger=$( { ledger_read "$plan" 2>&1 || true; } | status_jq 'status_ledger' -Rsc) || return 3
      status_ledger_stamp=$stamp
      status_ledger_plan=$plan
    fi
  else
    status_ledger='{"state":"absent"}'
    if [ "$valid_dirs" = false ] || [ -e "$ledger_file" ] || [ -L "$ledger_file" ]; then
      status_ledger='{"state":"error"}'
    fi
    status_ledger_stamp=''
  fi

  status_view=$(
    {
      printf '%s\n' "$spec" "$hb" "$owner" "$claimant"
      status_source "$status_state/$plan.tsv" 262144 'parse_steps'
      status_source "$status_state/$plan.holds.json" 262144 'holds($plan)' --arg plan "$plan"
      status_source "$status_state/$plan.metrics.json" 4194304 'metrics($plan)' --arg plan "$plan"
      printf '%s\n' "$workflow" "$status_ledger"
      status_liveness "$hb" "$owner" "$claimant"
    } | status_jq 'plan_view($plan; $doc) | clean_fields' -sc --arg plan "$plan" --arg doc "$doc"
  )
}

status_plan_cmd() { # request, json, watch interval (zero for a single snapshot)
  local status_request=$1 json=$2 interval=$3 status_root status_common status_flow
  local LEDGER_DIR status_ledger='' status_ledger_stamp='' status_ledger_plan='' status_view='' sleeper=''
  export GIT_OPTIONAL_LOCKS=0 GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL=''
  status_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 3
  cd "$status_root" || return 3
  status_common=$(git rev-parse --git-common-dir) && status_common=$(cd "$status_common" && pwd -P) || return 3
  status_flow="$status_common/agentic-flow"
  LEDGER_DIR="$status_flow/ledger"

  if [ "$interval" -gt 0 ]; then
    trap 'if [ -n "$sleeper" ]; then kill "$sleeper" 2>/dev/null || true; fi; exit 0' INT TERM
  fi
  while :; do
    status_snapshot || { printf 'status: unknown or unreadable plan: %s\n' "$status_request" >&2; return 3; }
    if [ "$interval" -gt 0 ]; then printf '\033[2J\033[H'; fi
    if [ "$json" = true ]; then
      printf '%s\n' "$status_view" | jq 'del(.escalations[].return_state)'
    else
      printf '%s\n' "$status_view" | status_jq 'plan_text' -r
    fi
    if [ "$interval" -eq 0 ]; then
      if printf '%s\n' "$status_view" | jq -e '.next.owner == "human"' >/dev/null; then return 10; fi
      return 0
    fi
    sleep "$interval" & sleeper=$!
    wait "$sleeper"
    sleeper=''
  done
}

status_summary() { # install root -> bounded local summary
  local root=$1 common flow listing plan
  common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || common=''
  case "$common" in ''|/*) ;; *) common="$root/$common" ;; esac
  flow="$common/agentic-flow"
  if [ -z "$common" ] || [ -L "$flow" ] || [ ! -d "$flow" ]; then
    printf '%s\n' '{"items":[],"more":0}'; return
  fi
  listing=$(perl "$STATUS_LIB/status-files.pl" discover "$flow") || return
  {
    printf '%s\n' "$listing"
    while IFS= read -r plan; do
      {
        if [ -L "$flow/state" ]; then printf '%s\n' '{"state":"missing"}' '{"state":"missing"}'
        else
          status_source "$flow/state/$plan.controller.json" 4096 'json_source | valid(heartbeat($plan))' --arg plan "$plan"
          status_source "$flow/state/$plan.tsv" 262144 'parse_steps'
        fi
      } | status_jq 'summary_row($plan)' -sc --arg plan "$plan"
    done < <(printf '%s\n' "$listing" | jq -r '.ids[]')
  } | status_jq '{items:.[1:],more:.[0].more} | clean_fields' -sc
}
