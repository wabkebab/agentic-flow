#!/usr/bin/env bash
# lifecycle-status.sh — report or verify implementation-document close-out state.
# Usage: scripts/lifecycle-status.sh [--check] [--verify-evidence]
#        [--doc <exact-path>] [--phase close-out|pre-merge]
#        [--doc <exact-path>] --validate-doc-status
set -euo pipefail

ROOT=${AGENTIC_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
SCRIPT_ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
STRICT=false
VERIFY_EVIDENCE=false
VALIDATE_DOC_STATUS=false
DOC=""
PHASE=close-out
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) STRICT=true ;;
    --verify-evidence) VERIFY_EVIDENCE=true ;;
    --validate-doc-status) VALIDATE_DOC_STATUS=true ;;
    --doc)
      [ "$#" -ge 2 ] || { echo 'error: --doc needs a path' >&2; exit 2; }
      DOC=$2; shift ;;
    --phase)
      [ "$#" -ge 2 ] || { echo 'error: --phase needs a value' >&2; exit 2; }
      PHASE=$2; shift ;;
    -h|--help) awk 'NR==1 {next} /^#/ {print; next} {exit}' "$0"; exit 0 ;;
    *) echo "error: unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$PHASE" in close-out|pre-merge) ;; *) echo "error: unknown phase: $PHASE" >&2; exit 2 ;; esac
[ -z "$DOC" ] || [ -f "$DOC" ] || { echo "error: --doc file not found: $DOC" >&2; exit 2; }

# Parse exactly one Status block. Fields cannot wrap or repeat, and only the eight
# declared keys are allowed. The tab-delimited result is internal and never evaluated.
status_fields() { # <doc>
  awk '
    /^## Status([[:space:]]|$)/ { if (status_seen++) { print "ERROR\tduplicate Status block"; exit }; in_status=1; next }
    in_status && /^#{1,2} / { in_status=0 }
    !in_status { next }
    /^- \*\*[^*]+:\*\*/ {
      line=$0
      sub(/^- \*\*/, "", line)
      split(line, parts, ":\\*\\*")
      key=parts[1]
      value=substr(line, length(key)+5)
      sub(/^[[:space:]]*/, "", value)
      if (key != "Evidence schema" && key != "Tracking issue" && key != "Approval" &&
          key != "Implementation head" && key != "Implementation PR" &&
          key != "Verification evidence" && key != "Review verdict" && key != "Memory") {
        print "ERROR\tunknown field " key; exit
      }
      if (seen[key]++) { print "ERROR\tduplicate field " key; exit }
      if (length(value) > 4096 || value ~ /\t/) { print "ERROR\tmalformed field " key; exit }
      print key "\t" value
      last_key=key
      next
    }
    last_key && /^[[:space:]]+[^[:space:]]/ {
      print "ERROR\tmalformed continuation of " last_key; exit
    }
    /^[[:space:]]*$/ { last_key="" }
    /^- / { last_key="" }
  ' "$1"
}

valid_value() { # <key> <value>
  case "$1" in
    'Evidence schema') [ "$2" = v2 ] ;;
    'Tracking issue') [[ "$2" =~ ^url=https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*$ ]] ;;
    Approval) [[ "$2" =~ ^status=approved\;\ by=[A-Za-z0-9]([A-Za-z0-9._\ -]*[A-Za-z0-9])?\;\ at=[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$ ]] ;;
    'Implementation head') [ "$2" = source=pr-head ] ;;
    'Implementation PR') [[ "$2" =~ ^url=https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*$ ]] ;;
    'Verification evidence') [ "$2" = source=final-approval-run ] ;;
    'Review verdict') [ "$2" = source=pr-head-approval ] ;;
    Memory) [ "$2" = status=n/a ] || [[ "$2" =~ ^path=docs/memory/[A-Za-z0-9._-]+\.md$ ]] ;;
  esac
}

# Keep every GitHub request bounded. gh api performs one request per invocation here:
# pagination and retries are never requested. The timer also covers a hung mock gh.
bounded_gh() { # <output-file> <gh arguments...>
  local output=$1 pid timer result
  shift
  gh "$@" > "$output" 2>/dev/null & pid=$!
  ( sleep 30; kill "$pid" 2>/dev/null || true ) & timer=$!
  result=0
  wait "$pid" || result=$?
  kill "$timer" 2>/dev/null || true
  wait "$timer" 2>/dev/null || true
  return "$result"
}

unverified_evidence() { evidence_status=UNVERIFIED; evidence_reason=$1; }
blocked_evidence() { evidence_status=BLOCKED; evidence_reason=$1; }

