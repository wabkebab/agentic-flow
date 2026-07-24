#!/usr/bin/env bash
# self-test.sh — offline regression checks for the agentic-flow scaffold.
#
# In the scaffold repo (scripts/export.sh present) it runs the full suite, including the
# export invariants. In an exported project (export.sh is deliberately not copied) it skips
# the export section and checks only the local invariants: hooks and spec validation.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMPDIR_ROOT=${TMPDIR:-/tmp}
TMP=$(mktemp -d "$TMPDIR_ROOT/agentic-flow-test.XXXXXX")
PROJECT_TOKEN="$(printf '{%sPROJECT_NAME}%s' '{' '}')"
# Matches only real scaffold placeholders (double-brace UPPER_SNAKE), not the
# dollar-brace expression syntax that shipped docs quote when documenting CI workflows.
# Built with printf so this file never contains a literal placeholder to self-match.
TOKEN_RE="$(printf '{%s[A-Z][A-Z0-9_]*}%s' '{' '}')"
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
  # Exercise mutations against an isolated copy of the current checkout. The old test
  # appended sentinels to the live CLAUDE.md and docs/inprogress, then restored them in a
  # trap. Two concurrent checks could back up each other's temporary state and leave the
  # source checkout modified. Copy tracked and untracked working files instead.
  SOURCE_FIXTURE="$TMP/source"
  mkdir -p "$SOURCE_FIXTURE"
  while IFS= read -r -d '' tracked; do
    mkdir -p "$SOURCE_FIXTURE/$(dirname "$tracked")"
    cp -p "$ROOT/$tracked" "$SOURCE_FIXTURE/$tracked"
  done < <(cd "$ROOT" && git ls-files -co --exclude-standard -z)

  # Let the fixture resolve the real source HEAD for the version-stamp assertion without
  # copying or mutating the repository's git database.
  source_git_dir=$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)
  if [ -n "$source_git_dir" ]; then
    printf 'gitdir: %s\n' "$source_git_dir" > "$SOURCE_FIXTURE/.git"
  fi

  cp "$SOURCE_FIXTURE/.codex/hooks.json" "$TMP/codex-hooks.orig"
  printf '%s\n' '{"hooks":{}}' > "$SOURCE_FIXTURE/.codex/hooks.json"
  (cd "$SOURCE_FIXTURE" && AGENTIC_SELFTEST=1 scripts/doctor.sh --check) >/dev/null 2>&1 \
    && fail "doctor accepted a structurally unwired Codex hook configuration"
  cp "$TMP/codex-hooks.orig" "$SOURCE_FIXTURE/.codex/hooks.json"

  printf '%s\n' unresolved > "$SOURCE_FIXTURE/CLAUDE.md.agentic-new"
  (cd "$SOURCE_FIXTURE" && AGENTIC_SELFTEST=1 scripts/doctor.sh --check) >/dev/null 2>&1 \
    && fail "doctor accepted an unresolved scaffold merge candidate"
  rm -f "$SOURCE_FIXTURE/CLAUDE.md.agentic-new"

  DOC_LEAK_SENTINEL="$SOURCE_FIXTURE/docs/inprogress/self-test-export-leak.md"
  TARGET="$TMP/target"
  printf '%s\n' "# self-test export leak sentinel" > "$DOC_LEAK_SENTINEL"
  printf '%s\n' "# self-test root sentinel" >> "$SOURCE_FIXTURE/CLAUDE.md"
  "$SOURCE_FIXTURE/scripts/export.sh" "$TARGET" >/dev/null
  expected_version=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || printf '%s\n' unknown)

  assert_file "$TARGET/METHODOLOGY.md"
  assert_file "$TARGET/ADOPTION.md"
  assert_file "$TARGET/CLAUDE.md"
  assert_file "$TARGET/AGENTS.md"
  assert_file "$TARGET/Makefile"
  assert_file "$TARGET/.claude/settings.json"
  assert_file "$TARGET/.codex/hooks.json"
  assert_file "$TARGET/.agents/skills/plan-to-issues/SKILL.md"
  assert_file "$TARGET/config/payload.tsv"
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
  assert_no_file "$TARGET/scripts/init.sh"

  (cd "$TARGET" && scripts/docs-index.sh --check) >/dev/null

  # A fresh export must start green: its `make check` may not depend on scaffold-only
  # files (regression: `bash -n scripts/export.sh` turned every fresh adoption red and
  # made the Stop gate block from turn one).
  (cd "$TARGET" && make check) >"$TMP/target-check.log" 2>&1 \
    || { cat "$TMP/target-check.log" >&2; fail "make check failed in a fresh export"; }

  printf '%s\n' "# local edits" >> "$TARGET/CLAUDE.md"
  # Simulate an older installed scaffold so a conflict can prove that invoking a newer
  # exporter does not falsely promote the active version.
  printf '%s\n' older-source > "$TARGET/.agentic-flow-version"
  "$SOURCE_FIXTURE/scripts/export.sh" "$TARGET" >/dev/null
  assert_file "$TARGET/CLAUDE.md.agentic-new"
  grep -q "# local edits" "$TARGET/CLAUDE.md" || fail "export clobbered an existing file"
  grep -qx older-source "$TARGET/.agentic-flow-version" \
    || fail "export advanced installed version while merge conflicts remained"
  grep -qx "$expected_version" "$TARGET/.agentic-flow-candidate-version" \
    || fail "export did not record the pending candidate version"

  cp "$TARGET/CLAUDE.md.agentic-new" "$TMP/first-candidate"
  printf '%s\n' "# second candidate content" >> "$SOURCE_FIXTURE/templates/harness/CLAUDE.md"
  "$SOURCE_FIXTURE/scripts/export.sh" "$TARGET" >/dev/null
  cmp -s "$TMP/first-candidate" "$TARGET/CLAUDE.md.agentic-new" \
    || fail "repeated export overwrote an existing merge candidate"
  second_candidate="$TARGET/CLAUDE.md.agentic-new.$expected_version"
  assert_file "$second_candidate"
  grep -q "# second candidate content" "$second_candidate" \
    || fail "versioned merge candidate does not contain the new source content"

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
  AGENTIC_PROJECT_ROOT="$PINFIX" "$PIN_GUARD" >/dev/null 2>&1 \
    && fail "pin guard accepted a mutable tag pin"

  cat > "$PINFIX/.github/workflows/bad.yml" <<'YAML'
