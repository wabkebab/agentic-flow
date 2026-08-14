#!/usr/bin/env bash
# self-test.sh — offline regression checks for the agentic-flow scaffold.
#
# In the scaffold repo (scripts/export.sh present) it runs the full suite, including the
# export invariants. In an exported project (export.sh is deliberately not copied) it skips
# the export section and checks only the local invariants: hooks and spec validation.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
SELF_TEST_MODE=fast
ONLY_GROUP=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fast)
      SELF_TEST_MODE=fast
      shift
      ;;
    --full)
      SELF_TEST_MODE=full
      shift
      ;;
    --only)
      [ "$#" -ge 2 ] || { echo "error: --only requires a group" >&2; exit 2; }
      ONLY_GROUP="$2"
      shift 2
      ;;
    -h|--help)
      echo "usage: $0 [--fast|--full|--only export|contracts|hooks|plan-to-issues|lifecycle|upgrade]" >&2
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done
# The one list both the flag parser and every `should_run` call site are checked against.
SELF_TEST_GROUPS="export contracts hooks plan-to-issues lifecycle upgrade"
GROUPS_RAN=" "
case " $SELF_TEST_GROUPS " in
  *" $ONLY_GROUP "*) ;;
  *) [ -z "$ONLY_GROUP" ] || { echo "unknown self-test group: $ONLY_GROUP" >&2; exit 2; } ;;
esac
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

tree_digest() { # <root>
  (
    cd "$1"
    find . -path './.git' -prune -o -type f -print | sort | while IFS= read -r file; do
      cksum "$file"
      printf '%s\n' "$file"
    done
  ) | cksum
}

assert_exported_harness_file() { # <file> <expected-first-non-empty-line>
  file="$1"
  expected_heading="$2"
  assert_file "$file"
  actual_heading=$(sed -n '/[^[:space:]]/{p;q;}' "$file")
  [ "$actual_heading" = "$expected_heading" ] \
    || fail "$file first non-empty line was '$actual_heading', expected '$expected_heading'"
  # Case-insensitive net over the note's recurring markers, not just its two most literal
  # phrases — a rewording that drops "export.sh"/"repo-root copy" but keeps "pristine form"
  # or "maintainer" still trips this. An arbitrary paraphrase avoiding all four can still slip
  # past; that residual gap is accepted, not solved, by a grep-based test.
  if grep -Eqi 'export\.sh|repo-root copy|pristine form|maintainer' "$file"; then
    fail "$file contains scaffold-maintainer export note text"
  fi
}

assert_active_ci_workflow() { # <workflow.yml>
  workflow="$1"
  assert_file "$workflow"
  if LC_ALL=C grep -q "$(printf '\t')" "$workflow"; then
    fail "$workflow contains a literal tab"
  fi
  grep -q '^name:' "$workflow" || fail "$workflow lacks top-level name"
  grep -q '^on:' "$workflow" || fail "$workflow lacks top-level on"
  grep -q '^permissions:' "$workflow" || fail "$workflow lacks top-level permissions"
  grep -q '^jobs:' "$workflow" || fail "$workflow lacks top-level jobs"
  grep -q '<[^>]*>' "$workflow" && fail "$workflow contains angle-bracket placeholders"
  assert_ci_gate_needs_asserted "$workflow"
}

assert_ci_gate_needs_asserted() { # <workflow.yml>
  workflow="$1"
  needs_csv=$(awk '
    /^[[:space:]]+ci-gate:/ { in_gate=1; next }
    in_gate && /^[[:space:]][A-Za-z0-9_-]+:/ { exit }
    in_gate && /^[[:space:]]+needs:/ {
      line=$0
      sub(/^[[:space:]]+needs:[[:space:]]*\[/, "", line)
      sub(/\][[:space:]]*$/, "", line)
      gsub(/[[:space:]]/, "", line)
      print line
      exit
    }
  ' "$workflow")
  [ -n "$needs_csv" ] || fail "$workflow ci-gate needs list was not found"

  # ci-gate must depend on every OTHER top-level job — derived from the workflow's actual
  # job set rather than a hand-maintained literal string. A hardcoded list only catches a
  # job being ADDED without updating it (and only by accident, since editing the needs:
  # array and forgetting this string are the same slip); it says nothing if a job is silently
  # DROPPED from needs, which is the more dangerous direction — that's exactly how #30
  # happened; nothing here should reproduce a milder version of the same drift one line up.
  other_jobs=$(awk '
    /^jobs:/ { in_jobs=1; next }
    in_jobs && /^[A-Za-z]/ { in_jobs=0 }
    in_jobs && /^  [A-Za-z0-9_-]+:/ {
      line=$0
      sub(/^  /, "", line)
      sub(/:.*/, "", line)
      if (line != "ci-gate") print line
    }
  ' "$workflow" | sort | tr '\n' ',' | sed 's/,$//')
  needs_sorted=$(printf '%s\n' "$needs_csv" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')
  [ "$needs_sorted" = "$other_jobs" ] \
    || fail "$workflow ci-gate needs list ($needs_csv) does not match its actual job set ($other_jobs)"

  IFS=, read -r -a ci_gate_needs <<< "$needs_csv"
  for job in "${ci_gate_needs[@]}"; do
    grep -q "needs\.$job\.result" "$workflow" \
      || fail "$workflow ci-gate loop does not assert on job '$job'"
  done
}

path_without_tools() { # <output-dir> <tool>...
  out_dir="$1"
  shift
  mkdir -p "$out_dir"
  old_ifs=$IFS
  IFS=:
  for path_dir in $PATH; do
    [ -d "$path_dir" ] || continue
    for candidate in "$path_dir"/*; do
      [ -f "$candidate" ] || continue
      [ -x "$candidate" ] || continue
      name=${candidate##*/}
      skip=false
      for blocked in "$@"; do
        [ "$name" = "$blocked" ] && skip=true
      done
      [ "$skip" = true ] && continue
      [ -e "$out_dir/$name" ] || ln -s "$candidate" "$out_dir/$name"
    done
  done
  IFS=$old_ifs
  printf '%s\n' "$out_dir"
}

# Feed a PreToolUse hook a Bash tool call and assert it blocks / allows.
must_block() { # <hook> <command>
  printf '{"tool_input":{"command":"%s"}}' "$2" | "$1" >/dev/null 2>&1 && fail "hook allowed: $2"
  true
}

must_allow() { # <hook> <command>
  printf '{"tool_input":{"command":"%s"}}' "$2" | "$1" >/dev/null 2>&1 || fail "hook blocked: $2"
}

# Same two assertions with jq absent. The guards used jq only to pull the command out of the
# payload and exited 0 — a silent allow — when it was missing, so a jq-less machine ran with
# every PreToolUse guard quietly disabled. Behaviour may not depend on which tools happen to
# be installed, exactly as already asserted for gitleaks below. NOJQ_PATH is set by the hooks
# group before these run.
must_block_nojq() { # <hook> <command>
  printf '{"tool_input":{"command":"%s"}}' "$2" \
    | PATH="$NOJQ_PATH" "$1" >/dev/null 2>&1 && fail "hook allowed without jq: $2"
  true
}

must_allow_nojq() { # <hook> <command>
  printf '{"tool_input":{"command":"%s"}}' "$2" \
    | PATH="$NOJQ_PATH" "$1" >/dev/null 2>&1 || fail "hook blocked without jq: $2"
}

should_run() { # <group>
  # Validate the CALL SITE, not just the user's --only value. A drifted label here would
  # match nothing, so `--only <group>` would fall through to "self-test passed." having
  # asserted nothing — green for the wrong reason, on the gate AGENTS.md tells the
  # executor to run per step. GROUPS_RAN + the tail check below close the other half:
  # a group whose guard stops firing at all.
  case " $SELF_TEST_GROUPS " in
    *" $1 "*) ;;
    *) fail "unknown self-test group at call site: $1" ;;
  esac
  if [ -n "$ONLY_GROUP" ]; then
    [ "$ONLY_GROUP" = "$1" ] || return 1
  elif [ "$SELF_TEST_MODE" != full ] && [ "$1" = export ]; then
    return 1
  fi
  GROUPS_RAN="$GROUPS_RAN $1 "
  return 0
}

