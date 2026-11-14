#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2153 # ROOT comes from the sourcing test runner.
# Sourced by self-test.sh. All credentials, GitHub state and faults are fixtures.
grep -q "brief)" "$ROOT/scripts/agentic-flow" || fail 'brief command is missing'
# The slice comes from Git, including its approval metadata, never dirty bytes.
SLICE_FIX="$TMP/step-slice"
mkdir -p "$SLICE_FIX/docs/inprogress"
git -C "$SLICE_FIX" init -q
git -C "$SLICE_FIX" checkout -qb topic
git -C "$SLICE_FIX" config user.email fixture@example.invalid
git -C "$SLICE_FIX" config user.name Fixture
git -C "$SLICE_FIX" config commit.gpgsign false
cat > "$SLICE_FIX/docs/inprogress/plan.md" <<'SLICE'
# Feature — Slice fixture
# Part A — Analysis
Analysis sentinel
# Part B — Implementation Brief
```agentic-flow-plan
id: slice
profile: strict
tracking: Plan: Slice
branch: topic
steps: s-1 s-2
```
## Branch
Base main, branch topic.
## Word ceilings: read first
Ceiling sentinel
## Definition of done (whole brief)
Whole DoD sentinel
## Verification commands
```bash
make check
```
## S-1 — First
First approach sentinel
**DoD:** first done
**Verify:** `make check`
**Red-first:** none
**Risks:** first risk
## S-2 — Second
Second approach sentinel
**DoD:** second done
**Verify:** `make check`
**Red-first:** none
**Risks:** second risk
# Close-out
Close-out sentinel
## Status
- **Approval:** pending
SLICE
git -C "$SLICE_FIX" add docs/inprogress/plan.md
git -C "$SLICE_FIX" commit -qm 'Fixture approved content'
SLICE_REV=$(git -C "$SLICE_FIX" rev-parse HEAD)
sed "s/Approval:\*\* pending/Approval:** status=approved; by=human; at=2026-11-14; rev=$SLICE_REV/" \
  "$SLICE_FIX/docs/inprogress/plan.md" > "$TMP/slice-approved"
cat "$TMP/slice-approved" > "$SLICE_FIX/docs/inprogress/plan.md"
git -C "$SLICE_FIX" add docs/inprogress/plan.md
git -C "$SLICE_FIX" commit -qm 'Record fixture approval'
sed 's/First approach sentinel/Dirty sentinel/; s/^- \*\*Approval:.*$/- **Approval:** pending/' \
  "$SLICE_FIX/docs/inprogress/plan.md" > "$TMP/slice-dirty"
cat "$TMP/slice-dirty" > "$SLICE_FIX/docs/inprogress/plan.md"
slice_run() { (cd "$SLICE_FIX" && "$ROOT/scripts/agentic-flow" brief docs/inprogress/plan.md "$@"); }
slice_run absent > "$TMP/slice.out" 2> "$TMP/slice.err" && fail 'unknown slice step accepted'
[ ! -s "$TMP/slice.out" ] || fail 'unknown step leaked content'
slice_run s-1 --at missing > "$TMP/slice.out" 2> "$TMP/slice.err" && fail 'missing revision accepted'
[ ! -s "$TMP/slice.out" ] || fail 'missing revision leaked content'
slice_run s-1 > "$TMP/slice.out" || fail 'default approved slice failed'
for expected in 'Feature — Slice fixture' 'Base main' 'Ceiling sentinel' 'Whole DoD sentinel' 'make check' 'First approach sentinel'; do
  grep -q "$expected" "$TMP/slice.out" || fail "slice omitted $expected"
