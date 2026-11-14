#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # Lifecycle context and shared adapter globals.
# Attest only committed, linear, completely covered history. Any doubt needs review.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/close-out.sh"

close_out_index_normalize() { # stdin; preserve all bytes outside exactly one generated region
  local line ending inside=false begins=0 ends=0
  while :; do
    ending=$'\n'
    if ! IFS= read -r line; then [ -n "$line" ] || break; ending=''; fi
    case "$line" in
      '<!-- BEGIN: generated index — do not edit by hand (scripts/docs-index.sh) -->')
        [ "$inside" = false ] || return 1
        begins=$((begins+1)); inside=true ;;
      '<!-- END: generated index -->')
        [ "$inside" = true ] || return 1
        ends=$((ends+1)); inside=false ;;
      *) [ "$inside" = false ] || continue ;;
    esac
    printf '%s%s' "$line" "$ending"
  done
  [ "$begins" = 1 ] && [ "$ends" = 1 ] && [ "$inside" = false ]
}

close_out_delta() { # root from to source-doc done-doc tmp; diagnostics on stdout
  local mode revision
  local root=$1 from=$2 to=$3 source=$4 done_doc=$5 tmp=$6 path old_doc new_doc before after invalid=false
  for revision in "$from" "$to"; do
    for path in "$source" "$done_doc" docs/README.md; do
      mode=$(git -C "$root" ls-tree "$revision" -- "$path") || return 1
      case "$mode" in ''|'100644 blob '*) ;; *) printf '%s (non-regular document mode)\n' "$path"; return 1 ;; esac
    done
  done
  git -C "$root" diff --name-only --no-renames "$from" "$to" > "$tmp/paths" || return 1
  while IFS= read -r path; do
    case "$path" in
      "$source"|"$done_doc") ;;
      docs/README.md)
        git -C "$root" show "$from:docs/README.md" > "$tmp/index-before" || return 1
        git -C "$root" show "$to:docs/README.md" > "$tmp/index-after" || return 1
        before=$(close_out_index_normalize < "$tmp/index-before" | git hash-object --stdin) || return 1
        after=$(close_out_index_normalize < "$tmp/index-after" | git hash-object --stdin) || return 1
        if [ "$before" != "$after" ]; then printf '%s (outside generated region)\n' "$path"; invalid=true; fi ;;
      *) printf '%s\n' "$path"; invalid=true ;;
    esac
  done < "$tmp/paths"
  old_doc=$source new_doc=$done_doc
  # Both a move and bookkeeping before the move are valid; deletion or duplication is not.
  if git -C "$root" cat-file -e "$from:$done_doc" 2>/dev/null; then old_doc=$done_doc; fi
  if ! git -C "$root" cat-file -e "$to:$done_doc" 2>/dev/null; then new_doc=$source; fi
  git -C "$root" show "$from:$old_doc" > "$tmp/doc-before" || return 1
  git -C "$root" show "$to:$new_doc" > "$tmp/doc-after" || return 1
  before=$(brief_normalize < "$tmp/doc-before" | git hash-object --stdin) || return 1
  after=$(brief_normalize < "$tmp/doc-after" | git hash-object --stdin) || return 1
  if [ "$before" != "$after" ]; then printf '%s (brief content changed)\n' "$new_doc"; invalid=true; fi
  [ "$invalid" = false ]
}

