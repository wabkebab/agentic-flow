#!/usr/bin/env bash
# self-test.sh — offline regression checks for the agentic-flow scaffold.
#
# In the scaffold repo (scripts/export.sh present) it runs the full suite, including the
# export invariants. In an exported project (export.sh is deliberately not copied) it skips
# the export section and checks only the local invariants: hooks and spec validation.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
TMPDIR_ROOT=${TMPDIR:-/tmp}
TMP=$(mktemp -d "$TMPDIR_ROOT/agentic-flow-test.XXXXXX")
DOC_LEAK_SENTINEL="$ROOT/docs/inprogress/self-test-export-leak.md"
trap 'rm -rf "$TMP"; rm -f "$DOC_LEAK_SENTINEL"' EXIT

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

# Feed a PreToolUse hook a Bash tool call and assert it blocks / allows.
must_block() { # <hook> <command>
  printf '{"tool_input":{"command":"%s"}}' "$2" | "$1" >/dev/null 2>&1 && fail "hook allowed: $2"
  true
}

must_allow() { # <hook> <command>
  printf '{"tool_input":{"command":"%s"}}' "$2" | "$1" >/dev/null 2>&1 || fail "hook blocked: $2"
}

# --- export invariants (scaffold repo only) ---------------------------------------------
if [ -f "$ROOT/scripts/export.sh" ]; then
  TARGET="$TMP/target"
  printf '%s\n' "# self-test export leak sentinel" > "$DOC_LEAK_SENTINEL"
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
  assert_file "$TARGET/docs/templates/feature-analysis.md"
  assert_file "$TARGET/docs/accepted_risks.md"
  assert_file "$TARGET/docs/backlog/.gitkeep"
  assert_file "$TARGET/docs/inprogress/.gitkeep"
  assert_file "$TARGET/docs/done/.gitkeep"
  assert_file "$TARGET/docs/done/security/.gitkeep"
  assert_no_file "$TARGET/docs/inprogress/feature-init-and-template-split.md"
  assert_no_file "$TARGET/docs/inprogress/self-test-export-leak.md"
  assert_no_file "$TARGET/scripts/export.sh"

  (cd "$TARGET" && scripts/docs-index.sh --check) >/dev/null

  # A fresh export must start green: its `make check` may not depend on scaffold-only
  # files (regression: `bash -n scripts/export.sh` turned every fresh adoption red and
  # made the Stop gate block from turn one).
  (cd "$TARGET" && make check) >"$TMP/target-check.log" 2>&1 \
    || { cat "$TMP/target-check.log" >&2; fail "make check failed in a fresh export"; }

  printf '%s\n' "# local edits" >> "$TARGET/CLAUDE.md"
  "$ROOT/scripts/export.sh" "$TARGET" >/dev/null
  assert_file "$TARGET/CLAUDE.md.agentic-new"
  grep -q "# local edits" "$TARGET/CLAUDE.md" || fail "export clobbered an existing file"
fi

# --- hook invariants (run everywhere) ----------------------------------------------------
ADD_GUARD="$ROOT/scripts/hooks/block-git-add-all.sh"

"$ADD_GUARD" <<'JSON' >/dev/null 2>"$TMP/hook.err" && fail "git add -A was allowed"
{"tool_input":{"command":"git add -A"}}
JSON
grep -q "Blocked:" "$TMP/hook.err" || fail "block hook did not explain the block"

must_block "$ADD_GUARD" 'git add .'
must_block "$ADD_GUARD" 'git-claude add --all'
must_allow "$ADD_GUARD" 'git add README.md'
must_allow "$ADD_GUARD" 'git add docs/inprogress/feature-x.md scripts/doctor.sh'

PUSH_GUARD="$ROOT/scripts/hooks/block-push.sh"

must_block "$PUSH_GUARD" 'git push'
must_block "$PUSH_GUARD" 'git push origin main --force'
must_block "$PUSH_GUARD" 'git -C /some/path push'
must_block "$PUSH_GUARD" 'git-claude push origin HEAD'
must_block "$PUSH_GUARD" 'git status && git push'
must_block "$PUSH_GUARD" 'gh pr merge 12'
must_allow "$PUSH_GUARD" 'git pull --rebase'
must_allow "$PUSH_GUARD" 'gh pr view 12'
must_allow "$PUSH_GUARD" 'echo push'

# --- plan-to-issues spec validation ------------------------------------------------------
INVALID_SPEC="$TMP/invalid-spec.json"
printf '%s\n' '{"tracking":{"title":"Plan: bad"},"steps":[]}' > "$INVALID_SPEC"
"$ROOT/scripts/plan-to-issues.sh" "$INVALID_SPEC" >/dev/null 2>"$TMP/plan.err" && fail "invalid plan spec was accepted"
grep -q "spec must include" "$TMP/plan.err" || fail "invalid plan spec did not fail validation first"

echo "self-test passed."
