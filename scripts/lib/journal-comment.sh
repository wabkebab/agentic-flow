#!/usr/bin/env bash
# Adapters supply trusted marker lines and separate Markdown inputs.
JOURNAL_COMMENT_HELPER=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/journal-comment.pl

journal_render() ( # event subject markers facts run-marker result-file [owner reason checks-file diagnostic-file warnings-file]
  set -o pipefail
  jq -n --arg event "$1" --arg subject "$2" --arg markers "$3" --arg facts "$4" --arg run_marker "$5" \
    --slurpfile results "$6" --arg owner "${7:-}" --arg andon_reason "${8:-}" \
    --slurpfile checks "${9:-/dev/null}" --rawfile diagnostic "${10:-/dev/null}" --slurpfile warnings "${11:-/dev/null}" '
    if ($results|length)!=1 or ($results[0]|type)!="object" then error("invalid journal comment input")
    else {event:$event,subject:$subject,markers:$markers,facts:$facts,run_marker:$run_marker,
      result:$results[0],station:($results[0].v==1),owner:$owner,andon_reason:$andon_reason,
      checks:$checks[0],diagnostic:$diagnostic,warnings:$warnings[0]} end' |
    perl "$JOURNAL_COMMENT_HELPER"
)

journal_summary() { printf '%s' "$1" | jq -Rs '{summary:.}'; }
journal_render_pr() { perl "$JOURNAL_COMMENT_HELPER"; } # JSON context on stdin
journal_run_marker() {
  if [ -n "${HANDOFF_CONTROLLER_RUN:-}" ] && [ -n "${HANDOFF_CONTROLLER_HOST:-}" ]; then
    printf 'agentic-flow-run: run=%s; host=%s' "$HANDOFF_CONTROLLER_RUN" "$HANDOFF_CONTROLLER_HOST"
  fi
}
journal_subject() { # step id and title; older fixtures may have no title
  local title=$2
  case "$title" in
    "$1"|"") printf '%s' "$1" ;;
    "$1 — "*) printf '%s' "$title" ;;
    *) printf '%s — %s' "$1" "$title" ;;
  esac
}