close_out_attest() { # repo head tmp; lifecycle's parsed doc and evidence helpers are shared
  local repo=$1 head=$2 tmp=$3 doc source done_doc approval rev base step number approved submissions previous first start commit path expected actual latest run_id attempt
  doc=${DOC#"$ROOT"/}
  case "$doc" in docs/done/*.md) ;; *) echo 'attestation requires a done document'; return 1 ;; esac
  source="docs/inprogress/${doc##*/}" done_doc=$doc
  if git -C "$ROOT" cat-file -e "$head:$source" 2>/dev/null; then echo "$source still exists"; return 1; fi
  git -C "$ROOT" show "$head:$doc" > "$tmp/head-doc" || return 1
  [ "$(git hash-object "$DOC")" = "$(git hash-object "$tmp/head-doc")" ] || { echo "$doc (local document differs from PR head)"; return 1; }
  approval=$(brief_approval "$tmp/head-doc") || return 1
  rev=${approval%%$'\t'*}
  git -C "$ROOT" merge-base --is-ancestor "$rev" "$head" || return 1
  git -C "$ROOT" show "$rev:$source" > "$tmp/approved-doc" || return 1
  expected=$(brief_normalize < "$tmp/approved-doc" | git hash-object --stdin) || return 1
  actual=$(brief_normalize < "$tmp/head-doc" | git hash-object --stdin) || return 1
  [ "$expected" = "$actual" ] || { echo "$doc (approved brief changed)"; return 1; }
  # Local worktree must not supply any plan or policy bytes to an attestation of another head.
  for path in .agentic-flow-review-policy config/workflow.tsv; do
    [ "$(git -C "$ROOT" rev-parse "$head:$path")" = "$(git -C "$ROOT" hash-object "$ROOT/$path")" ] || { echo "$path differs from PR head"; return 1; }
  done
  mkdir -p "$tmp/attest"
  CLOSE_TARGET_STATE=closing
  [ "$PHASE" != pre-merge ] || CLOSE_TARGET_STATE=closed
  close_out_load "$ROOT" "$doc" "$tmp/attest" || return 1
  [ "$(printf '%s' "$CLOSE_SPEC" | jq -r .id)" = "$(brief_parse "$tmp/approved-doc" "$source" "$rev" | jq -r .id)" ] || return 1
  [ "$CLOSE_TARGET" = "$issue_number" ] || { echo 'Tracking issue differs from plan'; return 1; }
  base=$(git -C "$ROOT" merge-base main "$head") || return 1
  [ -z "$(git -C "$ROOT" rev-list --merges "$base..$head")" ] || { echo 'merge commit in attestation range'; return 1; }
  previous=''
  while IFS="$(printf '\t')" read -r step number approved submissions; do
    verify_step_review "$repo" "$number" "$step" "$tmp/attest" "$head" || return 1
    [ "$STEP_VERIFIED_HEAD" = "$approved" ] || return 1
    first=$(jq -r '[.accepted[]|select(.event=="submit")]|first|.head' "$tmp/attest/$number.replay")
    start=$(git -C "$ROOT" rev-parse "$first^") || return 1
    git -C "$ROOT" merge-base --is-ancestor "$start" "$approved" || return 1
    if [ -z "$previous" ]; then
      git -C "$ROOT" merge-base --is-ancestor "$base" "$start" || return 1
      git -C "$ROOT" merge-base --is-ancestor "$rev" "$start" || return 1
      while IFS= read -r commit; do
        git -C "$ROOT" diff-tree --no-commit-id --name-only -r "$commit" > "$tmp/plan-paths" || return 1
        if [ "$(cat "$tmp/plan-paths")" != "$source" ]; then echo "uncovered plan-approval commit $commit"; cat "$tmp/plan-paths"; return 1; fi
        git -C "$ROOT" show "$commit:$source" > "$tmp/plan-doc" || return 1
        actual=$(brief_normalize < "$tmp/plan-doc" | git hash-object --stdin) || return 1
        [ "$actual" = "$expected" ] || { echo "$source (unapproved plan commit $commit)"; return 1; }
      done < <(git -C "$ROOT" rev-list --reverse "$base..$start")
    elif [ "$previous" != "$start" ]; then
      echo "uncovered gap before $step ($previous..$start)"; return 1
    fi
    previous=$approved
  done < "$tmp/attest/steps"
  close_out_delta "$ROOT" "$previous" "$head" "$source" "$done_doc" "$tmp" || return 1
  # Verify that the allowed index region really is generated from this head.
  mkdir -p "$tmp/snapshot/docs" || return 1
  git -C "$ROOT" ls-tree -r --name-only "$head" -- docs > "$tmp/doc-paths" || return 1
  local doc_count=0
  while IFS= read -r path; do
    doc_count=$((doc_count+1))
    [ "$doc_count" -le 1000 ] || { echo 'document snapshot exceeds 1000 files'; return 1; }
    case "$path" in *.md) ;; *) continue ;; esac
    [[ "$path" =~ ^docs/[A-Za-z0-9_./-]+\.md$ ]] || { echo "unparseable doc path: $path"; return 1; }
    case "$(git -C "$ROOT" ls-tree "$head" -- "$path")" in '100644 blob '*) ;; *) echo "non-regular doc: $path"; return 1 ;; esac
    mkdir -p "$tmp/snapshot/$(dirname "$path")" || return 1
    git -C "$ROOT" show "$head:$path" > "$tmp/snapshot/$path" || return 1
  done < "$tmp/doc-paths"
  AGENTIC_PROJECT_ROOT="$tmp/snapshot" "$SCRIPT_ROOT/scripts/docs-index.sh" --check || { echo 'docs/README.md (generated index is stale)'; return 1; }
  close_out_ci "$repo" "$head" "$tmp" || return 1
  printf 'attested head %s; Actions run %s attempt %s succeeded\n' "$head" "$CLOSE_CI_RUN" "$CLOSE_CI_ATTEMPT"
}

close_out_ci() { # repo head tmp -> latest successful run and attempt globals
  local repo=$1 head=$2 tmp=$3 latest run_id attempt
  bounded_gh "$tmp/runs" api "repos/$repo/actions/workflows/${REVIEW_WORKFLOW##*/}/runs?head_sha=$head&per_page=100" || return 1
  latest=$(jq -ec --arg head "$head" --arg workflow "$REVIEW_WORKFLOW" '
    .workflow_runs | select(type=="array" and length>0 and length<100) |
    if all(.[]; (.id|type)=="number" and .id>0 and (.id|floor)==.id and
      (.created_at|type)=="string" and (.created_at|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      (.head_sha|type)=="string" and (.head_sha|test("^[a-f0-9]{40}$")) and (.path|type)=="string")
    then . else error("malformed workflow run listing") end |
    map(select(.head_sha==$head and (.path|split("@")[0])==$workflow)) | sort_by(.created_at,.id) | last |
    select(.id|type=="number")' "$tmp/runs") || { echo 'CI pending or unavailable'; return 1; }
  run_id=$(printf '%s' "$latest" | jq -r .id)
  [[ "$run_id" =~ ^[1-9][0-9]*$ ]] || return 1
  bounded_gh "$tmp/attest-run" api "repos/$repo/actions/runs/$run_id" || return 1
  jq -e --arg repo "$repo" --arg head "$head" --arg workflow "$REVIEW_WORKFLOW" '
    .repository.full_name==$repo and .head_sha==$head and (.path|split("@")[0])==$workflow and
    .status=="completed" and .conclusion=="success" and (.run_attempt|type)=="number" and .run_attempt>=1 and (.run_attempt|floor)==.run_attempt' "$tmp/attest-run" >/dev/null || { echo 'CI pending or latest attempt did not succeed'; return 1; }
  attempt=$(jq -r .run_attempt "$tmp/attest-run")
  CLOSE_CI_RUN=$run_id CLOSE_CI_ATTEMPT=$attempt
}