# Action pins verified: 2999-01-01
jobs:
  j:
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd
YAML
  AGENTIC_PROJECT_ROOT="$PINFIX" "$PIN_GUARD" >/dev/null 2>&1 \
    && fail "pin guard accepted a SHA pin with no version comment"

  # A well-formed pin and a local action must both pass.
  cat > "$PINFIX/.github/workflows/bad.yml" <<'YAML'
# Action pins verified: 2999-01-01
jobs:
  j:
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
      - uses: ./.github/actions/local
YAML
  AGENTIC_PROJECT_ROOT="$PINFIX" "$PIN_GUARD" >/dev/null 2>&1 \
    || fail "pin guard rejected a correctly pinned action or a local action"

  # Staleness is a warning, not an error — otherwise the calendar alone turns repos red
  # and the Stop hook starts blocking turns. --strict is what enforces.
  printf '%s\n' "# Action pins verified: 2020-01-01" > "$PINFIX/.github/workflows/stale.yml"
  AGENTIC_PROJECT_ROOT="$PINFIX" "$PIN_GUARD" >/dev/null 2>&1 \
    || fail "pin guard treated a stale stamp as fatal in default mode"
  AGENTIC_PROJECT_ROOT="$PINFIX" "$PIN_GUARD" --strict >/dev/null 2>&1 \
    && fail "pin guard --strict did not fail on a stale stamp"

  # No workflows at all is a clean pass, not an error: most fresh adoptions have none.
  mkdir -p "$TMP/pin-empty"
  AGENTIC_PROJECT_ROOT="$TMP/pin-empty" "$PIN_GUARD" >/dev/null 2>&1 \
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
# Flags between `git` and `add` are everyday usage, not evasion — the guard used to require
# `add` to follow `git` immediately and let these through (ROADMAP 1.5.3).
must_block "$ADD_GUARD" 'git -C /some/path add -A'
must_block "$ADD_GUARD" 'git -c user.name=x add .'
must_block "$ADD_GUARD" 'git -C /some/path -c core.pager=cat add --all'
must_allow "$ADD_GUARD" 'git add README.md'
must_allow "$ADD_GUARD" 'git -C /some/path add README.md'
must_allow "$ADD_GUARD" 'git add docs/inprogress/feature-x.md scripts/doctor.sh'

