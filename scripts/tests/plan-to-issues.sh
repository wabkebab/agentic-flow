#!/usr/bin/env bash
# Sourced by self-test.sh; shared fixture context is intentional.
# shellcheck disable=SC1091,SC2034,SC2153,SC2164,SC2329 # Dispatcher globals (including ROOT), indirect fixture calls, inherited errexit.
[ -f "$ROOT/scripts/lib/brief.sh" ] || fail 'strict brief parser is missing'
INVALID_SPEC="$TMP/invalid-spec.json"
printf '%s\n' '{"tracking":{"title":"Plan: bad"},"steps":[]}' > "$INVALID_SPEC"
"$ROOT/scripts/plan-to-issues.sh" "$INVALID_SPEC" >/dev/null 2>"$TMP/plan.err" && fail "invalid plan spec was accepted"
grep -q "spec must contain" "$TMP/plan.err" || fail "invalid plan spec did not fail validation first"
"$ROOT/scripts/plan-to-issues.sh" --approved-by >/dev/null 2>"$TMP/approved-by.err" \
  && fail "plan-to-issues accepted --approved-by with no value"
grep -q -- "--approved-by requires a name" "$TMP/approved-by.err" \
  || fail "missing --approved-by value did not explain the error"

# --- plan-to-issues reconciliation -------------------------------------------------------
# Replay GitHub locally so failure/resume and repeated apply are deterministic, offline,
# and safe to run in any repository.
PLAN_DRIVER="$ROOT/scripts/plan-to-issues.sh"
GHFIX="$TMP/gh-fixture"
GHSTATE="$TMP/gh-state"
mkdir -p "$GHFIX" "$GHSTATE"
cat > "$GHFIX/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
state=${FAKE_GH_STATE:?}
if [ -n "${FAKE_GH_CALLS:-}" ]; then
  printf '%s\n' "$*" >> "$FAKE_GH_CALLS"
fi
mkdir -p "$state"
[ -f "$state/next" ] || printf '%s\n' 1 > "$state/next"

case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "repo view")
    case "$*" in
      *nameWithOwner*) printf '%s\n' owner/repo ;;
      *hasIssuesEnabled*) printf '%s\n' true ;;
    esac
    exit 0
    ;;
  "run view")
    printf '%s\n' "${FAKE_GH_RUN_CONCLUSION:-success}"
    exit 0
    ;;
  "label create") exit 0 ;;
  "issue view")
    case "${FAKE_GH_VIEW_FAILURE:-}" in
      malformed) printf '%s\n' '{broken'; exit 0 ;;
      timeout) exec sleep 10 ;;
    esac
    num=$3
    dir="$state/issue-$num"
    [ -d "$dir" ] || exit 1
    jq -n --argjson number "$num" --rawfile body "$dir/body" \
      --arg issue_state "$(cat "$dir/state")" \
      --arg url "$(cat "$dir/url" 2>/dev/null || printf 'https://github.com/owner/repo/issues/%s' "$num")" \
      '{number:$number,body:$body,state:$issue_state,url:$url}'
    exit 0
    ;;
  "issue list")
    if [ -n "${FAKE_GH_LIST_OVERRIDE:-}" ]; then
      cat "$FAKE_GH_LIST_OVERRIDE"
      exit 0
    fi
    out="$state/issues.jsonl"
    : > "$out"
    for dir in "$state"/issue-*; do
      [ -d "$dir" ] || continue
      if [ "${FAKE_GH_SEARCH_ONLY:-}" = 1 ]; then
        # The live stamp search does not discover handwritten issues.
        grep -Fq 'agentic-flow:plan:' "$dir/body" || continue
      fi
      num=${dir##*-}
      jq -n --argjson number "$num" \
        --arg title "$(cat "$dir/title")" \
        --rawfile body "$dir/body" \
        --arg issue_state "$(cat "$dir/state")" \
        --arg url "https://github.com/owner/repo/issues/$num" \
        '{number:$number,title:$title,body:$body,state:$issue_state,url:$url}' >> "$out"
    done
    jq -s . "$out"
    exit 0
    ;;
  "issue create")
    shift 2
    title=""; body=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --title) title="$2"; shift 2 ;;
        --body) body="$2"; shift 2 ;;
        --repo|--label) shift 2 ;;
        *) shift ;;
      esac
    done
    num=$(cat "$state/next")
    if [ "${FAKE_GH_FAIL_CREATE_NUMBER:-}" = "$num" ]; then
      echo "injected create failure" >&2
      exit 1
    fi
    printf '%s\n' $((num + 1)) > "$state/next"
    dir="$state/issue-$num"
    mkdir -p "$dir"
    printf '%s\n' "$title" > "$dir/title"
    printf '%s\n' "$body" > "$dir/body"
    printf '%s\n' OPEN > "$dir/state"
    printf 'https://github.com/owner/repo/issues/%s\n' "$num"
    exit 0
    ;;
  "issue edit")
    num=$3
    shift 3
    dir="$state/issue-$num"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --title) printf '%s\n' "$2" > "$dir/title"; shift 2 ;;
        --body) printf '%s\n' "$2" > "$dir/body"; shift 2 ;;
        --body-file) cat "$2" > "$dir/body"; shift 2 ;;
        --add-label)
          { cat "$dir/labels"; printf '\n%s\n' "$2"; } | tr ',' '\n' | sed '/^$/d' | sort -u > "$dir/labels.next"
          mv "$dir/labels.next" "$dir/labels"
          shift 2 ;;
        --remove-label)
          [ "$(cat "$dir/state")" = CLOSED ] || exit 2
          printf '%s\n' "$2" >> "$dir/removed-labels"
          shift 2 ;;
        --repo) shift 2 ;;
        *) shift ;;
      esac
    done
    exit 0
    ;;
  "issue close")
    num=$3
    printf '%s\n' CLOSED > "$state/issue-$num/state"
    exit 0
    ;;
esac

if [ "${1:-}" = api ]; then
  case "$*" in
    *"--method POST"*) exit 0 ;;
    *)
      endpoint=${2:-}
      num=${endpoint##*/}
      printf '%s\n' $((num + 1000))
      exit 0
      ;;
  esac
fi

echo "unsupported fake gh call: $*" >&2
exit 2
FAKE_GH
chmod +x "$GHFIX/gh"

# Scenario 9: the Part B cap travels with the brief, including in a fresh repository.
# shellcheck source=scripts/lib/brief.sh
source "$ROOT/scripts/lib/brief.sh"
(
  git init -qb main "$TMP/brief-cap"
  cd "$TMP/brief-cap"
  git config user.name Tester
  git config user.email tester@example.invalid
  git config commit.gpgsign false
  mkdir -p docs/inprogress
  doc=docs/inprogress/feature-cap.md
  cat > "$TMP/cap-part-b" <<'MD'
## Acceptance scenarios
Reject an oversized brief.
```text
# A heading-shaped line inside an example.
```
## Invariants
Approval binds the brief.
## Alpha — Fixture step
**DoD:** The fixture passes.
**Verify:** `make test-one F=plan-to-issues`
**Risks:** Counting bookkeeping.
**Red-first:** none
MD
  part_b_words=$(wc -w < "$TMP/cap-part-b")
  write_cap_brief() {
    {
      printf '%s\n' '# Feature — Cap fixture' '# Part A — Analysis'
      awk 'BEGIN {for (i=0; i<2001; i++) print "analysis"}'
      printf '%s\n' '# Part B — Implementation Brief' '```agentic-flow-plan'
      if [ "$1" = versioned ]; then printf '%s\n' 'format: 2'; fi
      printf '%s\n' 'id: cap' 'profile: strict' 'tracking: Plan: Cap fixture' 'branch: main' 'steps: alpha' '```'
      awk -v words="$(($2 - part_b_words))" 'BEGIN {for (i=0; i<words; i++) print "brief"}'
      cat "$TMP/cap-part-b"
      cat <<'MD'
## Status / Implementation status
- **Evidence schema:** v2
- **Tracking issue:** pending
- **Approval:** pending
- **Implementation head:** source=pr-head
- **Implementation PR:** pending
- **Verification evidence:** source=final-approval-run
- **Review verdict:** source=close-out-attestation
- **Memory:** pending
MD
      awk 'BEGIN {for (i=0; i<2001; i++) print "status"}'
    } > "$doc"
  }
  approve_cap_brief() {
    git add -- "$doc"
    git commit -qm 'Record brief revision'
    cap_rev=$(git rev-parse HEAD)
    sed "s/^- \*\*Approval:\*\* pending$/- **Approval:** status=approved; by=Tester; at=2026-11-21; rev=$cap_rev/" \
      "$doc" > "$TMP/cap-approved"
    cat "$TMP/cap-approved" > "$doc"
    git add -- "$doc"
    git commit -qm 'Record brief approval'
  }
  cap_driver() {
    PATH="$GHFIX:$PATH" FAKE_GH_STATE="$TMP/cap-gh" FAKE_GH_CALLS="$TMP/cap-calls" \
      "$PLAN_DRIVER" --doc "$doc" "$@"
  }

  write_cap_brief versioned 2001
  brief_parse "$doc" "$doc" local > "$TMP/cap-spec" 2> "$TMP/cap-error" \
    && fail 'format 2 accepted a Part B one word over the cap'
  grep -Fq 'Part B has 2001 words; cap is 2000' "$TMP/cap-error" \
    || fail 'format 2 did not report the Part B word count and cap'
  approve_cap_brief
  : > "$TMP/cap-calls"
  for mode in '' --apply; do
    cap_driver ${mode:+"$mode"} > "$TMP/cap-out" 2> "$TMP/cap-error" \
      && fail "plan-to-issues ${mode:-dry run} accepted an oversized format 2 brief"
    grep -Fq 'Part B has 2001 words; cap is 2000' "$TMP/cap-error" \
      || fail "plan-to-issues ${mode:-dry run} did not report the Part B cap"
    [ ! -s "$TMP/cap-calls" ] || fail "plan-to-issues ${mode:-dry run} called GitHub for an oversized brief"
  done

  write_cap_brief versioned 2000
  brief_parse "$doc" "$doc" local > "$TMP/cap-spec" || fail 'format 2 rejected Part B at the cap'
  jq -e '.steps[0].red_first == "none"' "$TMP/cap-spec" >/dev/null \
    || fail 'red-first opt-out did not parse'

  write_cap_brief legacy 2001
  approve_cap_brief
  brief_parse "$doc" "$doc" "$cap_rev" > "$TMP/cap-spec" || fail 'legacy approved brief was capped'
  cap_driver > "$TMP/cap-out" || fail 'legacy approved brief failed dry run in a fresh adopter repository'

  if active_scope docs; then
    mkdir -p docs/templates
    cp "$ROOT/docs/README.md" docs/README.md
    cp "$ROOT/docs/templates/feature-analysis.md" docs/templates/feature-analysis.md
    # Adopters may still have an older preserved template without the format key.
    sed '/^format: 2$/d' "$ROOT/docs/templates/security-review.md" > docs/templates/security-review.md
    git add -- docs/README.md docs/templates/feature-analysis.md docs/templates/security-review.md
    git commit -qm 'Seed current and legacy plan templates'
    for type in feature security; do
      case "$type" in feature) template=feature-analysis ;; security) template=security-review ;; esac
      grep -Fxq 'format: 2' "$ROOT/docs/templates/$template.md" || fail "$type template omitted format 2"
      AGENTIC_WORKTREE_ROOT="$TMP/cap-worktrees" "$ROOT/scripts/agentic-flow" \
        start "cap-$type" --type "$type" --no-fetch > "$TMP/cap-out" || fail "start failed for $type template"
      generated="$TMP/cap-worktrees/cap-$type/docs/inprogress/$type-cap-$type.md"
      [ "$(grep -Fxc 'format: 2' "$generated")" = 1 ] || fail "start did not write one format 2 field for $type"
      awk '
        /^# Part B / { part=1; next }
        part && /^## / {
          if (++heading==1 && $0!="## Acceptance scenarios") exit 1
          if (heading==2 && $0!="## Invariants") exit 1
        }
        END {if (heading<2) exit 1}
      ' "$generated" || fail "$type template did not lead Part B with scenarios and invariants"
      brief_parse "$generated" "$generated" local > "$TMP/cap-spec" || fail "$type template did not parse"
      jq -e '[.steps[].red_first] == ["none", "none"]' "$TMP/cap-spec" >/dev/null \
        || fail "$type template opted into red-first by default"
    done
  fi
)

