#!/usr/bin/env bash
# Journal-driven recovery and bounded station dispatch.
# shellcheck disable=SC1091,SC2034 # Shared adapters consume the context globals.
. "$(dirname "${BASH_SOURCE[0]}")/handoff.sh"
. "$(dirname "${BASH_SOURCE[0]}")/brief.sh"
. "$(dirname "${BASH_SOURCE[0]}")/packet.sh"
. "$(dirname "${BASH_SOURCE[0]}")/config.sh"
. "$(dirname "${BASH_SOURCE[0]}")/probe.sh"
. "$(dirname "${BASH_SOURCE[0]}")/start.sh"
CONTROLLER_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CONTROLLER_RECOVERY="$CONTROLLER_LIB/recovery.pl"

controller_error() { printf 'controller: %s\n' "$*" >&2; }

controller_worktree_hint() { # An absent HEAD doc is a routing hint, not authority to run.
  local refs tip match='' size spec plan
  refs=$(git for-each-ref --count=1001 --format='%(objectname)' refs/heads/) || return 0
  [ "$(printf '%s\n' "$refs" | wc -l)" -le 1000 ] || return 0
  while IFS= read -r tip; do
    [ -n "$tip" ] && [ "$(git cat-file -t "$tip:$CT_DOC" 2>/dev/null)" = blob ] || continue
    [ -z "$match" ] || return 0
    match=$tip
  done <<< "$refs"
  [ -n "$match" ] || return 0
  size=$(git cat-file -s "$match:$CT_DOC") && [ "$size" -le 1048576 ] || return 0
  git show "$match:$CT_DOC" > "$CT_TMP/branch-doc" || return 0
  spec=$(brief_parse "$CT_TMP/branch-doc" "$CT_DOC" "$match" 2>/dev/null) || return 0
  plan=$(printf '%s' "$spec" | jq -er .id) || return 0
  controller_error "run from the plan worktree for $CT_DOC"
  printf '  cd %q\n' "$(plan_worktree_path "$CT_COMMON" "$plan")" >&2
}

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

