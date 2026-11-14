#!/usr/bin/env bash
# shellcheck disable=SC2031 # Sourced adapter subshell locals do not mutate this command.
# Commit-bound verification. Commands are trusted project recipes from the brief.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/brief.sh"

verify_cleanup() {
  [ -z "${VERIFY_TIMER:-}" ] || kill "$VERIFY_TIMER" 2>/dev/null || true
  [ -z "${VERIFY_PID:-}" ] || kill -TERM -- "-$VERIFY_PID" 2>/dev/null || true
  [ -z "${VERIFY_WT:-}" ] || git worktree remove --force "$VERIFY_WT" >/dev/null 2>&1 || true
  [ -z "${VERIFY_TMP:-}" ] || rm -rf "$VERIFY_TMP"
}

verify_run() { # directory, command; result in VERIFY_RESULT
  local directory=$1 command=$2 start=$SECONDS status=0 timer digest
  # setsid ensures timeout/interrupt terminates the whole recipe process tree.
  (cd "$directory" && exec perl -MPOSIX=setsid -e 'setsid() or die $!; exec @ARGV' bash -o pipefail -c "$command") > "$VERIFY_TMP/output" 2>&1 &
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
    # A timer may observe an exited, unreaped child. Preserve a normal exit;
    # only a child terminated by our TERM/KILL is a timed-out command.
    case "$status" in 137|143) status=124 ;; esac
    rm "$VERIFY_TMP/timed-out"
  fi
  digest=$(shasum -a 256 "$VERIFY_TMP/output"); digest=${digest%% *}
  VERIFY_RESULT=$(jq -n --arg cmd "$command" --argjson exit "$status" --argjson seconds "$((SECONDS-start))" --arg digest "$digest" \
    '{cmd:$cmd,exit:$exit,seconds:$seconds,output_sha256:$digest}')
  cat "$VERIFY_TMP/output" >&2
}

