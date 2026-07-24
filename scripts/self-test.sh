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
PROJECT_TOKEN="$(printf '{%sPROJECT_NAME}%s' '{' '}')"
# Matches only real scaffold placeholders (double-brace UPPER_SNAKE), not the
# dollar-brace expression syntax that shipped docs quote when documenting CI workflows.
# Built with printf so this file never contains a literal placeholder to self-match.
TOKEN_RE="$(printf '{%s[A-Z][A-Z0-9_]*}%s' '{' '}')"
trap 'if [ -f "$TMP/CLAUDE.md.orig" ]; then cp "$TMP/CLAUDE.md.orig" "$ROOT/CLAUDE.md"; fi; rm -rf "$TMP"; rm -f "$DOC_LEAK_SENTINEL"' EXIT

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
  cp "$ROOT/CLAUDE.md" "$TMP/CLAUDE.md.orig"
  printf '%s\n' "# self-test export leak sentinel" > "$DOC_LEAK_SENTINEL"
  printf '%s\n' "# self-test root sentinel" >> "$ROOT/CLAUDE.md"
  "$ROOT/scripts/export.sh" "$TARGET" >/dev/null
  expected_version=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || printf '%s\n' unknown)

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
  assert_file "$TARGET/templates/ci/ci.yml"
  assert_file "$TARGET/templates/ci/deploy.yml"
  assert_file "$TARGET/templates/ci/README.md"
  # CI templates ship inert: adopting the harness must never activate a workflow —
  # least of all deploy.yml — behind the adopter's back.
  assert_no_file "$TARGET/.github/workflows/ci.yml"
  assert_no_file "$TARGET/.github/workflows/deploy.yml"
  # Every job in ci-gate's needs must also be asserted in its result loop, or the gate
  # reports green for a job nothing checked.
  for job in secrets-scan app docs; do
    grep -q "needs\.$job\.result" "$TARGET/templates/ci/ci.yml" \
      || fail "ci.yml gate loop does not assert on job '$job'"
  done
  assert_file "$TARGET/docs/backlog/.gitkeep"
  assert_file "$TARGET/docs/inprogress/.gitkeep"
  assert_file "$TARGET/docs/done/.gitkeep"
  assert_file "$TARGET/docs/done/security/.gitkeep"
  assert_file "$TARGET/.agentic-flow-version"
  grep -qx "$expected_version" "$TARGET/.agentic-flow-version" \
    || fail "export version stamp did not match source HEAD"
  grep -q "$PROJECT_TOKEN" "$TARGET/CLAUDE.md" \
    || fail "exported CLAUDE.md did not come from the tokenized harness template"
  if grep -q "# self-test root sentinel" "$TARGET/CLAUDE.md"; then
    fail "exported CLAUDE.md came from the repo root instead of templates/harness"
  fi
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

  rm -f "$DOC_LEAK_SENTINEL"
  cp "$TMP/CLAUDE.md.orig" "$ROOT/CLAUDE.md"
  (cd "$ROOT" && AGENTIC_SELFTEST=1 scripts/doctor.sh --check) >"$TMP/doctor.log" 2>&1 \
    || { cat "$TMP/doctor.log" >&2; fail "doctor --check failed on the scaffold repo"; }

  INIT_TARGET="$TMP/init-empty"
  "$ROOT/scripts/init.sh" "$INIT_TARGET" --name demo-proj --stack none --yes >"$TMP/init-empty.log" 2>&1 \
    || { cat "$TMP/init-empty.log" >&2; fail "init failed for an empty target"; }
  if grep -RE "$TOKEN_RE" "$INIT_TARGET" >/dev/null 2>&1; then
    grep -RE "$TOKEN_RE" "$INIT_TARGET" >&2 || true
    fail "init left unfilled template tokens in an empty target"
  fi
  grep -q "demo-proj" "$INIT_TARGET/CLAUDE.md" || fail "init did not stamp project name in CLAUDE.md"
  grep -q "demo-proj" "$INIT_TARGET/AGENTS.md" || fail "init did not stamp project name in AGENTS.md"
  assert_file "$INIT_TARGET/.agentic-flow-version"
  (cd "$INIT_TARGET" && make check) >"$TMP/init-empty-check.log" 2>&1 \
    || { cat "$TMP/init-empty-check.log" >&2; fail "make check failed in initialized target"; }

  INIT_EXISTING="$TMP/init-existing"
  mkdir -p "$INIT_EXISTING"
  printf '%s\n' "# Existing project guidance" > "$INIT_EXISTING/CLAUDE.md"
  "$ROOT/scripts/init.sh" "$INIT_EXISTING" --name demo-proj --stack none --yes >"$TMP/init-existing.log" 2>&1 \
    || { cat "$TMP/init-existing.log" >&2; fail "init failed for a target with existing CLAUDE.md"; }
  grep -qx "# Existing project guidance" "$INIT_EXISTING/CLAUDE.md" \
    || fail "init modified a pre-existing CLAUDE.md"
  assert_file "$INIT_EXISTING/CLAUDE.md.agentic-new"
  grep -q "demo-proj" "$INIT_EXISTING/CLAUDE.md.agentic-new" \
    || fail "init did not fill project name in CLAUDE.md.agentic-new"
  if grep -Eq "$TOKEN_RE" "$INIT_EXISTING/CLAUDE.md.agentic-new"; then
    fail "init left an unfilled token in CLAUDE.md.agentic-new"
  fi

  "$ROOT/scripts/init.sh" "$TMP/init-missing-name" --yes >"$TMP/init-missing.out" 2>"$TMP/init-missing.err" \
    && fail "init accepted --yes without --name"
  grep -q -- "--name is required" "$TMP/init-missing.err" \
    || fail "init missing-name error did not explain --name requirement"

  INIT_NONTty="$TMP/init-nontty"
  "$ROOT/scripts/init.sh" "$INIT_NONTty" --name pipe-proj --stack none < /dev/null >"$TMP/init-nontty.log" 2>&1 \
    || { cat "$TMP/init-nontty.log" >&2; fail "init non-TTY fallback failed"; }
  grep -q "pipe-proj" "$INIT_NONTty/CLAUDE.md" || fail "non-TTY init did not stamp project name"
  if grep -RE "$TOKEN_RE" "$INIT_NONTty" >/dev/null 2>&1; then
    fail "non-TTY init left unfilled template tokens"
  fi