origin_repository() {
  local origin
  origin=$(git -C "$ROOT" config --get remote.origin.url 2>/dev/null) || return 1
  case "$origin" in
    git@github.com:*) origin=${origin#git@github.com:} ;;
    https://github.com/*) origin=${origin#https://github.com/} ;;
    *) return 1 ;;
  esac
  origin=${origin%.git}
  [[ "$origin" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  printf '%s' "$origin"
}

# Parse one single-line review marker. Duplicate fields cannot be made harmless by
# choosing the first or last value.
parse_review_marker() { # <line>
  local raw=$1 part key value
  REVIEW_STATUS="" REVIEW_PR="" REVIEW_HEAD="" REVIEW_RUN="" REVIEW_ATTEMPT=""
  REVIEW_ROLE="" REVIEW_STEP=""
  raw=${raw#agentic-flow-review: }
  local -a parts
  IFS=';' read -r -a parts <<< "$raw"
  for part in "${parts[@]}"; do
    part=${part#"${part%%[![:space:]]*}"}
    part=${part%"${part##*[![:space:]]}"}
    [ -n "$part" ] || continue
    case "$part" in *=*) ;; *) return 1 ;; esac
    key=${part%%=*}; value=${part#*=}
    [ -n "$value" ] || return 1
    case "$key" in
      status) [ -z "$REVIEW_STATUS" ] || return 1; REVIEW_STATUS=$value ;;
      pr) [ -z "$REVIEW_PR" ] || return 1; REVIEW_PR=$value ;;
      head) [ -z "$REVIEW_HEAD" ] || return 1; REVIEW_HEAD=$value ;;
      run) [ -z "$REVIEW_RUN" ] || return 1; REVIEW_RUN=$value ;;
      attempt) [ -z "$REVIEW_ATTEMPT" ] || return 1; REVIEW_ATTEMPT=$value ;;
      role) [ -z "$REVIEW_ROLE" ] || return 1; REVIEW_ROLE=$value ;;
      step) [ -z "$REVIEW_STEP" ] || return 1; REVIEW_STEP=$value ;;
      *) return 1 ;;
    esac
  done
  [[ "$REVIEW_HEAD" =~ ^[[:xdigit:]]{40}$ ]] || return 1
  [[ "$REVIEW_STATUS" =~ ^(approved|changes-requested)$ ]] || return 1
}

authenticate_verdict() { # <comment-id> <API-author> <claimed-role>
  local comment_id=$1 author=$2 role=$3
  [ -n "$author" ] || { unverified_evidence "comment $comment_id author unavailable"; return 1; }
  [ "$role" = reviewer ] || {
    blocked_evidence "comment $comment_id role claim differs from reviewer"; return 1;
  }
  case "$REVIEW_REVIEWERS" in *" $author "*) ;; *)
      blocked_evidence "comment $comment_id author $author is not an authorized reviewer"; return 1 ;; esac
  if [ "$REVIEW_IDENTITY_MODE" = distinct-account ]; then
    case "$REVIEW_EXECUTORS$REVIEW_APPROVERS" in *" $author "*)
      blocked_evidence "comment $comment_id author $author overlaps executor or approver"; return 1 ;; esac
  fi
}

