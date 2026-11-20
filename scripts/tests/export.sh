#!/usr/bin/env bash
# Sourced by self-test.sh; shared fixture context is intentional.
# shellcheck disable=SC1091,SC2034,SC2153,SC2164,SC2329 # Dispatcher globals (including ROOT), indirect fixture calls, inherited errexit.
if [ -f "$ROOT/scripts/export.sh" ]; then
  # Snapshot once, then hard-link unchanged files into private directory trees.
  # The files mutated by export cases become private copies below.
  source_snapshot
  snapshot_digest=$(tree_digest "$SOURCE_SNAPSHOT")
  SOURCE_FIXTURE="$TMP/source"
  link_snapshot_files "$SOURCE_FIXTURE"
  for mutable in .claude/skills/create-tags/SKILL.md config/payload.tsv \
    .codex/hooks.json CLAUDE.md templates/harness/CLAUDE.md docs/README.md; do
    rm "$SOURCE_FIXTURE/$mutable"
    cp -p "$SOURCE_SNAPSHOT/$mutable" "$SOURCE_FIXTURE/$mutable"
  done
  # The source fixture omits live lifecycle docs, so regenerate its derived index.
  "$SOURCE_FIXTURE/scripts/docs-index.sh" >/dev/null

  # Let the fixture resolve the real source HEAD for the version-stamp assertion without
  # copying or mutating the repository's git database.
  source_git_dir=$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)
  if [ -n "$source_git_dir" ]; then
    printf 'gitdir: %s\n' "$source_git_dir" > "$SOURCE_FIXTURE/.git"
  fi

  # Export may not copy a stale generated adapter or create a partial target.
  printf '\nstale copy\n' >> "$SOURCE_FIXTURE/.claude/skills/create-tags/SKILL.md"
  cmp -s "$SOURCE_FIXTURE/.claude/skills/create-tags/SKILL.md" \
    "$SOURCE_SNAPSHOT/.claude/skills/create-tags/SKILL.md" \
    && fail 'mutable fixture did not isolate the changed skill'
  DRIFT_TARGET="$TMP/drift-export"
  "$SOURCE_FIXTURE/scripts/export.sh" "$DRIFT_TARGET" >/dev/null 2>&1 \
    && fail "export accepted a stale generated skill"
  assert_no_file "$DRIFT_TARGET"
  rm "$SOURCE_FIXTURE/.claude/skills/create-tags/SKILL.md"
  ln "$SOURCE_SNAPSHOT/.claude/skills/create-tags/SKILL.md" \
    "$SOURCE_FIXTURE/.claude/skills/create-tags/SKILL.md"

  assert_active_ci_workflow "$SOURCE_FIXTURE/.github/workflows/ci.yml"
  if grep -Eq 'agentic-flow-assurance|assurance\.sh' \
      "$SOURCE_FIXTURE/.github/workflows/ci.yml" "$SOURCE_FIXTURE/templates/ci/ci.yml"; then
    fail "CI workflow varies required checks with assurance state"
  fi

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

  awk -F "$(printf '\t')" 'BEGIN { OFS="\t" } $3=="codex" && $5=="export" { $3="unknown-scope" } { print }' \
    "$TMP/payload.tsv.orig" > "$SOURCE_FIXTURE/config/payload.tsv"
  "$SOURCE_FIXTURE/scripts/export.sh" "$TMP/unknown-scope-target" \
    > "$TMP/unknown-scope.out" 2>&1 \
    && fail "export accepted an unknown manifest scope"
  assert_no_file "$TMP/unknown-scope-target"
  cp "$TMP/payload.tsv.orig" "$SOURCE_FIXTURE/config/payload.tsv"

  cp "$SOURCE_FIXTURE/.codex/hooks.json" "$TMP/codex-hooks.orig"
  printf '%s\n' '{"hooks":{}}' > "$SOURCE_FIXTURE/.codex/hooks.json"
  (cd "$SOURCE_FIXTURE" && AGENTIC_SELFTEST=1 scripts/doctor.sh --check) >/dev/null 2>&1 \
    && fail "doctor accepted a structurally unwired Codex hook configuration"
  (cd "$SOURCE_FIXTURE" && AGENTIC_SELFTEST=1 scripts/doctor.sh --check --scope repo) >/dev/null 2>&1 \
    && fail "repo-scope doctor accepted a structurally unwired Codex hook configuration"
  cp "$TMP/codex-hooks.orig" "$SOURCE_FIXTURE/.codex/hooks.json"
  # Removing only SessionStart must fail with that adapter's diagnostic.
  for session_adapter in .claude/settings.json .codex/hooks.json; do
    cp "$SOURCE_FIXTURE/$session_adapter" "$TMP/session-hooks.orig"
    # Replace the directory entry so a hard link cannot expose the mutation.
    jq 'del(.hooks.SessionStart)' "$TMP/session-hooks.orig" > "$TMP/session-unwired.json"
    mv "$TMP/session-unwired.json" "$SOURCE_FIXTURE/$session_adapter"
    (cd "$SOURCE_FIXTURE" && AGENTIC_SELFTEST=1 scripts/doctor.sh --check --scope repo --skip-make-check) \
      > "$TMP/session-unwired.out" 2>&1 \
      && fail "doctor accepted missing SessionStart in $session_adapter"
    grep -Fq "missing $session_adapter SessionStart wired to scripts/hooks/session-context.sh" "$TMP/session-unwired.out" \
      || fail "doctor omitted the SessionStart diagnostic for $session_adapter"
    cat "$TMP/session-hooks.orig" > "$SOURCE_FIXTURE/$session_adapter"
  done
  mkdir -p "$SOURCE_FIXTURE/docs/inprogress"
  for session_doc in doctor-session-one doctor-session-two; do
    cat > "$SOURCE_FIXTURE/docs/inprogress/$session_doc.md" <<'DOCTOR_SESSION'
