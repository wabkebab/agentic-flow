#!/usr/bin/env bash
# Human shipping surface; phases are derived from Git, PR and lifecycle.
# shellcheck disable=SC1091,SC2034
. "$(dirname "${BASH_SOURCE[0]}")/close-out.sh"

ship_error() { printf 'ship: %s\n' "$*" >&2; }
ship_clean() {
  local dirty
  dirty=$(git status --porcelain) || return 1
  [ -z "$dirty" ] || { ship_error 'commit the staged/uncommitted close-out before shipping:'; printf '%s\n' "$dirty" >&2; return 1; }
}
# Query without executing recipes; status 1 means an existing target is out of date.
# Only an explicitly missing target is optional. Parse/build errors fail closed.
ship_gate() {
  local rc=0
  LC_ALL=C make -C "$SHIP_ROOT" -q ship-gate > "$HANDOFF_TMP/ship-gate-probe" 2>&1 || rc=$?
  case "$rc" in
    0|1) ;;
    *)
      if grep -q "No rule to make target .ship-gate'" "$HANDOFF_TMP/ship-gate-probe"; then
        printf 'ship: ship-gate target is not defined; continuing.\n'
        return 0
      fi
      cat "$HANDOFF_TMP/ship-gate-probe" >&2
      ship_error 'could not inspect ship-gate target'; return 1 ;;
  esac
  make -C "$SHIP_ROOT" ship-gate || { ship_error 'ship-gate failed; stopping before push'; return 1; }
}
ship_pr() {
  local prs
  prs=$(handoff_gh pr list --repo "$HANDOFF_REPO" --head "$SHIP_BRANCH" --state open --limit 100 --json number,url,headRefOid,baseRefName,isCrossRepository) || return 5
  SHIP_PR=$(printf '%s' "$prs" | jq -c --arg base "$SHIP_BASE" --arg repo "$HANDOFF_REPO" '
    if type!="array" or length>=100 then error("invalid PR listing")
    elif length==0 then null
    elif length==1 and .[0].baseRefName==$base and .[0].isCrossRepository==false and
      (.[0].headRefOid|test("^[a-f0-9]{40}$")) and (.[0].number|type)=="number" and .[0].number>0 and
      .[0].url==("https://github.com/"+$repo+"/pull/"+(.[0].number|tostring)) then .[0]
    else error("ambiguous PR or wrong base") end') || { ship_error "invalid PR listing or PR base differs from $SHIP_BASE"; return 3; }
  [ -n "$SHIP_PR" ] || return 3
}
ship_ci() {
  local listing latest
  listing=$(handoff_gh api "repos/$HANDOFF_REPO/actions/workflows/${REVIEW_WORKFLOW##*/}/runs?head_sha=$SHIP_HEAD&per_page=100") || return 5
  latest=$(printf '%s' "$listing" | jq -c --arg head "$SHIP_HEAD" --arg workflow "$REVIEW_WORKFLOW" '
    .workflow_runs | if type=="array" and length<100 then . else error("invalid run listing") end |
    if all(.[];(.id|type)=="number" and .id>0 and (.id|floor)==.id and
      (.created_at|type)=="string" and (.created_at|fromdateiso8601)>0 and
      (.head_sha|type)=="string" and (.path|type)=="string") then . else error("invalid runs") end |
    map(select(.head_sha==$head and (.path|split("@")[0])==$workflow)) | sort_by(.created_at,.id) | last') || {
      ship_error 'invalid policy workflow run listing'; return 5;
    }
  [ -n "$latest" ] || return 5
  [ "$latest" != null ] || { ship_error "no run for $SHIP_HEAD yet"; return 13; }
  SHIP_RUN_ID=$(printf '%s' "$latest" | jq -r .id)
  SHIP_RUN_URL="https://github.com/$HANDOFF_REPO/actions/runs/$SHIP_RUN_ID"
  SHIP_RUN=$(handoff_gh api "repos/$HANDOFF_REPO/actions/runs/$SHIP_RUN_ID") || return 5
  printf '%s' "$SHIP_RUN" | jq -e --arg repo "$HANDOFF_REPO" --arg head "$SHIP_HEAD" --arg workflow "$REVIEW_WORKFLOW" --argjson id "$SHIP_RUN_ID" '
    .id==$id and .repository.full_name==$repo and .head_sha==$head and (.path|split("@")[0])==$workflow and
    (.status=="queued" or .status=="in_progress" or .status=="completed" or .status=="waiting" or .status=="pending" or .status=="requested") and
    (.run_attempt|type)=="number" and .run_attempt>=1 and (.run_attempt|floor)==.run_attempt' >/dev/null || return 5
  SHIP_ATTEMPT=$(printf '%s' "$SHIP_RUN" | jq -r .run_attempt)
  [ "$(printf '%s' "$SHIP_RUN" | jq -r .status)" = completed ] || return 12
  [ "$(printf '%s' "$SHIP_RUN" | jq -r .conclusion)" = success ] || { ship_error "CI failed: $SHIP_RUN_URL attempt=$SHIP_ATTEMPT"; return 1; }
}
# Only the phase immediately after our push gets a registration grace period.
# 13 means no matching run yet; malformed responses and failed runs are fatal.
ship_wait_visibility() {
  local start rc
  start=$(date +%s)
  while :; do
    ship_pr || return $?
    if [ "$SHIP_PR" != null ] && [ "$(printf '%s' "$SHIP_PR" | jq -r .headRefOid)" = "$SHIP_HEAD" ]; then
      rc=0; ship_ci || rc=$?
      case "$rc" in 0|12) return 0 ;; 13) ;; *) return "$rc" ;; esac
    fi
    [ "$(( $(date +%s)-start ))" -lt 120 ] || {
      ship_error "PR head or policy CI run still not visible for $SHIP_HEAD after two minutes"; return 1;
    }
    sleep 10
  done
}