# --- export invariants (scaffold repo only, full suite only) -----------------------------
if should_run export; then
if [ -f "$ROOT/scripts/export.sh" ]; then
  # Exercise mutations against an isolated copy of the current checkout. The old test
  # appended sentinels to the live CLAUDE.md and docs/inprogress, then restored them in a
  # trap. Two concurrent checks could back up each other's temporary state and leave the
  # source checkout modified. Copy tracked and untracked working files instead.
  SOURCE_FIXTURE="$TMP/source"
  mkdir -p "$SOURCE_FIXTURE"
  while IFS= read -r -d '' tracked; do
    [ -e "$ROOT/$tracked" ] || continue
    mkdir -p "$SOURCE_FIXTURE/$(dirname "$tracked")"
    cp -p "$ROOT/$tracked" "$SOURCE_FIXTURE/$tracked"
  done < <(cd "$ROOT" && git ls-files -co --exclude-standard -z)

  # Let the fixture resolve the real source HEAD for the version-stamp assertion without
  # copying or mutating the repository's git database.
  source_git_dir=$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)
  if [ -n "$source_git_dir" ]; then
    printf 'gitdir: %s\n' "$source_git_dir" > "$SOURCE_FIXTURE/.git"
  fi

  assert_active_ci_workflow "$SOURCE_FIXTURE/.github/workflows/ci.yml"

  printf '%s\n' '{}' > "$SOURCE_FIXTURE/.codex/unclassified.json"
  AGENTIC_PROJECT_ROOT="$SOURCE_FIXTURE" \
    "$SOURCE_FIXTURE/scripts/check-payload-manifest.sh" >/dev/null 2>&1 \
    && fail "payload coverage accepted an unclassified Codex adapter file"
  rm -f "$SOURCE_FIXTURE/.codex/unclassified.json"

  # A wholly new adapter-shaped directory (not just a stray file inside a known one, #18)
  # must fail until it is classified, then pass once it is.
  cp "$SOURCE_FIXTURE/config/payload.tsv" "$TMP/payload.tsv.orig"
  mkdir -p "$SOURCE_FIXTURE/.cursor"
  printf '%s\n' '{}' > "$SOURCE_FIXTURE/.cursor/hooks.json"
  AGENTIC_PROJECT_ROOT="$SOURCE_FIXTURE" \
    "$SOURCE_FIXTURE/scripts/check-payload-manifest.sh" >/dev/null 2>&1 \
    && fail "payload coverage accepted a brand-new unclassified adapter directory"
  printf '.cursor\t.cursor\tsource-only\tnone\tsource-only\n' >> "$SOURCE_FIXTURE/config/payload.tsv"
  AGENTIC_PROJECT_ROOT="$SOURCE_FIXTURE" \
    "$SOURCE_FIXTURE/scripts/check-payload-manifest.sh" >/dev/null 2>&1 \
    || fail "payload coverage still rejected a newly classified adapter directory"
  cp "$TMP/payload.tsv.orig" "$SOURCE_FIXTURE/config/payload.tsv"
  rm -rf "$SOURCE_FIXTURE/.cursor"

  # A source-only manifest entry naming a DIRECTORY, not just a file, must exclude the
  # whole subtree on export (#17) — is_excluded() used to compare source-only paths by
  # exact equality, so a directory entry matched nothing and its contents were copied
  # straight through. Uses its own throwaway destination so it never touches $TARGET,
  # which later assertions in this section depend on staying in its original state.
  mkdir -p "$SOURCE_FIXTURE/scripts/private_probe"
  printf '%s\n' "should never leave the source repo" \
    > "$SOURCE_FIXTURE/scripts/private_probe/tool.sh"
  printf 'scripts/private_probe\tscripts/private_probe\tsource-only\tnone\tsource-only\n' \
    >> "$SOURCE_FIXTURE/config/payload.tsv"
  SOURCE_ONLY_DIR_TARGET="$TMP/source-only-dir-target"
  "$SOURCE_FIXTURE/scripts/export.sh" "$SOURCE_ONLY_DIR_TARGET" >/dev/null
  assert_no_file "$SOURCE_ONLY_DIR_TARGET/scripts/private_probe"
  assert_no_file "$SOURCE_ONLY_DIR_TARGET/scripts/private_probe/tool.sh"
  cp "$TMP/payload.tsv.orig" "$SOURCE_FIXTURE/config/payload.tsv"
  rm -rf "$SOURCE_FIXTURE/scripts/private_probe" "$SOURCE_ONLY_DIR_TARGET"

  cp "$SOURCE_FIXTURE/.codex/hooks.json" "$TMP/codex-hooks.orig"
  printf '%s\n' '{"hooks":{}}' > "$SOURCE_FIXTURE/.codex/hooks.json"
  (cd "$SOURCE_FIXTURE" && AGENTIC_SELFTEST=1 scripts/doctor.sh --check) >/dev/null 2>&1 \
    && fail "doctor accepted a structurally unwired Codex hook configuration"
  (cd "$SOURCE_FIXTURE" && AGENTIC_SELFTEST=1 scripts/doctor.sh --check --scope repo) >/dev/null 2>&1 \
    && fail "repo-scope doctor accepted a structurally unwired Codex hook configuration"
  cp "$TMP/codex-hooks.orig" "$SOURCE_FIXTURE/.codex/hooks.json"

  # --claude-only must actually scope the export. The scope column was validated and then
  # discarded, so the flag only rewrote opt-out prose and shipped every Codex and OpenCode
  # file regardless. AGENTS.md is `core`, not `codex`, so it must survive: CLAUDE.md links
  # to it and its OPT-OUT banner is the documented Claude-only behaviour.
  SCOPED_TARGET="$TMP/scoped-export"
  mkdir -p "$SCOPED_TARGET"
  "$SOURCE_FIXTURE/scripts/export.sh" --exclude-scope=codex --exclude-scope=opencode \
    "$SCOPED_TARGET" >/dev/null
  assert_no_file "$SCOPED_TARGET/.codex/hooks.json"
  assert_no_file "$SCOPED_TARGET/.agents/skills/plan-to-issues/SKILL.md"
  assert_no_file "$SCOPED_TARGET/.opencode/agent/code-reviewer.md"
  assert_file "$SCOPED_TARGET/AGENTS.md"
  assert_file "$SCOPED_TARGET/CLAUDE.md"
  assert_file "$SCOPED_TARGET/METHODOLOGY.md"
  assert_file "$SCOPED_TARGET/.claude/settings.json"
  assert_file "$SCOPED_TARGET/.claude/skills/plan-to-issues/SKILL.md"

  printf '%s\n' unresolved > "$SOURCE_FIXTURE/CLAUDE.md.agentic-new"
  (cd "$SOURCE_FIXTURE" && AGENTIC_SELFTEST=1 scripts/doctor.sh --check) >/dev/null 2>&1 \
    && fail "doctor accepted an unresolved scaffold merge candidate"
  rm -f "$SOURCE_FIXTURE/CLAUDE.md.agentic-new"

  # Bare (unguarded) calls here would let doctor.sh's own exit status kill this whole
  # script under `set -e` the moment an optional env tool (gh/gitleaks/git-claude/
  # git-codex) is missing from PATH — which is exactly true of this project's own CI
  # runner by design (see the "app" job's gotchas: it deliberately never installs
  # gitleaks/git-claude/git-codex). The point of this assertion is that `--scope all`
  # and the default agree with EACH OTHER, not that either happens to exit 0 on this
  # machine, so capture both outcomes explicitly instead of letting either escape.
  default_status=0
  (cd "$SOURCE_FIXTURE" && AGENTIC_SELFTEST=1 scripts/doctor.sh --check) \
    > "$TMP/doctor-default.out" 2>&1 || default_status=$?
  scope_all_status=0
  (cd "$SOURCE_FIXTURE" && AGENTIC_SELFTEST=1 scripts/doctor.sh --check --scope all) \
    > "$TMP/doctor-scope-all.out" 2>&1 || scope_all_status=$?
  cmp -s "$TMP/doctor-default.out" "$TMP/doctor-scope-all.out" \
    || fail "doctor --scope all output differed from the default all-scope run"
  [ "$default_status" -eq "$scope_all_status" ] \
    || fail "doctor --scope all exit status ($scope_all_status) differed from the default ($default_status)"

  STRIPPED_BIN=$(path_without_tools "$TMP/stripped-bin" gitleaks git-claude git-codex gh shellcheck)
  STRIPPED_PATH="$STRIPPED_BIN"
  PATH="$STRIPPED_PATH" command -v git >/dev/null 2>&1 \
    || fail "stripped PATH accidentally removed ordinary git"
  for removed_tool in gitleaks git-claude git-codex gh shellcheck; do
    PATH="$STRIPPED_PATH" command -v "$removed_tool" >/dev/null 2>&1 \
      && fail "stripped PATH still contains $removed_tool"
  done
  (cd "$SOURCE_FIXTURE" && PATH="$STRIPPED_PATH" AGENTIC_SELFTEST=1 scripts/doctor.sh --check --scope repo) \
    > "$TMP/doctor-repo-stripped.out" 2>&1 \
    || { cat "$TMP/doctor-repo-stripped.out" >&2; fail "repo-scope doctor failed on stripped PATH"; }
  grep -q "scope: repo" "$TMP/doctor-repo-stripped.out" \
    || fail "repo-scope doctor did not print its active scope"
  (cd "$SOURCE_FIXTURE" && PATH="$STRIPPED_PATH" AGENTIC_SELFTEST=1 scripts/doctor.sh --check --scope env) \
    > "$TMP/doctor-env-stripped.out" 2>&1 \
    && fail "env-scope doctor passed on stripped PATH without env tools"
  grep -q "scope: env" "$TMP/doctor-env-stripped.out" \
    || fail "env-scope doctor did not print its active scope"
  DOC_LEAK_SENTINEL="$SOURCE_FIXTURE/docs/inprogress/self-test-export-leak.md"
  TARGET="$TMP/target"
  printf '%s\n' "# self-test export leak sentinel" > "$DOC_LEAK_SENTINEL"
  printf '%s\n' "# self-test root sentinel" >> "$SOURCE_FIXTURE/CLAUDE.md"
  "$SOURCE_FIXTURE/scripts/export.sh" "$TARGET" >/dev/null
  # Mirrors export.sh's own semver+SHA computation exactly — see the comment there.
  expected_semver=$(sed -n '1p' "$ROOT/VERSION" 2>/dev/null || true)
  [ -n "$expected_semver" ] || expected_semver="0.0.0"
  expected_sha=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || printf '%s\n' unknown)
  expected_version="$expected_semver+$expected_sha"
  expected_origin=$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)

  assert_file "$TARGET/METHODOLOGY.md"
  assert_file "$TARGET/ADOPTION.md"
  assert_exported_harness_file "$TARGET/CLAUDE.md" "# CLAUDE.md — $PROJECT_TOKEN"
  assert_exported_harness_file "$TARGET/AGENTS.md" "# AGENTS.md — $PROJECT_TOKEN"
  assert_exported_harness_file "$TARGET/Makefile" "# Stack profile — the ONE place this project's build/test/run commands live."
  assert_file "$TARGET/.claude/settings.json"
  assert_file "$TARGET/.codex/hooks.json"
  assert_file "$TARGET/.agents/skills/plan-to-issues/SKILL.md"
  assert_file "$TARGET/config/payload.tsv"
  assert_file "$TARGET/scripts/plan-to-issues.sh"
  assert_file "$TARGET/scripts/doctor.sh"
  assert_file "$TARGET/scripts/lib/payload-apply.sh"
  assert_file "$TARGET/scripts/render-stack-profile.sh"
  assert_file "$TARGET/profiles/generic.tsv"
  assert_file "$TARGET/profiles/node.tsv"
  assert_file "$TARGET/profiles/python.tsv"
  assert_file "$TARGET/profiles/go.tsv"
  assert_file "$TARGET/profiles/rust.tsv"
  assert_file "$TARGET/docs/README.md"
  assert_file "$TARGET/docs/templates/feature-analysis.md"
  assert_file "$TARGET/docs/accepted_risks.md"
  assert_file "$TARGET/templates/ci/ci.yml"
  assert_file "$TARGET/templates/ci/deploy.yml"
  assert_file "$TARGET/templates/ci/release-native.yml"
  assert_file "$TARGET/templates/ci/README.md"
  # CI templates ship inert: adopting the harness must never activate a workflow —
  # least of all deploy.yml or a release workflow with `contents: write` — behind the
  # adopter's back.
  assert_no_file "$TARGET/.github/workflows/ci.yml"
  assert_no_file "$TARGET/.github/workflows/deploy.yml"
  assert_no_file "$TARGET/.github/workflows/release-native.yml"
  assert_no_file "$TARGET/.github"
  # Every job in ci-gate's needs must also be asserted in its result loop, or the gate
  # reports green for a job nothing checked.
  assert_ci_gate_needs_asserted "$TARGET/templates/ci/ci.yml"
  assert_file "$TARGET/docs/backlog/.gitkeep"
  assert_file "$TARGET/docs/inprogress/.gitkeep"
  assert_file "$TARGET/docs/done/.gitkeep"
  assert_file "$TARGET/docs/done/security/.gitkeep"
  assert_file "$TARGET/.agentic-flow-version"
  grep -qx "$expected_version" "$TARGET/.agentic-flow-version" \
    || fail "export version stamp did not match source HEAD"
  if [ -n "$expected_origin" ]; then
    assert_file "$TARGET/.agentic-flow-source"
    grep -qx "origin $expected_origin" "$TARGET/.agentic-flow-source" \
      || fail "export did not record the source origin"
    grep -qx "ref main" "$TARGET/.agentic-flow-source" \
      || fail "export did not record the default source ref"
  else
    assert_no_file "$TARGET/.agentic-flow-source"
  fi
  # VERSION is this repo's own maintainer-facing semver source; not in the manifest, so
  # nothing copies it. Only the computed semver+SHA stamp reaches a target.
  assert_no_file "$TARGET/VERSION"
  grep -q "$PROJECT_TOKEN" "$TARGET/CLAUDE.md" \
    || fail "exported CLAUDE.md did not come from the tokenized harness template"
  if grep -q "# self-test root sentinel" "$TARGET/CLAUDE.md"; then
    fail "exported CLAUDE.md came from the repo root instead of templates/harness"
  fi
  assert_no_file "$TARGET/docs/inprogress/feature-init-and-template-split.md"
  assert_no_file "$TARGET/docs/inprogress/self-test-export-leak.md"
  assert_no_file "$TARGET/scripts/export.sh"
  assert_no_file "$TARGET/scripts/init.sh"
  # shellcheck disable=SC1091 # The target is generated during this fixture.
  (cd "$TARGET" && . scripts/lib/payload-apply.sh && . scripts/lib/payload-apply.sh) \
    || fail "payload apply library was not safe to source twice"
  # templates/harness holds the pristine forms, which export to project-root destinations
  # (CLAUDE.md, AGENTS.md, Makefile) — never to templates/harness in the target. So the whole
  # subtree must be absent, which also keeps its maintainer-only README out of adopters.
  # Deliberately NOT derived from the manifest's source-only rows: a derived check stops
  # looking the moment someone flips a disposition to `export`, and passes. Stating the
  # invariant here makes that flip fail instead.
  assert_no_file "$TARGET/templates/harness/README.md"
  assert_no_file "$TARGET/templates/harness"

  (cd "$TARGET" && scripts/docs-index.sh --check) >/dev/null

  # A fresh export must start green: its `make check` may not depend on scaffold-only
  # files (regression: `bash -n scripts/export.sh` turned every fresh adoption red and
  # made the Stop gate block from turn one).
  (cd "$TARGET" && make check) >"$TMP/target-check.log" 2>&1 \
    || { cat "$TMP/target-check.log" >&2; fail "make check failed in a fresh export"; }
  (cd "$TARGET" && PATH="$STRIPPED_PATH" make check) > "$TMP/target-check-stripped.log" 2>&1 \
    || { cat "$TMP/target-check-stripped.log" >&2; fail "make check failed in a fresh export on stripped PATH"; }

  printf '%s\n' "# local edits" >> "$TARGET/CLAUDE.md"
  printf 'origin https://example.invalid/fork.git\nref v1.2.3\n' > "$TARGET/.agentic-flow-source"
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
  grep -qx "origin https://example.invalid/fork.git" "$TARGET/.agentic-flow-source" \
    || fail "re-export overwrote a hand-edited source origin"
  grep -qx "ref v1.2.3" "$TARGET/.agentic-flow-source" \
    || fail "re-export overwrote a tag-shaped source ref"

  cp "$TARGET/CLAUDE.md.agentic-new" "$TMP/first-candidate"
  printf '%s\n' "# second candidate content" >> "$SOURCE_FIXTURE/templates/harness/CLAUDE.md"
  "$SOURCE_FIXTURE/scripts/export.sh" "$TARGET" >/dev/null
  cmp -s "$TMP/first-candidate" "$TARGET/CLAUDE.md.agentic-new" \
    || fail "repeated export overwrote an existing merge candidate"
  second_candidate="$TARGET/CLAUDE.md.agentic-new.$expected_version"
  assert_file "$second_candidate"
  grep -q "# second candidate content" "$second_candidate" \
    || fail "versioned merge candidate does not contain the new source content"

  (cd "$ROOT" && AGENTIC_SELFTEST=1 scripts/doctor.sh --check --scope repo) >"$TMP/doctor.log" 2>&1 \
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

  INIT_RUST="$TMP/init-rust"
  "$ROOT/scripts/init.sh" "$INIT_RUST" --name rust-proj --stack rust --yes >"$TMP/init-rust.log" 2>&1 \
    || { cat "$TMP/init-rust.log" >&2; fail "init failed for a rust target"; }
  assert_no_file "$INIT_RUST/.github/workflows/ci.yml"
  assert_no_file "$INIT_RUST/.github/workflows/deploy.yml"
  assert_no_file "$INIT_RUST/.github"
  grep -q 'Set up Cargo toolchain' "$INIT_RUST/templates/ci/ci.yml" \
    || fail "rust init did not render a Cargo runtime setup block"
  grep -q 'cargo fetch --locked' "$INIT_RUST/templates/ci/ci.yml" \
    || fail "rust init did not render a locked Cargo dependency step"
  for node_marker in setup-node 'node-version' 'npm '; do
    if grep -q "$node_marker" "$INIT_RUST/templates/ci/ci.yml"; then
      fail "rust init leaked Node runtime marker into rendered CI template: $node_marker"
    fi
  done
  grep -q '<SRC DIRS, e.g. src/\*\*>' "$INIT_RUST/templates/ci/ci.yml" \
    || fail "rust init rewrote the project-specific source path placeholder"
  grep -q '<MANIFEST + LOCKFILE, e.g. package.json, package-lock.json>' \
    "$INIT_RUST/templates/ci/ci.yml" \
    || fail "rust init rewrote the project-specific manifest path placeholder"
  if grep -q 'Replace this block with your stack' "$INIT_RUST/templates/ci/ci.yml"; then
    fail "rust init left the runtime setup replacement marker in the rendered template"
  fi

  # Stack profiles are data, rendered by one implementation. Validate every shipped
  # profile without requiring its runtime or package manager to be installed.
  for profile in generic node python go rust; do
    profile_makefile="$TMP/Makefile.$profile"
    cp "$ROOT/templates/harness/Makefile" "$profile_makefile"
    "$ROOT/scripts/render-stack-profile.sh" "$profile" "$profile_makefile"
    if grep -q "TODO: define" "$profile_makefile"; then
      fail "$profile stack profile left placeholder Make targets"
    fi
    case "$profile" in
      generic) expected="No project build profile configured" ;;
      node) expected="npm run build" ;;
      python) expected="python3 -m build" ;;
      go) expected="go build ./..." ;;
      rust) expected="cargo build --locked" ;;
    esac
    grep -qF "$expected" "$profile_makefile" \
      || fail "$profile stack profile did not render its build command"

    profile_ci_root="$TMP/ci-root.$profile"
    mkdir -p "$profile_ci_root/templates/ci"
    profile_workflow="$profile_ci_root/templates/ci/ci.yml"
    cp "$ROOT/templates/ci/ci.yml" "$profile_workflow"
    "$ROOT/scripts/render-stack-profile.sh" "$profile" --ci "$profile_workflow"
    if grep -q 'Replace this block with your stack' "$profile_workflow" \
      || grep -q 'End runtime setup' "$profile_workflow"; then
      fail "$profile CI render left orphaned runtime setup marker comments"
    fi
    if grep -q '<MAJOR' "$profile_workflow"; then
      fail "$profile CI render left a runtime angle-bracket placeholder"
    fi
    grep -q '<SRC DIRS, e.g. src/\*\*>' "$profile_workflow" \
      || fail "$profile CI render rewrote the source path-filter placeholder"
    grep -q '<MANIFEST + LOCKFILE, e.g. package.json, package-lock.json>' "$profile_workflow" \
      || fail "$profile CI render rewrote the manifest path-filter placeholder"
    AGENTIC_PROJECT_ROOT="$profile_ci_root" "$ROOT/scripts/check-action-pins.sh" >/dev/null 2>&1 \
      || fail "$profile rendered CI workflow failed the action pin guard"

    case "$profile" in
      generic)
        for marker in setup-node 'node-version' 'npm ' cargo rustup 'go mod' python3; do
          if grep -q "$marker" "$profile_workflow"; then
            fail "generic CI render leaked runtime marker: $marker"
          fi
        done
        ;;
      node)
        grep -q 'setup-node' "$profile_workflow" \
          || fail "node CI render lacks setup-node"
        grep -q 'npm ci' "$profile_workflow" \
          || fail "node CI render lacks npm ci"
        grep -q 'node-version: 22' "$profile_workflow" \
          || fail "node CI render lacks a concrete node-version"
        for marker in cargo rustup 'go mod' python3; do
          if grep -q "$marker" "$profile_workflow"; then
            fail "node CI render leaked another runtime marker: $marker"
          fi
        done
        ;;
      python)
        grep -q 'python3 -m pip install --require-hashes' "$profile_workflow" \
          || fail "python CI render lacks locked dependency install"
        for marker in setup-node 'node-version' 'npm ' cargo rustup 'go mod'; do
          if grep -q "$marker" "$profile_workflow"; then
            fail "python CI render leaked another runtime marker: $marker"
          fi
        done
        ;;
      go)
        grep -q 'go mod download' "$profile_workflow" \
          || fail "go CI render lacks module download"
        for marker in setup-node 'node-version' 'npm ' cargo rustup python3; do
          if grep -q "$marker" "$profile_workflow"; then
            fail "go CI render leaked another runtime marker: $marker"
          fi
        done
        ;;
      rust)
        grep -q 'Set up Cargo toolchain' "$profile_workflow" \
          || fail "rust CI render lacks Cargo toolchain setup"
        grep -q 'cargo fetch --locked' "$profile_workflow" \
          || fail "rust CI render lacks locked Cargo dependency fetch"
        for marker in setup-node 'node-version' 'npm ' 'go mod' python3; do
          if grep -q "$marker" "$profile_workflow"; then
            fail "rust CI render leaked another runtime marker: $marker"
          fi
        done
        ;;
    esac
  done

  BAD_PROFILE="$SOURCE_FIXTURE/profiles/bad-ci.tsv"
  cp "$SOURCE_FIXTURE/profiles/generic.tsv" "$BAD_PROFILE"
  printf 'ci-setup\t      - name: Bad\tliteral tab\n' >> "$BAD_PROFILE"
  BAD_WORKFLOW="$TMP/bad-ci.yml"
  cp "$SOURCE_FIXTURE/templates/ci/ci.yml" "$BAD_WORKFLOW"
  "$SOURCE_FIXTURE/scripts/render-stack-profile.sh" bad-ci --ci "$BAD_WORKFLOW" >/dev/null 2>&1 \
    && fail "renderer accepted a ci-setup row containing a literal tab"

  # `make build` is the production assembly check and pipes dry-run output to /dev/null
  # into a temp dir it then deletes — so it would not notice a dry run that started
  # writing. Assert the promise in the flag's own name: it writes nothing.
  DRYRUN_TARGET="$TMP/dryrun-target"
  mkdir -p "$DRYRUN_TARGET"
  "$SOURCE_FIXTURE/scripts/export.sh" --dry-run "$DRYRUN_TARGET" >/dev/null \
    || fail "export --dry-run failed against an empty target"
  [ -z "$(find "$DRYRUN_TARGET" -mindepth 1 -print -quit)" ] \
    || fail "export --dry-run wrote into the target directory"

  # ...and does not clobber a target that already holds files.
  DRYRUN_EXISTING="$TMP/dryrun-existing"
  mkdir -p "$DRYRUN_EXISTING"
  printf 'sentinel\n' > "$DRYRUN_EXISTING/CLAUDE.md"
  "$SOURCE_FIXTURE/scripts/export.sh" --dry-run "$DRYRUN_EXISTING" >/dev/null \
    || fail "export --dry-run failed against a populated target"
  grep -qx 'sentinel' "$DRYRUN_EXISTING/CLAUDE.md" \
    || fail "export --dry-run overwrote an existing target file"
  [ "$(find "$DRYRUN_EXISTING" -mindepth 1 | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "export --dry-run added files to a populated target"

  TAG_REF_TARGET="$TMP/tag-ref-target"
  AGENTIC_FLOW_SOURCE_REF=v1.2.3 "$SOURCE_FIXTURE/scripts/export.sh" "$TAG_REF_TARGET" >/dev/null \
    || fail "export failed with a tag-shaped source ref"
  if [ -n "$expected_origin" ]; then
    grep -qx "ref v1.2.3" "$TAG_REF_TARGET/.agentic-flow-source" \
      || fail "export did not preserve a tag-shaped ref as opaque data"
  fi

  NO_REMOTE_SOURCE="$TMP/no-remote-source"
  mkdir -p "$NO_REMOTE_SOURCE"
  while IFS= read -r -d '' tracked; do
    [ -e "$ROOT/$tracked" ] || continue
    mkdir -p "$NO_REMOTE_SOURCE/$(dirname "$tracked")"
    cp -p "$ROOT/$tracked" "$NO_REMOTE_SOURCE/$tracked"
  done < <(cd "$ROOT" && git ls-files -co --exclude-standard -z)
  NO_REMOTE_TARGET="$TMP/no-remote-target"
  "$NO_REMOTE_SOURCE/scripts/export.sh" "$NO_REMOTE_TARGET" > "$TMP/no-remote-export.out" \
    || fail "export failed from a source with no git remote"
  assert_no_file "$NO_REMOTE_TARGET/.agentic-flow-source"
  grep -q "source repo has no origin remote" "$TMP/no-remote-export.out" \
    || fail "export without remote did not explain why no source was recorded"
  (cd "$NO_REMOTE_TARGET" && scripts/doctor.sh --scope repo) > "$TMP/no-source-doctor.out" \
    || fail "doctor report failed for a stamped project with no source"
  grep -q "scaffold source not recorded" "$TMP/no-source-doctor.out" \
    || fail "doctor did not warn about a stamped project with no source"

  # Regression for the scaffold-only scoping of the role-bundle word ceilings (below): an
  # oversized CLAUDE.md must still fail the check in the scaffold repo, and must NOT fail it
  # once exported, since CLAUDE.md/AGENTS.md are preserve/instance files every adopter fills
  # with real project content of whatever size that content actually needs. Extract the live
  # snippet rather than re-describing its logic, so this test breaks if the guard is ever
  # dropped instead of silently drifting from what actually runs. Rewritten to reference
  # CEILING_ROOT rather than ROOT so running it in a subshell below never shadows this
  # script's own $ROOT for shellcheck (SC2030/SC2031) or for real.
  CEILING_SNIPPET_FILE="$TMP/ceiling-snippet.sh"
  # shellcheck disable=SC2016 # literal $ROOT/$CEILING_ROOT text being rewritten, not expanded.
  sed -n '/^# Ceilings are set just above the MEASURED size of each bundle/,/reviewer static role bundle exceeds its ceiling/p' \
    "$ROOT/scripts/self-test.sh" \
    | sed 's/\$ROOT\//\$CEILING_ROOT\//g' > "$CEILING_SNIPPET_FILE"
  [ -s "$CEILING_SNIPPET_FILE" ] \
    || fail "could not extract the role-bundle ceiling snippet for its own regression test"

  run_ceiling_snippet() { # <fixture-root> <export-sh present: yes|no>
    local d="$1" has_export="$2"
    rm -rf "$d"
    mkdir -p "$d/.agents/skills/review-execution"
    printf 'word %.0s' $(seq 1 1600) > "$d/CLAUDE.md"
    printf 'word %.0s' $(seq 1 1600) > "$d/AGENTS.md"
    printf 'short reviewer skill\n' > "$d/.agents/skills/review-execution/SKILL.md"
    if [ "$has_export" = yes ]; then mkdir -p "$d/scripts"; : > "$d/scripts/export.sh"; fi
    ( # shellcheck disable=SC2034 # consumed by the sourced snippet below, not used directly here.
      CEILING_ROOT="$d"
      # shellcheck disable=SC2317,SC2329 # invoked indirectly by the sourced snippet below;
      # which of the two IDs fires is shellcheck-version-dependent (SC2317 on CI's 0.9.0,
      # SC2329 locally on 0.11.0), so both are disabled rather than chasing one.
      fail() { echo "CEILING_FAIL: $1"; }
      # shellcheck disable=SC1090 # the snippet is extracted from this file at runtime.
      . "$CEILING_SNIPPET_FILE"
    )
  }

  # Captured via command substitution, NOT piped live to grep -q: grep -q exits on its
  # first match, and the snippet still has a second echo (the executor ceiling) queued
  # behind it — writing to an already-closed pipe raises SIGPIPE, which pipefail turns
  # into a pipeline failure even though the match already succeeded. Capturing first
  # lets the subshell finish and exit cleanly before anything greps it.
  CEILING_FIXTURE="$TMP/ceiling-fixture"
  scaffold_ceiling_out=$(run_ceiling_snippet "$CEILING_FIXTURE" yes)
  printf '%s\n' "$scaffold_ceiling_out" | grep -q "planner static role bundle exceeds" \
    || fail "role-bundle ceiling did not fire for an oversized CLAUDE.md inside the scaffold repo"
  exported_ceiling_out=$(run_ceiling_snippet "$CEILING_FIXTURE" no)
  printf '%s\n' "$exported_ceiling_out" | grep -q "planner static role bundle exceeds" \
    && fail "role-bundle ceiling fired in an exported project (scripts/export.sh absent) — adopters must be allowed real project content of any size"
  rm -rf "$CEILING_FIXTURE"
fi
fi

# --- shellcheck is required, not optional ------------------------------------------------
if should_run contracts; then
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
  grep -q "scripts/self-test.sh --fast" "$mf" \
    || fail "$mf does not run fast self-test mode in 'make check'"
  grep -q "scripts/self-test.sh --full" "$mf" \
    || fail "$mf does not run full self-test mode in 'make test'"
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

# Contract drift guard: plan-to-issues genuinely needs two copies, because Codex scans only
# .agents/skills and Claude Code only .claude/skills — neither reads the other's directory —
# so a one-sided edit must fail before an agent follows stale instructions. review-execution
# needs no such pair: OpenCode discovers .agents/skills natively, so one copy serves both.
cmp -s "$ROOT/.agents/skills/plan-to-issues/SKILL.md" \
       "$ROOT/.claude/skills/plan-to-issues/SKILL.md" \
  || fail "plan-to-issues adapter copies diverged"
# shellcheck disable=SC2016 # literal Markdown backticks, not command substitution.
grep -q 'Stack profile.*`CLAUDE.md`' "$ROOT/.agents/skills/plan-to-issues/SKILL.md" \
  || fail "plan-to-issues guidance does not name CLAUDE.md as Stack profile owner"

token_line=""
token_seen=0
for token_file in "$ROOT/scripts/init.sh" "$ROOT/scripts/doctor.sh" "$ROOT/scripts/self-test.sh"; do
  [ -f "$token_file" ] || continue
  line=$(grep '^TOKEN_RE=' "$token_file" || true)
  [ -n "$line" ] || fail "$token_file lacks TOKEN_RE assignment"
  token_seen=$((token_seen + 1))
  if [ -z "$token_line" ]; then
    token_line="$line"
  elif [ "$line" != "$token_line" ]; then
    fail "TOKEN_RE assignment diverged in $token_file"
  fi
done
[ "$token_seen" -ge 2 ] || fail "not enough TOKEN_RE assignments to guard parity"
printf '%s\n%s\n' "$(printf '{%sPROJECT_NAME}%s' '{' '}')" \
  "$(printf '{%sPROJECT_123}%s' '{' '}')" | grep -Eq "$TOKEN_RE" \
  || fail "TOKEN_RE rejected valid placeholder fixtures"
# shellcheck disable=SC2016 # literal GitHub Actions expression fixture.
printf '%s\n%s\n%s\n' '${{ matrix.node }}' '{project_name}' \
  "$(printf '{%sproject-name}%s' '{' '}')" | grep -Eq "$TOKEN_RE" \
  && fail "TOKEN_RE accepted invalid placeholder fixtures"

grep -Eq '^ADOPTION\.md[[:space:]]+ADOPTION\.md[[:space:]]+core[[:space:]]+preserve[[:space:]]+export$' \
  "$ROOT/config/payload.tsv" \
  || fail "ADOPTION.md is not exported by the payload manifest"
grep -q 'require_file ADOPTION.md' "$ROOT/scripts/doctor.sh" \
  || fail "doctor no longer requires ADOPTION.md"
AGENTIC_SELFTEST=1 "$ROOT/scripts/doctor.sh" --scope repo --skip-make-check \
  >/dev/null 2>&1 \
  || fail "doctor rejected explicit repo-scope --skip-make-check"
"$ROOT/scripts/doctor.sh" --check --scope all --skip-make-check \
  >/dev/null 2>"$TMP/doctor-skip-scope.err" \
  && fail "doctor accepted --skip-make-check outside repo scope"
grep -q "only valid with --scope repo" "$TMP/doctor-skip-scope.err" \
  || fail "doctor skip-scope failure did not explain the constraint"

for role_file in "$ROOT/CLAUDE.md" "$ROOT/AGENTS.md" \
                 "$ROOT/templates/harness/CLAUDE.md" "$ROOT/templates/harness/AGENTS.md"; do
  [ -f "$role_file" ] || continue
  grep -qi 'preload the whole' "$role_file" \
    || fail "$role_file lacks the minimal read-set rule"
done
# Ceilings are set just above the MEASURED size of each bundle, not above a modelled
# "role used to preload METHODOLOGY.md" figure. A ceiling with 100%+ headroom passes no
# matter what gets re-inlined, which turns the assertion into decoration. Raising one is
# a deliberate act: move the content to its canonical home first (CLAUDE.md → routing).
#
# The planner/executor ceilings apply ONLY in the scaffold repo (scripts/export.sh present),
# never in an exported project. CLAUDE.md and AGENTS.md are "preserve" instance files —
# config/payload.tsv ships them to every adopter to fill with their OWN Stack profile,
# Architecture, and Gotchas, which is real project information the pristine template doesn't
# carry and has no reason to be bounded by this repo's own measurements. Running this
# unconditionally broke the first real adopter upgrade past this check: collector's filled-in
# CLAUDE.md measured 2227 words against a 1530 ceiling sized for the standard's own root file.
# The reviewer-skill ceiling stays unconditional — that file is pristine payload, never
# customized per project, so its size is meaningful everywhere.
if [ -f "$ROOT/scripts/export.sh" ]; then
  # Raised once, deliberately, when the review handoff became data-carrying: Codex now
  # comments the commit sha and verification on the step issue, and the reviewer closes
  # that issue itself rather than parking it at needs-closing. Every bit of *rationale* for
  # that went to METHODOLOGY.md §2/§6 (uncapped, and the canonical home); what landed in
  # the three bundles is irreducible mechanics — the state machine and the gh commands each
  # role runs. Each ceiling keeps the original ~80-word headroom over its new measured
  # size, so the assertion still bites on re-inlining rather than on one contract change.
  # For the executor the binding measurement is templates/harness/AGENTS.md (947), not this
  # repo's own root instance (869) — the same check runs inside a fresh export, where the
  # bundle carries the opt-out notes too. Size a ceiling against the larger of the pair, or
  # `make test` fails on the export while `make check` passes here.
  planner_words=$(wc -w < "$ROOT/CLAUDE.md" | tr -d ' ')
  executor_words=$(wc -w < "$ROOT/AGENTS.md" | tr -d ' ')
  [ "$planner_words" -le 1530 ] \
    || fail "planner static role bundle exceeds its ceiling: $planner_words words (max 1530)"
  [ "$executor_words" -le 1030 ] \
    || fail "executor static role bundle exceeds its ceiling: $executor_words words (max 1030)"
fi
reviewer_words=$(wc -w < "$ROOT/.agents/skills/review-execution/SKILL.md" | tr -d ' ')
[ "$reviewer_words" -le 965 ] \
  || fail "reviewer static role bundle exceeds its ceiling: $reviewer_words words (max 965)"

# One severity vocabulary across every review surface — the SKILL.md pair AND the live
# /review agent contract, which is where the old block/fix/nit scale survived an earlier
# normalization pass precisely because nothing asserted over it.
for review_surface in "$ROOT/.agents/skills/review-execution/SKILL.md" \
                      "$ROOT/.opencode/agent/code-reviewer.md"; do
  [ -f "$review_surface" ] || fail "missing review surface: $review_surface"
  for level in High Medium Low Nit; do
    grep -q "\*\*$level\*\*" "$review_surface" \
      || fail "$review_surface lacks $level severity"
  done
  grep -qi 'accepted/by-design' "$review_surface" \
    || fail "$review_surface does not name accepted/by-design as a disposition"
  # shellcheck disable=SC2016 # literal Markdown backticks, not command substitution.
  grep -qE '\*\*(Blocker|Critical)\*\*|`block`|`fix`|LGTM' "$review_surface" \
    && fail "$review_surface still uses a retired severity or verdict vocabulary"
done
grep -q 'AGENTS.md.*Engineering standards' "$ROOT/.agents/skills/review-execution/SKILL.md" \
  || fail "review skill does not route engineering standards to AGENTS.md"

# Every §N route an agent is told to follow must resolve. Emit each section on a line
# individually: a greedy `.*§([0-9]+)` keeps only the LAST one, so "§3, §5" silently
# stopped checking §3. ADOPTION.md and the docs README carry routes too.
while IFS= read -r section; do
  grep -q "^## $section\\. " "$ROOT/METHODOLOGY.md" \
    || fail "METHODOLOGY.md §$section reference has no matching section"
done < <(grep -RhoE 'METHODOLOGY\.md[^[:cntrl:]]*' \
  "$ROOT/CLAUDE.md" "$ROOT/AGENTS.md" "$ROOT/ADOPTION.md" "$ROOT/docs/README.md" \
  "$ROOT/templates" "$ROOT/docs/templates" \
  "$ROOT/.agents" "$ROOT/.opencode" "$ROOT/scripts" "$ROOT/Makefile" \
  | grep -oE '§[0-9]+' | tr -d '§' | sort -u)

# Failure-first coverage for the focused-group dispatcher itself. `make test-one F=…` is
# the executor's per-step gate, so both ways it can go quietly empty must be red.
DISPATCH_FIX="$TMP/dispatch/scripts"
mkdir -p "$DISPATCH_FIX"
sed 's/^if should_run hooks; then$/if should_run hook; then/' "$ROOT/scripts/self-test.sh" \
  > "$DISPATCH_FIX/self-test.sh"
chmod +x "$DISPATCH_FIX/self-test.sh"
cmp -s "$ROOT/scripts/self-test.sh" "$DISPATCH_FIX/self-test.sh" \
  && fail "dispatch fixture failed to rename a should_run call site"
"$DISPATCH_FIX/self-test.sh" --only hooks >/dev/null 2>"$TMP/dispatch-drift.err" \
  && fail "focused run passed with a drifted should_run call-site label"
grep -q "unknown self-test group at call site" "$TMP/dispatch-drift.err" \
  || fail "drifted call-site label did not name the problem"

sed 's/^if should_run hooks; then$/if false; then/' "$ROOT/scripts/self-test.sh" \
  > "$DISPATCH_FIX/self-test.sh"
chmod +x "$DISPATCH_FIX/self-test.sh"
"$DISPATCH_FIX/self-test.sh" --only hooks >/dev/null 2>"$TMP/dispatch-empty.err" \
  && fail "focused run passed with its group block disabled"
grep -q "self-test group 'hooks' never executed" "$TMP/dispatch-empty.err" \
  || fail "disabled group did not report that it never executed"

DOC_STAGE_FIX="$TMP/docs-stage"
mkdir -p "$DOC_STAGE_FIX/docs/unknown"
cp "$ROOT/docs/README.md" "$DOC_STAGE_FIX/docs/README.md"
cat > "$DOC_STAGE_FIX/docs/unknown/feature-bad.md" <<'MD'
<!-- TRIAGE (first pass · 2026-01-01) -->
> **Type:** Feature · **Status:** 🟦 Proposal
MD
AGENTIC_PROJECT_ROOT="$DOC_STAGE_FIX" "$ROOT/scripts/docs-index.sh" --check \
  >/dev/null 2>"$TMP/docs-stage.err" \
  && fail "docs-index accepted an undeclared docs stage"
grep -q "undeclared docs stage" "$TMP/docs-stage.err" \
  || fail "docs-index undeclared-stage failure did not explain the problem"
fi

# --- upgrade surface --------------------------------------------------------------------
if should_run upgrade; then
AGENTIC_FLOW_CLI="$ROOT/scripts/agentic-flow"
assert_file "$AGENTIC_FLOW_CLI"

OUTSIDE="$TMP/outside-project"
mkdir -p "$OUTSIDE"
(cd "$OUTSIDE" && "$AGENTIC_FLOW_CLI" status) >"$TMP/status-outside.out" 2>"$TMP/status-outside.err" \
  && fail "agentic-flow status succeeded outside an adopted project"
grep -q "no .agentic-flow-version found" "$TMP/status-outside.err" \
  || fail "status outside a project did not explain the missing stamp"

STATUS_FIX="$TMP/status-fixture"
mkdir -p "$STATUS_FIX/.claude" "$STATUS_FIX/.codex" "$STATUS_FIX/.agents" \
  "$STATUS_FIX/.opencode" "$STATUS_FIX/config" "$STATUS_FIX/scripts/lib" "$STATUS_FIX/sub/dir"
printf '%s\n' '1.2.3+abcdef0' > "$STATUS_FIX/.agentic-flow-version"
printf '%s\n' generic > "$STATUS_FIX/.agentic-flow-stack"
printf 'origin https://example.invalid/agentic-flow.git\nref main\n' \
  > "$STATUS_FIX/.agentic-flow-source"
printf '{}' > "$STATUS_FIX/.claude/settings.json"
printf '{}' > "$STATUS_FIX/.codex/hooks.json"
printf '# source\tdestination\tscope\tmerge-policy\tdisposition\n.claude/settings.json\t.claude/settings.json\tclaude\tpreserve\texport\n' \
  > "$STATUS_FIX/config/payload.tsv"
cp "$ROOT/scripts/doctor.sh" "$STATUS_FIX/scripts/doctor.sh"
cp "$ROOT/scripts/lib/payload-apply.sh" "$STATUS_FIX/scripts/lib/payload-apply.sh"
chmod +x "$STATUS_FIX/scripts/doctor.sh"
"$AGENTIC_FLOW_CLI" --help > "$TMP/agentic-flow-help.out" 2>&1
grep -q "project's installed harness stamp" "$TMP/agentic-flow-help.out" \
  || fail "agentic-flow --help did not document --version as the project stamp"
(cd "$STATUS_FIX/sub/dir" && "$AGENTIC_FLOW_CLI" status) > "$TMP/status-clean.out" \
  || fail "status did not find the nearest stamped root from a nested directory"
grep -q "installed: 1.2.3+abcdef0" "$TMP/status-clean.out" \
  || fail "status did not report the installed version"
grep -q "source: https://example.invalid/agentic-flow.git (ref main)" "$TMP/status-clean.out" \
  || fail "status did not report the recorded source"
grep -q "adapters: claude,codex,agents,opencode" "$TMP/status-clean.out" \
  || fail "status did not report adapter presence"

NO_GIT_BIN="$TMP/no-git-bin"
mkdir -p "$NO_GIT_BIN"
cat > "$NO_GIT_BIN/git" <<'FAKE_GIT'
#!/usr/bin/env bash
exit 127
FAKE_GIT
chmod +x "$NO_GIT_BIN/git"
(cd "$STATUS_FIX" && PATH="$NO_GIT_BIN:$PATH" "$AGENTIC_FLOW_CLI" status) > "$TMP/status-no-git.out" \
  || fail "offline status failed when git was absent from PATH"

printf '%s\n' '1.2.4+beef123' > "$STATUS_FIX/.agentic-flow-candidate-version"
printf '%s\n' pending > "$STATUS_FIX/CLAUDE.md.agentic-new"
(cd "$STATUS_FIX" && "$AGENTIC_FLOW_CLI" status) > "$TMP/status-pending.out" \
  && fail "status accepted a project with pending merge candidates"
grep -q "candidate: 1.2.4+beef123" "$TMP/status-pending.out" \
  || fail "status did not report the pending candidate version"
grep -q "CLAUDE.md.agentic-new" "$TMP/status-pending.out" \
  || fail "status did not name the unresolved merge candidate"
rm -f "$STATUS_FIX/.agentic-flow-candidate-version" "$STATUS_FIX/CLAUDE.md.agentic-new"

(
  cd "$STATUS_FIX"
  git init -q .
  git config user.email selftest@example.invalid
  git config user.name selftest
  printf '%s\n' '.claude/' > .gitignore
)
(cd "$STATUS_FIX" && "$AGENTIC_FLOW_CLI" status) > "$TMP/status-ignored.out" \
  && fail "status accepted a git-ignored payload path"
grep -q ".claude/settings.json" "$TMP/status-ignored.out" \
  || fail "status did not report the git-ignored payload path"
(cd "$STATUS_FIX" && AGENTIC_SELFTEST=1 scripts/doctor.sh --scope repo) > "$TMP/doctor-ignored.out" \
  || fail "doctor report failed on a fixture with ignored payload paths"
grep -q "payload paths are git-ignored" "$TMP/doctor-ignored.out" \
  || fail "doctor did not report git-ignored payload paths"

DIFF_SOURCE="$TMP/diff-source"
mkdir -p "$DIFF_SOURCE/config" "$DIFF_SOURCE/scripts/lib" "$DIFF_SOURCE/templates/harness"
printf '%s\n' '9.9.9' > "$DIFF_SOURCE/VERSION"
printf 'templates/harness/CLAUDE.md\tCLAUDE.md\tcore\tpreserve\texport\nscripts/lib\tscripts/lib\tcore\tpreserve\texport\nconfig/payload.tsv\tconfig/payload.tsv\tcore\tpreserve\texport\n' \
  > "$DIFF_SOURCE/config/payload.tsv"
printf '%s\n' '# source heading' > "$DIFF_SOURCE/templates/harness/CLAUDE.md"
cp "$ROOT/scripts/lib/payload-apply.sh" "$DIFF_SOURCE/scripts/lib/payload-apply.sh"
(
  cd "$DIFF_SOURCE"
  git init -q .
  git config user.email selftest@example.invalid
  git config user.name selftest
  git config commit.gpgsign false
  git add VERSION config/payload.tsv scripts/lib/payload-apply.sh templates/harness/CLAUDE.md
  git commit -q -m "Seed source"
  git branch -M main
)
DIFF_SOURCE_URL="file://$DIFF_SOURCE"

DIFF_TARGET="$TMP/diff-target"
mkdir -p "$DIFF_TARGET/config" "$DIFF_TARGET/scripts/lib"
printf '%s\n' 'old+0000000' > "$DIFF_TARGET/.agentic-flow-version"
cp "$DIFF_SOURCE/config/payload.tsv" "$DIFF_TARGET/config/payload.tsv"
cp "$DIFF_SOURCE/scripts/lib/payload-apply.sh" "$DIFF_TARGET/scripts/lib/payload-apply.sh"
(cd "$DIFF_TARGET" && "$AGENTIC_FLOW_CLI" diff) > "$TMP/diff-no-source.out" 2>"$TMP/diff-no-source.err" \
  && fail "diff accepted a project with no recorded source"
grep -q "back-fill" "$TMP/diff-no-source.err" \
  || fail "diff without .agentic-flow-source did not mention back-fill"

printf 'origin %s\nref missing-ref\n' "$DIFF_SOURCE_URL" > "$DIFF_TARGET/.agentic-flow-source"
before_digest=$(tree_digest "$DIFF_TARGET")
(cd "$DIFF_TARGET" && "$AGENTIC_FLOW_CLI" diff) > "$TMP/diff-missing-ref.out" 2>"$TMP/diff-missing-ref.err" \
  && fail "diff accepted a missing source ref"
after_digest=$(tree_digest "$DIFF_TARGET")
[ "$before_digest" = "$after_digest" ] \
  || fail "failed diff changed the project tree"
grep -q "failed to fetch agentic-flow source" "$TMP/diff-missing-ref.err" \
  || fail "diff fetch failure did not name the failed operation"

printf 'origin %s\nref main\n' "$DIFF_SOURCE_URL" > "$DIFF_TARGET/.agentic-flow-source"
printf '%s\n' '# source heading' > "$DIFF_TARGET/CLAUDE.md"
same_digest=$(tree_digest "$DIFF_TARGET")
(cd "$DIFF_TARGET" && "$AGENTIC_FLOW_CLI" diff) > "$TMP/diff-current.out" \
  || fail "diff returned non-zero for an already-current target"
post_same_digest=$(tree_digest "$DIFF_TARGET")
[ "$same_digest" = "$post_same_digest" ] \
  || fail "same-version diff changed the project tree"
grep -q "Already current" "$TMP/diff-current.out" \
  || fail "diff did not report an already-current target"

printf '%s\n' '# changed source heading' > "$DIFF_SOURCE/templates/harness/CLAUDE.md"
(
  cd "$DIFF_SOURCE"
  git add templates/harness/CLAUDE.md
  git commit -q -m "Change payload"
)
changed_digest=$(tree_digest "$DIFF_TARGET")
(cd "$DIFF_TARGET" && "$AGENTIC_FLOW_CLI" diff) > "$TMP/diff-changed.out" \
  && fail "diff returned zero when source changes were available"
post_changed_digest=$(tree_digest "$DIFF_TARGET")
[ "$changed_digest" = "$post_changed_digest" ] \
  || fail "changed diff wrote into the project tree"
grep -q "would-merge CLAUDE.md" "$TMP/diff-changed.out" \
  || fail "diff did not classify the changed payload file"

printf '%s\n' '# ref override source heading' > "$DIFF_SOURCE/templates/harness/CLAUDE.md"
(
  cd "$DIFF_SOURCE"
  git add templates/harness/CLAUDE.md
  git commit -q -m "Ref override payload"
  git tag v-selftest
)
override_digest=$(tree_digest "$DIFF_TARGET")
(cd "$DIFF_TARGET" && "$AGENTIC_FLOW_CLI" diff --ref v-selftest) > "$TMP/diff-ref.out" \
  && fail "diff --ref returned zero when override changes were available"
post_override_digest=$(tree_digest "$DIFF_TARGET")
[ "$override_digest" = "$post_override_digest" ] \
  || fail "diff --ref changed the project tree"
grep -qx "ref main" "$DIFF_TARGET/.agentic-flow-source" \
  || fail "diff --ref rewrote the recorded source ref"

TIMEOUT_TARGET="$TMP/timeout-target"
mkdir -p "$TIMEOUT_TARGET/config" "$TIMEOUT_TARGET/scripts/lib"
printf '%s\n' 'old+timeout' > "$TIMEOUT_TARGET/.agentic-flow-version"
printf 'origin https://example.invalid/slow.git\nref main\n' > "$TIMEOUT_TARGET/.agentic-flow-source"
printf 'scripts/lib\tscripts/lib\tcore\tpreserve\texport\n' > "$TIMEOUT_TARGET/config/payload.tsv"
cp "$ROOT/scripts/lib/payload-apply.sh" "$TIMEOUT_TARGET/scripts/lib/payload-apply.sh"
TIMEOUT_BIN="$TMP/timeout-bin"
TIMEOUT_SENTINEL="$TMP/timeout-child-survived"
mkdir -p "$TIMEOUT_BIN"
cat > "$TIMEOUT_BIN/git" <<'FAKE_TIMEOUT_GIT'
#!/usr/bin/env bash
case " $* " in
  *" clone "*)
    (sleep 2; printf '%s\n' survived > "__TIMEOUT_SENTINEL__") &
    sleep 30
    ;;
  *)
    exit 1
    ;;