# Pre-plan-block archives predate brief_parse. Exercise every archived plan block.
for archived_brief in "$ROOT"/docs/done/*.md "$ROOT"/docs/done/security/*.md; do
  [ -f "$archived_brief" ] || continue
  grep -Fxq '```agentic-flow-plan' "$archived_brief" || continue
  brief_parse "$archived_brief" "${archived_brief#"$ROOT"/}" local > "$TMP/archive-spec" \
    || fail "archived brief no longer parses: $archived_brief"
done

PLAN_SPEC="$TMP/plan-spec.json"
cat > "$PLAN_SPEC" <<'JSON'
{
  "id": "self-test-plan",
  "tracking": {"title": "Plan: self test", "body": "tracker"},
  "steps": [
    {"id": "alpha", "title": "Alpha", "body": "alpha v1"},
    {"id": "beta", "title": "Beta", "body": "beta v1", "labels": ["needs-execution"]}
  ]
}
JSON

plan_apply() {
  PATH="$GHFIX:$PATH" FAKE_GH_STATE="$GHSTATE" "$PLAN_DRIVER" --apply "$1" >/dev/null
}

plan_apply "$PLAN_SPEC" || fail "first plan apply failed against fake GitHub"
issue_count=$(find "$GHSTATE" -type d -name 'issue-*' | wc -l | tr -d ' ')
[ "$issue_count" -eq 3 ] || fail "first plan apply did not create one tracker and two steps"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$GHSTATE" \
  "$PLAN_DRIVER" --diff "$PLAN_SPEC" > "$TMP/plan-diff.out" \
  || fail "plan diff failed against fake GitHub"
grep -q "Tracker: current" "$TMP/plan-diff.out" \
  || fail "plan diff did not recognize the applied revision"
for issue_number in 1 2 3; do
  cp "$GHSTATE/issue-$issue_number/body" "$TMP/plan-before-$issue_number.body"
  cp "$GHSTATE/issue-$issue_number/title" "$TMP/plan-before-$issue_number.title"
done
plan_apply "$PLAN_SPEC" || fail "repeated identical plan apply failed"
issue_count=$(find "$GHSTATE" -type d -name 'issue-*' | wc -l | tr -d ' ')
[ "$issue_count" -eq 3 ] || fail "repeated plan apply duplicated issues"
for issue_number in 1 2 3; do
  cmp -s "$GHSTATE/issue-$issue_number/body" "$TMP/plan-before-$issue_number.body" \
    || fail "identical reapply changed issue #$issue_number body"
  cmp -s "$GHSTATE/issue-$issue_number/title" "$TMP/plan-before-$issue_number.title" \
    || fail "identical reapply changed issue #$issue_number title"
done

# Identity validation and discovery ambiguity must stop before mutation.
plan_reject_without_mutation() { # <name> <spec> [issue-list-override]
  : > "$TMP/plan-reject-calls"
  if PATH="$GHFIX:$PATH" FAKE_GH_STATE="$GHSTATE" \
    FAKE_GH_CALLS="$TMP/plan-reject-calls" FAKE_GH_LIST_OVERRIDE="${3:-}" \
    "$PLAN_DRIVER" --apply "$2" > "$TMP/plan-reject.out" 2>&1; then
    fail "plan apply accepted $1"
  fi
  if grep -Eq '(^| )(issue create|issue edit|issue close|label create|--method POST)( |$)' \
      "$TMP/plan-reject-calls"; then
    fail "plan apply mutated GitHub before rejecting $1"
  fi
}
jq '.steps = [{title:"Implicit"},{id:"step-1",title:"Explicit"}]' \
  "$PLAN_SPEC" > "$TMP/plan-collision.json"
plan_reject_without_mutation 'implicit/explicit step-1 collision' "$TMP/plan-collision.json"
grep -q 'uniquely identified' "$TMP/plan-reject.out" \
  || fail 'normalized ID collision lacked a useful error'
jq '.steps[0].id = "bad:id"' "$PLAN_SPEC" > "$TMP/plan-reserved-id.json"
plan_reject_without_mutation 'reserved marker character in step ID' "$TMP/plan-reserved-id.json"
grep -q 'uniquely identified' "$TMP/plan-reject.out" \
  || fail 'reserved marker character lacked a validation error'

PATH="$GHFIX:$PATH" FAKE_GH_STATE="$GHSTATE" gh issue list > "$TMP/plan-existing.json"
jq '.[1] as $step | . + [$step | .number = 99 | .url = "https://github.com/owner/repo/issues/99"]' \
  "$TMP/plan-existing.json" > "$TMP/plan-duplicate-step.json"
plan_reject_without_mutation 'duplicate remote step stamps' "$PLAN_SPEC" "$TMP/plan-duplicate-step.json"
grep -qE '2.*99|99.*2' "$TMP/plan-reject.out" \
  || fail 'duplicate step diagnostic did not name both issue numbers'
jq '.[0] as $tracker | . + [$tracker | .number = 98 | .url = "https://github.com/owner/repo/issues/98"]' \
  "$TMP/plan-existing.json" > "$TMP/plan-duplicate-tracker.json"
plan_reject_without_mutation 'duplicate remote tracker stamps' "$PLAN_SPEC" "$TMP/plan-duplicate-tracker.json"
grep -qE '1.*98|98.*1' "$TMP/plan-reject.out" \
  || fail 'duplicate tracker diagnostic did not name both issue numbers'
jq '.[0].body |= sub("spec:[0-9a-f]+";"spec:zz")' \
  "$TMP/plan-existing.json" > "$TMP/plan-malformed-stamp.json"
plan_reject_without_mutation 'malformed remote stamp' "$PLAN_SPEC" "$TMP/plan-malformed-stamp.json"
grep -q 'malformed identity stamp on issue #1' "$TMP/plan-reject.out" \
  || fail 'malformed stamp diagnostic did not name the issue'
jq -n '[range(1;101) | {number:.,title:"Other",body:"unrelated",state:"OPEN",url:("https://github.com/owner/repo/issues/" + tostring)}]' \
  > "$TMP/plan-full-page.json"
plan_reject_without_mutation '100-result discovery page' "$PLAN_SPEC" "$TMP/plan-full-page.json"
grep -q '100' "$TMP/plan-reject.out" || fail 'full discovery page lacked bound diagnostic'

# step-1 must never select the earlier step-10 issue. Create step-10 first so
# the old substring lookup picks the wrong row on the second apply.
jq '.id = "prefix-plan" | .steps = [{id:"step-10",title:"Ten",body:"ten"},{id:"step-1",title:"One",body:"one"}]' \
  "$PLAN_SPEC" > "$TMP/plan-prefix.json"
PREFIX_STATE="$TMP/gh-prefix-state"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$PREFIX_STATE" \
  "$PLAN_DRIVER" --apply "$TMP/plan-prefix.json" >/dev/null \
  || fail 'prefix fixture first apply failed'
jq '.steps[1].body = "one updated"' "$TMP/plan-prefix.json" > "$TMP/plan-prefix-updated.json"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$PREFIX_STATE" \
  "$PLAN_DRIVER" --apply "$TMP/plan-prefix-updated.json" >/dev/null \
  || fail 'prefix fixture reapply failed'
grep -q 'one updated' "$PREFIX_STATE/issue-3/body" \
  || fail 'step-1 did not update its exact issue'
grep -q 'ten' "$PREFIX_STATE/issue-2/body" \
  || fail 'step-1 update rewrote step-10'

# A reviewed step's live labels must survive a spec reapply unchanged.
printf '%s\n' 'agent:opencode,needs-review' > "$GHSTATE/issue-3/labels"
: > "$TMP/plan-reapply-calls"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$GHSTATE" FAKE_GH_CALLS="$TMP/plan-reapply-calls" \
  "$PLAN_DRIVER" --apply "$PLAN_SPEC" >/dev/null \
  || fail 'reviewer-state reapply failed'
if grep -Eq 'issue edit 3 .*--add-label' "$TMP/plan-reapply-calls"; then
  fail 'reapply reintroduced spec labels on a reviewed step'
fi
[ "$(cat "$GHSTATE/issue-3/labels")" = 'agent:opencode,needs-review' ] \
  || fail 'reapply changed live reviewer labels'

# Journal eligibility is fixed at creation and survives every reapply.
for created_issue in 1 2 3; do
  grep -q ' journal=v1' "$GHSTATE/issue-$created_issue/body" || fail 'created issue lacks journal=v1'
done
for legacy_issue in 1 2; do
  sed -E 's/ journal=v1//; s/ approved=[a-f0-9]{40}//' "$GHSTATE/issue-$legacy_issue/body" > "$TMP/legacy-body"
  mv "$TMP/legacy-body" "$GHSTATE/issue-$legacy_issue/body"
done
sed 's/journal=v1/journal=v2/' "$GHSTATE/issue-3/body" > "$TMP/other-journal-body"
mv "$TMP/other-journal-body" "$GHSTATE/issue-3/body"
plan_apply "$PLAN_SPEC" || fail 'journal-preserving reapply failed'
for legacy_issue in 1 2; do
  if grep -q ' journal=' "$GHSTATE/issue-$legacy_issue/body"; then fail 'reapply changed legacy eligibility'; fi
done
grep -q ' journal=v2' "$GHSTATE/issue-3/body" || fail 'reapply discarded an existing journal value'

APPROVAL_DOC_ROOT="$TMP/approval-doc-root"
mkdir -p "$APPROVAL_DOC_ROOT/docs/inprogress"
APPROVAL_DOC="$APPROVAL_DOC_ROOT/docs/inprogress/feature-approval.md"
cat > "$APPROVAL_DOC" <<'MD'
## Tracker
- [x] F-1 done
## Status / Implementation status
- **Evidence schema:** v2
- **Tracking issue:** pending
- **Approval:** pending
- **Implementation head:** source=pr-head
- **Implementation PR:** url=https://github.com/owner/repo/pull/2
- **Verification evidence:** source=final-approval-run
- **Review verdict:** source=pr-head-approval
- **Memory:** status=n/a
MD
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$GHSTATE" \
  "$PLAN_DRIVER" --apply --approved-by "Test User" --doc "$APPROVAL_DOC" "$PLAN_SPEC" >/dev/null \
  || fail "plan apply with --approved-by failed against fake GitHub"
tracker_body=$(grep -Rl "agentic-flow:plan:self-test-plan tracker" "$GHSTATE"/issue-*/body | xargs cat)
printf '%s\n' "$tracker_body" | grep -q 'approved-by:Test User approved-at:' \
  || fail "approval stamp did not land in the existing tracker marker"
