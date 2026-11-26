#!/usr/bin/env bash
# Build station input only after admission; keep all output buffered until valid.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/handoff.sh"
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/brief.sh"
. "$(dirname "${BASH_SOURCE[0]}")/verify-record.sh"
. "$(dirname "${BASH_SOURCE[0]}")/packet-findings.sh"
. "$(dirname "${BASH_SOURCE[0]}")/config.sh"

packet_error() { printf 'packet: %s\n' "$*" >&2; }
packet_words() {
  local data content serialized
  data=$(cat)
  content=$(printf '%s' "$data" | jq -r '[..|strings]|join("\n")' | wc -w | tr -d ' ')
  serialized=$(printf '%s' "$data" | wc -w | tr -d ' ')
  if [ "$content" -gt "$serialized" ]; then printf '%s\n' "$content"; else printf '%s\n' "$serialized"; fi
}

packet_decision() { # station journal-json normalized-comments-json
  jq -cs --arg station "$1" '
    def heading($entry):
      (if $entry.event=="ask" then "### ❓ Decision requested · " else "### ▶️ Resumed · " end) + $entry.step;
    def prose($entry):
      split("\n") |
      (if (.[0]|startswith("<!-- agentic-flow-transition:")) and index("-->")!=null then
         .[(index("-->")+1):]
       elif (.[0]|startswith("agentic-flow-transition:")) then .[1:]
       else . end) |
      (heading($entry) as $heading |
       if (.[0]//""|.==$heading or startswith($heading+" — "))
       then .[1:] | if .[0]=="" then .[1:] else . end |
         ("Role: \($entry.role) · Transition: \($entry.seq)" +
           (if ($entry.head//"none")=="none" then "" else " · Head: `\($entry.head[:12])`" end)) as $facts |
         if .[0]==$facts then .[1:] else . end
       else . end) | join("\n") |
      sub("(^|\\n)<!--\\nagentic-flow-run: run=[a-zA-Z0-9/._-]+; host=[a-zA-Z0-9._-]+\\n-->\\n*\\z";"") |
      (if $entry.event=="ask" then sub("(^|\\n\\n)@[a-zA-Z0-9-]+ needs a decision: [^\\n]*\\n*\\z";"") else . end) |
      sub("\\A\\n+|\\n+\\z";"";"g");
    def body($comments; $entry):
      ([$comments[]|select(.id==$entry.comment_id)|.body]|first) //
        ("packet: decision comment \($entry.comment_id) not found; retry\n"|halt_error(3)) |
      prose($entry);
    .[0].accepted as $entries | .[1] as $comments |
    ([$entries[]|select(.event=="submit")]|last|.seq//0) as $cutoff |
    ([$entries[]|select(.event=="ask" and .role==$station and .seq>$cutoff)]|last) as $ask |
    if $ask==null then null else
      ([$entries[]|select(.event=="resume" and .seq==($ask.seq+1))]|first) as $answer |
      {ask:($ask|{seq,role,comment_id,body:body($comments;$ask)}),
       answer:(if $answer==null then null else $answer|{seq,comment_id,body:body($comments;$answer)} end)}
    end' <<< "$2"$'\n'"$3" || return 3
}

packet_format() { # packet JSON file -> station prompt
  journal_jq -r '
    include "journal-marker";
    "Station: "+.station+" · issue #"+(.issue|tostring)+" · approved "+.approved,
    .brief,
    (.blocking_threshold | select(.!=null) |
      "Blocking threshold: \(.). Bounce only for findings at or above it; report the rest in an approve."),
    (.decision|select(.!=null)|
      "Owner decision:", "Question (seq \(.ask.seq)):", .ask.body,
      (if .answer==null then "Answer: none yet" else "Answer (seq \(.answer.seq)):", .answer.body end),
      (.file|select(.!=null)|"Full text: \(.path) (sha256 \(.sha256))")),
    "Journal:",(.journal|tojson),"Findings:",
    (.findings_file|select(.!=null)|"Findings file: "+.path+" (count "+(.count|tostring)+", sha256 "+.sha256+")"),
    (.findings[]?|if has("body") then .body else "\(.severity|review_severity) \(.file):\(.line//"?") \(.text)" end),
    .findings_index[]?,
    "Latest submit:",(.submit.body//"none"),
    (if has("policy_files_changed") then
      "Policy files changed:", (if .policy_files_changed==[] then "none" else .policy_files_changed[] end)
     else empty end),
    "Verification:",(.verification|if type=="string" then . else tojson end),.notice' "$1"
}

packet_measure() { # packet JSON file, requested presentation file
  local words count
  words=$(packet_words < "$1") || return 3
  count=$(wc -w < "$2" | tr -d ' ') || return 3
  if [ "$count" -gt "$words" ]; then printf '%s\n' "$count"; else printf '%s\n' "$words"; fi
}

packet_render_words() { # packet JSON file rendered file
  packet_format "$1" > "$2" && packet_measure "$1" "$2"
}

packet_over_limit() { # packet JSON file configured limit total words (including suffix)
  local packet=$1 cap=$2 words=$3 part count largest='' maximum=0
  for part in brief journal decision findings submit policy_files_changed verification; do
    count=$(jq --arg part "$part" '.[$part]' "$packet" | packet_words)
    if [ "$count" -gt "$maximum" ]; then maximum=$count; largest=$part; fi
  done
  packet_error "packet exceeds $cap words ($words); largest part: $largest ($maximum words)"
  return 3
}

packet_clip_decision() { # intact decision file shell decision file prose budget
  jq --argjson budget "$3" --slurpfile shell "$2" '
    def clip($words; $take):
      if ($words|length)<=$take then .
      elif $take==0 then "[clipped]"
      else .[:($words[$take-1]|.offset+.length)]+" [clipped]" end;
    [.ask.body|match("\\S+";"g")] as $question |
    [.answer.body//""|match("\\S+";"g")] as $answer |
    ([($question|length), ([60,($budget*0.4|floor)]|max)]|min) as $question_share |
    ([($answer|length), ($budget-$question_share)]|min) as $answer_share |
    .ask.body |= clip($question; $budget-$answer_share) |
    (if .answer!=null then .answer.body |= clip($answer; $answer_share) else . end) |
    .clipped=true | .file=$shell[0].file' "$1"
}

packet_fit_decision() { # scratch directory configured cap suffix words measured-full-packet findings-file plan issue
  local tmp=$1 cap=$2 suffix=$3 full_words=$4 findings_file=$5 plan=$6 number=$7
  local limit=$((cap-suffix)) base base_words intact_words reserve prose room=0 seq common dest path shell_words words fitted
  local index_budget=0 pass=0 clipped=false
  base="$tmp/base"
  jq --slurpfile other "$tmp/findings-other" '.findings=$other[0]' "$tmp/packet" > "$base" || return 3
  base_words=$(packet_render_words "$base" "$tmp/base-rendered") || return 3
  fitted="$tmp/intact-decision"
  jq '.+{clipped:false,file:null}' "$tmp/decision" > "$fitted" || return 3
  jq --slurpfile decision "$fitted" '.decision=$decision[0]' "$base" > "$tmp/intact" || return 3
  intact_words=$(packet_render_words "$tmp/intact" "$tmp/probe") || return 3
  prose=$(jq '[(.ask.body, (.answer.body//"")) | scan("\\S+")]|length' "$tmp/decision") || return 3
  reserve=$((intact_words-base_words))
  if [ "$prose" -gt 600 ] || [ "$intact_words" -gt "$limit" ]; then
    clipped=true
    seq=$(jq -r .ask.seq "$tmp/decision") || return 3
    common=$(git rev-parse --git-common-dir) && common=$(cd "$common" && pwd -P) || return 3
    dest="$common/agentic-flow/decisions/$plan/$number/$seq.md"
    path=$dest
    if [ -n "${PACKET_FINDINGS_DIR:-}" ]; then path="$PACKET_FINDINGS_DIR/decision.md"; fi
    jq --arg path "$path" '
      .ask.body="[clipped]" | if .answer!=null then .answer.body="[clipped]" else . end |
      .clipped=true | .file={path:$path,sha256:("0"*64)}' "$tmp/decision" > "$tmp/shell" || return 3
    jq --slurpfile shell "$tmp/shell" '.decision=$shell[0]' "$base" > "$tmp/probe-json" || return 3
    shell_words=$(packet_render_words "$tmp/probe-json" "$tmp/probe") || return 3
    room=$((limit-shell_words))
    [ "$room" -le 600 ] || room=600
    [ "$room" -ge 80 ] || { packet_over_limit "$tmp/intact" "$cap" "$((intact_words+suffix))"; return 3; }
    reserve=$((shell_words-base_words+room))
  fi

  # Try the complete findings with the reserved decision before considering an index.
  if [ "$findings_file" != null ]; then
    if [ "$((full_words+reserve))" -le "$limit" ]; then
      base="$tmp/packet"
    else
      index_budget=$((limit-base_words-reserve))
    fi
  fi
  if [ "$clipped" = true ]; then
    fitted="$tmp/clipped-decision"
    packet_clip_decision "$tmp/decision" "$tmp/shell" "$room" > "$fitted" || return 3
  fi
  while :; do
    if [ "$index_budget" -ge 12 ]; then
      packet_findings_index "$tmp/findings-source" "$index_budget" > "$tmp/index" || return 3
      jq --slurpfile index "$tmp/index" --slurpfile decision "$fitted" \
        '.findings_index=$index[0] | .decision=$decision[0]' "$base" > "$tmp/candidate" || return 3
    else
      jq --slurpfile decision "$fitted" '.decision=$decision[0]' "$base" > "$tmp/candidate" || return 3
    fi
    words=$(packet_render_words "$tmp/candidate" "$tmp/output") || return 3
    [ "$words" -gt "$limit" ] || break
    if [ "$pass" -eq 3 ]; then packet_over_limit "$tmp/candidate" "$cap" "$((words+suffix))"; return 3; fi
    if [ "$base" = "$tmp/packet" ]; then
      # JSON and rendered word counts can dominate different parts of the sum.
      base="$tmp/base"
      index_budget=$((limit-base_words-reserve))
    elif [ "$index_budget" -ge 12 ]; then
      index_budget=$((index_budget-(words-limit)))
    else
      # With no index, an intact decision was already measured to fit the base.
      room=$((room-(words-limit)))
      [ "$room" -ge 80 ] || { packet_over_limit "$tmp/candidate" "$cap" "$((words+suffix))"; return 3; }
      packet_clip_decision "$tmp/decision" "$tmp/shell" "$room" > "$fitted" || return 3
    fi
    pass=$((pass+1))
  done
  if [ "$clipped" = true ]; then
    if ! { jq -r '"# Owner decision", "", "## Question (seq \(.ask.seq))", "", .ask.body, "",
      (if .answer==null then "## Answer: none yet" else "## Answer (seq \(.answer.seq))", "", .answer.body end)' \
      "$tmp/decision" > "$tmp/decision.md" &&
      packet_publish_file "$tmp/decision.md" "$dest" "${PACKET_FINDINGS_DIR:-}" decision.md > "$tmp/published"; }; then
      packet_error "cannot deliver decision for #$number ask $seq"
      return 3
    fi
    jq --slurpfile file "$tmp/published" '.decision.file=$file[0]' "$tmp/candidate" > "$tmp/packet" || return 3
    packet_render_words "$tmp/packet" "$tmp/output" || return 3
  else
    mv "$tmp/candidate" "$tmp/packet" || return 3
    printf '%s\n' "$words"
  fi
}

packet_policy_files() { # approved SHA submitted SHA
  local approved=$1 head=$2 base path status changed=''
  [ "$approved" != "$head" ] || { printf '[]\n'; return 0; }
  base=$(git merge-base "$approved" "$head") || {
    packet_error "cannot compare policy files from $approved to $head"
    return 3
  }
  for path in .agentic-flow/config config/config-keys.tsv config/test-budgets.tsv config/test-wall-ceilings.tsv; do
    status=0
    git diff --quiet --no-ext-diff --ignore-submodules=none "$base" "$head" -- "$path" || status=$?
    case "$status" in 0) ;; 1) changed+="$path"$'\n' ;; *) return 3 ;; esac
  done
  printf '%s' "$changed" | jq -Rsc 'split("\n") | map(select(length>0))'
}

packet_cmd() (
  local number=${1:-} station='' json=false root tmp initial body author stamp approved doc step plan query comments accepted submit_id submit_index findings submit dropped brief journal decision verification common head selected red_base key command_plan record words part
  local bounce bounce_id bounce_seq findings_file=null word_cap word_limit suffix=0 policy_files='[]' threshold=judgment
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
  config_load "$root" || return $?
  word_cap=$(config_get packet.word_limit) || return 2
  if [ -n "${PACKET_SUFFIX_FILE:-}" ]; then
    suffix=$(wc -w < "$PACKET_SUFFIX_FILE") || return 3
  fi
  word_limit=$((word_cap-suffix))
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
  stamp=$(printf '%s' "$body" | journal_stamp_lines body) || { packet_error 'no valid plan stamp'; return 3; }
  approved=$(printf '%s' "$stamp" | jq -er .approved) || { packet_error 'missing or ambiguous approved stamp'; return 3; }
  git cat-file -e "$approved^{commit}" 2>/dev/null || {
    packet_error "approved revision $approved missing locally; run: git fetch origin $approved"; return 3;
  }
  plan=$(printf '%s' "$stamp" | jq -r .plan)
  step=$(printf '%s' "$stamp" | jq -r .step)
  [ "$step" != tracker ] || { packet_error 'packet requires a step issue'; return 3; }
  # Prefer the path stamp on rendered issues. Older bodies keep their generated
  # @rev reference or bootstrap backtick form.
  doc=$(printf '%s' "$body" | jq -Rser '
    split("\n") as $lines |
    [$lines[]|capture("^<!-- agentic-flow:brief:(?<doc>docs/[A-Za-z0-9_./-]+\\.md) -->$").doc] |
    if length>0 then . else
      [$lines[]|capture("^Brief: `?(?<doc>docs/[A-Za-z0-9_./-]+\\.md)(`|@| )").doc]|unique
    end |
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
  decision=$(packet_decision "$station" "$journal" "$comments") || return 3
  printf '%s\n' "$decision" > "$tmp/decision" || return 3
  printf '%s\n' "$comments" > "$tmp/comments" || return 3
  comments=$(jq 'map(.body|=(split("\n")|map(select(startswith("agentic-flow-run:")|not))|join("\n")))' "$tmp/comments") || return 3
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
        select(.body|journal_marker_line|(startswith("agentic-flow-hold:") or startswith("agentic-flow-hold-clear:") or
          startswith("agentic-flow-transition:"))|not)]') || return 3
  else
    threshold=$(printf '%s' "$stamp" | jq -er .pin.block_at) || return 3
    submit=$(printf '%s' "$comments" | jq --arg id "$submit_id" '[.[]|select(.id==$id)]|first // null')
    verification='"no record; run verify-step"'
    head=$(printf '%s' "$accepted" | jq -r '.head // "none"')
    if [[ "$head" =~ ^[a-f0-9]{40}$ ]]; then
      policy_files=$(packet_policy_files "$approved" "$head") || return 3
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
    --argjson findings_file "$findings_file" --argjson policy_files "$policy_files" --arg threshold "$threshold" \
    --slurpfile submit "$tmp/submit" --slurpfile verification "$tmp/verification" --argjson dropped "$dropped" \
    '{v:1,issue:$number,station:$station,approved:$approved,plan:$plan,step:$step,brief:$brief,journal:$journal,
      findings:($source[0]+$other[0]),findings_file:$findings_file,submit:$submit[0],verification:$verification[0],
      decision:null,dropped:$dropped,notice:("dropped "+($dropped|tostring)+" comment(s) from authors outside the policy")} |
      if $station=="reviewer" then .policy_files_changed=$policy_files else . end |
      if $threshold!="judgment" then .blocking_threshold=$threshold else . end' > "$tmp/packet" || return 3
  words=$(packet_render_words "$tmp/packet" "$tmp/output") || return 3
  if [ "$decision" != null ]; then
    words=$(packet_fit_decision "$tmp" "$word_cap" "$suffix" "$words" "$findings_file" "$plan" "$number") || return 3
  elif [ "$words" -gt "$word_limit" ] && [ "$findings_file" != null ]; then
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
    packet_over_limit "$tmp/packet" "$word_cap" "$((words+suffix))"; return 3
  fi
  if [ "$json" = true ]; then cat "$tmp/packet"; else cat "$tmp/output"; fi
)
