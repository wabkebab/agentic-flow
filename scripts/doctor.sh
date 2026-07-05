#!/usr/bin/env bash
# doctor.sh — adoption checklist for a project using the agentic-flow scaffold.
#
# Usage:
#   scripts/doctor.sh          report required-tool and scaffold gaps
#   scripts/doctor.sh --check  same report; exits non-zero when gaps are found
set -euo pipefail

CHECK=false
case "${1:-}" in
  --check) CHECK=true ;;
  -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
failures=0
warnings=0

ok() { printf 'ok      %s\n' "$*"; }
warn() { printf 'warning %s\n' "$*"; warnings=$((warnings + 1)); }
fail() { printf 'missing %s\n' "$*"; failures=$((failures + 1)); }

require_file() {
  [ -f "$ROOT/$1" ] && ok "$1" || fail "$1"
}

require_executable() {
  [ -x "$ROOT/$1" ] && ok "$1 executable" || fail "$1 executable"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 && ok "tool: $1" || fail "tool: $1"
}

optional_tool() {
  command -v "$1" >/dev/null 2>&1 && ok "optional tool: $1" || warn "optional tool not found: $1"
}

real_make_target() {
  local target="$1"
  if ! grep -Eq "^${target}:" "$ROOT/Makefile" 2>/dev/null; then
    fail "Makefile target: $target"
    return
  fi
  if awk -v target="$target" '
    $0 ~ "^" target ":" {in_target=1; next}
    in_target && /^[[:alnum:]_.-]+:/ {exit}
    in_target && /TODO: define/ {found=1}
    END {exit found ? 0 : 1}
  ' "$ROOT/Makefile"; then
    fail "Makefile target still placeholder: $target"
  else
    ok "Makefile target wired: $target"
  fi
}

echo "agentic-flow adoption checklist"
echo "root: $ROOT"
echo

require_tool bash
require_tool make
require_tool git
require_tool jq
require_tool gh
optional_tool shellcheck
optional_tool git-claude
optional_tool git-codex

echo
require_file METHODOLOGY.md
require_file ADOPTION.md
require_file CLAUDE.md
require_file AGENTS.md
require_file Makefile
require_file .claude/settings.json
require_file scripts/docs-index.sh
require_file scripts/plan-to-issues.sh
require_file scripts/doctor.sh
require_file scripts/self-test.sh
require_file scripts/hooks/check-gate.sh
require_file scripts/hooks/block-git-add-all.sh
require_file scripts/hooks/block-push.sh
require_file docs/README.md
require_file docs/accepted_risks.md

if grep -q "{{" "$ROOT/CLAUDE.md" "$ROOT/AGENTS.md" 2>/dev/null; then
  fail "unfilled template tokens in CLAUDE.md or AGENTS.md"
else
  ok "CLAUDE.md and AGENTS.md tokens filled"
fi

if [ -f "$ROOT/.agentic-flow-version" ]; then
  version=$(sed -n '1p' "$ROOT/.agentic-flow-version")
  ok "scaffold version: $version"
else
  warn "scaffold version stamp not found: .agentic-flow-version"
fi

require_executable scripts/docs-index.sh
require_executable scripts/plan-to-issues.sh
require_executable scripts/doctor.sh
require_executable scripts/self-test.sh
require_executable scripts/hooks/check-gate.sh
require_executable scripts/hooks/block-git-add-all.sh
require_executable scripts/hooks/block-push.sh

echo
real_make_target check
real_make_target test
real_make_target test-one
real_make_target build
real_make_target run

if grep -q "scripts/hooks/check-gate.sh" "$ROOT/.claude/settings.json" 2>/dev/null; then
  ok "Stop hook wired"
else
  fail "Stop hook wired to scripts/hooks/check-gate.sh"
fi

if grep -q "scripts/hooks/block-git-add-all.sh" "$ROOT/.claude/settings.json" 2>/dev/null; then
  ok "git-add guard hook wired"
else
  fail "PreToolUse hook wired to scripts/hooks/block-git-add-all.sh"
fi

if grep -q "scripts/hooks/block-push.sh" "$ROOT/.claude/settings.json" 2>/dev/null; then
  ok "push guard hook wired"
else
  fail "PreToolUse hook wired to scripts/hooks/block-push.sh"
fi

if "$ROOT/scripts/docs-index.sh" --check >/dev/null 2>&1; then
  ok "docs index up to date"
else
  fail "docs index up to date (run scripts/docs-index.sh)"
fi

# Behavior-derived, not text-derived: a `check` recipe can look wired yet still be red.
if (cd "$ROOT" && make check) >/dev/null 2>&1; then
  ok "make check passes"
else
  fail "make check passes (run 'make check' to see why)"
fi

echo
echo "Summary: $failures missing/failed, $warnings warning(s)."

if [ "$CHECK" = true ] && [ "$failures" -gt 0 ]; then
  exit 1
fi

exit 0