fi

# --- shellcheck is required, not optional ------------------------------------------------
# A lint that skips when its tool is missing reports green for the wrong reason — that is
# exactly how `make test` sat red-but-passing until someone installed shellcheck.
#
# Asserted by reading the recipes, NOT by running `make test` under a stripped PATH: this
# script IS what `make test` runs, so invoking it would recurse without bound.
for mf in "$ROOT/Makefile" "$ROOT/templates/harness/Makefile"; do
  [ -f "$mf" ] || continue
  grep -q "shellcheck" "$mf" || fail "$mf does not run shellcheck in 'make test'"
  if grep -qi "shellcheck not found; skipping" "$mf"; then
    fail "$mf skips shellcheck when absent instead of failing"
  fi
done

# --- action-pin guard (run everywhere) ---------------------------------------------------
# The guard's whole value is discriminating a mutable tag pin from an immutable SHA pin.
# Assert it FAILS on bad input first — a checker that only ever passes proves nothing.
PIN_GUARD="$ROOT/scripts/check-action-pins.sh"
if [ -x "$PIN_GUARD" ]; then
  PINFIX="$TMP/pinfix"
  mkdir -p "$PINFIX/.github/workflows"

  cat > "$PINFIX/.github/workflows/bad.yml" <<'YAML'
# Action pins verified: 2999-01-01
jobs:
  j:
    steps:
      - uses: actions/checkout@v4
YAML
  (cd "$PINFIX" && "$PIN_GUARD") >/dev/null 2>&1 && fail "pin guard accepted a mutable tag pin"

  cat > "$PINFIX/.github/workflows/bad.yml" <<'YAML'
# Action pins verified: 2999-01-01
jobs:
  j:
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd
YAML
  (cd "$PINFIX" && "$PIN_GUARD") >/dev/null 2>&1 && fail "pin guard accepted a SHA pin with no version comment"

  # A well-formed pin and a local action must both pass.
  cat > "$PINFIX/.github/workflows/bad.yml" <<'YAML'
# Action pins verified: 2999-01-01
jobs:
  j:
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
      - uses: ./.github/actions/local
YAML
  (cd "$PINFIX" && "$PIN_GUARD") >/dev/null 2>&1 \
    || fail "pin guard rejected a correctly pinned action or a local action"

  # Staleness is a warning, not an error — otherwise the calendar alone turns repos red
  # and the Stop hook starts blocking turns. --strict is what enforces.
  printf '%s\n' "# Action pins verified: 2020-01-01" > "$PINFIX/.github/workflows/stale.yml"
  (cd "$PINFIX" && "$PIN_GUARD") >/dev/null 2>&1 \
    || fail "pin guard treated a stale stamp as fatal in default mode"
  (cd "$PINFIX" && "$PIN_GUARD" --strict) >/dev/null 2>&1 \
    && fail "pin guard --strict did not fail on a stale stamp"

  # No workflows at all is a clean pass, not an error: most fresh adoptions have none.
  mkdir -p "$TMP/pin-empty"
  (cd "$TMP/pin-empty" && "$PIN_GUARD") >/dev/null 2>&1 \
    || fail "pin guard failed in a project with no workflow files"

  # The shipped templates must satisfy their own guard.
  (cd "$ROOT" && "$PIN_GUARD") >/dev/null 2>&1 \
    || fail "shipped templates/ci workflows fail the pin guard"
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