done
if grep -Eq 'Analysis sentinel|Second approach|Dirty sentinel|Approval:' "$TMP/slice.out"; then fail 'slice leaked unrelated or dirty content'; fi
slice_run s-2 --at "$SLICE_REV" --analysis > "$TMP/slice.out" || fail 'explicit analysis slice failed'
grep -q 'Analysis sentinel' "$TMP/slice.out" || fail 'analysis omitted'
grep -q 'Second approach sentinel' "$TMP/slice.out" || fail 'second step omitted'
grep -q 'First approach sentinel' "$TMP/slice.out" && fail 'other step leaked into analysis slice'
if grep -Eq '# Close-out|Close-out sentinel' "$TMP/slice.out"; then fail 'last step slice leaked close-out'; fi
# awk assignments must preserve literal backslash sequences in section titles.
SLICE_TITLE='S-2 — Second \t literal' awk '/^## S-2 / {$0="## " ENVIRON["SLICE_TITLE"]} {print}' \
  "$TMP/slice-approved" > "$SLICE_FIX/docs/inprogress/plan.md"
git -C "$SLICE_FIX" add docs/inprogress/plan.md
git -C "$SLICE_FIX" commit -qm 'Exercise a literal backslash in the last step title'
slice_run s-2 --at HEAD > "$TMP/slice.out" || fail 'literal backslash slice failed'
grep -q 'Second approach sentinel' "$TMP/slice.out" || fail 'literal backslash title lost the selected step'
if grep -Eq '# Close-out|Close-out sentinel' "$TMP/slice.out"; then fail 'backslash step slice leaked close-out'; fi


[ -f "$ROOT/scripts/lib/journal.sh" ] || fail 'journal library is missing'
must_block "$ROOT/scripts/hooks/require-step-comment.sh" 'gh issue edit 1 --add-label "bug, needs-review"'
must_block "$ROOT/scripts/hooks/require-step-comment.sh" 'cd /tmp; gh issue close 1'
must_allow "$ROOT/scripts/hooks/require-step-comment.sh" 'cd /tmp; gh issue view 1'

# shellcheck disable=SC1091,SC2153 # ROOT comes from the sourcing test runner.
. "$ROOT/scripts/lib/workflow.sh"
. "$ROOT/scripts/lib/review-policy.sh"
. "$ROOT/scripts/lib/journal.sh"
workflow_load "$ROOT" || fail 'cannot load station workflow'
REVIEW_EXECUTORS=' exec ' REVIEW_REVIEWERS=' review ' REVIEW_APPROVERS=' plan '
JOURNAL_PLAN=fixture JOURNAL_STEP=alpha JOURNAL_LEGACY=false
STATION_A=$(printf '%040d' 1)
STATION_B=$(printf '%040d' 2)
STATION_C=$(printf '%040d' 3)
STATION_COMMENTS='[]'
station_append() { # seq event from role head author [body]
  local line
  line="agentic-flow-transition: v=1; id=fixture/alpha/$1/$2; event=$2; from=$3; role=$4; head=$5"
  STATION_COMMENTS=$(printf '%s' "$STATION_COMMENTS" | jq --arg body "$line
${7:-Evidence}" --arg author "$6" '.+[{id:(length|tostring),dbid:(length|tostring),author:$author,body:$body,last_edited_at:null}]')
}
station_replay() { STATION_REPLAY=$(journal_replay "$STATION_COMMENTS" step-strict) || fail 'journal replay failed'; }
station_expect() { printf '%s' "$STATION_REPLAY" | jq -e "$1" >/dev/null || fail "journal assertion: $1: $STATION_REPLAY"; }
# Hostile and out-of-role writes, then both directions of a competing verdict.
station_append 1 submit executing executor "$STATION_A" stranger
station_append 1 submit executing executor "$STATION_A" review
station_replay; station_expect '.seq==0 and .state=="executing" and .skipped==2'
station_append 1 submit executing executor "$STATION_A" exec
station_append 2 approve reviewing reviewer "$STATION_A" review
station_append 2 bounce reviewing reviewer none review
station_replay; station_expect '.state=="approved" and .seq==2 and .skipped==3 and .accepted[1].comment_id=="3"'
STATION_COMMENTS='[]'
station_append 1 submit executing executor "$STATION_A" exec
station_append 2 bounce reviewing reviewer none review
station_append 2 approve reviewing reviewer "$STATION_A" review
station_replay; station_expect '.state=="executing" and .bounces==1 and .skipped==1'
# Bounced heads cannot be resubmitted, even after resume. Repeated cycles have unique IDs.
station_append 3 submit executing executor "$STATION_A" exec
station_replay; station_expect '.seq==2 and .skipped==2'
station_append 3 submit executing executor "$STATION_B" exec
station_append 4 bounce reviewing reviewer none review
station_append 5 submit executing executor "$STATION_C" exec
station_append 6 bounce reviewing reviewer none review
station_replay; station_expect '.seq==6 and .state=="escalated" and .bounces==3'
station_append 7 resume escalated approver none plan
station_append 8 submit executing executor "$STATION_A" exec
station_append 9 bounce reviewing reviewer none review
station_append 10 submit executing executor "$STATION_B" exec
station_append 11 bounce reviewing reviewer none review
station_append 12 submit executing executor "$STATION_C" exec
station_append 13 bounce reviewing reviewer none review
station_append 14 resume escalated approver none plan
station_replay; station_expect '.seq==14 and .bounces==0 and .state=="executing" and ([.accepted[].id]|unique|length)==14'
# A policy executor cannot author a reviewer-only tracker notification.
JOURNAL_STEP=tracker
STATION_COMMENTS=$(jq -nc '[{id:"foreign-notify",dbid:"20",author:"exec",last_edited_at:null,
  body:"agentic-flow-transition: v=1; id=fixture/tracker/1/notify; event=notify; from=open; role=reviewer; head=none\nAll steps approved."}]')
