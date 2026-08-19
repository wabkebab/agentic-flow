#!/usr/bin/env bash
# check-memory-index.sh — keep docs/MEMORY.md honest: every entry indexed, every index line
# resolving, every path:line citation still real, and the index short enough to stay cheap.
#
# The memory layer's whole economy is that the index is read every session and the bodies are
# not. That only holds while the index stays one line per entry and small. Three ways it rots,
# all silent, all checked here:
#
#   1. An entry file with no index line is unreachable — nothing will ever surface it.
#   2. An index line with no file is a dead pointer that costs a read to discover.
#   3. A citation like `foo.sh:42` outlives the line it names, and a memory that confidently
#      cites a file that moved is worse than no memory, because it is believed.
#
# Run from `make check`. A project with no memories yet is green: an adopter receives the empty
# tree and writes docs/MEMORY.md on first capture, so a missing index is "nothing to check",
# never a failure.
set -euo pipefail

ROOT=${AGENTIC_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
MEMORY_DIR="$ROOT/docs/memory"
INDEX="$ROOT/docs/MEMORY.md"

# Two ceilings, deliberately different, for the reason the role-bundle ceilings are split
# between conditional and unconditional (self-test.sh, "Ceilings are set just above the
# MEASURED size").
#
# The unconditional one is not this repo's measurement — it is the harness's. Claude Code reads
# the first 200 lines of a memory index and SILENTLY DROPS the rest, so an index past that is
# already losing entries wherever it is read:
#   https://code.claude.com/docs/en/errors — "over its 200-line read limit ... everything past
#   the limit is silently dropped each time the index is loaded".
# That is true in an adopted project too, so failing there is correct rather than presumptuous.
#
# The tight one applies only in the scaffold (scripts/export.sh present). An adopter's memory is
# their own real project knowledge and has no reason to be bounded by this repo's habits.
# Running a tight ceiling unconditionally is exactly the bug self-test.sh records at its
# role-bundle ceilings: it "broke the first real adopter upgrade past this check".
HARNESS_INDEX_MAX=200
SCAFFOLD_INDEX_MAX=50

failures=0

fail() { echo "memory index: $*" >&2; failures=$((failures + 1)); }

if [ ! -d "$MEMORY_DIR" ]; then
  echo "memory index check skipped (no docs/memory)."
  exit 0
fi

# Entry files, excluding the .gitkeep that ships the empty tree.
entries=""
while IFS= read -r entry; do
  entries="$entries $(basename "$entry" .md)"
done < <(find "$MEMORY_DIR" -maxdepth 1 -name '*.md' | sort)

if [ ! -f "$INDEX" ]; then
  # No index and no entries is the shipped state: nothing captured yet.
  if [ -n "${entries// /}" ]; then
    fail "docs/memory/ has entries but docs/MEMORY.md does not exist —$entries"
    exit 1
  fi
  echo "memory index check skipped (nothing captured yet)."
  exit 0
fi

# --- ceilings ---------------------------------------------------------------------------
# Frontmatter and HTML comments are excluded from Claude Code's own measurement, so exclude
# them here too rather than inventing a stricter rule than the harness enforces.
index_lines=$(grep -cv '^[[:space:]]*\(<!--\|-->\)' "$INDEX" || true)
if [ "$index_lines" -gt "$HARNESS_INDEX_MAX" ]; then
  fail "docs/MEMORY.md is $index_lines lines, over the $HARNESS_INDEX_MAX-line read limit —" \
       "entries past it are silently dropped. Promote or delete, don't extend."
fi
if [ -f "$ROOT/scripts/export.sh" ] && [ "$index_lines" -gt "$SCAFFOLD_INDEX_MAX" ]; then
  fail "docs/MEMORY.md is $index_lines lines, over this repo's $SCAFFOLD_INDEX_MAX-line ceiling."
fi

# --- every entry is indexed, and every index line resolves ------------------------------
for entry in $entries; do
  grep -qF "$entry" "$INDEX" \
    || fail "docs/memory/$entry.md has no line in docs/MEMORY.md — nothing will surface it."
done

# The entry name is the FIRST CELL of a table row and nowhere else. Scanning for any
# backticked token instead would read `cp`, `merge-policy` and every other inline code span in
# a description as if it were a filename — the first draft here did exactly that.
while IFS= read -r stem; do
  [ -n "$stem" ] || continue
  [ -f "$MEMORY_DIR/$stem.md" ] \
    || fail "docs/MEMORY.md has a row for $stem, which is not a file in docs/memory/."
done < <(awk -F'|' '
  /^[[:space:]]*\|/ && NF >= 4 {
    cell = $2
    gsub(/[`[:space:]]/, "", cell)
    if (cell == "" || cell == "Entry" || cell ~ /^-+$/) next
    print cell
  }
' "$INDEX" | sort -u)

# --- citations still resolve ------------------------------------------------------------
# A memory naming a path:line rots when that file moves or shrinks. Vendor/tool behaviour
# ("cp is interactive") cites nothing and is checked by nobody — correctly, it does not expire
# on this project's clock.
# shellcheck disable=SC2016 # literal Markdown backticks, not command substitution.
while IFS= read -r citation; do
  [ -n "$citation" ] || continue
  cited_path="${citation%%:*}"
  cited_line="${citation##*:}"
  if [ ! -f "$ROOT/$cited_path" ]; then
    fail "a memory cites $citation but $cited_path does not exist."
    continue
  fi
  actual_lines=$(wc -l < "$ROOT/$cited_path" | tr -d ' ')
  if [ "$cited_line" -gt "$actual_lines" ]; then
    fail "a memory cites $citation but $cited_path has only $actual_lines lines."
  fi
done < <(grep -rhoE '`[A-Za-z0-9_./-]+\.(sh|md|json|tsv|yml|yaml):[0-9]+`' "$MEMORY_DIR" 2>/dev/null \
           | tr -d '`' | sort -u)

if [ "$failures" -gt 0 ]; then
  echo "memory index check failed: $failures problem(s)." >&2
  exit 1
fi

echo "memory index ok."