esac
FAKE_TIMEOUT_GIT
sed "s|__TIMEOUT_SENTINEL__|$TIMEOUT_SENTINEL|g" "$TIMEOUT_BIN/git" > "$TIMEOUT_BIN/git.tmp"
mv "$TIMEOUT_BIN/git.tmp" "$TIMEOUT_BIN/git"
chmod +x "$TIMEOUT_BIN/git"
(cd "$TIMEOUT_TARGET" && PATH="$TIMEOUT_BIN:$PATH" AGENTIC_FLOW_FETCH_TIMEOUT=1 "$AGENTIC_FLOW_CLI" diff) \
  > "$TMP/diff-timeout.out" 2>"$TMP/diff-timeout.err" \
  && fail "diff accepted a timed-out fetch"
if command -v perl >/dev/null 2>&1; then
  sleep 3
  assert_no_file "$TIMEOUT_SENTINEL"
else
  # Without Perl's POSIX setsid helper, run_with_timeout deliberately falls back to killing
  # only the immediate child. Keep the basic timeout assertion above, but do not pretend the
  # fallback can enforce descendant cleanup that it cannot actually perform.
  rm -f "$TIMEOUT_SENTINEL"
fi

UPGRADE_SOURCE="$TMP/upgrade-source"
mkdir -p "$UPGRADE_SOURCE/config" "$UPGRADE_SOURCE/scripts/lib" "$UPGRADE_SOURCE/scripts" \
  "$UPGRADE_SOURCE/templates/harness"
