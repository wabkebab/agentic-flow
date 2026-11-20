#!/usr/bin/env bash
# shellcheck disable=SC2034 # Context globals are the replay/lifecycle interface.
# Pure journal derivation. Call workflow_load and read_review_policy before replay.
journal_jq() { # jq with the shared journal marker module on its search path
  jq -L "$(dirname "${BASH_SOURCE[0]}")" "$@"
}

journal_stamp() { # issue body -> {plan,step,topology,legacy}
  jq -Rsc '
    [split("\n")[] | select(startswith("<!-- agentic-flow:plan:"))] as $lines |
    if ($lines|length)!=1 then error("expected one plan stamp") else $lines[0] end |
    capture("^<!-- agentic-flow:plan:(?<plan>[a-z0-9][a-z0-9._-]*) (?<identity>tracker|step:[a-z0-9][a-z0-9._-]*) spec:[^ ]+(?<extra>[^\\n]*) -->$") |
    . + {step:(if .identity=="tracker" then "tracker" else .identity[5:] end),
      legacy:((.extra|test("(^| )journal=v1( |$)"))|not)} |
    {plan,step,legacy}'
}

journal_normalize() { # gh issue-view comments or GraphQL nodes -> one common shape
  review_normalize_comments | jq 'map({id, dbid:(.fullDatabaseId // .databaseId // .id),
    author:.author.login, created_at:(.createdAt // .created_at),
    last_edited_at:(.lastEditedAt // .last_edited_at // null), body})'
}

journal_context() { # body; caller retains globals for replay
  local stamp
  stamp=$(printf '%s' "$1" | journal_stamp) || return 1
  JOURNAL_PLAN=$(printf '%s' "$stamp" | jq -r .plan)
  JOURNAL_STEP=$(printf '%s' "$stamp" | jq -r .step)
  JOURNAL_LEGACY=$(printf '%s' "$stamp" | jq -r .legacy)
  JOURNAL_TOPOLOGY=step-strict
  if [ "$JOURNAL_STEP" = tracker ]; then JOURNAL_TOPOLOGY=tracker
  elif printf '%s\n' "$1" | grep -Fxq '<!-- agentic-flow:topology:standard -->'; then
    JOURNAL_TOPOLOGY=work-standard
  fi
}

journal_replay() { # normalized comments JSON, topology; stamp context via JOURNAL_*
  local rules
  rules=$(printf '%s\n' "$WORKFLOW_DATA" | jq -Rsc 'split("\n") | map(select(length>0)|split("\t"))') || return 1
  printf '%s' "$1" | journal_jq --arg topology "$2" --arg plan "${JOURNAL_PLAN:-}" \
    --arg step "${JOURNAL_STEP:-}" --argjson legacy "${JOURNAL_LEGACY:-false}" \
    --arg reviewers "$REVIEW_REVIEWERS" --arg executors "$REVIEW_EXECUTORS" \
    --arg approvers "$REVIEW_APPROVERS" --argjson rules "$rules" \
    -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/journal.jq"
}