# Doctor session fixture
# Part B — Implementation Brief
```agentic-flow-plan
branch: doctor-session-fixture
```
DOCTOR_SESSION
  done
  (cd "$SOURCE_FIXTURE" && AGENTIC_SELFTEST=1 scripts/doctor.sh --scope repo --skip-make-check) \
    > "$TMP/session-ambiguous.out" 2>&1 || fail 'doctor failed while reporting ambiguous session ownership'
  grep -Fq 'warning multiple inprogress docs name branch doctor-session-fixture; session context suppressed' "$TMP/session-ambiguous.out" \
    || fail 'doctor omitted ambiguous session branch warning'
  rm "$SOURCE_FIXTURE/docs/inprogress/doctor-session-one.md" "$SOURCE_FIXTURE/docs/inprogress/doctor-session-two.md"

  # Codex has no Claude project-root variable; doctor must reject the Claude-only form (#92).
  # shellcheck disable=SC2016 # literal hook command text being rewritten, not expanded.
  sed 's|\$(git rev-parse --show-toplevel)|\$CLAUDE_PROJECT_DIR|' "$TMP/codex-hooks.orig" \
    > "$SOURCE_FIXTURE/.codex/hooks.json"
  grep -q 'CLAUDE_PROJECT_DIR' "$SOURCE_FIXTURE/.codex/hooks.json" \
    || fail "Codex hook mutation did not apply"
  (cd "$SOURCE_FIXTURE" && AGENTIC_SELFTEST=1 scripts/doctor.sh --check --scope repo) \
    > "$TMP/codex-claude-root.out" 2>&1 \
    && fail "doctor accepted Codex hooks that depend on the Claude project root"
  grep -q 'resolve the root with git rev-parse' "$TMP/codex-claude-root.out" \
    || fail "doctor did not name the non-portable Codex hook root"
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
  assert_no_file "$SCOPED_TARGET/templates/shared"
  assert_no_file "$SCOPED_TARGET/.opencode/agent/code-reviewer.md"
  assert_file "$SCOPED_TARGET/AGENTS.md"
  assert_file "$SCOPED_TARGET/CLAUDE.md"
  assert_file "$SCOPED_TARGET/METHODOLOGY.md"
  assert_file "$SCOPED_TARGET/.claude/settings.json"
  assert_file "$SCOPED_TARGET/.claude/skills/plan-to-issues/SKILL.md"
  assert_file "$SCOPED_TARGET/.agentic-flow-installation"
  grep -qx standard "$SCOPED_TARGET/.agentic-flow-assurance" \
    || fail "new export did not seed Standard assurance"
  (cd "$SCOPED_TARGET" && scripts/assurance.sh set strict) >/dev/null \
    || fail "exported assurance CLI could not raise baseline"
  grep -qx 'scope=claude' "$SCOPED_TARGET/.agentic-flow-installation" \
    || fail "scoped export did not record its active Claude scope"
  grep -q '^scope=codex$' "$SCOPED_TARGET/.agentic-flow-installation" \
    && fail "scoped export recorded excluded Codex scope"
  printf '#!/bin/bash\ninvalid syntax (\n' > "$SCOPED_TARGET/scripts/their-deploy.sh"
  (cd "$SCOPED_TARGET" && scripts/shell-inventory.sh --syntax) >/dev/null 2>&1 \
    || fail "installed shell inventory included adopter-owned script"
  cp "$SCOPED_TARGET/.agentic-flow-installation" "$TMP/scoped-installation.orig"
  "$SOURCE_FIXTURE/scripts/export.sh" --exclude-scope=codex --exclude-scope=opencode \
    "$SCOPED_TARGET" >/dev/null
  "$SOURCE_FIXTURE/scripts/export.sh" --force --exclude-scope=codex --exclude-scope=opencode \
    "$SCOPED_TARGET" >/dev/null
  grep -qx strict "$SCOPED_TARGET/.agentic-flow-assurance" \
    || fail "forced export overwrote adopter assurance baseline"
  cmp -s "$TMP/scoped-installation.orig" "$SCOPED_TARGET/.agentic-flow-installation" \
    || fail "repeated scoped export changed stable installation state"
  scoped_version=$(cat "$SCOPED_TARGET/.agentic-flow-version")
  grep -q 'scripts/their-deploy.sh' "$SCOPED_TARGET/.agentic-flow-installation" \
    && fail "installation membership absorbed an adopter-owned script"

  state_rejects() { # <bad-line> <reason>
    cp "$TMP/scoped-installation.orig" "$SCOPED_TARGET/.agentic-flow-installation"
    printf '%s\n' "$1" >> "$SCOPED_TARGET/.agentic-flow-installation"
    ( # shellcheck disable=SC1091 # fixture library is created at runtime.
      . "$SOURCE_FIXTURE/scripts/lib/payload-apply.sh";
      payload_resolve_installation "$SCOPED_TARGET" "$SOURCE_FIXTURE/config/payload.tsv" ) \
      > "$TMP/state-reject.out" 2>&1 \
      && fail "installation state accepted $2"
    grep -q 'line ' "$TMP/state-reject.out" \
      || fail "invalid $2 did not name its installation-state line"
    grep -qx "$scoped_version" "$SCOPED_TARGET/.agentic-flow-version" \
      || fail "invalid $2 advanced installed version"
  }
  state_digest=$(printf '%064d' 0)
  state_rejects "file=bad  scripts/bad.sh" 'malformed digest'
  before_bad_state=$(tree_digest "$SCOPED_TARGET")
  "$SOURCE_FIXTURE/scripts/export.sh" --exclude-scope=codex --exclude-scope=opencode \
    "$SCOPED_TARGET" > "$TMP/bad-state-export.out" 2>&1 \
    && fail "export copied files despite malformed installation state"
  [ "$before_bad_state" = "$(tree_digest "$SCOPED_TARGET")" ] \
    || fail "malformed installation state allowed export mutation"
  state_rejects "file=1234  scripts/bad.sh" 'short digest'
  state_rejects "file=$state_digest  scripts/../bad.sh" 'parent segment'
  state_rejects "file=$state_digest  /tmp/bad.sh" 'absolute path'
  state_rejects "file=$state_digest  .codex/hooks.json" 'excluded scope'
  state_rejects "$(sed -n '/^file=/{p;q;}' "$TMP/scoped-installation.orig")" 'duplicate path'
  ln -s "$TMP" "$SCOPED_TARGET/scripts/linked"
  state_rejects "file=$state_digest  scripts/linked/bad.sh" 'symlink component'
  rm "$SCOPED_TARGET/scripts/linked"
  cp "$TMP/scoped-installation.orig" "$SCOPED_TARGET/.agentic-flow-installation"
  printf 'file=%s  scripts/bad\000path.sh\n' "$state_digest" \
    >> "$SCOPED_TARGET/.agentic-flow-installation"
  ( # shellcheck disable=SC1091 # fixture library is created at runtime.
    . "$SOURCE_FIXTURE/scripts/lib/payload-apply.sh";
    payload_resolve_installation "$SCOPED_TARGET" "$SOURCE_FIXTURE/config/payload.tsv" ) \
    > "$TMP/state-nul.out" 2>&1 \
    && fail "installation state accepted a NUL path"
  grep -q 'line .*NUL byte' "$TMP/state-nul.out" \
    || fail "NUL path did not name its installation-state line"
  {
    printf 'version=1\nscope=core\n'
    state_n=0
    while [ "$state_n" -lt 2001 ]; do
      printf 'file=%s  scripts/extra-%04d.sh\n' "$state_digest" "$state_n"
      state_n=$((state_n + 1))
    done
  } > "$SCOPED_TARGET/.agentic-flow-installation"
  ( # shellcheck disable=SC1091 # fixture library is created at runtime.
    . "$SOURCE_FIXTURE/scripts/lib/payload-apply.sh";
    payload_resolve_installation "$SCOPED_TARGET" "$SOURCE_FIXTURE/config/payload.tsv" ) \
    > "$TMP/state-bound.out" 2>&1 \
    && fail "installation state accepted more than 2000 files"
  grep -q 'line 2003: more than 2000 files' "$TMP/state-bound.out" \
    || fail "over-bound installation state did not name its offending line"
  cp "$TMP/scoped-installation.orig" "$SCOPED_TARGET/.agentic-flow-installation"
  printf '%s\n' '# locally changed' >> "$SCOPED_TARGET/scripts/doctor.sh"
  (cd "$SCOPED_TARGET" && AGENTIC_SELFTEST=1 scripts/doctor.sh --scope repo --skip-make-check) \
    > "$TMP/scoped-doctor.out" 2>&1 || true
  grep -q 'installed file digest changed: scripts/doctor.sh' "$TMP/scoped-doctor.out" \
    || fail "doctor did not report recorded digest drift"
  grep -q 'their-deploy.sh' "$TMP/scoped-doctor.out" \
    && fail "doctor treated adopter-owned script as harness drift"
  cp "$SCOPED_TARGET/.agentic-flow-scopes-excluded" "$TMP/scoped-legacy.orig"
  : > "$SCOPED_TARGET/.agentic-flow-scopes-excluded"
  "$SOURCE_FIXTURE/scripts/export.sh" --exclude-scope=codex --exclude-scope=opencode \
    "$SCOPED_TARGET" > "$TMP/scope-conflict.out" 2>&1 \
    && fail "export accepted conflicting old and new scope state"
  grep -q 'conflicts' "$TMP/scope-conflict.out" \
    || fail "scope conflict did not identify the old/new state mismatch"
  cmp -s "$TMP/scoped-installation.orig" "$SCOPED_TARGET/.agentic-flow-installation" \
    || fail "scope conflict advanced installation state"
  cp "$TMP/scoped-legacy.orig" "$SCOPED_TARGET/.agentic-flow-scopes-excluded"

  CODEX_ONLY_TARGET="$TMP/codex-only-export"
  "$SOURCE_FIXTURE/scripts/export.sh" --exclude-scope=claude --exclude-scope=opencode \
    "$CODEX_ONLY_TARGET" >/dev/null
  assert_no_file "$CODEX_ONLY_TARGET/CLAUDE.md"
  assert_no_file "$CODEX_ONLY_TARGET/.opencode/agent/code-reviewer.md"
  (cd "$CODEX_ONLY_TARGET" && make check) > "$TMP/codex-only-check.out" 2>&1 \
    || { cat "$TMP/codex-only-check.out" >&2; fail "Codex-only export failed its active checks"; }
  rm "$CODEX_ONLY_TARGET/.codex/hooks.json"
  (cd "$CODEX_ONLY_TARGET" && AGENTIC_SELFTEST=1 scripts/doctor.sh --check --scope repo --skip-make-check) \
    > "$TMP/codex-only-missing.out" 2>&1 \
    && fail "doctor accepted a missing active Codex adapter"
  grep -q 'manifest destination: .codex/hooks.json' "$TMP/codex-only-missing.out" \
    || fail "doctor did not identify the missing active adapter"

  NO_CI_TARGET="$TMP/no-ci-export"
  "$SOURCE_FIXTURE/scripts/export.sh" --exclude-scope=codex --exclude-scope=opencode \
    --exclude-scope=ci "$NO_CI_TARGET" >/dev/null
  assert_file "$NO_CI_TARGET/METHODOLOGY.md"
  assert_file "$NO_CI_TARGET/docs/README.md"
  assert_no_file "$NO_CI_TARGET/templates/ci/ci.yml"
  (cd "$NO_CI_TARGET" && make check) > "$TMP/no-ci-check.out" 2>&1 \
    || { cat "$TMP/no-ci-check.out" >&2; fail "no-CI export failed its active checks"; }
  for required_scope in core docs; do
    "$SOURCE_FIXTURE/scripts/export.sh" "--exclude-scope=$required_scope" \
      "$TMP/rejected-$required_scope" > "$TMP/rejected-$required_scope.out" 2>&1 \
      && fail "export excluded required $required_scope scope"
    assert_no_file "$TMP/rejected-$required_scope"
  done

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
  fresh_export "$SOURCE_FIXTURE" "$TARGET"
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
  assert_file "$TARGET/config/workflow.tsv"
  assert_file "$TARGET/scripts/lib/workflow.sh"
  # shellcheck disable=SC1091
  ( . "$TARGET/scripts/lib/workflow.sh"; workflow_load "$TARGET" ) \
    || fail 'exported workflow did not validate'
  assert_file "$TARGET/.agentic-flow-review-policy"
  cmp "$ROOT/templates/harness/.agentic-flow-review-policy" "$TARGET/.agentic-flow-review-policy" \
    || fail 'export changed the default review policy'
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

  # A logging wrapper rejects a nested full run immediately: ordinary export checks
  # must use fast mode, while ship-gate owns exported full coverage.
  mv "$TARGET/scripts/self-test.sh" "$TARGET/scripts/self-test.sh.original"
  cat > "$TARGET/scripts/self-test.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$0.calls"