ship_wait_ci() {
  local timeout=$1 start rc elapsed delay
  start=$(date +%s)
  while :; do
    rc=0; ship_ci || rc=$?
    [ "$rc" -ne 13 ] || return 1
    if [ "$rc" -ne 12 ]; then return "$rc"; fi
    elapsed=$(( $(date +%s)-start ))
    delay=10
    # Timeouts longer than 18 digits cannot expire within the wall-clock range.
    if [ "${#timeout}" -le 18 ]; then
      [ "$elapsed" -lt "$timeout" ] || { ship_error "CI still running: $SHIP_RUN_URL"; return 1; }
      [ "$((timeout-elapsed))" -ge "$delay" ] || delay=$((timeout-elapsed))
    fi
    sleep "$delay"
  done
}
ship_lifecycle() {
  "$SHIP_ROOT/scripts/lifecycle-status.sh" --doc "$SHIP_DOC" --phase "$1" --check --verify-evidence
}
ship_final_approve() {
  local file=$1 note='' tracker rc=0 pr marker
  [ "$SHIP_PR" != null ] && [ "$(printf '%s' "$SHIP_PR" | jq -r .headRefOid)" = "$SHIP_HEAD" ] || return 3
  ship_ci || { rc=$?; [ "$rc" -eq 5 ] && return 5; return 3; }
  [ -z "$file" ] || { [ -f "$file" ] && [ "$(wc -c < "$file")" -le 240000 ] || return 2; note=$(cat "$file") || return 2; }
  tracker=$(sed -n 's/^- \*\*Tracking issue:\*\* url=//p' "$SHIP_DOC")
  case "$tracker" in "https://github.com/$HANDOFF_REPO/issues/"*) tracker=${tracker##*/} ;; *) return 3 ;; esac
  [[ "$tracker" =~ ^[1-9][0-9]*$ ]] || return 3
  handoff_identity reviewer || return $?
  pr=$(printf '%s' "$SHIP_PR" | jq -r .number)
  marker="agentic-flow-review: status=approved; pr=$pr; head=$SHIP_HEAD; run=$SHIP_RUN_URL; attempt=$SHIP_ATTEMPT; role=reviewer"
  journal_summary "$note" > "$HANDOFF_TMP/final-result" || return 5
  journal_render final-approve "PR #$pr — ${SHIP_HEAD:0:12} · attempt $SHIP_ATTEMPT" "$marker" \
    "Role: reviewer · [CI run]($SHIP_RUN_URL)" '' "$HANDOFF_TMP/final-result" > "$HANDOFF_TMP/final-comment" || return $?
  handoff_comment "$tracker" "$HANDOFF_TMP/final-comment"
}
ship_commit_close_out() {
  local closer=$1 dest="docs/done/${SHIP_DOC##*/}" staged head tracking untracked
  local -a paths=(docs/README.md "$dest" "$SHIP_DOC")
  # Include both ends of the move and compare NUL-delimited output so a
  # staged pathname cannot masquerade as part of the expected list.
  git diff --cached --name-only --no-renames -z > "$HANDOFF_TMP/staged-paths" || return 1
  if ! printf '%s\0' "${paths[@]}" | cmp -s "$HANDOFF_TMP/staged-paths" -; then
    ship_error 'staged paths differ from the prepared close-out'
    git diff --cached --name-status --no-renames >&2
    return 1
  fi
  untracked=$(git ls-files --others --exclude-standard) || return 1
  git diff --quiet && [ -z "$untracked" ] || {
    ship_error 'worktree changed during close-out preparation'; return 1;
  }
  staged=$(git write-tree) || return 1
  tracking=$(sed -n 's/^- \*\*Tracking issue:\*\* url=//p' "$dest")
  [[ "$tracking" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*$ ]] || return 1
  # The nested commit does not pass through the agent's PreToolUse hook.
  # Run the same staged scan here before invoking the configured wrapper.
  printf '%s\n' '{"tool_input":{"command":"git commit"}}' |
    "$SHIP_ROOT/scripts/hooks/scan-secrets.sh" || return 1
  if ! "$closer" commit -m "Close out $SHIP_TITLE." \
      -m "Record the approved steps and prepare the plan for final review on $tracking." -- "${paths[@]}"; then
    ship_error "close-out commit failed with $closer; prepared paths:"
    printf '  %s\n' "${paths[@]}" >&2
    return 1
  fi
  head=$(git rev-parse HEAD) || return 1
  if [ "$(git rev-list --parents -n 1 "$head")" != "$head $SHIP_HEAD" ] ||
     [ "$(git rev-parse "$head^{tree}")" != "$staged" ]; then
    ship_error 'closer did not create one commit matching the prepared index'
    return 1
  fi
  SHIP_DOC=$dest SHIP_HEAD=$head
  ship_clean
}

