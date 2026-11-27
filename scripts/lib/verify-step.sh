#!/usr/bin/env bash
# shellcheck disable=SC2031 # Sourced adapter subshell locals do not mutate this command.
# Commit-bound verification. Commands are trusted project recipes from the brief.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/brief.sh"
. "$(dirname "${BASH_SOURCE[0]}")/verify-record.sh"
. "$(dirname "${BASH_SOURCE[0]}")/ledger.sh"

verify_cleanup() {
  [ -z "${VERIFY_TIMER:-}" ] || kill "$VERIFY_TIMER" 2>/dev/null || true
  [ -z "${VERIFY_PID:-}" ] || kill -TERM -- "-$VERIFY_PID" 2>/dev/null || true
  [ -z "${VERIFY_WT:-}" ] || git worktree remove --force "$VERIFY_WT" >/dev/null 2>&1 || true
  [ -z "${VERIFY_TMP:-}" ] || rm -rf "$VERIFY_TMP"
}

verify_run() { # directory, command; result in VERIFY_RESULT
  local directory=$1 command=$2 role=${3:-green} start=$SECONDS status=0 timer digest
  local ack='' policy=${VERIFY_BUDGET_DIGEST:-pre-ack}
  local -a recipe
  recipe=(bash -o pipefail -c "$command")
  if [ "$role" = red-first ] && [[ "$command" =~ ^([a-z][a-z-]*):([a-z]+)$ ]]; then
    recipe=(scripts/self-test.sh --only "${BASH_REMATCH[1]}" --scenario "${BASH_REMATCH[2]}")
  fi
  # setsid ensures timeout/interrupt terminates the whole recipe process tree.
  (cd "$directory" && exec perl -MPOSIX=setsid -e 'setsid() or die $!; exec @ARGV' "${recipe[@]}") > "$VERIFY_TMP/output" 2>&1 &
  VERIFY_PID=$!
  perl -e '
    my ($limit,$pid,$marker)=@ARGV;
    sleep $limit;
    exit unless kill 0,$pid;
    open my $fh, ">", $marker or die $!; close $fh;
    kill "TERM", -$pid;
    sleep 1;
    kill "KILL", -$pid;
  ' "$VERIFY_LIMIT" "$VERIFY_PID" "$VERIFY_TMP/timed-out" & timer=$!
  VERIFY_TIMER=$timer
  wait "$VERIFY_PID" || status=$?
  if [ ! -f "$VERIFY_TMP/timed-out" ]; then kill "$timer" 2>/dev/null || true; fi
  wait "$timer" 2>/dev/null || true
  VERIFY_PID='' VERIFY_TIMER=''
  if [ -f "$VERIFY_TMP/timed-out" ]; then
    # The timer can race with successful completion, so preserve success.
    # A terminated command can handle TERM and exit normally with a nonzero
    # status (including make); the watchdog marker still records a timeout.
    [ "$status" -eq 0 ] || status=124
    rm "$VERIFY_TMP/timed-out"
  fi
  digest=$(shasum -a 256 "$VERIFY_TMP/output"); digest=${digest%% *}
  : > "$VERIFY_TMP/output-tail"
  if [ "$status" -ne 0 ]; then
    ledger_output_tail "$VERIFY_TMP/output" 65536 > "$VERIFY_TMP/output-tail" || return 1
  fi
  cat "$VERIFY_TMP/output" >&2
  if [ "$policy" = "${VERIFY_PRE_ACK:-pre-ack}" ]; then
    policy=pre-ack
  else
    if ! ack=$(awk -v digest="$policy" '
      /^budget-policy:/ {
        if ($0 != "budget-policy: " digest) { invalid=1; exit }
        seen=1
      }
      END { if (invalid) exit 1; if (seen) print digest }
    ' "$VERIFY_TMP/output"); then
      echo "verify-step: $command acknowledged a different budget policy" >&2
      return 1
    fi
    if [ "$role" = green ] && [ "$command" = 'make check' ] && [ -z "$ack" ]; then
      echo 'verify-step: make check did not acknowledge the budget policy' >&2
      return 1
    fi
  fi
  VERIFY_RESULT=$(jq -n --rawfile tail "$VERIFY_TMP/output-tail" --arg cmd "$command" --arg role "$role" --argjson exit "$status" --argjson seconds "$((SECONDS-start))" --arg digest "$digest" --arg ack "$ack" --arg policy "$policy" \
    '{cmd:$cmd,role:$role,exit:$exit,seconds:$seconds,output_sha256:$digest,policy:$policy,
     budget_ack:(if $ack=="" then null else $ack end)} + (if $exit!=0 then {output_tail:$tail} else {} end)')
  printf '%s\n' "$VERIFY_RESULT" > "$VERIFY_TMP/command-result"
}

verify_step_cmd() {
  [ "$#" -ge 1 ] || return 2
  local sha=$1 doc='' step='' red_base='' json=false force=false root common rev='' spec='' selected='' first='' issue='' issues='' number=''
  local signature_sha key command_plan overrides green_budget red_index=0 VERIFY_BUDGET_DIGEST VERIFY_PRE_ACK
  local commands='[]' prepare='{"cmd":"skipped","role":"prepare","exit":0,"seconds":0,"budget_ack":null}' reds='"not-declared"' passed=true signature='' selector paths path status result verify started record
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --doc|--step|--red-base)
        [ "$#" -ge 2 ] || return 2
        case "$1" in --doc) doc=$2 ;; --step) step=$2 ;; --red-base) red_base=$2 ;; esac
        shift 2 ;;
      --json) json=true; shift ;;
      --force) force=true; shift ;;
      *) echo "unknown verify-step flag: $1" >&2; return 2 ;;
    esac
  done
  [ -z "$doc$step" ] || { [ -n "$doc" ] && [ -n "$step" ]; } || return 2
  case "$doc" in /*|../*|*/../*|*/..) return 2 ;; esac
  VERIFY_LIMIT=${AGENTIC_VERIFY_TIMEOUT:-1800}
  [[ "$VERIFY_LIMIT" =~ ^[1-9][0-9]{0,4}$ ]] || return 2
  command -v perl >/dev/null && command -v shasum >/dev/null || return 1
  root=$(git rev-parse --show-toplevel) || return 1
  cd "$root" || return 1
  sha=$(git rev-parse --verify --end-of-options "$sha^{commit}") || return 2
  if [ -n "$red_base" ]; then
    red_base=$(git rev-parse --verify --end-of-options "$red_base^{commit}") || return 2
  fi
  common=$(git rev-parse --git-common-dir); common=$(cd "$common" && pwd -P)
  VERIFY_TMP=$(mktemp -d "${TMPDIR:-/tmp}/agentic-verify.XXXXXX") || return 1
  VERIFY_WT='' VERIFY_PID='' VERIFY_TIMER=''
  local verify_status=0
  trap 'verify_status=$?; verify_cleanup; exit "$verify_status"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ -n "$doc" ]; then
    git show "$sha:$doc" > "$VERIFY_TMP/doc" || return 1
    # Read the journal, never infer the first implementation commit from HEAD^.
    # shellcheck disable=SC1091
    . "$root/scripts/lib/handoff.sh"
    # shellcheck disable=SC2034 # Consumed by the sourced handoff adapter.
    HANDOFF_ROOT=$root HANDOFF_TMP=$VERIFY_TMP HANDOFF_TOKEN=''
    HANDOFF_REPO=$(identity_repository "$root") || return 1
    workflow_load "$root" && read_review_policy "$root" || return 1
    spec=$(brief_parse "$VERIFY_TMP/doc" "$doc" "$sha") || return 1
    local plan
    plan=$(printf '%s' "$spec" | jq -r .id)
    # shellcheck disable=SC2034 # handoff_read validates membership against this plan.
    HANDOFF_PLAN=$plan
    local approver page
    issues='[]'
    while IFS= read -r approver; do
      page=$(handoff_gh issue list --repo "$HANDOFF_REPO" --state all --search "agentic-flow:plan:$plan in:body author:$approver" --limit 100 --json number,body,author) || return 1
      [ "$(printf '%s' "$page" | jq length)" -lt 100 ] || { echo 'issue discovery reached limit' >&2; return 1; }
      issues=$(printf '%s' "$issues" | jq --argjson page "$page" --arg login "$approver" '.+($page|map(select((.author.login + (if .author.is_bot==true and (.author.login|endswith("[bot]")|not) then "[bot]" else "" end))==$login)))|unique_by(.number)') || return 1
    done < <(printf '%s\n' "$REVIEW_APPROVERS" | tr ' ' '\n' | sed '/^$/d')
    while IFS= read -r number; do
      issue=$(printf '%s' "$issues" | jq -r --argjson n "$number" '.[]|select(.number==$n)|.body')
      if printf '%s' "$issue" | journal_stamp 2>/dev/null | jq -e --arg p "$plan" --arg s "$step" '.plan==$p and .step==$s' >/dev/null; then
        [ -z "$first" ] || { echo 'ambiguous step issue' >&2; return 1; }
        handoff_read "$number" || return 1
        first=$(printf '%s' "$HANDOFF_REPLAY" | jq -r '[.accepted[]|select(.event=="submit")][0].head//empty') || return 1
        # The controller verifies before the first submit. An explicit base is
        # required there; ordinary post-submit callers retain the journal base.
        if [ -z "$first" ]; then
          [ -n "$red_base" ] && [ "$(printf '%s' "$HANDOFF_REPLAY" | jq -r .state)" = executing ] || {
            echo 'step requires a journaled submit or an executing step with --red-base' >&2; return 1;
          }
          git merge-base --is-ancestor "$red_base" "$sha" || return 1
          first=$sha
        fi
        rev=$(printf '%s' "$issue" | sed -n 's/.* approved=\([a-f0-9]\{40\}\).*/\1/p')
        # shellcheck disable=SC2016 # Match literal Markdown backticks.
        if [ -z "$rev" ]; then rev=$(printf '%s' "$issue" | sed -n 's/.*approved revision `\([a-f0-9]\{40\}\)`.*/\1/p'); fi
      fi
    done < <(printf '%s' "$issues" | jq -r '.[].number')
    [ -n "$first" ] && [ -n "$rev" ] || { echo 'step requires a journaled submit and approved revision' >&2; return 1; }
    git merge-base --is-ancestor "$first" "$sha" || return 1
    git show "$rev:$doc" > "$VERIFY_TMP/doc" || return 1
    spec=$(brief_parse "$VERIFY_TMP/doc" "$doc" "$rev") || return 1
    selected=$(printf '%s' "$spec" | jq -ec --arg s "$step" '.steps[]|select(.id==$s)') || return 1
    [ -n "$red_base" ] || red_base=$(git rev-parse --verify --end-of-options "$first^") || return 2
  fi
  if [ -z "$red_base" ]; then
    # A root commit is valid when no red-first commands were requested.
    red_base=$(git rev-parse --verify --end-of-options "$sha^" 2>/dev/null) || red_base=''
  fi
  command_plan=$(verify_record_plan "$selected") || return 1
  printf '%s' "$command_plan" | jq -e '(.green|length)+2*(.red_first|length)+1<=100' >/dev/null || {
    echo 'verify command plan exceeds 100 commands' >&2; return 1;
  }
  overrides=$(budget_capture "$root" "$sha") || return 1
  key=$(verify_record_key "$sha" "$doc" "$step" "$red_base" "$command_plan" "$overrides") || return 1
  if [ "$force" = false ] && record=$(verify_record_fresh "$common/agentic-flow/verify/$sha.json" "$key"); then
    echo "verify-step $sha: reused ($common/agentic-flow/verify/$sha.json)" >&2
    if [ "$json" = true ]; then printf '%s\n' "$record"; fi
    return 0
  fi
  local AGENTIC_FLOW_BUDGET_POLICY=$overrides
  export AGENTIC_FLOW_BUDGET_POLICY
  green_budget=$(jq -er .budget_policy.green <<< "$key") || return 1
  VERIFY_BUDGET_DIGEST=$green_budget
  VERIFY_PRE_ACK=$(printf pre-ack | shasum -a 256) || return 1
  VERIFY_PRE_ACK=${VERIFY_PRE_ACK%% *}
  local green_policy=$green_budget
  if [ "$green_budget" = "$VERIFY_PRE_ACK" ]; then green_policy=pre-ack; fi
  prepare=$(jq --arg policy "$green_policy" '.policy=$policy' <<< "$prepare") || return 1
  if [ "${AGENTIC_VERIFY_TESTING:-}" = 1 ] && [ -n "${AGENTIC_VERIFY_PAUSE:-}" ]; then
    local waited=0
    : > "$AGENTIC_VERIFY_PAUSE.ready"
    while [ ! -f "$AGENTIC_VERIFY_PAUSE.release" ] && [ "$waited" -lt 300 ]; do sleep 0.1; waited=$((waited+1)); done
    [ -f "$AGENTIC_VERIFY_PAUSE.release" ] || return 1
  fi
  signature_sha=$(printf '%s' "$key" | jq -r .verifier.signature_source.sha)
  started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  VERIFY_WT="$VERIFY_TMP/worktree"
  git worktree add --quiet --detach "$VERIFY_WT" "$signature_sha" || return 1
  # The project assertion contract comes from committed HEAD (also for older
  # step commits predating this station). Dirty Makefile bytes are never read.
  # Query make variables through stdin; do not reparse Make syntax in shell.
  signature=$(cd "$VERIFY_WT" && make --no-print-directory -s -f Makefile -f - agentic-verify-signature <<'MAKE'
.PHONY: agentic-verify-signature
export RED_FIRST_SIGNATURE
agentic-verify-signature:
	@printenv RED_FIRST_SIGNATURE || true
MAKE
  ) || return 1
  git worktree remove --force "$VERIFY_WT" || return 1
  git worktree add --quiet --detach "$VERIFY_WT" "$sha" || return 1
  if (cd "$VERIFY_WT" && make -n verify-prepare >/dev/null 2>&1); then
    verify_run "$VERIFY_WT" 'make verify-prepare' prepare || return 1; prepare=$VERIFY_RESULT
    commands=$(printf '%s' "$commands" | jq --slurpfile r "$VERIFY_TMP/command-result" '.+[$r[0]]')
    [ "$(printf '%s' "$prepare" | jq .exit)" = 0 ] || passed=false
  fi
  verify_run "$VERIFY_WT" 'make check' || return 1
  commands=$(printf '%s' "$commands" | jq --slurpfile r "$VERIFY_TMP/command-result" '.+[$r[0]]')
  [ "$(printf '%s' "$VERIFY_RESULT" | jq .exit)" = 0 ] || passed=false
  if [ -n "$selected" ]; then
    while IFS= read -r verify; do
      verify_run "$VERIFY_WT" "$verify" || return 1
      commands=$(printf '%s' "$commands" | jq --slurpfile r "$VERIFY_TMP/command-result" '.+[$r[0]]')
      [ "$(printf '%s' "$VERIFY_RESULT" | jq .exit)" = 0 ] || passed=false
    done < <(printf '%s' "$selected" | jq -r '.packet.verification|split("\n")[0]|scan("`([^`]+)`")|.[0]')
    if [ "$(printf '%s' "$selected" | jq -r '.red_first|type')" = array ]; then
      reds='[]'
      while IFS= read -r result; do
        VERIFY_BUDGET_DIGEST=$(jq -er --argjson i "$red_index" '.budget_policy.red[$i]' <<< "$key") || return 1
        red_index=$((red_index+1))
        git worktree remove --force "$VERIFY_WT" || return 1
        git worktree add --quiet --detach "$VERIFY_WT" "$red_base" || return 1
        paths=$(printf '%s' "$result" | jq -c .paths)
        while IFS= read -r path; do
          git -C "$VERIFY_WT" restore --source="$sha" --staged --worktree -- "$path" || return 1
        done < <(printf '%s' "$paths" | jq -r '.[]')
        if (cd "$VERIFY_WT" && make -n verify-prepare >/dev/null 2>&1); then
          verify_run "$VERIFY_WT" 'make verify-prepare' prepare || return 1
          commands=$(printf '%s' "$commands" | jq --slurpfile r "$VERIFY_TMP/command-result" '.+[$r[0]]')
          [ "$(printf '%s' "$VERIFY_RESULT" | jq .exit)" = 0 ] || passed=false
        fi
        selector=$(printf '%s' "$result" | jq -r .selector)
        verify_run "$VERIFY_WT" "$selector" red-first || return 1
        commands=$(printf '%s' "$commands" | jq --slurpfile r "$VERIFY_TMP/command-result" '.+[$r[0]]')
        status=$(printf '%s' "$VERIFY_RESULT" | jq .exit)
        if [ "$status" = 0 ]; then status=green
        elif [ "$status" != 124 ] && [ "$status" != 130 ] && [ "$status" != 143 ] && [ -n "$signature" ] && grep -Eq -- "$signature" "$VERIFY_TMP/output"; then status=red
        else status=invalid; fi
        [ "$status" = red ] || passed=false
        ledger_output_tail "$VERIFY_TMP/output" 65536 > "$VERIFY_TMP/red-output" || return 1
        tail -40 "$VERIFY_TMP/red-output" > "$VERIFY_TMP/tail"
        reds=$(printf '%s' "$reds" | jq --arg selector "$selector" --argjson paths "$paths" --slurpfile r "$VERIFY_TMP/command-result" --arg status "$status" --rawfile tail "$VERIFY_TMP/tail" \
          '.+[{selector:$selector,paths:$paths,exit:$r[0].exit,status:$status,policy:$r[0].policy,budget_ack:$r[0].budget_ack,
            tail:($tail|split("\n")|if .[-1]=="" then .[:-1] else . end)}]')
      done < <(printf '%s' "$selected" | jq -c '.red_first[]')
    fi
  fi
  printf '%s\n' "$commands" > "$VERIFY_TMP/commands"
  printf '%s\n' "$prepare" > "$VERIFY_TMP/prepare"
  printf '%s\n' "$reds" > "$VERIFY_TMP/reds"
  record=$(printf '%s' "$key" | jq --arg started "$started" --arg signature "$signature" --argjson passed "$passed" \
    --slurpfile commands "$VERIFY_TMP/commands" --slurpfile prepare "$VERIFY_TMP/prepare" --slurpfile reds "$VERIFY_TMP/reds" \
    '.+{started:$started,passed:$passed,commands:$commands[0],red_first:$reds[0],prepare:$prepare[0]} |
      .verifier.signature_source.pattern=$signature') || return 1
  mkdir -p "$common/agentic-flow/verify"
  printf '%s\n' "$record" > "$VERIFY_TMP/record"
  [ "$(wc -c < "$VERIFY_TMP/record")" -le 8388608 ] || { echo 'verify record exceeds 8 MiB cap' >&2; return 1; }
  # Rename a same-filesystem temporary file for atomic publication.
  local pending
  pending=$(mktemp "$common/agentic-flow/verify/.record.XXXXXX") || return 1
  cat "$VERIFY_TMP/record" > "$pending"
  mv "$pending" "$common/agentic-flow/verify/$sha.json"
  if [ "$json" = true ]; then printf '%s\n' "$record"; else echo "verify-step $sha: $passed ($common/agentic-flow/verify/$sha.json)"; fi
  [ "$passed" = true ]
}
