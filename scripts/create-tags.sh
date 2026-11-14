#!/usr/bin/env bash
#
# create-tags.sh — create the seven agentic-flow workflow labels with their standard colors.
#
# Usage:
#   scripts/create-tags.sh [--repo <owner/repo>]
#
# Idempotent: `gh label create` failing because a label already exists is not an error here.
set -euo pipefail

REPO=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || { echo "error: --repo requires a value" >&2; exit 2; }
      REPO="$2"; shift 2 ;;
    -h|--help) awk 'NR==1 {next} /^#/ {print; next} {exit}' "$0"; exit 0 ;;
    *) echo "error: unknown flag: $1" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null || { echo "error: gh not found" >&2; exit 1; }
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) \
    || { echo "error: not in a GitHub repo (pass --repo owner/repo)" >&2; exit 1; }
fi

# name|color — CLAUDE.md's label state machine (METHODOLOGY.md §6) is the source of truth
# for what each pair means; this is only the color assignment.
LABELS="agent:claude|FFA500
agent:codex|0052CC
agent:opencode|000000
needs-review|FFA500
needs-execution|FBCA04
needs-closing|5319E7
needs-human|B60205"

printf '%s\n' "$LABELS" | while IFS='|' read -r name color; do
  [ -n "$name" ] || continue
  gh label create "$name" --repo "$REPO" --color "$color" >/dev/null 2>&1 || true
done

echo "Workflow labels ready on $REPO."
