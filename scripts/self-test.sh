#!/usr/bin/env bash
# self-test.sh — offline regression checks for the agentic-flow scaffold itself.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
TMPDIR_ROOT=${TMPDIR:-/tmp}
TMP=$(mktemp -d "$TMPDIR_ROOT/agentic-flow-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "self-test failed: $*" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "expected file: $1"
}

assert_no_file() {
  [ ! -e "$1" ] || fail "unexpected file: $1"
}

TARGET="$TMP/target"
"$ROOT/scripts/export.sh" "$TARGET" >/dev/null

assert_file "$TARGET/METHODOLOGY.md"
assert_file "$TARGET/ADOPTION.md"
assert_file "$TARGET/CLAUDE.md"
assert_file "$TARGET/AGENTS.md"
assert_file "$TARGET/Makefile"
assert_file "$TARGET/.claude/settings.json"
assert_file "$TARGET/scripts/plan-to-issues.sh"
assert_file "$TARGET/scripts/doctor.sh"
assert_file "$TARGET/docs/README.md"
assert_no_file "$TARGET/scripts/export.sh"

(cd "$TARGET" && scripts/docs-index.sh --check) >/dev/null

printf '%s\n' "# local edits" >> "$TARGET/CLAUDE.md"
"$ROOT/scripts/export.sh" "$TARGET" >/dev/null
assert_file "$TARGET/CLAUDE.md.agentic-new"
grep -q "# local edits" "$TARGET/CLAUDE.md" || fail "export clobbered an existing file"

"$TARGET/scripts/hooks/block-git-add-all.sh" <<'JSON' >/dev/null 2>"$TMP/hook.err" && fail "git add -A was allowed"
{"tool_input":{"command":"git add -A"}}
JSON
grep -q "Blocked:" "$TMP/hook.err" || fail "block hook did not explain the block"

"$TARGET/scripts/hooks/block-git-add-all.sh" <<'JSON' >/dev/null
{"tool_input":{"command":"git add README.md"}}
JSON

INVALID_SPEC="$TMP/invalid-spec.json"
printf '%s\n' '{"tracking":{"title":"Plan: bad"},"steps":[]}' > "$INVALID_SPEC"
"$ROOT/scripts/plan-to-issues.sh" "$INVALID_SPEC" >/dev/null 2>"$TMP/plan.err" && fail "invalid plan spec was accepted"
grep -q "spec must include" "$TMP/plan.err" || fail "invalid plan spec did not fail validation first"

echo "self-test passed."