approved_at=$(printf '%s\n' "$tracker_body" | sed -n 's/.*approved-at:\([^ ]*\) -->.*/\1/p' | head -1)
[ -n "$approved_at" ] || fail "approval stamp did not include approved-at"
grep -qF -- "- **Approval:** status=approved; by=Test User; at=${approved_at%%T*}" "$APPROVAL_DOC" \
  || fail "--doc did not write the canonical Approval status line"
grep -qF -- '- **Tracking issue:** url=https://github.com/owner/repo/issues/1' "$APPROVAL_DOC" \
  || fail "--doc did not write the v2 tracking URL"
AGENTIC_PROJECT_ROOT="$APPROVAL_DOC_ROOT" "$ROOT/scripts/lifecycle-status.sh" --check >/dev/null \
  || fail "lifecycle-status did not recognize the machine-written Approval line"

# Writer validation precedes authentication. Each rejected case must leave the
# mock gh call log empty, rather than merely avoid an issue mutation.
REJECT_DOC="$TMP/rejected-plan-doc.md"
reject_before_gh() { # <case-name> <doc-path> <approved-by>
  rm -f "$TMP/rejected-gh-calls"
  PATH="$GHFIX:$PATH" FAKE_GH_STATE="$GHSTATE" FAKE_GH_CALLS="$TMP/rejected-gh-calls" \
    "$PLAN_DRIVER" --apply --doc "$2" --approved-by "$3" "$PLAN_SPEC" \
    > "$TMP/rejected-plan.out" 2>&1 \
    && fail "plan apply accepted $1"
  [ ! -e "$TMP/rejected-gh-calls" ] \
    || fail "plan apply called gh before rejecting $1"
}
sed 's/Evidence schema:\*\* v2/Evidence schema:** v3/' "$APPROVAL_DOC" > "$REJECT_DOC"
reject_before_gh 'unknown schema' "$REJECT_DOC" 'Test User'
sed '/^- \*\*Evidence schema:/d' "$APPROVAL_DOC" > "$REJECT_DOC"
reject_before_gh 'legacy document' "$REJECT_DOC" 'Test User'
sed 's/source=pr-head-approval/source=not-approved/' "$APPROVAL_DOC" > "$REJECT_DOC"
reject_before_gh 'invalid v2 selector' "$REJECT_DOC" 'Test User'
cp "$APPROVAL_DOC" "$REJECT_DOC"
printf '%s\n' '- **Approval:** status=approved; by=Other; at=2026-01-01' >> "$REJECT_DOC"
reject_before_gh 'duplicate v2 field' "$REJECT_DOC" 'Test User'
reject_before_gh 'missing document' "$TMP/no-such-doc.md" 'Test User'
cp "$APPROVAL_DOC" "$REJECT_DOC"
chmod 444 "$REJECT_DOC"
reject_before_gh 'unwritable document' "$REJECT_DOC" 'Test User'
chmod 644 "$REJECT_DOC"
reject_before_gh 'newline in approver' "$REJECT_DOC" "$(printf 'Test\nUser')"
reject_before_gh 'semicolon in approver' "$REJECT_DOC" 'Test;User'
reject_before_gh 'surrounding whitespace in approver' "$REJECT_DOC" ' Test User '
reject_before_gh 'trailing dot in approver' "$REJECT_DOC" 'John D.'
reject_before_gh 'trailing hyphen in approver' "$REJECT_DOC" 'user-'

plan_apply "$PLAN_SPEC" || fail "plan apply without --approved-by failed after approval"
tracker_body_after=$(grep -Rl "agentic-flow:plan:self-test-plan tracker" "$GHSTATE"/issue-*/body | xargs cat)
printf '%s\n' "$tracker_body_after" | grep -q "approved-at:$approved_at" \
  || fail "repeated apply changed the original approval timestamp"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$GHSTATE" \
  "$PLAN_DRIVER" --apply --approved-by "Other User" "$PLAN_SPEC" >/dev/null 2>"$TMP/approval-conflict.err" \
  && fail "plan apply silently rewrote an existing approval"
grep -q "already approved by 'Test User'" "$TMP/approval-conflict.err" \
  || fail "approval conflict did not explain the preserved approver"

UPDATED_SPEC="$TMP/plan-spec-updated.json"
jq '.steps[0].body = "alpha v2"' "$PLAN_SPEC" > "$UPDATED_SPEC"
plan_apply "$UPDATED_SPEC" || fail "changed plan did not reconcile"
grep -Rl "alpha v2" "$GHSTATE"/issue-*/body >/dev/null \
  || fail "changed step body was not updated in place"
tracker_body_updated=$(grep -Rl "agentic-flow:plan:self-test-plan tracker" "$GHSTATE"/issue-*/body | xargs cat)
printf '%s\n' "$tracker_body_updated" | grep -q "approved-at:$approved_at" \
  || fail "changed plan reconciliation dropped the original approval"

REMOVED_SPEC="$TMP/plan-spec-removed.json"
jq '.steps = [.steps[0]]' "$UPDATED_SPEC" > "$REMOVED_SPEC"
plan_apply "$REMOVED_SPEC" || fail "plan with a removed step did not reconcile"
beta_state=$(grep -Rl "step:beta" "$GHSTATE"/issue-*/body | sed 's|/body$|/state|' | xargs cat)
[ "$beta_state" = CLOSED ] || fail "removed plan step was not closed with history retained"
beta_dir=$(grep -Rl "step:beta" "$GHSTATE"/issue-*/body | sed 's|/body$||')
[ -f "$beta_dir/removed-labels" ] \
  || fail "removed plan step retained workflow labels"
[ "$(cat "$beta_dir/removed-labels")" = 'agent:claude,agent:codex,agent:opencode,needs-review,needs-execution,needs-closing' ] \
  || fail "removed plan step did not clear all workflow labels after closing"