decimal_greater() { # <candidate> <current> — compare unbounded decimal strings exactly
  local a=$1 b=$2
  a=${a#"${a%%[!0]*}"}; b=${b#"${b%%[!0]*}"}
  [ -n "$a" ] || a=0
  [ -n "$b" ] || b=0
  [ "${#a}" -gt "${#b}" ] && return 0
  [ "${#a}" -lt "${#b}" ] && return 1
  # shellcheck disable=SC2071 # Equal-length decimal strings need lexical ordering.
  [[ "$a" > "$b" ]]
}

normalize_decimal() { # <validated decimal string>
  local value=$1
  value=${value#"${value%%[!0]*}"}
  printf '%s' "${value:-0}"
}

# Check one step against the implementation SHA recorded on its own thread.
# The same bounded GraphQL page carries both implementation handoff and verdict.
verify_step_review() { # <repo> <issue-number> <step-id> <tmp-dir> <pr-head> [reuse-tracking-page]
  local repo=$1 number=$2 step=$3 tmp=$4 owner=${1%%/*} name=${1#*/} \
    query response node body id dbid edited handoff_author step_head="" selected_id="" \
    selected_dbid="" selected_marker="" selected_author="" selected_edited="" \
    null_index candidate normalized pr_head=$5 ancestry_status shallow git_error
  if [ "${6:-}" = reuse-tracking-page ]; then
    response=$(cat "$tmp/comments")
  else
    # shellcheck disable=SC2016
    query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){comments(first:100){pageInfo{hasNextPage endCursor} nodes{id fullDatabaseId body author{login __typename} createdAt lastEditedAt}}}}}'
    if ! bounded_gh "$tmp/step-$number" api graphql -f "query=$query" -f "owner=$owner" -f "name=$name" -F "number=$number"; then
      unverified_evidence "step $step comments unavailable"; return 1
    fi
    response=$(cat "$tmp/step-$number")
  fi
  if printf '%s' "$response" | jq -e '(.errors | type == "array" and length > 0)' >/dev/null 2>&1; then
    unverified_evidence "step $step GraphQL error: $(printf '%s' "$response" | jq -r '.errors[0].message')"; return 1
  fi
  if ! printf '%s' "$response" | jq -e '.data.repository.issue.comments.nodes | type == "array"' >/dev/null 2>&1; then
    unverified_evidence "step $step comments nodes missing"; return 1
  fi
  if ! printf '%s' "$response" | jq -e '.data.repository.issue.comments.pageInfo.hasNextPage | type == "boolean"' >/dev/null 2>&1; then
    unverified_evidence "step $step pageInfo.hasNextPage missing"; return 1
  fi
  if [ "$(printf '%s' "$response" | jq -r '.data.repository.issue.comments.pageInfo.hasNextPage')" = true ]; then
    unverified_evidence "step $step comments exceed one page"; return 1
  fi
  null_index=$(printf '%s' "$response" | jq -r '.data.repository.issue.comments.nodes | to_entries[] | select(.value | type != "object") | .key' | head -1)
  if [ -n "$null_index" ]; then
    unverified_evidence "step $step comment node $null_index unreadable"; return 1
  fi
  local ignored normalized_comments
  normalized_comments=$(printf '%s' "$response" | jq '.data.repository.issue.comments.nodes' | review_normalize_comments) || {
    unverified_evidence 'comment author normalization failed'; return 1;
  }
  response=$(printf '%s' "$response" | jq --argjson nodes "$normalized_comments" '.data.repository.issue.comments.nodes=$nodes')
  ignored=$(printf '%s' "$response" | jq --arg roles "$REVIEW_REVIEWERS$REVIEW_EXECUTORS$REVIEW_APPROVERS" '[.data.repository.issue.comments.nodes[] | select(.author.login as $login | ($roles | split(" ") | index($login)) == null)] | length')
  [ "$ignored" -eq 0 ] || printf 'EVIDENCE ignored %s comment(s) from authors outside the review policy\n' "$ignored"
  printf '%s' "$response" | jq -c --arg roles "$REVIEW_REVIEWERS$REVIEW_EXECUTORS$REVIEW_APPROVERS" '.data.repository.issue.comments.nodes[] | select(.author.login as $login | ($roles | split(" ") | index($login)) != null)' > "$tmp/step-nodes-$number"
  # The latest executor handoff on this thread identifies the implementation
  # commit. A full SHA is required so a truncated hash cannot masquerade as head.
  while IFS= read -r node; do
    body=$(printf '%s' "$node" | jq -r '.body // empty')
    candidate=$(printf '%s\n' "$body" | sed -nE 's/.*Implemented in ([[:xdigit:]]{40})([^[:xdigit:]]|$).*/\1/p' | head -1)
    if [ -n "$candidate" ]; then
      {
        handoff_author=$(printf '%s' "$node" | jq -r '.author.login // empty')
        [ -n "$handoff_author" ] || {
          unverified_evidence "step $step implementation handoff author unavailable"; return 1;
        }
        case "$REVIEW_EXECUTORS" in *" $handoff_author "*) ;; *)
          blocked_evidence "step $step implementation handoff author $handoff_author is not an executor"; return 1 ;; esac
      }
      step_head=$candidate
    fi
  done < "$tmp/step-nodes-$number"
  if [ -z "$step_head" ]; then
    unverified_evidence "step $step has no full implementation SHA handoff"; return 1
  fi
  while IFS= read -r node; do
    body=$(printf '%s' "$node" | jq -r '.body // empty')
    candidate=$(printf '%s\n' "$body" | sed -n '/^[[:space:]]*agentic-flow-review:/p')
    [ -n "$candidate" ] || continue
    id=$(printf '%s' "$node" | jq -r '.id // empty')
    [ -n "$id" ] || { unverified_evidence "step $step verdict has no opaque id"; return 1; }
    if [ "$(printf '%s\n' "$candidate" | wc -l | tr -d ' ')" -ne 1 ]; then
      blocked_evidence "step $step comment $id has multiple review markers"; return 1
    fi
    candidate=${candidate#"${candidate%%[![:space:]]*}"}
    if ! parse_review_marker "$candidate"; then
      blocked_evidence "step $step comment $id has malformed review record"; return 1
    fi
    if [ "$REVIEW_HEAD" != "$step_head" ]; then
      printf 'EVIDENCE step %s  superseded comment %s head=%s\n' "$step" "$id" "$REVIEW_HEAD"
      continue
    fi
    # Standard's final PR approval shares this thread. It is a different
    # verdict kind and must not displace the step review for the same head.
    [ -n "$REVIEW_STEP" ] || continue
    dbid=$(printf '%s' "$node" | jq -r '.fullDatabaseId // empty')
    if ! printf '%s' "$node" | jq -e '.fullDatabaseId | type == "string"' >/dev/null 2>&1 \
       || ! [[ "$dbid" =~ ^[0-9]+$ ]]; then
      unverified_evidence "step $step comment $id missing valid fullDatabaseId"; return 1
    fi
    normalized=$(normalize_decimal "$dbid")
    if grep -Fxq -- "$normalized" "$tmp/step-dbids-$number" 2>/dev/null; then
      blocked_evidence "step $step duplicate fullDatabaseId $dbid"; return 1
    fi
    printf '%s\n' "$normalized" >> "$tmp/step-dbids-$number"
    if ! printf '%s' "$node" | jq -e 'has("lastEditedAt")' >/dev/null; then
      unverified_evidence "step $step comment $id missing lastEditedAt"; return 1
    fi
    edited=$(printf '%s' "$node" | jq -r '.lastEditedAt // empty')
    if [ -z "$selected_id" ] || decimal_greater "$dbid" "$selected_dbid"; then
      if [ -n "$selected_id" ]; then
        printf 'EVIDENCE step %s  superseded comment %s head=%s\n' "$step" "$selected_id" "$step_head"
      fi
      selected_id=$id selected_dbid=$dbid selected_marker=$candidate selected_edited=$edited
      selected_author=$(printf '%s' "$node" | jq -r '.author.login // empty')
    elif [ "$dbid" = "$selected_dbid" ]; then
      blocked_evidence "step $step comments $selected_id and $id share fullDatabaseId"; return 1
    else
      printf 'EVIDENCE step %s  superseded comment %s head=%s\n' "$step" "$id" "$step_head"
    fi
  done < "$tmp/step-nodes-$number"
  if [ -z "$selected_id" ]; then
    unverified_evidence "step $step has no review for implementation head $step_head"; return 1
  fi
  printf 'EVIDENCE step %s  comment %s fullDatabaseId=%s lastEditedAt=%s head=%s author=%s\n' \
    "$step" "$selected_id" "$selected_dbid" "${selected_edited:-null}" "$step_head" "${selected_author:-unavailable}"
  if [ -n "$selected_edited" ]; then
    blocked_evidence "step $step comment $selected_id was edited at $selected_edited"; return 1
  fi
  parse_review_marker "$selected_marker"
  authenticate_verdict "$selected_id" "$selected_author" "$REVIEW_ROLE" || return 1
  if [ "$REVIEW_STATUS" != approved ] || [ "$REVIEW_STEP" != "$step" ]; then
    blocked_evidence "step $step comment $selected_id does not approve implementation head $step_head"; return 1
  fi
  if ! git -C "$ROOT" cat-file -e "${step_head}^{commit}" 2>/dev/null; then
    unverified_evidence "step $step SHA $step_head unavailable locally as a commit; run git fetch origin $step_head"; return 1
  fi
  ancestry_status=0
  git -C "$ROOT" merge-base --is-ancestor "$step_head" "$pr_head" 2> "$tmp/ancestry-error" || ancestry_status=$?
  case "$ancestry_status" in
    0) return 0 ;;
    1)
      if ! shallow=$(git -C "$ROOT" rev-parse --is-shallow-repository 2> "$tmp/ancestry-error"); then
        git_error=$(cat "$tmp/ancestry-error")
        unverified_evidence "step $step history unavailable: $git_error; run git fetch origin"; return 1
      fi
      case "$shallow" in
        true) unverified_evidence "step $step ancestry unavailable in shallow history; run git fetch --unshallow" ;;
        false) blocked_evidence "approved step $step commit $step_head is not an ancestor of PR head $pr_head" ;;
        *) unverified_evidence "step $step history completeness unavailable; run git fetch origin" ;;
      esac ;;
    *)
      git_error=$(cat "$tmp/ancestry-error")
      unverified_evidence "step $step ancestry git error: $git_error; run git fetch origin" ;;
  esac
  return 1
}

