#!/usr/bin/env bash
# Sourced by self-test.sh; shared fixture context is intentional.
# shellcheck disable=SC1091,SC2034,SC2153,SC2164,SC2329 # Dispatcher globals (including ROOT), indirect fixture calls, inherited errexit.
# Run the real shipping orchestrator; all remote and Git writes are doubles.
# shellcheck disable=SC2030 # Fixture globals intentionally remain inside this subshell.
ship_gate_tests() (
  # shellcheck disable=SC1091
  . "$ROOT/scripts/lib/ship.sh"
  local fixture="$TMP/ship-gate-lifecycle" rc=0 phase
  local HANDOFF_TMP HANDOFF_REPO SHIP_ROOT SHIP_BRANCH SHIP_BASE SHIP_HEAD SHIP_TITLE SHIP_PLAN SHIP_PR SHIP_DOC CLOSE_TARGET
  mkdir -p "$fixture/docs/done"
  cd "$fixture" || exit 1
  HANDOFF_TMP=$fixture SHIP_ROOT=$fixture SHIP_BRANCH=feature SHIP_BASE=main
  SHIP_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  HANDOFF_REPO=owner/repo SHIP_TITLE=Fixture SHIP_PLAN=fixture
  SHIP_PR='{"number":3,"url":"https://github.com/owner/repo/pull/3"}'
  export SHIP_GATE_ACTIONS="$fixture/actions"
  git() {
    case "$1" in
      status|for-each-ref) return 0 ;;
      push) printf 'push\n' >> "$SHIP_GATE_ACTIONS" ;;
      *) return 99 ;;
    esac
  }
  brief_approval() { printf '%s\towner\n' "$SHIP_HEAD"; }
  brief_approved_at_head() { return 0; }
  close_out_load() { CLOSE_TARGET=1; }
  close_out_cmd() { printf '%s\n' "$1" >> "$SHIP_GATE_ACTIONS"; }
  handoff_gh() { printf 'pr-create\n' >> "$SHIP_GATE_ACTIONS"; }
  ship_pr() { SHIP_PR='{"number":3,"url":"https://github.com/owner/repo/pull/3"}'; }
  ship_wait_visibility() { return 0; }
  ship_wait_ci() { return 0; }
  ship_lifecycle() { printf 'READY fixture\n'; }
  # A gate failure must stop each push path, including the initial PR-creation push.
  for phase in initial final; do
    SHIP_DOC=docs/done/plan.md
    [ "$phase" != initial ] || { SHIP_PR=null; SHIP_DOC=docs/inprogress/plan.md; }
    cat > Makefile <<'MAKE'
.PHONY: ship-gate
ship-gate:
	@echo 'gate' >> "$$SHIP_GATE_ACTIONS"
	@echo 'self-test failed: group: hooks' >&2
	@exit 1
MAKE
    : > "$SHIP_GATE_ACTIONS"; rc=0
    ship_run false > "$fixture/out" 2>&1 || rc=$?
    [ "$rc" = 1 ] || fail "ship accepted a failing $phase gate"
    [ "$(cat "$SHIP_GATE_ACTIONS")" = gate ] || fail "ship pushed after a failing $phase gate"
    grep -q 'group: hooks' "$fixture/out" || fail 'ship swallowed failing group diagnostics'
    # A missing prerequisite is a broken gate, even when its name shares the prefix.
    printf 'ship-gate: ship-gate-dependency\n' > Makefile
    : > "$SHIP_GATE_ACTIONS"; rc=0
    ship_run false > "$fixture/out" 2>&1 || rc=$?
    [ "$rc" = 1 ] && [ ! -s "$SHIP_GATE_ACTIONS" ] \
      || fail 'ship treated a broken gate dependency as an absent optional target'
    # No target is a supported adopter configuration, with a visible notice.
    printf 'test:\n\t@:\n' > Makefile
    : > "$SHIP_GATE_ACTIONS"
    ship_run false > "$fixture/out" 2>&1 || fail "ship refused a missing $phase gate"
    grep -q '^push$' "$SHIP_GATE_ACTIONS" || fail 'ship did not continue without a gate'
    grep -q 'ship-gate.*not defined' "$fixture/out" || fail 'ship omitted the missing-target notice'
    # On success the gate precedes every push, and final close-out is already committed.
    [ "$phase" != initial ] || SHIP_PR=null
    cat > Makefile <<'MAKE'
.PHONY: ship-gate
ship-gate:
	@echo "gate" >> "$$SHIP_GATE_ACTIONS"
MAKE
    : > "$SHIP_GATE_ACTIONS"
    ship_run false > "$fixture/out" 2>&1 || fail "ship refused a passing $phase gate"
    [ "$(head -2 "$SHIP_GATE_ACTIONS" | tr '\n' /)" = "gate/push/" ] \
      || fail "ship did not gate the $phase head before push"
  done
)
ship_gate_tests

V2FIX="$TMP/lifecycle-v2"
mkdir -p "$V2FIX/docs/inprogress"
cat > "$V2FIX/docs/inprogress/feature-v2.md" <<'MD'
## Tracker
- [x] F-1 done
## Status / Implementation status
- **Evidence schema:** v2
- **Tracking issue:** url=https://github.com/owner/repo/issues/1
- **Approval:** status=not approved; by=Tester; at=2026-01-01
- **Implementation head:** source=pr-head
- **Implementation PR:** url=https://github.com/owner/repo/pull/2
- **Verification evidence:** source=final-approval-run
- **Review verdict:** source=pr-head-approval
- **Memory:** status=n/a
MD
AGENTIC_PROJECT_ROOT="$V2FIX" "$ROOT/scripts/lifecycle-status.sh" --doc "$V2FIX/docs/inprogress/feature-v2.md" --check \
  > "$TMP/lifecycle-v2-red.out" 2>&1 \
  && fail "v2 lifecycle accepted a negated approval"
grep -q 'BLOCKED.*approval' "$TMP/lifecycle-v2-red.out" \
  || fail "v2 lifecycle did not classify a negated approval as BLOCKED"

# The new evidence source must be admitted by the shared Status writer parser.
sed 's/status=not approved/status=approved/; s/source=pr-head-approval/source=close-out-attestation/' \
  "$V2FIX/docs/inprogress/feature-v2.md" > "$TMP/attestation-status.md"
AGENTIC_PROJECT_ROOT="$V2FIX" "$ROOT/scripts/lifecycle-status.sh" --doc "$TMP/attestation-status.md" --validate-doc-status \
  > "$TMP/attestation-status.out" 2>&1 || fail 'Status parser rejected close-out attestation'

# Open work has precedence over any evidence schema, including legacy work.
cat > "$V2FIX/docs/inprogress/feature-active.md" <<'MD'
## Tracker
- [x] F-1 done
- [ ] F-2 open
## Status
- **Approval:** not approved
MD
AGENTIC_PROJECT_ROOT="$V2FIX" "$ROOT/scripts/lifecycle-status.sh" --doc \
  "$V2FIX/docs/inprogress/feature-active.md" --check --verify-evidence \
  > "$TMP/lifecycle-active.out" \
  || fail "open legacy document failed strict verification"
grep -q '^ACTIVE.*feature-active.md' "$TMP/lifecycle-active.out" \
  || fail "open legacy document was not ACTIVE"

sed 's/status=not approved/status=approved/' "$V2FIX/docs/inprogress/feature-v2.md" \
  > "$TMP/valid-v2.md"
