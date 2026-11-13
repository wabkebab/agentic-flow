#!/usr/bin/env bash
# GitHub adapter and single-machine transaction coordinator for the pure journal.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/identity.sh"
. "$(dirname "${BASH_SOURCE[0]}")/workflow.sh"
. "$(dirname "${BASH_SOURCE[0]}")/journal.sh"

handoff_error() { echo "handoff: $*" >&2; }
handoff_gh() { # Never persist credentials or print them in diagnostics.
  if [ -n "${HANDOFF_TOKEN:-}" ]; then
    GH_TOKEN=$HANDOFF_TOKEN review_bounded gh "$@"
  else review_bounded gh "$@"; fi
}

handoff_identity() { # role, exit 7 means unavailable here, 5 means configured but broken
  local rc=0 roles
  HANDOFF_TOKEN='' HANDOFF_LOGIN=''
  identity_load "$HANDOFF_ROOT" "$1" 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    HANDOFF_LOGIN=$IDENTITY_LOGIN
    HANDOFF_TOKEN=$(identity_token "$HANDOFF_ROOT" "$1") || return 5
  elif [ "$rc" -eq 6 ]; then
    HANDOFF_LOGIN=$(handoff_gh api user --jq .login) || return 5
    case "$1" in executor) roles=$REVIEW_EXECUTORS ;; reviewer) roles=$REVIEW_REVIEWERS ;; approver) roles=$REVIEW_APPROVERS ;; *) return 5 ;; esac
    case "$roles" in *" $HANDOFF_LOGIN "*) ;; *) handoff_error "ambient login does not hold $1"; return 7 ;; esac
  else return 5; fi
}

handoff_read() { # number; results in HANDOFF_ISSUE/HANDOFF_REPLAY and journal context
  local response body comments
  # shellcheck disable=SC2016
  local query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){number body state labels(first:100){pageInfo{hasNextPage} nodes{name}} comments(first:100){pageInfo{hasNextPage} nodes{id fullDatabaseId body author{login __typename} createdAt lastEditedAt}}}}}'
  response=$(handoff_gh api graphql -f "query=$query" -f "owner=${HANDOFF_REPO%%/*}" \
    -f "name=${HANDOFF_REPO#*/}" -F "number=$1") || return 5
  HANDOFF_ISSUE=$(printf '%s' "$response" | jq -ec --argjson n "$1" '
    if (.errors // [] | length)>0 then error("GraphQL error") else .data.repository.issue end |
    if .number!=$n or (.body|type)!="string" or (.state!="OPEN" and .state!="CLOSED") or
      (.labels.nodes|type)!="array" or .labels.pageInfo.hasNextPage!=false or
      (.comments.nodes|type)!="array" or .comments.pageInfo.hasNextPage!=false or
      (.comments.nodes|length)>100 or any(.comments.nodes[];
        (.id|type)!="string" or (.body|type)!="string" or (.createdAt|type)!="string" or
        (has("lastEditedAt")|not))
    then error("invalid issue or more than 100 comments/labels") else . end') || {
      handoff_error "invalid or truncated issue #$1"; return 5;
    }
  body=$(printf '%s' "$HANDOFF_ISSUE" | jq -r .body)
  journal_context "$body" || { handoff_error "issue #$1 has no valid plan stamp"; return 3; }
  [ "$JOURNAL_PLAN" = "$HANDOFF_PLAN" ] || { handoff_error 'plan changed while reading'; return 5; }
  comments=$(printf '%s' "$HANDOFF_ISSUE" | jq '.comments.nodes' | journal_normalize) || return 5
  HANDOFF_REPLAY=$(journal_replay "$comments" "$JOURNAL_TOPOLOGY") || return 5
  if [ "$(printf '%s' "$HANDOFF_REPLAY" | jq -r .unjournaled)" != null ]; then
    handoff_error "UNJOURNALED #$1 comment $(printf '%s' "$HANDOFF_REPLAY" | jq -r .unjournaled)"; return 3
  fi
  printf '%s\n' "$HANDOFF_REPLAY" > "$HANDOFF_TMP/$1.replay"
  printf '%s\n' "$HANDOFF_ISSUE" > "$HANDOFF_TMP/$1.issue"
}

