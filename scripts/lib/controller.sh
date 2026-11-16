#!/usr/bin/env bash
# C-4: recovery only. No station launch, verification, checkout, reset or clean.
# shellcheck disable=SC1091,SC2034 # Shared adapters consume the context globals.
. "$(dirname "${BASH_SOURCE[0]}")/handoff.sh"
. "$(dirname "${BASH_SOURCE[0]}")/brief.sh"
CONTROLLER_RECOVERY=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/recovery.pl

controller_error() { printf 'controller: %s\n' "$*" >&2; }
controller_check() { # Rule a: same read-only report exposed by handoff reconcile --check.
  local json=true
  handoff_drift > "$CT_TMP/report" || return $?
  CT_REPORT=$(cat "$CT_TMP/report")
  printf '%s\n' "$CT_SPEC" > "$CT_TMP/spec"
  jq -e --slurpfile spec "$CT_TMP/spec" '
    $spec[0] as $spec |
    (.issues|length)>0 and (.issues|length)<=100 and
    ([.issues[].step]|unique|length)==(.issues|length) and
    ([.issues[]|select(.topology!="tracker")|.step]|sort)==([$spec.steps[].id]|sort) and
    (if $spec.profile=="strict" then ([.issues[]|select(.topology=="tracker")]|length)==1
     else (.issues|length)==1 and .issues[0].topology=="work-standard" end)' "$CT_TMP/report" >/dev/null || {
    controller_error 'stamped issues differ from the approved plan'; return 3;
  }
  CT_TRACKER=$(jq -r '.tracker//.issues[0].number' "$CT_TMP/report")
}