cp "$TMP/valid-v2.md" "$V2FIX/docs/inprogress/feature-v2.md"
AGENTIC_PROJECT_ROOT="$V2FIX" "$ROOT/scripts/lifecycle-status.sh" --doc \
  "$V2FIX/docs/inprogress/feature-v2.md" --check > "$TMP/lifecycle-valid.out" \
  || fail "valid local v2 Status failed report validation"
grep -q '^READY.*feature-v2.md' "$TMP/lifecycle-valid.out" \
  || fail "valid local v2 Status was not READY in offline report"

v2_case() { # <sed expression> <expected state> <diagnostic>
  sed "$1" "$TMP/valid-v2.md" > "$V2FIX/docs/inprogress/feature-v2.md"
  if AGENTIC_PROJECT_ROOT="$V2FIX" "$ROOT/scripts/lifecycle-status.sh" --doc \
      "$V2FIX/docs/inprogress/feature-v2.md" --check --verify-evidence \
      > "$TMP/lifecycle-case.out" 2>&1; then
    fail "strict verified lifecycle accepted $3"
  fi
  grep -q "^$2.*$3" "$TMP/lifecycle-case.out" \
    || fail "lifecycle did not classify $3 as $2"
}
v2_case 's/status=approved/status=not approved/' BLOCKED approval
v2_case 's/source=pr-head/source=not-pr-head/' BLOCKED implementation-head
v2_case '/^- \*\*Approval:/d' UNVERIFIED approval
v2_case 's/Evidence schema:\*\* v2/Evidence schema:** v3/' BLOCKED 'Evidence schema'
v2_case 's/Review verdict:/Unknown key:/' BLOCKED 'unknown field'
sed '/^- \*\*Approval:/a\
  not approved' "$TMP/valid-v2.md" > "$V2FIX/docs/inprogress/feature-v2.md"
AGENTIC_PROJECT_ROOT="$V2FIX" "$ROOT/scripts/lifecycle-status.sh" --doc \
  "$V2FIX/docs/inprogress/feature-v2.md" --check > "$TMP/lifecycle-wrapped.out" 2>&1 \
  && fail "v2 lifecycle accepted continuation prose after approval"
grep -q 'BLOCKED.*malformed continuation of Approval' "$TMP/lifecycle-wrapped.out" \
  || fail "v2 lifecycle did not name the malformed Approval continuation"
cat "$TMP/valid-v2.md" > "$V2FIX/docs/inprogress/feature-v2.md"
printf '%s\n' '- **Approval:** status=approved; by=Other; at=2026-01-01' \
  >> "$V2FIX/docs/inprogress/feature-v2.md"
AGENTIC_PROJECT_ROOT="$V2FIX" "$ROOT/scripts/lifecycle-status.sh" --doc \
  "$V2FIX/docs/inprogress/feature-v2.md" --check > "$TMP/lifecycle-duplicate.out" 2>&1 \
  && fail "duplicate v2 field passed"
grep -q 'BLOCKED.*duplicate field Approval' "$TMP/lifecycle-duplicate.out" \
  || fail "duplicate v2 field did not report its name"
cp "$TMP/valid-v2.md" "$V2FIX/docs/inprogress/feature-v2.md"
AGENTIC_PROJECT_ROOT="$V2FIX" "$ROOT/scripts/lifecycle-status.sh" --doc \
  "$V2FIX/docs/inprogress/feature-v2.md" --check --verify-evidence \
  > "$TMP/lifecycle-unresolved.out" 2>&1 \
  && fail "strict verification accepted unresolved v2 evidence"
grep -q '^UNVERIFIED.*feature-v2.md' "$TMP/lifecycle-unresolved.out" \
  || fail "unresolved v2 evidence was not UNVERIFIED"

# A fully checked schema-less document is a migration report, never evidence-ready.
cat > "$V2FIX/docs/inprogress/feature-legacy.md" <<'MD'
## Tracker
- [x] F-1 done
## Status
- **Approval:** approved by Tester
MD
AGENTIC_PROJECT_ROOT="$V2FIX" "$ROOT/scripts/lifecycle-status.sh" --doc \
  "$V2FIX/docs/inprogress/feature-legacy.md" --check --verify-evidence \
  > "$TMP/lifecycle-legacy.out" 2>&1 \
  && fail "strict verification accepted fully checked legacy document"
grep -q '^LEGACY.*feature-legacy.md' "$TMP/lifecycle-legacy.out" \
  || fail "fully checked schema-less document was not LEGACY"

# Phase mismatch is a resolved contradiction, even while later CI/review evidence
# remains unavailable until F-2/F-3.
GH_PHASE="$TMP/gh-phase"
mkdir -p "$GH_PHASE"
cat > "$GH_PHASE/gh" <<'FAKE_GH'
#!/usr/bin/env bash
case "$*" in
  *'issue view'*)
    labels='[{"name":"agent:claude"},{"name":"needs-closing"}]'
    [ -z "${FAKE_ISSUE_LABELS:-}" ] || labels=$FAKE_ISSUE_LABELS
    printf '{"state":"%s","labels":%s}\n' "${FAKE_ISSUE_STATE:-OPEN}" "$labels" ;;
  *) exit 2 ;;
esac
FAKE_GH
chmod +x "$GH_PHASE/gh"
PATH="$GH_PHASE:$PATH" FAKE_ISSUE_STATE=OPEN AGENTIC_PROJECT_ROOT="$V2FIX" \
  "$ROOT/scripts/lifecycle-status.sh" --doc "$V2FIX/docs/inprogress/feature-v2.md" \
  --phase pre-merge --check --verify-evidence > "$TMP/lifecycle-wrong-pre.out" 2>&1 \
  && fail "pre-merge accepted an open issue"
grep -q 'BLOCKED.*phase pre-merge found OPEN' "$TMP/lifecycle-wrong-pre.out" \
  || fail "pre-merge mismatch did not name the phase and state"
PATH="$GH_PHASE:$PATH" FAKE_ISSUE_STATE=CLOSED AGENTIC_PROJECT_ROOT="$V2FIX" \
  "$ROOT/scripts/lifecycle-status.sh" --doc "$V2FIX/docs/inprogress/feature-v2.md" \
  --phase close-out --check --verify-evidence > "$TMP/lifecycle-wrong-close.out" 2>&1 \
  && fail "close-out accepted a closed issue"
grep -q 'BLOCKED.*phase close-out found CLOSED' "$TMP/lifecycle-wrong-close.out" \
  || fail "close-out mismatch did not name the phase and state"
for missing_label in needs-closing agent:claude; do
  case "$missing_label" in
    needs-closing) labels='[{"name":"agent:claude"}]' ;;
    agent:claude) labels='[{"name":"needs-closing"}]' ;;
  esac
  PATH="$GH_PHASE:$PATH" FAKE_ISSUE_STATE=OPEN FAKE_ISSUE_LABELS="$labels" \
    AGENTIC_PROJECT_ROOT="$V2FIX" "$ROOT/scripts/lifecycle-status.sh" \
    --doc "$V2FIX/docs/inprogress/feature-v2.md" --phase close-out \
    --check --verify-evidence > "$TMP/lifecycle-missing-label.out" 2>&1 \
    && fail "close-out accepted an open issue without $missing_label"
  grep -q "BLOCKED.*phase close-out found OPEN without $missing_label" \
    "$TMP/lifecycle-missing-label.out" \
    || fail "close-out did not name missing $missing_label label"