controller_lock_check() { # Inspect the existing owner without writing to the lock.
  local owner pid start host current
  [ ! -L "$CT_LOCK" ] || return 5
  [ -f "$CT_LOCK/owner.json" ] && [ ! -L "$CT_LOCK/owner.json" ] && [ "$(wc -c < "$CT_LOCK/owner.json")" -le 4096 ] || return 5
  owner=$(cat "$CT_LOCK/owner.json") || return 5
  printf '%s' "$owner" | jq -e '(.pid|type)=="number" and .pid>0 and (.start|type)=="string" and (.host|test("^[a-f0-9]{12}$")) and (.run|type)=="string"' >/dev/null || return 5
  pid=$(printf '%s' "$owner" | jq -r .pid)
  start=$(printf '%s' "$owner" | jq -r .start)
  host=$(printf '%s' "$owner" | jq -r .host)
  if [ "$host" = "$CT_HOST" ]; then
    current=$(perl "$CONTROLLER_RECOVERY" process "$pid") || return 5
    if [ -n "$current" ] && [ "$current" = "$start" ]; then controller_error "controller already owns $CT_PLAN (pid $pid)"; return 9; fi
  elif [ "$CT_TAKE_OVER" = false ]; then controller_error "controller lock belongs to host $host"; return 9; fi
  printf '%s\n' "$owner"
}
controller_lock() {
  local owner
  mkdir -p "$CT_COMMON/agentic-flow/locks" || return 9
  [ ! -L "$CT_LOCK" ] || return 9
  if mkdir "$CT_LOCK" 2>/dev/null; then CT_LOCK_OWNED=true
  else
    owner=$(controller_lock_check) || return 9
    controller_claim "$owner" || return 9
    CT_PREVIOUS_HOST=$(printf '%s' "$owner" | jq -r .host)
    # Keep the old owner until reconciliation completes cleanly.
    return 0
  fi
  controller_lock_publish
}
controller_claim() { # A recovery claimant can itself crash; inspect its process too.
  local expected_owner=$1 owner pid start current
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
  [ -n "$start" ] || return 9
  jq -n --argjson pid "$CT_PID" --arg start "$start" '{pid:$pid,start:$start}' > "$CT_LOCK/recover/owner.json" || return 9
  [ "$(cat "$CT_LOCK/owner.json")" = "$expected_owner" ] || return 9
  CT_START=$start
}
controller_lock_publish() {
  local start
  start=$(perl "$CONTROLLER_RECOVERY" process "$CT_PID") || return 9
  [ -n "$start" ] || return 9
  jq -n --argjson pid "$CT_PID" --arg start "$start" --arg host "$CT_HOST" --arg run "$CT_RUN" \
    '{pid:$pid,start:$start,host:$host,run:$run}' > "$CT_LOCK/owner.tmp" || return 9
  mv "$CT_LOCK/owner.tmp" "$CT_LOCK/owner.json" || return 9
  CT_START=$start
}
controller_acknowledge() {
  [ -n "$CT_DETACH_NONCE" ] || return 0
  local dir="$CT_COMMON/agentic-flow/launches" tmp ownership=owner status=0
  [ "$CT_LOCK_OWNED" = true ] || ownership=recovering
  tmp=$(mktemp "$dir/.ack.XXXXXX") || return 5
  if ! { jq -nc --arg nonce "$CT_DETACH_NONCE" --arg plan "$CT_PLAN" --argjson pid "$CT_PID" \
    --arg start "$CT_START" --arg host "$CT_HOST" --arg run "$CT_RUN" --arg ownership "$ownership" '
    {v:1,nonce:$nonce,plan:$plan,pid:$pid,start:$start,host:$host,run:$run,ownership:$ownership,at:(now|floor)}' > "$tmp" &&
    [ "$(wc -c < "$tmp")" -le 1024 ] &&
    perl -e 'link($ARGV[0], $ARGV[1]) or die "controller acknowledgment: $!\n"' "$tmp" "$dir/$CT_DETACH_NONCE.json"
  }; then
    controller_error "could not publish startup acknowledgment for $CT_PLAN"
    status=5
  fi
  rm -f "$tmp"
  return "$status"
}
controller_heartbeat() { # phase [intent | waiting | exit]
  { [ "${CT_LOCK_OWNED:-false}" = true ] || [ "${CT_RECOVER_CLAIM:-false}" = true ]; } || return 0
  # Ownership flags also cover cleanup of partially published locks.
  [ -n "$CT_START" ] || return 0
  local phase=$1 ownership=owner intent=null timeout=null waiting=null exit_code=null dir target tmp=''
  [ "$CT_LOCK_OWNED" = true ] || ownership=recovering
  case "$phase" in
    station) intent=$2; timeout=$LAUNCH_TIMEOUT ;;
    waiting-human) waiting=$2 ;;
    stopped) exit_code=$2 ;;
  esac
  dir="$CT_COMMON/agentic-flow/state"
  target="$dir/$CT_PLAN.controller.json"
  if {
    mkdir -p "$dir" &&
    tmp=$(mktemp "$dir/.controller.XXXXXX") &&
    jq -nc --arg plan "$CT_PLAN" --arg doc "$CT_DOC" --argjson pid "$CT_PID" --arg start "$CT_START" \
      --arg host "$CT_HOST" --arg run "$CT_RUN" --arg ownership "$ownership" --arg phase "$phase" \
      --argjson turn "$CT_TURNS" --argjson turn_cap "$CT_TURN_CAP" --argjson intent "$intent" \
      --argjson timeout "$timeout" --argjson waiting "$waiting" --argjson exit "$exit_code" '
      {v:1,plan:$plan,doc:$doc,pid:$pid,start:$start,host:$host,run:$run,ownership:$ownership,
       phase:$phase,turn:$turn,turn_cap:$turn_cap,
       station:($intent|if .==null then null else {issue,step,station,cli,run,started,timeout_s:$timeout} end),
       waiting:$waiting,exit:$exit,updated_at:(now|floor)}' > "$tmp" &&
    [ "$(wc -c < "$tmp")" -le 4096 ] &&
    [ ! -d "$target" ] && mv -f "$tmp" "$target"
  } 2>/dev/null; then
    return 0
  fi
  [ -z "$tmp" ] || rm -f "$tmp" 2>/dev/null || true
  controller_error "warning: could not write heartbeat for $CT_PLAN" || true
}
controller_unlock() {
  if [ "$CT_LOCK_OWNED" = true ]; then rm -rf "$CT_LOCK"
  elif [ "$CT_RECOVER_CLAIM" = true ]; then rm -rf "$CT_LOCK/recover"; fi
  rm -rf "$CT_TMP"
}
controller_exit() {
  controller_heartbeat stopped "$1"
  controller_unlock
}
controller_foreign_rows() { # fresh foreign hosts, excluding those accepted at startup
  printf '%s' "$CT_REPORT" | jq -c --arg host "$CT_HOST" --argjson lease "$CT_LEASE" \
    --argjson started "$CT_STARTED" --argjson allowed "$CT_FOREIGN_ALLOWED" '
    .issues[]|select(.host!=null and .host!=$host and .latest_at!=null)|
    select((.latest_at|fromdateiso8601)>(now-$lease))|
    select(($started|not) or (. as $row | $allowed|index("\($row.number)/\($row.replay.seq)/\($row.host)")==null))'
}
controller_foreign() {
  local foreign number host seq row
  foreign=$(controller_foreign_rows) || return 5
  [ -n "$foreign" ] || return 0
  while IFS= read -r row; do
    number=$(printf '%s' "$row" | jq .number); host=$(printf '%s' "$row" | jq -r .host); seq=$(printf '%s' "$row" | jq .replay.seq)
    if [ "$CT_STARTED" = false ]; then
      if [ "$CT_TAKE_OVER" = false ]; then controller_error "foreign controller host $host on #$number; use --take-over"; return 9; fi
      CT_FOREIGN_ALLOWED=$(printf '%s' "$CT_FOREIGN_ALLOWED" | jq --arg key "$number/$seq/$host" '.+[$key]')
      CT_PREVIOUS_HOST=$host
    else
      CT_FOREIGN_SEEN=true
      controller_hold "$number" foreign-controller-host "Controller host changed to $host during reconciliation." || return $?
      return 10
    fi
  done <<< "$foreign"
}
controller_diagnostic() { # issue run cause-file -> bounded note
  if [ "${HANDOFF_LEDGER_UNAVAILABLE:-false}" = true ]; then
    printf '%s\n' "$CT_RECORDS" > "$CT_TMP/diagnostic-records"
  else ledger_read "$CT_PLAN" > "$CT_TMP/diagnostic-records" || return 5; fi
  ledger_backend diagnostic "$CT_PLAN" "$2" "$1" "$3" "$CT_TMP/diagnostic-records"
}
launch_output_record() { # hand over scratch output without a second disk copy
  [ -n "${LAUNCH_OUTPUT_DIR:-}" ] || return 0
  local status=0
  mv "$1" "$LAUNCH_OUTPUT_DIR/station-events" || status=$?
  mv "$2" "$LAUNCH_OUTPUT_DIR/station-stderr" || status=$?
  return "$status"
}
controller_store_output() { # run; retain each stream that reached the controller
  local run=$1 events='' stderr=''
  if [ -e "$CT_TMP/station-events" ] || [ -L "$CT_TMP/station-events" ]; then events="$CT_TMP/station-events"; fi
  if [ -e "$CT_TMP/station-stderr" ] || [ -L "$CT_TMP/station-stderr" ]; then stderr="$CT_TMP/station-stderr"; fi
  [ -n "$events$stderr" ] || return 0
  ledger_tails "$CT_PLAN" "$run" "$events" "$stderr" || return 5
  rm -f "$CT_TMP/station-events" "$CT_TMP/station-stderr"
}
controller_hold() { # issue reason paragraph [run]
  local number=$1 reason=$2 note=$3 run=${4:-none} rc=0
  printf '%s: %s\n' "$reason" "$note" > "$CT_TMP/hold-cause"
  controller_diagnostic "$number" "$run" "$CT_TMP/hold-cause" > "$CT_TMP/hold-note" || return 5
  handoff_transaction interactive "$number" hold --as approver --reason "$reason" --run "$run" --body-file "$CT_TMP/hold-note" > "$CT_TMP/hold-output" || rc=$?
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
          jq -n --arg plan "$CT_PLAN" --arg id "$id" --argjson rebaseline "$(printf '%s' "$item" | jq '.rebaseline//false')" '{v:1,kind:"clear",plan:$plan,hold:$id,by:"journal",note:"Recovered authorized clear",rebaseline:$rebaseline,at:(now|floor)}' > "$CT_TMP/record"
          ledger_clear "$CT_PLAN" "$CT_TMP/record" >/dev/null || return 5
        fi
      fi
    done < <(printf '%s' "$history" | jq -c '.[]')
    CT_RECORDS=$(ledger_read "$CT_PLAN") || return 5
  fi
  CT_HOLDS=$(hold_snapshot "$HANDOFF_ISSUE") || return 5
}
controller_wait_snapshot() {
  jq -nc --argjson holds "$CT_HOLDS" --slurpfile report "$CT_TMP/report" '
    {holds:([$holds[].id]|unique), reasons:([$holds[].reason]|unique),
     issues:([$report[0].issues[]|select(.state=="escalated")|.number]|unique),
     seqs:($report[0].issues|map({key:(.number|tostring),value:.replay.seq})|from_entries)}'
}
controller_wait_poll() { # called in a command substitution, with separate scratch files
  local baseline=$1 CT_TMP="$CT_TMP/wait-observation" foreign observed
  local HANDOFF_TMP=$CT_TMP
  controller_check || return $?
  controller_holds || return $?
  handoff_write_cache "$CT_COMMON" "$HANDOFF_ISSUES" || return 5
  foreign=$(controller_foreign_rows) || return 5
  observed=$(controller_wait_snapshot) || return 5
  jq -nc --argjson before "$baseline" --argjson after "$observed" --arg foreign "$foreign" '
    ($foreign!="") or ($before.seqs!=$after.seqs) or (($after.holds-$before.holds)|length>0) or
    (($after.holds|length)==0 and (($before.issues-$after.issues)==$before.issues))' || return 5
}
controller_wait_loop() { # initial observation; 0 requests a normal turn
  local baseline=$1 since until now next backoff=60 failed=0 waiting changed rc=0
  if [ "${AGENTIC_CONTROLLER_TESTING:-}" = 1 ] && [ -n "${AGENTIC_CONTROLLER_WAIT_BACKOFF_S:-}" ]; then
    backoff=$AGENTIC_CONTROLLER_WAIT_BACKOFF_S
    [[ "$backoff" =~ ^[1-9][0-9]{0,2}$ ]] && [ "$backoff" -le 900 ] || return 2
  fi
  mkdir -p "$CT_TMP/wait-observation" || return 5
  since=$(date +%s) || return 5
  until=$((since + CT_WAIT_S))
  while :; do
    now=$(date +%s) || return 5
    [ "$now" -lt "$until" ] || return 10
    next=$((now + backoff))
    [ "$next" -le "$until" ] || next=$until
    waiting=$(printf '%s' "$baseline" | jq -c --argjson since "$since" --argjson next "$next" \
      --argjson until "$until" --argjson failed "$failed" '. + {
        stop:(if (.holds|length)>0 then "hold" else "escalated" end),
        since:$since,next_poll_at:$next,until:$until,failed_polls:$failed}') || return 5
    controller_heartbeat waiting-human "$waiting"
    CT_CHILD_KIND='sleep'
    sleep "$((next - now))" &
    CT_CHILD=$!
    rc=0
    wait "$CT_CHILD" || rc=$?
    CT_CHILD=''
    [ "$rc" -eq 0 ] || return 5
    now=$(date +%s) || return 5
    [ "$now" -lt "$until" ] || return 10
    changed=$(controller_wait_poll "$baseline") || rc=$?
    case "$rc" in
      0) [ "$changed" != true ] || return 0; failed=0 ;;
      5) failed=$((failed + 1)); [ "$failed" -lt 3 ] || return 5 ;;
      *) return "$rc" ;;
    esac
    backoff=$((backoff * 2))
    [ "$backoff" -le 900 ] || backoff=900
  done
}
controller_wait_human() {
  [ "$CT_SALVAGE_ONLY" = false ] || return 10
  [ "$CT_TURNS" -lt "$CT_TURN_CAP" ] || return 10
  local resumable='["station-escalation","station-infrastructure","findings-incomplete","plan-effect-pending"]'
  local baseline rc=0
  # A non-resumable reason raised this turn already rules out a wait.
  printf '%s' "$CT_HOLD_REASONS" | jq -e --argjson allowed "$resumable" \
    'all(.[].reason; . as $reason | $allowed|index($reason)!=null)' >/dev/null || return 10
  controller_holds || return $?
  printf '%s' "$CT_HOLDS" | jq -e --argjson allowed "$resumable" --argjson raised "$CT_HOLD_REASONS" '
    . as $holds | all(.[].reason; . as $reason | $allowed|index($reason)!=null) and
    all($raised[]; . as $r | any($holds[]; .issue==$r.issue and .reason==$r.reason))' >/dev/null || return 10
  baseline=$(controller_wait_snapshot) || return 5
  printf '%s' "$baseline" | jq -e '(.holds|length)>0 or (.issues|length)>0' >/dev/null || return 10
  controller_wait_loop "$baseline" || rc=$?
  if [ "$rc" -ne 0 ]; then
    controller_heartbeat reconciling
    return "$rc"
  fi
  # Reconcile the state that woke the controller. Pending work is rebuilt by the turn.
  mv "$CT_TMP/wait-observation/report" "$CT_TMP/report" || return 5
  CT_REPORT=$(cat "$CT_TMP/report") || return 5
  CT_TRACKER=$(jq -r '.tracker//.issues[0].number' "$CT_TMP/report") || return 5
}
controller_repair() { # issue projection flag description
  local rc=0
  handoff_cmd "$1" reconcile "$2" --json > "$CT_TMP/repair-output" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  jq -e '.changed==true' "$CT_TMP/repair-output" >/dev/null || return 0
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
  local actual common branch owner run chain recorded snapshot saved count row result orphan=false hold_run=none rebaselines clear salvage_run
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
  rebaselines=$(printf '%s' "$CT_RECORDS" | jq -c '
    [.[]|select(.kind=="salvage")|.rebaseline//empty] as $saved |
    [.[]|select(.kind=="clear" and .rebaseline==true)|.hold|select(. as $id|($saved|index($id))==null)]') || return 5
  [ "$(printf '%s' "$snapshot" | jq .dirty)" = true ] || [ "$rebaselines" != '[]' ] || return 0
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
  # A clear is a one-shot authorization. Its id, rather than this controller's
  # invocation id, names the immutable ref, so a crash before the ledger append
  # recovers exactly that snapshot. Save it before adopting its HEAD/trees.
  while IFS= read -r clear; do
    salvage_run="$CT_PLAN/unowned/$(printf '%s' "$clear" | shasum -a 256 | cut -c1-24)"
    saved=$(perl "$CONTROLLER_RECOVERY" salvage "$CT_WORKTREE" "$salvage_run" "$CT_TMP/snapshot") || return 9
    controller_fault after-rebaseline-ref || return $?
    [ "$owner" != null ] || run=$salvage_run
    printf '%s' "$saved" | jq --arg run "$run" --arg chain "$chain" --argjson orphan "$orphan" --arg clear "$clear" '
      .+{v:1,kind:"salvage",run:$run,chain:(if $chain=="null" then null else $chain end),orphan:$orphan,rebaseline:$clear,at:(now|floor)}|del(.dirty)' > "$CT_TMP/record"
    controller_record salvage || return 5
    CT_RECORDS=$(ledger_read "$CT_PLAN") || return 5
  done < <(printf '%s' "$rebaselines" | jq -r '.[]')
  [ "$(printf '%s' "$snapshot" | jq .dirty)" = true ] || return 0
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
    # The approver explicitly adopted this unowned snapshot. New edits will
    # need a new clear, but replaying this baseline must not raise another hold.
    [ "$(printf '%s' "$saved" | jq -r '.rebaseline//empty')" = '' ] || return 0
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
  local item=$1 run intent station verify escalation outcome head body action number row reason='' step role subject
  local HANDOFF_REPLAY JOURNAL_TOPOLOGY JOURNAL_STEP JOURNAL_PLAN=$CT_PLAN JOURNAL_MAX_BOUNCES HANDOFF_CONTROLLER_RUN
  run=$(printf '%s' "$item" | jq -r .head)
  intent=$(printf '%s' "$CT_RECORDS" | jq -c --arg run "$run" '.[]|select(.kind=="intent" and .run==$run)')
  number=$(printf '%s' "$intent" | jq .issue)
  row=$(printf '%s' "$CT_REPORT" | jq -c --argjson n "$number" '.issues[]|select(.number==$n)')
  JOURNAL_MAX_BOUNCES=$(printf '%s' "$row" | jq -er .max_bounces) || return 3
  station=$(printf '%s' "$CT_RECORDS" | jq -c --arg run "$run" '[.[]|select(.kind=="station" and .run==$run)]|last//null')
  verify=$(printf '%s' "$CT_RECORDS" | jq -c --arg run "$run" '[.[]|select(.kind=="verify" and .run==$run)]|last//null')
  escalation=$(printf '%s' "$item" | jq -r '.escalation//""')
  [ "$run" != "$CT_REVIEWER_ESCALATE" ] || escalation='reviewer edited the worktree'
  if [ -n "$escalation" ]; then action=ask; head=none; reason=$escalation
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
  fi
  : > "$CT_TMP/diagnostic-body"
  printf '%s' "$station" | jq '.warnings//[]' > "$CT_TMP/decision-warnings" || return 5
  if [ -n "$reason" ]; then
    jq -n --arg question "$reason" '{v:1,question:$question}' > "$CT_TMP/decision-result" || return 5
  else
    printf '%s' "$station" | jq '.result' > "$CT_TMP/decision-result" || return 5
  fi
  if [ "$action" = ask ] || { [ "$action" = bounce ] && [ "$(printf '%s' "$row" | jq .replay.bounces)" -ge "$JOURNAL_MAX_BOUNCES" ]; }; then
    if [ "$action" = bounce ]; then printf 'bounce cap reached\n' > "$CT_TMP/decision-cause"
    else jq -r .question "$CT_TMP/decision-result" > "$CT_TMP/decision-cause" || return 5; fi
    controller_diagnostic "$number" "$run" "$CT_TMP/decision-cause" > "$CT_TMP/diagnostic-body" || return 5
  fi
  if [ "$action" = ask ] && ! printf '%s' "$row" | jq -e '.state=="executing" or .state=="reviewing"' >/dev/null; then
    controller_hold "$number" station-escalation "$(cat "$CT_TMP/diagnostic-body")" "$run" || return $?
    controller_end "$(printf '%s' "$intent" | jq -r .chain)" held || return 5
    return 0
  fi
  step=$(printf '%s' "$intent" | jq -r .step)
  role=$(printf '%s' "$intent" | jq -r .station)
  subject=$(printf '%s' "$CT_SPEC" | jq -r --arg step "$step" '.steps[]|select(.id==$step)|.title')
  subject=$(journal_subject "$step" "$subject")
  JOURNAL_STEP=$step
  JOURNAL_TOPOLOGY=$(printf '%s' "$row" | jq -r .topology)
  HANDOFF_REPLAY=$(printf '%s' "$row" | jq -c .replay)
  HANDOFF_CONTROLLER_RUN=$run
  handoff_render "$action" "$role" "$head" "$subject" "$CT_TMP/decision-result" "$CT_TMP/body" \
    "$CT_TMP/diagnostic-body" "$CT_TMP/decision-warnings" || return $?
  body=$(shasum -a 256 "$CT_TMP/body"); body=${body%% *}
  jq -n --arg run "$run" --arg action "$action" --arg head "$head" --arg file "$CT_TMP/body" --arg hash "$body" \
    '{v:1,kind:"decision",run:$run,action:$action,event:$action,head:$head,body_file:$file,body_sha256:$hash,body_format:"markdown-v1",at:(now|floor)}' > "$CT_TMP/record"
  controller_record decision || return 5
  controller_fault after-decision
}
controller_replay_handoff() { # Rule f: immutable body plus the original CAS position.
  local run=$1 intent decision number event role head after attempt rc=0 seq=null reason format
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
  format=$(printf '%s' "$decision" | jq -r '.body_format//"interactive"')
  if [ "$format" = interactive ]; then
    # Old decisions stored the run marker in the Markdown itself.
    sed '/^agentic-flow-run: run=/d' "$CT_TMP/replay-body" > "$CT_TMP/legacy-body" || return 5
    mv "$CT_TMP/legacy-body" "$CT_TMP/replay-body" || return 5
  fi
  HANDOFF_CONTROLLER_RUN=$run handoff_transaction "$format" "$number" "$event" --as "$role" --head "$head" \
    --after "$after" --body-file "$CT_TMP/replay-body" > "$CT_TMP/handoff-output" || rc=$?
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
      reason=illegal-transition; [ "$rc" -ne 7 ] || reason='plan-effect-pending'
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
      infrastructure)
        rc=0; controller_superseded "$item" || rc=$?
        case "$rc" in
          0) ;;
          1)
            local infrastructure_intent infrastructure_reason
            infrastructure_intent=$(printf '%s' "$CT_RECORDS" | jq -c --arg run "$run" '.[]|select(.kind=="intent" and .run==$run)')
            infrastructure_reason=$(printf '%s' "$CT_RECORDS" | jq -r --arg run "$run" '.[]|select(.kind=="station" and .run==$run)|.invalid_reason')
            controller_hold "$(printf '%s' "$infrastructure_intent" | jq .issue)" station-infrastructure "$infrastructure_reason" "$run" || return $? ;;
          *) return "$rc" ;;
        esac ;;
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
    case "$code" in 3) reason=illegal-transition ;; 7) reason='plan-effect-pending' ;; *) continue ;; esac
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