printf '%s\n' '10.0.0' > "$UPGRADE_SOURCE/VERSION"
printf 'templates/harness/CLAUDE.md\tCLAUDE.md\tcore\tpreserve\texport\nscripts/lib\tscripts/lib\tcore\tpreserve\texport\nscripts/docs-index.sh\tscripts/docs-index.sh\tcore\tpreserve\texport\nconfig/payload.tsv\tconfig/payload.tsv\tcore\tpreserve\texport\n' \
  > "$UPGRADE_SOURCE/config/payload.tsv"
printf '%s\n' '# upgraded harness' > "$UPGRADE_SOURCE/templates/harness/CLAUDE.md"
cp "$ROOT/scripts/lib/payload-apply.sh" "$UPGRADE_SOURCE/scripts/lib/payload-apply.sh"
cat > "$UPGRADE_SOURCE/scripts/docs-index.sh" <<'DOCS_INDEX_SENTINEL'
#!/usr/bin/env bash
printf '%s\n' fetched-code-ran > docs-index-sentinel
DOCS_INDEX_SENTINEL
chmod +x "$UPGRADE_SOURCE/scripts/docs-index.sh"
(
  cd "$UPGRADE_SOURCE"
  git init -q .
  git config user.email selftest@example.invalid
  git config user.name selftest
  git config commit.gpgsign false
  git add VERSION config/payload.tsv scripts/lib/payload-apply.sh scripts/docs-index.sh templates/harness/CLAUDE.md
  git commit -q -m "Seed upgrade source"
  git branch -M main
)
UPGRADE_SOURCE_URL="file://$UPGRADE_SOURCE"

