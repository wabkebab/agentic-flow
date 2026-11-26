#!/usr/bin/env bash
# Andon markers are separate from the transition journal. Caller holds the plan lock.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/ledger.sh"
. "$(dirname "${BASH_SOURCE[0]}")/journal-comment.sh"
. "$(dirname "${BASH_SOURCE[0]}")/journal.sh" # journal_jq, used by the hold counter below

andon_desktop() {
  if command -v osascript >/dev/null 2>&1; then
    review_bounded osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "agentic-flow"' -e 'end run' "$1" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    review_bounded notify-send -- agentic-flow "$1" >/dev/null 2>&1 || true
  fi
}
hold_replay() { # normalized comments on stdin; plan -> open authorized markers
  # shellcheck disable=SC2016 # jq variables
  journal_jq --arg mode "${2:-open}" --arg plan "$1" --arg approvers "$REVIEW_APPROVERS" '
    include "journal-marker";
    if type!="array" or length>100 then error("invalid hold thread") else . end |
    reduce .[] as $c ({holds:[],cleared:[]};
      if ($approvers|split(" ")|index($c.author))==null then . else
        ($c.body|journal_marker_line) as $line |
        if ($line|startswith("agentic-flow-hold: ")) then
          ([try ($line|capture("^agentic-flow-hold: v=1; id=(?<plan>[a-z0-9][a-z0-9._-]*)/hold/(?<n>[1-9][0-9]{0,5}); issue=#(?<issue>[1-9][0-9]{0,9}); reason=(?<reason>[a-z0-9][a-z0-9-]{0,79}); run=(?<run>[a-zA-Z0-9/._-]+)$"))]|first) as $h |
          if $h==null or $h.plan!=$plan then . else
            ($h+{id:($h.plan+"/hold/"+$h.n),issue:($h.issue|tonumber),comment_id:$c.dbid}) as $h |
            if any(.holds[];.id==$h.id) then . else .holds+=[$h] end
          end
        elif ($line|startswith("agentic-flow-hold-clear: id=")) then
          ([try ($line|capture("^agentic-flow-hold-clear: id=(?<id>[a-z0-9][a-z0-9._-]*/hold/[1-9][0-9]{0,5})(?<flag>; rebaseline=true)?$"))]|first) as $clear |
          if $clear!=null and any(.holds[];.id==$clear.id) and all(.cleared[];.id!=$clear.id)
          then .cleared+=[{id:$clear.id,rebaseline:($clear.flag=="; rebaseline=true")}] else . end
        else . end
      end) | . as $s | [.holds[]|.id as $id|([$s.cleared[]|select(.id==$id)]|first) as $clear |
        . + {cleared:($clear!=null),rebaseline:($clear.rebaseline//false)}|select($mode=="all" or (.cleared|not))]'
}

hold_snapshot() { # remote issue JSON -> remote and local-only open holds
  local issue=$1 remote records history
  remote=$(printf '%s' "$issue" | jq .comments.nodes | journal_normalize | hold_replay "$HANDOFF_PLAN") || return 5
  history=$(printf '%s' "$issue" | jq .comments.nodes | journal_normalize | hold_replay "$HANDOFF_PLAN" all) || return 5
  ledger_init "$HANDOFF_ROOT" || return 5
  if [ "${HANDOFF_LEDGER_UNAVAILABLE:-false}" = true ]; then records='[]'; else records=$(ledger_read "$HANDOFF_PLAN") || return 5; fi
  printf '%s' "$records" | jq --argjson history "$history" --argjson remote "$remote" '
    . as $records |
    ([ $records[]|select(.kind=="clear")|.hold] + [$history[]|select(.cleared)|.id]) as $cleared |
    $remote + [$records[]|select(.kind=="hold" and .comment_id==null) |
      select(.hold as $id|($cleared|index($id))==null and all($remote[];.id!=$id)) |
      {id:.hold,issue,reason,run:(.run//"none"),comment_id:null}] | unique_by(.id)'
}

handoff_comment() { # number body-file; post, then verify returned comment and author
  local number=$1 file=$2 posted rc=0 dbid comment
  posted=$(handoff_gh issue comment "$number" --repo "$HANDOFF_REPO" --body-file "$file") || rc=$?
  dbid=${posted##*#issuecomment-}
  [[ "$dbid" =~ ^[0-9]+$ ]] || dbid=''
  handoff_read "$number" || return $?
  comment=$(printf '%s' "$HANDOFF_ISSUE" | jq -c --rawfile body "$file" --arg dbid "$dbid" '
    [.comments.nodes[]|select((.body|sub("\n+$";""))==($body|sub("\n+$";"")))|select($dbid=="" or (.fullDatabaseId|tostring)==$dbid)]|last//empty') || return 5
  [ -n "$comment" ] || { handoff_error "comment not found after post (status $rc)"; return 5; }
  [ "$(printf '[%s]' "$comment" | journal_normalize | jq -r '.[0].author')" = "$HANDOFF_LOGIN" ] || {
    handoff_error 'posted comment author differs from role identity'; return 5;
  }
  HANDOFF_COMMENT_ID=$(printf '%s' "$comment" | jq -r .fullDatabaseId)
}

hold_record() { # plan id issue reason run comment_id; imports journal holds before clear
  local plan=$1 id=$2 records file="$HANDOFF_TMP/hold-record"
  [ "${HANDOFF_LEDGER_UNAVAILABLE:-false}" != true ] || return 0
  ledger_init "$HANDOFF_ROOT" || return 5
  records=$(ledger_read "$plan") || return 5
  if ! printf '%s' "$records" | jq -e --arg id "$id" 'any(.[];.kind=="hold" and .hold==$id)' >/dev/null; then
    jq -n --arg plan "$plan" --arg id "$id" --argjson issue "$3" --arg reason "$4" --arg run "$5" --arg cid "$6" '
      {v:1,kind:"hold",plan:$plan,hold:$id,issue:$issue,reason:$reason,run:(if $run=="none" then null else $run end),comment_id:(if $cid=="null" then null else ($cid|tonumber) end),at:(now|floor)}' > "$file" || return 5
    ledger_hold "$plan" "$file" || return 5
  fi
}

hold_transition() { # affected issue event reason run hold-id note [rebaseline]
  local issue=$1 event=$2 reason=$3 run=$4 id=$5 note=$6 rebaseline=${7:-false} tracker holds match n file="$HANDOFF_TMP/hold-comment" records marker='' subject
  handoff_plan_read || return $?
  tracker=$HANDOFF_TRACKER
  if [ -z "$tracker" ]; then
    handoff_read "$issue" || return $?
    [ "$JOURNAL_TOPOLOGY" = work-standard ] || return 3
    tracker=$issue
  fi
  # shellcheck disable=SC2034 # Returned to handoff_cmd.
  HANDOFF_HOLD_TRACKER=$tracker
  handoff_read "$tracker" || return $?
  subject=$(journal_subject "$JOURNAL_STEP" "$(jq -r '.title//""' <<< "$HANDOFF_ISSUE")")
  holds=$(hold_snapshot "$HANDOFF_ISSUE") || return 5
  if [ "$event" = hold ]; then
    if [ "$run" != none ]; then
      local run_pattern='^([a-z0-9][a-z0-9._-]*)/[1-9][0-9]{0,8}/[0-9]{1,9}/(executor|reviewer)/[1-9][0-9]{0,8}/[1-9][0-9]{0,8}$'
      [[ "$run" =~ $run_pattern ]] && [ "${BASH_REMATCH[1]}" = "$HANDOFF_PLAN" ] || return 2
    fi
    [[ "$reason" =~ ^[a-z0-9][a-z0-9-]{0,79}$ ]] && [ "${#run}" -le 512 ] && [[ "$run" =~ ^[a-zA-Z0-9/._-]+$ ]] || return 2
    match=$(printf '%s' "$holds" | jq -c --argjson issue "$issue" --arg reason "$reason" '[.[]|select(.issue==$issue and .reason==$reason)]|first//empty') || return 5
    if [ -n "$match" ]; then
      id=$(printf '%s' "$match" | jq -r .id) || return 5
      if [ "$(printf '%s' "$match" | jq -r .comment_id)" != null ]; then
        printf 'hold %s already open\n' "$id"
        return 0
      fi
    else
      ledger_init "$HANDOFF_ROOT" || return 5
      if [ "${HANDOFF_LEDGER_UNAVAILABLE:-false}" = true ]; then records='[]'; else records=$(ledger_read "$HANDOFF_PLAN") || return 5; fi
      printf '%s\n' "$HANDOFF_ISSUE" > "$HANDOFF_TMP/hold-tracker" || return 5
      # shellcheck disable=SC2016 # jq variables
      n=$(printf '%s' "$records" | journal_jq --slurpfile tracker "$HANDOFF_TMP/hold-tracker" --arg p "$HANDOFF_PLAN" '
        include "journal-marker";
        . as $records | [($records[]|select(.kind=="hold")|.hold),($tracker[0].comments.nodes[].body|journal_marker_line|try capture("^agentic-flow-hold: v=1; id=(?<id>[^;]+);").id)] |
        [.[]|select(startswith($p+"/hold/"))|split("/")[-1]|try tonumber] | (max//0)+1') || return 5
      [ "$n" -le 999999 ] || return 5
      id="$HANDOFF_PLAN/hold/$n"
    fi
    if ! handoff_identity approver; then
      if [ -n "$match" ]; then
        printf 'hold %s already open (local-only)\n' "$id"
        return 10
      fi
      hold_record "$HANDOFF_PLAN" "$id" "$issue" "$reason" "$run" null || return 5
      andon_desktop "$reason"
      handoff_error "hold $id: approver unavailable; run agentic-flow handoff $issue hold --as approver --reason $reason where the approver identity exists"
      return 10
    fi
    marker="agentic-flow-hold: v=1; id=$id; issue=#$issue; reason=$reason; run=$run"
    printf '%s' "$note" > "$file.note" || return 5
    note=$(ledger_comment_redact "$file.note") || return 5
    journal_summary "$note" > "$file.result" || return 5
    journal_render hold "$subject" "$marker" \
      "Issue: #$issue · Reason: $reason" "$(journal_run_marker)" "$file.result" "${REVIEW_OWNER:-}" "$reason" > "$file" || return $?
    handoff_comment "$tracker" "$file" || return $?
    hold_record "$HANDOFF_PLAN" "$id" "$issue" "$reason" "$run" "$HANDOFF_COMMENT_ID" || return 5
    if [ -z "$match" ]; then andon_desktop "$reason"; fi
  else
    [ "${#note}" -le 1200 ] || return 2
    match=$(printf '%s' "$holds" | jq -c --arg id "$id" '[.[]|select(.id==$id)]|first//empty') || return 5
    if [ -z "$match" ]; then
      match=$(printf '%s' "$HANDOFF_ISSUE" | jq .comments.nodes | journal_normalize | hold_replay "$HANDOFF_PLAN" all | jq -c --arg id "$id" '[.[]|select(.id==$id)]|first//empty') || return 5
      if [ -z "$match" ]; then
        if [ "${HANDOFF_LEDGER_UNAVAILABLE:-false}" = true ]; then records='[]'; else records=$(ledger_read "$HANDOFF_PLAN") || return 5; fi
        printf '%s' "$records" | jq -e --arg id "$id" 'any(.[];.kind=="clear" and .hold==$id)' >/dev/null && return 0
        handoff_error "unknown hold: $id"; return 3
      fi
    fi
    handoff_identity approver || return 5
    if [ "$(printf '%s' "$match" | jq -r '.cleared//false')" = true ]; then
      rebaseline=$(printf '%s' "$match" | jq -r '.rebaseline//false')
    else
      [ "$rebaseline" = false ] || marker='; rebaseline=true'
      journal_summary "$note" > "$file.result" || return 5
      journal_render hold-clear "$subject" \
        "agentic-flow-hold-clear: id=$id$marker" "Hold: $id" '' "$file.result" > "$file" || return $?
      handoff_comment "$tracker" "$file" || return $?
      handoff_fault after-hold-clear-post || return 5
    fi
    hold_record "$HANDOFF_PLAN" "$id" "$(printf '%s' "$match" | jq .issue)" "$(printf '%s' "$match" | jq -r .reason)" "$(printf '%s' "$match" | jq -r .run)" "$(printf '%s' "$match" | jq -r .comment_id)" || return 5
    if [ "${HANDOFF_LEDGER_UNAVAILABLE:-false}" = true ]; then records='[]'; else records=$(ledger_read "$HANDOFF_PLAN") || return 5; fi
    if ! printf '%s' "$records" | jq -e --arg id "$id" 'any(.[];.kind=="clear" and .hold==$id)' >/dev/null; then
      jq -n --arg plan "$HANDOFF_PLAN" --arg id "$id" --arg by "$HANDOFF_LOGIN" --arg note "$note" --argjson rebaseline "$rebaseline" '
        {v:1,kind:"clear",plan:$plan,hold:$id,by:$by,note:$note,rebaseline:$rebaseline,at:(now|floor)}' > "$HANDOFF_TMP/clear-record"
      ledger_clear "$HANDOFF_PLAN" "$HANDOFF_TMP/clear-record" || return 5
    fi
  fi
  printf '%s %s\n' "$event" "$id"
}

hold_cache() { # common dir; all reads were bounded by handoff_read
  local n holds='[]' part body
  for n in $HANDOFF_ISSUES; do
    [ -f "$HANDOFF_TMP/$n.issue" ] || continue
    body=$(jq -r .body "$HANDOFF_TMP/$n.issue") || return 5
    journal_context "$body" || return 5
    case "$JOURNAL_TOPOLOGY" in tracker|work-standard) ;; *) continue ;; esac
    part=$(hold_snapshot "$(cat "$HANDOFF_TMP/$n.issue")") || return 5
    holds=$(jq -n --argjson a "$holds" --argjson b "$part" '$a+$b|unique_by(.id)') || return 5
  done
  printf '%s\n' "$holds" > "$HANDOFF_TMP/holds-cache"
  mv "$HANDOFF_TMP/holds-cache" "$1/agentic-flow/state/$HANDOFF_PLAN.holds.json"
}

handoff_drift() { # read-only, bounded plan snapshot; structured report for the controller
  local n state labels actual expected status drift='[]' rows='[]' row
  handoff_plan_read || return $?
  for n in $HANDOFF_ISSUES; do
    handoff_read "$n" || return $?
    state=$(printf '%s' "$HANDOFF_REPLAY" | jq -r .state)
    labels=$(workflow_state_labels "$JOURNAL_TOPOLOGY" "$state") || return 5
    if [ "$JOURNAL_TOPOLOGY" = tracker ] || [ "$JOURNAL_TOPOLOGY" = work-standard ]; then
      if printf '%s' "$HANDOFF_ISSUE" | jq .comments.nodes | journal_normalize | hold_replay "$HANDOFF_PLAN" | jq -e 'length>0' >/dev/null; then
        if [ "$labels" = '-' ]; then labels=needs-human; else labels="$labels,needs-human"; fi
      fi
    fi
    actual=$(printf '%s' "$HANDOFF_ISSUE" | jq -r '.labels.nodes[].name' | LC_ALL=C sort)
    expected=$( {
      printf '%s\n' "$actual" | while IFS= read -r label; do
        if ! workflow_labels | grep -Fxq -- "$label"; then printf '%s\n' "$label"; fi
      done
      printf '%s\n' "$labels" | tr ',' '\n' | sed '/^-$/d'
    } | sed '/^$/d' | LC_ALL=C sort -u)
    status=$(printf '%s\n' "$WORKFLOW_DATA" | awk -F '\t' -v t="$JOURNAL_TOPOLOGY" -v s="$state" '$1=="state"&&$2==t&&$3==s{print $5}')
    drift='[]'
    [ "$actual" = "$expected" ] || drift=$(printf '%s' "$drift" | jq '.+["labels"]')
    [ "$(printf '%s' "$HANDOFF_ISSUE" | jq -r '.state|ascii_downcase')" = "$status" ] || drift=$(printf '%s' "$drift" | jq '.+["open-state"]')
    if [ "$(printf '%s' "$HANDOFF_REPLAY" | jq -r .unjournaled)" != null ]; then drift=$(printf '%s' "$drift" | jq '.+["unjournaled"]'); fi
    if [ "$n" = "$HANDOFF_TRACKER" ] && [ "$state" = open ] && [ "$HANDOFF_FOUND" -gt 0 ] && [ "$HANDOFF_ALL_APPROVED" = true ]; then
      drift=$(printf '%s' "$drift" | jq '.+["plan-effect"]')
    fi
    row=$(printf '%s' "$HANDOFF_ISSUE" | jq -c --argjson replay "$HANDOFF_REPLAY" --argjson drift "$drift" \
      --arg topology "$JOURNAL_TOPOLOGY" --arg step "$JOURNAL_STEP" --arg status "$status" \
      --argjson max_bounces "$JOURNAL_MAX_BOUNCES" --arg policy "$JOURNAL_POLICY" '
      ([.comments.nodes[]|select(.id==$replay.latest.comment_id)]|first//null) as $latest |
      ([($latest.body//""|split("\n")[])|try capture("^agentic-flow-run: run=(?<run>[a-zA-Z0-9/._-]+); host=(?<host>[a-f0-9]{12})$")]|last//{}) as $host |
      {number,step:$step,topology:$topology,state:$replay.state,observed_status:(.state|ascii_downcase),
       expected_status:$status,max_bounces:$max_bounces,policy:$policy,replay:$replay,drift:$drift,
       latest_at:($latest.createdAt//null),host:($host.host//null),run:($host.run//null)}') || return 5
    rows=$(printf '%s' "$rows" | jq --argjson row "$row" '.+[$row]') || return 5
  done
  printf '%s\n' "$rows" > "$HANDOFF_TMP/drift-rows"
  HANDOFF_DRIFT=$(jq -n --arg plan "$HANDOFF_PLAN" --arg tracker "$HANDOFF_TRACKER" --slurpfile rows "$HANDOFF_TMP/drift-rows" '{plan:$plan,tracker:(if $tracker=="" then null else ($tracker|tonumber) end),issues:$rows[0]}') || return 5
  if [ "${json:-false}" = true ]; then printf '%s\n' "$HANDOFF_DRIFT"
  else printf '%s' "$HANDOFF_DRIFT" | jq -r 'if all(.issues[];.drift|length==0) then "projection clean" else .issues[]|select(.drift|length>0)|"drift #\(.number): \(.drift|join(",")) journal=\(.state)" end'; fi
}