ship_pr_body() {
  local source="docs/inprogress/${SHIP_DOC##*/}" title goal
  close_out_load "$SHIP_ROOT" "$SHIP_DOC" "$HANDOFF_TMP" || return $?
  git merge-base --is-ancestor "$CLOSE_REV" "$SHIP_HEAD" &&
    git show "$CLOSE_REV:$source" > "$HANDOFF_TMP/approved-doc" || return 3
  git show "$SHIP_HEAD:$SHIP_DOC" > "$HANDOFF_TMP/shipped-doc" || return 3
  [ "$(brief_normalize < "$HANDOFF_TMP/approved-doc" | git hash-object --stdin)" = \
    "$(brief_normalize < "$HANDOFF_TMP/shipped-doc" | git hash-object --stdin)" ] || {
    ship_error 'closed document differs from the approved brief'; return 3;
  }
  title=$(awk '/^# / {print substr($0,3); exit}' "$HANDOFF_TMP/approved-doc")
  goal=$(awk '/^# / {exit} /^> / && !/^> \*\*(Type|Assurance):\*\*/ {print substr($0,3); exit}' "$HANDOFF_TMP/approved-doc")
  printf '%s\n' "$CLOSE_SPEC" > "$HANDOFF_TMP/pr-spec" || return 5
  jq -Rn --arg title "${title:-$SHIP_TITLE}" --arg goal "$goal" --arg repo "https://github.com/$HANDOFF_REPO" \
    --arg rev "$CLOSE_REV" --arg source "$source" --arg target "$CLOSE_TARGET" --slurpfile spec "$HANDOFF_TMP/pr-spec" '
    {pull_request:{title:$title,goal:$goal,brief:($repo+"/blob/"+$rev+"/"+$source),
      issue_root:($repo+"/issues"),tracker:($repo+"/issues/"+$target),
      steps:[inputs | split("\t") as $row | {
        title:($spec[0].steps[] | select(.id==$row[0]) | .title),
        issue:$row[1],head:$row[2],bounces:($row[4]|tonumber)
      }]}}' "$HANDOFF_TMP/steps" | journal_render_pr > "$HANDOFF_TMP/pr-body"
}