for arg in "$@"; do
  [ "$arg" != --full ] || { echo 'nested --full marker' >&2; exit 91; }
done
exec bash "$0.original" "$@"
SH
  chmod +x "$TARGET/scripts/self-test.sh"

  # A fresh export must start green: its `make check` may not depend on scaffold-only
  # files (regression: `bash -n scripts/export.sh` turned every fresh adoption red and
  # made the Stop gate block from turn one).
  (cd "$TARGET" && make check) >"$TMP/target-check.log" 2>&1 \
    || { cat "$TMP/target-check.log" >&2; fail "make check failed in a fresh export"; }
  (cd "$TARGET" && PATH="$STRIPPED_PATH" make check) > "$TMP/target-check-stripped.log" 2>&1 \
    || { cat "$TMP/target-check-stripped.log" >&2; fail "make check failed in a fresh export on stripped PATH"; }
  # Everyday tests keep exported fast coverage; ship-gate and CI run its full suite.
  (cd "$TARGET" && AGENTIC_MEASURE_EVENTS='' scripts/self-test.sh --fast) \
    > "$TMP/target-fast.log" 2>&1 \
    || { cat "$TMP/target-fast.log" >&2; fail "fast self-test failed in a fresh export"; }

  grep -qx -- '--fast' "$TARGET/scripts/self-test.sh.calls" \
    || fail 'export checks did not run the exported fast suite'
  if grep -q -- '--full' "$TARGET/scripts/self-test.sh.calls"; then
    fail 'everyday export checks invoked the nested --full marker'
  fi
  mv "$TARGET/scripts/self-test.sh.original" "$TARGET/scripts/self-test.sh"
  rm "$TARGET/scripts/self-test.sh.calls"

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
  "$ROOT/scripts/init.sh" "$INIT_TARGET" --owner-login wabkebab --name demo-proj --stack none --yes >"$TMP/init-empty.log" 2>&1 \
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
  "$ROOT/scripts/init.sh" "$INIT_EXISTING" --owner-login wabkebab --name demo-proj --stack none --yes >"$TMP/init-existing.log" 2>&1 \
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
  "$ROOT/scripts/init.sh" "$INIT_NONTty" --owner-login wabkebab --name pipe-proj --stack none < /dev/null >"$TMP/init-nontty.log" 2>&1 \
    || { cat "$TMP/init-nontty.log" >&2; fail "init non-TTY fallback failed"; }
  grep -q "pipe-proj" "$INIT_NONTty/CLAUDE.md" || fail "non-TTY init did not stamp project name"
  if grep -RE "$TOKEN_RE" "$INIT_NONTty" >/dev/null 2>&1; then
    fail "non-TTY init left unfilled template tokens"
  fi

  INIT_RUST="$TMP/init-rust"
  "$ROOT/scripts/init.sh" "$INIT_RUST" --owner-login wabkebab --name rust-proj --stack rust --yes >"$TMP/init-rust.log" 2>&1 \
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
  ci_filter_step() {
    sed -n '/^      - name: Filter paths$/,/^  secrets-scan:$/p' "$1"
  }
  cmp -s <(ci_filter_step "$ROOT/templates/ci/ci.yml") <(ci_filter_step "$INIT_RUST/templates/ci/ci.yml") \
    || fail 'rust init rewrote the CI path filter'
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
    cmp -s <(ci_filter_step "$ROOT/templates/ci/ci.yml") <(ci_filter_step "$profile_workflow") \
      || fail "$profile CI render rewrote the path filter"
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
  [ "$snapshot_digest" = "$(tree_digest "$SOURCE_SNAPSHOT")" ] \
    || fail 'export fixture mutated the shared source snapshot'
  link_snapshot_files "$NO_REMOTE_SOURCE"
  cmp -s "$NO_REMOTE_SOURCE/.claude/skills/create-tags/SKILL.md" \
    "$SOURCE_SNAPSHOT/.claude/skills/create-tags/SKILL.md" \
    || fail 'fixture mutation leaked into the no-remote source'
  NO_REMOTE_TARGET="$TMP/no-remote-target"
  "$NO_REMOTE_SOURCE/scripts/export.sh" "$NO_REMOTE_TARGET" > "$TMP/no-remote-export.out" \
    || fail "export failed from a source with no git remote"
  assert_no_file "$NO_REMOTE_TARGET/.agentic-flow-source"
  grep -q "source repo has no origin remote" "$TMP/no-remote-export.out" \
    || fail "export without remote did not explain why no source was recorded"
  [ "$snapshot_digest" = "$(tree_digest "$SOURCE_SNAPSHOT")" ] \
    || fail 'no-remote fixture mutated the shared source snapshot'
  (cd "$NO_REMOTE_TARGET" && scripts/doctor.sh --scope repo) > "$TMP/no-source-doctor.out" \
    || fail "doctor report failed for a stamped project with no source"
  grep -q "scaffold source not recorded" "$TMP/no-source-doctor.out" \
    || fail "doctor did not warn about a stamped project with no source"

  # Reuse the final pristine export rather than copy another project tree.
  adopter_twin_build "$NO_REMOTE_TARGET"
  adopter_twin_check
  [ "$snapshot_digest" = "$(tree_digest "$SOURCE_SNAPSHOT")" ] \
    || fail 'adopter twin mutated the shared source snapshot'

fi