verify_strict_steps() { # <repo> <tracking-body> <tmp-dir> <pr-head>
  local repo=$1 tracking_body=$2 tmp=$3 pr_head=$4 plan number step state count=0
  plan=$(printf '%s\n' "$tracking_body" | sed -nE 's/^<!-- agentic-flow:plan:([a-z0-9][a-z0-9._-]*) tracker spec:[[:xdigit:]]{40}.* -->$/\1/p' | head -1)
  if [ -z "$plan" ]; then
    unverified_evidence 'Tracking issue identity stamp unavailable'; return 1
  fi
  if ! bounded_gh "$tmp/issues" issue list --repo "$repo" --state all \
    --search "\"agentic-flow:plan:$plan\" in:body" --limit 100 --json number,body,state; then
    unverified_evidence 'step issue discovery unavailable'; return 1
  fi
  if ! jq -e 'type == "array" and length < 100' "$tmp/issues" >/dev/null 2>&1; then
    unverified_evidence 'step issue listing incomplete within 100'; return 1
  fi
  jq -r --arg plan "$plan" '.[] | select((.body // "") | split("\n") | any(.[]; startswith("<!-- agentic-flow:plan:" + $plan + " step:") and endswith(" -->"))) | [.number, (.body | capture("step:(?<id>[a-z0-9][a-z0-9._-]*) spec:").id), .state] | @tsv' \
    "$tmp/issues" > "$tmp/steps" || { unverified_evidence 'step issue stamps malformed'; return 1; }
  while IFS="$(printf '\t')" read -r number step state; do
    [ -n "$number" ] || continue
    count=$((count + 1))
    if [ "$state" != CLOSED ]; then
      blocked_evidence "step $step issue $number is $state"; return 1
    fi
    verify_step_review "$repo" "$number" "$step" "$tmp" "$pr_head" || return 1
  done < "$tmp/steps"
  if [ "$count" -eq 0 ]; then
    unverified_evidence "plan $plan has no stamped step issues"; return 1
  fi
}