controller_lock() {
  local owner pid start host current
  CT_LOCK="$CT_COMMON/agentic-flow/locks/controller-$CT_PLAN"
  mkdir -p "$CT_COMMON/agentic-flow/locks" || return 9
  [ ! -L "$CT_LOCK" ] || return 9
  if mkdir "$CT_LOCK" 2>/dev/null; then CT_LOCK_OWNED=true
  else
    [ -f "$CT_LOCK/owner.json" ] && [ ! -L "$CT_LOCK/owner.json" ] && [ "$(wc -c < "$CT_LOCK/owner.json")" -le 4096 ] || return 9
    owner=$(cat "$CT_LOCK/owner.json")
    printf '%s' "$owner" | jq -e '(.pid|type)=="number" and .pid>0 and (.start|type)=="string" and (.host|test("^[a-f0-9]{12}$")) and (.run|type)=="string"' >/dev/null || return 9
    pid=$(printf '%s' "$owner" | jq -r .pid)
    start=$(printf '%s' "$owner" | jq -r .start)
    host=$(printf '%s' "$owner" | jq -r .host)
    if [ "$host" = "$CT_HOST" ]; then
      current=$(perl "$CONTROLLER_RECOVERY" process "$pid") || return 9
      if [ -n "$current" ] && [ "$current" = "$start" ]; then controller_error "controller already owns $CT_PLAN (pid $pid)"; return 9; fi
    elif [ "$CT_TAKE_OVER" = false ]; then controller_error "controller lock belongs to host $host"; return 9; fi
    controller_claim || return 9
    CT_RECOVER_CLAIM=true
    [ "$(cat "$CT_LOCK/owner.json")" = "$owner" ] || return 9
    CT_PREVIOUS_HOST=$host
    # Keep the old owner until reconciliation completes cleanly.
    return 0
  fi
  controller_lock_publish
}
controller_claim() { # A recovery claimant can itself crash; inspect its process too.
  local owner pid start current
  if ! mkdir "$CT_LOCK/recover" 2>/dev/null; then
    [ -f "$CT_LOCK/recover/owner.json" ] && [ ! -L "$CT_LOCK/recover/owner.json" ] && [ "$(wc -c < "$CT_LOCK/recover/owner.json")" -le 4096 ] || return 9
    owner=$(cat "$CT_LOCK/recover/owner.json")
    printf '%s' "$owner" | jq -e '(.pid|type)=="number" and .pid>0 and (.start|type)=="string"' >/dev/null || return 9
    pid=$(printf '%s' "$owner" | jq .pid); start=$(printf '%s' "$owner" | jq -r .start)
    current=$(perl "$CONTROLLER_RECOVERY" process "$pid") || return 9
    if [ -n "$current" ] && [ "$current" = "$start" ]; then return 9; fi
    mv "$CT_LOCK/recover" "$CT_LOCK/recover.stale.$CT_PID" 2>/dev/null || return 9
    rm -rf "$CT_LOCK/recover.stale.$CT_PID"
    mkdir "$CT_LOCK/recover" 2>/dev/null || return 9
  fi
  CT_RECOVER_CLAIM=true
  start=$(perl "$CONTROLLER_RECOVERY" process "$CT_PID") || return 9
  jq -n --argjson pid "$CT_PID" --arg start "$start" '{pid:$pid,start:$start}' > "$CT_LOCK/recover/owner.json"
}
controller_lock_publish() {
  local start
  start=$(perl "$CONTROLLER_RECOVERY" process "$CT_PID") || return 9
  [ -n "$start" ] || return 9
  jq -n --argjson pid "$CT_PID" --arg start "$start" --arg host "$CT_HOST" --arg run "$CT_RUN" \
    '{pid:$pid,start:$start,host:$host,run:$run}' > "$CT_LOCK/owner.tmp" || return 9
  mv "$CT_LOCK/owner.tmp" "$CT_LOCK/owner.json" || return 9
}
controller_unlock() {
  if [ "$CT_LOCK_OWNED" = true ]; then rm -rf "$CT_LOCK"
  elif [ "$CT_RECOVER_CLAIM" = true ]; then rm -rf "$CT_LOCK/recover"; fi
  rm -rf "$CT_TMP"
}
controller_foreign() {
  local foreign number host seq row
  foreign=$(printf '%s' "$CT_REPORT" | jq -c --arg host "$CT_HOST" --argjson lease "$CT_LEASE" '
    .issues[]|select(.host!=null and .host!=$host and .latest_at!=null)|
    select((.latest_at|fromdateiso8601)>(now-$lease))') || return 5
  [ -n "$foreign" ] || return 0
  while IFS= read -r row; do
    number=$(printf '%s' "$row" | jq .number); host=$(printf '%s' "$row" | jq -r .host); seq=$(printf '%s' "$row" | jq .replay.seq)
    if [ "$CT_STARTED" = false ]; then
      if [ "$CT_TAKE_OVER" = false ]; then controller_error "foreign controller host $host on #$number; use --take-over"; return 9; fi
      CT_FOREIGN_ALLOWED=$(printf '%s' "$CT_FOREIGN_ALLOWED" | jq --arg key "$number/$seq/$host" '.+[$key]')
      CT_PREVIOUS_HOST=$host
    elif ! printf '%s' "$CT_FOREIGN_ALLOWED" | jq -e --arg key "$number/$seq/$host" 'index($key)!=null' >/dev/null; then
      CT_FOREIGN_SEEN=true
      controller_hold "$number" foreign-controller-host "Controller host changed to $host during reconciliation." || return $?
      return 10
    fi
  done <<< "$foreign"
}
controller_hold() { # issue reason paragraph [run]
  local number=$1 reason=$2 note=$3 run=${4:-none} rc=0
  printf '%s\nagentic-flow-run: run=%s; host=%s\n' "$note" "$CT_RUN" "$CT_HOST" > "$CT_TMP/hold-note"
  handoff_cmd "$number" hold --as approver --reason "$reason" --run "$run" --body-file "$CT_TMP/hold-note" > "$CT_TMP/hold-output" || rc=$?
  case "$rc" in 0|10) ;; *) return "$rc" ;; esac
  if [ "$run" != none ] && [ "$HANDOFF_LEDGER_UNAVAILABLE" = false ]; then
    local held_chain
    held_chain=$(printf '%s' "$CT_RECORDS" | jq -r --arg run "$run" '.[]|select(.kind=="intent" and .run==$run)|.chain')
    [ -z "$held_chain" ] || controller_end "$held_chain" held || return 5
  fi
  CT_RAISED=true
  CT_HOLD_REASONS=$(printf '%s' "$CT_HOLD_REASONS" | jq --arg reason "$reason" --argjson issue "$number" '.+[{issue:$issue,reason:$reason}]|unique_by([.issue,.reason])')
}
controller_holds() { # import authorized remote clears, including a crash before ledger append
  local history item id records
  handoff_read "$CT_TRACKER" || return $?
  history=$(printf '%s' "$HANDOFF_ISSUE" | jq .comments.nodes | journal_normalize | hold_replay "$CT_PLAN" all) || return 5
  if [ "$HANDOFF_LEDGER_UNAVAILABLE" = false ]; then
    while IFS= read -r item; do
      id=$(printf '%s' "$item" | jq -r .id)
      hold_record "$CT_PLAN" "$id" "$(printf '%s' "$item" | jq .issue)" "$(printf '%s' "$item" | jq -r .reason)" "$(printf '%s' "$item" | jq -r .run)" "$(printf '%s' "$item" | jq -r .comment_id)" >/dev/null || return 5
      if [ "$(printf '%s' "$item" | jq .cleared)" = true ]; then
        records=$(ledger_read "$CT_PLAN") || return 5
        if ! printf '%s' "$records" | jq -e --arg id "$id" 'any(.[];.kind=="clear" and .hold==$id)' >/dev/null; then
          jq -n --arg plan "$CT_PLAN" --arg id "$id" '{v:1,kind:"clear",plan:$plan,hold:$id,by:"journal",note:"Recovered authorized clear",at:(now|floor)}' > "$CT_TMP/record"
          ledger_clear "$CT_PLAN" "$CT_TMP/record" >/dev/null || return 5
        fi
      fi
    done < <(printf '%s' "$history" | jq -c '.[]')
  fi
  CT_HOLDS=$(hold_snapshot "$HANDOFF_ISSUE") || return 5
}
controller_repair() { # issue projection flag description
  local rc=0
  handoff_cmd "$1" reconcile "$2" > "$CT_TMP/repair-output" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  CT_REPAIRS=$(printf '%s' "$CT_REPAIRS" | jq --argjson issue "$1" --arg kind "$3" '.+[{issue:$issue,kind:$kind}]')
}
controller_labels() { # Rule b; never changes open/closed status or posts notify.
  local number
  while IFS= read -r number; do controller_repair "$number" --labels-only labels || return $?; done \
    < <(printf '%s' "$CT_REPORT" | jq -r '.issues[]|select(.drift|index("labels"))|select((.drift|index("unjournaled"))==null)|.number')
}
controller_timeline() { # GraphQL keeps actor type and refuses truncated event histories.
  local number=$1 response
  # shellcheck disable=SC2016 # Literal GraphQL variables.
  local query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){timelineItems(first:100,itemTypes:[CLOSED_EVENT,REOPENED_EVENT]){pageInfo{hasNextPage} nodes{__typename ... on ClosedEvent{createdAt actor{login __typename}} ... on ReopenedEvent{createdAt actor{login __typename}}}}}}}'
  response=$(handoff_gh api graphql -f "query=$query" -f "owner=${HANDOFF_REPO%%/*}" -f "name=${HANDOFF_REPO#*/}" -F "number=$number") || return 5
  printf '%s' "$response" | jq -ec '
    if (.errors//[]|length)>0 then error("timeline API error") else .data.repository.issue.timelineItems end |
    if .pageInfo.hasNextPage!=false or (.nodes|type)!="array" or (.nodes|length)>100 or
      any(.nodes[]; (.__typename!="ClosedEvent" and .__typename!="ReopenedEvent") or (.createdAt|type)!="string" or (.actor|type)!="object" or (.actor.login|type)!="string" or (.actor.__typename!="User" and .actor.__typename!="Bot"))
    then error("invalid or truncated issue timeline") else .nodes end'
}
controller_open_state() { # Rule c; a deliberate human action is never projected away.
  local row number events human reason
  while IFS= read -r row; do
    number=$(printf '%s' "$row" | jq .number)
    events=$(controller_timeline "$number") || { controller_error "cannot read complete timeline for #$number"; return 5; }
    human=$(printf '%s' "$events" | jq -c --argjson row "$row" '
      [.[]|select(.actor.__typename=="User")|
        select((.createdAt|fromdateiso8601)>($row.latest_at//"1970-01-01T00:00:00Z"|fromdateiso8601))|
        select((.__typename=="ReopenedEvent" and $row.observed_status=="open") or (.__typename=="ClosedEvent" and $row.observed_status=="closed"))]|sort_by(.createdAt)|last//null') || return 5
    if [ "$human" != null ]; then
      reason=reopened; [ "$(printf '%s' "$human" | jq -r .__typename)" != ClosedEvent ] || reason=closed
      controller_hold "$number" "$reason" "$reason by $(printf '%s' "$human" | jq -r .actor.login); journal state is $(printf '%s' "$row" | jq -r .state)." || return $?
    else controller_repair "$number" --project-only open-state || return $?; fi
  done < <(printf '%s' "$CT_REPORT" | jq -c '.issues[]|select(.drift|index("open-state"))|select((.drift|index("unjournaled"))==null)')
}
controller_plan_effect() { # Rule d; suppress completion while a human decision is pending.
  local number rc
  if printf '%s' "$CT_REPORT" | jq -e 'any(.issues[];.drift|index("unjournaled"))' >/dev/null; then return 0; fi
  [ "$CT_RAISED" = false ] && [ "$(printf '%s' "$CT_HOLDS" | jq length)" -eq 0 ] || return 0
  while IFS= read -r number; do
    rc=0; handoff_cmd "$number" reconcile > "$CT_TMP/repair-output" || rc=$?
    case "$rc" in
      0) CT_REPAIRS=$(printf '%s' "$CT_REPAIRS" | jq --argjson issue "$number" '.+[{issue:$issue,kind:"plan-effect"}]') ;;
      7) controller_hold "$number" plan-effect-pending "Run agentic-flow handoff $number reconcile where the reviewer identity is configured." || return $? ;;
      *) return "$rc" ;;
    esac
  done < <(printf '%s' "$CT_REPORT" | jq -r '.issues[]|select(.drift|index("plan-effect"))|.number')
}
controller_unjournaled() { # Rule e.
  local number
  while IFS= read -r number; do controller_hold "$number" unjournaled 'The admitted historical journal cannot be replayed; repair or re-plan it.' || return $?; done \
    < <(printf '%s' "$CT_REPORT" | jq -r '.issues[]|select(.drift|index("unjournaled"))|.number')
}

