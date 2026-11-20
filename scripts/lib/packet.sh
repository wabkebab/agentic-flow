#!/usr/bin/env bash
# Build station input only after admission; keep all output buffered until valid.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/handoff.sh"
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/brief.sh"
. "$(dirname "${BASH_SOURCE[0]}")/verify-record.sh"
. "$(dirname "${BASH_SOURCE[0]}")/packet-findings.sh"

packet_error() { printf 'packet: %s\n' "$*" >&2; }
packet_words() {
  local data content serialized
  data=$(cat)
  content=$(printf '%s' "$data" | jq -r '[..|strings]|join("\n")' | wc -w | tr -d ' ')
  serialized=$(printf '%s' "$data" | wc -w | tr -d ' ')
  if [ "$content" -gt "$serialized" ]; then printf '%s\n' "$content"; else printf '%s\n' "$serialized"; fi
}

packet_format() { # packet JSON file -> station prompt
  jq -r '
    "Station: "+.station+" · issue #"+(.issue|tostring)+" · approved "+.approved,
    .brief,"Journal:",(.journal|tojson),"Findings:",
    (.findings_file|select(.!=null)|"Findings file: "+.path+" (count "+(.count|tostring)+", sha256 "+.sha256+")"),
    (.findings[]?|if has("body") then .body else "\(.severity) \(.file):\(.line//"?") \(.text)" end),
    .findings_index[]?,
    "Latest submit:",(.submit.body//"none"),"Verification:",(.verification|if type=="string" then . else tojson end),.notice' "$1"
}

packet_measure() { # packet JSON file, requested presentation file
  local words count
  words=$(packet_words < "$1") || return 3
  count=$(wc -w < "$2" | tr -d ' ') || return 3
  if [ "$count" -gt "$words" ]; then printf '%s\n' "$count"; else printf '%s\n' "$words"; fi
}

packet_cmd() (
  local number=${1:-} station='' json=false root tmp initial body author stamp approved doc step plan query comments accepted submit_id submit_index findings submit dropped brief journal verification common head selected red_base key command_plan record words part count largest='' maximum=0
  local bounce bounce_id bounce_seq findings_file=null word_limit=3000 reserve
  [[ "$number" =~ ^[1-9][0-9]{0,9}$ ]] || return 2
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --station) [ "$#" -ge 2 ] || return 2; station=$2; shift 2 ;;
      --json) json=true; shift ;;
      *) packet_error "unknown flag: $1"; return 2 ;;
    esac
  done
  case "$station" in executor|reviewer) ;; *) packet_error '--station requires executor or reviewer'; return 2 ;; esac
  if [ -n "${PACKET_SUFFIX_FILE:-}" ]; then
    reserve=$(wc -w < "$PACKET_SUFFIX_FILE") || return 3
    word_limit=$((word_limit-reserve))
  fi
  root=$(git rev-parse --show-toplevel) || return 3
  cd "$root" || return 3
  workflow_load "$root" && read_review_policy "$root" || return 3
  # shellcheck disable=SC2034 # The read-only adapter consumes these context variables.
  HANDOFF_ROOT=$root HANDOFF_TOKEN=''
  HANDOFF_REPO=$(identity_repository "$root") || return 3
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/agentic-packet.XXXXXX") || return 3
  # shellcheck disable=SC2034 # Used by handoff_read.
  HANDOFF_TMP=$tmp
  trap 'rm -rf "$tmp"' EXIT
  # GraphQL preserves the Bot type, unlike gh issue view --json author.
  # shellcheck disable=SC2016
  query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){number body author{login __typename}}}}'
  initial=$(handoff_gh api graphql -f "query=$query" -f "owner=${HANDOFF_REPO%%/*}" -f "name=${HANDOFF_REPO#*/}" -F "number=$number") || return 3
  initial=$(printf '%s' "$initial" | jq -ec --argjson n "$number" '
    if (.errors//[]|length)>0 then error("issue read failed") else .data.repository.issue end |
    if .number!=$n or (.body|type)!="string" or (.author.login|type)!="string"
    then error("invalid issue") else . end') || return 3
  author=$(printf '%s' "$initial" | jq '[{author:.author}]' | review_normalize_comments | jq -r '.[0].author.login') || return 3
  review_valid_login "$author" || { packet_error 'invalid issue author'; return 3; }
  case "$REVIEW_APPROVERS" in *" $author "*) ;; *) packet_error 'issue creator is not an approver'; return 3 ;; esac
  body=$(printf '%s' "$initial" | jq -r .body)
  stamp=$(printf '%s' "$body" | journal_stamp) || { packet_error 'no valid plan stamp'; return 3; }
  approved=$(printf '%s' "$body" | jq -Rser '
    [split("\n")[]|select(startswith("<!-- agentic-flow:plan:"))|
      [scan("(?:^| )approved=([a-f0-9]{40})(?= |$)")|.[0]]] |
    if length==1 and (.[0]|length)==1 then .[0][0] else error("missing or ambiguous approved stamp") end') || return 3
  git cat-file -e "$approved^{commit}" 2>/dev/null || {
    packet_error "approved revision $approved missing locally; run: git fetch origin $approved"; return 3;
  }
  plan=$(printf '%s' "$stamp" | jq -r .plan)
  step=$(printf '%s' "$stamp" | jq -r .step)
  [ "$step" != tracker ] || { packet_error 'packet requires a step issue'; return 3; }
  # Both generated @rev references and the bootstrap backtick form are supported.
  doc=$(printf '%s' "$body" | jq -Rser '
    [split("\n")[]|select(startswith("Brief: "))|
      capture("^Brief: `?(?<doc>docs/[A-Za-z0-9_./-]+\\.md)(`|@| )").doc]|unique|
    if length==1 then .[0] else error("missing or ambiguous brief path") end') || return 3
  case "$doc" in *'/../'*|*'/./'*|*/..) packet_error 'invalid brief path'; return 3 ;; esac
  git show "$approved:$doc" > "$tmp/doc" || return 3
  brief_parse "$tmp/doc" "$doc" "$approved" > "$tmp/spec" || return 3
  jq -e --arg p "$plan" --arg s "$step" '.id==$p and any(.steps[];.id==$s)' "$tmp/spec" >/dev/null || {
    packet_error 'stamp does not identify an approved step'; return 3;
  }
  # shellcheck disable=SC2034 # Used by handoff_read.
  HANDOFF_PLAN=$plan
  handoff_read "$number" || return 3
  [ "$(printf '%s' "$HANDOFF_ISSUE" | jq -r .body)" = "$body" ] || { packet_error 'issue changed during admission; retry'; return 3; }
  comments=$(printf '%s' "$HANDOFF_ISSUE" | jq .comments.nodes | journal_normalize) || return 3
  printf '%s\n' "$comments" > "$tmp/comments" || return 3
  comments=$(jq 'map(.body|=(split("\n")|map(select(startswith("agentic-flow-run:")|not))|join("\n")))' "$tmp/comments") || return 3
  journal=$HANDOFF_REPLAY
  dropped=$(printf '%s' "$comments" | jq --arg policy "$REVIEW_EXECUTORS$REVIEW_REVIEWERS$REVIEW_APPROVERS" '[.[]|select(.author as $a|($policy|split(" ")|index($a))==null)]|length') || return 3
  accepted=$(printf '%s' "$journal" | jq -c '[.accepted[]|select(.event=="submit")]|last // null')
  submit_id=$(printf '%s' "$accepted" | jq -r '.comment_id // ""')
  submit_index=$(printf '%s' "$comments" | jq --arg id "$submit_id" 'map(.id)|index($id)// -1')
  findings='[]' submit=null verification=null
  if [ "$station" = executor ]; then
    bounce=$(printf '%s' "$journal" | jq -c --argjson submit "$accepted" '
      [.accepted[]|select(.event=="bounce" and .seq>($submit.seq//0))]|last//null') || return 3
    bounce_id=$(printf '%s' "$bounce" | jq -r '.comment_id//""')
    if [ -n "$bounce_id" ]; then
      bounce_seq=$(printf '%s' "$bounce" | jq .seq)
      common=$(git rev-parse --git-common-dir) && common=$(cd "$common" && pwd -P) || return 3
      if ! { jq -e --arg id "$bounce_id" '.[]|select(.id==$id)' "$tmp/comments" > "$tmp/bounce" &&
        packet_findings_source "$plan" "$number" "$bounce" "$tmp/bounce" "$tmp/findings-source" &&
        findings_file=$(packet_findings_publish "$tmp/findings-source" \
          "$common/agentic-flow/findings/$plan/$number/$bounce_seq.json" "${PACKET_FINDINGS_DIR:-}"); }; then
        packet_findings_error "cannot recover or deliver findings for #$number bounce $bounce_seq"
        return $?
      fi
    fi
    # shellcheck disable=SC2016 # jq variables
    findings=$(printf '%s' "$comments" | journal_jq --arg reviewers "$REVIEW_REVIEWERS" --argjson since "$submit_index" --arg bounce "$bounce_id" '
      include "journal-marker";
      [to_entries[] | select(.key>$since) | .value | select(.id!=$bounce) |
        select(.author as $a|($reviewers|split(" ")|index($a))!=null) |
        select(.body|journal_marker_line|(startswith("agentic-flow-hold:") or startswith("agentic-flow-hold-clear:"))|not)]') || return 3
  else
    submit=$(printf '%s' "$comments" | jq --arg id "$submit_id" '[.[]|select(.id==$id)]|first // null')
    verification='"no record; run verify-step"'
    head=$(printf '%s' "$accepted" | jq -r '.head // "none"')
    if [[ "$head" =~ ^[a-f0-9]{40}$ ]]; then
      common=$(git rev-parse --git-common-dir) || return 3
      record="$common/agentic-flow/verify/$head.json"
      if [ -f "$record" ]; then
        [ "$(wc -c < "$record" | tr -d ' ')" -le 262144 ] || { packet_error 'packet exceeds cap; largest part: verification'; return 3; }
        selected=$(jq -c --arg s "$step" '.steps[]|select(.id==$s)' "$tmp/spec") || return 3
        command_plan=$(verify_record_plan "$selected") || return 3
        # The verifier may use an explicit pre-submit base spanning several commits.
        # Retain that base, but require it to be a real ancestor of this head.
        red_base=$(jq -er '.red_base|select(type=="string")' "$record" 2>/dev/null) || red_base=''
        verification='"stale or invalid record; run verify-step"'
        if [ -n "$red_base" ] && git merge-base --is-ancestor "$red_base" "$head" 2>/dev/null &&
          key=$(verify_record_key "$head" "$doc" "$step" "$red_base" "$command_plan") &&
          part=$(verify_record_fresh "$record" "$key"); then
          verification=$part
        fi
      fi
    fi
  fi
  brief=$(brief_cmd "$doc" "$step" --at "$approved") || return 3
  printf '%s\n' "$findings" > "$tmp/findings-other" || return 3
  [ -f "$tmp/findings-source" ] || printf '[]\n' > "$tmp/findings-source" || return 3
  printf '%s\n' "$submit" > "$tmp/submit" && printf '%s\n' "$verification" > "$tmp/verification" || return 3
  jq -n --argjson number "$number" --arg station "$station" --arg approved "$approved" --arg plan "$plan" --arg step "$step" --arg brief "$brief" \
    --argjson journal "$journal" --slurpfile other "$tmp/findings-other" --slurpfile source "$tmp/findings-source" \
    --argjson findings_file "$findings_file" --slurpfile submit "$tmp/submit" --slurpfile verification "$tmp/verification" --argjson dropped "$dropped" \
    '{v:1,issue:$number,station:$station,approved:$approved,plan:$plan,step:$step,brief:$brief,journal:$journal,
      findings:($source[0]+$other[0]),findings_file:$findings_file,submit:$submit[0],verification:$verification[0],
      dropped:$dropped,notice:("dropped "+($dropped|tostring)+" comment(s) from authors outside the policy")}' > "$tmp/packet" || return 3
  packet_format "$tmp/packet" > "$tmp/output" || return 3
  words=$(packet_measure "$tmp/packet" "$tmp/output") || return 3
  if [ "$words" -gt "$word_limit" ] && [ "$findings_file" != null ]; then
    jq --slurpfile other "$tmp/findings-other" '.findings=$other[0]' "$tmp/packet" > "$tmp/without-source" || return 3
    packet_format "$tmp/without-source" > "$tmp/output" || return 3
    words=$(packet_measure "$tmp/without-source" "$tmp/output") || return 3
    packet_findings_index "$tmp/findings-source" "$((word_limit-words))" > "$tmp/index" || return 3
    jq --slurpfile index "$tmp/index" '.findings_index=$index[0]' "$tmp/without-source" > "$tmp/indexed" || return 3
    mv "$tmp/indexed" "$tmp/packet" || return 3
    packet_format "$tmp/packet" > "$tmp/output" || return 3
    words=$(packet_measure "$tmp/packet" "$tmp/output") || return 3
  fi
  if [ "$words" -gt "$word_limit" ]; then
    for part in brief journal findings submit verification; do
      count=$(jq --arg part "$part" '.[$part]' "$tmp/packet" | packet_words)
      if [ "$count" -gt "$maximum" ]; then maximum=$count; largest=$part; fi
    done
    packet_error "packet exceeds 3000 words ($((words+3000-word_limit))); largest part: $largest ($maximum words)"; return 3
  fi
  if [ "$json" = true ]; then cat "$tmp/packet"; else cat "$tmp/output"; fi
)