done
for phase_state in 'close-out OPEN' 'pre-merge CLOSED'; do
  read -r phase_name state_name <<< "$phase_state"
  PATH="$GH_PHASE:$PATH" FAKE_ISSUE_STATE="$state_name" AGENTIC_PROJECT_ROOT="$V2FIX" \
    "$ROOT/scripts/lifecycle-status.sh" --doc "$V2FIX/docs/inprogress/feature-v2.md" \
    --phase "$phase_name" --check --verify-evidence > "$TMP/lifecycle-phase.out" 2>&1 \
    && fail "$phase_name accepted unresolved review and CI"
  grep -q '^UNVERIFIED.*review policy missing or invalid' "$TMP/lifecycle-phase.out" \
    || fail "$phase_name did not reach the shared external evidence check"
done

# F-2 reads policy from the adopted project, the PR head from GitHub, and one
# complete comment page from the tracking issue. Each selected run gets exactly
# one Actions lookup, including attempt mismatch and failure cases.
printf '%s\n' 'version=1' 'workflow=.github/workflows/ci.yml' \
  'identity-mode=single-operator' \
  'reviewer=reviewer' 'executor=executor' 'approver=approver' \
  'accepted-risk=docs/accepted_risks.md#single-operator-review' \
  > "$V2FIX/.agentic-flow-review-policy"
mkdir -p "$V2FIX/docs"
printf '%s\n' '<a id="single-operator-review"></a>' > "$V2FIX/docs/accepted_risks.md"
git -C "$V2FIX" init -q
git -C "$V2FIX" remote add origin git@github.com:owner/repo.git
git -C "$V2FIX" -c commit.gpgsign=false -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m base
STEP_HEAD=$(git -C "$V2FIX" rev-parse HEAD)
git -C "$V2FIX" -c commit.gpgsign=false -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m head
LIFE_HEAD=$(git -C "$V2FIX" rev-parse HEAD)
LIFE_RUN_URL=https://github.com/owner/repo/actions/runs/100
LIFE_MARKER="agentic-flow-review: status=approved; pr=2; head=$LIFE_HEAD; run=$LIFE_RUN_URL; attempt=1; role=reviewer"
LIFE_API="$TMP/lifecycle-api"
mkdir -p "$LIFE_API"
cat > "$LIFE_API/gh" <<'FAKE_GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LIFE_CALLS"
case "$*" in
  *'issue view'*)
    if [ -n "${LIFE_ISSUE_BODY_FILE:-}" ]; then
      jq -n --arg state "${LIFE_ISSUE_STATE:-OPEN}" --rawfile body "$LIFE_ISSUE_BODY_FILE" \
        '{state:$state,labels:[{name:"agent:claude"},{name:"needs-closing"}],body:$body}'
    else
      printf '{"state":"%s","labels":[{"name":"agent:claude"},{"name":"needs-closing"}],"body":"<!-- agentic-flow:plan:fixture tracker spec:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->"}\n' "${LIFE_ISSUE_STATE:-OPEN}"
    fi ;;
  *'issue list'*) printf '[{"number":3,"state":"%s","body":"<!-- agentic-flow:plan:fixture step:f-1 spec:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->"}]\n' "${LIFE_STEP_STATE:-CLOSED}" ;;
  *'api repos/owner/repo/pulls/2'*) cat "$LIFE_PR_JSON" ;;
  *'api graphql '*'number=1'*) cat "$LIFE_COMMENTS_JSON" ;;
  *'api graphql '*'number=2'*) cat "$LIFE_PR_COMMENTS_JSON" ;;
  *'api graphql '*'number=3'*) cat "$LIFE_STEP_COMMENTS_JSON" ;;
  *'api repos/owner/repo/actions/runs/100'*)
    [ "${LIFE_RUN_FAIL:-false}" = false ] || exit 1
    cat "$LIFE_RUN_JSON" ;;
  *) exit 2 ;;
esac
FAKE_GH
chmod +x "$LIFE_API/gh"
printf '{"head":{"sha":"%s"}}\n' "$LIFE_HEAD" > "$TMP/lifecycle-pr.json"
printf '{"repository":{"full_name":"owner/repo"},"path":".github/workflows/ci.yml","head_sha":"%s","conclusion":"success","run_attempt":1}\n' \
  "$LIFE_HEAD" > "$TMP/lifecycle-run.json"
jq -n --arg body "$LIFE_MARKER" '{data:{repository:{issue:{comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:"opaque-1",fullDatabaseId:"10",body:$body,author:{login:"reviewer"},lastEditedAt:null}]}}}}}' \
  > "$TMP/lifecycle-comments.json"
jq -n --arg head "$LIFE_HEAD" \
  '{data:{repository:{issue:{comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:"handoff",fullDatabaseId:"10",body:("Implemented in " + $head + " — implementation"),author:{login:"executor"},lastEditedAt:null},{id:"step-review",fullDatabaseId:"11",body:("agentic-flow-review: status=approved; step=f-1; head=" + $head + "; role=reviewer"),author:{login:"reviewer"},lastEditedAt:null}]}}}}}' \
  > "$TMP/lifecycle-step-comments.json"
LIFE_PR_JSON="$TMP/lifecycle-pr.json"
LIFE_RUN_JSON="$TMP/lifecycle-run.json"
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"
LIFE_PR_COMMENTS_JSON="$TMP/lifecycle-comments.json"
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"
LIFE_CALLS="$TMP/lifecycle-calls"
export LIFE_PR_JSON LIFE_RUN_JSON LIFE_COMMENTS_JSON LIFE_PR_COMMENTS_JSON \
  LIFE_STEP_COMMENTS_JSON LIFE_CALLS
bound_case() { # <name> <expected state> <diagnostic> <expected run calls>
  : > "$LIFE_CALLS"
  PATH="$LIFE_API:$PATH" AGENTIC_PROJECT_ROOT="$V2FIX" LIFE_RUN_FAIL="${LIFE_RUN_FAIL:-false}" \
    "$ROOT/scripts/lifecycle-status.sh" --doc "$V2FIX/docs/inprogress/feature-v2.md" \
    --check --verify-evidence > "$TMP/lifecycle-bound.out" 2>&1 \
    && [ "$2" != READY ] && fail "strict verified lifecycle accepted $1"
  grep -q "^$2.*$3" "$TMP/lifecycle-bound.out" \
    || fail "$1 was not $2 with $3: $(cat "$TMP/lifecycle-bound.out")"
  [ "$(grep -c 'api repos/owner/repo/actions/runs/100' "$LIFE_CALLS" || true)" -eq "$4" ] \
    || fail "$1 made the wrong number of Actions lookups"
  [ "$(grep -c 'api graphql .*number=1' "$LIFE_CALLS" || true)" -eq 1 ] \
    || fail "$1 did not make exactly one tracking-thread query"
  if [ "$2" = READY ]; then
    [ "$(grep -c 'api graphql ' "$LIFE_CALLS" || true)" -eq 2 ] \
      || fail "$1 did not query exactly one Strict step thread"
  else
    [ "$(grep -c 'api graphql ' "$LIFE_CALLS" || true)" -eq 1 ] \
      || fail "$1 queried another review thread before selecting evidence"
  fi
}
bound_case 'authenticated correct binding' READY 'review by reviewer' 1
grep -q "$LIFE_HEAD.*comment opaque-1" "$TMP/lifecycle-bound.out" \
  || fail 'bound CI output omitted the resolved head or selected comment'
grep -q 'attempt 1 succeeded' "$TMP/lifecycle-bound.out" || fail 'run attempt not printed'

# Standard uses one open work issue for both the step and final review. The
# same complete comment page must support close-out and the post-close recheck.
STANDARD_LIFE_DOC="$V2FIX/docs/inprogress/feature-standard.md"
cp "$TMP/valid-v2.md" "$STANDARD_LIFE_DOC"
printf '%s\n' \
  '<!-- agentic-flow:plan:standard-plan step:alpha spec:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa approved-by:Tester approved-at:2026-01-01T00:00:00Z -->' \
  '<!-- agentic-flow:topology:standard -->' > "$TMP/standard-life-body"