UPGRADE_TARGET="$TMP/upgrade-target"
mkdir -p "$UPGRADE_TARGET/config" "$UPGRADE_TARGET/scripts/lib"
printf '%s\n' 'old+1111111' > "$UPGRADE_TARGET/.agentic-flow-version"
printf 'origin %s\nref main\n' "$UPGRADE_SOURCE_URL" > "$UPGRADE_TARGET/.agentic-flow-source"
cp "$UPGRADE_SOURCE/config/payload.tsv" "$UPGRADE_TARGET/config/payload.tsv"
cp "$UPGRADE_SOURCE/scripts/lib/payload-apply.sh" "$UPGRADE_TARGET/scripts/lib/payload-apply.sh"
(cd "$UPGRADE_TARGET" && "$AGENTIC_FLOW_CLI" upgrade) > "$TMP/upgrade-no-yes.out" 2>"$TMP/upgrade-no-yes.err" \
  && fail "upgrade wrote without --yes in a non-interactive run"
grep -q "pass --yes" "$TMP/upgrade-no-yes.err" \
  || fail "upgrade without --yes did not explain confirmation"

printf '%s\n' '# local project edits' > "$UPGRADE_TARGET/CLAUDE.md"
printf '%s\n' '# occupied candidate' > "$UPGRADE_TARGET/CLAUDE.md.agentic-new"
(cd "$UPGRADE_TARGET" && "$AGENTIC_FLOW_CLI" upgrade --yes) > "$TMP/upgrade-pending.out" \
  || fail "upgrade with merge candidates failed"