STATION_REPLAY=$(journal_replay "$STATION_COMMENTS" tracker) || fail 'tracker replay failed'
station_expect '.state=="open" and .seq==0 and .skipped==1 and (.accepted|length)==0'
JOURNAL_STEP=alpha
# Legacy mapping, implied bounce, approval head binding, and fixed eligibility.
STATION_COMMENTS=$(jq -nc --arg a "$STATION_A" --arg b "$STATION_B" '[
  {id:"s1",author:"exec",body:("Implemented in "+$a)},
  {id:"prose",author:"review",body:"Please fix this"},
  {id:"s2",author:"exec",body:("Implemented in "+$b)},
  {id:"r2",author:"review",body:("agentic-flow-review: status=approved; step=alpha; head="+$b+"; role=reviewer")}
] | map(.+{dbid:.id,last_edited_at:null})')
JOURNAL_LEGACY=true
station_replay; station_expect '.seq==4 and .state=="approved" and .bounces==1'
STATION_SAVED=$STATION_COMMENTS
STATION_COMMENTS=$(printf '%s' "$STATION_COMMENTS" | jq --arg a "$STATION_A" '.[-1].body|=sub("head=[a-f0-9]{40}";"head="+$a)')
station_replay; station_expect '.unjournaled=="r2"'
STATION_COMMENTS=$STATION_SAVED JOURNAL_LEGACY=false
station_replay; station_expect '.seq==0 and .state=="executing"'
legacy_body='<!-- agentic-flow:plan:fixture step:alpha spec:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa approved=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb -->'
journal_context "$legacy_body" || fail 'legacy stamp not parsed'
[ "$JOURNAL_LEGACY" = true ] || fail 'approved stamp discarded legacy eligibility'
journal_context "${legacy_body/ -->/ journal=v1 -->}" || fail 'new stamp not parsed'
[ "$JOURNAL_LEGACY" = false ] || fail 'journal=v1 did not disable legacy markers'

# Real CLI against a stateful fake gh. No network, no external Python runtime.
STATION_FIX="$TMP/stations"
mkdir -p "$STATION_FIX/bin" "$STATION_FIX/project/scripts/lib" "$STATION_FIX/project/config" "$STATION_FIX/project/docs" "$STATION_FIX/state"
# Share immutable fixture inputs; copy only identity.sh, which this fixture overrides.
for station_library in "$ROOT/scripts/lib/"*; do
  if [ "${station_library##*/}" = identity.sh ]; then
    cp "$station_library" "$STATION_FIX/project/scripts/lib/identity.sh"
  else ln "$station_library" "$STATION_FIX/project/scripts/lib/${station_library##*/}"; fi