handoff_fault() { # Enabled only in hermetic tests; no fault controls in station inputs.
  [ "${AGENTIC_HANDOFF_TESTING:-}" = 1 ] || return 0
  [ "${AGENTIC_HANDOFF_FAULT:-}" = "$1" ] || return 0
  if [ -n "${AGENTIC_HANDOFF_PAUSE:-}" ]; then
    : > "$AGENTIC_HANDOFF_PAUSE.ready"
    local waited=0
    while [ ! -f "$AGENTIC_HANDOFF_PAUSE.release" ] && [ "$waited" -lt 300 ]; do
      sleep 0.1; waited=$((waited+1))
    done
    [ -f "$AGENTIC_HANDOFF_PAUSE.release" ] || return 5
  else return 5; fi
}

handoff_post() { # number event role head body; replay MUST have just been read
  local number=$1 event=$2 role=$3 head=$4 note=$5 seq from id comment file rc=0 author posted posted_dbid
  seq=$(printf '%s' "$HANDOFF_REPLAY" | jq '.seq+1')
  from=$(printf '%s' "$HANDOFF_REPLAY" | jq -r .state)
  id="$JOURNAL_PLAN/$JOURNAL_STEP/$seq/$event"
  file="$HANDOFF_TMP/comment"
  printf 'agentic-flow-transition: v=1; id=%s; event=%s; from=%s; role=%s; head=%s\n' \
    "$id" "$event" "$from" "$role" "$head" > "$file"
  case "$event" in
    submit) printf 'Implemented in %s\n' "$head" >> "$file" ;;
    approve|bounce)
      local verdict=approved compatibility_head=$head
      [ "$event" != bounce ] || { verdict=changes-requested; compatibility_head=$(printf '%s' "$HANDOFF_REPLAY" | jq -r .submitted_head); }
      printf 'agentic-flow-review: status=%s; step=%s; head=%s; role=reviewer\n' \
        "$verdict" "$JOURNAL_STEP" "$compatibility_head" >> "$file" ;;
  esac
  printf '%s\n' "$note" >> "$file"
  posted=$(handoff_gh issue comment "$number" --repo "$HANDOFF_REPO" --body-file "$file") || rc=$?
  posted_dbid=${posted##*#issuecomment-}
  [[ "$posted_dbid" =~ ^[0-9]+$ ]] || posted_dbid=''
  # A failed/timed-out post may have landed. Read once; never blindly repost.
  handoff_read "$number" || return $?
  comment=$(jq -c --arg id "$id" --arg dbid "$posted_dbid" '[.comments.nodes[] | select(.body|startswith("agentic-flow-transition: v=1; id="+$id+";")) | select($dbid=="" or (.fullDatabaseId|tostring)==$dbid)] | first // empty' "$HANDOFF_TMP/$number.issue")
  [ -n "$comment" ] || { handoff_error "post not found for $id (status $rc)"; return 5; }
  author=$(printf '[%s]' "$comment" | journal_normalize | jq -r '.[0].author') || return 5
  [ "$author" = "$HANDOFF_LOGIN" ] || { handoff_error 'posted comment author differs from role identity'; return 5; }
  if ! printf '%s' "$HANDOFF_REPLAY" | jq -e --arg id "$id" --arg head "$head" \
    --arg cid "$(printf '%s' "$comment" | jq -r .id)" \
    'any(.accepted[]; .id==$id and .head==$head and .comment_id==$cid)' >/dev/null; then
    handoff_error "lost race to $(printf '%s' "$HANDOFF_REPLAY" | jq -r --argjson seq "$seq" '.accepted[] | select(.seq==$seq) | .id')"
    return 4
  fi
  handoff_fault after-post
}