# --- Stop gate (check-gate.sh) -----------------------------------------------------------
# The highest-leverage hook and previously untested (ROADMAP 1.5.4). All four paths matter:
# a green check must not block, a red one must, the loop-safety escape must fire on the
# retry, and both no-op paths (no Makefile, clean tree) must stay out of the way.
GATE="$ROOT/scripts/hooks/check-gate.sh"
if [ -x "$GATE" ]; then
  GATEFIX="$TMP/gate-fixture"
  mkdir -p "$GATEFIX"
  # Hermetic: the fixture must not inherit the developer's global git config. With
  # commit.gpgsign=true set globally, the fixture commit below signs — which succeeds in an
  # interactive shell with an agent loaded and fails with git's exit 128 under the Stop
  # hook. That made this suite pass by hand and fail from the hook, for reasons having
  # nothing to do with what it tests.
  (
    cd "$GATEFIX"
    git init -q .
    git config user.email selftest@example.invalid
    git config user.name selftest
    git config commit.gpgsign false
  ) >/dev/null 2>&1

  gate_makefile() { # <shell-command-for-check>
    printf 'check:\n\t@%s\n' "$1" > "$GATEFIX/Makefile"
  }
  gate_run() { # <stop_hook_active> -> exit status
    (cd "$GATEFIX" && printf '{"stop_hook_active":%s}' "$1" | "$GATE") >/dev/null 2>&1
  }

  # Dirty tree (untracked Makefile) + passing check → allow.
  gate_makefile true
  gate_run false || fail "Stop gate blocked a turn while 'make check' was green"

  # Dirty tree + failing check → block, so the turn can't end red.
  gate_makefile 'exit 1'
  gate_run false && fail "Stop gate allowed a turn while 'make check' was red"

  # Same failure, but already inside a stop-hook continuation → warn and allow, or the
  # agent is stuck in a loop it cannot exit.
  gate_run true || fail "Stop gate did not warn-and-allow on the stop_hook_active retry"

  # No `check` target → nothing to gate on.
  printf 'other:\n\t@true\n' > "$GATEFIX/Makefile"
  gate_run false || fail "Stop gate blocked with no 'check' target in the Makefile"
  rm -f "$GATEFIX/Makefile"
  gate_run false || fail "Stop gate blocked with no Makefile at all"

  # Clean tree → skip even with a red check: pre-existing breakage must not hold an
  # unrelated, no-edit turn hostage.
  gate_makefile 'exit 1'
  (cd "$GATEFIX" && git add Makefile && git commit -q --no-gpg-sign -m "fixture") >/dev/null 2>&1 \
    || fail "gate fixture commit failed (git exit $?) — fixture is not hermetic"
  gate_run false || fail "Stop gate blocked a no-edit turn on a clean working tree"

  # Failure output must go somewhere unique per run, not a fixed shared path
  # (ROADMAP 1.5.2) — two sessions sharing one log show each other's errors.
  #
  # Assert the MECHANISM, not a filename: an earlier version of this check grepped for the
  # old path and matched the comment that documents having moved away from it. A guard that
  # a file's own changelog can trip is a guard that fails on correct code.
  grep -q 'mktemp' "$GATE" || fail "check-gate.sh does not create a per-run log with mktemp"
  if grep -qE '>[[:space:]]*"?/tmp/' "$GATE"; then
    fail "check-gate.sh still redirects output to a fixed /tmp path"
  fi
