#!/usr/bin/env bash
# shellcheck disable=SC2034 # Globals consumed by lifecycle attestation.
# Shared journal admission and deterministic close-out preparation.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/handoff.sh"
. "$(dirname "${BASH_SOURCE[0]}")/brief.sh"

close_out_error() { printf 'close-out: %s\n' "$*" >&2; }

close_out_load() { # root doc tmp; read-only, all decisions come from replay
  local root=$1 doc=$2 tmp=$3 approval spec profile plan n step body stamp state expected count=0 target=''
  workflow_load "$root" && read_review_policy "$root" || return 3
  approval=$(brief_approval "$root/$doc") || return 3
  CLOSE_REV=${approval%%$'\t'*}
  spec=$(brief_parse "$root/$doc" "$doc" "$CLOSE_REV") || return 3
  profile=$(printf '%s' "$spec" | jq -r .profile)
  plan=$(printf '%s' "$spec" | jq -r .id)
  # shellcheck disable=SC2034 # Shared read-only GitHub adapter context.
  HANDOFF_ROOT=$root HANDOFF_TOKEN='' HANDOFF_PLAN=$plan HANDOFF_TMP=$tmp
  HANDOFF_REPO=$(identity_repository "$root") || return 3
  handoff_plan_read || return $?
  : > "$tmp/steps"
  while IFS= read -r step; do
    count=0
    for n in $HANDOFF_ISSUES; do
      body=$(jq -r .body "$tmp/$n.issue")
      stamp=$(printf '%s' "$body" | journal_stamp_lines body) || return 3
      [ "$(printf '%s' "$stamp" | jq -r .step)" = "$step" ] || continue
      count=$((count+1))
      [ "$(printf '%s' "$stamp" | jq -r .approved)" = "$CLOSE_REV" ] || {
        close_out_error "#$n lacks the approved revision stamp"; return 3;
      }
      printf '%s\n' "$body" | grep -Fxq "<!-- agentic-flow:topology:$profile -->" || {
        close_out_error 'legacy or mismatched topology; close out by hand'; return 3;
      }
      journal_context "$body" || return 3
      expected="step-strict"
      [ "$profile" != standard ] || expected=work-standard
      [ "$JOURNAL_TOPOLOGY" = "$expected" ] || { close_out_error 'legacy or mismatched topology; close out by hand'; return 3; }
      state=$(jq -r .state "$tmp/$n.replay")
      expected=approved
      [ "$profile" != standard ] || { expected=${CLOSE_TARGET_STATE:-closing}; target=$n; }
      [ "$state" = "$expected" ] || { close_out_error "#$n journal state $state; expected $expected"; return 3; }
      jq -e 'any(.accepted[];.event=="approve")' "$tmp/$n.replay" >/dev/null || return 3
      jq -r --arg step "$step" --argjson issue "$n" '
        [$step, $issue, ([.accepted[]|select(.event=="approve")]|last|.head),
         ([.accepted[]|select(.event=="submit")|.head]|unique|join(",")),
         ([.accepted[]|select(.event=="bounce")]|length)] | @tsv' "$tmp/$n.replay" >> "$tmp/steps" || return 3
    done
    [ "$count" = 1 ] || { close_out_error "expected exactly one issue for $step"; return 3; }
  done < <(printf '%s' "$spec" | jq -r '.steps[].id')
  expected=$(printf '%s' "$spec" | jq '.steps|length')
  [ "$profile" != strict ] || expected=$((expected+1))
  [ "$(printf '%s\n' "$HANDOFF_ISSUES" | wc -w | tr -d ' ')" = "$expected" ] || {
    close_out_error 'plan discovery differs from declared steps'; return 3;
  }
  if [ "$profile" = strict ]; then
    target=$HANDOFF_TRACKER
    if [ -z "$target" ] || ! jq -r .body "$tmp/$target.issue" | grep -Fxq '<!-- agentic-flow:topology:strict -->'; then
      close_out_error 'legacy tracker topology; close out by hand'; return 3
    fi
    [ -n "$target" ] && [ "$(jq -r .state "$tmp/$target.replay")" = "${CLOSE_TARGET_STATE:-closing}" ] || {
      close_out_error 'tracker journal must be closing'; return 3;
    }
  fi
  CLOSE_TARGET=$target CLOSE_SPEC=$spec
}