grep -qx 'old+1111111' "$UPGRADE_TARGET/.agentic-flow-version" \
  || fail "upgrade advanced installed version while candidates remained"
assert_file "$UPGRADE_TARGET/.agentic-flow-candidate-version"
grep -q "pending     .agentic-flow-candidate-version" "$TMP/upgrade-pending.out" \
  || fail "upgrade did not report pending candidate version"
assert_no_file "$UPGRADE_TARGET/docs-index-sentinel"
grep -q "Docs index was not run automatically" "$TMP/upgrade-pending.out" \
  || fail "upgrade did not explain that docs-index was not executed"
grep -qx '# occupied candidate' "$UPGRADE_TARGET/CLAUDE.md.agentic-new" \
  || fail "upgrade clobbered an occupied merge candidate"
suffixed_candidates=$(find "$UPGRADE_TARGET" -type f -name 'CLAUDE.md.agentic-new.*' | wc -l | tr -d ' ')
[ "$suffixed_candidates" -eq 1 ] \
  || fail "upgrade did not create exactly one suffixed candidate for occupied content"
candidate_count_before=$(find "$UPGRADE_TARGET" -type f -name 'CLAUDE.md.agentic-new*' | wc -l | tr -d ' ')
(cd "$UPGRADE_TARGET" && "$AGENTIC_FLOW_CLI" upgrade --yes) > "$TMP/upgrade-rerun.out" \
  || fail "rerunning upgrade with pending candidates failed"
candidate_count_after=$(find "$UPGRADE_TARGET" -type f -name 'CLAUDE.md.agentic-new*' | wc -l | tr -d ' ')
[ "$candidate_count_before" = "$candidate_count_after" ] \
  || fail "rerunning upgrade duplicated existing merge candidates"

CHANGED_ORIGIN_TARGET="$TMP/upgrade-origin-target"
mkdir -p "$CHANGED_ORIGIN_TARGET/config" "$CHANGED_ORIGIN_TARGET/scripts/lib"
printf '%s\n' 'old+2222222' > "$CHANGED_ORIGIN_TARGET/.agentic-flow-version"
printf 'origin file:///old-standard\nref main\n' > "$CHANGED_ORIGIN_TARGET/.agentic-flow-source-applied"
printf 'origin %s\nref main\n' "$UPGRADE_SOURCE_URL" > "$CHANGED_ORIGIN_TARGET/.agentic-flow-source"
cp "$UPGRADE_SOURCE/config/payload.tsv" "$CHANGED_ORIGIN_TARGET/config/payload.tsv"
cp "$UPGRADE_SOURCE/scripts/lib/payload-apply.sh" "$CHANGED_ORIGIN_TARGET/scripts/lib/payload-apply.sh"
(cd "$CHANGED_ORIGIN_TARGET" && "$AGENTIC_FLOW_CLI" upgrade --yes) > "$TMP/upgrade-origin.out" 2>"$TMP/upgrade-origin.err" \
  && fail "upgrade accepted a changed origin without --force"
grep -q "origin changed" "$TMP/upgrade-origin.err" \
  || fail "changed-origin refusal did not explain the hard stop"

UPGRADE_CLEAN="$TMP/upgrade-clean"
mkdir -p "$UPGRADE_CLEAN/config" "$UPGRADE_CLEAN/scripts/lib"
printf '%s\n' 'old+3333333' > "$UPGRADE_CLEAN/.agentic-flow-version"
printf 'origin %s\nref main\n' "$UPGRADE_SOURCE_URL" > "$UPGRADE_CLEAN/.agentic-flow-source"
cp "$UPGRADE_SOURCE/config/payload.tsv" "$UPGRADE_CLEAN/config/payload.tsv"
cp "$UPGRADE_SOURCE/scripts/lib/payload-apply.sh" "$UPGRADE_CLEAN/scripts/lib/payload-apply.sh"
(cd "$UPGRADE_CLEAN" && "$AGENTIC_FLOW_CLI" upgrade --yes) > "$TMP/upgrade-clean.out" \
  || fail "clean upgrade failed"
expected_upgrade_version=$(cd "$UPGRADE_SOURCE" && printf '10.0.0+%s\n' "$(git rev-parse --short HEAD)")
grep -qx "$expected_upgrade_version" "$UPGRADE_CLEAN/.agentic-flow-version" \
  || fail "clean upgrade did not advance the installed version"
assert_no_file "$UPGRADE_CLEAN/.agentic-flow-candidate-version"
assert_file "$UPGRADE_CLEAN/.agentic-flow-source-applied"
assert_no_file "$UPGRADE_CLEAN/docs-index-sentinel"
fi