fi

SECRET_GUARD="$ROOT/scripts/hooks/scan-secrets.sh"

# The scanner reads STAGED content, so it needs a throwaway repo rather than a command
# string. Fixture credentials are ASSEMBLED from pieces: writing a real-shaped key literal
# into this file would make the scanner block every commit that touches self-test.sh.
if [ -x "$SECRET_GUARD" ]; then
  SECFIX="$TMP/secret-fixture"
  mkdir -p "$SECFIX"
  (
    cd "$SECFIX"
    git init -q .
    git config user.email selftest@example.invalid
    git config user.name selftest
  ) >/dev/null 2>&1

  secret_hook() { # <command> -> exit status
    (cd "$SECFIX" && printf '{"tool_input":{"command":"%s"}}' "$1" | "$SECRET_GUARD") >/dev/null 2>&1
  }
  # Same call with gitleaks forced off. The hook must reach the same verdict either way:
  # its behaviour may not depend on which tools happen to be installed on this machine.
  secret_hook_nogl() { # <command> -> exit status
    (cd "$SECFIX" && printf '{"tool_input":{"command":"%s"}}' "$1" \
      | AGENTIC_SKIP_GITLEAKS=1 "$SECRET_GUARD") >/dev/null 2>&1
  }
  stage() { # <content>
    (cd "$SECFIX" && git reset -q && printf '%s\n' "$1" > staged.txt && git add staged.txt)
  }

  stage "aws_key = \"$(printf 'AKIA%s' 'IOSFODNN7EXAMPLE')\""
  secret_hook 'git-claude commit -m x' && fail "secret scanner allowed a staged AWS-format key"
  secret_hook_nogl 'git-claude commit -m x' \
    && fail "secret scanner allowed an AWS-format key with gitleaks unavailable"
  secret_hook 'git status' || fail "secret scanner blocked a non-commit command"

  stage "$(printf -- '-----BEGIN RSA PRIVATE %s-----' 'KEY')"
  secret_hook 'git commit -m x' && fail "secret scanner allowed a staged private key block"
  secret_hook_nogl 'git commit -m x' \
    && fail "secret scanner allowed a private key block with gitleaks unavailable"

  # Assembled, not literal: a quoted `password = "..."` written directly into this file
  # would make the scanner block every commit that touches self-test.sh. (It did, once.)
  pw_fixture="$(printf 's3cret%s' 'passphrase')"
  stage "password = \"$pw_fixture\""
  secret_hook 'git commit -m x' && fail "secret scanner allowed a hardcoded password"
  secret_hook_nogl 'git commit -m x' \
    && fail "secret scanner allowed a hardcoded password with gitleaks unavailable"

  # Placeholders and env lookups must NOT trip it — a scanner that cries wolf gets disabled.
  stage 'password = "changeme-please"'
  secret_hook 'git commit -m x' || fail "secret scanner flagged an obvious placeholder"
  stage 'password = os.environ["PW"]'
  secret_hook 'git commit -m x' || fail "secret scanner flagged an env lookup"
  stage 'const timeout = 30000'
  secret_hook 'git commit -m x' || fail "secret scanner flagged ordinary code"

  # The escape hatch has to work, or the gate gets removed wholesale instead of bypassed.
  stage "aws_key = \"$(printf 'AKIA%s' 'IOSFODNN7EXAMPLE')\""
  (cd "$SECFIX" && printf '{"tool_input":{"command":"git commit -m x"}}' \
    | AGENTIC_ALLOW_SECRET=1 "$SECRET_GUARD") >/dev/null 2>&1 \
    || fail "AGENTIC_ALLOW_SECRET=1 did not bypass the secret scanner"

  (cd "$SECFIX" && git reset -q)
  secret_hook 'git commit -m x' || fail "secret scanner blocked a commit with nothing staged"
fi

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