jq -n --arg head "$LIFE_HEAD" --arg step "$STEP_HEAD" --arg run "$LIFE_RUN_URL" \
  '{data:{repository:{issue:{comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[
    {id:"handoff",fullDatabaseId:"9",body:("Implemented in " + $step + " — implementation"),author:{login:"executor"},lastEditedAt:null},
    {id:"step-review",fullDatabaseId:"10",body:("agentic-flow-review: status=approved; step=alpha; head=" + $step + "; role=reviewer"),author:{login:"reviewer"},lastEditedAt:null},
    {id:"final-review",fullDatabaseId:"11",body:("agentic-flow-review: status=approved; pr=2; head=" + $head + "; run=" + $run + "; attempt=1; role=reviewer"),author:{login:"reviewer"},lastEditedAt:null}
  ]}}}}}' > "$TMP/standard-life-comments.json"
LIFE_ISSUE_BODY_FILE="$TMP/standard-life-body"
LIFE_COMMENTS_JSON="$TMP/standard-life-comments.json"
export LIFE_ISSUE_BODY_FILE LIFE_COMMENTS_JSON
for phase_state in 'close-out OPEN' 'pre-merge CLOSED'; do
  read -r phase_name state_name <<< "$phase_state"
  : > "$LIFE_CALLS"
  PATH="$LIFE_API:$PATH" AGENTIC_PROJECT_ROOT="$V2FIX" LIFE_ISSUE_STATE="$state_name" \
    "$ROOT/scripts/lifecycle-status.sh" --doc "$STANDARD_LIFE_DOC" \
    --phase "$phase_name" --check --verify-evidence > "$TMP/standard-life.out" 2>&1 \
    || fail "Standard $phase_name failed: $(cat "$TMP/standard-life.out")"
  grep -q '^READY' "$TMP/standard-life.out" || fail "Standard $phase_name was not READY"
  [ "$(grep -c 'api graphql ' "$LIFE_CALLS" || true)" -eq 1 ] \
    || fail 'Standard queried more than its one review thread'
done
# Standard's reused tracking page must also reject an approved alternate commit.
STANDARD_ALT=$(printf '%s\n' standard-alternate | git -C "$V2FIX" -c commit.gpgsign=false -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree "${LIFE_HEAD}^{tree}" -p "$STEP_HEAD")
jq --arg old "$STEP_HEAD" --arg new "$STANDARD_ALT" '.data.repository.issue.comments.nodes |= map(.body |= gsub($old; $new))' \
  "$TMP/standard-life-comments.json" > "$TMP/standard-life-alternate.json"
PATH="$LIFE_API:$PATH" AGENTIC_PROJECT_ROOT="$V2FIX" LIFE_COMMENTS_JSON="$TMP/standard-life-alternate.json" \
  "$ROOT/scripts/lifecycle-status.sh" --doc "$STANDARD_LIFE_DOC" --check --verify-evidence \
  > "$TMP/standard-life-alternate.out" 2>&1 && fail 'Standard accepted an approved alternate commit'
grep -q "^BLOCKED.*$STANDARD_ALT.*$LIFE_HEAD" "$TMP/standard-life-alternate.out" \
  || fail 'Standard ancestry rejection lacked both SHAs'
sed 's/approved-by:Tester/approved-by:Other/' "$TMP/standard-life-body" \
  > "$TMP/standard-life-bad-body"
LIFE_ISSUE_BODY_FILE="$TMP/standard-life-bad-body" \
  PATH="$LIFE_API:$PATH" AGENTIC_PROJECT_ROOT="$V2FIX" \
  "$ROOT/scripts/lifecycle-status.sh" --doc "$STANDARD_LIFE_DOC" \
  --check --verify-evidence > "$TMP/standard-life-bad.out" 2>&1 \
  && fail 'Standard accepted mismatched approval metadata'
grep -q 'BLOCKED.*approval stamp differs' "$TMP/standard-life-bad.out" \
  || fail 'Standard approval mismatch lacked diagnostic'
LIFE_ISSUE_BODY_FILE="$TMP/standard-life-body"
jq '.data.repository.issue.comments.nodes |= map(select(.id != "step-review"))' \
  "$TMP/standard-life-comments.json" > "$TMP/standard-life-no-step.json"
LIFE_COMMENTS_JSON="$TMP/standard-life-no-step.json"
export LIFE_COMMENTS_JSON
PATH="$LIFE_API:$PATH" AGENTIC_PROJECT_ROOT="$V2FIX" \
  "$ROOT/scripts/lifecycle-status.sh" --doc "$STANDARD_LIFE_DOC" \
  --check --verify-evidence > "$TMP/standard-life-no-step.out" 2>&1 \
  && fail 'Standard accepted missing step review'
grep -q 'UNVERIFIED.*no review' "$TMP/standard-life-no-step.out" \
  || fail 'Standard missing review lacked diagnostic'
jq '.data.repository.issue.comments.nodes[-1].body |= sub("head=[a-f0-9]{40}";"head=cccccccccccccccccccccccccccccccccccccccc")' \
  "$TMP/standard-life-comments.json" > "$TMP/standard-life-stale.json"
LIFE_COMMENTS_JSON="$TMP/standard-life-stale.json"
export LIFE_COMMENTS_JSON
PATH="$LIFE_API:$PATH" AGENTIC_PROJECT_ROOT="$V2FIX" \
  "$ROOT/scripts/lifecycle-status.sh" --doc "$STANDARD_LIFE_DOC" \
  --check --verify-evidence > "$TMP/standard-life-stale.out" 2>&1 \
  && fail 'Standard accepted stale final-head approval'
grep -q 'UNVERIFIED.*no approval for PR head' "$TMP/standard-life-stale.out" \
  || fail 'Standard stale final-head evidence lacked diagnostic'
LIFE_COMMENTS_JSON="$TMP/standard-life-comments.json"
unset LIFE_ISSUE_BODY_FILE
export LIFE_COMMENTS_JSON

jq '.path = ".github/workflows/ci.yml@main"' "$TMP/lifecycle-run.json" > "$TMP/lifecycle-run-ref.json"
LIFE_RUN_JSON="$TMP/lifecycle-run-ref.json"; export LIFE_RUN_JSON
bound_case 'workflow path with GitHub ref suffix' READY 'review by reviewer' 1
LIFE_RUN_JSON="$TMP/lifecycle-run.json"; export LIFE_RUN_JSON

jq '.repository.full_name = "other/repo"' "$TMP/lifecycle-run.json" > "$TMP/lifecycle-run-case.json"
LIFE_RUN_JSON="$TMP/lifecycle-run-case.json"; export LIFE_RUN_JSON
bound_case 'wrong repository' BLOCKED 'differs from repository' 1
jq '.path = ".github/workflows/other.yml"' "$TMP/lifecycle-run.json" > "$TMP/lifecycle-run-case.json"
bound_case 'wrong workflow' BLOCKED 'differs from repository' 1
jq '.head_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$TMP/lifecycle-run.json" > "$TMP/lifecycle-run-case.json"
bound_case 'copied successful run' BLOCKED 'differs from repository' 1
jq '.conclusion = "failure"' "$TMP/lifecycle-run.json" > "$TMP/lifecycle-run-case.json"
bound_case 'failed run' BLOCKED 'concluded failure' 1
jq '.run_attempt = 2 | .conclusion = "failure"' "$TMP/lifecycle-run.json" > "$TMP/lifecycle-run-case.json"
bound_case 'rerun changed conclusion' BLOCKED 'attempt 2 differs' 1
jq '.run_attempt = 2' "$TMP/lifecycle-run.json" > "$TMP/lifecycle-run-case.json"
bound_case 'live attempt advanced' BLOCKED 'attempt 2 differs' 1
LIFE_RUN_JSON="$TMP/lifecycle-run.json"; export LIFE_RUN_JSON
sed 's/attempt=1/attempt=2/' "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments-case.json"; export LIFE_COMMENTS_JSON
bound_case 'recorded attempt greater' BLOCKED 'attempt 1 differs' 1
sed 's/; attempt=1//' "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
bound_case 'missing attempt' UNVERIFIED 'missing attempt=' 0
sed 's/; attempt=1/; attempt=1; attempt=1/' "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
bound_case 'duplicate attempt' BLOCKED 'malformed review record' 0
sed 's|; run=https://github.com/owner/repo/actions/runs/100|; run=https://github.com/owner/repo/actions/runs/100; run=https://github.com/owner/repo/actions/runs/100|' \
  "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
