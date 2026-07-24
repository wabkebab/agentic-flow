#!/usr/bin/env bash
# check-payload-manifest.sh — fail when an adapter/template/profile file is unclassified,
# or when a brand-new agent-surface directory exists with no manifest entry at all.
set -euo pipefail

ROOT=${AGENTIC_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
MANIFEST="$ROOT/config/payload.tsv"
[ -f "$MANIFEST" ] || { echo "payload manifest not found: $MANIFEST" >&2; exit 1; }

failures=0

# True when $1 (a path relative to ROOT) is covered by some manifest source entry —
# either exactly, or as a descendant of a directory entry.
covered_by_manifest() {
  local rel="$1" source
  while IFS="$(printf '\t')" read -r source _rest; do
    case "${source:-}" in ""|\#*) continue ;; esac
    case "$rel" in "$source"|"$source"/*) return 0 ;; esac
  done < "$MANIFEST"
  return 1
}

# True when $1 (a directory, relative to ROOT) has SOME manifest row underneath it — the
# reverse direction from covered_by_manifest: ".agents" is never itself a manifest source
# (".agents/skills" is), so a directory is "classified" when a row exists inside it, not when
# the directory path itself matches a row exactly.
has_manifest_entry_under() {
  local rel="$1" source
  while IFS="$(printf '\t')" read -r source _rest; do
    case "${source:-}" in ""|\#*) continue ;; esac
    case "$source" in "$rel"|"$rel"/*) return 0 ;; esac
  done < "$MANIFEST"
  return 1
}

# --- every file inside a KNOWN adapter/template/profile area must itself be covered ------
# Catches a file added inside an already-declared area (e.g. .codex/) that nobody added to
# the manifest — the original #9 class of bug. This list is deliberately curated, not
# derived from the manifest's own top-level paths: several manifest entries (docs/README.md,
# docs/accepted_risks.md, docs/templates) share a top-level directory, `docs/`, whose other
# contents (docs/inprogress/*, docs/done/*) are this project's own live documents and are
# never meant to be manifest-covered. Deriving the scan list from the manifest would pull
# `docs` in wholesale and flag every real working doc as "unclassified".
for area in .claude .codex .agents templates/harness profiles; do
  [ -d "$ROOT/$area" ] || continue
  while IFS= read -r file; do
    rel="${file#"$ROOT"/}"
    if ! covered_by_manifest "$rel"; then
      echo "unclassified payload file: $rel" >&2
      failures=$((failures + 1))
    fi
  done < <(find "$ROOT/$area" -type f | sort)
done

# --- a wholly new agent-surface directory must not silently escape classification --------
# The check above only ever looks inside areas already on its curated list, so it is blind
# to an entirely new adapter directory (e.g. .cursor/, .gemini/) that has zero manifest rows
# — the exact class of bug #9 was fixed for, one level up, and the reason that list must stay
# curated rather than self-extending from directory contents alone. Heuristic: a top-level
# dot-directory containing hooks.json, settings.json, or a skills/ subdirectory looks like an
# agent surface. If nothing in the manifest references it at all, fail loudly and name both
# classification options rather than let it ship (or fail to ship) silently.
while IFS= read -r -d '' dir; do
  name=$(basename "$dir")
  [ "$name" = .git ] && continue

  looks_like_adapter=false
  [ -f "$dir/hooks.json" ] && looks_like_adapter=true
  [ -f "$dir/settings.json" ] && looks_like_adapter=true
  [ -d "$dir/skills" ] && looks_like_adapter=true
  [ "$looks_like_adapter" = true ] || continue

  rel="${dir#"$ROOT"/}"
  if ! has_manifest_entry_under "$rel"; then
    echo "unclassified agent-surface directory: $rel (contains hooks.json, settings.json," \
      "or skills/ — looks like an adapter). Add it to config/payload.tsv with disposition" \
      "'export' (ships to adopters) or 'source-only' (stays in this repo)." >&2
    failures=$((failures + 1))
  fi
done < <(find "$ROOT" -maxdepth 1 -type d -name '.*' -print0)

[ "$failures" -eq 0 ] || exit 1
echo "payload manifest coverage ok."
