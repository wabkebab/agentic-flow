# Frozen from 0.21.0 (97c6ebe). Source only in a compatibility-test subshell.
# shellcheck shell=bash disable=SC2034
journal_stamp() { # issue body -> {plan,step,topology,legacy}
  jq -Rsc '
    [split("\n")[] | select(startswith("<!-- agentic-flow:plan:"))] as $lines |
    if ($lines|length)!=1 then error("expected one plan stamp") else $lines[0] end |
    capture("^<!-- agentic-flow:plan:(?<plan>[a-z0-9][a-z0-9._-]*) (?<identity>tracker|step:[a-z0-9][a-z0-9._-]*) spec:[^ ]+(?<extra>[^\\n]*) -->$") |
    . + {step:(if .identity=="tracker" then "tracker" else .identity[5:] end),
      legacy:((.extra|test("(^| )journal=v1( |$)"))|not)} |
    {plan,step,legacy}'
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
TRACK_STAMP_RE='^<!-- agentic-flow:plan:([a-z0-9][a-z0-9._-]*) tracker spec:([a-f0-9]{40}|[a-f0-9]{64}|[0-9]{1,10})( journal=[a-z0-9][a-z0-9._-]*)?( approved=[a-f0-9]{40})?( approved-by:.+ approved-at:[^ ]+)? -->$'
STEP_STAMP_RE='^<!-- agentic-flow:plan:([a-z0-9][a-z0-9._-]*) step:([a-z0-9][a-z0-9._-]*) spec:([a-f0-9]{40}|[a-f0-9]{64}|[0-9]{1,10})( journal=[a-z0-9][a-z0-9._-]*)?( approved=[a-f0-9]{40})?( approved-by:.+ approved-at:[^ ]+)? -->$'

frozen_issue_index_rows() { # Whole-line discovery from the 0.21.0 JSON-spec path.
  jq -r --arg prefix "<!-- agentic-flow:plan:$1 " '
    .[] | .number as $number | .body | split("\n")[]
    | select(contains($prefix)) | [$number, .] | @tsv'
}
