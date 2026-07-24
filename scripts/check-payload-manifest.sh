#!/usr/bin/env bash
# check-payload-manifest.sh — fail when an adapter/template/profile file is unclassified.
set -euo pipefail

ROOT=${AGENTIC_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
MANIFEST="$ROOT/config/payload.tsv"
[ -f "$MANIFEST" ] || { echo "payload manifest not found: $MANIFEST" >&2; exit 1; }

failures=0
for area in .claude .codex .agents templates/harness profiles; do
  [ -d "$ROOT/$area" ] || continue
  while IFS= read -r file; do
    rel="${file#"$ROOT"/}"
    covered=false
    while IFS="$(printf '\t')" read -r source _manifest_rest; do
      case "${source:-}" in ""|\#*) continue ;; esac
      case "$rel" in
        "$source"|"$source"/*) covered=true; break ;;
      esac
    done < "$MANIFEST"
    if [ "$covered" = false ]; then
      echo "unclassified payload file: $rel" >&2
      failures=$((failures + 1))
    fi
  done < <(find "$ROOT/$area" -type f | sort)
done

[ "$failures" -eq 0 ] || exit 1
echo "payload manifest coverage ok."