PARTIAL_STATE="$TMP/gh-partial-state"
PARTIAL_SPEC="$TMP/partial-spec.json"
jq '.id = "partial-plan"' "$PLAN_SPEC" > "$PARTIAL_SPEC"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$PARTIAL_STATE" FAKE_GH_FAIL_CREATE_NUMBER=2 \
  "$PLAN_DRIVER" --apply "$PARTIAL_SPEC" >/dev/null 2>&1 \
  && fail "injected partial GitHub failure unexpectedly succeeded"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$PARTIAL_STATE" \
  "$PLAN_DRIVER" --apply "$PARTIAL_SPEC" >/dev/null \
  || fail "plan apply did not resume after a partial failure"
partial_count=$(find "$PARTIAL_STATE" -type d -name 'issue-*' | wc -l | tr -d ' ')
[ "$partial_count" -eq 3 ] || fail "partial resume duplicated or omitted plan issues"

# Standard creates one work issue. Its packet and approval metadata stay on
# that issue across reapply, and a topology change fails before mutation.
STANDARD_SPEC="$TMP/standard-spec.json"
jq '{profile:"standard",id:"standard-plan",steps:[.steps[0] | .packet = {
  brief:"docs/inprogress/feature.md Step 1",
  definition_of_done:"Failure path and success path pass",
  verification:"make check and make test-one F=plan-to-issues",
  risks:"Malformed input must fail before a GitHub write"
}]}' "$PLAN_SPEC" > "$STANDARD_SPEC"
packet_words=$(jq -r '.steps[0].packet |
    "## Executor packet\nProfile: Standard\nBrief: \(.brief)\nDefinition of Done: \(.definition_of_done)\nVerification: \(.verification)\nRisks and edge cases: \(.risks)"' \
  "$STANDARD_SPEC" | wc -w | tr -d ' ')
if [ -n "${AGENTIC_MEASURE_EVENTS:-}" ]; then
  measure_event "packet_words:$packet_words"
fi
jq --argjson extra "$((800 - packet_words))" \
  '.steps[0].packet.verification += (" " + ([range($extra) | "word"] | join(" ")))' \
  "$STANDARD_SPEC" > "$TMP/packet-at-cap.json"
"$PLAN_DRIVER" "$TMP/packet-at-cap.json" >/dev/null || fail '800-word packet was rejected'
STANDARD_STATE="$TMP/gh-standard-state"
if PATH="$GHFIX:$PATH" FAKE_GH_STATE="$STANDARD_STATE" \
  "$PLAN_DRIVER" --apply "$STANDARD_SPEC" > "$TMP/standard-unapproved.out" 2>&1; then
  fail 'Standard created an issue without plan approval metadata'
fi
grep -q 'requires --approved-by' "$TMP/standard-unapproved.out" \
  || fail 'Standard missing approval lacked diagnostic'
[ ! -d "$STANDARD_STATE/issue-1" ] || fail 'Standard wrote an unapproved work issue'
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$STANDARD_STATE" \
  "$PLAN_DRIVER" --apply --approved-by "Test User" "$STANDARD_SPEC" >/dev/null \
  || fail 'Standard apply failed'
[ "$(find "$STANDARD_STATE" -type d -name 'issue-*' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail 'Standard created a parent or more than one work issue'
grep -q 'agentic-flow:topology:standard' "$STANDARD_STATE/issue-1/body" \
  || fail 'Standard work issue lacks topology stamp'
grep -q 'approved-by:Test User' "$STANDARD_STATE/issue-1/body" \
  || fail 'Standard approval metadata was not recorded on work issue'
grep -q '^### Definition of done$' "$STANDARD_STATE/issue-1/body" \
  || fail 'Standard work issue lacks executor packet'
STANDARD_DOC="$TMP/standard-doc.md"
cp "$APPROVAL_DOC" "$STANDARD_DOC"
sed 's@url=https://github.com/owner/repo/issues/1@pending@; s/status=approved; by=Test User; at=[0-9-]*/pending/' \
  "$STANDARD_DOC" > "$TMP/standard-doc-pending.md"
mv "$TMP/standard-doc-pending.md" "$STANDARD_DOC"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$STANDARD_STATE" \
  "$PLAN_DRIVER" --apply --doc "$STANDARD_DOC" "$STANDARD_SPEC" >/dev/null \
  || fail 'Standard apply could not write the work issue URL and approval to the document'
grep -qF -- '- **Tracking issue:** url=https://github.com/owner/repo/issues/1' "$STANDARD_DOC" \
  || fail 'Standard document did not receive the work issue URL'
grep -qF -- '- **Approval:** status=approved; by=Test User;' "$STANDARD_DOC" \
  || fail 'Standard document did not receive approval evidence'
cp "$STANDARD_STATE/issue-1/body" "$TMP/standard-before.body"
: > "$TMP/standard-reapply-calls"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$STANDARD_STATE" FAKE_GH_CALLS="$TMP/standard-reapply-calls" \
  "$PLAN_DRIVER" --apply "$STANDARD_SPEC" >/dev/null \
  || fail 'Standard reapply failed'
cmp -s "$STANDARD_STATE/issue-1/body" "$TMP/standard-before.body" \
  || fail 'Standard reapply changed work issue metadata'
if grep -Eq 'issue edit 1 .*--add-label' "$TMP/standard-reapply-calls"; then
  fail 'Standard reapply reset live work issue labels'
fi

standard_reject() { # <name> <spec>
  : > "$TMP/standard-reject-calls"
  if PATH="$GHFIX:$PATH" FAKE_GH_STATE="$STANDARD_STATE" \
    FAKE_GH_CALLS="$TMP/standard-reject-calls" \
    "$PLAN_DRIVER" --apply "$2" > "$TMP/standard-reject.out" 2>&1; then
    fail "Standard accepted $1"
  fi
  if grep -Eq '(^| )(issue create|issue edit|issue close|label create)( |$)' \
      "$TMP/standard-reject-calls"; then
    fail "Standard mutated GitHub before rejecting $1"
  fi
}
jq '.steps = []' "$STANDARD_SPEC" > "$TMP/standard-zero.json"
standard_reject 'zero steps' "$TMP/standard-zero.json"
jq '.steps += [.steps[0] | .id="second"]' "$STANDARD_SPEC" > "$TMP/standard-two.json"
standard_reject 'two steps' "$TMP/standard-two.json"
jq '.profile="strict"' "$STANDARD_SPEC" > "$TMP/strict-no-parent.json"
standard_reject 'Strict without parent specification' "$TMP/strict-no-parent.json"
jq '.profile="strict" | .tracking={title:"Plan: standard-plan"}' \
  "$STANDARD_SPEC" > "$TMP/topology-change.json"
standard_reject 'topology-changing reapply' "$TMP/topology-change.json"
grep -q 'migration' "$TMP/standard-reject.out" \
  || fail 'topology change lacked migration diagnostic'
jq '.steps[0].packet.brief = ([range(0;801) | "word"] | join(" "))' \
  "$STANDARD_SPEC" > "$TMP/packet-overflow.json"
standard_reject 'packet overflow' "$TMP/packet-overflow.json"
grep -q '800 words' "$TMP/standard-reject.out" \
  || fail 'packet overflow lacked bound diagnostic'

ASSURANCE_FIX="$TMP/assurance-fixture"
mkdir -p "$ASSURANCE_FIX/scripts"
cp "$ROOT/scripts/plan-to-issues.sh" "$ROOT/scripts/assurance.sh" "$ASSURANCE_FIX/scripts/"
printf 'strict\n' > "$ASSURANCE_FIX/.agentic-flow-assurance"
if PATH="$GHFIX:$PATH" FAKE_GH_STATE="$STANDARD_STATE" \
  "$ASSURANCE_FIX/scripts/plan-to-issues.sh" --apply "$STANDARD_SPEC" \
  > "$TMP/standard-downgrade.out" 2>&1; then
  fail 'Standard accepted a downgrade below the project baseline'
fi
grep -q 'downgrade' "$TMP/standard-downgrade.out" \
  || fail 'Standard downgrade lacked diagnostic'

STRICT_SPEC="$TMP/strict-spec.json"
jq '.profile="strict" | .id="strict-plan" | .tracking.body="Tracker prose\n---\nMore details." |
  .steps |= map(.packet={brief:"approved brief step",definition_of_done:"reviewed behavior",
    verification:"make check",risks:"failure path"})' "$PLAN_SPEC" > "$STRICT_SPEC"
STRICT_STATE="$TMP/gh-strict-state"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$STRICT_STATE" \
  "$PLAN_DRIVER" --apply "$STRICT_SPEC" >/dev/null \
  || fail 'Strict apply failed'
[ "$(find "$STRICT_STATE" -type d -name 'issue-*' | wc -l | tr -d ' ')" -eq 3 ] \
  || fail 'Strict did not create one tracker and two sub-issues'
grep -q 'agentic-flow:topology:strict' "$STRICT_STATE/issue-1/body" \
  || fail 'Strict parent lacks topology stamp'
grep -Fxq 'Tracker prose' "$STRICT_STATE/issue-1/body" \
  || fail 'Strict tracker lost its tracking body'
grep -Fxq '\---' "$STRICT_STATE/issue-1/body" \
  || fail 'Strict tracking prose can render as a setext heading'
grep -q '^### Definition of done$' "$STRICT_STATE/issue-2/body" \
  || fail 'Strict step lacks executor packet'

# Document-derived specs: real commits, fake GitHub, no ambient working-tree input.
BRIEF_FIX="$TMP/brief-repo"
mkdir -p "$BRIEF_FIX/docs"
git -C "$BRIEF_FIX" init -q
git -C "$BRIEF_FIX" config user.name Tester
git -C "$BRIEF_FIX" config user.email tester@example.invalid
cat > "$BRIEF_FIX/docs/plan.md" <<'MD'
# Feature — Fixture stations
## Tracker
- [ ] S-1 fixture
# Part B — Implementation Brief
```agentic-flow-plan
id: deterministic-stations
profile: strict
tracking: Plan: Deterministic stations
branch: phase-1
base: trunk
steps: s-1 s-2 s-3 s-4 s-5 s-6 s-7 s-8 s-9
```
## Verification commands
```bash
make check
make test
```
MD
for n in 1 2 3 4 5 6 7 8 9; do
  cat <<MD
## S-$n — Fixture step $n
**Approach:** Parsing is strict.
**DoD:** The fixture passes.
**Verify:** make test-one F=plan-to-issues
MD
  if [ "$n" -eq 2 ]; then
    cat <<'MD'
**Risks:**
- Keep <placeholder> visible.
- Preserve `a | b`.
MD
  else
    printf '%s\n' '**Risks:** A malformed plan must fail.'
  fi
  cat <<'MD'
**Red-first:** `scripts/self-test.sh --only plan-to-issues` — scripts/self-test.sh
MD
done >> "$BRIEF_FIX/docs/plan.md"
cat >> "$BRIEF_FIX/docs/plan.md" <<'MD'
## Status / Implementation status
- **Evidence schema:** v2
- **Tracking issue:** pending
- **Approval:** pending
- **Implementation head:** source=pr-head
- **Implementation PR:** pending
- **Verification evidence:** source=final-approval-run
- **Review verdict:** source=pr-head-approval
- **Memory:** pending
MD
git -C "$BRIEF_FIX" add docs/plan.md
git -C "$BRIEF_FIX" -c commit.gpgsign=false commit -qm 'Record approved plan'
BRIEF_REV=$(git -C "$BRIEF_FIX" rev-parse HEAD)
sed "s/^- \*\*Approval:\*\*.*/- **Approval:** status=approved; by=Tester; at=2026-11-12; rev=$BRIEF_REV/" \
  "$BRIEF_FIX/docs/plan.md" > "$TMP/approved-plan.md"
cp "$TMP/approved-plan.md" "$BRIEF_FIX/docs/plan.md"
git -C "$BRIEF_FIX" add docs/plan.md
git -C "$BRIEF_FIX" -c commit.gpgsign=false commit -qm 'Record approval revision'
brief_run() { (cd "$BRIEF_FIX" && PATH="$GHFIX:$PATH" FAKE_GH_STATE="$TMP/brief-gh" \
  FAKE_GH_CALLS="$TMP/brief-calls" "$PLAN_DRIVER" --doc docs/plan.md "$@"); }
brief_run > "$TMP/brief-dry.out" || fail 'approved brief did not dry-run'
grep -q 'Steps (9)' "$TMP/brief-dry.out" || fail 'brief generated the wrong issue set'
brief_parse "$BRIEF_FIX/docs/plan.md" docs/plan.md "$BRIEF_REV" > "$TMP/brief-spec.json" \
  || fail 'valid brief parser failed'
[ "$(jq -r '.steps[3].id' "$TMP/brief-spec.json")" = s-4 ] || fail 'brief order changed'
jq -e '.steps[3].red_first == [{selector:"scripts/self-test.sh --only plan-to-issues",paths:["scripts/self-test.sh"]}]' \
  "$TMP/brief-spec.json" > /dev/null || fail 'Red-first proof was not parsed'
printf 'plan without newline' | brief_normalize > "$TMP/normalized"
printf 'plan without newline' > "$TMP/expected-normalized"
cmp -s "$TMP/normalized" "$TMP/expected-normalized" || fail 'normalization changed content bytes'
printf '%s\n' '## Approach' '- **Memory:** keep this instruction visible' | brief_normalize > "$TMP/normalized"
grep -q 'keep this instruction visible' "$TMP/normalized" || fail 'normalization erased plan content outside Status'


for label in DoD Verify Risks; do
  case "$label" in DoD) field=definition_of_done ;; Verify) field=verification ;; Risks) field=risks ;; esac
  git -C "$BRIEF_FIX" show "$BRIEF_REV:docs/plan.md" | \
    awk -v label="$label" '/^## S-4 — / {step=1; next} step && /^## / {exit}
      step && index($0,"**" label ":** ")==1 {sub(/^\*\*[^*]+:\*\* /,""); print; exit}' > "$TMP/label-source"
  jq -r --arg field "$field" '.steps[3].packet[$field] | split("\n")[0]' "$TMP/brief-spec.json" > "$TMP/label-packet"
  cmp -s "$TMP/label-source" "$TMP/label-packet" || fail "packet changed $label bytes"