done
ln "$ROOT/scripts/agentic-flow" "$STATION_FIX/project/scripts/agentic-flow"
ln "$ROOT/config/workflow.tsv" "$STATION_FIX/project/config/workflow.tsv"
git -C "$STATION_FIX/project" init -q
git -C "$STATION_FIX/project" remote add origin https://github.com/owner/repo.git
printf '%s\n' 'version=1' 'workflow=.github/workflows/ci.yml' 'identity-mode=distinct-account' \
  'executor=exec' 'reviewer=review' 'approver=plan' > "$STATION_FIX/project/.agentic-flow-review-policy"
cat > "$STATION_FIX/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
state=${STATION_STATE:?}
printf '%s\n' "$*" >> "$state/calls"
case "$1 $2" in
  'issue comment'|'issue edit'|'issue close'|'issue reopen')
    waited=0
    until mkdir "$state/write-lock" 2>/dev/null; do
      [ "$waited" -lt 100 ] || exit 1
      sleep 0.05; waited=$((waited+1))
    done
    trap 'rmdir "$state/write-lock"' EXIT ;;
esac
case "$1 $2" in
  'api user') printf '%s\n' "${STATION_LOGIN:-exec}" ;;
  'api graphql')
    n=''; for arg in "$@"; do case "$arg" in number=*) n=${arg#number=} ;; esac; done
    [ "${STATION_BAD_READ:-0}" = 0 ] || { echo '{}'; exit 0; }
    jq --argjson more "${STATION_MORE:-false}" '{data:{repository:{issue:(. | .comments.pageInfo.hasNextPage=$more)}}}' "$state/$n.json" ;;
  'issue view') jq '{body}' "$state/$3.json" ;;
  'issue list')
    search=''; for ((i=1;i<=$#;i++)); do
      if [ "${!i}" = --search ]; then i=$((i+1)); search=${!i}; fi
    done
    author=${search##* author:}
    jq -s --arg author "$author" --arg unfiltered "${STATION_DISCOVERY_UNFILTERED:-0}" '
      map({number,body,author}) |
      if $author!="" and $unfiltered!="1" then
        map(select((.author.login + (if .author.is_bot==true and (.author.login|endswith("[bot]")|not) then "[bot]" else "" end))==$author))
      else . end | .[0:100]' "$state/"*.json ;;
  'issue comment')
    n=$3; shift 3; file=''
    while [ "$#" -gt 0 ]; do case "$1" in --body-file) file=$2; shift 2 ;; *) shift ;; esac; done
    jq --arg body "$(cat "$file")" --arg login "$(if [ "${GH_TOKEN:-}" = fixture-review ]; then echo review; else echo "${STATION_LOGIN:-exec}"; fi)" \
      '.comments.nodes += [{id:("C"+(.comments.nodes|length|tostring)),fullDatabaseId:(.comments.nodes|length|tostring),body:$body,author:{login:$login,__typename:"User"},createdAt:"2026-01-01T00:00:00Z",lastEditedAt:null}]' \
      "$state/$n.json" > "$state/next"; mv "$state/next" "$state/$n.json"
    printf 'https://github.com/owner/repo/issues/%s#issuecomment-%s\n' "$n" "$(jq '(.comments.nodes|length)-1' "$state/$n.json")"
    [ "${STATION_POST_TIMEOUT:-0}" = 0 ] || exit 1 ;;
  'issue edit')
    n=$3; shift 3; add='' remove=''
    while [ "$#" -gt 0 ]; do case "$1" in --add-label) add=$2; shift 2 ;; --remove-label) remove=$2; shift 2 ;; *) shift ;; esac; done
    [ "${STATION_EDIT_FAIL:-0}" = 0 ] || exit 1
    jq --arg add "$add" --arg remove "$remove" '.labels.nodes =
      ([.labels.nodes[].name | select(. as $x | ($remove|split(",")|index($x))==null)] +
      ($add|split(",")|map(select(length>0))) | unique | map({name:.}))' "$state/$n.json" > "$state/next"
    mv "$state/next" "$state/$n.json" ;;
  'issue close'|'issue reopen')
    target=CLOSED; [ "$2" != reopen ] || target=OPEN
    jq --arg target "$target" '.state=$target' "$state/$3.json" > "$state/next"; mv "$state/next" "$state/$3.json" ;;
  *) exit 2 ;;
