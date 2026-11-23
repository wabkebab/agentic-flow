#!/usr/bin/env bash
# check-harness-sync.sh — assert root/template section parity and generated content.
#
# CLAUDE.md and AGENTS.md exist twice on purpose: the root instance is this repo's own
# contract, the templates/harness/ one is what an adopting project receives. They are
# deliberately different documents — the template carries the project-name placeholder,
# generalizes "hand to OpenCode" to "hand to the reviewer" for projects that opted out, and
# marks the stack profile as needing wiring up — so their prose is NOT compared here.
#
# (That placeholder is described rather than written out: this file ships to adopters, and
# init.sh/self-test.sh scan exported files for unfilled tokens, so a literal one here would
# report itself as an unfilled token.)
#
# Unmarked prose is intentionally project-specific. Compare its `##` section list: a section
# that exists in one and not the other is either a section the other should have gained, or
# a deliberate divergence that belongs in the exception list below. Both are decisions.
# Neither should happen silently. The generated regions and skill bodies are checked
# byte-for-byte by render-shared.sh.
#
# Deeper headings (### and below) are elaboration and legitimately differ — the root file
# documents a step-issue label state machine the template does not mandate — so they are
# out of scope rather than smuggled past with a growing exception list.
set -euo pipefail

ROOT=${AGENTIC_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}

"$ROOT/scripts/render-command-policy.sh" --check || exit 1

# Adopted projects receive scripts/ but not templates/harness/, so there is nothing to
# compare there. Same source-vs-adopted distinction self-test.sh makes.
if [ ! -d "$ROOT/templates/harness" ]; then
  echo "harness sync check skipped (no templates/harness — adopted project)."
  exit 0
fi

# Deliberate, declared differences. Format: <file>|<side>|<normalized heading>
# where <side> is root-only or template-only. Empty today: keep it that way if you can, and
# when you cannot, add the line here so the difference is a statement rather than an
# accident.
EXCEPTIONS=""

failures=0

# Strip the template's "needs attention" marker so it is not read as a structural change.
# The heading is the same section either way.
normalize_headings() { # <file>
  grep -E '^## ' "$1" \
    | sed -e 's/[[:space:]]*⚠️[[:space:]]*WIRE THIS UP[[:space:]]*$//' \
          -e 's/[[:space:]]*$//'
}

is_declared_exception() { # <file> <side> <heading>
  printf '%s\n' "$EXCEPTIONS" | grep -Fxq "$1|$2|$3"
}

check_pair() { # <root-relative file> <template file>
  local rel="$1" tpl="$2" heading
  if [ ! -f "$ROOT/$rel" ] || [ ! -f "$ROOT/$tpl" ]; then
    echo "harness sync: expected both $rel and $tpl to exist" >&2
    failures=$((failures + 1))
    return
  fi

  while IFS= read -r heading; do
    [ -n "$heading" ] || continue
    is_declared_exception "$rel" root-only "$heading" && continue
    echo "harness sync: \"$heading\" is in $rel but not $tpl." >&2
    echo "  Add it to the template, or declare it in EXCEPTIONS as '$rel|root-only|$heading'." >&2
    failures=$((failures + 1))
  done < <(comm -23 <(normalize_headings "$ROOT/$rel" | sort -u) \
                    <(normalize_headings "$ROOT/$tpl" | sort -u))

  while IFS= read -r heading; do
    [ -n "$heading" ] || continue
    is_declared_exception "$rel" template-only "$heading" && continue
    echo "harness sync: \"$heading\" is in $tpl but not $rel." >&2
    echo "  Add it to the root file, or declare it in EXCEPTIONS as '$rel|template-only|$heading'." >&2
    failures=$((failures + 1))
  done < <(comm -13 <(normalize_headings "$ROOT/$rel" | sort -u) \
                    <(normalize_headings "$ROOT/$tpl" | sort -u))
}

check_pair CLAUDE.md templates/harness/CLAUDE.md
check_pair AGENTS.md templates/harness/AGENTS.md

# The source checkout also has canonical shared regions and skill bodies. Compare
# their complete bytes; heading parity alone cannot detect drift within a section.
if [ -d "$ROOT/templates/shared" ]; then
  "$ROOT/scripts/render-shared.sh" --check || failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "harness sync check failed: $failures section(s) out of sync." >&2
  exit 1
fi

echo "harness sync ok."
