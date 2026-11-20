#!/usr/bin/env bash
# Human-only clarification approval; the hook blocks agent invocations.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/brief.sh"
. "$(dirname "${BASH_SOURCE[0]}")/review-policy.sh"

approve_cmd() (
  [ "$#" -eq 3 ] && [ "$2" = --by ] || return 2
  local doc=$1 by=$3 root tmp head approval rev old new diff_status=0
  root=$(git rev-parse --show-toplevel) || return 2
  cd "$root" || return 2
  case "$doc" in docs/inprogress/*.md) ;; *) return 2 ;; esac
  case "$doc" in *'/../'*|*'/./'*|*[!A-Za-z0-9_./-]*) return 2 ;; esac
  read_review_policy "$root" && review_valid_login "$by" || return 2
  case "$REVIEW_APPROVERS" in *" $by "*) ;; *) echo 'approve: --by must name a policy approver' >&2; return 3 ;; esac
  [ -f "$doc" ] && [ ! -L "$doc" ] || return 2
  [ "$(wc -c < "$doc")" -le 1048576 ] || return 2
  if ! git diff --quiet -- "$doc" || ! git diff --cached --quiet -- "$doc"; then echo 'approve: dirty doc; commit the clarification first' >&2; return 3; fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/agentic-approve.XXXXXX") || return 5
  trap 'rm -rf "$tmp"' EXIT
  head=$(git rev-parse HEAD) || return 5
  git show "HEAD:$doc" > "$tmp/head" || return 3
  approval=$(brief_approval "$tmp/head") || return 3
  rev=${approval%%$'\t'*}
  git merge-base --is-ancestor "$rev" HEAD || return 3
  git show "$rev:$doc" > "$tmp/old" || return 3
  old=$(brief_parse "$tmp/old" "$doc" "$rev") || return 3
  new=$(brief_parse "$tmp/head" "$doc" "$head") || { echo 'approve: invalid plan; re-plan required' >&2; return 3; }
  jq -en --argjson old "$old" --argjson new "$new" '
    $old.id==$new.id and $old.profile==$new.profile and $old.branch==$new.branch and
    ([$old.steps[].id]-[$new.steps[].id]|length)==0' >/dev/null || {
    echo 'approve: removed or changed plan ids; re-plan required' >&2; return 3;
  }
  brief_normalize < "$tmp/old" > "$tmp/old.normalized"
  brief_normalize < "$tmp/head" > "$tmp/new.normalized"
  diff -u "$tmp/old.normalized" "$tmp/new.normalized" || diff_status=$?
  [ "$diff_status" -le 1 ] || return 5
  awk -v by="$by" -v day="$(date -u +%Y-%m-%d)" -v rev="$head" '
    /^- \*\*Approval:\*\*/ {print "- **Approval:** status=approved; by=" by "; at=" day "; rev=" rev; next} {print}
  ' "$tmp/head" > "$tmp/approved" || return 5
  cat "$tmp/approved" > "$doc" || return 5
  git add -- "$doc" || return 5
  printf 'Approval staged for %s at %s. Commit the Status change, then run:\n  scripts/plan-to-issues.sh --doc %s --apply\n' "$doc" "$head" "$doc"
)

hold_cmd() (
  [ "$#" -ge 3 ] && [ "$1" = clear ] || return 2
  local doc=$2 id=$3 note='' root tmp spec issue repo rebaseline=()
  shift 3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --note) [ "$#" -ge 2 ] || return 2; note=$2; shift 2 ;;
      --rebaseline) rebaseline=(--rebaseline); shift ;;
      *) return 2 ;;
    esac
  done
  [ "${#note}" -le 1200 ] || return 2
  root=$(git rev-parse --show-toplevel) || return 2
  cd "$root" || return 2
  case "$doc" in docs/inprogress/*.md|docs/done/*.md) ;; *) return 2 ;; esac
  case "$doc" in *'/../'*|*'/./'*|*[!A-Za-z0-9_./-]*) return 2 ;; esac
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/agentic-hold.XXXXXX") || return 5
  trap 'rm -rf "$tmp"' EXIT
  git show "HEAD:$doc" > "$tmp/doc" || return 3
  spec=$(brief_parse "$tmp/doc" "$doc" HEAD) || return 3
  [[ "$id" =~ ^[a-z0-9][a-z0-9._-]*/hold/[1-9][0-9]{0,5}$ ]] || return 2
  [ "${id%%/*}" = "$(printf '%s' "$spec" | jq -r .id)" ] || return 3
  repo=$(identity_repository "$root") || return 5
  issue=$(sed -n "s@^- \*\*Tracking issue:\*\* url=https://github.com/$repo/issues/@@p" "$tmp/doc")
  [[ "$issue" =~ ^[1-9][0-9]{0,9}$ ]] || return 3
  printf '%s\n' "$note" > "$tmp/note"
  handoff_cmd "$issue" hold-clear --as approver --hold-id "$id" --body-file "$tmp/note" ${rebaseline[@]+"${rebaseline[@]}"}
)
