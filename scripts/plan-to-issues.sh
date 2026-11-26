#!/usr/bin/env bash
#
# plan-to-issues.sh — reconcile Standard work issues or Strict tracker/sub-issues.
#
# Usage:
#   scripts/plan-to-issues.sh <spec.json>                   # offline dry run
#   scripts/plan-to-issues.sh --diff <spec.json>            # compare with GitHub
#   scripts/plan-to-issues.sh --doc <path> [--apply|--diff] # approved brief
#   scripts/plan-to-issues.sh --apply [--doc <path>] <spec> # legacy JSON
#
# With an approved --doc, repeat --adopt <step-id>=<issue-number> to reuse open
# issues in this repository. Strict plans also accept --adopt tracker=<number>.
# Apply appends the packet and adds creation labels while retaining the original
# title, description, and labels. Keep handwritten edits above the adopted marker.
# Dry run prints the mappings; --diff also checks the issues on GitHub.
#
# Stable identity:
#   spec.id, or a hash of tracking.title when id is omitted
#   steps[].id, or step-N when id is omitted
#
# Every issue receives an HTML identity stamp. Re-running --apply discovers those stamps,
# resumes partial work, edits changed artifacts in place, and closes removed steps with a
# comment. It never identifies plans by editable issue titles.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)

MODE=dry
SPEC=""
DOC=""
APPROVED_BY=""
ADOPT=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) MODE=apply; shift ;;
    --diff) MODE="diff"; shift ;;
    --doc)
      [ "$#" -ge 2 ] || { echo "error: --doc requires a path" >&2; exit 2; }
      DOC="$2"; shift 2 ;;
    --approved-by)
      [ "$#" -ge 2 ] || { echo "error: --approved-by requires a name" >&2; exit 2; }
      APPROVED_BY="$2"; shift 2 ;;
    --adopt)
      [ "$#" -ge 2 ] || { echo "error: --adopt requires <step-id>=<issue-number>" >&2; exit 2; }
      [ "${#ADOPT[@]}" -lt 101 ] || { echo "error: too many --adopt mappings" >&2; exit 2; }
      ADOPT+=("$2"); shift 2 ;;
    -h|--help) awk 'NR==1 {next} /^#/ {print; next} {exit}' "$0"; exit 0 ;;
    -*)
      echo "error: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      [ -z "$SPEC" ] || { echo "error: multiple spec files provided" >&2; exit 2; }
      SPEC="$1"; shift
      ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

if [ "${#ADOPT[@]}" -gt 0 ] && { [ -z "$DOC" ] || [ -n "$SPEC" ]; }; then
  die "--adopt requires an approved --doc without a legacy JSON spec"
fi

