#!/usr/bin/env bash
# docs-index.sh — regenerate the "Current docs" table in docs/README.md from each doc's
# TRIAGE header, so the index is DERIVED, never hand-maintained. See METHODOLOGY.md §4.
#
# Usage:
#   scripts/docs-index.sh            rewrite the generated block in docs/README.md
#   scripts/docs-index.sh --check    exit non-zero if the block is stale (for CI / a hook)
#
# Scans docs/**/*.md, skipping non-lifecycle paths such as templates/ and reference/. Reads the
# `> **Type:** … · **Status:** …` TRIAGE line and the file's stage (its folder under docs/).
# Tracker-checkbox sync from live GitHub issue state is a planned follow-up layer.
set -euo pipefail

ROOT=${AGENTIC_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
DOCS_DIR="$ROOT/docs"
README="$DOCS_DIR/README.md"
BEGIN='<!-- BEGIN: generated index — do not edit by hand (scripts/docs-index.sh) -->'
END='<!-- END: generated index -->'

[ -f "$README" ] || { echo "error: $README not found" >&2; exit 1; }

trim() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }

build_table() {
  printf '| Doc | Type | Status | Stage |\n'
  printf '|-----|------|--------|-------|\n'
  local found=0 f rel stage triage type status name
  while IFS= read -r f; do
    case "$f" in
      "$DOCS_DIR/reference/"*|*/templates/*|*/README.md|*/accepted_risks.md|*/memory/*|*/MEMORY.md) continue ;;
    esac
    rel="${f#"$DOCS_DIR"/}"
    stage="${rel%/*}"
    [ "$stage" = "$rel" ] && stage="(root)"
    case "$stage" in
      backlog|inprogress|done|done/security) ;;
      *) echo "error: undeclared docs stage '$stage' for $rel" >&2; exit 2 ;;
    esac
    triage=$(grep -m1 -E '\*\*Type:\*\*' "$f" || true)
    type=$(printf '%s\n' "$triage" | sed -E 's/.*\*\*Type:\*\*[[:space:]]*//; s/[[:space:]]*(·|\*\*Status).*$//' | trim)
    status=$(printf '%s\n' "$triage" | sed -E 's/.*\*\*Status:\*\*[[:space:]]*//' | trim)
    name=$(basename "$f" .md)
    printf '| %s | %s | %s | %s |\n' "$name" "${type:-—}" "${status:-—}" "$stage"
    found=1
  done < <(find "$DOCS_DIR" -type f -name '*.md' | sort)
  if [ "$found" -eq 0 ]; then printf '| _none yet_ | | | |\n'; fi
}

TABLE=$(build_table)

grep -qF "$BEGIN" "$README" || { echo "error: BEGIN marker not found in $README" >&2; exit 1; }
grep -qF "$END" "$README"   || { echo "error: END marker not found in $README" >&2; exit 1; }

# Splice the table between the markers. The table is multi-line, and macOS awk rejects
# newlines in -v assignments, so pass it via a temp file and getline it in.
TMPTBL=$(mktemp)
trap 'rm -f "$TMPTBL"' EXIT
printf '%s\n' "$TABLE" > "$TMPTBL"
NEW=$(awk -v b="$BEGIN" -v e="$END" -v tf="$TMPTBL" '
  $0==b {print; while ((getline line < tf) > 0) print line; close(tf); skip=1; next}
  $0==e {print; skip=0; next}
  skip!=1 {print}
' "$README")
rm -f "$TMPTBL"
trap - EXIT

if [ "${1:-}" = "--check" ]; then
  if [ "$NEW" = "$(cat "$README")" ]; then
    echo "docs index up to date."; exit 0
  fi
  echo "docs index OUT OF DATE — run: scripts/docs-index.sh" >&2; exit 1
fi

printf '%s\n' "$NEW" > "$README"
echo "Rewrote docs index in $README"
