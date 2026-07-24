#!/usr/bin/env bash
# lifecycle-status.sh — derive whether active implementation docs are eligible to close.
#
# Usage:
#   scripts/lifecycle-status.sh          report ACTIVE / READY / BLOCKED
#   scripts/lifecycle-status.sh --check  fail when an all-checked tracker lacks evidence
set -euo pipefail

ROOT=${AGENTIC_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
STRICT=false
case "${1:-}" in
  --check) STRICT=true ;;
  -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac

blocked=0
found=0
while IFS= read -r doc; do
  tracker_lines=$(grep -Ec '^- \[[ xX]\] ' "$doc" || true)
  [ "$tracker_lines" -gt 0 ] || continue
  found=$((found + 1))
  open=$(grep -Ec '^- \[ \] ' "$doc" || true)
  checked=$(grep -Ec '^- \[[xX]\] ' "$doc" || true)
  rel="${doc#"$ROOT"/}"

  if [ "$open" -gt 0 ]; then
    printf 'ACTIVE  %s  %s/%s tracker items complete\n' "$rel" "$checked" "$tracker_lines"
    continue
  fi

  missing=""
  approval=$(grep -m1 -E '^- \*\*Approval:\*\*' "$doc" || true)
  tracking=$(grep -m1 -E '^- \*\*Tracking issue:\*\*' "$doc" || true)
  evidence=$(grep -m1 -E '^- \*\*Verification evidence:\*\*' "$doc" || true)
  review=$(grep -m1 -E '^- \*\*Review verdict:\*\*' "$doc" || true)

  printf '%s' "$approval" | grep -Eiq 'approved|accepted|user approved' \
    || missing="$missing approval"
  printf '%s' "$tracking" | grep -Eq 'https?://' \
    || missing="$missing tracking-link"
  printf '%s' "$evidence" | grep -Eq 'https?://' \
    || missing="$missing verification-evidence"
  printf '%s' "$review" | grep -Eiq 'approved|pass|accepted' \
    || missing="$missing review-verdict"

  if [ -z "$missing" ]; then
    printf 'READY   %s  eligible to move to done/\n' "$rel"
  else
    printf 'BLOCKED %s  all tracker items checked; missing:%s\n' "$rel" "$missing"
    blocked=$((blocked + 1))
  fi
done < <(find "$ROOT/docs/inprogress" -type f -name '*.md' | sort)

[ "$found" -gt 0 ] || echo "No active implementation trackers found."
if [ "$STRICT" = true ] && [ "$blocked" -gt 0 ]; then
  exit 1
fi
