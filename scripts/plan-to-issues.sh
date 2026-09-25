#!/usr/bin/env bash
#
# plan-to-issues.sh — reconcile a GitHub tracker and sub-issues from a JSON plan spec.
#
# Usage:
#   scripts/plan-to-issues.sh <spec.json>                   # offline dry run
#   scripts/plan-to-issues.sh --diff <spec.json>            # compare with GitHub
#   scripts/plan-to-issues.sh --apply [--doc <path>] <spec> # create/update/close
#
# Stable identity:
#   spec.id, or a hash of tracking.title when id is omitted
#   steps[].id, or step-N when id is omitted
#
# Every issue receives an HTML identity stamp. Re-running --apply discovers those stamps,
# resumes partial work, edits changed artifacts in place, and closes removed steps with a
# comment. It never identifies plans by editable issue titles.
set -euo pipefail

MODE=dry
SPEC=""
DOC=""
APPROVED_BY=""
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
  (.tracking.title | type == "string" and length > 0) and
  ((.labels // []) | type == "array" and all(.[]; type == "string" and length > 0)) and
  (.steps | type == "array" and length > 0 and length <= 100) and
  all(.steps[];
    (.id == null or (.id | type == "string" and length <= 80 and test("^[a-z0-9][a-z0-9._-]*$"))) and
    (.title | type == "string" and length > 0) and
    ((.labels // []) | type == "array" and all(.[]; type == "string" and length > 0))
  ) and
  ([.steps | to_entries[] | (.value.id // ("step-" + ((.key + 1) | tostring)))] as $ids
   | ($ids | unique | length) == ($ids | length))
' "$SPEC" >/dev/null 2>&1 \
  || die "spec must contain a tracker and uniquely identified, valid steps"


# Validate the local writer target before authentication or any issue mutation.
# A schema-less document needs deliberate migration; applying a plan cannot do it.
if [ "$MODE" = apply ] && [ -n "$DOC" ]; then
  [ -f "$DOC" ] || die "--doc file not found: $DOC"
  [ -w "$DOC" ] || die "--doc file is not writable: $DOC"
  "$(dirname "$0")/lifecycle-status.sh" --doc "$DOC" --validate-doc-status >/dev/null \
    || die "--doc Status is not valid v2; migrate using the v2 Feature/Security template"
fi

hash_stdin() {
  git hash-object --stdin 2>/dev/null || cksum | awk '{print $1}'
}

TRACK_TITLE=$(jq -r '.tracking.title' "$SPEC")
TRACK_BODY=$(jq -r '.tracking.body // ""' "$SPEC")
TRACK_LABELS=$(jq -r '(.labels // []) | join(",")' "$SPEC")
STEP_COUNT=$(jq '.steps | length' "$SPEC")
PLAN_KEY=$(jq -r '.id // empty' "$SPEC")
[ -n "$PLAN_KEY" ] || PLAN_KEY=$(printf '%s' "$TRACK_TITLE" | hash_stdin)
SPEC_HASH=$(jq -cS . "$SPEC" | hash_stdin)
PLAN_MARKER="agentic-flow:plan:$PLAN_KEY"

echo "Mode:            $MODE"
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

if [ "$MODE" = dry ]; then
  echo
  echo "OFFLINE DRY RUN — nothing queried or created."
  echo "Use --diff to compare with GitHub or --apply to reconcile."
  exit 0
fi

command -v gh >/dev/null || die "gh not found"
gh auth status >/dev/null 2>&1 || die "gh not authenticated (run: gh auth login)"
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || die "not in a GitHub repo"
HAS_ISSUES=$(gh repo view --json hasIssuesEnabled --jq .hasIssuesEnabled)
[ "$HAS_ISSUES" = true ] || die "Issues are not enabled on $REPO"
echo "Repo:            $REPO"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/plan-to-issues.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

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

# Read whole stamp lines into a validated exact index before any GitHub mutation.
# A malformed matching stamp or two issues with one identity is an ambiguity,
# not permission to choose the first search result.
INDEX="$TMP/issue-index"
: > "$INDEX"
TRACK_STAMP_RE='^<!-- agentic-flow:plan:([a-z0-9][a-z0-9._-]*) tracker spec:([a-f0-9]{40}|[a-f0-9]{64}|[0-9]{1,10})( approved-by:.+ approved-at:[^ ]+)? -->$'
STEP_STAMP_RE='^<!-- agentic-flow:plan:([a-z0-9][a-z0-9._-]*) step:([a-z0-9][a-z0-9._-]*) spec:([a-f0-9]{40}|[a-f0-9]{64}|[0-9]{1,10}) -->$'
printf '%s\n' "$ISSUES_JSON" | jq -r --arg prefix "<!-- $PLAN_MARKER " '
  .[] | .number as $number | .body | split("\n")[]
  | select(contains($prefix)) | [$number, .] | @tsv
' > "$TMP/stamp-lines" || die "could not parse issue stamps"
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
  previous_number=$(awk -F '\t' -v key="$identity" '$1 == key {print $2; exit}' "$INDEX")
  [ -z "$previous_number" ] || die "duplicate $identity stamps on issues #$previous_number and #$remote_number"
  previous_identity=$(awk -F '\t' -v number="$remote_number" '$2 == number {print $1; exit}' "$INDEX")
  [ -z "$previous_identity" ] || die "issue #$remote_number has multiple identity stamps: $previous_identity and $identity"
  printf '%s\t%s\n' "$identity" "$remote_number" >> "$INDEX"
done < "$TMP/stamp-lines"

issue_for_identity() { # <tracker | step:id>
  local number
  number=$(awk -F '\t' -v key="$1" '$1 == key {print $2; exit}' "$INDEX")
  [ -n "$number" ] || return 0
  printf '%s\n' "$ISSUES_JSON" | jq -c --arg number "$number" \
    '.[] | select((.number | tostring) == $number)'
}

TRACK_ID_MARKER="$PLAN_MARKER tracker"
existing_tracker=$(issue_for_identity tracker)
APPROVAL_BY=""
APPROVAL_AT=""
if [ -n "$existing_tracker" ]; then
  existing_body=$(printf '%s\n' "$existing_tracker" | jq -r '.body // ""')
  APPROVAL_BY=$(printf '%s\n' "$existing_body" \
    | sed -n 's/.* approved-by:\(.*\) approved-at:[^ ]* -->.*/\1/p' | head -1)
  APPROVAL_AT=$(printf '%s\n' "$existing_body" \
    | sed -n 's/.* approved-at:\([^ ]*\) -->.*/\1/p' | head -1)
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
TRACK_STAMP="<!-- $TRACK_ID_MARKER spec:$SPEC_HASH"
if [ -n "$APPROVAL_BY" ]; then
  TRACK_STAMP="$TRACK_STAMP approved-by:$APPROVAL_BY approved-at:$APPROVAL_AT"
fi
TRACK_STAMP="$TRACK_STAMP -->"
TRACK_DESIRED="${TRACK_BODY}

${TRACK_STAMP}"

if [ "$MODE" = diff ]; then
  if [ -z "$existing_tracker" ]; then
    echo
    echo "Tracker: missing (would create)"
  else
    existing_spec=$(printf '%s\n' "$existing_tracker" | jq -r '.body' \
      | sed -n 's/.* spec:\([^ ]*\) -->.*/\1/p' | head -1)
    if [ "$existing_spec" = "$SPEC_HASH" ]; then
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
    if [ -n "$existing" ]; then
      echo "Step $step_id: exists"
    else
      echo "Step $step_id: missing (would create)"
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
  "$(dirname "$0")/create-tags.sh" --repo "$REPO"
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
  gh issue edit "$track_num" --repo "$REPO" --title "$TRACK_TITLE" \
    --body "$TRACK_DESIRED" >/dev/null
  echo "updated track #$track_num  $TRACK_TITLE"
fi

: > "$TMP/current-step-ids"
: > "$TMP/step-rows"
i=0
while [ "$i" -lt "$STEP_COUNT" ]; do
  title=$(jq -r ".steps[$i].title" "$SPEC")
  body=$(jq -r ".steps[$i].body // \"\"" "$SPEC")
  labels=$(jq -r ".steps[$i].labels // [] | join(\",\")" "$SPEC")
  step_id=$(jq -r ".steps[$i].id // \"step-$((i + 1))\"" "$SPEC")
  marker="$PLAN_MARKER step:$step_id"
  stamp="<!-- $marker spec:$SPEC_HASH -->"
  desired_body="${body}

${stamp}"
  printf '%s\n' "$step_id" >> "$TMP/current-step-ids"
  existing=$(issue_for_identity "step:$step_id")

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
    gh issue edit "$num" --repo "$REPO" --title "$title" --body "$desired_body" >/dev/null
    echo "updated step  #$num  $title"
  fi
  printf '%s\t%s\t%s\n' "$num" "$step_id" "$title" >> "$TMP/step-rows"
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
  echo "closed removed step #$old_num [$old_id]"
done < "$INDEX"

tasklist='

## Steps
'
while IFS="$(printf '\t')" read -r num step_id title; do
  tasklist="${tasklist}- [ ] #${num} [${step_id}] ${title}
"
done < "$TMP/step-rows"
TRACK_FINAL="${TRACK_BODY}${tasklist}
${TRACK_STAMP}"
gh issue edit "$track_num" --repo "$REPO" --title "$TRACK_TITLE" \
  --body "$TRACK_FINAL" >/dev/null

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
    approval_line="- **Approval:** status=approved; by=${APPROVAL_BY}; at=${approval_day}"
  fi
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