esac
FAKE_GH
chmod +x "$STATION_FIX/bin/gh"
export STATION_STATE="$STATION_FIX/state"
station_issue() { # number identity extra topology
  jq -n --argjson n "$1" --arg body "<!-- agentic-flow:plan:fixture $2 spec:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa journal=v1 -->
<!-- agentic-flow:topology:${3:-strict} -->" \
    '{number:$n,body:$body,author:{login:"plan",is_bot:false},state:"OPEN",labels:{pageInfo:{hasNextPage:false},nodes:[{name:"user-label"}]},comments:{pageInfo:{hasNextPage:false},nodes:[]}}' > "$STATION_STATE/$1.json"
}
station_run() { # expected status, then handoff args
  local expected=$1 rc=0; shift
  (cd "$STATION_FIX/project" && PATH="$STATION_FIX/bin:$PATH" XDG_CONFIG_HOME="$STATION_FIX/config" \
    scripts/agentic-flow handoff "$@") > "${STATION_OUTPUT:-$TMP/station.out}" 2>&1 || rc=$?
  [ "$rc" = "$expected" ] || fail "handoff returned $rc expected $expected ($*): $(cat "${STATION_OUTPUT:-$TMP/station.out}")"
}
station_count() { jq '.comments.nodes|length' "$STATION_STATE/$1.json"; }
station_issue 1 step:alpha
station_issue 2 tracker
STATION_LOGIN=review; export STATION_LOGIN
# Public search hits are untrusted until author and exact plan stamp match.
station_issue 3 step:foreign
jq '.author={login:"stranger",is_bot:false} | .body="Someone mentioned agentic-flow:plan:fixture"' "$STATION_STATE/3.json" > "$STATION_STATE/next"
mv "$STATION_STATE/next" "$STATION_STATE/3.json"
station_issue 4 step:forged
jq '.author={login:"stranger",is_bot:false}' "$STATION_STATE/4.json" > "$STATION_STATE/next"
mv "$STATION_STATE/next" "$STATION_STATE/4.json"
station_issue 5 step:quoted
jq '.body="Quote: <!-- agentic-flow:plan:fixture step:quoted spec:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->"' "$STATION_STATE/5.json" > "$STATION_STATE/next"
mv "$STATION_STATE/next" "$STATION_STATE/5.json"
station_issue 7 step:malformed
jq '.body="<!-- agentic-flow:plan:fixture malformed -->"' "$STATION_STATE/7.json" > "$STATION_STATE/next"
mv "$STATION_STATE/next" "$STATION_STATE/7.json"
station_issue 6 step:other
jq '.body|=sub("plan:fixture";"plan:fixture-other")' "$STATION_STATE/6.json" > "$STATION_STATE/next"
mv "$STATION_STATE/next" "$STATION_STATE/6.json"
printf '%s\n' 'approver=plan-app[bot]' >> "$STATION_FIX/project/.agentic-flow-review-policy"
jq '.author={login:"plan-app",is_bot:true}' "$STATION_STATE/2.json" > "$STATION_STATE/next"
mv "$STATION_STATE/next" "$STATION_STATE/2.json"
station_issue 8 step:impersonator
jq '.author={login:"plan-app",is_bot:false}' "$STATION_STATE/8.json" > "$STATION_STATE/next"
mv "$STATION_STATE/next" "$STATION_STATE/8.json"
# A matching cwd filename must never expand an App login into a glob match.
: > "$STATION_FIX/project/plan-appo"
: > "$STATION_STATE/calls"
STATION_DISCOVERY_UNFILTERED=1 station_run 0 1 reconcile --json
# Diagnostics go to stderr; station_run captures both streams, so separate JSON.
grep -q 'skipping approver-authored discovery hit #7: unparseable plan stamp' "$TMP/station.out" || fail 'malformed trusted hit was skipped silently'
sed '/^handoff: /d' "$TMP/station.out" > "$TMP/discovery.json"
jq -e 'keys==["1","2"]' "$TMP/discovery.json" >/dev/null || fail 'discovery admitted foreign or non-stamped issues'
if grep -Eq 'api graphql .*number=(3|4|5|6|7|8)$' "$STATION_STATE/calls"; then fail 'discovery read a rejected issue thread'; fi
rm "$STATION_STATE/3.json" "$STATION_STATE/5.json" "$STATION_STATE/6.json" "$STATION_STATE/7.json" "$STATION_STATE/8.json"
# Author filtering must precede the server result cap, not just filter one full page.
for ((spam=10;spam<110;spam++)); do
  jq --argjson n "$spam" '.number=$n | .author={login:"stranger",is_bot:false}' "$STATION_STATE/1.json" > "$STATION_STATE/$spam.json"