# --- hook invariants (run everywhere) ----------------------------------------------------
if should_run hooks; then
NOJQ_PATH=$(path_without_tools "$TMP/nojq-bin" jq)
PATH="$NOJQ_PATH" command -v jq >/dev/null 2>&1 && fail "jq-less PATH still contains jq"
PATH="$NOJQ_PATH" command -v git >/dev/null 2>&1 \
  || fail "jq-less PATH accidentally removed ordinary git"

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
must_allow "$ADD_GUARD" 'rg "git add -A" scripts/self-test.sh'
# Verdicts must not change when jq is absent (previously: silent exit 0, guard disabled).
must_block_nojq "$ADD_GUARD" 'git add -A'
must_block_nojq "$ADD_GUARD" 'git -C /some/path add --all'
must_allow_nojq "$ADD_GUARD" 'git add README.md'

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

  (cd "$GATEFIX" && printf '{"stop_hook_active":false}' | "$GATE") \
    >"$TMP/gate-unknown.out" 2>"$TMP/gate-unknown.err" \
    && fail "Stop gate allowed an unknown failing check"
  grep -q -- "--- make check output" "$TMP/gate-unknown.err" \
    || fail "Stop gate unknown failure did not include diagnostic tail"

  gate_makefile 'echo "docs index OUT OF DATE - run: scripts/docs-index.sh" >&2; exit 1'
  (cd "$GATEFIX" && printf '{"stop_hook_active":false}' | "$GATE") \
    >"$TMP/gate-docs.out" 2>"$TMP/gate-docs.err" \
    && fail "Stop gate allowed a stale docs index"
  grep -q "Run: scripts/docs-index.sh" "$TMP/gate-docs.err" \
    || fail "Stop gate stale-docs failure did not print the one-line remedy"
  grep -q -- "--- make check output" "$TMP/gate-docs.err" \
    && fail "Stop gate stale-docs failure printed the full diagnostic tail"

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

  # Tree-state cache: the clean-tree exit keys on cleanliness, not on who is stopping, so a
  # fan-out of subagents against one dirty worktree paid a full `make check` each, plus once
  # more for the parent turn. Re-running is skipped only while the tree is byte-identical to
  # the state that last passed. The counter lives outside the fixture: a log written inside
  # it would itself change the tree and defeat what is being measured.
  GATE_RUNS="$TMP/gate-run-counter"
  : > "$GATE_RUNS"
  printf 'check:\n\t@echo run >> %s\n' "$GATE_RUNS" > "$GATEFIX/Makefile"
  gate_runs() { wc -l < "$GATE_RUNS" | tr -d ' '; }

  gate_run false || fail "Stop gate blocked while the check was green (cache cold)"
  [ "$(gate_runs)" = 1 ] || fail "cold Stop gate did not run make check exactly once"
  gate_run false || fail "Stop gate blocked on an unchanged tree"
  [ "$(gate_runs)" = 1 ] || fail "Stop gate re-ran make check with nothing changed"

  # A new untracked file is a real change and must invalidate the cache.
  printf 'x\n' > "$GATEFIX/cache-probe.txt"
  gate_run false || fail "Stop gate blocked after adding an untracked file"
  [ "$(gate_runs)" = 2 ] || fail "Stop gate reused a stale verdict after a new file appeared"

  # The trap this cache must not fall into: editing a tracked file leaves
  # `git status --porcelain` byte-identical ("M <path>"), so a porcelain-only state id would
  # skip a gate that has to run. The id hashes content, not just status.
  (cd "$GATEFIX" && git add cache-probe.txt && git commit -q --no-gpg-sign -m probe) >/dev/null 2>&1 \
    || fail "gate cache fixture commit failed"
  printf 'first\n' > "$GATEFIX/cache-probe.txt"
  gate_run false || fail "Stop gate blocked after modifying a tracked file"
  [ "$(gate_runs)" = 3 ] || fail "Stop gate did not re-run after a tracked file changed"
  printf 'second\n' > "$GATEFIX/cache-probe.txt"
  gate_run false || fail "Stop gate blocked after a second modification"
  [ "$(gate_runs)" = 4 ] \
    || fail "Stop gate reused a verdict across different content with identical git status"

  # The escape hatch must always force a real run.
  AGENTIC_CHECK_GATE_NO_CACHE=1 gate_run false \
    || fail "Stop gate blocked with the cache disabled"
  [ "$(gate_runs)" = 5 ] || fail "AGENTIC_CHECK_GATE_NO_CACHE did not force a make check run"

  # A cached green must never mask a genuinely red check on a changed tree.
  printf 'check:\n\t@exit 1\n' > "$GATEFIX/Makefile"
  gate_run false && fail "Stop gate allowed a red check after a cached green"
  rm -f "$GATEFIX/cache-probe.txt"

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
  # Same call with jq absent. jq was only ever used to read the command out of the payload —
  # every scan below runs on git's own staged diff — so exiting 0 without it disabled the
  # whole scanner for no structural reason.
  secret_hook_nojq() { # <command> -> exit status
    (cd "$SECFIX" && printf '{"tool_input":{"command":"%s"}}' "$1" \
      | PATH="$NOJQ_PATH" "$SECRET_GUARD") >/dev/null 2>&1
  }
  stage() { # <content>
    (cd "$SECFIX" && git reset -q && printf '%s\n' "$1" > staged.txt && git add staged.txt)
  }

  stage "aws_key = \"$(printf 'AKIA%s' 'IOSFODNN7EXAMPLE')\""
  secret_hook 'git-claude commit -m x' && fail "secret scanner allowed a staged AWS-format key"
  secret_hook_nogl 'git-claude commit -m x' \
    && fail "secret scanner allowed an AWS-format key with gitleaks unavailable"
  secret_hook_nojq 'git-claude commit -m x' \
    && fail "secret scanner allowed an AWS-format key with jq unavailable"
  secret_hook 'git status' || fail "secret scanner blocked a non-commit command"
  secret_hook_nojq 'git status' \
    || fail "secret scanner blocked a non-commit command with jq unavailable"

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
# Verdicts must not change when jq is absent (previously: silent exit 0, guard disabled).
must_block_nojq "$PUSH_GUARD" 'git push'
must_block_nojq "$PUSH_GUARD" 'git-claude push origin HEAD'
must_block_nojq "$PUSH_GUARD" 'gh pr merge 12'
must_allow_nojq "$PUSH_GUARD" 'git pull --rebase'
fi

# --- plan-to-issues spec validation ------------------------------------------------------
if should_run plan-to-issues; then
INVALID_SPEC="$TMP/invalid-spec.json"
printf '%s\n' '{"tracking":{"title":"Plan: bad"},"steps":[]}' > "$INVALID_SPEC"
"$ROOT/scripts/plan-to-issues.sh" "$INVALID_SPEC" >/dev/null 2>"$TMP/plan.err" && fail "invalid plan spec was accepted"
grep -q "spec must contain" "$TMP/plan.err" || fail "invalid plan spec did not fail validation first"
"$ROOT/scripts/plan-to-issues.sh" --approved-by >/dev/null 2>"$TMP/approved-by.err" \
  && fail "plan-to-issues accepted --approved-by with no value"
grep -q -- "--approved-by requires a name" "$TMP/approved-by.err" \
  || fail "missing --approved-by value did not explain the error"

# --- plan-to-issues reconciliation -------------------------------------------------------
# Replay GitHub locally so failure/resume and repeated apply are deterministic, offline,
# and safe to run in any repository.
PLAN_DRIVER="$ROOT/scripts/plan-to-issues.sh"
GHFIX="$TMP/gh-fixture"
GHSTATE="$TMP/gh-state"
mkdir -p "$GHFIX" "$GHSTATE"
cat > "$GHFIX/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
state=${FAKE_GH_STATE:?}
mkdir -p "$state"
[ -f "$state/next" ] || printf '%s\n' 1 > "$state/next"

case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "repo view")
    case "$*" in
      *nameWithOwner*) printf '%s\n' owner/repo ;;
      *hasIssuesEnabled*) printf '%s\n' true ;;
    esac
    exit 0
    ;;
  "run view")
    printf '%s\n' "${FAKE_GH_RUN_CONCLUSION:-success}"
    exit 0
    ;;
  "label create") exit 0 ;;
  "issue list")
    out="$state/issues.jsonl"
    : > "$out"
    for dir in "$state"/issue-*; do
      [ -d "$dir" ] || continue
      num=${dir##*-}
      jq -n --argjson number "$num" \
        --arg title "$(cat "$dir/title")" \
        --arg body "$(cat "$dir/body")" \
        --arg issue_state "$(cat "$dir/state")" \
        --arg url "https://github.test/owner/repo/issues/$num" \
        '{number:$number,title:$title,body:$body,state:$issue_state,url:$url}' >> "$out"
    done
    jq -s . "$out"
    exit 0
    ;;
  "issue create")
    shift 2
    title=""; body=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --title) title="$2"; shift 2 ;;
        --body) body="$2"; shift 2 ;;
        --repo|--label) shift 2 ;;
        *) shift ;;
      esac
    done
    num=$(cat "$state/next")
    printf '%s\n' $((num + 1)) > "$state/next"
    if [ "${FAKE_GH_FAIL_CREATE_NUMBER:-}" = "$num" ]; then
      echo "injected create failure" >&2
      exit 1
    fi
    dir="$state/issue-$num"
    mkdir -p "$dir"
    printf '%s\n' "$title" > "$dir/title"
    printf '%s\n' "$body" > "$dir/body"
    printf '%s\n' OPEN > "$dir/state"
    printf 'https://github.test/owner/repo/issues/%s\n' "$num"
    exit 0
    ;;
  "issue edit")
    num=$3
    shift 3
    dir="$state/issue-$num"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --title) printf '%s\n' "$2" > "$dir/title"; shift 2 ;;
        --body) printf '%s\n' "$2" > "$dir/body"; shift 2 ;;
        --repo|--add-label) shift 2 ;;
        *) shift ;;
      esac
    done
    exit 0
    ;;
  "issue close")
    num=$3
    printf '%s\n' CLOSED > "$state/issue-$num/state"
    exit 0
    ;;
esac