close_out_cmd() (
  local action=${1:-} doc=${2:-} pr='' pr_source=source=final-approval dry=false root tmp dest tracking dirty
  [ "$#" -ge 2 ] || return 2
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pr) [ "$#" -ge 2 ] && [ -n "$2" ] || return 2; pr=$2; shift 2 ;;
      --dry-run) dry=true; shift ;;
      *) return 2 ;;
    esac
  done
  case "$action" in prep|finish) ;; *) return 2 ;; esac
  case "$doc" in docs/inprogress/*.md|docs/done/*.md) ;; *) return 2 ;; esac
  case "$doc" in *'/../'*|*'/./'*|*'//'*) return 2 ;; esac
  root=$(git rev-parse --show-toplevel) || return 3
  cd "$root" || return 3
  [ -f "$doc" ] && [ ! -L "$doc" ] || return 3
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/agentic-close-out.XXXXXX") || return 3
  trap 'rm -rf "$tmp"' EXIT
  if [ "$action" = finish ]; then
    [ -z "$pr" ] && [ "$dry" = false ] || return 2
    "$root/scripts/lifecycle-status.sh" --doc "$doc" --phase close-out --check --verify-evidence > "$tmp/lifecycle" || { cat "$tmp/lifecycle"; return 3; }
    cat "$tmp/lifecycle"
    grep -Eq '^READY[[:space:]]' "$tmp/lifecycle" || { close_out_error 'lifecycle did not reach READY'; return 3; }
    tracking=$(sed -n 's/^- \*\*Tracking issue:\*\* url=//p' "$doc")
    [[ "$tracking" =~ ^https://github.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*$ ]] || return 3
    handoff_cmd "${tracking##*/}" close --as approver
    return $?
  fi
  if [ -n "$pr" ]; then
    [[ "$pr" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*$ ]] || { close_out_error 'prep requires a real PR URL when --pr is supplied'; return 3; }
  fi
  # A done document is an idempotent no-op, including after finish.
  case "$doc" in docs/done/*) printf 'Already prepared: %s\n' "$doc"; return 0 ;; esac
  dirty=$(git status --porcelain) || return 3
  [ -z "$dirty" ] || { close_out_error 'prep requires a clean worktree'; return 3; }
  brief_approved_at_head "$doc" "$(brief_approval "$doc" | cut -f1)" || return 3
  CLOSE_TARGET_STATE=closing
  close_out_load "$root" "$doc" "$tmp" || return $?
  if [ -n "$pr" ]; then
    case "$pr" in "https://github.com/$HANDOFF_REPO/pull/"*) ;; *) close_out_error 'PR repository differs from origin'; return 3 ;; esac
    review_bounded gh api "repos/$HANDOFF_REPO/pulls/${pr##*/}" > "$tmp/pr" || return 3
    jq -e --arg repo "$HANDOFF_REPO" --argjson number "${pr##*/}" '.number==$number and .base.repo.full_name==$repo and (.head.sha|test("^[a-f0-9]{40}$"))' "$tmp/pr" >/dev/null || return 3
    pr_source="url=$pr"
  fi
  dest="docs/done/${doc##*/}"
  [ ! -e "$dest" ] || { close_out_error "destination exists: $dest"; return 3; }
  tracking="https://github.com/$HANDOFF_REPO/issues/$CLOSE_TARGET"
  awk -v steps="$tmp/steps" -v tracking="$tracking" -v pr_source="$pr_source" '
    /^## Tracker$/ {print; while((getline row < steps)>0) {split(row,a,"\t"); print "- [x] " a[1] " — #" a[2] "; approved=" a[3] "; submissions=" a[4]}; close(steps); tracker=1; next}
    tracker && /^##? |^---$/ {tracker=0}
    tracker {next}
    /^> \*\*Type:\*\* .* · \*\*Status:\*\* / {sub(/ · \*\*Status:\*\* .*/," · **Status:** ✅ Done")}
    /^- \*\*Tracking issue:\*\* / {$0="- **Tracking issue:** url=" tracking}
    /^- \*\*Implementation head:\*\* / {$0="- **Implementation head:** source=pr-head"}
    /^- \*\*Implementation PR:\*\* / {$0="- **Implementation PR:** " pr_source}
    /^- \*\*Verification evidence:\*\* / {$0="- **Verification evidence:** source=final-approval-run"}
    /^- \*\*Review verdict:\*\* / {$0="- **Review verdict:** source=close-out-attestation"}
    /^- \*\*Memory:\*\* pending$/ {$0="- **Memory:** status=n/a"}
    {print}
  ' "$doc" > "$tmp/prepared"
  [ "$(brief_normalize < "$doc" | git hash-object --stdin)" = "$(brief_normalize < "$tmp/prepared" | git hash-object --stdin)" ] || {
    close_out_error 'preparation changed non-bookkeeping content'; return 3;
  }
  "$root/scripts/lifecycle-status.sh" --doc "$tmp/prepared" --validate-doc-status || return 3
  if [ "$dry" = true ]; then diff -u "$doc" "$tmp/prepared" || [ "$?" = 1 ]; printf 'Would move %s to %s and stage the doc and docs/README.md\n' "$doc" "$dest"; return 0; fi
  cat "$tmp/prepared" > "$doc"
  mkdir -p docs/done
  git mv -- "$doc" "$dest" || return 3
  AGENTIC_PROJECT_ROOT=$root "$root/scripts/docs-index.sh" || return 3
  git add -- "$dest" docs/README.md || return 3
  printf 'Prepared %s; review staged changes and commit.\n' "$dest"
)