done
jq -e '
  .steps[0].packet.risks == "A malformed plan must fail." and
  .steps[1].packet.risks == "- Keep <placeholder> visible.\n- Preserve `a | b`."
' "$TMP/brief-spec.json" >/dev/null || fail 'brief changed risk content'
# Strict parse failures must name a source line.
for mutation in duplicate duplicate-section missing orphan extra-section malformed traversal empty-risks prose-risks; do
  case "$mutation" in
    duplicate-section) sed 's/^## S-2 — /## S-1 — /' "$TMP/approved-plan.md" ;;
    extra-section) sed 's/steps: s-1 s-2 /steps: s-1 /' "$TMP/approved-plan.md" ;;
    traversal) sed 's@— scripts/self-test.sh@— ../outside.sh@' "$TMP/approved-plan.md" ;;
    duplicate) sed 's/steps: s-1 /steps: s-1 s-1 /' "$TMP/approved-plan.md" ;;
    missing) sed '/^\*\*Risks:\*\*/d' "$TMP/approved-plan.md" ;;
    empty-risks) sed 's/^\*\*Risks:\*\*.*/**Risks:**/' "$TMP/approved-plan.md" ;;
    prose-risks) awk '/^\*\*Risks:/ {print "**Risks:**\nThis is prose."; next} {print}' "$TMP/approved-plan.md" ;;
    orphan) sed 's/steps: s-1 /steps: absent s-1 /' "$TMP/approved-plan.md" ;;
    malformed) sed 's/^\*\*Red-first:\*\*.*/**Red-first:** broken/' "$TMP/approved-plan.md" ;;
  esac > "$TMP/bad-brief.md"
  if brief_parse "$TMP/bad-brief.md" fixture.md "$BRIEF_REV" > /dev/null 2> "$TMP/parse.err"; then
    fail "brief accepted $mutation"
  fi
  grep -Eq 'fixture.md:[0-9]+:' "$TMP/parse.err" || fail 'parse error omitted line'
done
FAKE_GH_FAIL_CREATE_NUMBER=2 brief_run --apply > /dev/null 2>&1 && fail 'approved creation unexpectedly succeeded'
[ -e "$TMP/brief-gh/issue-1/body" ] || fail 'interrupted apply did not retain its tracker'
brief_run --apply > /dev/null || fail 'approved document apply did not resume'
git -C "$BRIEF_FIX" add docs/plan.md
git -C "$BRIEF_FIX" -c commit.gpgsign=false commit -qm 'Record tracking issue'
brief_hash=$(jq -cS . "$TMP/brief-spec.json" | git hash-object --stdin)
grep -Fq "tracker spec:$brief_hash journal=v1 approved=$BRIEF_REV" "$TMP/brief-gh/issue-1/body" \
  || fail 'issue layout changed the approved spec hash'
normalize_issue_body() {
  sed -E 's/spec:[a-f0-9]{40}/spec:<hash>/; s/approved=[a-f0-9]{40}/approved=<revision>/; s@/blob/[a-f0-9]{40}/@/blob/<revision>/@; s/approved-at:[^ ]+/approved-at:<time>/' "$1"
}
normalize_issue_body "$TMP/brief-gh/issue-1/body" > "$TMP/tracker-rendered"
cat > "$TMP/tracker-golden" <<'MD'
## Plan: Deterministic stations