verify_step_cmd() {
  [ "$#" -ge 1 ] || return 2
  local verify_source
  verify_source=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/${BASH_SOURCE[0]##*/}
  local sha=$1 doc='' step='' red_base='' json=false root common rev='' spec='' selected='' first='' issue='' issues='' number=''
  local implementation_hash signature_sha signature_tree
  local commands='[]' prepare='{"cmd":"skipped","exit":0,"seconds":0}' reds='"not-declared"' passed=true signature='' selector paths path status result verify started tree version tools record
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --doc|--step|--red-base)
        [ "$#" -ge 2 ] || return 2
        case "$1" in --doc) doc=$2 ;; --step) step=$2 ;; --red-base) red_base=$2 ;; esac
        shift 2 ;;
      --json) json=true; shift ;;
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
        first=$(printf '%s' "$HANDOFF_REPLAY" | jq -er '[.accepted[]|select(.event=="submit")][0].head') || return 1
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
    [ -n "$red_base" ] || red_base="$first^"
  fi
  if [ -n "$red_base" ]; then
    red_base=$(git rev-parse --verify --end-of-options "$red_base^{commit}") || return 2
  else
    # A root commit is valid when no red-first commands were requested.
    red_base=$(git rev-parse --verify --end-of-options "$sha^" 2>/dev/null) || red_base=''
  fi
  tree=$(git rev-parse "$sha^{tree}") || return 1
  implementation_hash=$(shasum -a 256 "$verify_source") || return 1
  implementation_hash=${implementation_hash%% *}
  signature_sha=$(git rev-parse HEAD) || return 1
  signature_tree=$(git rev-parse "$signature_sha^{tree}") || return 1
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
  version=$(cat "$VERIFY_WT/.agentic-flow-version" 2>/dev/null || printf unknown)
  if (cd "$VERIFY_WT" && make -n verify-prepare >/dev/null 2>&1); then
    verify_run "$VERIFY_WT" 'make verify-prepare'; prepare=$VERIFY_RESULT
    [ "$(printf '%s' "$prepare" | jq .exit)" = 0 ] || passed=false
  fi
  verify_run "$VERIFY_WT" 'make check'
  commands=$(printf '%s' "$commands" | jq --argjson r "$VERIFY_RESULT" '.+[$r]')
  [ "$(printf '%s' "$VERIFY_RESULT" | jq .exit)" = 0 ] || passed=false
  if [ -n "$selected" ]; then
    while IFS= read -r verify; do
      verify_run "$VERIFY_WT" "$verify"
      commands=$(printf '%s' "$commands" | jq --argjson r "$VERIFY_RESULT" '.+[$r]')
      [ "$(printf '%s' "$VERIFY_RESULT" | jq .exit)" = 0 ] || passed=false
    done < <(printf '%s' "$selected" | jq -r '.packet.verification|split("\n")[0]|scan("`([^`]+)`")|.[0]')
    if [ "$(printf '%s' "$selected" | jq -r '.red_first|type')" = array ]; then
      reds='[]'
      while IFS= read -r result; do
        git worktree remove --force "$VERIFY_WT" || return 1
        git worktree add --quiet --detach "$VERIFY_WT" "$red_base" || return 1
        paths=$(printf '%s' "$result" | jq -c .paths)
        while IFS= read -r path; do
          git -C "$VERIFY_WT" restore --source="$sha" --staged --worktree -- "$path" || return 1
        done < <(printf '%s' "$paths" | jq -r '.[]')
        if (cd "$VERIFY_WT" && make -n verify-prepare >/dev/null 2>&1); then
          verify_run "$VERIFY_WT" 'make verify-prepare'
          commands=$(printf '%s' "$commands" | jq --argjson r "$VERIFY_RESULT" '.+[$r]')
          [ "$(printf '%s' "$VERIFY_RESULT" | jq .exit)" = 0 ] || passed=false
        fi
        selector=$(printf '%s' "$result" | jq -r .selector)
        verify_run "$VERIFY_WT" "$selector"
        commands=$(printf '%s' "$commands" | jq --argjson r "$VERIFY_RESULT" '.+[$r]')
        status=$(printf '%s' "$VERIFY_RESULT" | jq .exit)
        if [ "$status" = 0 ]; then status=green
        elif [ "$status" = 1 ] && [ -n "$signature" ] && grep -Eq -- "$signature" "$VERIFY_TMP/output"; then status=red
        else status=invalid; fi
        [ "$status" = red ] || passed=false
        tail -40 "$VERIFY_TMP/output" > "$VERIFY_TMP/tail"
        reds=$(printf '%s' "$reds" | jq --arg selector "$selector" --argjson paths "$paths" --argjson r "$VERIFY_RESULT" --arg status "$status" --rawfile tail "$VERIFY_TMP/tail" \
          '.+[{selector:$selector,paths:$paths,exit:$r.exit,status:$status,tail:($tail|split("\n")|if .[-1]=="" then .[:-1] else . end)}]')
      done < <(printf '%s' "$selected" | jq -c '.red_first[]')
    fi
  fi
  tools=$(jq -n --arg bash "$BASH_VERSION" --arg git "$(git --version)" --arg make "$(make --version | head -1)" --arg jq "$(jq --version)" '{bash:$bash,git:$git,make:$make,jq:$jq}')
  record=$(jq -n --arg sha "$sha" --arg tree "$tree" --arg red_base "$red_base" --arg version "$version" --arg started "$started" \
    --arg implementation "$implementation_hash" --arg signature_sha "$signature_sha" --arg signature_tree "$signature_tree" --arg signature "$signature" --argjson timeout "$VERIFY_LIMIT" \
    --argjson commands "$commands" --argjson prepare "$prepare" --argjson reds "$reds" --argjson tools "$tools" \
    '{v:1,sha:$sha,tree:$tree,red_base:$red_base,harness_version:$version,started:$started,commands:$commands,red_first:$reds,prepare:$prepare,tools:$tools,verifier:{implementation_sha256:$implementation,timeout_seconds:$timeout,signature_source:{sha:$signature_sha,tree:$signature_tree,pattern:$signature}}}')
  mkdir -p "$common/agentic-flow/verify"
  printf '%s\n' "$record" > "$VERIFY_TMP/record"
  # Rename a same-filesystem temporary file for atomic publication.
  local pending
  pending=$(mktemp "$common/agentic-flow/verify/.record.XXXXXX") || return 1
  cat "$VERIFY_TMP/record" > "$pending"
  mv "$pending" "$common/agentic-flow/verify/$sha.json"
  if [ "$json" = true ]; then printf '%s\n' "$record"; else echo "verify-step $sha: $passed ($common/agentic-flow/verify/$sha.json)"; fi
  [ "$passed" = true ]
}
