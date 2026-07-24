#!/usr/bin/env bash
# render-stack-profile.sh — apply a data-only stack profile to a harness Makefile.
#
# Usage: scripts/render-stack-profile.sh <profile> <Makefile>
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
PROFILE=${1:-}
MAKEFILE=${2:-}
[ -n "$PROFILE" ] && [ -n "$MAKEFILE" ] \
  || { echo "usage: $0 <profile> <Makefile>" >&2; exit 2; }
PROFILE_FILE="$ROOT/profiles/$PROFILE.tsv"
[ -f "$PROFILE_FILE" ] || { echo "unknown stack profile: $PROFILE" >&2; exit 2; }
[ -f "$MAKEFILE" ] || { echo "Makefile not found: $MAKEFILE" >&2; exit 1; }

if awk -F "$(printf '\t')" '
  /^#/ || NF == 0 { next }
  $1 !~ /^(detect|check|test|test-one|build|run)$/ || NF < 2 { exit 1 }
' "$PROFILE_FILE"; then
  :
else
  echo "invalid stack profile: $PROFILE_FILE" >&2
  exit 1
fi
for required_target in test test-one build run; do
  grep -q "^${required_target}$(printf '\t')" "$PROFILE_FILE" \
    || { echo "stack profile lacks '$required_target': $PROFILE_FILE" >&2; exit 1; }
done

tmp="$MAKEFILE.tmp.$$"
awk -v profile="$PROFILE_FILE" '
  BEGIN {
    while ((getline line < profile) > 0) {
      if (line ~ /^#/ || line == "") continue
      tab = index(line, "\t")
      key = substr(line, 1, tab - 1)
      value = substr(line, tab + 1)
      if (key == "detect") continue
      count[key]++
      command[key, count[key]] = value
    }
    close(profile)
  }
  function profile_commands(target, i) {
    for (i = 1; i <= count[target]; i++) print "\t@" command[target, i]
  }
  function base_commands(target) {
    if (target == "check") {
      print "\t@for f in scripts/*.sh scripts/hooks/*.sh; do bash -n \"$$f\" || exit 1; done"
      print "\t@scripts/docs-index.sh --check"
      print "\t@scripts/check-payload-manifest.sh"
      print "\t@scripts/check-action-pins.sh"
      print "\t@scripts/self-test.sh"
    } else if (target == "test") {
      print "\t@command -v shellcheck >/dev/null 2>&1 || { echo \"shellcheck is required for make test.\" >&2; exit 1; }"
      print "\t@shellcheck scripts/*.sh scripts/hooks/*.sh"
    }
  }
  skip == 1 && /^[A-Za-z0-9_.-]+:/ { skip=0 }
  skip == 1 { next }
  /^(check|test|test-one|build|run):/ {
    target=$0
    sub(/:.*/, "", target)
    print
    base_commands(target)
    profile_commands(target)
    skip=1
    next
  }
  { print }
' "$MAKEFILE" > "$tmp"
mv "$tmp" "$MAKEFILE"