**Profile:** Strict · `phase-1` → `trunk` · [Approved brief](https://github.com/owner/repo/blob/<revision>/docs/plan.md)

### Steps

- [ ] #2 [s-1] Fixture step 1
- [ ] #3 [s-2] Fixture step 2
- [ ] #4 [s-3] Fixture step 3
- [ ] #5 [s-4] Fixture step 4
- [ ] #6 [s-5] Fixture step 5
- [ ] #7 [s-6] Fixture step 6
- [ ] #8 [s-7] Fixture step 7
- [ ] #9 [s-8] Fixture step 8
- [ ] #10 [s-9] Fixture step 9

<!-- agentic-flow:plan:deterministic-stations tracker spec:<hash> journal=v1 approved=<revision> approved-by:Tester approved-at:<time> -->
<!-- agentic-flow:topology:strict -->
MD
diff -u "$TMP/tracker-golden" "$TMP/tracker-rendered" || fail 'Strict tracker Markdown changed'
normalize_issue_body "$TMP/brief-gh/issue-3/body" > "$TMP/strict-rendered"
cat > "$TMP/strict-golden" <<'MD'
## s-2 — Fixture step 2

[Tracker #1](https://github.com/owner/repo/issues/1) · **Profile:** Strict · [Approved brief](https://github.com/owner/repo/blob/<revision>/docs/plan.md)

### Definition of done

The fixture passes.

### Verify

make test-one F=plan-to-issues

### Verification commands

```bash
make check
make test
```

### Risks

- Keep &lt;placeholder&gt; visible.
- Preserve `a | b`.

<!-- agentic-flow:brief:docs/plan.md -->
<!-- agentic-flow:plan:deterministic-stations step:s-2 spec:<hash> journal=v1 approved=<revision> -->
<!-- agentic-flow:topology:strict -->
MD
diff -u "$TMP/strict-golden" "$TMP/strict-rendered" || fail 'Strict step issue Markdown changed'
brief_run --diff > "$TMP/new-brief-diff.out" || fail 'new-layout tracker discovery failed'
grep -q '^Tracker: current$' "$TMP/new-brief-diff.out" || fail 'new tracker was not recognized'
# Use an actual old-layout tracker in the approval-only migration below.
{
  printf '%s\n' 'Handwritten tracker' '' '## Steps' '- [ ] #2 [s-1] S-1 — Fixture step 1' ''
  tail -n 2 "$TMP/brief-gh/issue-1/body"
} > "$TMP/old-layout-tracker"
cp "$TMP/old-layout-tracker" "$TMP/brief-gh/issue-1/body"
for n in 1 2 3 4 5 6 7 8 9 10; do
  grep -q "approved=$BRIEF_REV" "$TMP/brief-gh/issue-$n/body" || fail 'issue lacks approved revision'
  # Simulate legacy creation without journal=v1. Migration must preserve eligibility.
  sed -E 's/ journal=v1//; s/ approved=[a-f0-9]{40}//' "$TMP/brief-gh/issue-$n/body" > "$TMP/legacy-body"
  cp "$TMP/legacy-body" "$TMP/brief-gh/issue-$n/body"
  cp "$TMP/legacy-body" "$TMP/legacy-before-$n"
done
# Replay three distinct legacy states across the actual migration.
source "$ROOT/scripts/lib/workflow.sh"
source "$ROOT/scripts/lib/journal.sh"
workflow_load "$ROOT" || fail 'migration workflow load failed'
REVIEW_EXECUTORS=' exec ' REVIEW_REVIEWERS=' review ' REVIEW_APPROVERS=' plan '
brief_replays() {
  local n step comments
  for n in 2 3 4; do
    journal_context "$(cat "$TMP/brief-gh/issue-$n/body")" || fail 'migration stamp context failed'
    step=$JOURNAL_STEP
    comments=$(jq -nc --arg step "$step" --arg head "$BRIEF_REV" --argjson n "$n" '
      if $n==4 then [] else
        [{id:"submit",dbid:"1",last_edited_at:null,author:"exec",body:("Implemented in "+$head)},
         {id:"review",dbid:"2",last_edited_at:null,author:"review",
          body:("agentic-flow-review: status="+(if $n==2 then "approved" else "changes-requested" end)+"; step="+$step+"; head="+$head+"; role=reviewer")}] end')
    journal_replay "$comments" step-strict || fail 'migration replay failed'
  done
}
brief_replays > "$TMP/replay-before"
brief_run --diff > "$TMP/brief-diff.out" || fail 'brief diff failed'
brief_run --apply > /dev/null || fail 'legacy stamp migration failed'
brief_replays > "$TMP/replay-after"
cmp -s "$TMP/replay-before" "$TMP/replay-after" || fail 'migration changed replay state, seq, bounces or heads'
for n in 1 2 3 4 5 6 7 8 9 10; do
  sed -E 's/ approved=[a-f0-9]{40}//' "$TMP/brief-gh/issue-$n/body" > "$TMP/migrated-body"
  cmp -s "$TMP/legacy-before-$n" "$TMP/migrated-body" || fail 'migration changed more than approved stamp'
done
if grep -q 'journal=v1' "$TMP/brief-gh"/issue-*/body; then fail 'migration changed legacy eligibility'; fi
# Bookkeeping is exempt from drift; content is not. Refusal precedes GitHub access.
printf '\n' >> "$BRIEF_FIX/docs/plan.md"
: > "$TMP/brief-calls"
brief_run --apply > "$TMP/brief-reject.out" 2>&1 && fail 'dirty doc applied'
[ ! -s "$TMP/brief-calls" ] || fail 'dirty doc reached GitHub'
git -C "$BRIEF_FIX" add docs/plan.md
brief_run --apply > "$TMP/brief-reject.out" 2>&1 && fail 'staged dirty doc applied'
[ ! -s "$TMP/brief-calls" ] || fail 'staged dirty doc reached GitHub'
git -C "$BRIEF_FIX" reset -q HEAD -- docs/plan.md
cp "$TMP/approved-plan.md" "$BRIEF_FIX/docs/untracked.md"
(cd "$BRIEF_FIX" && PATH="$GHFIX:$PATH" FAKE_GH_STATE="$TMP/brief-gh" \
  FAKE_GH_CALLS="$TMP/brief-calls" "$PLAN_DRIVER" --doc docs/untracked.md --apply) \
  > "$TMP/brief-reject.out" 2>&1 && fail 'uncommitted doc applied'
grep -q 'uncommitted' "$TMP/brief-reject.out" || fail 'uncommitted refusal omitted reason'
[ ! -s "$TMP/brief-calls" ] || fail 'uncommitted doc reached GitHub'

git -C "$BRIEF_FIX" checkout -- docs/plan.md
sed 's/^- \[ \] S-1 /- [x] S-1 /' "$BRIEF_FIX/docs/plan.md" > "$TMP/bookkeeping.md"
cp "$TMP/bookkeeping.md" "$BRIEF_FIX/docs/plan.md"
git -C "$BRIEF_FIX" add docs/plan.md
git -C "$BRIEF_FIX" -c commit.gpgsign=false commit -qm 'Update tracker only'
brief_run > /dev/null || fail 'tracker-only change invalidated approval'
sed 's/Parsing is strict/Parsing is very strict/' "$BRIEF_FIX/docs/plan.md" > "$TMP/drift.md"
cp "$TMP/drift.md" "$BRIEF_FIX/docs/plan.md"
git -C "$BRIEF_FIX" add docs/plan.md
git -C "$BRIEF_FIX" -c commit.gpgsign=false commit -qm 'Change approved approach'
DRIFT_SHA=$(git -C "$BRIEF_FIX" rev-parse HEAD)
: > "$TMP/brief-calls"
brief_run --apply > "$TMP/brief-reject.out" 2>&1 && fail 'drifted approval applied'
grep -q "changed at $DRIFT_SHA: re-approve" "$TMP/brief-reject.out" || fail 'drift diagnostic omitted changing commit'
[ ! -s "$TMP/brief-calls" ] || fail 'drifted approval reached GitHub'
git -C "$BRIEF_FIX" checkout HEAD~1 -- docs/plan.md
UNRELATED_REV=$(printf 'Unrelated plan\n' | git -C "$BRIEF_FIX" -c commit.gpgsign=false commit-tree "$(git -C "$BRIEF_FIX" rev-parse 'HEAD^{tree}')")
for approval_case in unapproved missing-rev unknown-rev unrelated-rev; do
  case "$approval_case" in
    unapproved) replacement='pending' ;;
    missing-rev) replacement='status=approved; by=Tester; at=2026-11-12' ;;
    unrelated-rev) replacement="status=approved; by=Tester; at=2026-11-12; rev=$UNRELATED_REV" ;;
    unknown-rev) replacement="status=approved; by=Tester; at=2026-11-12; rev=$(printf '%040d' 9)" ;;
  esac
  sed "s/^- \*\*Approval:\*\*.*/- **Approval:** $replacement/" "$TMP/bookkeeping.md" > "$BRIEF_FIX/docs/plan.md"
  : > "$TMP/brief-calls"
  brief_run --apply > "$TMP/brief-reject.out" 2>&1 && fail "accepted $approval_case"
  [ ! -s "$TMP/brief-calls" ] || fail "$approval_case reached GitHub"
done


# Standard creation and reapply from a linked worktree with a branch-only brief.
STANDARD_REPO="$TMP/standard-brief"
STANDARD_BRIEF="$STANDARD_REPO/.git/agentic-flow/worktrees/standard-doc"
mkdir -p "$STANDARD_REPO"
git -C "$STANDARD_REPO" init -qb main
git -C "$STANDARD_REPO" config user.name Tester
git -C "$STANDARD_REPO" config user.email fixture@example.invalid
git -C "$STANDARD_REPO" -c commit.gpgsign=false commit --allow-empty -qm 'Standard base'
git -C "$STANDARD_REPO" worktree add -qb topic "$STANDARD_BRIEF"
mkdir -p "$STANDARD_BRIEF/docs/inprogress"
cat > "$STANDARD_BRIEF/docs/inprogress/plan.md" <<'MD'
# Feature — Standard fixture
## Tracker
- [ ] alpha
# Part B — Implementation Brief
```agentic-flow-plan
id: standard-doc
profile: standard
branch: topic
steps: alpha
```
## Verification commands
```bash
make test-one F=<group>
# Keep this shell comment in the fence.
printf '%s\n' '---' 'a | b' '`ticks`'
```

---