bound_case 'duplicate run' BLOCKED 'malformed review record' 0
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"; export LIFE_COMMENTS_JSON
LIFE_RUN_FAIL=true
bound_case 'deleted run' UNVERIFIED 'Actions run 100 unavailable' 1
LIFE_RUN_FAIL=false

jq '.data.repository.issue.comments.pageInfo.hasNextPage = true | .data.repository.issue.comments.nodes = ([range(0;100) | {id:("opaque-"+tostring),fullDatabaseId:tostring,body:"prose",author:{login:"reviewer"},lastEditedAt:null}] | .[0].body = .[0].body)' \
  "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
# Keep a valid approval on the first page; pageInfo alone decides completeness.
jq --arg body "$LIFE_MARKER" '.data.repository.issue.comments.nodes[0].body = $body' \
  "$TMP/lifecycle-comments-case.json" > "$TMP/lifecycle-comments-page.json"
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments-page.json"; export LIFE_COMMENTS_JSON
bound_case 'full incomplete page' UNVERIFIED 'exceed one page' 0
jq 'del(.data.repository.issue.comments.pageInfo)' "$TMP/lifecycle-comments-page.json" \
  > "$TMP/lifecycle-comments-case.json"
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments-case.json"; export LIFE_COMMENTS_JSON
bound_case 'missing pageInfo' UNVERIFIED 'pageInfo.hasNextPage missing' 0
jq '.data.repository.issue.comments.pageInfo.hasNextPage = false' "$TMP/lifecycle-comments-page.json" \
  > "$TMP/lifecycle-comments-case.json"
bound_case 'complete 100-node page' READY 'review by reviewer' 1
jq '.errors = [{message:"partial read",path:["repository","issue"]}]' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
bound_case 'GraphQL partial error' UNVERIFIED 'GraphQL error' 0
jq '.data.repository.issue.comments.nodes = null' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
bound_case 'null nodes' UNVERIFIED 'nodes missing' 0
jq '.data.repository.issue.comments.nodes += [null]' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
bound_case 'null node' UNVERIFIED 'node 1 unreadable' 0
jq '.data.repository.issue.comments.nodes[0].fullDatabaseId = null' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
bound_case 'null ordering key' UNVERIFIED 'comment opaque-1 missing valid fullDatabaseId' 0
jq '.data.repository.issue.comments.nodes[0].fullDatabaseId = 10' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
bound_case 'numeric ordering key' UNVERIFIED 'comment opaque-1 missing valid fullDatabaseId' 0
jq '.data.repository.issue.comments.nodes[0].lastEditedAt = "2026-09-24T12:00:00Z"' \
  "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
bound_case 'edited final approval' BLOCKED 'comment opaque-1 was edited' 0
jq 'del(.data.repository.issue.comments.nodes[0].lastEditedAt)' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
bound_case 'missing edit indicator' UNVERIFIED 'comment opaque-1 missing lastEditedAt' 0
jq '.data.repository.issue.comments.nodes = []' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
bound_case 'approval on PR or step issue only' UNVERIFIED 'no approval for PR head' 0
jq --arg old "${LIFE_MARKER/$LIFE_HEAD/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}" \
  '.data.repository.issue.comments.nodes[0].body = $old' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
bound_case 'superseded approval only' UNVERIFIED 'no approval for PR head' 0
jq '.data.repository.issue.comments.nodes[0].body |= sub("status=approved";"status=changes-requested")' \
  "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
bound_case 'changes requested on current head' BLOCKED 'does not approve PR' 0
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"; export LIFE_COMMENTS_JSON

# Later posting wins even when listing order, lexicographic order, and floating
# point conversion each point at the wrong comment.
for ids in '9 10' '9007199254740992 9007199254740993'; do
  read -r low high <<< "$ids"
  jq -n --arg old "${LIFE_MARKER/attempt=1/attempt=2}" --arg new "$LIFE_MARKER" \
    --arg low "$low" --arg high "$high" \
    '{data:{repository:{issue:{comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:"new",fullDatabaseId:$high,body:$new,author:{login:"reviewer"},lastEditedAt:null},{id:"old",fullDatabaseId:$low,body:$old,author:{login:"reviewer"},lastEditedAt:null}]}}}}}' \
    > "$TMP/lifecycle-comments-case.json"
  LIFE_COMMENTS_JSON="$TMP/lifecycle-comments-case.json"; export LIFE_COMMENTS_JSON
  bound_case "decimal order $ids" READY 'review by reviewer.*comment new' 1
done
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"; export LIFE_COMMENTS_JSON

# Project policy is validated independently of the document's own selectors.
cp "$V2FIX/.agentic-flow-review-policy" "$TMP/lifecycle-policy-valid"
for policy_case in 'version=2' 'version=1
version=1' 'version=1
workflow=../ci.yml' 'version=1
workflow=.github/workflows/ci.yml
unknown=value'; do
  printf '%s\n' "$policy_case" > "$V2FIX/.agentic-flow-review-policy"
  : > "$LIFE_CALLS"
  PATH="$LIFE_API:$PATH" AGENTIC_PROJECT_ROOT="$V2FIX" \
    "$ROOT/scripts/lifecycle-status.sh" --doc "$V2FIX/docs/inprogress/feature-v2.md" \
    --check --verify-evidence > "$TMP/lifecycle-policy.out" 2>&1 \
    && fail 'invalid review policy passed'
  grep -q '^UNVERIFIED.*review policy missing or invalid' "$TMP/lifecycle-policy.out" \
    || fail 'invalid policy was not UNVERIFIED'
  if grep -q '^api ' "$LIFE_CALLS"; then fail 'invalid policy made API calls'; fi
done
cp "$TMP/lifecycle-policy-valid" "$V2FIX/.agentic-flow-review-policy"