done
station_run 0 1 reconcile --json
jq -e 'keys==["1","2"]' "$TMP/station.out" >/dev/null || fail 'foreign search hits exhausted discovery'
for ((spam=10;spam<110;spam++)); do rm "$STATION_STATE/$spam.json"; done
# Scenario 10 requires the CLI to refuse and name the mismatched legacy approval.
jq --arg a "$STATION_A" --arg b "$STATION_B" '
  .body|=sub(" journal=v1";"") |
  .comments.nodes=[
    {id:"legacy-submit",fullDatabaseId:"1",body:("Implemented in "+$a),author:{login:"exec"},createdAt:"2026-01-01T00:00:00Z",lastEditedAt:null},
    {id:"legacy-mismatch",fullDatabaseId:"2",body:("agentic-flow-review: status=approved; step=alpha; head="+$b+"; role=reviewer"),author:{login:"review"},createdAt:"2026-01-01T00:00:01Z",lastEditedAt:null}]
' "$STATION_STATE/1.json" > "$STATION_STATE/next"
mv "$STATION_STATE/next" "$STATION_STATE/1.json"
: > "$STATION_STATE/calls"
STATION_LOGIN='exec'
station_run 3 1 submit --as executor --head "$STATION_C"
grep -q 'UNJOURNALED #1 comment legacy-mismatch' "$TMP/station.out" || fail 'UNJOURNALED refusal did not name the comment'
if grep -Eq '^issue (comment|edit|close|reopen) ' "$STATION_STATE/calls"; then fail 'UNJOURNALED handoff mutated GitHub'; fi
station_issue 1 step:alpha
STATION_LOGIN=review
station_run 3 2 notify --as reviewer
station_run 3 1 submit --as executor --head "$STATION_A"
[ "$(station_count 1)" = 0 ] || fail 'unauthorized role wrote a comment'
STATION_LOGIN='exec'
STATION_MORE=true; export STATION_MORE
station_run 5 1 submit --as executor --head "$STATION_A"
unset STATION_MORE
STATION_BAD_READ=1; export STATION_BAD_READ
station_run 5 1 submit --as executor --head "$STATION_A"
unset STATION_BAD_READ
[ "$(station_count 1)" = 0 ] || fail 'malformed/truncated read wrote a comment'
station_run 3 1 approve --as reviewer --head "$STATION_A"
STATION_EDIT_FAIL=1; export STATION_EDIT_FAIL
station_run 5 1 submit --as executor --head "$STATION_A"
unset STATION_EDIT_FAIL
[ "$(station_count 1)" = 1 ] || fail 'submit did not land before projection failure'
station_run 0 1 submit --as executor --head "$STATION_A"
[ "$(station_count 1)" = 1 ] || fail 'retry duplicated a submit'
jq -e '[.labels.nodes[].name]|sort==["agent:opencode","needs-review","user-label"]' "$STATION_STATE/1.json" >/dev/null || fail 'retry did not repair labels'
printf '%s\n' 'Failure evidence' > "$STATION_FIX/note"
STATION_LOGIN=review
station_run 0 1 bounce --as reviewer --body-file "$STATION_FIX/note"
STATION_LOGIN='exec'
station_run 0 1 submit --as executor --head "$STATION_A" --after 0
grep -q superseded "$TMP/station.out" || fail 'superseded retry not reported'
station_run 4 1 submit --as executor --head "$STATION_B" --after 0
station_run 3 1 submit --as executor --head "$STATION_A"
STATION_POST_TIMEOUT=1; export STATION_POST_TIMEOUT
station_run 0 1 submit --as executor --head "$STATION_B"
unset STATION_POST_TIMEOUT
[ "$(station_count 1)" = 3 ] || fail 'timed-out successful post duplicated'
STATION_LOGIN=review
AGENTIC_HANDOFF_TESTING=1 AGENTIC_HANDOFF_FAULT=before-notify station_run 5 1 approve --as reviewer --head "$STATION_B"
[ "$(station_count 2)" = 0 ] || fail 'before-notify fault did not stop effect'
jq -e '.state=="CLOSED" and [.labels.nodes[].name]==["user-label"]' "$STATION_STATE/1.json" >/dev/null || fail 'approval projection incorrect'
# Any role can reconcile, but only the reviewer may author the effect.
STATION_LOGIN='exec'
station_run 7 1 reconcile
grep -q 'handoff 2 reconcile' "$TMP/station.out" || fail 'pending effect omitted recovery command'
[ "$(station_count 2)" = 0 ] || fail 'executor authored notify'
# Only the fixture copy is overridden: exercise configured identity routing and
# configured mint failure without a real keychain or credential.
cat >> "$STATION_FIX/project/scripts/lib/identity.sh" <<'FIXTURE_IDENTITY'
identity_load() {
  if [ "${STATION_CONFIGURED:-0}" = 1 ] && [ "$2" = reviewer ]; then
    IDENTITY_LOGIN=review; return 0
  fi
  return 6
}
identity_token() {
  [ "${STATION_MINT_FAIL:-0}" = 0 ] || return 5
  printf '%s\n' fixture-review
}
FIXTURE_IDENTITY
STATION_CONFIGURED=1 STATION_MINT_FAIL=1 station_run 5 1 reconcile
[ "$(station_count 2)" = 0 ] || fail 'failed configured mint fell back to ambient'
STATION_CONFIGURED=1 station_run 0 1 reconcile
jq -e '.comments.nodes[0].author.login=="review"' "$STATION_STATE/2.json" >/dev/null || fail 'notify used caller instead of configured reviewer'
STATION_LOGIN=review
station_run 0 1 approve --as reviewer --head "$STATION_B"
station_run 0 1 approve --as reviewer --head "$STATION_B"
station_run 0 2 reconcile --json
[ "$(station_count 1)" = 4 ] && [ "$(station_count 2)" = 1 ] || fail 'notify crash recovery duplicated comments'
jq -e '.["2"].state=="closing" and .["1"].state=="approved"' "$TMP/station.out" >/dev/null || fail 'reconcile JSON did not report plan replay'
[ -s "$STATION_FIX/project/.git/agentic-flow/state/fixture.tsv" ] || fail 'handoff cache absent'
# A dead process lock is recoverable; two concurrent approvals serialize to one.
mkdir -p "$STATION_FIX/project/.git/agentic-flow/locks/fixture"
printf '%s\n' 99999999 > "$STATION_FIX/project/.git/agentic-flow/locks/fixture/pid"
station_run 0 1 reconcile
rm "$STATION_STATE/2.json" "$STATION_STATE/4.json"
station_issue 1 step:alpha standard
STATION_LOGIN='exec'
station_run 0 1 submit --as executor --head "$STATION_A"
STATION_LOGIN=review
station_run 0 1 approve --as reviewer --head "$STATION_A" & station_pid=$!
station_run 0 1 approve --as reviewer --head "$STATION_A"
wait "$station_pid" || fail 'concurrent approval failed'
[ "$(station_count 1)" = 2 ] || fail 'lock did not serialize identical approvals'
jq -e '.state=="OPEN" and ([.labels.nodes[].name]|index("needs-closing"))!=null' "$STATION_STATE/1.json" >/dev/null || fail 'Standard approval did not remain open in closing'
# Lock bypass simulates another machine. A losing approval leaves its marker on
# the thread but cannot win the journal or the labels.
station_wait_ready() {
  local tries=0
  until [ -f "$1.ready" ]; do
    [ "$tries" -lt 300 ] || fail 'handoff fault did not pause'
    sleep 0.1; tries=$((tries+1))
  done
}
station_issue 1 step:alpha standard
STATION_LOGIN='exec'
station_run 0 1 submit --as executor --head "$STATION_A"
STATION_LOGIN=review
AGENTIC_HANDOFF_TESTING=1 AGENTIC_HANDOFF_NO_LOCK=1 AGENTIC_HANDOFF_FAULT=after-replay \
  AGENTIC_HANDOFF_PAUSE="$STATION_FIX/approval" STATION_OUTPUT="$TMP/loser.out" \
  station_run 4 1 approve --as reviewer --head "$STATION_A" & station_pid=$!