handoff_project() { # number; always re-read immediately before projection, then verify
  local number=$1 attempt=0 state labels current target remove label issue_state expected
  local -a args
  while [ "$attempt" -lt 3 ]; do
    handoff_read "$number" || return $?
    state=$(printf '%s' "$HANDOFF_REPLAY" | jq -r .state)
    labels=$(workflow_state_labels "$JOURNAL_TOPOLOGY" "$state") || return 5
    target=$(printf '%s\n' "$labels" | tr ',' '\n' | LC_ALL=C sort | sed '/^-$/d')
    current=$(printf '%s' "$HANDOFF_ISSUE" | jq -r '.labels.nodes[].name' | LC_ALL=C sort)
    remove=''
    while IFS= read -r label; do
      if ! printf '%s\n' "$target" | grep -Fxq -- "$label"; then
        if printf '%s\n' "$current" | grep -Fxq -- "$label"; then remove="${remove:+$remove,}$label"; fi
      fi
    done < <(workflow_labels)
    expected=$( { printf '%s\n' "$current" | while IFS= read -r label; do
      [ -n "$label" ] || continue
      workflow_labels | grep -Fxq -- "$label" || printf '%s\n' "$label"
    done; printf '%s\n' "$target"; } | sed '/^$/d' | LC_ALL=C sort -u)
    args=(issue edit "$number" --repo "$HANDOFF_REPO")
    [ "$labels" = '-' ] || args+=(--add-label "$labels")
    [ -z "$remove" ] || args+=(--remove-label "$remove")
    if [ "$current" != "$expected" ] && [ "${#args[@]}" -gt 5 ]; then handoff_gh "${args[@]}" >/dev/null || return 5; fi
    issue_state=$(printf '%s\n' "$WORKFLOW_DATA" | awk -F '\t' -v t="$JOURNAL_TOPOLOGY" -v s="$state" '$1=="state"&&$2==t&&$3==s{print $5}')
    if [ "$(printf '%s' "$HANDOFF_ISSUE" | jq -r '.state|ascii_downcase')" != "$issue_state" ]; then
      local verb=close
      [ "$issue_state" != open ] || verb=reopen
      handoff_gh issue "$verb" "$number" --repo "$HANDOFF_REPO" >/dev/null || return 5
    fi
    handoff_fault after-labels || return 5
    handoff_read "$number" || return $?
    # Check both journal drift and the entire workflow-label projection.
    local new_state actual
    new_state=$(printf '%s' "$HANDOFF_REPLAY" | jq -r .state)
    actual=$(printf '%s' "$HANDOFF_ISSUE" | jq -r '.labels.nodes[].name' | LC_ALL=C sort)
    if [ "$new_state" = "$state" ] && [ "$actual" = "$expected" ] &&
      [ "$(printf '%s' "$HANDOFF_ISSUE" | jq -r '.state|ascii_downcase')" = "$issue_state" ]; then return 0; fi
    attempt=$((attempt+1))
  done
  handoff_error 'labels did not converge'; return 5
}

handoff_plan_read() { # bounded exact-stamped discovery; labels are not evidence
  local n discovery='[]' context other_plan other_step approver page candidate searches=0
  HANDOFF_ISSUES='' HANDOFF_TRACKER='' HANDOFF_ALL_APPROVED=true HANDOFF_FOUND=0
  # Filter at GitHub as well as locally: strangers must not fill the bounded page.
  # Separate searches avoid depending on multi-author qualifier OR semantics.
  for approver in $REVIEW_APPROVERS; do
    searches=$((searches+1))
    [ "$searches" -le 100 ] || { handoff_error 'approver discovery exceeds 100 searches'; return 5; }
    page=$(handoff_gh issue list --repo "$HANDOFF_REPO" --state all --limit 100 \
      --search "\"agentic-flow:plan:$HANDOFF_PLAN\" in:body author:$approver" --json number,body,author) || return 5
    printf '%s' "$page" | jq -e 'type=="array" and length<100 and all(.[];(.number|type)=="number" and .number>0 and .number<10000000000 and (.number|floor)==.number and (.body|type)=="string")' >/dev/null || {
      handoff_error "invalid or incomplete discovery for approver $approver"; return 5;
    }
    # gh issue-list exposes typed Bot metadata as author.is_bot. Adapt it to
    # the shared normalizer; a human with the same slug never gains [bot].
    page=$(printf '%s' "$page" | jq 'map(select((.author|type)=="object" and (.author.login|type)=="string") |
      if .author.is_bot==true then .author.__typename="Bot" else . end)' |
      review_normalize_comments | jq --arg roles "$REVIEW_APPROVERS" \
      '[.[] | select(.author.login as $login | ($roles|split(" ")|index($login))!=null)]') || return 5
    while IFS= read -r candidate; do
      # Search text can be a quotation or malformed stamp. It is not membership.
      context=$(printf '%s' "$candidate" | jq -r .body | journal_stamp 2>/dev/null) || continue
      other_plan=$(printf '%s' "$context" | jq -r .plan)
      [ "$other_plan" = "$HANDOFF_PLAN" ] || continue
      discovery=$(printf '%s' "$discovery" | jq --argjson issue "$candidate" '.+[$issue]|unique_by(.number)') || return 5
      [ "$(printf '%s' "$discovery" | jq length)" -lt 100 ] || {
        handoff_error 'plan discovery reached 100 admitted issues'; return 5;
      }
    done < <(printf '%s' "$page" | jq -c '.[]')
  done
  HANDOFF_ISSUES=$(printf '%s' "$discovery" | jq -r '.[].number')
  for n in $HANDOFF_ISSUES; do
    context=$(printf '%s' "$discovery" | jq -r --argjson n "$n" '.[]|select(.number==$n)|.body' | journal_stamp) || return 5
    other_step=$(printf '%s' "$context" | jq -r .step)
    if [ "$other_step" = tracker ]; then [ -z "$HANDOFF_TRACKER" ] || return 5; HANDOFF_TRACKER=$n; fi
    handoff_read "$n" || return $?
    if [ "$JOURNAL_TOPOLOGY" = step-strict ]; then
      HANDOFF_FOUND=$((HANDOFF_FOUND+1))
      [ "$(printf '%s' "$HANDOFF_REPLAY" | jq -r .state)" = approved ] || HANDOFF_ALL_APPROVED=false
    fi
  done
}