# F-3: authenticated authors, strict step completeness, and verdict recovery.
review_case() { # <name> <state> <diagnostic>
  : > "$LIFE_CALLS"
  if PATH="$LIFE_API:$PATH" AGENTIC_PROJECT_ROOT="$V2FIX" \
    LIFE_STEP_STATE="${LIFE_STEP_STATE:-CLOSED}" \
    "$ROOT/scripts/lifecycle-status.sh" --doc "$V2FIX/docs/inprogress/feature-v2.md" \
    --check --verify-evidence > "$TMP/lifecycle-review.out" 2>&1; then
    [ "$2" = READY ] || fail "$1 unexpectedly passed"
  else
    [ "$2" != READY ] || fail "$1 unexpectedly failed: $(cat "$TMP/lifecycle-review.out")"
  fi
  grep -q "^$2.*$3" "$TMP/lifecycle-review.out" \
    || fail "$1 did not report $2 and $3: $(cat "$TMP/lifecycle-review.out")"
}
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"; export LIFE_COMMENTS_JSON
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"; export LIFE_STEP_COMMENTS_JSON
# Same-sequence race losers carry valid compatibility lines. The journal must
# choose the winner before the old marker parser ever sees those lines.
jq --arg head "$LIFE_HEAD" '
  .data.repository.issue.body="<!-- agentic-flow:plan:fixture step:f-1 spec:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa journal=v1 -->" |
  .data.repository.issue.comments.nodes |= (
    .[0].body=("agentic-flow-transition: v=1; id=fixture/f-1/1/submit; event=submit; from=executing; role=executor; head="+$head+"\n"+.[0].body) |
    .[1].body=("agentic-flow-transition: v=1; id=fixture/f-1/2/approve; event=approve; from=reviewing; role=reviewer; head="+$head+"\n"+.[1].body) |
    . + [{id:"race-loser",fullDatabaseId:"12",lastEditedAt:null,author:{login:"reviewer"},
      body:("agentic-flow-transition: v=1; id=fixture/f-1/2/bounce; event=bounce; from=reviewing; role=reviewer; head=none\nagentic-flow-review: status=changes-requested; step=f-1; head="+$head+"; role=reviewer\nFindings")}])
' "$TMP/lifecycle-step-comments.json" > "$TMP/journal-approved.json"
LIFE_STEP_COMMENTS_JSON="$TMP/journal-approved.json"
review_case 'accepted approval with losing bounce' READY 'review by reviewer'
grep -q 'journal skipped 1' "$TMP/lifecycle-review.out" || fail 'lifecycle did not count racing loser'
# This installation-specific check does not apply to generic exported policies.
if [ -f "$ROOT/scripts/export.sh" ]; then
  # Exercise the repository policy: the owner may approve plans, but cannot review.
  cp "$ROOT/.agentic-flow-review-policy" "$V2FIX/.agentic-flow-review-policy"
  jq '.data.repository.issue.comments.nodes[0].author.login="agentic-flow-reviewer[bot]"' \
    "$TMP/lifecycle-comments.json" > "$TMP/journal-app-review.json"
  LIFE_COMMENTS_JSON="$TMP/journal-app-review.json"
  jq '.data.repository.issue.comments.nodes |= [.[0],.[1]] |
    .data.repository.issue.comments.nodes[0].author.login="flow-implementer[bot]" |
    .data.repository.issue.comments.nodes[1].author.login="wabkebab"' \
    "$TMP/journal-approved.json" > "$TMP/journal-owner-review.json"
  LIFE_STEP_COMMENTS_JSON="$TMP/journal-owner-review.json"
  review_case 'repository policy rejects owner review' BLOCKED 'journal state reviewing'
  (
    . "$ROOT/scripts/lib/workflow.sh"
    . "$ROOT/scripts/lib/review-policy.sh"
    . "$ROOT/scripts/lib/journal.sh"
    workflow_load "$ROOT" && read_review_policy "$V2FIX" || exit 1
    journal_context "$(jq -r '.data.repository.issue.body' "$TMP/journal-owner-review.json")" || exit 1
    owner_comments=$(jq '.data.repository.issue.comments.nodes' "$TMP/journal-owner-review.json" | journal_normalize) || exit 1
    journal_replay "$owner_comments" step-strict | jq -e \
      '.state=="reviewing" and .seq==1 and .skipped==1' >/dev/null
  ) || fail 'repository policy did not count owner review as skipped'
  cp "$TMP/lifecycle-policy-valid" "$V2FIX/.agentic-flow-review-policy"
  LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"
fi
jq '.data.repository.issue.comments.nodes |= [.[0],.[2],.[1]]' \
  "$TMP/journal-approved.json" > "$TMP/journal-bounced.json"
LIFE_STEP_COMMENTS_JSON="$TMP/journal-bounced.json"
review_case 'accepted bounce with losing approval' BLOCKED 'journal state executing'
jq '.data.repository.issue.comments.nodes[1].lastEditedAt="2026-01-01T00:00:00Z"' \
  "$TMP/journal-approved.json" > "$TMP/journal-edited.json"
LIFE_STEP_COMMENTS_JSON="$TMP/journal-edited.json"
review_case 'accepted journal approval edited' BLOCKED 'was edited'
# With no journal lines, the legacy latest-marker reader still blocks the bounce.
jq 'del(.data.repository.issue.body) | .data.repository.issue.comments.nodes[].body |=
  (split("\n")|map(select(startswith("agentic-flow-transition:")|not))|join("\n"))' \
  "$TMP/journal-approved.json" > "$TMP/journal-legacy-reader.json"
LIFE_STEP_COMMENTS_JSON="$TMP/journal-legacy-reader.json"
review_case 'legacy latest marker selects bounce' BLOCKED 'does not approve'
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"
# Unlisted authors cannot inject malformed evidence or replace a real handoff.
sed 's/^reviewer=.*/reviewer=review-app[bot]/; s/^executor=.*/executor=execute-app[bot]/' \
  "$TMP/lifecycle-policy-valid" > "$V2FIX/.agentic-flow-review-policy"
for comments in lifecycle-comments lifecycle-step-comments; do
  jq '.data.repository.issue.comments.nodes |= map(
    if .author.login == "reviewer" then .author={login:"review-app",__typename:"Bot"}
    elif .author.login == "executor" then .author={login:"execute-app",__typename:"Bot"}
    else . end)' "$TMP/$comments.json" > "$TMP/$comments-app.json"