ship_run() {
  local wait_review=$1 start rc ref closer count=0
  ship_clean || return 1
  case "$SHIP_DOC" in docs/inprogress/*)
    if [ "$SHIP_PR" != null ]; then
      close_out_cmd prep "$SHIP_DOC" --pr "$(printf '%s' "$SHIP_PR" | jq -r .url)" || return $?
      printf 'commit the staged close-out, then run ship again\n'
      return 0
    fi
    close_out_cmd prep "$SHIP_DOC" || return $?
    closer=${AGENTIC_CLOSER_COMMIT-$(command -v git-claude || true)}
    if [ -z "$closer" ]; then
      printf 'commit the staged close-out, then run ship again\n'
      return 0
    fi
    ship_commit_close_out "$closer" || return $?
    ;;
  esac
  if [ "$SHIP_PR" = null ]; then ship_pr_body || return $?; fi
  ship_clean || return 1
  ship_gate || return 1
  ship_clean || return 1
  git push -- origin "$SHIP_HEAD:refs/heads/$SHIP_BRANCH" || return 1
  if [ "$SHIP_PR" = null ]; then
    handoff_gh pr create --repo "$HANDOFF_REPO" --head "$SHIP_BRANCH" --base "$SHIP_BASE" \
      --title "$SHIP_TITLE" --body-file "$HANDOFF_TMP/pr-body" || return 5
  fi
  ship_wait_visibility || return $?
  ship_wait_ci "$SHIP_CI_TIMEOUT" || return $?
  start=$(date +%s)
  while :; do
    rc=0; ship_lifecycle close-out > "$HANDOFF_TMP/lifecycle" 2>&1 || rc=$?
    cat "$HANDOFF_TMP/lifecycle"
    if [ "$rc" -eq 0 ] && grep -Eq '^READY[[:space:]]' "$HANDOFF_TMP/lifecycle"; then break; fi
    grep -q '^NEEDS-REVIEW ' "$HANDOFF_TMP/lifecycle" || return 1
    printf 'final-head approval needed: head=%s run=%s attempt=%s; markers for another head or attempt are stale.\nThe reviewer runs: agentic-flow final-approve %s\n' "$SHIP_HEAD" "$SHIP_RUN_URL" "$SHIP_ATTEMPT" "$SHIP_DOC"
    [ "$wait_review" = true ] && [ "$(( $(date +%s)-start ))" -lt 3600 ] || return 11
    sleep 10
    ship_pr || return $?
    [ "$(printf '%s' "$SHIP_PR" | jq -r .headRefOid)" = "$SHIP_HEAD" ] || return 1
    ship_ci || { ship_error "CI changed while waiting for review: $SHIP_RUN_URL"; return 1; }
  done
  close_out_cmd finish "$SHIP_DOC" || return $?
  ship_lifecycle pre-merge || return 1
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    git update-ref -d "$ref" || return 1
    count=$((count+1))
  done < <(git for-each-ref --format='%(refname)' "refs/agentic-flow/salvage/$SHIP_PLAN/")
  printf 'Deleted %s salvage refs.\nHuman merge: gh pr merge %s --repo %s\n' "$count" "$(printf '%s' "$SHIP_PR" | jq -r .number)" "$HANDOFF_REPO"
  printf 'After merge: agentic-flow clean %s\n' "$SHIP_PLAN"
}
ship_dispatch() (
  set +x
  local action=${1:-} doc=${2:-} wait_review=false file='' tmp approval spec moved SHIP_CI_TIMEOUT
  [ "$#" -ge 2 ] || return 2; shift 2
  while [ "$#" -gt 0 ]; do
    case "$action:$1" in ship:--wait-review) wait_review=true; shift ;;
      final-approve:--body-file) [ "$#" -ge 2 ] || return 2; file=$2; shift 2 ;; *) return 2 ;; esac
  done
  if [ "$action" = ship ]; then
    SHIP_CI_TIMEOUT=${AGENTIC_SHIP_CI_TIMEOUT-3600}
    if ! [[ "$SHIP_CI_TIMEOUT" =~ ^0*[1-9][0-9]*$ ]]; then
      ship_error 'AGENTIC_SHIP_CI_TIMEOUT must be a positive integer'
      return 2
    fi
    SHIP_CI_TIMEOUT=${SHIP_CI_TIMEOUT#"${SHIP_CI_TIMEOUT%%[!0]*}"}
  fi
  local SHIP_ROOT SHIP_DOC SHIP_BRANCH SHIP_BASE SHIP_PLAN SHIP_TITLE SHIP_HEAD SHIP_PR SHIP_RUN SHIP_RUN_ID SHIP_RUN_URL SHIP_ATTEMPT
  SHIP_ROOT=$(git rev-parse --show-toplevel) || return 3
  cd "$SHIP_ROOT" || return 3
  case "$doc" in docs/inprogress/*.md|docs/done/*.md) ;; *) return 2 ;; esac
  case "$doc" in *'/../'*|*'/./'*|*'//'*|*[!A-Za-z0-9_./-]*) return 2 ;; esac
  if [ ! -f "$doc" ]; then
    moved="docs/done/${doc##*/}"; [ -f "$moved" ] || return 3; doc=$moved
  fi
  [ ! -L "$doc" ] || return 3
  SHIP_DOC=$doc
  approval=$(brief_approval "$doc") || return 3
  spec=$(brief_parse "$doc" "$doc" "${approval%%$'\t'*}") || return 3
  SHIP_BRANCH=$(printf '%s' "$spec" | jq -r .branch)
  SHIP_BASE=$(printf '%s' "$spec" | jq -r '.base//"main"')
  git check-ref-format "refs/heads/$SHIP_BRANCH" && git check-ref-format "refs/heads/$SHIP_BASE" || return 3
  SHIP_PLAN=$(printf '%s' "$spec" | jq -r .id)
  SHIP_TITLE=$(awk '/^# / {sub(/^# (Feature|Security Review) — /,""); sub(/^# /,""); print; exit}' "$doc")
  [ -n "$SHIP_TITLE" ] || SHIP_TITLE=$(printf '%s' "$spec" | jq -r '.tracking.title//.steps[0].title')
  [ "$(git symbolic-ref --short HEAD)" = "$SHIP_BRANCH" ] || return 3
  SHIP_HEAD=$(git rev-parse HEAD) || return 3
  workflow_load "$SHIP_ROOT" && read_review_policy "$SHIP_ROOT" || return 3
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/agentic-ship.XXXXXX") || return 5
  trap 'rm -rf "$tmp"' EXIT
  HANDOFF_ROOT=$SHIP_ROOT HANDOFF_TMP=$tmp HANDOFF_PLAN=$SHIP_PLAN HANDOFF_TOKEN=''
  HANDOFF_REPO=$(identity_repository "$SHIP_ROOT") || return 3
  case "$action" in final-approve) ship_pr && ship_final_approve "$file" ;; ship)
    ledger_init "$SHIP_ROOT" || return 5
    jq -n --arg plan "$SHIP_PLAN" --arg ship "ship-$$-$(date +%s)-$(printf '%s' "${tmp##*.}" | tr '[:upper:]' '[:lower:]')" '{v:1,kind:"ship",plan:$plan,ship:$ship,at:(now|floor)}' > "$tmp/touch"
    ledger_ship "$SHIP_PLAN" "$tmp/touch" >/dev/null || return 5
    ship_pr || return $?
    ship_run "$wait_review" ;; *) return 2 ;; esac
)

ship_cmd() {
  local action=${1:-} rc=0
  ship_dispatch "$@" || rc=$?
  if [ "$action" = ship ]; then
    case "$rc" in 0|2|5|11) ;; *) rc=1 ;; esac
  fi
  return "$rc"
}