station_wait_ready "$STATION_FIX/approval"
AGENTIC_HANDOFF_TESTING=1 AGENTIC_HANDOFF_NO_LOCK=1 \
  station_run 0 1 bounce --as reviewer --body-file "$STATION_FIX/note"
: > "$STATION_FIX/approval.release"
wait "$station_pid" || fail 'race-losing approval did not return 4'
station_run 0 1 reconcile --json
jq -e '.["1"].state=="executing" and .["1"].skipped==1' "$TMP/station.out" >/dev/null || fail 'racing loser changed replay'
jq -e '([.labels.nodes[].name]|index("needs-execution"))!=null' "$STATION_STATE/1.json" >/dev/null || fail 'racing loser overwrote projection'
# A submit which resumes after a subsequent bounce must repair executing labels.
station_issue 1 step:alpha standard
STATION_LOGIN='exec'
AGENTIC_HANDOFF_TESTING=1 AGENTIC_HANDOFF_NO_LOCK=1 AGENTIC_HANDOFF_FAULT=after-labels \
  AGENTIC_HANDOFF_PAUSE="$STATION_FIX/submit" STATION_OUTPUT="$TMP/stale-submit.out" \
  station_run 0 1 submit --as executor --head "$STATION_A" & station_pid=$!
station_wait_ready "$STATION_FIX/submit"
STATION_LOGIN=review
AGENTIC_HANDOFF_TESTING=1 AGENTIC_HANDOFF_NO_LOCK=1 \
  station_run 0 1 bounce --as reviewer --body-file "$STATION_FIX/note"