done
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments-app.json"
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments-app.json"
review_case 'typed App verdicts and handoff' READY 'review by review-app'
jq '.data.repository.issue.comments.nodes[].author.__typename="User"' \
  "$TMP/lifecycle-comments-app.json" > "$TMP/lifecycle-comments-human.json"
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments-human.json"
review_case 'human slug cannot impersonate App reviewer' UNVERIFIED 'no approval for PR head'
cp "$TMP/lifecycle-policy-valid" "$V2FIX/.agentic-flow-review-policy"
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"
jq '.data.repository.issue.comments.nodes += [{id:"stranger",body:"agentic-flow-review: malformed",author:{login:"stranger"}}]' "$TMP/lifecycle-comments.json" > "$TMP/stranger-final.json"
jq '.data.repository.issue.comments.nodes += [{id:"stranger",body:"Implemented in bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",author:{login:"stranger"}}]' "$TMP/lifecycle-step-comments.json" > "$TMP/stranger-step.json"
LIFE_COMMENTS_JSON="$TMP/stranger-final.json"
LIFE_STEP_COMMENTS_JSON="$TMP/stranger-step.json"
review_case 'stranger malformed marker and later handoff' READY 'review by reviewer'
grep -q 'EVIDENCE ignored 1' "$TMP/lifecycle-review.out" || fail 'stranger comments not counted'
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"
jq '.data.repository.issue.comments.nodes += [{id:"reviewer-handoff",body:"Implemented in bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",author:{login:"reviewer"}}]' "$TMP/lifecycle-step-comments.json" > "$TMP/reviewer-handoff.json"
LIFE_STEP_COMMENTS_JSON="$TMP/reviewer-handoff.json"
review_case 'reviewer handoff rejected' BLOCKED 'is not an executor'
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"
# Approved commits must remain reachable from the live PR head.
ancestry_case() { # <name> <head> <state> <diagnostic>
  jq --arg head "$2" --arg old "$LIFE_HEAD" '.data.repository.issue.comments.nodes |= map(.body |= gsub($old; $head))' \
    "$TMP/lifecycle-step-comments.json" > "$TMP/ancestry-step.json"
  LIFE_STEP_COMMENTS_JSON="$TMP/ancestry-step.json"
  review_case "$1" "$3" "$4"
}
# An alternate commit models an amended implementation, absent from the PR.
ALT_HEAD=$(printf '%s\n' alternate | git -C "$V2FIX" -c commit.gpgsign=false -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree "${LIFE_HEAD}^{tree}" -p "$STEP_HEAD")
ancestry_case 'amended approved step' "$ALT_HEAD" BLOCKED "$ALT_HEAD.*$LIFE_HEAD"
ancestry_case 'missing approved step' cccccccccccccccccccccccccccccccccccccccc UNVERIFIED 'cccccccccccccccccccccccccccccccccccccccc.*git fetch'
jq '.head.sha = "cccccccccccccccccccccccccccccccccccccccc"' "$TMP/lifecycle-pr.json" > "$TMP/missing-pr.json"
sed "s/$LIFE_HEAD/cccccccccccccccccccccccccccccccccccccccc/g" "$TMP/lifecycle-comments.json" > "$TMP/missing-pr-comments.json"
sed "s/$LIFE_HEAD/cccccccccccccccccccccccccccccccccccccccc/g" "$TMP/lifecycle-run.json" > "$TMP/missing-pr-run.json"
LIFE_PR_JSON="$TMP/missing-pr.json"
LIFE_COMMENTS_JSON="$TMP/missing-pr-comments.json"
LIFE_RUN_JSON="$TMP/missing-pr-run.json"
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"
review_case 'missing PR object' UNVERIFIED 'cccccccccccccccccccccccccccccccccccccccc.*git fetch origin pull/2/head'
LIFE_PR_JSON="$TMP/lifecycle-pr.json"
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"
LIFE_RUN_JSON="$TMP/lifecycle-run.json"
# A genuine shallow boundary hides an otherwise present ancestor object.
printf '%s\n' "$LIFE_HEAD" > "$V2FIX/.git/shallow"
ancestry_case 'shallow ancestry' "$STEP_HEAD" UNVERIFIED 'git fetch --unshallow'
rm "$V2FIX/.git/shallow"
# Inject only the ancestry command failure; object checks still use real Git.
REAL_LIFE_GIT=$(command -v git)
export REAL_LIFE_GIT
cat > "$LIFE_API/git" <<'FAKE_GIT'
#!/usr/bin/env bash
case "$*" in
  *'merge-base --is-ancestor'*) echo 'fatal: fixture ancestry error' >&2; exit 128 ;;
esac
exec "$REAL_LIFE_GIT" "$@"
FAKE_GIT
chmod +x "$LIFE_API/git"
ancestry_case 'git ancestry error' "$STEP_HEAD" UNVERIFIED 'fatal: fixture ancestry error'
rm "$LIFE_API/git"
ancestry_case 'ancestor approved step' "$STEP_HEAD" READY 'review by reviewer'
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"
review_case 'authenticated final and step' READY 'review by reviewer'
grep -q 'EVIDENCE step f-1.*author=reviewer' "$TMP/lifecycle-review.out" \
  || fail 'step evidence did not print comment and author'
grep -q 'WARN.*single-operator.*not independent review' "$TMP/lifecycle-review.out" \
  || fail 'single-operator evidence lacked the independence warning'
LIFE_STEP_STATE=OPEN
review_case 'open Strict step' BLOCKED 'step f-1 issue 3 is OPEN'
LIFE_STEP_STATE=CLOSED
mkdir -p "$V2FIX/docs/done"
cp "$V2FIX/docs/inprogress/feature-v2.md" "$V2FIX/docs/done/feature-v2.md"
PATH="$LIFE_API:$PATH" AGENTIC_PROJECT_ROOT="$V2FIX" \
  "$ROOT/scripts/lifecycle-status.sh" --doc "$V2FIX/docs/done/feature-v2.md" \
  --phase close-out --check --verify-evidence > "$TMP/lifecycle-closeout.out" 2>&1 \
  || fail 'moved document did not verify before tracker close'
PATH="$LIFE_API:$PATH" LIFE_ISSUE_STATE=CLOSED AGENTIC_PROJECT_ROOT="$V2FIX" \
  "$ROOT/scripts/lifecycle-status.sh" --doc "$V2FIX/docs/done/feature-v2.md" \
  --phase pre-merge --check --verify-evidence > "$TMP/lifecycle-premerge.out" 2>&1 \
  || fail 'same moved document did not verify after tracker close'
grep -q '^READY.*feature-v2.md' "$TMP/lifecycle-premerge.out" \
  || fail 'pre-merge did not report READY after tracker close'
jq 'del(.data.repository.issue.comments.nodes[0].author)' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments-case.json"; export LIFE_COMMENTS_JSON
review_case 'missing final author' UNVERIFIED 'no approval for PR head'
jq '.data.repository.issue.comments.nodes[0].author.login = "intruder"' \
  "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
printf '%s\n' 'version=1' 'workflow=.github/workflows/ci.yml' 'identity-mode=distinct-account' \
  'reviewer=reviewer' 'executor=executor' 'approver=approver' \
  > "$V2FIX/.agentic-flow-review-policy"
review_case 'unauthorized author' UNVERIFIED 'no approval for PR head'
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"; export LIFE_COMMENTS_JSON
review_case 'distinct account reviewer' READY 'review by reviewer'
jq '.data.repository.issue.comments.nodes[0].author.login = "intruder"' \
  "$TMP/lifecycle-step-comments.json" > "$TMP/lifecycle-step-case.json"
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-case.json"; export LIFE_STEP_COMMENTS_JSON
review_case 'unauthorized step handoff' UNVERIFIED 'no full implementation SHA handoff'
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"; export LIFE_STEP_COMMENTS_JSON
printf '%s\n' 'version=1' 'workflow=.github/workflows/ci.yml' 'identity-mode=distinct-account' \
  'reviewer=reviewer' 'executor=reviewer' 'approver=approver' \
  > "$V2FIX/.agentic-flow-review-policy"
review_case 'overlapping reviewer account' UNVERIFIED 'review policy missing or invalid'
cp "$TMP/lifecycle-policy-valid" "$V2FIX/.agentic-flow-review-policy"
sed 's/; role=reviewer/; role=executor/' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments-case.json"; export LIFE_COMMENTS_JSON
review_case 'false role claim' BLOCKED 'role claim differs'
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"; export LIFE_COMMENTS_JSON

jq '.data.repository.issue.comments.pageInfo.hasNextPage = true' \
  "$TMP/lifecycle-step-comments.json" > "$TMP/lifecycle-step-case.json"
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-case.json"; export LIFE_STEP_COMMENTS_JSON
review_case 'partial step page' UNVERIFIED 'step f-1 comments exceed one page'
jq 'del(.data.repository.issue.comments.pageInfo)' "$TMP/lifecycle-step-comments.json" \
  > "$TMP/lifecycle-step-case.json"
review_case 'step missing pageInfo' UNVERIFIED 'step f-1 pageInfo.hasNextPage missing'
jq '.errors = [{message:"partial step read",path:["issue"]}]' \
  "$TMP/lifecycle-step-comments.json" > "$TMP/lifecycle-step-case.json"
review_case 'step GraphQL error' UNVERIFIED 'step f-1 GraphQL error'
jq '.data.repository.issue.comments.nodes += [null]' "$TMP/lifecycle-step-comments.json" \
  > "$TMP/lifecycle-step-case.json"
