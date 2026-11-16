#!/usr/bin/env bash
# Build station input only after admission; keep all output buffered until valid.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/handoff.sh"
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/brief.sh"

packet_error() { printf 'packet: %s\n' "$*" >&2; }
packet_words() {
  local data content serialized
  data=$(cat)
  content=$(printf '%s' "$data" | jq -r '[..|strings]|join("\n")' | wc -w | tr -d ' ')
  serialized=$(printf '%s' "$data" | wc -w | tr -d ' ')
  if [ "$content" -gt "$serialized" ]; then printf '%s\n' "$content"; else printf '%s\n' "$serialized"; fi
}

packet_cmd() (
  local number=${1:-} station='' json=false root tmp initial body author stamp approved doc step plan query comments accepted submit_id submit_index findings submit dropped brief journal verification common head tree implementation record packet words part count largest='' maximum=0
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
  journal=$HANDOFF_REPLAY
  dropped=$(printf '%s' "$comments" | jq --arg policy "$REVIEW_EXECUTORS$REVIEW_REVIEWERS$REVIEW_APPROVERS" '[.[]|select(.author as $a|($policy|split(" ")|index($a))==null)]|length') || return 3
  accepted=$(printf '%s' "$journal" | jq -c '[.accepted[]|select(.event=="submit")]|last // null')
  submit_id=$(printf '%s' "$accepted" | jq -r '.comment_id // ""')
  submit_index=$(printf '%s' "$comments" | jq --arg id "$submit_id" 'map(.id)|index($id)// -1')
  findings='[]' submit=null verification=null
  if [ "$station" = executor ]; then
    findings=$(printf '%s' "$comments" | jq --arg reviewers "$REVIEW_REVIEWERS" --argjson since "$submit_index" '[to_entries[]|select(.key>$since)|.value|select(.author as $a|($reviewers|split(" ")|index($a))!=null)|select((.body|startswith("agentic-flow-hold:")) or (.body|startswith("agentic-flow-hold-clear:"))|not)]') || return 3
  else
    submit=$(printf '%s' "$comments" | jq --arg id "$submit_id" '[.[]|select(.id==$id)]|first // null')
    verification='"no record; run verify-step"'
    head=$(printf '%s' "$accepted" | jq -r '.head // "none"')
    if [[ "$head" =~ ^[a-f0-9]{40}$ ]]; then
      common=$(git rev-parse --git-common-dir) || return 3
      record="$common/agentic-flow/verify/$head.json"
      if [ -f "$record" ]; then
        [ "$(wc -c < "$record" | tr -d ' ')" -le 262144 ] || { packet_error 'packet exceeds cap; largest part: verification'; return 3; }
        tree=$(git rev-parse --verify "$head^{tree}" 2>/dev/null) || tree=''
        implementation=$(shasum -a 256 "$root/scripts/lib/verify-step.sh") || return 3
        implementation=${implementation%% *}
        if jq -e --arg sha "$head" --arg tree "$tree" --arg impl "$implementation" '
          .v==1 and .sha==$sha and .tree==$tree and .verifier.implementation_sha256==$impl and
          (.verifier.signature_source.sha|type)=="string" and (.verifier.signature_source.tree|type)=="string" and
          (.verifier.signature_source.pattern|type)=="string"' "$record" >/dev/null 2>&1; then
          verification=$(cat "$record")
        else verification='"stale or invalid record; run verify-step"'; fi
      fi
    fi
  fi
  brief=$(brief_cmd "$doc" "$step" --at "$approved") || return 3
  packet=$(jq -n --argjson number "$number" --arg station "$station" --arg approved "$approved" --arg plan "$plan" --arg step "$step" --arg brief "$brief" \
    --argjson journal "$journal" --argjson findings "$findings" --argjson submit "$submit" --argjson verification "$verification" --argjson dropped "$dropped" \
    '{v:1,issue:$number,station:$station,approved:$approved,plan:$plan,step:$step,brief:$brief,journal:$journal,findings:$findings,submit:$submit,verification:$verification,dropped:$dropped,notice:("dropped "+($dropped|tostring)+" comment(s) from authors outside the policy")}') || return 3
  if [ "$json" = true ]; then printf '%s\n' "$packet" > "$tmp/output"
  else
    printf '%s' "$packet" | jq -r '"Station: "+.station+" · issue #"+(.issue|tostring)+" · approved "+.approved,
      .brief,"Journal:",(.journal|tojson),"Findings:",(.findings[]?.body),"Latest submit:",(.submit.body//"none"),"Verification:",(.verification|if type=="string" then . else tojson end),.notice' > "$tmp/output" || return 3
  fi
  words=$(printf '%s' "$packet" | packet_words)
  count=$(wc -w < "$tmp/output" | tr -d ' ')
  [ "$count" -le "$words" ] || words=$count
  if [ "$words" -gt 3000 ]; then
    for part in brief journal findings submit verification; do
      count=$(printf '%s' "$packet" | jq --arg part "$part" '.[$part]' | packet_words)
      if [ "$count" -gt "$maximum" ]; then maximum=$count; largest=$part; fi
    done
    packet_error "packet exceeds 3000 words ($words); largest part: $largest ($maximum words)"; return 3
  fi
  cat "$tmp/output"
)
