#!/usr/bin/env bash
# shellcheck disable=SC2034 # Context globals are the replay/lifecycle interface.
# Pure journal derivation. Call workflow_load and read_review_policy before replay.
# Resolved once, when this file is sourced: BASH_SOURCE is relative if the caller sourced it by a
# relative path, and it no longer resolves after the caller changes directory.
JOURNAL_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/workflow.sh
. "$JOURNAL_LIB_DIR/workflow.sh"
journal_jq() { # jq with the shared journal marker module on its search path
  jq -L "$JOURNAL_LIB_DIR" "$@"
}

journal_default_policy() {
  journal_jq -nr 'include "journal-marker"; journal_legacy_pin'
}

JOURNAL_STAMP_PREFIX='<!-- agentic-flow:plan:'
# shellcheck disable=SC2016 # The quoted expressions are jq programs.
journal_stamp_lines() { # body|discover|index [plan]; index accepts a bounded issue array
  case "${1:-}" in
    index)
      journal_jq -rc --arg prefix "$JOURNAL_STAMP_PREFIX" --arg plan "$2" '
        include "journal-marker";
        .[] | .number as $number | .body |
        select(any(split("\n")[]; startswith($prefix+$plan+" "))) |
        (try journal_stamp_lines($prefix) catch error("malformed identity stamp on issue #\($number): \(.)")) |
        [$number, .line, .policy, (.policy_line != null)] | @tsv' ;;
    discover)
      journal_jq -Rsc --arg prefix "$JOURNAL_STAMP_PREFIX" --arg plan "$2" '
        include "journal-marker";
        . as $body | try journal_stamp_lines($prefix) catch (
          . as $reason |
          if any($body|split("\n")[]|journal_identity($prefix); .plan==$plan and (.versions|index("v2"))!=null)
          then error($reason) else null end)' ;;
    *)
      journal_jq -Rsc --arg prefix "$JOURNAL_STAMP_PREFIX" '
        include "journal-marker"; journal_stamp_lines($prefix)' ;;
  esac
}

journal_stamp() { # issue body -> parsed identity and validated policy
  journal_stamp_lines body || return 3
}

journal_normalize() { # gh issue-view comments or GraphQL nodes -> one common shape
  review_normalize_comments | jq 'map({id, dbid:(.fullDatabaseId // .databaseId // .id),
    author:.author.login, created_at:(.createdAt // .created_at),
    last_edited_at:(.lastEditedAt // .last_edited_at // null), body})'
}

journal_context() { # body; caller retains globals for replay
  local stamp fields
  stamp=$(printf '%s' "$1" | journal_stamp_lines body) || return 3
  fields=$(printf '%s' "$stamp" | jq -r '[.plan,.step,.legacy,.pin.max_bounces,.pin.block_at,.pin.infra,.policy]|@tsv') || return 3
  IFS=$'\t' read -r JOURNAL_PLAN JOURNAL_STEP JOURNAL_LEGACY JOURNAL_MAX_BOUNCES JOURNAL_BLOCK_AT JOURNAL_INFRA JOURNAL_POLICY <<< "$fields"
  JOURNAL_TOPOLOGY=step-strict
  if [ "$JOURNAL_STEP" = tracker ]; then JOURNAL_TOPOLOGY=tracker
  elif printf '%s\n' "$1" | grep -Fxq '<!-- agentic-flow:topology:standard -->'; then
    JOURNAL_TOPOLOGY=work-standard
  fi
}

journal_replay() { # normalized comments JSON, topology; stamp context via JOURNAL_*
  local rules limit=${JOURNAL_MAX_BOUNCES:-2}
  workflow_check_limit "$limit" || return $?
  rules=$(printf '%s\n' "$WORKFLOW_DATA" | jq -Rsc 'split("\n") | map(select(length>0)|split("\t"))') || return 1
  printf '%s' "$1" | journal_jq --arg topology "$2" --arg plan "${JOURNAL_PLAN:-}" \
    --arg step "${JOURNAL_STEP:-}" --argjson legacy "${JOURNAL_LEGACY:-false}" \
    --arg reviewers "$REVIEW_REVIEWERS" --arg executors "$REVIEW_EXECUTORS" \
    --arg approvers "$REVIEW_APPROVERS" --argjson rules "$rules" --argjson limit "$limit" \
    -f "$JOURNAL_LIB_DIR/journal.jq"
}