controller_record() { ledger_append "$1" "$CT_PLAN" "$CT_TMP/record" >/dev/null; }
controller_end() {
  if ledger_read "$CT_PLAN" | jq -e --arg chain "$1" 'any(.[];.kind=="end" and .chain==$chain)' >/dev/null; then return 0; fi
  jq -n --arg chain "$1" --arg how "$2" --arg hold "${3:-}" '{v:1,kind:"end",chain:$chain,how:$how,hold:(if $hold=="" then null else $hold end),at:(now|floor)}' > "$CT_TMP/record"
  controller_record end
}
controller_preserve_divergence() { # Never overwrite the owning run's immutable salvage ref.
  local run saved
  run="$CT_PLAN/unowned/$(printf '%s/%s' "$CT_RUN" "$(jq -r .worktree_tree "$CT_TMP/snapshot")" | shasum -a 256 | cut -c1-24)"
  saved=$(perl "$CONTROLLER_RECOVERY" salvage "$CT_WORKTREE" "$run" "$CT_TMP/snapshot") || return 9
  printf '%s' "$saved" | jq --arg run "$run" '.+{v:1,kind:"salvage",run:$run,chain:null,orphan:true,at:(now|floor)}|del(.dirty)' > "$CT_TMP/record"
  controller_record salvage || return 5
  CT_RECORDS=$(ledger_read "$CT_PLAN") || return 5
  CT_OWNERSHIP=$(printf '%s' "$saved" | jq --arg run "$run" '{run:$run,ref,paths,restore_required:false}')
}
controller_worktree() { # Salvage before any repair; reconciliation never restores it.
  local actual common branch owner run chain recorded snapshot saved count row result orphan=false hold_run=none
  CT_WORKTREE="${AGENTIC_WORKTREE_ROOT:-$CT_COMMON/agentic-flow/worktrees}/$CT_PLAN"
  CT_CONTEXT='{}' CT_OWNERSHIP=null
  [ -e "$CT_WORKTREE" ] || return 0
  actual=$(git -C "$CT_WORKTREE" rev-parse --show-toplevel) || return 9
  actual=$(cd "$actual" && pwd -P) || return 9
  [ "$actual" = "$(cd "$CT_WORKTREE" && pwd -P)" ] || return 9
  common=$(git -C "$CT_WORKTREE" rev-parse --git-common-dir) || return 9
  common=$(cd "$CT_WORKTREE" && cd "$common" && pwd -P) || return 9
  branch=$(git -C "$CT_WORKTREE" symbolic-ref --quiet --short HEAD) || return 9
  [ "$common" = "$CT_COMMON" ] && [ "$branch" = "$CT_BRANCH" ] || { controller_error 'plan worktree ownership differs'; return 9; }
  snapshot=$(perl "$CONTROLLER_RECOVERY" snapshot "$CT_WORKTREE") || return 9
  CT_SNAPSHOT=$snapshot
  # Context used by C-2 summaries: only commits on the current branch after base_head.
  printf '%s\n' "$CT_CHAINS" > "$CT_TMP/chains"
  while IFS= read -r owner; do
    run=$(printf '%s' "$owner" | jq -r .run)
    result=false
    if [ "$(printf '%s' "$owner" | jq -r .station)" = executor ]; then
      local base number commit commits=0
      base=$(printf '%s' "$owner" | jq -r .base_head); number=$(printf '%s' "$owner" | jq .issue)
      if git -C "$CT_WORKTREE" merge-base --is-ancestor "$base" HEAD; then
        while IFS= read -r commit; do
          commits=$((commits+1)); [ "$commits" -le 1000 ] || return 9
          if git -C "$CT_WORKTREE" show -s --format=%B "$commit" | grep -Eiq "(^|[[:space:]])Fixes #$number([^0-9]|$)"; then result=true; break; fi
        done < <(git -C "$CT_WORKTREE" rev-list --max-count=1001 "$base..HEAD")
      fi
    fi
    CT_CONTEXT=$(printf '%s' "$CT_CONTEXT" | jq --arg run "$run" --argjson dirty "$(printf '%s' "$snapshot" | jq .dirty)" --argjson commit "$result" '.+{($run):{dirty:$dirty,commit:$commit}}')
  done < <(printf '%s' "$CT_RECORDS" | jq -c --slurpfile chains "$CT_TMP/chains" '$chains[0] as $chains | [$chains[]|select(.head!=null)|.head] as $heads|.[]|select(.kind=="intent" and (.run as $run|$heads|index($run))!=null)')
  [ "$(printf '%s' "$snapshot" | jq .dirty)" = true ] || return 0
  printf '%s\n' "$CT_CONTEXT" > "$CT_TMP/context"
  if [ "$HANDOFF_LEDGER_UNAVAILABLE" = true ]; then CT_CHAINS='[]'; else CT_CHAINS=$(ledger_chains "$CT_PLAN" "$CT_TMP/context") || return 5; fi
  printf '%s\n' "$CT_RECORDS" > "$CT_TMP/records"
  printf '%s\n' "$CT_CHAINS" > "$CT_TMP/chains"
  owner=$(jq -nc --slurpfile records "$CT_TMP/records" --slurpfile chains "$CT_TMP/chains" '
    $records[0] as $records | $chains[0] as $chains |
    [$chains[]|select(.head!=null)|.head] as $heads |
    [$records[]|select(.kind=="intent" and (.run as $r|$heads|index($r))!=null)]|sort_by(.started)|last//null')
  # A completed executor ask retains ownership through the human resume.
  if [ "$owner" = null ]; then
    owner=$(printf '%s' "$CT_RECORDS" | jq -c '[.[]|select(.kind=="intent")]|sort_by(.started)|last//null')
    if [ "$owner" != null ]; then
      run=$(printf '%s' "$owner" | jq -r .run)
      result=$(printf '%s' "$CT_RECORDS" | jq -r --arg run "$run" '([.[]|select(.run==$run and .kind=="decision")]|last|.event)//([.[]|select(.run==$run and .kind=="station")]|last|.result.outcome)//"none"')
      row=$(printf '%s' "$CT_REPORT" | jq -c --argjson n "$(printf '%s' "$owner" | jq .issue)" '.issues[]|select(.number==$n)')
      if [ "$(printf '%s' "$owner" | jq -r .station)" != executor ] || [ "$result" != ask ] ||
        ! printf '%s' "$row" | jq -e --argjson seq "$(printf '%s' "$owner" | jq .seq_before)" '
          any(.replay.accepted[];.seq==($seq+1) and .event=="ask" and .role=="executor") and
          ((.state=="escalated" and .replay.seq==($seq+1)) or
           (.state=="executing" and .replay.seq==($seq+2) and .replay.latest.event=="resume"))' >/dev/null; then owner=null; fi
    fi
  fi
  if [ "$owner" = null ]; then
    run=$(printf '%s' "$CT_RECORDS" | jq -r --argjson now "$snapshot" '[.[]|select(.kind=="salvage" and .orphan==true and .head==$now.head and .index_tree==$now.index_tree and .worktree_tree==$now.worktree_tree)]|last|.run//""')
    [ -n "$run" ] || run="$CT_PLAN/unowned/$(printf '%s' "$CT_RUN" | shasum -a 256 | cut -c1-24)"
    chain=null; orphan=true
  else run=$(printf '%s' "$owner" | jq -r .run); chain=$(printf '%s' "$owner" | jq -r .chain); fi
  [ "$owner" = null ] || hold_run=$run
  printf '%s\n' "$snapshot" > "$CT_TMP/snapshot"
  recorded=$(printf '%s' "$CT_RECORDS" | jq -c --arg run "$run" '[.[]|select(.kind=="salvage" and .run==$run)]|last//null')
  if [ "$recorded" != null ]; then
    if ! jq -en --argjson old "$recorded" --argjson now "$snapshot" '$old.head==$now.head and $old.index_tree==$now.index_tree and $old.worktree_tree==$now.worktree_tree' >/dev/null; then
      controller_preserve_divergence || return $?
      controller_hold "$CT_TRACKER" worktree-changed-after-salvage "Worktree differs from $(printf '%s' "$recorded" | jq -r .ref); current edits were saved at $(printf '%s' "$CT_OWNERSHIP" | jq -r .ref)." "$hold_run" || return $?
      return 0
    fi
    saved=$recorded
  else
    printf '%s\n' "$snapshot" > "$CT_TMP/snapshot"
    saved=$(perl "$CONTROLLER_RECOVERY" salvage "$CT_WORKTREE" "$run" "$CT_TMP/snapshot") || {
      controller_preserve_divergence || return $?
      controller_hold "$CT_TRACKER" worktree-changed-after-salvage "Existing salvage ref for $run differs; current edits were saved at $(printf '%s' "$CT_OWNERSHIP" | jq -r .ref)." "$hold_run"; return $?;
    }
    printf '%s' "$saved" | jq --arg run "$run" --arg chain "$chain" --argjson orphan "$orphan" '
      .+{v:1,kind:"salvage",run:$run,chain:(if $chain=="null" then null else $chain end),orphan:$orphan,at:(now|floor)}|del(.dirty)' > "$CT_TMP/record"
    if [ "$HANDOFF_LEDGER_UNAVAILABLE" = false ]; then
      controller_record salvage || return 5
      CT_RECORDS=$(ledger_read "$CT_PLAN") || return 5
    fi
  fi
  CT_OWNERSHIP=$(printf '%s' "$saved" | jq --arg run "$run" '{run:$run,ref,paths,restore_required:false}')
  [ "$CT_SALVAGE_ONLY" = false ] || return 0
  if [ "$owner" = null ]; then
    [ "$(printf '%s' "$CT_HOLDS" | jq length)" -eq 0 ] || return 0
    controller_hold "$CT_TRACKER" unexplained-worktree-changes "Unowned edits saved at $(printf '%s' "$saved" | jq -r .ref): $(printf '%s' "$saved" | jq -c '[.paths[:20][]|{path:(.path[0:200]),status}]') (full paths are in the salvage record)" || return $?
    return 0
  fi
  result=$(printf '%s' "$CT_RECORDS" | jq -c --arg run "$run" '[.[]|select(.run==$run and .kind=="station")]|last//null')
  if [ "$(printf '%s' "$owner" | jq -r .station)" = reviewer ]; then
    count=$(printf '%s' "$CT_RECORDS" | jq --arg chain "$chain" '[.[]|select(.kind=="salvage" and .chain==$chain)]|length')
    CT_OWNERSHIP=$(printf '%s' "$CT_OWNERSHIP" | jq '.restore_required=true')
    if [ "$count" -gt 1 ]; then CT_REVIEWER_ESCALATE=$run
    elif ! printf '%s' "$CT_RECORDS" | jq -e --arg run "$run" 'any(.[];.kind=="decision" and .run==$run)' >/dev/null; then CT_REVIEWER_RELAUNCH=$run; fi
  elif [ "$result" != null ] && ! printf '%s' "$result" | jq -e '.invalid_reason!=null or .result.outcome=="ask"' >/dev/null; then
    controller_hold "$(printf '%s' "$owner" | jq .issue)" unexplained-worktree-changes "Recorded submit left unexplained edits at $(printf '%s' "$saved" | jq -r .ref)." "$run" || return $?
  fi
}

controller_decide() { # Rule f: deterministic rendering from durable records only.
  local item=$1 run intent station verify escalation outcome head body action number row reason=''
  run=$(printf '%s' "$item" | jq -r .head)
  intent=$(printf '%s' "$CT_RECORDS" | jq -c --arg run "$run" '.[]|select(.kind=="intent" and .run==$run)')
  number=$(printf '%s' "$intent" | jq .issue)
  row=$(printf '%s' "$CT_REPORT" | jq -c --argjson n "$number" '.issues[]|select(.number==$n)')
  station=$(printf '%s' "$CT_RECORDS" | jq -c --arg run "$run" '[.[]|select(.kind=="station" and .run==$run)]|last//null')
  verify=$(printf '%s' "$CT_RECORDS" | jq -c --arg run "$run" '[.[]|select(.kind=="verify" and .run==$run)]|last//null')
  escalation=$(printf '%s' "$item" | jq -r '.escalation//""')
  [ "$run" != "$CT_REVIEWER_ESCALATE" ] || escalation='reviewer edited the worktree'
  if [ -n "$escalation" ]; then action=ask; head=none; printf '%s\n' "$escalation" > "$CT_TMP/body"
  else
    outcome=$(printf '%s' "$station" | jq -r .result.outcome)
    head=$(printf '%s' "$station" | jq -r '.result.head//"none"')
    case "$outcome" in
      submitted) action=submit
        if [ "$(printf '%s' "$verify" | jq -r .status)" != green ]; then return 3; fi
        if ! git merge-base --is-ancestor "$(printf '%s' "$intent" | jq -r .base_head)" "$head" ||
          [ "$head" = "$(printf '%s' "$intent" | jq -r .base_head)" ] ||
          ! git merge-base --is-ancestor "$head" "refs/heads/$CT_BRANCH" ||
          [ "$head" = "$(printf '%s' "$row" | jq -r .replay.last_bounced_head)" ] ||
          ! git show -s --format=%B "$head" | grep -Eiq "(^|[[:space:]])Fixes #$number([^0-9]|$)"; then
          action=ask; head=none; reason='bad claimed head'
        fi ;;
      approve|bounce) action=$outcome
        if [ "$head" != "$(printf '%s' "$row" | jq -r .replay.submitted_head)" ]; then action=ask; head=none; reason='bad claimed head'; fi ;;
      ask) action=ask; head=none ;;
      *) return 3 ;;
    esac
    if [ -n "$reason" ]; then printf '%s\n' "$reason" > "$CT_TMP/body"
    elif [ "$action" = ask ]; then printf '%s' "$station" | jq -r .result.question > "$CT_TMP/body"
    elif [ "$action" = bounce ]; then printf '%s' "$station" | jq -r '.result|.summary, (.findings[]|"\(.severity) \(.file):\(.line//"?") \(.text)")' > "$CT_TMP/body"
    else printf '%s' "$station" | jq -r .result.summary > "$CT_TMP/body"; fi
  fi
  if [ "$action" = ask ] && ! printf '%s' "$row" | jq -e '.state=="executing" or .state=="reviewing"' >/dev/null; then
    controller_hold "$number" station-escalation "$(cat "$CT_TMP/body")" "$run" || return $?
    controller_end "$(printf '%s' "$intent" | jq -r .chain)" held || return 5
    return 0
  fi
  printf '\nagentic-flow-run: run=%s; host=%s\n' "$run" "$CT_HOST" >> "$CT_TMP/body"
  [ "$(wc -c < "$CT_TMP/body")" -le 65536 ] || { controller_hold "$number" decision-too-large 'The recorded result exceeds the handoff body cap.' "$run"; return $?; }
  body=$(shasum -a 256 "$CT_TMP/body"); body=${body%% *}
  jq -n --arg run "$run" --arg action "$action" --arg head "$head" --arg file "$CT_TMP/body" --arg hash "$body" \
    '{v:1,kind:"decision",run:$run,action:$action,event:$action,head:$head,body_file:$file,body_sha256:$hash,at:(now|floor)}' > "$CT_TMP/record"
  controller_record decision || return 5
  controller_fault after-decision
}
controller_replay_handoff() { # Rule f: immutable body plus the original CAS position.
  local run=$1 intent decision number event role head after attempt rc=0 seq=null reason
  intent=$(printf '%s' "$CT_RECORDS" | jq -c --arg run "$run" '.[]|select(.kind=="intent" and .run==$run)')
  decision=$(printf '%s' "$CT_RECORDS" | jq -c --arg run "$run" '.[]|select(.kind=="decision" and .run==$run)')
  number=$(printf '%s' "$intent" | jq .issue); role=$(printf '%s' "$intent" | jq -r .station)
  event=$(printf '%s' "$decision" | jq -r .event); head=$(printf '%s' "$decision" | jq -r '.head//"none"'); after=$(printf '%s' "$intent" | jq .seq_before)
  if ! ledger_body "$CT_PLAN" "$run" > "$CT_TMP/replay-body" 2> "$CT_TMP/body-error"; then
    controller_hold "$number" ledger-body-hash-mismatch "Decision body for $run failed integrity validation." "$run" || return $?
    controller_end "$(printf '%s' "$intent" | jq -r .chain)" held || return 5
    return 0
  fi
  case "$event" in submit|approve|bounce|ask) ;; *) controller_hold "$number" illegal-transition "Recorded event $event is not a station handoff." "$run"; return $? ;; esac
  handoff_cmd "$number" "$event" --as "$role" --head "$head" --after "$after" --body-file "$CT_TMP/replay-body" > "$CT_TMP/handoff-output" || rc=$?
  controller_fault after-post || return $?
  if handoff_read "$number"; then seq=$(printf '%s' "$HANDOFF_REPLAY" | jq .seq); fi
  attempt=$(printf '%s' "$CT_RECORDS" | jq --arg run "$run" '[.[]|select(.kind=="handoff" and .run==$run)]|length+1')
  jq -n --arg run "$run" --arg event "$event" --argjson after "$after" --argjson exit "$rc" --argjson seq "$seq" --argjson attempt "$attempt" \
    '{v:1,kind:"handoff",run:$run,event:$event,after:$after,exit:$exit,seq_after:$seq,attempt:$attempt,at:(now|floor)}' > "$CT_TMP/record"
  controller_record handoff || return 5
  controller_fault after-handoff || return $?
  case "$rc" in
    0|4)
      controller_check || return $?
      local foreign_status=0
      controller_foreign || foreign_status=$?
      [ "$foreign_status" -eq 0 ] || [ "$foreign_status" -eq 10 ] || return "$foreign_status" ;;
    3|7)
      reason=illegal-transition; [ "$rc" -ne 7 ] || reason=plan-effect-pending
      controller_hold "$number" "$reason" "Handoff for $run exited $rc; $(cat "$CT_TMP/handoff-output")" "$run" || return $?
      controller_end "$(printf '%s' "$intent" | jq -r .chain)" held || return 5 ;;
    *) return 5 ;;
  esac
}
controller_superseded() { # Rule g; decisions always replay through CAS instead.
  local item=$1 intent row expected
  intent=$(printf '%s' "$CT_RECORDS" | jq -c --arg run "$(printf '%s' "$item" | jq -r .head)" '.[]|select(.kind=="intent" and .run==$run)')
  row=$(printf '%s' "$CT_REPORT" | jq -c --argjson n "$(printf '%s' "$intent" | jq .issue)" '.issues[]|select(.number==$n)')
  expected=executing; [ "$(printf '%s' "$intent" | jq -r .station)" != reviewer ] || expected=reviewing
  if [ "$(printf '%s' "$row" | jq .replay.seq)" != "$(printf '%s' "$intent" | jq .seq_before)" ] || [ "$(printf '%s' "$row" | jq -r .state)" != "$expected" ]; then
    controller_end "$(printf '%s' "$item" | jq -r .chain)" dropped || return 5
    return 0
  fi
  return 1
}
controller_pending() { # Rule f then g, oldest chain first. Only decide/handoff execute.
  local item run pending rc
  CT_PENDING='[]'
  printf '%s\n' "$CT_CONTEXT" > "$CT_TMP/context"
  CT_CHAINS=$(ledger_chains "$CT_PLAN" "$CT_TMP/context") || return 5
  while IFS= read -r item; do
    [ "$CT_FOREIGN_SEEN" = false ] || break
    run=$(printf '%s' "$item" | jq -r .head); pending=$(printf '%s' "$item" | jq -r .pending)
    CT_RECORDS=$(ledger_read "$CT_PLAN") || return 5
    if [ "$run" = "$CT_REVIEWER_RELAUNCH" ] && [ "$(printf '%s' "$item" | jq -r '.escalation//""')" = '' ]; then
      pending=relaunch; item=$(printf '%s' "$item" | jq '.pending="relaunch"')
    fi
    [ "$run" != "$CT_REVIEWER_ESCALATE" ] || { pending=decide; item=$(printf '%s' "$item" | jq '.pending="decide"|.escalation="reviewer edited the worktree"'); }
    case "$pending" in
      decide)
        controller_decide "$item" || return $?
        CT_RECORDS=$(ledger_read "$CT_PLAN") || return 5
        if printf '%s' "$CT_RECORDS" | jq -e --arg run "$run" 'any(.[];.kind=="decision" and .run==$run)' >/dev/null; then controller_replay_handoff "$run" || return $?; fi ;;
      handoff) controller_replay_handoff "$run" || return $? ;;
      *)
        rc=0; controller_superseded "$item" || rc=$?
        case "$rc" in 0) ;; 1) CT_PENDING=$(printf '%s' "$CT_PENDING" | jq --argjson item "$item" '.+[$item]') ;; *) return "$rc" ;; esac ;;
    esac
  done < <(printf '%s' "$CT_CHAINS" | jq -c '.[]|select(.head!=null)')
}
controller_completed_effects() { # A crash after a completing exit 3/7 must not lose its hold.
  local item run intent code reason
  printf '%s\n' "$CT_CHAINS" > "$CT_TMP/chains"
  while IFS= read -r item; do
    run=$(printf '%s' "$item" | jq -r .latest)
    code=$(printf '%s' "$CT_RECORDS" | jq -r --arg run "$run" '[.[]|select(.kind=="handoff" and .run==$run)]|last|.exit//0')
    case "$code" in 3) reason=illegal-transition ;; 7) reason=plan-effect-pending ;; *) continue ;; esac
    if printf '%s' "$CT_RECORDS" | jq -e --arg chain "$(printf '%s' "$item" | jq -r .chain)" 'any(.[];.kind=="end" and .chain==$chain)' >/dev/null; then continue; fi
    if [ "$code" = 7 ] && printf '%s' "$CT_REPORT" | jq -e --argjson n "$CT_TRACKER" 'any(.issues[];.number==$n and .state!="open")' >/dev/null; then continue; fi
    intent=$(printf '%s' "$CT_RECORDS" | jq -c --arg run "$run" '.[]|select(.kind=="intent" and .run==$run)')
    controller_hold "$(printf '%s' "$intent" | jq .issue)" "$reason" "Recovered handoff exit $code for $run." "$run" || return $?
    controller_end "$(printf '%s' "$item" | jq -r .chain)" held || return 5
  done < <(printf '%s' "$CT_RECORDS" | jq -c --slurpfile chains "$CT_TMP/chains" 'map(select(.kind=="handoff" and (.exit==3 or .exit==7))|.run) as $runs|$chains[0][]|select(.head==null and (.latest as $run|$runs|index($run))!=null)')
}
controller_fault() {
  [ "${AGENTIC_CONTROLLER_TESTING:-}" = 1 ] && [ "${AGENTIC_CONTROLLER_FAULT:-}" = "$1" ] || return 0
  if [ -n "${AGENTIC_CONTROLLER_PAUSE:-}" ]; then
    local waited=0
    : > "$AGENTIC_CONTROLLER_PAUSE.ready"
    while [ ! -f "$AGENTIC_CONTROLLER_PAUSE.release" ] && [ "$waited" -lt 300 ]; do sleep 0.1; waited=$((waited+1)); done
    [ -f "$AGENTIC_CONTROLLER_PAUSE.release" ] || return 5
    return 0
  fi
  return 5
}

