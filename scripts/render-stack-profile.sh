#!/usr/bin/env bash
# render-stack-profile.sh — apply a data-only stack profile to harness templates.
#
# Usage: scripts/render-stack-profile.sh <profile> <Makefile> [--ci <workflow.yml>]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
PROFILE=${1:-}
[ -n "$PROFILE" ] || { echo "usage: $0 <profile> <Makefile> [--ci <workflow.yml>]" >&2; exit 2; }
shift
MAKEFILE=""
CI_FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ci)
      [ "$#" -ge 2 ] || { echo "--ci requires a workflow path" >&2; exit 2; }
      CI_FILE="$2"; shift 2 ;;
    --ci=*)
      CI_FILE="${1#--ci=}"; shift ;;
    -*)
      echo "unknown flag: $1" >&2; exit 2 ;;
    *)
      [ -z "$MAKEFILE" ] || { echo "multiple Makefiles provided" >&2; exit 2; }
      MAKEFILE="$1"; shift ;;
  esac
done
[ -n "$MAKEFILE" ] || [ -n "$CI_FILE" ] \
  || { echo "usage: $0 <profile> <Makefile> [--ci <workflow.yml>]" >&2; exit 2; }
PROFILE_FILE="$ROOT/profiles/$PROFILE.tsv"
[ -f "$PROFILE_FILE" ] || { echo "unknown stack profile: $PROFILE" >&2; exit 2; }
[ -z "$MAKEFILE" ] || [ -f "$MAKEFILE" ] || { echo "Makefile not found: $MAKEFILE" >&2; exit 1; }
[ -z "$CI_FILE" ] || [ -f "$CI_FILE" ] || { echo "CI workflow not found: $CI_FILE" >&2; exit 1; }

if awk -F "$(printf '\t')" '
  /^#/ || NF == 0 { next }
  $1 !~ /^(detect|check|test|test-one|build|run|ci-setup)$/ || NF < 2 { exit 1 }
  $1 == "ci-setup" && NF != 2 { exit 1 }
  $1 == "ci-setup" && $2 ~ /\t/ { exit 1 }
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

if [ -n "$MAKEFILE" ]; then
  tmp="$MAKEFILE.tmp.$$"
  awk -v profile="$PROFILE_FILE" '
    BEGIN {
      while ((getline line < profile) > 0) {
        if (line ~ /^#/ || line == "") continue
        tab = index(line, "\t")
        key = substr(line, 1, tab - 1)
        value = substr(line, tab + 1)
        if (key == "detect" || key == "ci-setup") continue
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
        print "\t@for f in scripts/*.sh scripts/hooks/*.sh scripts/lib/*.sh; do bash -n \"$$f\" || exit 1; done"
        print "\t@scripts/docs-index.sh --check"
        print "\t@scripts/check-payload-manifest.sh"
        print "\t@scripts/check-action-pins.sh"
        print "\t@scripts/self-test.sh --fast"
      } else if (target == "test") {
        print "\t@scripts/self-test.sh --full"
        print "\t@command -v shellcheck >/dev/null 2>&1 || { echo \"shellcheck is required for make test.\" >&2; exit 1; }"
        print "\t@shellcheck scripts/*.sh scripts/hooks/*.sh scripts/lib/*.sh"
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
fi

if [ -n "$CI_FILE" ]; then
  tmp="$CI_FILE.tmp.$$"
  if awk -v profile="$PROFILE_FILE" '
    BEGIN {
      while ((getline line < profile) > 0) {
        if (line ~ /^#/ || line == "") continue
        tab = index(line, "\t")
        key = substr(line, 1, tab - 1)
        value = substr(line, tab + 1)
        if (key == "ci-setup") {
          setup_count++
          setup[setup_count] = value
        }
      }
      close(profile)
    }
    /# ── Replace this block with your stack'\''s runtime setup/ {
      seen_start++
      in_runtime = 1
      for (i = 1; i <= setup_count; i++) print setup[i]
      next
    }
    /# ── End runtime setup/ {
      if (in_runtime != 1) exit 1
      seen_end++
      in_runtime = 0
      next
    }
    in_runtime == 1 { next }
    { print }
    END {
      if (seen_start != 1 || seen_end != 1 || in_runtime == 1) exit 1
    }
  ' "$CI_FILE" > "$tmp"; then
    mv "$tmp" "$CI_FILE"
  else
    rm -f "$tmp"
    echo "CI workflow lacks exactly one runtime setup marker block: $CI_FILE" >&2
    exit 1
  fi
fi