controller_gate() {
  local role
  [ "$REVIEW_IDENTITY_MODE" = distinct-account ] || { controller_error 'unattended run requires distinct-account'; return 6; }
  for role in executor reviewer approver; do
    identity_token "$CT_ROOT" "$role" --check >/dev/null || { controller_error "token $role --check failed"; return 6; }
  done
  ROLES_JSON=$CT_ASSIGNMENTS
  roles_same_model "$CT_ROOT" || return 6
  # Check launch readiness in the plan checkout at dispatch, where failures can
  # use the infrastructure hold path after the ledger has been loaded.
}
controller_finished() {
  printf '%s' "$CT_REPORT" | jq -e '
    any(.issues[];(.topology=="tracker" or .topology=="work-standard") and .state=="closed") or
    all(.issues[];if .topology=="step-strict" then .state=="approved" else .state=="closing" end)' >/dev/null
}
controller_head_valid() {
  local intent=$1 result=$2 row=$3 head base number
  head=$(printf '%s' "$result" | jq -r .head)
  case "$(printf '%s' "$result" | jq -r .outcome)" in
    ask) return 0 ;;
    approve|bounce) [ "$head" = "$(printf '%s' "$row" | jq -r .replay.submitted_head)" ]; return $? ;;
  esac
  base=$(printf '%s' "$intent" | jq -r .base_head); number=$(printf '%s' "$intent" | jq .issue)
  [ "$head" != "$base" ] && git merge-base --is-ancestor "$base" "$head" &&
    git merge-base --is-ancestor "$head" "refs/heads/$CT_BRANCH" &&
    [ "$head" != "$(printf '%s' "$row" | jq -r .replay.last_bounced_head)" ] &&
    git show -s --format=%B "$head" | grep -Eiq "(^|[[:space:]])Fixes #$number([^0-9]|$)"
}
controller_verify() {
  local run=$1 intent result row head status=green rc=0 reused=false selected command_plan key red_base
  intent=$(printf '%s' "$CT_RECORDS" | jq -c --arg run "$run" '.[]|select(.kind=="intent" and .run==$run)')
  result=$(printf '%s' "$CT_RECORDS" | jq -c --arg run "$run" '.[]|select(.kind=="station" and .run==$run)|.result')
  row=$(printf '%s' "$CT_REPORT" | jq -c --argjson n "$(printf '%s' "$intent" | jq .issue)" '.issues[]|select(.number==$n)')
  if ! controller_head_valid "$intent" "$result" "$row"; then
    controller_decide "$(jq -nc --arg run "$run" '{head:$run,escalation:"bad claimed head"}')"; return $?
  fi
  head=$(printf '%s' "$result" | jq -r .head)
  # A new chain after a human resume can start on already-implemented code.
  # Red-first always needs the step's original executor base; the current
  # intent base still governs ownership and whether the station advanced HEAD.
  red_base=$(printf '%s' "$CT_RECORDS" | jq -er --argjson intent "$intent" '
    [.[]|select(.kind=="intent" and .station=="executor" and
      .plan==$intent.plan and .issue==$intent.issue and .step==$intent.step)]|first|.base_head // empty') || return 5
  selected=$(printf '%s' "$CT_SPEC" | jq -c --arg s "$(printf '%s' "$intent" | jq -r .step)" '.steps[]|select(.id==$s)') || return 5
  command_plan=$(verify_record_plan "$selected") || return 5
  if key=$(cd "$CT_WORKTREE" && verify_record_key "$head" "$CT_DOC" "$(printf '%s' "$intent" | jq -r .step)" "$red_base" "$command_plan") &&
    verify_record_fresh "$CT_COMMON/agentic-flow/verify/$head.json" "$key" > "$CT_TMP/verify-output"; then
    reused=true
    : > "$CT_TMP/verify-tail"
  else
    CT_CHILD_KIND=verify
    (cd "$CT_WORKTREE" && exec scripts/agentic-flow verify-step "$head" --doc "$CT_DOC" --step "$(printf '%s' "$intent" | jq -r .step)" --red-base "$red_base" --json) > "$CT_TMP/verify-output" 2> "$CT_TMP/verify-tail" &
    CT_CHILD=$!
    wait "$CT_CHILD" || rc=$?
    CT_CHILD=''
  fi
  [ "$rc" -eq 0 ] || status=red
  ledger_output_tail "$CT_TMP/verify-tail" 16384 > "$CT_TMP/tail" || return 5
  jq -n --arg run "$run" --arg head "$head" --arg status "$status" --argjson reused "$reused" --arg record "$CT_COMMON/agentic-flow/verify/$head.json" --rawfile tail "$CT_TMP/tail" \
    '{v:1,kind:"verify",run:$run,head:$head,status:$status,reused:$reused,record:$record,tail:$tail,at:(now|floor)}' > "$CT_TMP/record"
  controller_record verify || return 5
  controller_fault after-verify
}
launch_session_record() {
  jq -n --arg run "$CT_ACTIVE_RUN" --arg session "$1" '{v:1,kind:"session",run:$run,session:$session,at:(now|floor)}' > "$CT_TMP/record"
  controller_record session || return 5
  controller_fault after-session
}
controller_interrupt() {
  if [ -n "$CT_CHILD" ]; then
    if [ "$CT_CHILD_KIND" = verify ] || [ "$CT_CHILD_KIND" = probe ] || [ "$CT_CHILD_KIND" = sleep ]; then
      kill -TERM "$CT_CHILD" 2>/dev/null || true
      wait "$CT_CHILD" 2>/dev/null || true
    else launch_abort "$CT_CHILD" "$CT_TMP/station-pgid"; fi
  fi
  exit "$1"
}
controller_result_valid() {
  local diagnostic
  CONTROLLER_RESULT_REASON='cannot validate station result'
  CONTROLLER_RESULT_WARNINGS='[]'
  diagnostic=$(perl "$LEDGER_HELPER" - result-check "$1" "$2") || return 1
  CONTROLLER_RESULT_REASON=$(printf '%s' "$diagnostic" | jq -r '.invalid_reason//""') || return 1
  CONTROLLER_RESULT_WARNINGS=$(printf '%s' "$diagnostic" | jq -c .warnings) || return 1
  [ -z "$CONTROLLER_RESULT_REASON" ]
}
controller_retry_context() { # pending run; evidence is included verbatim in the retry prompt
  printf '\nRecovery: %s\n' "$1"
  printf '%s\n' "$CT_RECORDS" | jq --arg run "$2" '
    [.[]|select(.run==$run and (.kind=="station" or .kind=="verify"))|
      if .kind=="station" then {invalid_reason,result:(.result|{outcome,head,summary})}
      else {status,tail} end]'
}
controller_probe() { # station; once mode never auto-probes
  [ "$CT_UNATTENDED" = true ] || return 0
  if probe_needed "$1" "$CT_WORKTREE"; then
    local probe_status=0
    CT_CHILD_KIND=probe
    probe_station "$1" "$CT_WORKTREE" > "$CT_TMP/probe.json" &
    CT_CHILD=$!
    wait "$CT_CHILD" || probe_status=$?
    CT_CHILD=''
    if [ "$probe_status" != 0 ]; then
      controller_hold "$CT_TRACKER" station-infrastructure "$(cat "$CT_TMP/probe.json")" || return $?
      return 10
    fi
  fi
  if ! launch_preflight "$1" "$CT_WORKTREE" > "$CT_TMP/preflight" 2>&1; then
    controller_hold "$CT_TRACKER" station-infrastructure "Launch preflight failed for $1: $(cat "$CT_TMP/preflight")" || return $?
    return 10
  fi
}

controller_retry_session() { # old intent fingerprint; set caller's resume/mode/from
  local old=$1 fingerprint=$2 candidate used
  if [ "$(printf '%s' "$old" | jq -r .cli)" != "$LAUNCH_CLI" ] || [ "$(printf '%s' "$old" | jq -r '.profile//""')" != "${LAUNCH_PROFILE#"$LAUNCH_ROOT"/}" ]; then
    mode=fresh-reassigned; from=$(printf '%s' "$old" | jq -r .cli)
    return 0
  fi
  candidate=$(printf '%s' "$CT_RECORDS" | jq -r --arg run "$(printf '%s' "$old" | jq -r .run)" '[.[]|select(.kind=="session" and .run==$run)]|last|.session//""')
  used=$(printf '%s' "$CT_RECORDS" | jq --arg run "$(printf '%s' "$old" | jq -r .run)" 'any(.[];.kind=="station" and .run==$run and ((.usage.input//0)>0 or (.usage.output//0)>0))')
  if [ "$(printf '%s' "$old" | jq -r '.fingerprint//""')" != "$fingerprint" ]; then mode=fresh-launcher-changed
  elif [ -z "$candidate" ] || [ "$used" != true ]; then mode=fresh-dead
  else resume=$candidate; mode=resume; fi
}
controller_prelaunch_failure() { # exit metadata captured-session (never a preassigned id)
  [ "$1" -ne 0 ] && [ -z "$3" ] && printf '%s' "$2" | jq -e '
    .seconds>=0 and .seconds<5 and (.usage.input//0)==0 and (.usage.output//0)==0' >/dev/null
}

controller_dispatch() {
  local item row station number step pending=initial replaces='' chain run seq gen nth=1 old=null resume='' mode=new from='' base hash session='' rc=0 invalid='' result=null metadata snapshot intent fingerprint captured launch_started scratch packet_status=0
  item=$(printf '%s' "$CT_PENDING" | jq -c '.[0]//null')
  if [ "$item" != null ]; then
    replaces=$(printf '%s' "$item" | jq -r .head); pending=$(printf '%s' "$item" | jq -r .pending)
    if [ "$pending" = verify ]; then
      controller_verify "$replaces" || return $?
      CT_STATIONS=$((CT_STATIONS+1))
      return 0
    fi
    old=$(printf '%s' "$CT_RECORDS" | jq -c --arg run "$replaces" '.[]|select(.kind=="intent" and .run==$run)')
    number=$(printf '%s' "$old" | jq .issue)
    row=$(printf '%s' "$CT_REPORT" | jq -c --argjson n "$number" '.issues[]|select(.number==$n)')
  else
    row=$(printf '%s' "$CT_SPEC" | jq -c --argjson report "$CT_REPORT" '[.steps[].id as $id|$report.issues[]|select(.step==$id and .state!="approved")]|.[0]//null')
    [ "$row" != null ] || return 3
    number=$(printf '%s' "$row" | jq .number)
  fi
  station=executor; [ "$(printf '%s' "$row" | jq -r .state)" != reviewing ] || station=reviewer
  step=$(printf '%s' "$row" | jq -r .step); seq=$(printf '%s' "$row" | jq .replay.seq)
  launch_assignment "$station" "$CT_ROOT" || return 6
  if [ "$LAUNCH_CLI" = manual ]; then
    controller_error "$station is manual: run it interactively"
    printf '  scripts/agentic-flow brief %s %s\n' "$CT_DOC" "$step" >&2
    printf '  scripts/agentic-flow packet %s --station %s\n' "$number" "$station" >&2
    printf '  scripts/agentic-flow verify-step <sha> --doc %s --step %s --red-base <base-sha>\n' "$CT_DOC" "$step" >&2
    printf '  scripts/agentic-flow handoff %s <submit|approve|bounce|ask> --as %s --head <sha>\n' "$number" "$station" >&2
    return 12
  fi
  if [ ! -d "$CT_WORKTREE" ]; then
    mkdir -p "${CT_WORKTREE%/*}" || return 9
    if git show-ref --verify --quiet "refs/heads/$CT_BRANCH"; then git worktree add "$CT_WORKTREE" "$CT_BRANCH" >&2 || return 9
    else git worktree add -b "$CT_BRANCH" "$CT_WORKTREE" HEAD >&2 || return 9; fi
  fi
  if [ "$(printf '%s' "$CT_OWNERSHIP" | jq -r '.restore_required//false')" = true ]; then
    git -C "$CT_WORKTREE" reset --hard HEAD >&2 && git -C "$CT_WORKTREE" clean -fd >&2 || return 9
  fi
  scratch=$(mktemp -d "$CT_TMP/station-scratch.XXXXXX") || return 5
  scratch=$(cd "$scratch" && pwd -P) || return 5
  {
    [ -z "$replaces" ] || controller_retry_context "$pending" "$replaces"
    printf '\nExisting HEAD: %s\nSalvaged edits: %s\n' "$(git -C "$CT_WORKTREE" rev-parse HEAD)" "$CT_OWNERSHIP"
  } > "$CT_TMP/packet-suffix" || return 5
  (cd "$CT_WORKTREE" && PACKET_FINDINGS_DIR="$scratch" PACKET_SUFFIX_FILE="$CT_TMP/packet-suffix" \
    scripts/agentic-flow packet "$number" --station "$station") > "$CT_TMP/packet" || packet_status=$?
  if [ "$packet_status" -eq 13 ]; then
    controller_hold "$number" findings-incomplete 'Cannot recover or deliver the full review findings.' || return $?
    return 10
  fi
  [ "$packet_status" -eq 0 ] || return "$packet_status"
  cat "$CT_TMP/packet-suffix" >> "$CT_TMP/packet" || return 5
  # Profiles and effective project config belong to the plan checkout. They may
  # differ from the caller's checkout or have changed during an earlier station.
  controller_probe "$station" || return $?
  launch_assignment "$station" "$CT_WORKTREE" || return 6
  fingerprint=$(launch_fingerprint "$station" "$CT_WORKTREE") || {
    [ "$CT_UNATTENDED" = true ] || return 6
    controller_hold "$number" station-infrastructure "Cannot fingerprint the $station launcher." || return $?
    return 10
  }
  if [ "$old" = null ]; then
    old=$(printf '%s' "$CT_RECORDS" | jq -c --argjson n "$number" --arg station "$station" '[.[]|select(.kind=="intent" and .issue==$n and .station==$station)]|last//null')
  fi
  if [ "$old" != null ]; then
    controller_retry_session "$old" "$fingerprint"
  fi
  if [ -n "$replaces" ]; then
    chain=$(printf '%s' "$item" | jq -r .chain)
    nth=$(printf '%s' "$CT_RECORDS" | jq --arg chain "$chain" '[.[]|select(.kind=="intent" and .chain==$chain)]|length+1')
    base=$(printf '%s' "$old" | jq -r .base_head)
  else
    gen=$(ledger_generation "$CT_PLAN" "$number" "$seq" "$station") || return 5
    chain="$CT_PLAN/$number/$seq/$station/$gen"
    base=$(git -C "$CT_WORKTREE" rev-parse HEAD) || return 9
  fi
  controller_fault before-launch || return $?
  controller_worktree || return $?
  [ "$CT_RAISED" = false ] || return 10
  run="$chain/$nth"; CT_ACTIVE_RUN=$run
  # Codex and OpenCode create their own session; a caller-chosen OpenCode id is created
  # without the user's provider and hits the free-tier limit. Record theirs from the events.
  if [ -z "$resume" ] && [ "$LAUNCH_CLI" = claude ]; then session=$(perl -e 'printf "%08x-%04x-4%03x-8%03x-%012x",time,int(rand(65536)),int(rand(4096)),int(rand(4096)),int(rand(2**48))'); fi
  hash=$(shasum -a 256 "$CT_TMP/packet"); hash=${hash%% *}
  jq -n --arg run "$run" --arg chain "$chain" --arg replaces "$replaces" --arg reason "$pending" --arg plan "$CT_PLAN" --argjson number "$number" --arg step "$step" --arg station "$station" \
    --arg cli "$LAUNCH_CLI" --arg model "$LAUNCH_MODEL" --arg profile "${LAUNCH_PROFILE#"$LAUNCH_ROOT"/}" --arg contract "$LAUNCH_CONTRACT_MODE" --arg fingerprint "$fingerprint" --arg resume "$resume" --arg session "$session" --arg mode "$mode" --arg from "$from" --argjson seq "$seq" --arg base "$base" --arg hash "$hash" --arg host "$CT_HOST" \
    '{v:1,kind:"intent",run:$run,chain:$chain,replaces:(if $replaces=="" then null else $replaces end),reason:$reason,plan:$plan,issue:$number,step:$step,station:$station,cli:$cli,model:$model,profile:$profile,contract_mode:$contract,fingerprint:$fingerprint,resume_of:(if $resume=="" then null else $resume end),session:(if $session=="" then null else $session end),session_mode:$mode,reassigned_from:(if $from=="" then null else $from end),seq_before:$seq,base_head:$base,packet_sha256:$hash,host:$host,started:(now|floor)}' > "$CT_TMP/record"
  intent=$(cat "$CT_TMP/record")
  controller_record intent || return 5
  if [ -n "$replaces" ]; then controller_fault after-replacement-intent || return $?; fi
  controller_fault after-intent || return $?
  LAUNCH_STEP=$step LAUNCH_ISSUE=$number LAUNCH_SESSION=$session
  LAUNCH_RESUME_CLI=$LAUNCH_CLI LAUNCH_RESUME_PROFILE="${LAUNCH_PROFILE#"$LAUNCH_ROOT"/}"
  LAUNCH_PGID_FILE="$CT_TMP/station-pgid"
  local LAUNCH_OUTPUT_DIR=$CT_TMP
  local LAUNCH_SCRATCH=$scratch
  CT_CHILD_KIND=station
  rm -f "$LAUNCH_PGID_FILE"
  : > "$CT_TMP/result"
  launch_started=$(date +%s)
  controller_heartbeat station "$intent"
  if [ -n "$resume" ]; then launch_station "$station" "$CT_WORKTREE" "$CT_TMP/packet" "$CT_TMP/result" --resume "$resume" > "$CT_TMP/launched" 2> "$CT_TMP/launch-stderr" &
  else launch_station "$station" "$CT_WORKTREE" "$CT_TMP/packet" "$CT_TMP/result" > "$CT_TMP/launched" 2> "$CT_TMP/launch-stderr" & fi
  CT_CHILD=$!
  wait "$CT_CHILD" || rc=$?
  CT_CHILD=''
  controller_heartbeat reconciling
  cat "$CT_TMP/launch-stderr" >&2
  CT_STATIONS=$((CT_STATIONS+1))
  # A supervised preflight refusal keeps its historical exit 6. An actual
  # station exit (which has metadata) must still be classified below.
  if [ "$rc" -eq 6 ] && [ ! -s "$CT_TMP/launched" ]; then
    [ "$CT_UNATTENDED" = true ] || return 6
    # Keep stderr bounded and redact before selecting the last lines. The
    # diagnostic formatter retains the cause, timing, tail and hold-clear path.
    ledger_output_tail "$CT_TMP/launch-stderr" 65536 > "$CT_TMP/preflight-tail" || return 5
    printf 'Launch preflight failed before station start. Exit: %s; seconds: %s.\n' "$rc" "$(($(date +%s)-launch_started))" > "$CT_TMP/preflight-cause"
    tail -n 20 "$CT_TMP/preflight-tail" >> "$CT_TMP/preflight-cause"
    controller_hold "$number" station-infrastructure "$(cat "$CT_TMP/preflight-cause")" "$run" || return $?
    return 10
  fi
  # A failed session callback aborts before any station record is published.
  if [ "${AGENTIC_CONTROLLER_TESTING:-}" = 1 ] && [ "${AGENTIC_CONTROLLER_FAULT:-}" = after-session ] && [ "$rc" -ne 0 ]; then return 5; fi
  controller_fault after-launch || return $?
  [ "$(git -C "$CT_WORKTREE" symbolic-ref --quiet --short HEAD)" = "$CT_BRANCH" ] || { controller_hold "$number" station-changed-branch 'Station changed the plan worktree branch.' "$run"; return 10; }
  metadata=$(jq 'del(.result)' "$CT_TMP/launched") || metadata=''
  if ! printf '%s' "$metadata" | jq -e 'type=="object" and (.seconds|type)=="number" and (.usage|type)=="object"' >/dev/null 2>&1; then
    metadata=$(jq -nc --argjson seconds "$(($(date +%s)-launch_started))" '{seconds:$seconds,usage:{input:null,output:null,cost_usd:null}}')
  fi
  CT_RECORDS=$(ledger_read "$CT_PLAN") || return 5
  captured=$(printf '%s' "$CT_RECORDS" | jq -r --arg run "$run" '[.[]|select(.kind=="session" and .run==$run)]|last|.session//""')
  # Claude's caller-chosen id alone is not evidence of a live session. Persist
  # the session actually reported by its events, as for the other CLIs.
  if [ -z "$captured" ]; then
    captured=$(printf '%s' "$metadata" | jq -r '.session//""')
    if [ -n "$captured" ]; then launch_session_record "$captured" || return 5; fi
  fi
  if controller_result_valid "$station" "$CT_TMP/result"; then result=$(cat "$CT_TMP/result")
  else
    invalid=$CONTROLLER_RESULT_REASON
    printf 'null\n' > "$CT_TMP/result"
  fi
  [ "$rc" -eq 0 ] || invalid="station exit $rc"
  snapshot=$(perl "$CONTROLLER_RECOVERY" snapshot "$CT_WORKTREE") || return 9
  if [ "$result" != null ] && [ "$(printf '%s' "$result" | jq -r .outcome)" = submitted ] && [ "$(printf '%s' "$snapshot" | jq .dirty)" = true ]; then invalid='uncommitted changes after submit'; fi
  if [ "$result" != null ] && [ -z "$invalid" ] && ! controller_head_valid "$intent" "$result" "$row"; then
    invalid='bad claimed head'
  fi
  if controller_prelaunch_failure "$rc" "$metadata" "$captured"; then
    invalid="pre-launch failure: exit $rc; seconds $(printf '%s' "$metadata" | jq .seconds)"
  fi
  jq -n --arg run "$run" --argjson exit "$rc" --argjson meta "$metadata" --slurpfile result "$CT_TMP/result" --arg invalid "$invalid" --argjson warnings "$CONTROLLER_RESULT_WARNINGS" \
    '{v:1,kind:"station",run:$run,exit:$exit,seconds:$meta.seconds,usage:$meta.usage,result:$result[0],warnings:$warnings,invalid_reason:(if $invalid=="" then null else $invalid end),ended:(now|floor)}' > "$CT_TMP/record" || return 5
  controller_record station || return 5
  controller_store_output "$run" || return 5
  controller_fault after-station
}

controller_cmd() (
  set +x
  local entry=$1; shift
  local doc=${1:-} reconcile=false once=false detach=false CT_TAKE_OVER=false CT_JSON=false CT_WAIT_S=0
  local CT_DETACH_NONCE=${AGENTIC_DETACH_NONCE-}
  [ "$#" -ge 1 ] || return 2; shift
  local forward=("$doc")
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --once) once=true ;;
      --reconcile-only) reconcile=true ;;
      --take-over) CT_TAKE_OVER=true ;;
      --json) CT_JSON=true ;;
      --detach) detach=true; shift; continue ;;
      --wait-human)
        [ "$CT_WAIT_S" -eq 0 ] || return 2
        CT_WAIT_S=86400
        forward+=("$1")
        shift
        case "${1:-}" in
          ''|-*) continue ;;
          *)
            [[ "$1" =~ ^[1-9][0-9]{0,5}$ ]] && [ "$1" -le 604800 ] || return 2
            CT_WAIT_S=$1 ;;
        esac ;;
      *) return 2 ;;
    esac
    forward+=("$1")
    shift
  done
  if [ "$CT_WAIT_S" -ne 0 ] && { [ "$once" = true ] || [ "$reconcile" = true ]; }; then return 2; fi
  case "$doc" in docs/inprogress/*.md) ;; *) return 2 ;; esac
  case "$doc" in *'/../'*|*'/./'*|*[!A-Za-z0-9_./-]*) return 2 ;; esac
  if [ "${AGENTIC_DETACH_NONCE+x}" ]; then
    [[ "$CT_DETACH_NONCE" =~ ^[a-f0-9]{32}$ ]] && [ "$detach" = false ] || return 2
    unset AGENTIC_DETACH_NONCE
  fi
  case "$entry" in /*) ;; *) entry="$PWD/$entry" ;; esac
  local CT_DOC=$doc CT_ASSIGNMENTS='' CT_STATIONS=0 CT_ACTIVE_RUN='' CT_TURNS=0 CT_TURN_CAP CT_CHILD='' CT_CHILD_KIND=station CT_UNATTENDED=false
  [ "$once" = true ] || CT_UNATTENDED=true
  local CT_ROOT CT_COMMON CT_TMP CT_PLAN CT_BRANCH CT_SPEC CT_REPORT CT_TRACKER CT_RECORDS CT_CHAINS CT_CONTEXT='{}' CT_PENDING='[]'
  local CT_LOCK='' CT_LOCK_OWNED=false CT_RECOVER_CLAIM=false CT_START='' CT_PREVIOUS_HOST='' CT_STARTED=false CT_FOREIGN_ALLOWED='[]' CT_FOREIGN_SEEN=false
  local CT_HOLDS='[]' CT_HOLD_REASONS='[]' CT_REPAIRS='[]' CT_RAISED=false CT_OWNERSHIP=null CT_REVIEWER_ESCALATE='' CT_REVIEWER_RELAUNCH='' CT_SNAPSHOT='{}' CT_SALVAGE_ONLY=false
  local CT_HOST CT_PID CT_RUN CT_WORKTREE CT_LEASE=${AGENTIC_CONTROLLER_LEASE:-21600} approval rev dirty status=0 result=0
  [[ "$CT_LEASE" =~ ^[1-9][0-9]{0,6}$ ]] || return 2
  CT_ROOT=$(git rev-parse --show-toplevel) || return 3
  cd "$CT_ROOT" || return 3
  config_load "$CT_ROOT" || return $?
  CT_TURN_CAP=$(config_get controller.turn_cap) || return 2
  CT_COMMON=$(git rev-parse --git-common-dir) && CT_COMMON=$(cd "$CT_COMMON" && pwd -P) || return 3
  CT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/agentic-controller.XXXXXX") || return 5
  trap 'controller_exit "$?"' EXIT
  trap 'controller_interrupt 130' INT
  trap 'controller_interrupt 143' TERM
  if ! git show "HEAD:$doc" > "$CT_TMP/head-doc"; then
    controller_worktree_hint
    return 3
  fi
  [ "$(wc -c < "$CT_TMP/head-doc")" -le 1048576 ] || return 3
  approval=$(brief_approval "$CT_TMP/head-doc") || return 3; rev=${approval%%$'\t'*}
  brief_approved_at_head "$doc" "$rev" || return 3
  git show "$rev:$doc" > "$CT_TMP/doc" || return 3
  CT_SPEC=$(brief_parse "$CT_TMP/doc" "$doc" "$rev") || return 3
  CT_PLAN=$(printf '%s' "$CT_SPEC" | jq -r .id); CT_BRANCH=$(printf '%s' "$CT_SPEC" | jq -r .branch)
  git check-ref-format "refs/heads/$CT_BRANCH" || return 3
  CT_LOCK="$CT_COMMON/agentic-flow/locks/controller-$CT_PLAN"
  if [ "$detach" = true ]; then
    if [ -e "$CT_LOCK" ]; then
      local precheck=0
      CT_HOST=$(perl "$CONTROLLER_RECOVERY" host "$CT_COMMON") || return 9
      controller_lock_check >/dev/null || precheck=$?
      [ "$precheck" -ne 9 ] || return 9
    fi
    rm -rf "$CT_TMP" || return 5
    exec perl "$CONTROLLER_LIB/controller-detach.pl" "$CT_COMMON/agentic-flow" "$CT_PLAN" "$CT_JSON" \
      "$BASH" "$entry" run "${forward[@]}"
  fi
  CT_WORKTREE=$(plan_worktree_path "$CT_COMMON" "$CT_PLAN")
  if [ "$CT_ROOT" -ef "$CT_WORKTREE" ]; then
    [ "$(git symbolic-ref --quiet HEAD)" = "refs/heads/$CT_BRANCH" ] || {
      controller_error 'plan worktree ownership differs'; return 9;
    }
    # A planner starting here must commit their edits before controller recovery runs.
    dirty=$(GIT_OPTIONAL_LOCKS=0 git status --porcelain --untracked-files=all --ignore-submodules=none) || return 9
    if [ -n "$dirty" ]; then
      controller_error "plan worktree is dirty: $CT_WORKTREE"
      printf '%s\n' "$dirty" >&2
      return 3
    fi
  fi
  workflow_load "$CT_ROOT" && read_review_policy "$CT_ROOT" || return 3
  [ -n "$REVIEW_OWNER" ] || { controller_error 'owner= is required for the controller'; return 3; }
  ledger_init "$CT_ROOT" || return 3
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
  controller_acknowledge || return $?
  controller_heartbeat reconciling
  controller_fault after-lock || return $?
  controller_check || return $?
  controller_foreign || return $?
  CT_STARTED=true
  if [ "$reconcile" = false ]; then
    roles_load "$CT_ROOT" || return 6
    CT_ASSIGNMENTS=$ROLES_JSON
    if [ "$once" = false ]; then controller_gate || return 6; fi
  fi
  local resumed_turn=false
  while :; do
    while :; do
      controller_heartbeat reconciling
      CT_RAISED=false CT_HOLD_REASONS='[]' CT_REVIEWER_ESCALATE='' CT_REVIEWER_RELAUNCH=''
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
        if [ "$reconcile" = false ] && [ -n "$CT_REVIEWER_ESCALATE" ]; then
          # Preserve the second reviewer violation in salvage, then remove its edits
          # before escalating so a human resume can return to a clean review tree.
          git -C "$CT_WORKTREE" reset --hard HEAD >&2 && git -C "$CT_WORKTREE" clean -fd >&2 || return 9
          CT_OWNERSHIP=$(printf '%s' "$CT_OWNERSHIP" | jq '.restore_required=false')
        fi
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
        if [ "$result" -eq 0 ] && [ "$CT_RECOVER_CLAIM" = true ]; then
          controller_lock_publish || return 9
          CT_LOCK_OWNED=true CT_RECOVER_CLAIM=false
          controller_heartbeat reconciling
        fi
        if [ "$CT_PREVIOUS_HOST" != '' ] && [ "$result" -eq 0 ]; then
          jq -n --arg plan "$CT_PLAN" --arg host "$CT_HOST" --arg previous "$CT_PREVIOUS_HOST" --arg run "$CT_RUN" '{v:1,kind:"takeover",plan:$plan,host:$host,previous_host:$previous,run:$run,at:(now|floor)}' > "$CT_TMP/record"
          controller_record takeover || return 5
          CT_PREVIOUS_HOST=''
        fi
      fi
      [ "$result" -eq 0 ] && [ "$reconcile" = false ] || break
      if [ "$once" = true ] && [ "$CT_STATIONS" -ge 1 ]; then
        # Finish deterministic result processing, including verification, before exit.
        if ! printf '%s' "$CT_PENDING" | jq -e 'any(.[];.pending=="verify")' >/dev/null; then break; fi
      fi
      if controller_finished; then break; fi
      if [ "$resumed_turn" = true ]; then
        resumed_turn=false
      else
        if [ "$CT_TURNS" -ge "$CT_TURN_CAP" ]; then
          controller_hold "$CT_TRACKER" turn-cap "Controller reached the $CT_TURN_CAP-turn cap." || return $?
          result=10; break
        fi
        CT_TURNS=$((CT_TURNS+1))
      fi
      controller_dispatch || { result=$?; break; }
    done
    [ "$result" -eq 10 ] && [ "$CT_WAIT_S" -ne 0 ] || break
    result=0
    controller_wait_human || { result=$?; break; }
    # A resumed reconcile consumes a turn even when it stops before dispatch.
    CT_TURNS=$((CT_TURNS+1))
    resumed_turn=true
  done
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