APPROVED_REV=""
BRIEF_TMP=""
if [ -z "$SPEC" ] && [ -n "$DOC" ]; then
  command -v jq >/dev/null || die "jq not found"
  # shellcheck source=scripts/lib/brief.sh
  source "$SCRIPT_DIR/lib/brief.sh"
  repo_root=$(git rev-parse --show-toplevel) || die "--doc requires a Git checkout"
  doc_dir=$(cd "$(dirname "$DOC")" && pwd -P) || die "--doc directory not found"
  case "$doc_dir/$(basename "$DOC")" in
    "$repo_root"/*) DOC="${doc_dir#"$repo_root"}/$(basename "$DOC")"; DOC=${DOC#/} ;;
    *) die "--doc must be inside the repository" ;;
  esac
  cd "$repo_root"
  [ -f "$DOC" ] || die "--doc file not found: $DOC"
  approval=$(brief_approval "$DOC") || die "document is not approved with a revision"
  APPROVED_REV=${approval%%"$(printf '\t')"*}
  APPROVED_BY=${approval#*"$(printf '\t')"}
  if [ "$MODE" = apply ]; then
    git ls-files --error-unmatch -- "$DOC" >/dev/null 2>&1 || die "--doc is uncommitted"
    [ -z "$(git status --porcelain -- "$DOC")" ] || die "--doc is dirty or uncommitted"
  fi
  brief_approved_at_head "$DOC" "$APPROVED_REV" || exit 1
  BRIEF_TMP=$(mktemp -d "${TMPDIR:-/tmp}/brief-spec.XXXXXX")
  trap 'rm -rf "$BRIEF_TMP"' EXIT
  git show "$APPROVED_REV:$DOC" > "$BRIEF_TMP/approved.md" || die "doc missing at approved revision"
  SPEC="$BRIEF_TMP/spec.json"
  brief_parse "$BRIEF_TMP/approved.md" "$DOC" "$APPROVED_REV" issue-layout > "$BRIEF_TMP/layout-spec.json" \
    || die "invalid approved brief"
  jq '.issue_layout' "$BRIEF_TMP/layout-spec.json" > "$BRIEF_TMP/layout.json"
  jq 'del(.issue_layout)' "$BRIEF_TMP/layout-spec.json" > "$SPEC"
fi

[ -n "$SPEC" ] || die "no spec file given. Usage: $0 [--apply|--diff] [--doc <path>] <spec.json>"
[ -f "$SPEC" ] || die "spec file not found: $SPEC"
if [ -n "$APPROVED_BY" ]; then
  [[ "$APPROVED_BY" =~ ^[A-Za-z0-9]([A-Za-z0-9._\ -]*[A-Za-z0-9])?$ ]] \
    || die "--approved-by must start and end with a letter or digit and contain only letters, digits, spaces, dots, underscores, or hyphens"
fi
command -v jq >/dev/null || die "jq not found"
command -v git >/dev/null || die "git not found"
jq -e . "$SPEC" >/dev/null 2>&1 || die "spec is not valid JSON: $SPEC"
jq -e '
  (.id == null or (.id | type == "string" and length <= 80 and test("^[a-z0-9][a-z0-9._-]*$"))) and
  ((.profile == null) or (.profile == "standard") or (.profile == "strict")) and
  (if .profile == "standard" then (.steps | length == 1) and
     (.tracking == null or .tracking == {})
   else (.tracking.title | type == "string" and length > 0) end) and
  ((.labels // []) | type == "array" and all(.[]; type == "string" and length > 0)) and
  (.steps | type == "array" and length > 0 and length <= 100) and
  all(.steps[];
    (.id == null or (.id | type == "string" and length <= 80 and test("^[a-z0-9][a-z0-9._-]*$"))) and
    (.title | type == "string" and length > 0) and
    ((.labels // []) | type == "array" and all(.[]; type == "string" and length > 0))
  ) and
  (if .profile == null then true else
    all(.steps[]; (.packet | type == "object") and
      ([.packet.brief, .packet.definition_of_done, .packet.verification, .packet.risks]
       | all(.[]; type == "string" and length > 0 and length <= 4096)) and
      ((.packet | keys) == ["brief", "definition_of_done", "risks", "verification"])) end) and
  ([.steps | to_entries[] | (.value.id // ("step-" + ((.key + 1) | tostring)))] as $ids
   | ($ids | unique | length) == ($ids | length))
' "$SPEC" >/dev/null 2>&1 \
  || die "spec must contain valid profile, topology, packet, and uniquely identified steps"

PROFILE=$(jq -r '.profile // "legacy"' "$SPEC")
BASELINE=$("$SCRIPT_DIR/assurance.sh" status | awk '{print $1}') \
  || die "project assurance baseline is invalid"
case "$PROFILE:$BASELINE" in
  standard:strict) die "standard profile would downgrade the strict project baseline" ;;
esac
if [ "$PROFILE" != legacy ]; then
  i=0
  while [ "$i" -lt "$(jq '.steps | length' "$SPEC")" ]; do
    packet=$(jq -r --arg profile "$PROFILE" --argjson i "$i" '
      .steps[$i].packet |
      "Profile: \($profile)\nBrief: \(.brief)\nDefinition of Done: \(.definition_of_done)\nVerification: \(.verification)\nRisks and edge cases: \(.risks)"
    ' "$SPEC")
    words=$(printf '## Executor packet\n%s\n' "$packet" | wc -w | tr -d ' ')
    [ "$words" -le 800 ] || die "executor packet for step $((i + 1)) exceeds 800 words ($words)"
    i=$((i + 1))
  done
fi


# Validate the local writer target before authentication or any issue mutation.
# A schema-less document needs deliberate migration; applying a plan cannot do it.
if [ "$MODE" = apply ] && [ -n "$DOC" ]; then
  [ -f "$DOC" ] || die "--doc file not found: $DOC"
  [ -w "$DOC" ] || die "--doc file is not writable: $DOC"
  "$SCRIPT_DIR/lifecycle-status.sh" --doc "$DOC" --validate-doc-status >/dev/null \
    || die "--doc Status is not valid v2; migrate using the v2 Feature/Security template"
fi

hash_stdin() {
  git hash-object --stdin 2>/dev/null || cksum | awk '{print $1}'
}

TRACK_TITLE=$(jq -r 'if .profile == "standard" then .steps[0].title else .tracking.title end' "$SPEC")
TRACK_BODY=$(jq -r '.tracking.body // ""' "$SPEC")
TRACK_LABELS=$(jq -r '(.labels // []) | join(",")' "$SPEC")
STEP_COUNT=$(jq '.steps | length' "$SPEC")
PLAN_KEY=$(jq -r '.id // empty' "$SPEC")
[ -n "$PLAN_KEY" ] || PLAN_KEY=$(printf '%s' "$TRACK_TITLE" | hash_stdin)
SPEC_HASH=$(jq -cS . "$SPEC" | hash_stdin)
PLAN_MARKER="agentic-flow:plan:$PLAN_KEY"
ADOPTED_MARKER='<!-- agentic-flow:adopted -->'

if [ "${#ADOPT[@]}" -gt 0 ]; then
  adoption_map="$BRIEF_TMP/adoptions"
  : > "$adoption_map"
  step_ids=$(jq -r '.steps[].id' "$SPEC")
  for mapping in "${ADOPT[@]}"; do
    [[ "$mapping" =~ ^([a-z0-9][a-z0-9._-]{0,79})=([1-9][0-9]{0,9})$ ]] \
      || die "expected --adopt <step-id>=<issue-number>: $mapping"
    key=${BASH_REMATCH[1]} number=${BASH_REMATCH[2]}
    identity="step:$key"
    if [ "$key" = tracker ]; then
      [ "$PROFILE" = strict ] || die "--adopt tracker requires a Strict plan"
      identity=tracker
    else
      printf '%s\n' "$step_ids" | grep -Fxq "$key" || die "unknown step in --adopt: $key"
    fi
    conflict=$(awk -F '\t' -v key="$identity" -v number="$number" '
      $1 == key { print "duplicate adoption for " (key == "tracker" ? key : substr(key, 6)); exit }
      $2 == number { print "duplicate adoption issue #" number; exit }
    ' "$adoption_map")
    [ -z "$conflict" ] || die "$conflict"
    printf '%s\t%s\n' "$identity" "$number" >> "$adoption_map"
  done
fi

echo "Mode:            $MODE"
echo "Profile:         $PROFILE"
echo "Plan identity:   $PLAN_KEY"
echo "Spec revision:   $SPEC_HASH"
echo "Tracking issue:  $TRACK_TITLE   [labels: $TRACK_LABELS]"
echo "Steps ($STEP_COUNT):"
i=0
while [ "$i" -lt "$STEP_COUNT" ]; do
  title=$(jq -r ".steps[$i].title" "$SPEC")
  step_id=$(jq -r ".steps[$i].id // \"step-$((i + 1))\"" "$SPEC")
  labels=$(jq -r ".steps[$i].labels // [] | join(\",\")" "$SPEC")
  echo "  $((i + 1)). [$step_id] $title   [labels: $labels]"
  i=$((i + 1))
done
if [ -n "${adoption_map:-}" ]; then
  while IFS=$'\t' read -r identity number; do
    echo "Adopt ${identity#step:}: #$number"
  done < "$adoption_map"
fi

if [ "$MODE" = dry ]; then
  echo
  echo "OFFLINE DRY RUN — nothing queried or created."
  echo "Use --diff to compare with GitHub or --apply to reconcile."
  exit 0
fi

command -v gh >/dev/null || die "gh not found"
# shellcheck source=scripts/lib/review-policy.sh
source "$SCRIPT_DIR/lib/review-policy.sh"
# shellcheck source=scripts/lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"
gh auth status >/dev/null 2>&1 || die "gh not authenticated (run: gh auth login)"
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || die "not in a GitHub repo"
HAS_ISSUES=$(gh repo view --json hasIssuesEnabled --jq .hasIssuesEnabled)
[ "$HAS_ISSUES" = true ] || die "Issues are not enabled on $REPO"
echo "Repo:            $REPO"
[ -z "$APPROVED_REV" ] || echo "Approved stamp:  approved=$APPROVED_REV (journal and live labels preserved)"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/plan-to-issues.XXXXXX")
trap 'rm -rf "$TMP"; [ -z "$BRIEF_TMP" ] || rm -rf "$BRIEF_TMP"' EXIT

BRIEF_LINK=""
BRIEF_STAMP=""
if [ -n "$BRIEF_TMP" ]; then
  doc_url_path=$(jq -nr --arg doc "$DOC" '$doc | split("/") | map(@uri) | join("/")')
  BRIEF_LINK="[Approved brief](https://github.com/$REPO/blob/$APPROVED_REV/$doc_url_path)"
  if [[ "$DOC" =~ ^docs/[A-Za-z0-9_./-]+\.md$ ]]; then
    BRIEF_STAMP="<!-- agentic-flow:brief:$DOC -->"
  fi
fi

# Preserve code spans and fenced code while protecting literal placeholder and
# separator lines in prose. Keep the same rendering rules for both topologies.
# shellcheck disable=SC2016
ISSUE_MARKDOWN_JQ='
  def issue_markdown:
    gsub(
      "(?<code>(?<![^\n]) {0,3}(?<fence>`{3,}|~{3,})[^\n]*\n[\\s\\S]*?(?<![^\n]) {0,3}\\k<fence>[`~]*[ \t]*(?=\n|$)|`+[^`\n]+`+)" +
      "|(?<![^\n])(?<indent> {0,3})(?<separator>-+|=+)[ \t]*(?=\n|$)" +
      "|<(?<tag>/?[A-Za-z][A-Za-z0-9_-]*)>|<!--";
      if .code then .code elif .separator then .indent + "\\" + .separator
      elif .tag then "&lt;" + .tag + "&gt;" else "&lt;!--" end);
  def short_title($id):
    if ascii_downcase | startswith($id + " — ") then split(" — ") | .[1:] | join(" — ") else . end;
'

render_step_body() { # <step index> <step id> <tracker URL or empty> <stamp>
  local layout=/dev/null
  [ -z "$BRIEF_TMP" ] || layout="$BRIEF_TMP/layout.json"
  jq -r --argjson i "$1" --arg id "$2" --arg tracker "$3" --arg stamp "$4" \
    --arg brief_link "$BRIEF_LINK" --arg brief_stamp "$BRIEF_STAMP" --slurpfile layout "$layout" \
    "$ISSUE_MARKDOWN_JQ"'
    .steps[$i] as $step | $step.packet as $packet | $layout[0].steps[$id] as $step_layout |
    [
      ("## " + ([$id, ($step.title | short_title($id))] | join(" — ") | issue_markdown)),
      ([if $tracker != "" then "[Tracker #" + ($tracker | split("/") | last) + "](" + $tracker + ")" else empty end,
        ("**Profile:** " + (if .profile == "strict" then "Strict" else "Standard" end)),
        ($brief_link | select(length > 0))]
        | join(" · ")),
      (if $brief_link == "" then "Brief: " + ($packet.brief | issue_markdown) else empty end),
      (($step.body // "") | select(length > 0) | issue_markdown),
      "### Definition of done", (($step_layout.definition_of_done // $packet.definition_of_done) | issue_markdown),
      "### Verify", (($step_layout.verify // $packet.verification) | issue_markdown),
      ($layout[0].verification_commands // "" | select(length > 0) |
        "### Verification commands", issue_markdown),
      "### Risks",
      (if $step_layout.bullet_risks then $packet.risks | issue_markdown
       else "- " + ($packet.risks | issue_markdown | gsub("\n"; "\n  ")) end),
      ([$brief_stamp, $stamp] | map(select(length > 0)) | join("\n"))
    ] | join("\n\n")
  ' "$SPEC"
}

render_tracker_intro() {
  jq -r --arg brief_link "$BRIEF_LINK" "$ISSUE_MARKDOWN_JQ"'
    [("## " + (.tracking.title | issue_markdown)),
     (["**Profile:** Strict",
       (select(.branch // "" | length > 0) | "`" + .branch + "` → `" + (.base // "main") + "`"),
       ($brief_link | select(length > 0))] | join(" · ")),
     (.tracking.body // "" | select(length > 0) | issue_markdown)] | join("\n\n")
  ' "$SPEC"
}

# One bounded query discovers the tracker and every step belonging to this logical plan.
ISSUES_JSON=$(gh issue list --repo "$REPO" --state all --limit 100 \
  --search "\"$PLAN_MARKER\" in:body" --json number,title,body,state,url) \
  || die "failed to query existing plan issues"
printf '%s\n' "$ISSUES_JSON" | jq -e 'type == "array"' >/dev/null \
  || die "GitHub returned malformed issue data"
issue_count=$(printf '%s\n' "$ISSUES_JSON" | jq 'length')
[ "$issue_count" -lt 100 ] || die "issue discovery reached 100 results; narrow or repair the stamped plan set before applying"
printf '%s\n' "$ISSUES_JSON" | jq -e --arg repo "$REPO" '
  all(.[]; (.number | type == "number" and . > 0 and . == floor) and
    (.body | type == "string") and (.state == "OPEN" or .state == "CLOSED") and
    (.url == ("https://github.com/" + $repo + "/issues/" + (.number | tostring))))' >/dev/null \
  || die "GitHub returned incomplete issue identity data"

if [ -n "${adoption_map:-}" ]; then
  : > "$TMP/adoption-candidates"
  while IFS=$'\t' read -r identity number; do
    issue=$(review_bounded gh issue view "$number" --repo "$REPO" --json number,body,state,url) \
      || die "could not read issue #$number from $REPO"
    issue=$(printf '%s\n' "$issue" | jq -ces --argjson number "$number" '
      if length != 1 then null else .[0] end |
      if .number != $number or (.url | type) != "string" or (.body | type) != "string" or
         (.state != "OPEN" and .state != "CLOSED") then empty
      else {number, url, state, body,
        adopting: (.body | split("<!--")[1:] | all(.[]; split("-->")[0] | contains("agentic-flow:") | not))}
      end
    ') || die "malformed response for issue #$number"
    [ "$(printf '%s\n' "$issue" | jq -r .url)" = "https://github.com/$REPO/issues/$number" ] \
      || die "issue #$number is not in $REPO or is a pull request"
    [ "$(printf '%s\n' "$issue" | jq -r .state)" = OPEN ] || die "issue #$number is closed"
    printf '%s\n' "$issue" >> "$TMP/adoption-candidates"
  done < "$adoption_map"
  # Use the direct read for mapped issues, including issues already stamped on a previous run.
  ISSUES_JSON=$(printf '%s\n' "$ISSUES_JSON" | jq -c --slurpfile candidates "$TMP/adoption-candidates" '
    ($candidates | map(.number)) as $numbers |
    (map(.number)) as $discovered |
    map(select(.number as $n | $numbers | index($n) | not)) +
    ($candidates | map(.number as $n | .discovered = ($discovered | index($n) != null)))')
fi

# Only the managed suffix supplies identity, topology and approval metadata.
# Keep the exact bytes through the marker as an opaque prefix for subsequent edits.
if [[ "$ISSUES_JSON" == *"$ADOPTED_MARKER"* ]] || [ -n "${adoption_map:-}" ]; then
  ISSUES_JSON=$(printf '%s\n' "$ISSUES_JSON" | jq -c --arg marker "$ADOPTED_MARKER" '
    map(if .adopting then
      .adopted_prefix = (.body + (if .body == "" then "" else "\n\n" end) + $marker + "\n") | .body = ""
    else
      (.body | match("(?:\\A|\n)" + $marker + "\n") // null) as $boundary |
      if $boundary == null then . else
        ($boundary.offset + $boundary.length) as $end |
        .adopted_prefix = .body[:$end] | .body = .body[$end:]
      end
    end)')
fi

# Read whole stamp lines into a validated exact index before any GitHub mutation.
# A malformed matching stamp or two issues with one identity is an ambiguity,
# not permission to choose the first search result.
INDEX="$TMP/issue-index"
: > "$INDEX"
TRACK_STAMP_RE='^<!-- agentic-flow:plan:([a-z0-9][a-z0-9._-]*) tracker spec:([a-f0-9]{40}|[a-f0-9]{64}|[0-9]{1,10})( journal=[a-z0-9][a-z0-9._-]*)?( approved=[a-f0-9]{40})?( approved-by:.+ approved-at:[^ ]+)? -->$'
STEP_STAMP_RE='^<!-- agentic-flow:plan:([a-z0-9][a-z0-9._-]*) step:([a-z0-9][a-z0-9._-]*) spec:([a-f0-9]{40}|[a-f0-9]{64}|[0-9]{1,10})( journal=[a-z0-9][a-z0-9._-]*)?( approved=[a-f0-9]{40})?( approved-by:.+ approved-at:[^ ]+)? -->$'
number_for_identity() {
  awk -F '\t' -v key="$1" '$1 == key {print $2; exit}' "$INDEX"
}

index_identity() { # identity, number
  local previous_number previous_identity
  previous_number=$(number_for_identity "$1")
  [ -z "$previous_number" ] || die "duplicate $1 stamps on issues #$previous_number and #$2"
  previous_identity=$(awk -F '\t' -v number="$2" '$2 == number {print $1; exit}' "$INDEX")
  [ -z "$previous_identity" ] || die "issue #$2 has multiple identity stamps: $previous_identity and $1"
  printf '%s\t%s\n' "$1" "$2" >> "$INDEX"
}

printf '%s\n' "$ISSUES_JSON" | journal_stamp_lines index "$PLAN_KEY" > "$TMP/stamp-lines" \
  || die "could not parse issue stamps"
while IFS="$(printf '\t')" read -r remote_number stamp; do
  [ -n "$remote_number" ] || continue
  if [[ "$stamp" =~ $TRACK_STAMP_RE ]]; then
    [ "${BASH_REMATCH[1]}" = "$PLAN_KEY" ] || die "issue #$remote_number has a mismatched plan stamp"
    identity=tracker
  elif [[ "$stamp" =~ $STEP_STAMP_RE ]]; then
    [ "${BASH_REMATCH[1]}" = "$PLAN_KEY" ] || die "issue #$remote_number has a mismatched plan stamp"
    identity="step:${BASH_REMATCH[2]}"
  else
    die "malformed identity stamp on issue #$remote_number"
  fi
  index_identity "$identity" "$remote_number"
done < "$TMP/stamp-lines"

issue_for_number() {
  printf '%s\n' "$ISSUES_JSON" | jq -c --argjson number "$1" '.[] | select(.number == $number)'
}

issue_for_identity() { # <tracker | step:id>
  local number
  number=$(number_for_identity "$1")
  [ -n "$number" ] || return 0
  issue_for_number "$number"
}

if [ -n "${adoption_map:-}" ]; then
  while IFS=$'\t' read -r identity number; do
    previous_number=$(number_for_identity "$identity")
    [ -z "$previous_number" ] || [ "$previous_number" = "$number" ] \
      || die "${identity#step:} is already stamped on issue #$previous_number"
    issue=$(issue_for_number "$number")
    if printf '%s\n' "$issue" | jq -e .adopting >/dev/null; then
      index_identity "$identity" "$number"
    elif [ "$previous_number" != "$number" ] ||
      ! printf '%s\n' "$issue" | jq -e '.discovered and has("adopted_prefix")' >/dev/null; then
      die "issue #$number already contains an agentic-flow comment"
    fi
  done < "$adoption_map"
fi

# First document-mode reapply migrates legacy bodies in place. Preserve the old
# spec hash and handwritten packets: bootstrap must change only approved=.
migrate_approval_body() { # existing managed body, proposed body
  local old=$1 stamp stamped_rev line
  if [ -n "$APPROVED_REV" ] && [ -n "$1" ]; then
    stamp=$(printf '%s\n' "$old" | journal_stamp_lines body) || return 1
    stamped_rev=$(printf '%s\n' "$stamp" | jq -r '.approved // empty')
    if [ -z "$stamped_rev" ] || [ "$stamped_rev" = "$APPROVED_REV" ]; then
      line=$(printf '%s\n' "$stamp" | jq -r .line)
      printf '%s\n' "$old" | STAMP_LINE="$line" awk -v rev="$APPROVED_REV" '
        $0 == ENVIRON["STAMP_LINE"] {
          if (index($0," approved=")>0) sub(/ approved=[a-f0-9]+/," approved=" rev)
          else if (index($0," approved-by:")>0) sub(/ approved-by:/," approved=" rev " approved-by:")
          else sub(/ -->$/," approved=" rev " -->")
        }
        {print}'
      return
    fi
  fi
  printf '%s\n' "$2"
}

issue_body() {
  printf '%s\n' "$1" | jq -r .body
}

issue_stamp_fields() { # parsed existing stamp, or empty for a new issue
  journal_value=journal=v1
  approved_value=${APPROVED_REV:+approved=$APPROVED_REV}
  policy_line=''
  [ -n "$1" ] || return 0
  approved_value=${approved_value:-$(printf '%s\n' "$1" | jq -r '.approved | values | "approved="+.')}
  journal_value=$(printf '%s\n' "$1" | jq -r '.journal | values | "journal="+.')
  policy_line=$(printf '%s\n' "$1" | jq -r '.policy_line // empty')
}

has_adopted_prefix() {
  printf '%s\n' "$1" | jq -e .adopted_prefix >/dev/null
}

prepare_adopted_body() { # issue JSON, managed body
  local number
  printf '%s\n' "$1" | jq -rj .adopted_prefix > "$TMP/adopted-body"
  printf '%s' "$2" >> "$TMP/adopted-body"
  if ! jq -eRs 'length <= 65536' "$TMP/adopted-body" >/dev/null; then
    number=$(printf '%s\n' "$1" | jq -r .number)
    die "adopted issue #$number body would exceed 65,536 characters"
  fi
}

edit_plan_issue() { # existing issue JSON, number, title, managed body, creation labels
  if has_adopted_prefix "$1"; then
    prepare_adopted_body "$1" "$4"
    # Add labels before stamping, so an interrupted adoption can safely retry.
    # Once the stamp is present the live workflow labels take precedence.
    if [ -n "$5" ] && printf '%s\n' "$1" | jq -e .adopting >/dev/null; then
      review_bounded gh issue edit "$2" --repo "$REPO" --add-label "$5" >/dev/null
    fi
    review_bounded gh issue edit "$2" --repo "$REPO" --body-file "$TMP/adopted-body" >/dev/null
  else
    gh issue edit "$2" --repo "$REPO" --title "$3" --body "$4" >/dev/null
  fi
}

# Topology is immutable for a plan identity. Check every discovered issue before
# label creation, edits, or closes; a partial conversion would be unrecoverable.
existing_topology=""
while IFS="$(printf '\t')" read -r identity number; do
  [ -n "$identity" ] || continue
  body=$(issue_body "$(issue_for_number "$number")")
  if [ -z "$body" ]; then  # A validated, unstamped adoption takes the approved profile.
    found_topology=$PROFILE
  elif printf '%s\n' "$body" | grep -Fxq '<!-- agentic-flow:topology:standard -->'; then
    found_topology=standard
  elif printf '%s\n' "$body" | grep -Fxq '<!-- agentic-flow:topology:strict -->'; then
    found_topology=strict
  else
    found_topology=legacy
  fi
  [ -z "$existing_topology" ] || [ "$existing_topology" = "$found_topology" ] \
    || die "mixed issue topology for plan $PLAN_KEY; migration required"
  existing_topology=$found_topology
done < "$INDEX"
[ -z "$existing_topology" ] || [ "$existing_topology" = "$PROFILE" ] \
  || die "changing plan $PLAN_KEY topology from $existing_topology to $PROFILE requires migration"

if [ "$PROFILE" = standard ]; then
  [ ! -s "$INDEX" ] || [ "$(wc -l < "$INDEX" | tr -d ' ')" -eq 1 ] \
    || die "standard plan has more than one existing issue; migration required"
  [ -z "$(issue_for_identity tracker)" ] \
    || die "standard plan cannot reuse a parent tracker; migration required"
  step_id=$(jq -r '.steps[0].id // "step-1"' "$SPEC")
  existing=$(issue_for_identity "step:$step_id")
  [ ! -s "$INDEX" ] || [ -n "$existing" ] \
    || die "changing a standard work issue identity requires migration"
  existing_body=$(issue_body "$existing")
  existing_stamp=''
  approval_by="" approval_at=""
  if [ -n "$existing_body" ]; then
    existing_stamp=$(printf '%s\n' "$existing_body" | journal_stamp_lines body)
    approval_by=$(printf '%s\n' "$existing_stamp" | jq -r .line | sed -n 's/.* approved-by:\(.*\) approved-at:[^ ]* -->.*/\1/p')
    approval_at=$(printf '%s\n' "$existing_stamp" | jq -r .line | sed -n 's/.* approved-at:\([^ ]*\) -->.*/\1/p')
    if [ -n "$approval_by" ]; then
      [[ "$approval_by" =~ ^[A-Za-z0-9]([A-Za-z0-9._\ -]*[A-Za-z0-9])?$ ]] \
        && [[ "$approval_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
        || die "existing Standard approval metadata is invalid"
    fi
    [ -z "$APPROVED_BY" ] || [ -z "$approval_by" ] || [ "$APPROVED_BY" = "$approval_by" ] \
      || die "plan already approved by '$approval_by'"
  fi
  if [ -n "$APPROVED_BY" ] && [ -z "$approval_by" ]; then
    approval_by=$APPROVED_BY
    approval_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
  if [ "$MODE" = apply ] && [ -z "$approval_by" ]; then
    die "standard work issue requires --approved-by to record plan approval"
  fi
  issue_stamp_fields "$existing_stamp"
  stamp="<!-- $PLAN_MARKER step:$step_id spec:$SPEC_HASH${journal_value:+ $journal_value}${approved_value:+ $approved_value}"
  [ -z "$approval_by" ] || stamp="$stamp approved-by:$approval_by approved-at:$approval_at"
  stamp="$stamp -->${policy_line:+$'\n'$policy_line}"
  desired_body=$(render_step_body 0 "$step_id" "" "$stamp
<!-- agentic-flow:topology:standard -->")
  desired_body=$(migrate_approval_body "$existing_body" "$desired_body")
  if has_adopted_prefix "$existing"; then
    prepare_adopted_body "$existing" "$desired_body"
  fi
  if [ "$MODE" = diff ]; then
    if [ -n "$existing_body" ]; then
      echo 'Work issue: exists'
    elif [ -n "$existing" ]; then
      echo 'Work issue: would adopt'
    else
      echo 'Work issue: missing (would create)'
    fi
    exit 0
  fi
  labels=$(jq -r '(.steps[0].labels // []) | join(",")' "$SPEC")
  jq -r '[(.steps[0].labels // [])[]] | unique[]' "$SPEC" | while IFS= read -r label; do
    [ -n "$label" ] || continue
    gh label create "$label" --repo "$REPO" --color CCCCCC >/dev/null 2>&1 || true
  done
  workflow_label_hit=$(gh label list --repo "$REPO" --json name \
    --jq '[.[] | select(.name == "agent:claude" or .name == "agent:codex" or .name == "agent:opencode" or .name == "needs-review" or .name == "needs-execution" or .name == "needs-closing")] | length' \
    2>/dev/null || echo 0)
  if [ "$workflow_label_hit" -eq 0 ]; then
    "$SCRIPT_DIR/create-tags.sh" --repo "$REPO"
  fi
  if [ -z "$existing" ]; then
    if [ -n "$labels" ]; then
      url=$(gh issue create --repo "$REPO" --title "$TRACK_TITLE" --body "$desired_body" --label "$labels")
    else
      url=$(gh issue create --repo "$REPO" --title "$TRACK_TITLE" --body "$desired_body")
    fi
    echo "created work issue $url"
  else
    number=$(printf '%s\n' "$existing" | jq -r .number)
    url=$(printf '%s\n' "$existing" | jq -r .url)
    edit_plan_issue "$existing" "$number" "$TRACK_TITLE" "$desired_body" "$labels"
    echo "updated work issue $url"
  fi
  if [ -n "$DOC" ]; then
    doc_tmp="$DOC.tmp.$$"
    approval_line=""
    [ -z "$approval_by" ] || approval_line="- **Approval:** status=approved; by=$approval_by; at=${approval_at%%T*}${APPROVED_REV:+; rev=$APPROVED_REV}"
    [ -z "$APPROVED_REV" ] || approval_line=""
    awk -v url="$url" -v approval_line="$approval_line" '
      /^- \*\*Tracking issue:\*\*/ {print "- **Tracking issue:** url=" url; found=1; next}
      approval_line != "" && /^- \*\*Approval:\*\*/ {print approval_line; approved=1; next}
      {print}
      END {if (!found || (approval_line != "" && !approved)) exit 1}
    ' "$DOC" > "$doc_tmp" || { rm -f "$doc_tmp"; die "--doc lacks Tracking issue or Approval Status field"; }
    mv "$doc_tmp" "$DOC"
  fi
  echo "Done. Tracking issue: $url"
  exit 0
fi

TRACK_ID_MARKER="$PLAN_MARKER tracker"
existing_tracker=$(issue_for_identity tracker)
existing_tracker_body=$(issue_body "$existing_tracker")
existing_tracker_stamp=''
APPROVAL_BY=""
APPROVAL_AT=""
if [ -n "$existing_tracker_body" ]; then
  existing_tracker_stamp=$(printf '%s\n' "$existing_tracker_body" | journal_stamp_lines body)
  APPROVAL_BY=$(printf '%s\n' "$existing_tracker_stamp" | jq -r .line \
    | sed -n 's/.* approved-by:\(.*\) approved-at:[^ ]* -->.*/\1/p')
  APPROVAL_AT=$(printf '%s\n' "$existing_tracker_stamp" | jq -r .line \
    | sed -n 's/.* approved-at:\([^ ]*\) -->.*/\1/p')
  if [ -n "$APPROVAL_BY" ]; then
    [[ "$APPROVAL_BY" =~ ^[A-Za-z0-9]([A-Za-z0-9._\ -]*[A-Za-z0-9])?$ ]] \
      || die "existing approval identity is not v2-safe"
    [[ "$APPROVAL_AT" =~ ^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$ ]] \
      || die "existing approval timestamp is invalid"
  fi
fi
if [ -n "$APPROVED_BY" ]; then
  if [ -n "$APPROVAL_BY" ] && [ "$APPROVAL_BY" != "$APPROVED_BY" ]; then
    die "plan already approved by '$APPROVAL_BY'; refusing to replace it with '$APPROVED_BY'"
  fi
  if [ -z "$APPROVAL_BY" ]; then
    APPROVAL_BY="$APPROVED_BY"
    APPROVAL_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
fi
issue_stamp_fields "$existing_tracker_stamp"
TRACK_STAMP="<!-- $TRACK_ID_MARKER spec:$SPEC_HASH${journal_value:+ $journal_value}${approved_value:+ $approved_value}"
if [ -n "$APPROVAL_BY" ]; then
  TRACK_STAMP="$TRACK_STAMP approved-by:$APPROVAL_BY approved-at:$APPROVAL_AT"
fi
TRACK_STAMP="$TRACK_STAMP -->${policy_line:+$'\n'$policy_line}"
if [ "$PROFILE" = strict ]; then
  TRACK_STAMP="$TRACK_STAMP
<!-- agentic-flow:topology:strict -->"
  TRACK_BODY=$(render_tracker_intro)
fi
TRACK_DESIRED="${TRACK_BODY}

${TRACK_STAMP}"
TRACK_STUB=$TRACK_DESIRED

TRACK_DESIRED=$(migrate_approval_body "$existing_tracker_body" "$TRACK_DESIRED")

desired_step_body() { # index, step id, tracker URL, existing managed body
  local stamp body existing_stamp='' journal_value approved_value policy_line
  if [ -n "$4" ]; then
    existing_stamp=$(printf '%s\n' "$4" | journal_stamp_lines body) || return 1
  fi
  issue_stamp_fields "$existing_stamp" || return 1
  stamp="<!-- $PLAN_MARKER step:$2 spec:$SPEC_HASH${journal_value:+ $journal_value}${approved_value:+ $approved_value} -->${policy_line:+$'\n'$policy_line}"
  if [ "$PROFILE" = strict ]; then
    stamp="$stamp
<!-- agentic-flow:topology:strict -->"
    body=$(render_step_body "$1" "$2" "$3" "$stamp") || return 1
  else
    body=$(jq -r ".steps[$1].body // \"\"" "$SPEC") || return 1
    body="${body}

${stamp}"
  fi
  migrate_approval_body "$4" "$body"
}

strict_task_title() {
  jq -nr --arg title "$1" --arg id "$2" "$ISSUE_MARKDOWN_JQ"'
    $title | short_title($id) | gsub("[\r\n\t]+"; " ") | issue_markdown'
}

tracker_checklist_body() {
  local tasklist
  if [ "$PROFILE" = strict ]; then
    tasklist=$'\n\n### Steps\n\n'
  else
    tasklist=$'\n\n## Steps\n'
  fi
  while IFS=$'\t' read -r num step_id title; do
    tasklist="${tasklist}- [ ] #${num} [${step_id}] ${title}"$'\n'
  done < "$1"
  local final="${TRACK_BODY}${tasklist}"$'\n'"${TRACK_STAMP}"
  # Finish a tracker stub after a partial apply, and preserve a completed
  # tracker during approval-only migration.
  if [ "$TRACK_DESIRED" != "$TRACK_STUB" ] || [ -z "$APPROVED_REV" ]; then
    migrate_approval_body "$existing_tracker_body" "$final"
  else
    printf '%s\n' "$final"
  fi
}

tracker_adopted=false
if has_adopted_prefix "$existing_tracker"; then
  tracker_adopted=true
fi

# Check all adopted body sizes before label creation or any issue edit. Reserve
# space for issue numbers that GitHub will assign during this apply.
if [[ "$ISSUES_JSON" == *'"adopted_prefix":'* ]]; then
  unassigned_number=9999999999
  preflight_track_url=$(printf '%s\n' "$existing_tracker" | jq -r .url)
  preflight_track_url=${preflight_track_url:-https://github.com/$REPO/issues/$unassigned_number}
  : > "$TMP/adoption-step-rows"
  i=0
  while [ "$i" -lt "$STEP_COUNT" ]; do
    step_id=$(jq -r ".steps[$i].id" "$SPEC")
    existing=$(issue_for_identity "step:$step_id")
    if has_adopted_prefix "$existing"; then
      desired_body=$(desired_step_body "$i" "$step_id" "$preflight_track_url" "$(issue_body "$existing")")
      prepare_adopted_body "$existing" "$desired_body"
    fi
    if [ "$tracker_adopted" = true ]; then
      num=$(printf '%s\n' "$existing" | jq -r .number)
      title=$(jq -r ".steps[$i].title" "$SPEC")
      task_title=$(strict_task_title "$title" "$step_id")
      printf '%s\t%s\t%s\n' "${num:-$unassigned_number}" "$step_id" "$task_title" >> "$TMP/adoption-step-rows"
    fi
    i=$((i + 1))
  done
  if [ "$tracker_adopted" = true ]; then
    desired_body=$(tracker_checklist_body "$TMP/adoption-step-rows")
    prepare_adopted_body "$existing_tracker" "$desired_body"
  fi
fi

if [ "$MODE" = diff ]; then
  if [ -z "$existing_tracker" ]; then
    echo
    echo "Tracker: missing (would create)"
  elif [ -z "$existing_tracker_body" ]; then
    echo
    echo "Tracker: would adopt"
  else
    existing_spec=$(printf '%s\n' "$existing_tracker_stamp" | jq -r .spec)
    existing_approved=$(printf '%s\n' "$existing_tracker_stamp" | jq -r '.approved // empty')
    if [ -n "$APPROVED_REV" ] && [ -z "$existing_approved" ]; then
      echo
      echo "Tracker: add approved=$APPROVED_REV only (journal, labels and body preserved)"
    elif [ -n "$APPROVED_REV" ] && [ "$existing_approved" = "$APPROVED_REV" ]; then
      echo
      echo "Tracker: current"
    elif [ "$existing_spec" = "$SPEC_HASH" ]; then
      echo
      echo "Tracker: current"
    else
      echo
      echo "Tracker: revision differs (would reconcile)"
    fi
  fi
  i=0
  while [ "$i" -lt "$STEP_COUNT" ]; do
    step_id=$(jq -r ".steps[$i].id // \"step-$((i + 1))\"" "$SPEC")
    existing=$(issue_for_identity "step:$step_id")
    if [ -z "$existing" ]; then
      echo "Step $step_id: missing (would create)"
    elif [ -z "$(issue_body "$existing")" ]; then
      echo "Step $step_id: would adopt"
    else
      if [ -n "$APPROVED_REV" ]; then
        existing_approved=$(issue_body "$existing" | journal_stamp_lines body | jq -r '.approved // empty')
        if [ -z "$existing_approved" ]; then
          echo "Step $step_id: add approved=$APPROVED_REV only (journal, labels and body preserved)"
        elif [ "$existing_approved" = "$APPROVED_REV" ]; then
          echo "Step $step_id: current"
        else
          echo "Step $step_id: approved revision differs (would reconcile)"
        fi
      else
        echo "Step $step_id: exists"
      fi
    fi
    i=$((i + 1))
  done
  exit 0
fi

# Labels are idempotent support data. A create failure may mean the label already exists;
# issue mutations below still fail loudly if a required label is actually unavailable.
jq -r '[(.labels // [])[], (.steps[].labels // [])[]] | unique[]' "$SPEC" \
  | while IFS= read -r label; do
      [ -n "$label" ] || continue
      gh label create "$label" --repo "$REPO" --color CCCCCC >/dev/null 2>&1 || true
    done

# The six workflow labels (agent:*/needs-*) get their standard colors from the create-tags
# skill (scripts/create-tags.sh), not this loop's flat gray. Run it once, the first time none
# of the six exist yet — a repo `init.sh` already seeded, or a repeat plan, has no reason to
# re-invoke it every apply.
WORKFLOW_LABEL_HIT=$(gh label list --repo "$REPO" --json name \
  --jq '[.[] | select(.name == "agent:claude" or .name == "agent:codex" or .name == "agent:opencode" or .name == "needs-review" or .name == "needs-execution" or .name == "needs-closing")] | length' \
  2>/dev/null || echo 0)
if [ "$WORKFLOW_LABEL_HIT" -eq 0 ]; then
  "$SCRIPT_DIR/create-tags.sh" --repo "$REPO"
fi

# Create the tracker first. If a later step fails, the stamped tracker is the durable
# recovery anchor and the next --apply resumes from it.
if [ -z "$existing_tracker" ]; then
  if [ -n "$TRACK_LABELS" ]; then
    track_url=$(gh issue create --repo "$REPO" --title "$TRACK_TITLE" \
      --body "$TRACK_DESIRED" --label "$TRACK_LABELS")
  else
    track_url=$(gh issue create --repo "$REPO" --title "$TRACK_TITLE" \
      --body "$TRACK_DESIRED")
  fi
  track_num=${track_url##*/}
  echo "created track #$track_num  $TRACK_TITLE"
else
  track_num=$(printf '%s\n' "$existing_tracker" | jq -r .number)
  track_url=$(printf '%s\n' "$existing_tracker" | jq -r .url)
  if [ "$tracker_adopted" = false ] || [ -z "$existing_tracker_body" ]; then
    edit_plan_issue "$existing_tracker" "$track_num" "$TRACK_TITLE" "$TRACK_DESIRED" "$TRACK_LABELS"
  fi
  echo "updated track #$track_num  $TRACK_TITLE"
fi

: > "$TMP/current-step-ids"
: > "$TMP/step-rows"
i=0
while [ "$i" -lt "$STEP_COUNT" ]; do
  title=$(jq -r ".steps[$i].title" "$SPEC")
  labels=$(jq -r ".steps[$i].labels // [] | join(\",\")" "$SPEC")
  step_id=$(jq -r ".steps[$i].id // \"step-$((i + 1))\"" "$SPEC")
  existing=$(issue_for_identity "step:$step_id")
  desired_body=$(desired_step_body "$i" "$step_id" "$track_url" "$(issue_body "$existing")")
  printf '%s\n' "$step_id" >> "$TMP/current-step-ids"

  if [ -z "$existing" ]; then
    if [ -n "$labels" ]; then
      url=$(gh issue create --repo "$REPO" --title "$title" \
        --body "$desired_body" --label "$labels")
    else
      url=$(gh issue create --repo "$REPO" --title "$title" --body "$desired_body")
    fi
    num=${url##*/}
    echo "created step  #$num  $title"
  else
    num=$(printf '%s\n' "$existing" | jq -r .number)
    url=$(printf '%s\n' "$existing" | jq -r .url)
    edit_plan_issue "$existing" "$num" "$title" "$desired_body" "$labels"
    echo "updated step  #$num  $title"
  fi
  task_title=$title
  if [ "$PROFILE" = strict ]; then
    task_title=$(strict_task_title "$title" "$step_id")
  fi
  printf '%s\t%s\t%s\n' "$num" "$step_id" "$task_title" >> "$TMP/step-rows"
  i=$((i + 1))
done

# Close steps removed from the current spec. History is retained; nothing is deleted.
while IFS="$(printf '\t')" read -r old_identity old_num; do
  case "$old_identity" in step:*) old_id=${old_identity#step:} ;; *) continue ;; esac
  old_state=$(printf '%s\n' "$ISSUES_JSON" | jq -r --argjson number "$old_num" \
    '.[] | select(.number == $number) | .state')
  grep -qxF "$old_id" "$TMP/current-step-ids" && continue
  [ "$old_state" = CLOSED ] && continue
  gh issue close "$old_num" --repo "$REPO" \
    --comment "Closed by plan reconciliation: step '$old_id' is no longer in spec revision $SPEC_HASH." \
    >/dev/null
  gh issue edit "$old_num" --repo "$REPO" \
    --remove-label "agent:claude,agent:codex,agent:opencode,needs-review,needs-execution,needs-closing" \
    >/dev/null
  echo "closed removed step #$old_num [$old_id]"
done < "$INDEX"

TRACK_FINAL=$(tracker_checklist_body "$TMP/step-rows")
edit_plan_issue "$existing_tracker" "$track_num" "$TRACK_TITLE" "$TRACK_FINAL" ""

# Native linking remains best-effort; the stamped task list is the durable fallback.
linked=0
while IFS="$(printf '\t')" read -r num step_id title; do
  child_id=$(gh api "repos/$REPO/issues/$num" --jq .id 2>/dev/null || true)
  [ -n "$child_id" ] || continue
  if gh api --method POST "repos/$REPO/issues/$track_num/sub_issues" \
       -F sub_issue_id="$child_id" >/dev/null 2>&1; then
    linked=$((linked + 1))
  fi
done < "$TMP/step-rows"
echo "native sub-issue link attempts succeeded: $linked/$STEP_COUNT"

if [ -n "$DOC" ]; then
  doc_tmp="$DOC.tmp.$$"
  approval_line=""
  if [ -n "$APPROVAL_BY" ]; then
    approval_day=${APPROVAL_AT%%T*}
    approval_line="- **Approval:** status=approved; by=${APPROVAL_BY}; at=${approval_day}${APPROVED_REV:+; rev=$APPROVED_REV}"
  fi
  [ -z "$APPROVED_REV" ] || approval_line=""
  awk -v url="$track_url" -v approval_line="$approval_line" '
    /^- \*\*Tracking issue:\*\*/ && replaced != 1 {
      print "- **Tracking issue:** url=" url
      replaced=1
      next
    }
    approval_line != "" && /^- \*\*Approval:\*\*/ && approved != 1 {
      print approval_line
      approved=1
      next
    }
    { print }
    END {
      if (replaced != 1) exit 3
      if (approval_line != "" && approved != 1) exit 4
    }
  ' "$DOC" > "$doc_tmp" || {
    status=$?
    rm -f "$doc_tmp"
    case "$status" in
      4) die "--doc has no '- **Approval:**' status line" ;;
      *) die "--doc has no '- **Tracking issue:**' status line" ;;
    esac
  }
  mv "$doc_tmp" "$DOC"
  echo "updated doc tracker link: $DOC"
fi

echo
echo "Done. Tracking issue: $track_url"