## alpha — First
**DoD:** Render <placeholder>, pipes | and `code <literal>`.
---
Keep this line after the separator.
**Verify:** `make check`
**Red-first:** none
**Risks:** malformed input
## Status / Implementation status
- **Evidence schema:** v2
- **Tracking issue:** pending
- **Approval:** pending
- **Implementation head:** source=pr-head
- **Implementation PR:** pending
- **Verification evidence:** source=final-approval-run
- **Review verdict:** source=close-out-attestation
- **Memory:** pending
MD
git -C "$STANDARD_BRIEF" add docs/inprogress/plan.md
git -C "$STANDARD_BRIEF" -c commit.gpgsign=false commit -qm 'Standard approved revision'
STANDARD_REV=$(git -C "$STANDARD_BRIEF" rev-parse HEAD)
sed "s/^- \*\*Approval:\*\*.*/- **Approval:** status=approved; by=Tester; at=2026-01-01; rev=$STANDARD_REV/" "$STANDARD_BRIEF/docs/inprogress/plan.md" > "$TMP/std-plan"
cat "$TMP/std-plan" > "$STANDARD_BRIEF/docs/inprogress/plan.md"
git -C "$STANDARD_BRIEF" add docs/inprogress/plan.md
git -C "$STANDARD_BRIEF" -c commit.gpgsign=false commit -qm 'Record Standard approval'
standard_brief_apply() {
  (cd "$STANDARD_BRIEF" && PATH="$GHFIX:$PATH" FAKE_GH_STATE="$TMP/standard-brief-gh" FAKE_GH_CALLS="$TMP/std-calls" \
    "$PLAN_DRIVER" --doc docs/inprogress/plan.md --apply) > "$TMP/std.out" 2>&1
}
standard_brief_apply || fail "Standard document creation failed: $(cat "$TMP/std.out")"
[ "$(find "$TMP/standard-brief-gh" -type d -name 'issue-*' | wc -l | tr -d ' ')" = 1 ] || fail 'Standard document created a tracker'
grep -q "approved=$STANDARD_REV" "$TMP/standard-brief-gh/issue-1/body" || fail 'Standard creation missing revision stamp'
grep -q "journal=v1" "$TMP/standard-brief-gh/issue-1/body" || fail 'Standard creation missing journal stamp'
normalize_issue_body "$TMP/standard-brief-gh/issue-1/body" > "$TMP/standard-rendered"
cat > "$TMP/standard-golden" <<'MD'
## alpha — First