: > "$STATION_FIX/submit.release"
wait "$station_pid" || fail 'stale submit failed to converge'
jq -e '([.labels.nodes[].name]|index("needs-execution"))!=null' "$STATION_STATE/1.json" >/dev/null || fail 'stale submit restored reviewing labels'
# With the plan lock, a bounce waits for the paused submit, then succeeds.
station_issue 1 step:alpha standard
STATION_LOGIN='exec'
AGENTIC_HANDOFF_TESTING=1 AGENTIC_HANDOFF_FAULT=after-replay \
  AGENTIC_HANDOFF_PAUSE="$STATION_FIX/locked" STATION_OUTPUT="$TMP/locked-submit.out" \
  station_run 0 1 submit --as executor --head "$STATION_A" & station_pid=$!
station_wait_ready "$STATION_FIX/locked"
STATION_LOGIN=review
STATION_OUTPUT="$TMP/locked-bounce.out" station_run 0 1 bounce --as reviewer --body-file "$STATION_FIX/note" & bounce_pid=$!
[ "$(station_count 1)" = 0 ] || fail 'bounce did not wait for submit lock'
: > "$STATION_FIX/locked.release"
wait "$station_pid" || fail 'locked submit failed'
wait "$bounce_pid" || fail 'locked bounce failed'
jq -e '([.labels.nodes[].name]|index("needs-execution"))!=null' "$STATION_STATE/1.json" >/dev/null || fail 'serialized bounce did not execute'
# Exactly 100 comments are readable; a pageInfo continuation is refused above.
station_issue 1 step:alpha standard
jq '.comments.nodes=[range(100)|{id:tostring,fullDatabaseId:tostring,author:{login:"stranger"},body:"ordinary",createdAt:"2026-01-01T00:00:00Z",lastEditedAt:null}]' \
  "$STATION_STATE/1.json" > "$STATION_STATE/next"
mv "$STATION_STATE/next" "$STATION_STATE/1.json"
station_run 0 1 reconcile
unset STATION_STATE STATION_LOGIN