handoff_cmd() ( # transaction-local credentials, temporary files, lock and traps
  set +x
  local number=${1:-} event=${2:-} role='' head=none after='' body_file='' json=false
  [[ "$number" =~ ^[1-9][0-9]{0,9}$ ]] && [ "$#" -ge 2 ] || { handoff_error 'usage: handoff <issue> <event> --as <role> [--head <sha>] [--after <seq>] [--body-file <path>]'; return 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --as|--head|--after|--body-file)
        [ "$#" -ge 2 ] || return 2
        case "$1" in --as) role=$2 ;; --head) head=$2 ;; --after) after=$2 ;; --body-file) body_file=$2 ;; esac
        shift 2 ;;
      --json) json=true; shift ;;
      *) return 2 ;;
    esac
  done
  case "$event" in submit|bounce|resume|approve|notify|close) [ "$json" = false ] && [ -n "$role" ] || return 2 ;; reconcile) [ -z "$role" ] && [ "$head" = none ] && [ -z "$after" ] && [ -z "$body_file" ] || return 2 ;; *) return 2 ;; esac
  [[ "$head" =~ ^([a-f0-9]{40}|none)$ ]] || return 2
  [ -z "$after" ] || [[ "$after" =~ ^[0-9]{1,6}$ ]] || return 2
  HANDOFF_ROOT=$(git rev-parse --show-toplevel) || return 5
  HANDOFF_REPO=$(identity_repository "$HANDOFF_ROOT") || return 5
  workflow_load "$HANDOFF_ROOT" && read_review_policy "$HANDOFF_ROOT" || return 5
  HANDOFF_TOKEN='' HANDOFF_LOGIN=''
  local initial stamp lock common waited=0 locked=false note='' result=0 latest_seq status lock_pid
  initial=$(handoff_gh issue view "$number" --repo "$HANDOFF_REPO" --json body) || return 5
  stamp=$(printf '%s' "$initial" | jq -er .body | journal_stamp) || { handoff_error 'no valid plan stamp'; return 3; }
  HANDOFF_PLAN=$(printf '%s' "$stamp" | jq -r .plan)
  common=$(git rev-parse --git-common-dir) || return 5
  common=$(cd "$common" && pwd -P) || return 5
  lock="$common/agentic-flow/locks/$HANDOFF_PLAN"
  mkdir -p "$common/agentic-flow/locks" "$common/agentic-flow/state" || return 5
  HANDOFF_TMP=$(mktemp -d "${TMPDIR:-/tmp}/agentic-handoff.XXXXXX") || return 5
  trap 'rm -rf "$HANDOFF_TMP"; if [ "$locked" = true ]; then rm -rf "$lock"; fi' EXIT
  trap 'exit 5' INT TERM
  if [ "${AGENTIC_HANDOFF_TESTING:-}" != 1 ] || [ "${AGENTIC_HANDOFF_NO_LOCK:-}" != 1 ]; then
    until mkdir "$lock" 2>/dev/null; do
      local pid=''
      [ ! -f "$lock/pid" ] || read -r pid < "$lock/pid"
      if { [[ "$pid" =~ ^[1-9][0-9]*$ ]] && ! kill -0 "$pid" 2>/dev/null; } ||
        { [ -z "$pid" ] && [ "$waited" -ge 2 ]; }; then
        # A recovery claim serializes stale takeover; recheck after acquiring it.
        if mkdir "$lock/recover" 2>/dev/null; then
          pid=''
          [ ! -f "$lock/pid" ] || read -r pid < "$lock/pid"
          if [ -z "$pid" ] || { [[ "$pid" =~ ^[1-9][0-9]*$ ]] && ! kill -0 "$pid" 2>/dev/null; }; then
            if mv "$lock" "$lock.stale.$$" 2>/dev/null; then rm -rf "$lock.stale.$$"; fi
          else rmdir "$lock/recover" 2>/dev/null || true; fi
        fi
      fi
      [ "$waited" -lt 30 ] || { handoff_error 'plan lock timed out'; return 5; }
      sleep 1; waited=$((waited+1))
    done
    locked=true
    lock_pid=$(exec sh -c 'printf "%s\n" "$PPID"')
    printf '%s\n' "$lock_pid" > "$lock/pid"
    date +%s > "$lock/started"
  fi
  handoff_read "$number" || return $?
  local topology=$JOURNAL_TOPOLOGY
  if [ -n "$body_file" ]; then
    [ -f "$body_file" ] && [ "$(wc -c < "$body_file")" -le 65536 ] || return 2
    note=$(cat "$body_file")
  fi
  if [ "$event" != reconcile ]; then
    local event_role
    event_role=$(printf '%s\n' "$WORKFLOW_DATA" | awk -F '\t' -v t="$topology" -v e="$event" '$1=="transition"&&$2==t&&$3==e{print $4}' | sort -u)
    [ "$role" = "$event_role" ] || { handoff_error 'role differs from workflow'; return 3; }
    handoff_identity "$role" || { status=$?; [ "$status" -ne 7 ] || status=3; return "$status"; }
    latest_seq=$(printf '%s' "$HANDOFF_REPLAY" | jq .seq)
    local retry=false superseded=false
    if printf '%s' "$HANDOFF_REPLAY" | jq -e --arg e "$event" --arg r "$role" --arg h "$head" '.latest | .event==$e and .role==$r and .head==$h' >/dev/null; then retry=true
    elif [ -n "$after" ] && [ "$after" -lt "$latest_seq" ]; then
      if printf '%s' "$HANDOFF_REPLAY" | jq -e --argjson seq "$((10#$after+1))" --arg e "$event" --arg r "$role" --arg h "$head" \
        'any(.accepted[]; .seq==$seq and .event==$e and .role==$r and .head==$h)' >/dev/null; then superseded=true; echo superseded
      else handoff_error "lost race to $(printf '%s' "$HANDOFF_REPLAY" | jq -r --argjson seq "$((10#$after+1))" '.accepted[]|select(.seq==$seq)|.id')"; result=4; superseded=true; fi
    fi
    if [ "$retry" = false ] && [ "$superseded" = false ]; then
      local state bounces
      state=$(printf '%s' "$HANDOFF_REPLAY" | jq -r .state)
      bounces=$(printf '%s' "$HANDOFF_REPLAY" | jq .bounces)
      workflow_successor "$topology" "$state" "$event" "$bounces" >/dev/null || {
        handoff_error "illegal $event from $state; legal events: $(printf '%s\n' "$WORKFLOW_DATA" | awk -F '\t' -v t="$topology" -v s="$state" '$1=="transition"&&$2==t&&$5==s{print $3}' | sort -u | tr '\n' ' ')"; return 3;
      }
      case "$event" in
        submit) [ "$head" != none ] && [ "$head" != "$(printf '%s' "$HANDOFF_REPLAY" | jq -r .last_bounced_head)" ] || return 3 ;;
        approve) [ "$head" = "$(printf '%s' "$HANDOFF_REPLAY" | jq -r .submitted_head)" ] || return 3 ;;
        bounce|resume) [ -n "${note//[[:space:]]/}" ] || { handoff_error 'findings/note required'; return 3; } ;;
        notify)
          handoff_plan_read || return $?
          [ "$HANDOFF_TRACKER" = "$number" ] && [ "$HANDOFF_FOUND" -gt 0 ] &&
            [ "$HANDOFF_ALL_APPROVED" = true ] || { handoff_error 'notify requires all steps approved'; return 3; }
          handoff_read "$number" || return $? ;;
        close)
          local doc close_doc='' count=0 scanned=0
          for doc in "$HANDOFF_ROOT"/docs/inprogress/*.md "$HANDOFF_ROOT"/docs/done/*.md "$HANDOFF_ROOT"/docs/done/security/*.md; do
            [ -f "$doc" ] || continue
            scanned=$((scanned+1))
            [ "$scanned" -le 1000 ] || { handoff_error 'lifecycle document scan exceeds 1000 files'; return 5; }
            if grep -Fxq -- "- **Tracking issue:** url=https://github.com/$HANDOFF_REPO/issues/$number" "$doc"; then
              count=$((count+1)); close_doc=$doc
            fi
          done
          [ "$count" -eq 1 ] || { handoff_error 'close needs one lifecycle document'; return 3; }
          "$HANDOFF_ROOT/scripts/lifecycle-status.sh" --doc "$close_doc" --phase close-out --check --verify-evidence || return 3 ;;
      esac
      handoff_fault after-replay || return 5
      handoff_post "$number" "$event" "$role" "$head" "$note" || { status=$?; [ "$status" -eq 4 ] || return "$status"; result=4; }
    fi
  fi
  handoff_project "$number" || return $?
  handoff_fault before-notify || return 5
  handoff_plan_read || return $?
  local issues=$HANDOFF_ISSUES tracker=$HANDOFF_TRACKER n
  local found=$HANDOFF_FOUND all_approved=$HANDOFF_ALL_APPROVED
  if [ -n "$tracker" ] && [ "$found" -gt 0 ] && [ "$all_approved" = true ]; then
    handoff_read "$tracker" || return $?
    if [ "$(printf '%s' "$HANDOFF_REPLAY" | jq -r .state)" = open ]; then
      status=0; handoff_identity reviewer || status=$?
      if [ "$status" -eq 7 ]; then
        handoff_error "plan effect pending: notify on #$tracker; run agentic-flow handoff $tracker reconcile where the reviewer identity is configured"
        result=7
      elif [ "$status" -ne 0 ]; then return 5
      else handoff_post "$tracker" notify reviewer none 'All steps approved.' || { status=$?; [ "$status" -eq 4 ] || return "$status"; result=4; }; fi
    fi
    # An unavailable effect still permits the requested projection to converge.
    handoff_project "$tracker" || return $?
  fi
  # Re-read every written issue after plan effects, detecting out-of-lock writers.
  handoff_project "$number" || return $?
  local cache="$HANDOFF_TMP/cache"
  : > "$cache"
  for n in $issues; do
    [ -f "$HANDOFF_TMP/$n.replay" ] || continue
    jq -r --arg n "$n" --arg step "$(jq -r .body "$HANDOFF_TMP/$n.issue" | journal_stamp | jq -r .step)" \
      '[$n,$step,.state,(.latest.id//"none"),.submitted_head,(now|todateiso8601)]|@tsv' "$HANDOFF_TMP/$n.replay" >> "$cache"
  done
  mv "$cache" "$common/agentic-flow/state/$HANDOFF_PLAN.tsv" || return 5
  if [ "$json" = true ]; then
    jq -s 'to_entries|map({key:(.value.number|tostring),value:.value.replay})|from_entries' \
      <(for n in $issues; do [ ! -f "$HANDOFF_TMP/$n.replay" ] || jq --argjson n "$n" '{number:$n,replay:.}' "$HANDOFF_TMP/$n.replay"; done)
  else printf 'issue #%s: %s (seq %s, skipped %s)\n' "$number" \
    "$(jq -r .state "$HANDOFF_TMP/$number.replay")" "$(jq .seq "$HANDOFF_TMP/$number.replay")" "$(jq .skipped "$HANDOFF_TMP/$number.replay")"; fi
  return "$result"
)
