#!/usr/bin/env bash
#
# plan-to-issues.sh — create a GitHub tracking issue + one sub-issue per step from a
# JSON spec. Implements METHODOLOGY.md §6 (driven by the plan-to-issues skill).
#
# Usage:
#   scripts/plan-to-issues.sh <spec.json>            # DRY RUN — prints what it would create
#   scripts/plan-to-issues.sh --apply <spec.json>    # actually create issues
#
# Spec shape:
#   {
#     "tracking": { "title": "Plan: <topic>", "body": "<summary + doc link + branch>" },
#     "labels":   ["plan"],
#     "steps": [
#       { "title": "Step 1 — ...", "body": "<DoD + verify cmds>", "labels": ["needs-execution","agent:codex"] }
#     ]
#   }
#
# Requires: gh (authenticated), jq. Run from inside the target git repo.
set -euo pipefail

APPLY=0
SPEC=""
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) SPEC="$arg" ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

[ -n "$SPEC" ] || die "no spec file given. Usage: $0 [--apply] <spec.json>"
[ -f "$SPEC" ] || die "spec file not found: $SPEC"
command -v gh >/dev/null || die "gh not found"
command -v jq >/dev/null || die "jq not found"
jq -e . "$SPEC" >/dev/null 2>&1 || die "spec is not valid JSON: $SPEC"
gh auth status >/dev/null 2>&1 || die "gh not authenticated (run: gh auth login)"

REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || die "not in a GitHub repo"
HAS_ISSUES=$(gh repo view --json hasIssuesEnabled --jq .hasIssuesEnabled)
[ "$HAS_ISSUES" = "true" ] || die "Issues are not enabled on $REPO"

# --- gather every label referenced (tracking + steps), deduped ---
ALL_LABELS=$(jq -r '[(.labels // [])[], (.steps[].labels // [])[]] | unique[]' "$SPEC")

TRACK_TITLE=$(jq -r '.tracking.title' "$SPEC")
TRACK_BODY=$(jq -r '.tracking.body // ""' "$SPEC")
TRACK_LABELS=$(jq -r '(.labels // []) | join(",")' "$SPEC")
STEP_COUNT=$(jq '.steps | length' "$SPEC")

echo "Repo:            $REPO"
echo "Mode:            $([ $APPLY -eq 1 ] && echo 'APPLY (will create issues)' || echo 'DRY RUN')"
echo "Labels to ensure: $(echo "$ALL_LABELS" | paste -sd' ' -)"
echo
echo "Tracking issue:  $TRACK_TITLE   [labels: $TRACK_LABELS]"
echo "Steps ($STEP_COUNT):"
for i in $(seq 0 $((STEP_COUNT - 1))); do
  t=$(jq -r ".steps[$i].title" "$SPEC")
  l=$(jq -r ".steps[$i].labels // [] | join(\",\")" "$SPEC")
  echo "  $((i + 1)). $t   [labels: $l]"
done

if [ $APPLY -eq 0 ]; then
  echo
  echo "DRY RUN — nothing created. Re-run with --apply to create these issues."
  exit 0
fi

# --- ensure labels exist (idempotent) ---
while IFS= read -r label; do
  [ -n "$label" ] || continue
  gh label create "$label" --color CCCCCC >/dev/null 2>&1 || true
done <<< "$ALL_LABELS"

# --- create step issues first, collect numbers ---
declare -a STEP_NUMS=()
declare -a STEP_TITLES=()
for i in $(seq 0 $((STEP_COUNT - 1))); do
  title=$(jq -r ".steps[$i].title" "$SPEC")
  body=$(jq -r ".steps[$i].body // \"\"" "$SPEC")
  labels=$(jq -r ".steps[$i].labels // [] | join(\",\")" "$SPEC")
  label_args=()
  [ -n "$labels" ] && label_args=(--label "$labels")
  url=$(gh issue create --repo "$REPO" --title "$title" --body "$body" "${label_args[@]}")
  num=${url##*/}
  STEP_NUMS+=("$num")
  STEP_TITLES+=("$title")
  echo "created step  #$num  $title"
done

# --- build the task-list fallback for the tracking body ---
tasklist=$'\n\n## Steps\n'
for idx in "${!STEP_NUMS[@]}"; do
  tasklist+="- [ ] #${STEP_NUMS[$idx]} ${STEP_TITLES[$idx]}"$'\n'
done

track_label_args=()
[ -n "$TRACK_LABELS" ] && track_label_args=(--label "$TRACK_LABELS")
track_url=$(gh issue create --repo "$REPO" --title "$TRACK_TITLE" \
  --body "${TRACK_BODY}${tasklist}" "${track_label_args[@]}")
track_num=${track_url##*/}
echo "created track #$track_num  $TRACK_TITLE"

# --- best-effort: link steps as native sub-issues (needs the REST database id) ---
linked=0
for num in "${STEP_NUMS[@]}"; do
  child_id=$(gh api "repos/$REPO/issues/$num" --jq .id 2>/dev/null) || continue
  if gh api --method POST "repos/$REPO/issues/$track_num/sub_issues" \
       -F sub_issue_id="$child_id" >/dev/null 2>&1; then
    linked=$((linked + 1))
  fi
done
if [ "$linked" -eq "${#STEP_NUMS[@]}" ]; then
  echo "linked $linked sub-issues to #$track_num"
else
  echo "sub-issue API linked $linked/${#STEP_NUMS[@]}; the task list in #$track_num is the fallback checklist"
fi

echo
echo "Done. Tracking issue: $track_url"