controller_cmd() (
  set +x
  local doc=${1:-} reconcile=false CT_TAKE_OVER=false CT_JSON=false
  [ "$#" -ge 1 ] || return 2; shift
  while [ "$#" -gt 0 ]; do
    case "$1" in --reconcile-only) reconcile=true ;; --take-over) CT_TAKE_OVER=true ;; --json) CT_JSON=true ;; *) return 2 ;; esac
    shift
  done
  [ "$reconcile" = true ] || { controller_error 'this step implements run --reconcile-only'; return 2; }
  local CT_ROOT CT_COMMON CT_TMP CT_PLAN CT_BRANCH CT_SPEC CT_REPORT CT_TRACKER CT_RECORDS CT_CHAINS CT_CONTEXT='{}' CT_PENDING='[]'
  local CT_LOCK='' CT_LOCK_OWNED=false CT_RECOVER_CLAIM=false CT_PREVIOUS_HOST='' CT_STARTED=false CT_FOREIGN_ALLOWED='[]' CT_FOREIGN_SEEN=false
  local CT_HOLDS='[]' CT_HOLD_REASONS='[]' CT_REPAIRS='[]' CT_RAISED=false CT_OWNERSHIP=null CT_REVIEWER_ESCALATE='' CT_REVIEWER_RELAUNCH='' CT_SNAPSHOT='{}' CT_SALVAGE_ONLY=false
  local CT_HOST CT_PID CT_RUN CT_WORKTREE CT_LEASE=${AGENTIC_CONTROLLER_LEASE:-21600} approval rev status=0 result=0
  [[ "$CT_LEASE" =~ ^[1-9][0-9]{0,6}$ ]] || return 2
  CT_ROOT=$(git rev-parse --show-toplevel) || return 3
  cd "$CT_ROOT" || return 3
  case "$doc" in docs/inprogress/*.md) ;; *) return 2 ;; esac
  case "$doc" in *'/../'*|*'/./'*|*[!A-Za-z0-9_./-]*) return 2 ;; esac
  CT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/agentic-controller.XXXXXX") || return 5
  trap controller_unlock EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  git show "HEAD:$doc" > "$CT_TMP/head-doc" || return 3
  [ "$(wc -c < "$CT_TMP/head-doc")" -le 1048576 ] || return 3
  approval=$(brief_approval "$CT_TMP/head-doc") || return 3; rev=${approval%%$'\t'*}
  brief_approved_at_head "$doc" "$rev" || return 3
  git show "$rev:$doc" > "$CT_TMP/doc" || return 3
  CT_SPEC=$(brief_parse "$CT_TMP/doc" "$doc" "$rev") || return 3
  CT_PLAN=$(printf '%s' "$CT_SPEC" | jq -r .id); CT_BRANCH=$(printf '%s' "$CT_SPEC" | jq -r .branch)
  git check-ref-format "refs/heads/$CT_BRANCH" || return 3
  workflow_load "$CT_ROOT" && read_review_policy "$CT_ROOT" || return 3
  [ -n "$REVIEW_OWNER" ] || { controller_error 'owner= is required for the controller'; return 3; }
  ledger_init "$CT_ROOT" || return 3
  CT_COMMON=$(git rev-parse --git-common-dir); CT_COMMON=$(cd "$CT_COMMON" && pwd -P) || return 3
  CT_HOST=$(perl "$CONTROLLER_RECOVERY" host "$CT_COMMON") || return 9
  CT_PID=$(exec sh -c 'printf "%s\n" "$PPID"')
  CT_RUN="$CT_PLAN/controller/$CT_PID-$(date +%s)"
  HANDOFF_ROOT=$CT_ROOT HANDOFF_PLAN=$CT_PLAN
  # Read-only controller requests must not inherit a handoff credential.
  unset HANDOFF_TOKEN
  HANDOFF_ALLOW_UNJOURNALED=true HANDOFF_LEDGER_UNAVAILABLE=false
  HANDOFF_TMP=$CT_TMP HANDOFF_CONTROLLER_RUN=$CT_RUN HANDOFF_CONTROLLER_HOST=$CT_HOST
  HANDOFF_REPO=$(identity_repository "$CT_ROOT") || return 3
  controller_lock || return $?
  controller_fault after-lock || return $?
  controller_check || return $?
  controller_foreign || return $?
  CT_STARTED=true
  if ! CT_RECORDS=$(ledger_read "$CT_PLAN" 2> "$CT_TMP/ledger-error"); then
    HANDOFF_LEDGER_UNAVAILABLE=true
    CT_RECORDS='[]' CT_CHAINS='[]' CT_SALVAGE_ONLY=true
    controller_worktree || return $?
    local reason=ledger-invalid
    if grep -q 'ledger too large' "$CT_TMP/ledger-error"; then reason=ledger-too-large; fi
    controller_hold "$CT_TRACKER" "$reason" "$(cat "$CT_TMP/ledger-error"); salvage: $(printf '%s' "$CT_OWNERSHIP" | jq -r '.ref//"none"')" || return $?
    result=10
  else
    controller_holds || return $?
    CT_CHAINS=$(ledger_chains "$CT_PLAN") || return 5
    controller_worktree || return $?
    controller_labels || return $?
    controller_open_state || return $?
    controller_plan_effect || return $?
    controller_unjournaled || return $?
    controller_check || return $?
    controller_foreign || { status=$?; [ "$status" -eq 10 ] || return "$status"; }
    if [ "$CT_FOREIGN_SEEN" = false ]; then
      controller_completed_effects || return $?
      # Holds stop launches; reconciliation still safely replays recorded decisions.
      controller_pending || return $?
    fi
    controller_check || return $?
    controller_foreign || { status=$?; [ "$status" -eq 10 ] || return "$status"; }
    controller_holds || return $?
    controller_repair "$CT_TRACKER" --labels-only hold-projection || return $?
    mkdir -p "$CT_COMMON/agentic-flow/state" || return 5
    handoff_write_cache "$CT_COMMON" "$HANDOFF_ISSUES" || return 5
    if [ "$CT_RAISED" = true ] || [ "$(printf '%s' "$CT_HOLDS" | jq length)" -gt 0 ] || printf '%s' "$CT_REPORT" | jq -e 'any(.issues[];.state=="escalated")' >/dev/null; then result=10; fi
    if [ "$result" -eq 0 ] && [ "$CT_RECOVER_CLAIM" = true ]; then controller_lock_publish || return 9; CT_LOCK_OWNED=true; fi
    if [ "$CT_PREVIOUS_HOST" != '' ] && [ "$result" -eq 0 ]; then
      jq -n --arg plan "$CT_PLAN" --arg host "$CT_HOST" --arg previous "$CT_PREVIOUS_HOST" --arg run "$CT_RUN" '{v:1,kind:"takeover",plan:$plan,host:$host,previous_host:$previous,run:$run,at:(now|floor)}' > "$CT_TMP/record"
      controller_record takeover || return 5
    fi
  fi
  local output
  printf '%s\n' "$CT_PENDING" > "$CT_TMP/pending"
  printf '%s\n' "$CT_OWNERSHIP" > "$CT_TMP/ownership"
  output=$(jq -n --arg plan "$CT_PLAN" --slurpfile report "$CT_TMP/report" --argjson holds "$CT_HOLDS" --argjson reasons "$CT_HOLD_REASONS" --slurpfile pending "$CT_TMP/pending" --argjson repairs "$CT_REPAIRS" --slurpfile ownership "$CT_TMP/ownership" \
    '$report[0] as $report | $pending[0] as $pending | $ownership[0] as $ownership | {plan:$plan,holds:$holds,raised:$reasons,pending:$pending,repairs:$repairs,ownership:$ownership,
      escalated:[$report.issues[]|select(.state=="escalated")|.number],
      status:(if any($report.issues[];(.topology=="tracker" or .topology=="work-standard") and .state=="closed") then "plan closed"
        elif all($report.issues[];if .topology=="step-strict" then .state=="approved" else .state=="closing" end) then "ready to ship" else "reconciled" end)}') || return 5
  if [ "$CT_JSON" = true ]; then printf '%s\n' "$output"
  else printf '%s' "$output" | jq -r '"Plan \(.plan): \(.status)",(.holds[]|"hold \(.id): \(.reason)"),(.raised[]|"hold #\(.issue): \(.reason)"),(.escalated[]|"escalated #\(.)"),(.repairs[]|"repaired #\(.issue): \(.kind)"),(.pending[]|"pending \(.head): \(.pending)"), (if .ownership!=null then "salvaged \(.ownership.ref)" else empty end)'; fi
  return "$result"
)