verify_evidence() { # <tracking-url> <pr-url> <tracking-body> <topology>
  local tracking=$1 pr_url=$2 tracking_body=$3 topology=$4 repo workflow pr_number issue_number owner name \
    tmp pr_json comments_json run_json head query nodes id dbid body marker edited \
    selected_id="" selected_dbid="" selected_marker="" selected_edited="" selected_author="" \
    null_index run_id live_attempt conclusion run_repo run_path run_head normalized step_id
  evidence_status=UNVERIFIED
  evidence_reason='external evidence unresolved'
  # shellcheck disable=SC1091 # The library is resolved from the installed script root.
  . "$SCRIPT_ROOT/scripts/lib/review-policy.sh"
  if ! read_review_policy "$ROOT" >/dev/null 2>&1; then
    unverified_evidence 'review policy missing or invalid'; return
  fi
  if [ "$REVIEW_IDENTITY_MODE" = single-operator ]; then
    printf 'WARN    single-operator reviewer role is an account attestation, not independent review (%s)\n' \
      "$REVIEW_ACCEPTED_RISK"
  fi
  workflow=$REVIEW_WORKFLOW
  repo=$(origin_repository) || { unverified_evidence 'configured GitHub origin unavailable'; return; }
  owner=${repo%%/*}; name=${repo#*/}
  case "$tracking" in "https://github.com/$repo/issues/"*) ;; *)
    blocked_evidence 'Tracking issue repository differs from origin'; return ;; esac
  case "$pr_url" in "https://github.com/$repo/pull/"*) ;; *)
    blocked_evidence 'Implementation PR repository differs from origin'; return ;; esac
  issue_number=${tracking##*/}; pr_number=${pr_url##*/}
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/agentic-flow-evidence.XXXXXX") || {
    unverified_evidence 'cannot prepare evidence lookup'; return;
  }
  if ! bounded_gh "$tmp/pr" api "repos/$repo/pulls/$pr_number"; then
    unverified_evidence 'Implementation PR unavailable'; rm -rf "$tmp"; return
  fi
  pr_json=$(cat "$tmp/pr")
  head=$(printf '%s' "$pr_json" | jq -r '.head.sha // empty' 2>/dev/null) || head=""
  if ! [[ "$head" =~ ^[[:xdigit:]]{40}$ ]]; then
    unverified_evidence 'Implementation PR head unavailable'; rm -rf "$tmp"; return
  fi
  # shellcheck disable=SC2016 # GraphQL variables belong in the literal query.
  query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){comments(first:100){pageInfo{hasNextPage endCursor} nodes{id fullDatabaseId body author{login __typename} createdAt lastEditedAt}}}}}'
  if ! bounded_gh "$tmp/comments" api graphql -f "query=$query" -f "owner=$owner" -f "name=$name" -F "number=$issue_number"; then
    unverified_evidence 'Tracking issue comments unavailable'; rm -rf "$tmp"; return
  fi
  comments_json=$(cat "$tmp/comments")
  if printf '%s' "$comments_json" | jq -e '(.errors | type == "array" and length > 0)' >/dev/null 2>&1; then
    unverified_evidence "Tracking issue GraphQL error: $(printf '%s' "$comments_json" | jq -r '.errors[0] | [.message, (.path | tostring)] | join(" at ")' 2>/dev/null)"
    rm -rf "$tmp"; return
  fi
  if ! printf '%s' "$comments_json" | jq -e '.data.repository.issue.comments.nodes | type == "array"' >/dev/null 2>&1; then
    unverified_evidence 'Tracking issue comments nodes missing'; rm -rf "$tmp"; return
  fi
  if ! printf '%s' "$comments_json" | jq -e '.data.repository.issue.comments.pageInfo.hasNextPage | type == "boolean"' >/dev/null 2>&1; then
    unverified_evidence 'Tracking issue comments pageInfo.hasNextPage missing'; rm -rf "$tmp"; return
  fi
  if [ "$(printf '%s' "$comments_json" | jq -r '.data.repository.issue.comments.pageInfo.hasNextPage')" = true ]; then
    unverified_evidence 'Tracking issue comments exceed one page; resolve the thread'; rm -rf "$tmp"; return
  fi
  null_index=$(printf '%s' "$comments_json" | jq -r '.data.repository.issue.comments.nodes | to_entries[] | select(.value | type != "object") | .key' | head -1)
  if [ -n "$null_index" ]; then
    unverified_evidence "Tracking issue comment node $null_index unreadable"; rm -rf "$tmp"; return
  fi
  local ignored normalized_comments
  normalized_comments=$(printf '%s' "$comments_json" | jq '.data.repository.issue.comments.nodes' | review_normalize_comments) || {
    unverified_evidence 'comment author normalization failed'; rm -rf "$tmp"; return;
  }
  comments_json=$(printf '%s' "$comments_json" | jq --argjson nodes "$normalized_comments" '.data.repository.issue.comments.nodes=$nodes')
  ignored=$(printf '%s' "$comments_json" | jq --arg roles "$REVIEW_REVIEWERS$REVIEW_EXECUTORS$REVIEW_APPROVERS" '[.data.repository.issue.comments.nodes[] | select(.author.login as $login | ($roles | split(" ") | index($login)) == null)] | length')
  [ "$ignored" -eq 0 ] || printf 'EVIDENCE ignored %s comment(s) from authors outside the review policy\n' "$ignored"
  printf '%s' "$comments_json" | jq -c --arg roles "$REVIEW_REVIEWERS$REVIEW_EXECUTORS$REVIEW_APPROVERS" '.data.repository.issue.comments.nodes[] | select(.author.login as $login | ($roles | split(" ") | index($login)) != null)' > "$tmp/nodes"
  while IFS= read -r nodes; do
    body=$(printf '%s' "$nodes" | jq -r '.body // empty')
    marker=$(printf '%s\n' "$body" | sed -n '/^[[:space:]]*agentic-flow-review:/p')
    [ -n "$marker" ] || continue
    id=$(printf '%s' "$nodes" | jq -r '.id // empty')
    [ -n "$id" ] || { unverified_evidence 'Tracking issue verdict has no opaque id'; break; }
    if grep -Fxq -- "$id" "$tmp/seen-ids" 2>/dev/null; then
      blocked_evidence "duplicate comment id $id"; break
    fi
    printf '%s\n' "$id" >> "$tmp/seen-ids"
    if [ "$(printf '%s\n' "$marker" | wc -l | tr -d ' ')" -ne 1 ]; then
      blocked_evidence "comment $id has multiple review markers"; break
    fi
    marker=${marker#"${marker%%[![:space:]]*}"}
    if ! parse_review_marker "$marker"; then
      blocked_evidence "comment $id has malformed review record"; break
    fi
    if [ "$REVIEW_HEAD" != "$head" ]; then
      printf 'EVIDENCE %s  superseded comment %s head=%s\n' "$pr_url" "$id" "$REVIEW_HEAD"
      continue
    fi
    dbid=$(printf '%s' "$nodes" | jq -r '.fullDatabaseId // empty')
    if ! printf '%s' "$nodes" | jq -e '.fullDatabaseId | type == "string"' >/dev/null 2>&1 \
       || ! [[ "$dbid" =~ ^[0-9]+$ ]]; then
      unverified_evidence "comment $id missing valid fullDatabaseId"; break
    fi
    normalized=$(normalize_decimal "$dbid")
    if grep -Fxq -- "$normalized" "$tmp/seen-dbids" 2>/dev/null; then
      blocked_evidence "duplicate fullDatabaseId $dbid"; break
    fi
    printf '%s\n' "$normalized" >> "$tmp/seen-dbids"
    if ! printf '%s' "$nodes" | jq -e 'has("lastEditedAt")' >/dev/null; then
      unverified_evidence "comment $id missing lastEditedAt"; break
    fi
    edited=$(printf '%s' "$nodes" | jq -r '.lastEditedAt // empty')
    if [ -z "$selected_id" ] || decimal_greater "$dbid" "$selected_dbid"; then
      if [ -n "$selected_id" ]; then
        printf 'EVIDENCE %s  superseded comment %s head=%s\n' "$pr_url" "$selected_id" "$head"
      fi
      selected_id=$id selected_dbid=$dbid selected_marker=$marker selected_edited=$edited
      selected_author=$(printf '%s' "$nodes" | jq -r '.author.login // empty')
    elif [ "$dbid" = "$selected_dbid" ]; then
      blocked_evidence "comments $selected_id and $id share fullDatabaseId"; break
    else
      printf 'EVIDENCE %s  superseded comment %s head=%s\n' "$pr_url" "$id" "$head"
    fi
  done < "$tmp/nodes"
  if [ "$evidence_reason" != 'external evidence unresolved' ]; then rm -rf "$tmp"; return; fi
  if [ -z "$selected_id" ]; then
    unverified_evidence "Tracking issue has no approval for PR head $head"; rm -rf "$tmp"; return
  fi
  printf 'EVIDENCE %s  comment %s fullDatabaseId=%s lastEditedAt=%s head=%s author=%s\n' \
    "$pr_url" "$selected_id" "$selected_dbid" "${selected_edited:-null}" "$head" "${selected_author:-unavailable}"
  if [ -n "$selected_edited" ]; then
    blocked_evidence "comment $selected_id was edited at $selected_edited"; rm -rf "$tmp"; return
  fi
  parse_review_marker "$selected_marker"
  authenticate_verdict "$selected_id" "$selected_author" "$REVIEW_ROLE" || { rm -rf "$tmp"; return; }
  if [ "$REVIEW_STATUS" != approved ] || [ "$REVIEW_PR" != "$pr_number" ]; then
    blocked_evidence "comment $selected_id does not approve PR $pr_number head $head"; rm -rf "$tmp"; return
  fi
  if [ -z "$REVIEW_ATTEMPT" ]; then
    unverified_evidence "comment $selected_id missing attempt="; rm -rf "$tmp"; return
  fi
  if ! [[ "$REVIEW_ATTEMPT" =~ ^[1-9][0-9]*$ ]]; then
    blocked_evidence "comment $selected_id has malformed attempt="; rm -rf "$tmp"; return
  fi
  case "$REVIEW_RUN" in "https://github.com/$repo/actions/runs/"*) ;; *)
    blocked_evidence "comment $selected_id run repository differs from origin"; rm -rf "$tmp"; return ;; esac
  run_id=${REVIEW_RUN##*/}
  if ! [[ "$run_id" =~ ^[1-9][0-9]*$ ]]; then
    blocked_evidence "comment $selected_id has malformed run="; rm -rf "$tmp"; return
  fi
  if ! bounded_gh "$tmp/run" api "repos/$repo/actions/runs/$run_id"; then
    unverified_evidence "Actions run $run_id unavailable"; rm -rf "$tmp"; return
  fi
  run_json=$(cat "$tmp/run")
  if ! printf '%s' "$run_json" | jq -e '.repository.full_name | type == "string"' >/dev/null 2>&1 \
     || ! printf '%s' "$run_json" | jq -e '.path | type == "string"' >/dev/null 2>&1 \
     || ! printf '%s' "$run_json" | jq -e '.head_sha | type == "string"' >/dev/null 2>&1 \
     || ! printf '%s' "$run_json" | jq -e '.conclusion | type == "string"' >/dev/null 2>&1 \
     || ! printf '%s' "$run_json" | jq -e '.run_attempt | type == "number"' >/dev/null 2>&1; then
    unverified_evidence "Actions run $run_id lacks required fields"; rm -rf "$tmp"; return
  fi
  run_repo=$(printf '%s' "$run_json" | jq -r '.repository.full_name')
  run_path=$(printf '%s' "$run_json" | jq -r '.path')
  # GitHub's run representation can append @<ref> to the workflow file path.
  # Policy identifies the workflow file; the run head is checked separately.
  run_path=${run_path%%@*}
  run_head=$(printf '%s' "$run_json" | jq -r '.head_sha')
  conclusion=$(printf '%s' "$run_json" | jq -r '.conclusion')
  live_attempt=$(printf '%s' "$run_json" | jq -r '.run_attempt')
  if [ "$run_repo" != "$repo" ] || [ "$run_path" != "$workflow" ] || [ "$run_head" != "$head" ]; then
    blocked_evidence "Actions run $REVIEW_RUN differs from repository, workflow, or PR head $head"
  elif [ "$live_attempt" != "$REVIEW_ATTEMPT" ]; then
    blocked_evidence "Actions run $REVIEW_RUN attempt $live_attempt differs from comment $selected_id attempt $REVIEW_ATTEMPT"
  elif [ "$conclusion" != success ]; then
    blocked_evidence "Actions run $REVIEW_RUN concluded $conclusion"
  else
    # Shared by both topologies; Strict checks the PR object once for all steps.
    if ! git -C "$ROOT" cat-file -e "${head}^{commit}" 2>/dev/null; then
      unverified_evidence "PR head SHA $head unavailable locally as a commit; run git fetch origin pull/$pr_number/head"
    elif [ "$topology" = standard ]; then
      step_id=$(printf '%s\n' "$tracking_body" | sed -nE 's/^<!-- agentic-flow:plan:[a-z0-9][a-z0-9._-]* step:([a-z0-9][a-z0-9._-]*) spec:[a-f0-9]{40}.* -->$/\1/p' | head -1)
      if [ -z "$step_id" ]; then
        unverified_evidence 'Standard work issue identity stamp unavailable'
      else
        verify_step_review "$repo" "$issue_number" "$step_id" "$tmp" "$head" reuse-tracking-page || true
      fi
    else
      verify_strict_steps "$repo" "$tracking_body" "$tmp" "$head" || true
    fi
    if [ "$evidence_reason" = 'external evidence unresolved' ]; then
      evidence_status=READY
      evidence_reason="review by $selected_author at head $head via comment $selected_id (fullDatabaseId $selected_dbid, lastEditedAt=null); Actions run $run_id attempt $live_attempt succeeded"
    fi
  fi
  rm -rf "$tmp"
}