**Profile:** Standard · [Approved brief](https://github.com/owner/repo/blob/<revision>/docs/inprogress/plan.md)

### Definition of done

Render &lt;placeholder&gt;, pipes | and `code <literal>`.
\---
Keep this line after the separator.

### Verify

`make check`

### Verification commands

```bash
make test-one F=<group>
# Keep this shell comment in the fence.
printf '%s\n' '---' 'a | b' '`ticks`'
```

### Risks

- malformed input

<!-- agentic-flow:brief:docs/inprogress/plan.md -->
<!-- agentic-flow:plan:standard-doc step:alpha spec:<hash> journal=v1 approved=<revision> approved-by:Tester approved-at:<time> -->
<!-- agentic-flow:topology:standard -->
MD
diff -u "$TMP/standard-golden" "$TMP/standard-rendered" || fail 'Standard work issue Markdown changed'
git -C "$STANDARD_BRIEF" add docs/inprogress/plan.md
git -C "$STANDARD_BRIEF" -c commit.gpgsign=false commit -qm 'Record Standard work URL'
cp "$TMP/standard-brief-gh/issue-1/body" "$TMP/std-before"
: > "$TMP/std-calls"
standard_brief_apply || fail "Standard document reapply failed: $(cat "$TMP/std.out")"
cmp -s "$TMP/std-before" "$TMP/standard-brief-gh/issue-1/body" || fail 'Standard reapply changed the body or journal eligibility'
if grep -Eq 'issue edit .*--(add|remove)-label' "$TMP/std-calls"; then fail 'Standard reapply changed live labels'; fi
# The Standard migration path changes only approved=, preserving journal=v1.
sed -E 's/ approved=[a-f0-9]{40}//' "$TMP/std-before" > "$TMP/standard-brief-gh/issue-1/body"
: > "$TMP/std-calls"
standard_brief_apply || fail "Standard revision migration failed: $(cat "$TMP/std.out")"
cmp -s "$TMP/std-before" "$TMP/standard-brief-gh/issue-1/body" || fail 'Standard revision migration changed more than its stamp'
if grep -Eq 'issue edit .*--(add|remove)-label' "$TMP/std-calls"; then fail 'Standard revision migration reset live labels'; fi

# Existing issues must be looked up directly, since the stamp search misses them.
(
  cd "$STANDARD_BRIEF"
  export PATH="$GHFIX:$PATH" FAKE_GH_STATE="$TMP/adopt-gh" FAKE_GH_CALLS="$TMP/adopt-calls"
  export FAKE_GH_SEARCH_ONLY=1
  doc=docs/inprogress/plan.md
  git checkout -- "$doc"
  strict_doc=docs/inprogress/strict.md
  awk '
    /^id: / { $0="id: strict-adoption" }
    /^profile: / { print "profile: strict"; $0="tracking: Plan: Strict adoption" }
    /^steps: / { $0="steps: alpha beta" }
    /^## Status / {
      print "## beta — Second"
      print "**DoD:** A fresh step is created."
      print "**Verify:** make check"
      print "**Red-first:** none"
      print "**Risks:** Invalid targets."
    }
    /^- \*\*Approval:\*\*/ { $0="- **Approval:** pending" }
    {print}
  ' "$doc" > "$strict_doc"
  git add -- "$strict_doc"
  git -c commit.gpgsign=false commit -qm 'Record Strict adoption fixture'
  strict_rev=$(git rev-parse HEAD)
  sed "s/^- \*\*Approval:\*\*.*/- **Approval:** status=approved; by=Tester; at=2026-01-01; rev=$strict_rev/" \
    "$strict_doc" > "$TMP/strict-adoption-approved"
  cat "$TMP/strict-adoption-approved" > "$strict_doc"
  git add -- "$strict_doc"
  git -c commit.gpgsign=false commit -qm 'Approve Strict adoption fixture'

  seed_adoption() { # issue-number, state
    local dir="$FAKE_GH_STATE/issue-$1"
    mkdir -p "$dir"
    printf 'Handwritten issue %s\n' "$1" > "$dir/title"
    printf 'Original café for #%s  \n\n\n' "$1" > "$dir/body"
    printf '%s\n' "$2" > "$dir/state"
    printf 'triage\n' > "$dir/labels"
  }
  no_adoption_mutation() {
    if grep -Eq '^(issue (create|edit|close|comment)|label create|api --method POST)( |$)' "$FAKE_GH_CALLS"; then
      fail 'adoption preflight mutated GitHub'
    fi
  }
  adoption_refused() { # document, expected diagnostic, driver args
    local doc_path=$1 expected=$2
    shift 2
    : > "$FAKE_GH_CALLS"
    if "$PLAN_DRIVER" --doc "$doc_path" --apply "$@" > "$TMP/adopt-out" 2>&1; then
      fail "adoption accepted invalid input ($expected)"
    fi
    grep -Fq -- "$expected" "$TMP/adopt-out" || fail "adoption omitted diagnostic ($expected): $(cat "$TMP/adopt-out")"
    no_adoption_mutation
  }
  seed_adoption 41 OPEN
  seed_adoption 42 CLOSED
  seed_adoption 43 OPEN
  seed_adoption 44 OPEN
  seed_adoption 45 OPEN
  seed_adoption 46 OPEN
  seed_adoption 47 OPEN
  printf 'https://github.com/owner/repo/pull/43\n' > "$FAKE_GH_STATE/issue-43/url"
  printf 'https://github.com/other/repo/issues/44\n' > "$FAKE_GH_STATE/issue-44/url"
  printf '<!--\n  agentic-flow:brief:docs/elsewhere.md\n-->\n' >> "$FAKE_GH_STATE/issue-45/body"
  awk 'BEGIN {for (i=0; i<65536; i++) printf "x"}' > "$FAKE_GH_STATE/issue-46/body"
  printf '<!-- agentic-flow:plan:standard-doc step:alpha spec:%s -->\n<!-- agentic-flow:topology:standard -->\n' \
    "$STANDARD_REV" > "$FAKE_GH_STATE/issue-47/body"

  adoption_refused "$doc" 'already stamped on issue #47' --adopt alpha=41
  printf '<!-- agentic-flow:adopted -->\n' > "$TMP/forged-adopted"
  cat "$FAKE_GH_STATE/issue-47/body" >> "$TMP/forged-adopted"
  cat "$TMP/forged-adopted" > "$FAKE_GH_STATE/issue-47/body"
  printf '%s\n' '[]' > "$TMP/empty-search"
  FAKE_GH_LIST_OVERRIDE="$TMP/empty-search" adoption_refused "$doc" \
    'issue #47 already contains an agentic-flow comment' --adopt alpha=47
  rm -r "$FAKE_GH_STATE/issue-47"
  adoption_refused "$doc" 'could not read issue #48' --adopt alpha=48
  adoption_refused "$doc" 'issue #42 is closed' --adopt alpha=42
  adoption_refused "$doc" 'issue #43 is not in owner/repo' --adopt alpha=43
  adoption_refused "$doc" 'issue #44 is not in owner/repo' --adopt alpha=44
  adoption_refused "$doc" 'issue #45 already contains an agentic-flow comment' --adopt alpha=45
  adoption_refused "$doc" '65,536 characters' --adopt alpha=46
  FAKE_GH_VIEW_FAILURE=malformed adoption_refused "$doc" 'malformed response for issue #41' --adopt alpha=41
  AGENTIC_REVIEW_TIMEOUT=1 FAKE_GH_VIEW_FAILURE=timeout adoption_refused "$doc" 'could not read issue #41' --adopt alpha=41
  adoption_refused "$doc" 'unknown step' --adopt missing=41
  adoption_refused "$doc" 'tracker requires a Strict plan' --adopt tracker=41
  adoption_refused "$doc" 'duplicate adoption for alpha' --adopt alpha=41 --adopt alpha=42
  adoption_refused "$doc" 'expected --adopt' --adopt alpha=041
  adoption_refused "$strict_doc" 'duplicate adoption issue #41' --adopt tracker=41 --adopt alpha=41
  adoption_refused "$strict_doc" 'issue #42 is closed' --adopt tracker=41 --adopt alpha=42
  adoption_refused "$strict_doc" '65,536 characters' --adopt tracker=41 --adopt alpha=46
  : > "$FAKE_GH_CALLS"
  if "$PLAN_DRIVER" --adopt alpha=41 --apply "$STANDARD_SPEC" > "$TMP/adopt-out" 2>&1; then
    fail 'legacy spec accepted issue adoption'
  fi
  grep -Fq -- '--adopt requires an approved --doc' "$TMP/adopt-out" || fail 'legacy adoption refusal omitted reason'
  [ ! -s "$FAKE_GH_CALLS" ] || fail 'legacy adoption reached GitHub'

  "$PLAN_DRIVER" --doc "$doc" --adopt alpha=41 > "$TMP/adopt-out" || fail 'adoption dry run failed'
  grep -Fq 'Adopt alpha: #41' "$TMP/adopt-out" || fail 'adoption dry run omitted mapping'
  [ ! -s "$FAKE_GH_CALLS" ] || fail 'offline adoption dry run reached GitHub'
  "$PLAN_DRIVER" --doc "$doc" --adopt alpha=41 --diff > "$TMP/adopt-out" || fail 'adoption diff failed'
  grep -Fq 'Adopt alpha: #41' "$TMP/adopt-out" || fail 'adoption diff omitted mapping'
  grep -Eq '^issue view 41 .*--repo owner/repo' "$FAKE_GH_CALLS" || fail 'adoption skipped direct issue lookup'
  no_adoption_mutation

  cp "$FAKE_GH_STATE/issue-41/body" "$TMP/adoption-prefix"
  "$PLAN_DRIVER" --doc "$doc" --adopt alpha=41 --apply > "$TMP/adopt-out" || fail 'Standard adoption failed'
  [ "$(cat "$FAKE_GH_STATE/issue-41/title")" = 'Handwritten issue 41' ] || fail 'Standard adoption changed the title'
  [ "$(cat "$FAKE_GH_STATE/issue-41/labels")" = "$(printf '%s\n' agent:codex needs-execution triage)" ] \
    || fail 'Standard adoption did not add creation labels alongside existing labels'
  prefix_size=$(wc -c < "$TMP/adoption-prefix" | tr -d ' ')
  head -c "$prefix_size" "$FAKE_GH_STATE/issue-41/body" > "$TMP/adoption-prefix-after"
  cmp -s "$TMP/adoption-prefix" "$TMP/adoption-prefix-after" || fail 'Standard adoption changed the original body bytes'
  grep -Fxq '<!-- agentic-flow:adopted -->' "$FAKE_GH_STATE/issue-41/body" || fail 'Standard adoption omitted marker'
  grep -Fq "step:alpha spec:" "$FAKE_GH_STATE/issue-41/body" || fail 'Standard adoption omitted identity stamp'
  grep -Fq "journal=v1 approved=$STANDARD_REV approved-by:Tester" "$FAKE_GH_STATE/issue-41/body" \
    || fail 'Standard adoption omitted journal or approval metadata'
  grep -Fq 'https://github.com/owner/repo/issues/41' "$doc" || fail 'Standard adoption omitted the work URL from the doc'
  if grep -q '^issue create ' "$FAKE_GH_CALLS"; then fail 'Standard adoption created a duplicate issue'; fi
  git add -- "$doc"
  git -c commit.gpgsign=false commit -qm 'Record adopted work URL'

  # Keep edits above the boundary byte for byte, even when they resemble metadata.
  {
    printf '%s\n' 'Edited by a human approved-by:Somebody approved-at:wrong -->' \
      '<!-- agentic-flow:topology:strict -->' "<!-- agentic-flow:plan:standard-doc tracker spec:$STANDARD_REV -->"
    cat "$FAKE_GH_STATE/issue-41/body"
  } > "$TMP/adopt-edited"
  cat "$TMP/adopt-edited" > "$FAKE_GH_STATE/issue-41/body"
  printf '%s\n' agent:opencode needs-review triage > "$FAKE_GH_STATE/issue-41/labels"
  : > "$FAKE_GH_CALLS"
  "$PLAN_DRIVER" --doc "$doc" --apply > "$TMP/adopt-out" || fail 'Standard adopted reapply failed'
  cmp -s "$TMP/adopt-edited" "$FAKE_GH_STATE/issue-41/body" || fail 'Standard reapply changed preserved issue text'
  if grep -Eq 'issue edit 41 .*--(title|add-label)' "$FAKE_GH_CALLS"; then fail 'Standard reapply reset adopted metadata'; fi
  sed -E "s/ approved=$STANDARD_REV//" "$TMP/adopt-edited" > "$FAKE_GH_STATE/issue-41/body"
  "$PLAN_DRIVER" --doc "$doc" --apply > "$TMP/adopt-out" || fail 'adopted approval migration failed'
  cmp -s "$TMP/adopt-edited" "$FAKE_GH_STATE/issue-41/body" || fail 'adopted approval migration changed more than its stamp'
  sed 's/\*\*Risks:\*\* malformed input/**Risks:** updated risks/' "$doc" > "$TMP/adopt-revised"
  cat "$TMP/adopt-revised" > "$doc"
  git add -- "$doc"
  git -c commit.gpgsign=false commit -qm 'Revise the adopted plan'
  revised=$(git rev-parse HEAD)
  sed "s/rev=$STANDARD_REV/rev=$revised/" "$TMP/adopt-revised" > "$doc"
  git add -- "$doc"
  git -c commit.gpgsign=false commit -qm 'Approve the revised plan'
  "$PLAN_DRIVER" --doc "$doc" --apply > "$TMP/adopt-out" || fail 'revised adopted plan did not apply'
  grep -Fxq -- '- updated risks' "$FAKE_GH_STATE/issue-41/body" || fail 'revised adopted plan did not update its packet'
  for file in "$TMP/adopt-edited" "$FAKE_GH_STATE/issue-41/body"; do
    sed '/^<!-- agentic-flow:adopted -->$/q' "$file" > "$TMP/prefix-${file##*/}"
  done
  cmp -s "$TMP/prefix-adopt-edited" "$TMP/prefix-body" || fail 'revised adopted plan changed the preserved prefix'

  # A partial Strict apply leaves an adopted tracker and step. Retry the same
  # mapping, create only the unmapped step and complete the tracker's checklist.
  export FAKE_GH_STATE="$TMP/adopt-strict-gh"
  seed_adoption 51 OPEN
  seed_adoption 52 OPEN
  : > "$FAKE_GH_CALLS"
  if FAKE_GH_FAIL_CREATE_NUMBER=1 "$PLAN_DRIVER" --doc "$strict_doc" --adopt tracker=51 --adopt alpha=52 --apply > "$TMP/adopt-out" 2>&1; then
    fail 'Strict adoption fixture did not stop at the injected failure'
  fi
  grep -Fq 'injected create failure' "$TMP/adopt-out" || fail 'Strict adoption did not reach the unmapped step'
  : > "$FAKE_GH_CALLS"
  "$PLAN_DRIVER" --doc "$strict_doc" --adopt tracker=51 --adopt alpha=52 --apply > "$TMP/adopt-out" || fail 'Strict adoption retry failed'
  [ "$(grep -c '^issue create ' "$FAKE_GH_CALLS")" = 1 ] || fail 'Strict adoption did not create exactly the unmapped step'
  for number in 51 52; do
    [ "$(cat "$FAKE_GH_STATE/issue-$number/title")" = "Handwritten issue $number" ] || fail 'Strict adoption changed a title'
    grep -Fq "Original café for #$number" "$FAKE_GH_STATE/issue-$number/body" || fail 'Strict adoption lost original prose'
  done
  if grep -q -- '--add-label' "$FAKE_GH_CALLS"; then fail 'Strict retry reset live labels'; fi
  grep -Fxq plan "$FAKE_GH_STATE/issue-51/labels" || fail 'adopted tracker lacks the plan label'
  grep -Fxq needs-execution "$FAKE_GH_STATE/issue-52/labels" || fail 'adopted Strict step lacks its creation labels'
  grep -Fq -- '- [ ] #52 [alpha]' "$FAKE_GH_STATE/issue-51/body" || fail 'adopted tracker lost its adopted step link'
  grep -Fq -- '- [ ] #1 [beta]' "$FAKE_GH_STATE/issue-51/body" || fail 'adopted tracker lost its created step link'
  grep -Fq 'https://github.com/owner/repo/issues/51' "$strict_doc" || fail 'Strict adoption omitted tracker URL from the doc'
  git add -- "$strict_doc"
  git -c commit.gpgsign=false commit -qm 'Record adopted tracker URL'
  for number in 51 52; do
    { printf 'Later edit to #%s\n' "$number"; cat "$FAKE_GH_STATE/issue-$number/body"; } > "$TMP/adopt-later-$number"
    cat "$TMP/adopt-later-$number" > "$FAKE_GH_STATE/issue-$number/body"
  done
  "$PLAN_DRIVER" --doc "$strict_doc" --apply > "$TMP/adopt-out" || fail 'Strict adopted reapply failed'
  for number in 51 52; do
    cmp -s "$TMP/adopt-later-$number" "$FAKE_GH_STATE/issue-$number/body" || fail 'Strict reapply changed preserved issue text'
  done
)