if [ "${1:-}" = api ]; then
  case "$*" in
    *"--method POST"*) exit 0 ;;
    *)
      endpoint=${2:-}
      num=${endpoint##*/}
      printf '%s\n' $((num + 1000))
      exit 0
      ;;
  esac
fi

echo "unsupported fake gh call: $*" >&2
exit 2
FAKE_GH
chmod +x "$GHFIX/gh"

PLAN_SPEC="$TMP/plan-spec.json"
cat > "$PLAN_SPEC" <<'JSON'
{
  "id": "self-test-plan",
  "tracking": {"title": "Plan: self test", "body": "tracker"},
  "steps": [
    {"id": "alpha", "title": "Alpha", "body": "alpha v1"},
    {"id": "beta", "title": "Beta", "body": "beta v1", "labels": ["needs-execution"]}
  ]
}
JSON

plan_apply() {
  PATH="$GHFIX:$PATH" FAKE_GH_STATE="$GHSTATE" "$PLAN_DRIVER" --apply "$1" >/dev/null
}

plan_apply "$PLAN_SPEC" || fail "first plan apply failed against fake GitHub"
issue_count=$(find "$GHSTATE" -type d -name 'issue-*' | wc -l | tr -d ' ')
[ "$issue_count" -eq 3 ] || fail "first plan apply did not create one tracker and two steps"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$GHSTATE" \
  "$PLAN_DRIVER" --diff "$PLAN_SPEC" > "$TMP/plan-diff.out" \
  || fail "plan diff failed against fake GitHub"
grep -q "Tracker: current" "$TMP/plan-diff.out" \
  || fail "plan diff did not recognize the applied revision"
plan_apply "$PLAN_SPEC" || fail "repeated identical plan apply failed"
issue_count=$(find "$GHSTATE" -type d -name 'issue-*' | wc -l | tr -d ' ')
[ "$issue_count" -eq 3 ] || fail "repeated plan apply duplicated issues"

APPROVAL_DOC_ROOT="$TMP/approval-doc-root"
mkdir -p "$APPROVAL_DOC_ROOT/docs/inprogress"
APPROVAL_DOC="$APPROVAL_DOC_ROOT/docs/inprogress/feature-approval.md"
cat > "$APPROVAL_DOC" <<'MD'
## Tracker
- [x] F-1 done
## Status / Implementation status
- **Tracking issue:** pending.
- **Approval:** pending.
- **Verification evidence:** https://example.invalid/actions/1
- **Review verdict:** approved.
MD
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$GHSTATE" \
  "$PLAN_DRIVER" --apply --approved-by "Test User" --doc "$APPROVAL_DOC" "$PLAN_SPEC" >/dev/null \
  || fail "plan apply with --approved-by failed against fake GitHub"
tracker_body=$(grep -Rl "agentic-flow:plan:self-test-plan tracker" "$GHSTATE"/issue-*/body | xargs cat)
printf '%s\n' "$tracker_body" | grep -q 'approved-by:Test User approved-at:' \
  || fail "approval stamp did not land in the existing tracker marker"
approved_at=$(printf '%s\n' "$tracker_body" | sed -n 's/.*approved-at:\([^ ]*\) -->.*/\1/p' | head -1)
[ -n "$approved_at" ] || fail "approval stamp did not include approved-at"
grep -qF -- "- **Approval:** Test User approved on ${approved_at%%T*} via plan-to-issues --apply." "$APPROVAL_DOC" \
  || fail "--doc did not write the canonical Approval status line"
AGENTIC_PROJECT_ROOT="$APPROVAL_DOC_ROOT" "$ROOT/scripts/lifecycle-status.sh" --check >/dev/null \
  || fail "lifecycle-status did not recognize the machine-written Approval line"
plan_apply "$PLAN_SPEC" || fail "plan apply without --approved-by failed after approval"
tracker_body_after=$(grep -Rl "agentic-flow:plan:self-test-plan tracker" "$GHSTATE"/issue-*/body | xargs cat)
printf '%s\n' "$tracker_body_after" | grep -q "approved-at:$approved_at" \
  || fail "repeated apply changed the original approval timestamp"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$GHSTATE" \
  "$PLAN_DRIVER" --apply --approved-by "Other User" "$PLAN_SPEC" >/dev/null 2>"$TMP/approval-conflict.err" \
  && fail "plan apply silently rewrote an existing approval"
grep -q "already approved by 'Test User'" "$TMP/approval-conflict.err" \
  || fail "approval conflict did not explain the preserved approver"

UPDATED_SPEC="$TMP/plan-spec-updated.json"
jq '.steps[0].body = "alpha v2"' "$PLAN_SPEC" > "$UPDATED_SPEC"
plan_apply "$UPDATED_SPEC" || fail "changed plan did not reconcile"
grep -Rl "alpha v2" "$GHSTATE"/issue-*/body >/dev/null \
  || fail "changed step body was not updated in place"
tracker_body_updated=$(grep -Rl "agentic-flow:plan:self-test-plan tracker" "$GHSTATE"/issue-*/body | xargs cat)
printf '%s\n' "$tracker_body_updated" | grep -q "approved-at:$approved_at" \
  || fail "changed plan reconciliation dropped the original approval"

REMOVED_SPEC="$TMP/plan-spec-removed.json"
jq '.steps = [.steps[0]]' "$UPDATED_SPEC" > "$REMOVED_SPEC"
plan_apply "$REMOVED_SPEC" || fail "plan with a removed step did not reconcile"
beta_state=$(grep -Rl "step:beta" "$GHSTATE"/issue-*/body | sed 's|/body$|/state|' | xargs cat)
[ "$beta_state" = CLOSED ] || fail "removed plan step was not closed with history retained"

PARTIAL_STATE="$TMP/gh-partial-state"
PARTIAL_SPEC="$TMP/partial-spec.json"
jq '.id = "partial-plan"' "$PLAN_SPEC" > "$PARTIAL_SPEC"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$PARTIAL_STATE" FAKE_GH_FAIL_CREATE_NUMBER=2 \
  "$PLAN_DRIVER" --apply "$PARTIAL_SPEC" >/dev/null 2>&1 \
  && fail "injected partial GitHub failure unexpectedly succeeded"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$PARTIAL_STATE" \
  "$PLAN_DRIVER" --apply "$PARTIAL_SPEC" >/dev/null \
  || fail "plan apply did not resume after a partial failure"
partial_count=$(find "$PARTIAL_STATE" -type d -name 'issue-*' | wc -l | tr -d ' ')
[ "$partial_count" -eq 3 ] || fail "partial resume duplicated or omitted plan issues"
fi

# --- lifecycle qualification -------------------------------------------------------------
if should_run lifecycle; then
LIFEFIX="$TMP/lifecycle-fixture"
mkdir -p "$LIFEFIX/docs/inprogress"
cat > "$LIFEFIX/docs/inprogress/feature-active.md" <<'MD'
## Tracker
- [x] F-1 done
- [ ] F-2 open
MD
cat > "$LIFEFIX/docs/inprogress/feature-blocked.md" <<'MD'
## Tracker
- [x] F-1 done
## Status
- **Approval:** user approved 2026-01-01.
- **Tracking issue:** https://example.invalid/issues/1
- **Verification evidence:** pending.
- **Review verdict:** pending.
MD
AGENTIC_PROJECT_ROOT="$LIFEFIX" "$ROOT/scripts/lifecycle-status.sh" \
  > "$TMP/lifecycle.out"
grep -q "ACTIVE.*feature-active.md" "$TMP/lifecycle.out" \
  || fail "lifecycle report did not retain an open tracker as active"
grep -q "BLOCKED.*feature-blocked.md.*verification-evidence.*review-verdict" \
  "$TMP/lifecycle.out" \
  || fail "lifecycle report did not name missing closure evidence"
AGENTIC_PROJECT_ROOT="$LIFEFIX" "$ROOT/scripts/lifecycle-status.sh" --check >/dev/null 2>&1 \
  && fail "strict lifecycle check accepted an all-checked tracker without evidence"

sed \
  -e 's|^- \*\*Verification evidence:\*\* pending\.$|- **Verification evidence:** https://example.invalid/actions/1|' \
  -e 's|^- \*\*Review verdict:\*\* pending\.$|- **Review verdict:** approved — https://example.invalid/reviews/1|' \
  "$LIFEFIX/docs/inprogress/feature-blocked.md" > "$TMP/lifecycle-ready.md"
mv "$TMP/lifecycle-ready.md" "$LIFEFIX/docs/inprogress/feature-blocked.md"
AGENTIC_PROJECT_ROOT="$LIFEFIX" "$ROOT/scripts/lifecycle-status.sh" --check >/dev/null \
  || fail "strict lifecycle check rejected a tracker with complete closure evidence"

# --- lifecycle: CI run evidence verification (#25) --------------------------------------
write_lifecycle_ready_doc() { # <root> <verification-evidence>
  mkdir -p "$1/docs/inprogress"
  cat > "$1/docs/inprogress/feature-ready.md" <<MD
## Tracker
- [x] F-1 done
## Status
- **Approval:** user approved 2026-01-01.
- **Tracking issue:** https://example.invalid/issues/1
- **Verification evidence:** $2
- **Review verdict:** approved.
MD
}

LIFEGHFIX="$TMP/lifecycle-gh-fixture"
mkdir -p "$LIFEGHFIX"
cat > "$LIFEGHFIX/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "run view")
    printf '%s\n' "${FAKE_GH_RUN_CONCLUSION:-success}"
    exit 0
    ;;
esac
echo "unsupported fake gh call: $*" >&2
exit 2
FAKE_GH
chmod +x "$LIFEGHFIX/gh"

LIFE25_NO_GH="$TMP/lifecycle25-no-gh"
write_lifecycle_ready_doc "$LIFE25_NO_GH" "https://github.com/owner/repo/actions/runs/100"
NO_GH_BIN=$(path_without_tools "$TMP/no-gh-bin" gh)
AGENTIC_PROJECT_ROOT="$LIFE25_NO_GH" PATH="$NO_GH_BIN" \
  "$ROOT/scripts/lifecycle-status.sh" --check --verify-evidence > "$TMP/lifecycle25-no-gh.out" \
  || fail "strict verified lifecycle check treated absent gh as fatal"
grep -q 'UNVERIFIED.*feature-ready\.md.*gh is not available' "$TMP/lifecycle25-no-gh.out" \
  || fail "verified lifecycle check did not report absent gh as UNVERIFIED"

LIFE25_NON_RUN="$TMP/lifecycle25-non-run"
write_lifecycle_ready_doc "$LIFE25_NON_RUN" "https://example.invalid/actions/1"
AGENTIC_PROJECT_ROOT="$LIFE25_NON_RUN" PATH="$LIFEGHFIX:$PATH" \
  "$ROOT/scripts/lifecycle-status.sh" --check --verify-evidence > "$TMP/lifecycle25-non-run.out" \
  || fail "strict verified lifecycle check treated non-run evidence as fatal"
grep -q 'UNVERIFIED.*feature-ready\.md.*not a GitHub Actions run URL' \
  "$TMP/lifecycle25-non-run.out" \
  || fail "verified lifecycle check did not report non-run evidence as UNVERIFIED"

LIFE25_FAILURE="$TMP/lifecycle25-failure"
write_lifecycle_ready_doc "$LIFE25_FAILURE" "https://github.com/owner/repo/actions/runs/200"
AGENTIC_PROJECT_ROOT="$LIFE25_FAILURE" PATH="$LIFEGHFIX:$PATH" \
  FAKE_GH_RUN_CONCLUSION=failure \
  "$ROOT/scripts/lifecycle-status.sh" --check --verify-evidence > "$TMP/lifecycle25-failure.out" 2>&1 \
  && fail "strict verified lifecycle check accepted a resolved failing CI run"
grep -q 'BLOCKED.*feature-ready\.md.*concluded failure' "$TMP/lifecycle25-failure.out" \
  || fail "verified lifecycle check did not block on a resolved failing CI run"

LIFE25_SUCCESS="$TMP/lifecycle25-success"
write_lifecycle_ready_doc "$LIFE25_SUCCESS" "https://github.com/owner/repo/actions/runs/100"
AGENTIC_PROJECT_ROOT="$LIFE25_SUCCESS" PATH="$LIFEGHFIX:$PATH" \
  FAKE_GH_RUN_CONCLUSION=success \
  "$ROOT/scripts/lifecycle-status.sh" --check --verify-evidence > "$TMP/lifecycle25-success.out" \
  || fail "strict verified lifecycle check rejected a resolved successful CI run"
grep -q 'READY.*feature-ready\.md.*concluded success' "$TMP/lifecycle25-success.out" \
  || fail "verified lifecycle check did not mark a resolved successful CI run READY"

# --- lifecycle: absent vs. misnamed vs. wrapped evidence (#19) ---------------------------
# A checker that reports "missing" for both "never recorded" and "recorded under the wrong
# label" trains people to stop trusting it — this bit the project itself: a pre-schema doc
# recorded its approval as "Approved:" and the checker called it missing, indistinguishable
# from a doc with no approval line at all.
cat > "$LIFEFIX/docs/inprogress/lc19-misnamed.md" <<'MD'
## Tracker
- [x] F-1 done
## Status
- **Approved:** user approved 2026-01-01.
- **Tracking issue:** https://example.invalid/issues/1
- **Verification evidence:** https://example.invalid/actions/1
- **Review verdict:** approved.
MD
cat > "$LIFEFIX/docs/inprogress/lc19-absent.md" <<'MD'
## Tracker
- [x] F-1 done
## Status
- **Tracking issue:** https://example.invalid/issues/1
- **Verification evidence:** https://example.invalid/actions/1
- **Review verdict:** approved.
MD
cat > "$LIFEFIX/docs/inprogress/lc19-wrapped.md" <<'MD'
## Tracker
- [x] F-1 done
## Status
- **Approval:** user approved 2026-01-01.
- **Tracking issue:** https://example.invalid/issues/1
- **Verification evidence:** see the CI run recorded at
  https://example.invalid/actions/1
- **Review verdict:** approved.
MD
AGENTIC_PROJECT_ROOT="$LIFEFIX" "$ROOT/scripts/lifecycle-status.sh" > "$TMP/lifecycle19.out"

grep -q 'BLOCKED.*lc19-misnamed\.md.*unrecognized: approval (found "Approved:")' \
  "$TMP/lifecycle19.out" \
  || fail "lifecycle did not flag a misnamed Approval field as unrecognized, not missing"
grep -q 'BLOCKED.*lc19-absent\.md.*missing: approval' "$TMP/lifecycle19.out" \
  || fail "lifecycle did not report a genuinely absent approval field as missing"
if grep -q 'lc19-absent\.md.*unrecognized' "$TMP/lifecycle19.out"; then
  fail "lifecycle invented an unrecognized-field match where no similar label exists"
fi
grep -q 'READY.*lc19-wrapped\.md' "$TMP/lifecycle19.out" \
  || fail "lifecycle did not read a Verification evidence value wrapped onto a continuation line"

# The schema stays single-valued: a misnamed field is reported clearly, but it must never
# silently satisfy the check (that would let the vocabulary fork instead of surfacing it).
AGENTIC_PROJECT_ROOT="$LIFEFIX" "$ROOT/scripts/lifecycle-status.sh" --check >/dev/null 2>&1 \
  && fail "strict lifecycle check accepted a misnamed Approval field as though it were valid"
fi

# --- the run did what the mode promised --------------------------------------------------
# Without this, deleting or mis-guarding a group's `if should_run` block still prints
# "self-test passed." A pass has to mean the groups for this mode actually executed.
if [ -n "$ONLY_GROUP" ]; then
  EXPECTED_GROUPS="$ONLY_GROUP"
elif [ "$SELF_TEST_MODE" = full ]; then
  EXPECTED_GROUPS="$SELF_TEST_GROUPS"
else
  EXPECTED_GROUPS=$(printf '%s\n' "$SELF_TEST_GROUPS" | sed 's/export //')
fi
for group in $EXPECTED_GROUPS; do
  case "$GROUPS_RAN" in
    *" $group "*) ;;
    *) fail "self-test group '$group' never executed in $([ -n "$ONLY_GROUP" ] \
         && echo "--only $ONLY_GROUP" || echo "--$SELF_TEST_MODE") mode" ;;
  esac
done
for group in $GROUPS_RAN; do
  case " $EXPECTED_GROUPS " in
    *" $group "*) ;;
    *) fail "self-test ran unrelated group '$group'" ;;
  esac
done

echo "self-test passed."