# Local writer pre-flight uses the same parser as lifecycle reports. Pending is
# valid while work is active, but no undeclared value can be written through.
if [ "$VALIDATE_DOC_STATUS" = true ]; then
  [ -n "$DOC" ] || { echo 'error: --validate-doc-status requires --doc' >&2; exit 2; }
  parsed=$(status_fields "$DOC")
  if printf '%s\n' "$parsed" | grep -q '^ERROR'; then
    printf '%s\n' "$parsed" | grep '^ERROR' >&2
    exit 1
  fi
  for key in 'Evidence schema' 'Tracking issue' Approval 'Implementation head' \
             'Implementation PR' 'Verification evidence' 'Review verdict' Memory; do
    value=$(printf '%s\n' "$parsed" | awk -F '\t' -v k="$key" '$1 == k { print $2 }')
    [ -n "$value" ] || { echo "error: missing $key" >&2; exit 1; }
    if [ "$key" != 'Evidence schema' ] && [ "$value" = pending ]; then continue; fi
    valid_value "$key" "$value" || { echo "error: invalid $key" >&2; exit 1; }
  done
  exit 0
fi

blocked=0
unverified=0
legacy=0
found=0
check_doc() { # <doc>
  local doc=$1 rel tracker_lines open checked parsed key value field_id schema="" tracking="" pr_url="" missing="" invalid="" \
    parser_error="" state_json issue_state labels state_file issue_body topology approval approval_by approval_at stamp_by stamp_at
  tracker_lines=$(grep -Ec '^- \[[ xX]\] ' "$doc" || true)
  [ "$tracker_lines" -gt 0 ] || return 0
  found=$((found + 1))
  open=$(grep -Ec '^- \[ \] ' "$doc" || true)
  checked=$((tracker_lines - open))
  rel=${doc#"$ROOT"/}
  if [ "$open" -gt 0 ]; then
    printf 'ACTIVE  %s  %s/%s tracker items complete\n' "$rel" "$checked" "$tracker_lines"
    return
  fi
  parsed=$(status_fields "$doc")
  while IFS="$(printf '\t')" read -r key value; do
    [ -n "$key" ] || continue
    if [ "$key" = ERROR ]; then parser_error=$value; break; fi
    case "$key" in
      'Evidence schema') schema=$value ;;
      'Tracking issue') tracking=${value#url=} ;;
      Approval) approval=$value ;;
      'Implementation PR') pr_url=${value#url=} ;;
    esac
  done <<< "$parsed"
  if [ -n "$parser_error" ]; then
    printf 'BLOCKED %s  %s\n' "$rel" "$parser_error"
    blocked=$((blocked + 1)); return
  fi
  if [ -z "$schema" ]; then
    printf 'LEGACY  %s  migrate Status using the v2 Feature/Security template\n' "$rel"
    legacy=$((legacy + 1)); return
  fi
  if [ "$schema" != v2 ]; then
    printf 'BLOCKED %s  invalid Evidence schema\n' "$rel"
    blocked=$((blocked + 1)); return
  fi
  for key in 'Evidence schema' 'Tracking issue' Approval 'Implementation head' \
             'Implementation PR' 'Verification evidence' 'Review verdict' Memory; do
    field_id=$(printf '%s' "$key" | tr '[:upper:] ' '[:lower:]-')
    value=$(printf '%s\n' "$parsed" | awk -F '\t' -v k="$key" '$1 == k { print $2 }')
    if [ -z "$value" ] || [ "$value" = pending ]; then
      missing="$missing $field_id"; continue
    fi
    if ! valid_value "$key" "$value"; then invalid="$invalid $field_id"; fi
  done
  if [ -n "$invalid" ]; then
    printf 'BLOCKED %s  invalid:%s\n' "$rel" "$invalid"
    blocked=$((blocked + 1)); return
  fi
  if [ -n "$missing" ]; then
    printf 'UNVERIFIED %s  missing:%s\n' "$rel" "$missing"
    unverified=$((unverified + 1)); return
  fi
  if [ "$VERIFY_EVIDENCE" = false ]; then
    printf 'READY   %s  local v2 Status valid; external evidence unresolved\n' "$rel"
    return
  fi
  if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    printf 'UNVERIFIED %s  gh or jq unavailable for issue evidence\n' "$rel"
    unverified=$((unverified + 1)); return
  fi
  state_file=$(mktemp "${TMPDIR:-/tmp}/agentic-flow-issue.XXXXXX") || {
    printf 'UNVERIFIED %s  cannot prepare issue lookup\n' "$rel"
    unverified=$((unverified + 1)); return
  }
  if bounded_gh "$state_file" issue view "$tracking" --json state,labels,body; then
    state_json=$(cat "$state_file")
  else
    state_json=""
  fi
  rm -f "$state_file"
  if ! printf '%s' "$state_json" | jq -e '(.state == "OPEN" or .state == "CLOSED") and (.labels | type == "array")' >/dev/null 2>&1; then
    printf 'UNVERIFIED %s  could not resolve tracking issue state\n' "$rel"
    unverified=$((unverified + 1)); return
  fi
  issue_state=$(printf '%s' "$state_json" | jq -r .state)
  labels=$(printf '%s' "$state_json" | jq -r '[.labels[].name] | join(",")')
  case "$PHASE:$issue_state:$labels" in
    close-out:OPEN:*)
      case ",$labels," in *,needs-closing,*) ;; *)
        printf 'BLOCKED %s  phase close-out found OPEN without needs-closing\n' "$rel"
        blocked=$((blocked + 1)); return ;; esac
      case ",$labels," in *,agent:claude,*) ;; *)
        printf 'BLOCKED %s  phase close-out found OPEN without agent:claude\n' "$rel"
        blocked=$((blocked + 1)); return ;; esac ;;
    pre-merge:CLOSED:*) ;;
    *) printf 'BLOCKED %s  phase %s found %s tracking issue\n' "$rel" "$PHASE" "$issue_state"
       blocked=$((blocked + 1)); return ;;
  esac
  issue_body=$(printf '%s' "$state_json" | jq -r '.body // empty')
  topology=legacy
  if printf '%s\n' "$issue_body" | grep -Fxq '<!-- agentic-flow:topology:standard -->'; then
    topology=standard
  elif printf '%s\n' "$issue_body" | grep -Fxq '<!-- agentic-flow:topology:strict -->'; then
    topology=strict
  fi
  if [ "$topology" = standard ]; then
    approval_by=$(printf '%s' "$approval" | sed -nE 's/^status=approved; by=(.*); at=[0-9]{4}-[0-9]{2}-[0-9]{2}$/\1/p')
    approval_at=${approval##*at=}
    stamp_by=$(printf '%s\n' "$issue_body" | sed -n 's/.* approved-by:\(.*\) approved-at:[^ ]* -->.*/\1/p' | head -1)
    stamp_at=$(printf '%s\n' "$issue_body" | sed -n 's/.* approved-at:\([^ ]*\) -->.*/\1/p' | head -1)
    if [ -z "$stamp_by" ] || [ "$stamp_by" != "$approval_by" ] || [ "${stamp_at%%T*}" != "$approval_at" ]; then
      printf 'BLOCKED %s  Standard work issue approval stamp differs from document\n' "$rel"
      blocked=$((blocked + 1)); return
    fi
  fi
  verify_evidence "$tracking" "$pr_url" "$issue_body" "$topology"
  printf '%-10s %s  %s\n' "$evidence_status" "$rel" "$evidence_reason"
  case "$evidence_status" in
    BLOCKED) blocked=$((blocked + 1)) ;;
    UNVERIFIED) unverified=$((unverified + 1)) ;;
  esac
}

if [ -n "$DOC" ]; then
  check_doc "$DOC"
else
  while IFS= read -r doc; do check_doc "$doc"; done < <(find "$ROOT/docs/inprogress" -type f -name '*.md' | sort)
fi
[ "$found" -gt 0 ] || echo 'No active implementation trackers found.'
if [ "$STRICT" = true ] && [ "$blocked" -gt 0 ]; then exit 1; fi
if [ "$STRICT" = true ] && [ "$VERIFY_EVIDENCE" = true ] && [ "$((unverified + legacy))" -gt 0 ]; then exit 1; fi