review_case 'step null node' UNVERIFIED 'step f-1 comment node 2 unreadable'
jq '.data.repository.issue.comments.nodes += ([range(2;100) | {id:("prose-"+tostring),fullDatabaseId:tostring,body:"prose",author:{login:"reviewer"},lastEditedAt:null}]) | .data.repository.issue.comments.pageInfo.hasNextPage = false' \
  "$TMP/lifecycle-step-comments.json" > "$TMP/lifecycle-step-case.json"
review_case 'complete 100-node step page' READY 'review by reviewer'
jq 'del(.data.repository.issue.comments.nodes[1].lastEditedAt)' \
  "$TMP/lifecycle-step-comments.json" > "$TMP/lifecycle-step-case.json"
review_case 'step missing edit indicator' UNVERIFIED 'step f-1 comment step-review missing lastEditedAt'
jq '.data.repository.issue.comments.nodes[1].fullDatabaseId = null' \
  "$TMP/lifecycle-step-comments.json" > "$TMP/lifecycle-step-case.json"
review_case 'step null ordering key' UNVERIFIED 'step f-1 comment step-review missing valid fullDatabaseId'
jq '.data.repository.issue.comments.nodes[1].lastEditedAt = "2026-09-25T12:00:00Z"' \
  "$TMP/lifecycle-step-comments.json" > "$TMP/lifecycle-step-case.json"
review_case 'edited authoritative step verdict' BLOCKED 'step f-1 comment step-review was edited'
jq --arg head "$LIFE_HEAD" '.data.repository.issue.comments.nodes += [{id:"fresh",fullDatabaseId:"12",body:("agentic-flow-review: status=approved; step=f-1; head=" + $head + "; role=reviewer"),author:{login:"reviewer"},lastEditedAt:null}]' \
  "$TMP/lifecycle-step-case.json" > "$TMP/lifecycle-step-recovered.json"
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-recovered.json"; export LIFE_STEP_COMMENTS_JSON
review_case 'fresh verdict recovers edit' READY 'review by reviewer'
jq --arg head "$LIFE_HEAD" '.data.repository.issue.comments.nodes[1].body = "review note" | .data.repository.issue.comments.nodes += [{id:"earlier-approval",fullDatabaseId:"9",body:("agentic-flow-review: status=approved; step=f-1; head=" + $head + "; role=reviewer"),author:{login:"reviewer"},lastEditedAt:null}]' \
  "$TMP/lifecycle-step-case.json" > "$TMP/lifecycle-step-recovered.json"
review_case 'removing marker recovers edit' READY 'review by reviewer'
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"; export LIFE_STEP_COMMENTS_JSON

# A reviewer body that repeats the marker handoff writes yields two identical lines.
# That is one claim and must not block; a different second marker still must.
jq '.data.repository.issue.comments.nodes[1].body |= (. + "\n" + .)' \
  "$TMP/lifecycle-step-comments.json" > "$TMP/lifecycle-step-case.json"
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-case.json"; export LIFE_STEP_COMMENTS_JSON
review_case 'identical repeated step marker' READY 'review by reviewer'
jq '.data.repository.issue.comments.nodes[1].body |= (. + "\n" + sub("status=approved";"status=changes-requested"))' \
  "$TMP/lifecycle-step-comments.json" > "$TMP/lifecycle-step-case.json"
review_case 'conflicting second step marker' BLOCKED 'has multiple review markers'
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"; export LIFE_STEP_COMMENTS_JSON

# Above 2^53, adjacent ids collapse if coerced through jq's floating-point number.
# Reverse listing order and share a creation second to rule out both shortcuts.
jq --arg head "$LIFE_HEAD" '.data.repository.issue.comments.nodes = [.data.repository.issue.comments.nodes[0],{id:"new-rejection",fullDatabaseId:"9007199254740993",body:("agentic-flow-review: status=changes-requested; step=f-1; head=" + $head + "; role=reviewer"),author:{login:"reviewer"},createdAt:"2026-09-25T12:00:00Z",lastEditedAt:null},{id:"old-approval",fullDatabaseId:"9007199254740992",body:("agentic-flow-review: status=approved; step=f-1; head=" + $head + "; role=reviewer"),author:{login:"reviewer"},createdAt:"2026-09-25T12:00:00Z",lastEditedAt:null}]' \
  "$TMP/lifecycle-step-comments.json" > "$TMP/lifecycle-step-case.json"
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-case.json"; export LIFE_STEP_COMMENTS_JSON
review_case 'adjacent high step ids and same-second verdicts' BLOCKED 'comment new-rejection does not approve'
jq '.data.repository.issue.comments.nodes[1].lastEditedAt = "2026-09-25T12:00:00Z" | .data.repository.issue.comments.nodes[1].body |= sub("status=changes-requested";"status=approved")' \
  "$TMP/lifecycle-step-case.json" > "$TMP/lifecycle-step-edited.json"
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-edited.json"; export LIFE_STEP_COMMENTS_JSON
review_case 'same-second authoritative edit' BLOCKED 'comment new-rejection was edited'
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"; export LIFE_STEP_COMMENTS_JSON

jq --arg head "$LIFE_HEAD" '.data.repository.issue.comments.nodes += [{id:"duplicate-db-id",fullDatabaseId:"010",body:("agentic-flow-review: status=approved; pr=2; head=" + $head + "; run=https://github.com/owner/repo/actions/runs/100; attempt=1; role=reviewer"),author:{login:"reviewer"},lastEditedAt:null}]' \
  "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments-case.json"; export LIFE_COMMENTS_JSON
review_case 'normalized duplicate database id' BLOCKED 'duplicate fullDatabaseId'
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"; export LIFE_COMMENTS_JSON

# The same collapse applies to the tracking issue's final-head verdict.
jq '.data.repository.issue.comments.nodes |= map(if (.body | startswith("agentic-flow-review: status=approved; pr=")) then .body |= (. + "\n" + .) else . end)' \
  "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments-case.json"; export LIFE_COMMENTS_JSON
review_case 'identical repeated final marker' READY 'review by reviewer'
jq '.data.repository.issue.comments.nodes |= map(if (.body | startswith("agentic-flow-review: status=approved; pr=")) then .body |= (. + "\n" + sub("attempt=1";"attempt=2")) else . end)' \
  "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
review_case 'conflicting second final marker' BLOCKED 'has multiple review markers'
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"; export LIFE_COMMENTS_JSON

# The review thread is scoped to the current PR head. A new commit makes old
# approval history irrelevant even if the Actions run once succeeded.
jq '.head.sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$TMP/lifecycle-pr.json" \
  > "$TMP/lifecycle-pr-new.json"
LIFE_PR_JSON="$TMP/lifecycle-pr-new.json"; export LIFE_PR_JSON
review_case 'stale approval after PR commit' UNVERIFIED 'no approval for PR head'
LIFE_PR_JSON="$TMP/lifecycle-pr.json"; export LIFE_PR_JSON

printf '%s\n' 'version=1' 'workflow=.github/workflows/ci.yml' 'identity-mode=single-operator' \
  'accepted-risk=docs/accepted_risks.md#missing-entry' > "$V2FIX/.agentic-flow-review-policy"
review_case 'unlinked accepted risk' UNVERIFIED 'review policy missing or invalid'
cp "$TMP/lifecycle-policy-valid" "$V2FIX/.agentic-flow-review-policy"
sed '/^reviewer=/d; /^executor=/d; /^approver=/d' "$TMP/lifecycle-policy-valid" > "$V2FIX/.agentic-flow-review-policy"
review_case 'missing role logins' UNVERIFIED 'review policy missing or invalid'
cp "$TMP/lifecycle-policy-valid" "$V2FIX/.agentic-flow-review-policy"
