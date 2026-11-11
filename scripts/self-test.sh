#!/usr/bin/env bash
# self-test.sh — offline regression checks for the agentic-flow scaffold.
#
# In the scaffold repo (scripts/export.sh present) it runs the full suite, including the
# export invariants. In an exported project (export.sh is deliberately not copied) it skips
# the export section and checks only the local invariants: hooks and spec validation.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
# Exported checks use the same recorded adapter selection as doctor and the shell gate.
# The scaffold has no installation record and checks every source adapter.
# shellcheck disable=SC1091 # This library is part of the installed harness.
if [ -f "$ROOT/scripts/lib/payload-apply.sh" ]; then
  . "$ROOT/scripts/lib/payload-apply.sh"
fi
if [ -f "$ROOT/.agentic-flow-installation" ] && command -v payload_resolve_installation >/dev/null 2>&1; then
  payload_resolve_installation "$ROOT" "$ROOT/config/payload.tsv"
else
  PAYLOAD_ACTIVE_SCOPES="core claude codex opencode ci docs"
fi
active_scope() { case " $PAYLOAD_ACTIVE_SCOPES " in *" $1 "*) return 0 ;; esac; return 1; }
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
LOCAL_EVENTS="$TMP/local-events"
: > "$LOCAL_EVENTS"
REPORT_EVENTS=${AGENTIC_MEASURE_EVENTS:-}
PROJECT_TOKEN="$(printf '{%sPROJECT_NAME}%s' '{' '}')"
# Matches only real scaffold placeholders (double-brace UPPER_SNAKE), not the
# dollar-brace expression syntax that shipped docs quote when documenting CI workflows.
# Built with printf so this file never contains a literal placeholder to self-match.
TOKEN_RE="$(printf '{%s[A-Z][A-Z0-9_]*}%s' '{' '}')"
trap 'rm -rf "$TMP"' EXIT

# Keep per-process cost evidence even when no external report was requested.
# An external report also receives nested self-test events.
measure_event() {
  if [ "${AGENTIC_MEASURE_EVENTS:-}" = "$REPORT_EVENTS" ]; then
    printf '%s\n' "$1" >> "$LOCAL_EVENTS"
  fi
  if [ -n "${AGENTIC_MEASURE_EVENTS:-}" ]; then
    printf '%s\n' "$1" >> "$AGENTIC_MEASURE_EVENTS"
  fi
}

measure_copy() { # <cp arguments, after a successful cp>
  local recursive=0 options=1 arg source i
  local -a paths=()
  for arg in "$@"; do
    if [ "$options" -eq 1 ]; then
      case "$arg" in
        --) options=0; continue ;;
        --recursive|--archive) recursive=1; continue ;;
        --*) continue ;;
        -*)
          case "$arg" in *[Rra]*) recursive=1 ;; esac
          continue ;;
      esac
    fi
    paths+=( "$arg" )
  done
  # The final path is the destination. Count every source, including both
  # operands of `cp a b dir/` and each source tree of a recursive copy.
  for ((i=0; i<${#paths[@]}-1; i++)); do
    source=${paths[$i]}
    if [ "$recursive" -eq 1 ] && [ -d "$source" ]; then
      measure_event fixture_tree_copy
      find "$source" -type f -print | while IFS= read -r arg; do
        measure_event fixture_file_copy
      done
    else
      measure_event fixture_file_copy
    fi
  done
}

cp() {
  command cp "$@" || return $?
  measure_copy "$@"
}

link_snapshot_files() { # <destination>; directories are private, unchanged files share inodes
  local destination="$1" source rel
  mkdir -p "$destination"
  while IFS= read -r -d '' source; do
    rel=${source#"$SOURCE_SNAPSHOT/"}
    mkdir -p "$destination/$(dirname "$rel")"
    ln "$source" "$destination/$rel"
  done < <(find "$SOURCE_SNAPSHOT" -type f -print0)
}

fail() {
  echo "self-test failed: $*" >&2
  exit 1
}

cost_count() { # <event-file> <event>
  awk -v event="$2" '$0 == event { n++ } END { print n+0 }' "$1"
}

assert_cost_budget() { # <event-file> <fast|full>
  local events="$1" mode="$2"
  if [ "$mode" = fast ]; then
    [ "$(cost_count "$events" source_snapshot_copy)" -eq 0 ] || fail 'fast mode built a source snapshot'
    [ "$(cost_count "$events" fixture_tree_copy)" -eq 0 ] || fail 'fast mode copied a fixture tree'
    [ "$(cost_count "$events" fixture_file_copy)" -le 33 ] || fail 'fast mode exceeded 33 fixture file copies'
  elif [ -f "$ROOT/scripts/export.sh" ]; then
    # Exported projects omit the source-only exporter and never build this
    # snapshot. The approved full-copy limits describe scaffold verification.
    [ "$(cost_count "$events" source_snapshot_copy)" -eq 1 ] || fail 'full mode did not reuse one source snapshot'
    [ "$(cost_count "$events" fixture_tree_copy)" -le 1 ] || fail 'full mode exceeded one fixture tree copy'
    [ "$(cost_count "$events" fixture_file_copy)" -le 297 ] || fail 'full mode exceeded 297 fixture file copies'
  fi
  [ "$(cost_count "$events" path_directory_scan)" -eq 0 ] || fail "$mode mode scanned PATH directories"
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
  local out_dir="$1" tool resolved blocked skip
  shift
  for tool in awk bash cat cp find git grep iconv jq make mkdir rm sed sort tr uniq wc; do
    skip=false
    for blocked in "$@"; do
      [ "$tool" = "$blocked" ] && skip=true
    done
    [ "$skip" = true ] && continue
    type -P "$tool" >/dev/null 2>&1 || fail "required fixture tool missing: $tool"
  done
  mkdir -p "$out_dir"
  # The fixture needs only the tools used by the shipped shell checks and hooks.
  # Resolve names directly; walking PATH copies unrelated executables and makes the
  # cost depend on the caller's machine.
  for tool in awk bash basename cat chmod cksum cmp cp cut date dirname env find git \
    grep head iconv jq ln make mkdir mktemp mv od pwd readlink rm sed sh \
    sha256sum shasum sort stat tail touch tr uname uniq wc xargs; do
    skip=false
    for blocked in "$@"; do
      [ "$tool" = "$blocked" ] && skip=true
    done
    [ "$skip" = true ] && continue
    resolved=$(type -P "$tool" 2>/dev/null || true)
    [ -n "$resolved" ] || continue
    case "$resolved" in /*) ln -s "$resolved" "$out_dir/$tool" ;; esac
  done
  printf '%s\n' "$out_dir"
}

# Feed a PreToolUse hook a Bash tool call and assert it blocks / allows.
# Build the payload with jq, not printf. Interpolating a command straight into a JSON string
# breaks the moment it contains a quote — `rg "git add -A" notes.md` produced invalid JSON,
# jq returned empty, and the hook exited on the empty-command guard before reaching any
# pattern. Those assertions passed without testing anything, which is how a false positive on
# exactly that command reached main.
hook_payload() { # <command>
  printf '%s' "$1" | jq -Rs '{tool_input: {command: .}}'
}

must_block() { # <hook> <command>
  local status=0 output
  output=$(hook_payload "$2" | "$1" 2>&1) || status=$?
  case "$status" in
    2) return 0 ;;
    0) fail "hook allowed: $2 (status 0)" ;;
    *) fail "hook crashed/wrong contract: $2 (status $status): $output" ;;
  esac
}

must_allow() { # <hook> <command>
  hook_payload "$2" | "$1" >/dev/null 2>&1 || fail "hook blocked: $2"
}

# Same two assertions with jq absent. The guards used jq only to pull the command out of the
# payload and exited 0 — a silent allow — when it was missing, so a jq-less machine ran with
# every PreToolUse guard quietly disabled. Behaviour may not depend on which tools happen to
# be installed, exactly as already asserted for gitleaks below. NOJQ_PATH is set by the hooks
# group before these run.
must_block_nojq() { # <hook> <command>
  local status=0 output
  output=$(hook_payload "$2" | PATH="$NOJQ_PATH" "$1" 2>&1) || status=$?
  case "$status" in
    2) return 0 ;;
    0) fail "hook allowed without jq: $2 (status 0)" ;;
    *) fail "hook crashed/wrong contract without jq: $2 (status $status): $output" ;;
  esac
}

must_allow_nojq() { # <hook> <command>
  hook_payload "$2" \
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
  elif [ "$SELF_TEST_MODE" != full ] && { [ "$1" = export ] || [ "$1" = upgrade ]; }; then
    return 1
  fi
  GROUPS_RAN="$GROUPS_RAN $1 "
  measure_event "group:$1"
  if [ -z "$ONLY_GROUP" ] && [ "$SELF_TEST_MODE" = fast ]; then
    fast_check_group "$1"
    return 1
  fi
  return 0
}

fast_check_group() { # <group>; fast mode only
  case "$1" in
    contracts)
      [ -f "$ROOT/config/payload.tsv" ] || fail 'payload manifest is missing'
      [ -f "$ROOT/templates/harness/Makefile" ] || [ ! -f "$ROOT/scripts/export.sh" ] \
        || fail 'pristine Makefile is missing'
      ;;
    hooks)
      for hook in block-git-add-all block-push scan-secrets check-gate require-step-comment; do
        [ -x "$ROOT/scripts/hooks/$hook.sh" ] || fail "critical hook is missing: $hook"
      done
      must_block "$ROOT/scripts/hooks/block-git-add-all.sh" 'git add -A'
      must_allow "$ROOT/scripts/hooks/block-git-add-all.sh" 'git add scripts/self-test.sh'
      must_block "$ROOT/scripts/hooks/block-push.sh" 'git push origin main'
      must_allow "$ROOT/scripts/hooks/block-push.sh" 'git status --short'
      ;;
    plan-to-issues)
      [ -x "$ROOT/scripts/plan-to-issues.sh" ] || fail 'plan driver is missing'
      bash -n "$ROOT/scripts/plan-to-issues.sh" || fail 'plan driver has invalid syntax'
      ;;
    lifecycle)
      [ -x "$ROOT/scripts/lifecycle-status.sh" ] || fail 'lifecycle gate is missing'
      bash -n "$ROOT/scripts/lifecycle-status.sh" || fail 'lifecycle gate has invalid syntax'
      ;;
  esac
}

# --- export invariants (scaffold repo only, full suite only) -----------------------------
if should_run export; then
if [ -f "$ROOT/scripts/export.sh" ]; then
  # Snapshot once, then hard-link unchanged files into private directory trees.
  # The five existing files mutated by export cases become private copies below.
  SOURCE_SNAPSHOT="$TMP/source-snapshot"
  mkdir -p "$SOURCE_SNAPSHOT"
  measure_event source_snapshot_copy
  measure_event fixture_tree_copy
  while IFS= read -r -d '' tracked; do
    [ -e "$ROOT/$tracked" ] || continue
    mkdir -p "$SOURCE_SNAPSHOT/$(dirname "$tracked")"
    cp -p "$ROOT/$tracked" "$SOURCE_SNAPSHOT/$tracked"
  done < <(cd "$ROOT" && git ls-files -co --exclude-standard -z)
  snapshot_digest=$(tree_digest "$SOURCE_SNAPSHOT")
  SOURCE_FIXTURE="$TMP/source"
  link_snapshot_files "$SOURCE_FIXTURE"
  for mutable in .claude/skills/create-tags/SKILL.md config/payload.tsv \
    .codex/hooks.json CLAUDE.md templates/harness/CLAUDE.md; do
    rm "$SOURCE_FIXTURE/$mutable"
    cp -p "$SOURCE_SNAPSHOT/$mutable" "$SOURCE_FIXTURE/$mutable"
  done

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
  cp "$ROOT/.claude/skills/create-tags/SKILL.md" \
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

  # A fresh export must start green: its `make check` may not depend on scaffold-only
  # files (regression: `bash -n scripts/export.sh` turned every fresh adoption red and
  # made the Stop gate block from turn one).
  (cd "$TARGET" && make check) >"$TMP/target-check.log" 2>&1 \
    || { cat "$TMP/target-check.log" >&2; fail "make check failed in a fresh export"; }
  (cd "$TARGET" && PATH="$STRIPPED_PATH" make check) > "$TMP/target-check-stripped.log" 2>&1 \
    || { cat "$TMP/target-check-stripped.log" >&2; fail "make check failed in a fresh export on stripped PATH"; }
  # Exported projects have no source-only export.sh and therefore build no source
  # snapshot. Their full suite must still pass, as it does in the shipped CI job.
  (cd "$TARGET" && AGENTIC_MEASURE_EVENTS='' scripts/self-test.sh --full) \
    > "$TMP/target-full.log" 2>&1 \
    || { cat "$TMP/target-full.log" >&2; fail "full self-test failed in a fresh export"; }

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
  sed -n '/^# Ceilings are set just above the MEASURED size of each bundle/,/^# END ROLE-BUNDLE CEILINGS/p' \
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
if [ -f "$ROOT/scripts/export.sh" ]; then
  [ -x "$ROOT/scripts/shell-inventory.sh" ] \
    || fail "scaffold shell inventory is missing"
  # Recompute from manifest source paths independently of the gate helper. In particular,
  # a second call to its --list mode would only prove that the helper agrees with itself.
  expected_shell_inventory() { # <source-root>
    # shellcheck disable=SC2031 # Per-command fixture assignments supply this scoped value.
    local src_root="$1" excluded_scopes="${PAYLOAD_EXCLUDED_SCOPES:-}"
    local source scope disposition rel first
    while IFS="$(printf '\t')" read -r source _dst scope _merge disposition; do
      case "${source:-}" in ''|\#*) continue ;; esac
      [ "$disposition" = export ] || [ "$disposition" = source-only ] || continue
      if [ "$disposition" = export ]; then
        case " $excluded_scopes " in *" $scope "*) continue ;; esac
      fi
      if [ -f "$src_root/$source" ]; then
        printf '%s\n' "$source"
      elif [ -d "$src_root/$source" ]; then
        find "$src_root/$source" -type f | sed "s|^$src_root/||"
      fi
    done < "$src_root/config/payload.tsv" | sort -u | while IFS= read -r rel; do
      [ -f "$src_root/$rel" ] || continue
      IFS= read -r first < "$src_root/$rel" || true
      case "$first" in '#!'*'/bash'|'#!'*'/sh'|'#!'*'env bash'|'#!'*'env sh')
        printf '%s\n' "$rel" ;;
      esac
    done
  }
  expected_shell_inventory "$ROOT" > "$TMP/shell-expected"
  "$ROOT/scripts/shell-inventory.sh" --list > "$TMP/shell-actual"
  cmp -s "$TMP/shell-expected" "$TMP/shell-actual" \
    || fail "scaffold shell inventory is incomplete against manifest source tree"

  shell_fix="$TMP/shell-inventory-fixture"
  mkdir -p "$shell_fix/source/config" "$shell_fix/source/scripts" \
    "$shell_fix/source/harness-src" "$shell_fix/source/scoped-src"
  cp "$ROOT/scripts/shell-inventory.sh" "$shell_fix/source/scripts/"
  printf 'harness-src\tscripts\tcore\tpreserve\texport\n' > "$shell_fix/source/config/payload.tsv"
  printf 'scoped-src\tscoped-dest\tcodex\tpreserve\texport\n' >> "$shell_fix/source/config/payload.tsv"
  printf 'scripts/shell-inventory.sh\tscripts/shell-inventory.sh\tsource-only\tnone\tsource-only\n' \
    >> "$shell_fix/source/config/payload.tsv"
  printf '#!/usr/bin/env bash\nif then\n' > "$shell_fix/source/harness-src/new-command"
  cp "$shell_fix/source/harness-src/new-command" "$shell_fix/source/scripts/new-command"
  # shellcheck disable=SC2016 # Deliberate literal ShellCheck defect in the adopter file.
  printf '#!/usr/bin/env bash\nif then\necho $bad\n' > "$shell_fix/source/scripts/their-deploy.sh"
  printf '#!/usr/bin/env bash\necho scoped\n' > "$shell_fix/source/scoped-src/ignored-command"
  PAYLOAD_EXCLUDED_SCOPES='' AGENTIC_PROJECT_ROOT="$shell_fix/source" \
    "$ROOT/scripts/shell-inventory.sh" --list \
    > "$shell_fix/list"
  grep -qx 'harness-src/new-command' "$shell_fix/list" \
    || fail "manifest extensionless shell command missing from inventory"
  grep -q 'their-deploy' "$shell_fix/list" \
    && fail "adopter script was swept into source inventory"
  # The destination query must not turn a shared directory into ownership of adopter files.
  (
    # shellcheck disable=SC1091 # Source the checked-in library in this isolated probe.
    . "$ROOT/scripts/lib/payload-apply.sh"
    payload_destination_files "$shell_fix/source"
  ) > "$shell_fix/destination-list"
  grep -qx 'scripts/their-deploy.sh' "$shell_fix/destination-list" \
    && fail "destination query swept in an adopter-owned file"
  AGENTIC_PROJECT_ROOT="$shell_fix/source" "$ROOT/scripts/shell-inventory.sh" --syntax \
    > "$shell_fix/syntax.out" 2>&1 \
    && fail "syntax gate missed a manifest extensionless command"
  grep -q 'new-command' "$shell_fix/syntax.out" \
    || fail "syntax gate failed for the wrong reason"
  grep -q 'their-deploy' "$shell_fix/syntax.out" \
    && fail "syntax gate reported the adopter-owned script"
  if command -v shellcheck >/dev/null 2>&1; then
    AGENTIC_PROJECT_ROOT="$shell_fix/source" "$ROOT/scripts/shell-inventory.sh" --lint \
      > "$shell_fix/lint.out" 2>&1 \
      && fail "ShellCheck gate missed a manifest extensionless command"
    grep -q 'new-command' "$shell_fix/lint.out" \
      || fail "ShellCheck gate failed for the wrong reason"
    grep -q 'their-deploy' "$shell_fix/lint.out" \
      && fail "ShellCheck gate reported the adopter-owned script"
  fi
  PAYLOAD_EXCLUDED_SCOPES='' expected_shell_inventory "$shell_fix/source" \
    > "$shell_fix/expected"
  cmp -s "$shell_fix/expected" "$shell_fix/list" \
    || fail "fixture shell inventory missed a manifest source member"
  PAYLOAD_EXCLUDED_SCOPES=codex expected_shell_inventory "$shell_fix/source" \
    > "$shell_fix/expected-excluded"
  PAYLOAD_EXCLUDED_SCOPES=codex AGENTIC_PROJECT_ROOT="$shell_fix/source" \
    "$ROOT/scripts/shell-inventory.sh" --list > "$shell_fix/list-excluded"
  cmp -s "$shell_fix/expected-excluded" "$shell_fix/list-excluded" \
    || fail "shell inventory disagrees with excluded manifest scope"
  grep -q 'ignored-command' "$shell_fix/list-excluded" \
    && fail "shell inventory included an excluded-scope command"
  grep -qx 'scoped-src/ignored-command' "$shell_fix/list" \
    || fail "scope fixture was missing before exclusion"

  rm "$shell_fix/source/harness-src/new-command"
  AGENTIC_PROJECT_ROOT="$shell_fix/source" "$ROOT/scripts/shell-inventory.sh" --syntax \
    > "$shell_fix/adopter-syntax.out" 2>&1 \
    || fail "syntax gate swept in an adopter-owned script under the destination"
  if command -v shellcheck >/dev/null 2>&1; then
    AGENTIC_PROJECT_ROOT="$shell_fix/source" "$ROOT/scripts/shell-inventory.sh" --lint \
      > "$shell_fix/adopter-lint.out" 2>&1 \
      || fail "ShellCheck gate swept in an adopter-owned script under the destination"
  fi
  cp "$ROOT/scripts/agentic-flow" "$shell_fix/source/harness-src/agentic-flow"
  printf '\nif then\n' >> "$shell_fix/source/harness-src/agentic-flow"
  AGENTIC_PROJECT_ROOT="$shell_fix/source" "$ROOT/scripts/shell-inventory.sh" --syntax \
    > "$shell_fix/cli-syntax.out" 2>&1 \
    && fail "syntax gate missed a damaged scripts/agentic-flow"
  grep -q 'agentic-flow' "$shell_fix/cli-syntax.out" \
    || fail "CLI syntax gate failed for the wrong reason"
  cp "$ROOT/scripts/agentic-flow" "$shell_fix/source/harness-src/agentic-flow"
  # shellcheck disable=SC2016 # This literal creates a ShellCheck fixture in the copied CLI.
  printf '\nprintf %%s $unquoted\n' >> "$shell_fix/source/harness-src/agentic-flow"
  if command -v shellcheck >/dev/null 2>&1; then
    AGENTIC_PROJECT_ROOT="$shell_fix/source" "$ROOT/scripts/shell-inventory.sh" --lint \
      > "$shell_fix/cli-lint.out" 2>&1 \
      && fail "ShellCheck gate missed a damaged scripts/agentic-flow"
    grep -q 'SC2086' "$shell_fix/cli-lint.out" \
      || fail "CLI ShellCheck gate failed for the wrong reason"
  fi

  build_fix="$TMP/build-failure"
  mkdir -p "$build_fix/scripts"
  cp "$ROOT/Makefile" "$build_fix/Makefile"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$build_fix/scripts/export.sh"
  chmod +x "$build_fix/scripts/export.sh"
  (cd "$build_fix" && make build) > "$build_fix/out" 2>&1 \
    && fail "make build masked export failure"
  grep -q 'export dry-run ok' "$build_fix/out" \
    && fail "make build printed success after export failed"
fi
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

# --- harness/template section sync -------------------------------------------------------
# CLAUDE.md and AGENTS.md exist twice on purpose and their prose legitimately differs, so
# nothing compared them and a section added to one side shipped unnoticed. The guard asserts
# structure only; assert it fires in both directions, or it is decoration.
SYNC="$ROOT/scripts/check-harness-sync.sh"
if [ -x "$SYNC" ]; then
  SYNCFIX="$TMP/harness-sync-fixture"
  mkdir -p "$SYNCFIX/templates/harness"
  sync_fixture() { # <root-body> <template-body>
    printf '# Contract\n\n%s\n' "$1" > "$SYNCFIX/CLAUDE.md"
    printf '# Contract\n\n%s\n' "$2" > "$SYNCFIX/templates/harness/CLAUDE.md"
    printf '# Executor\n\n## Your job\n' > "$SYNCFIX/AGENTS.md"
    printf '# Executor\n\n## Your job\n' > "$SYNCFIX/templates/harness/AGENTS.md"
  }
  sync_run() { AGENTIC_PROJECT_ROOT="$SYNCFIX" "$SYNC" >/dev/null 2>&1; }

  sync_fixture '## Roles' '## Roles'
  sync_run || fail "harness sync rejected files with matching section structure"

  # The template's "needs wiring" marker is not a structural change.
  sync_fixture '## Stack profile' '## Stack profile  ⚠️ WIRE THIS UP'
  sync_run || fail "harness sync treated the WIRE THIS UP marker as a section difference"

  sync_fixture '## Roles' '## Roles
## Extra section'
  sync_run && fail "harness sync missed a section present only in the template"

  sync_fixture '## Roles
## Root only' '## Roles'
  sync_run && fail "harness sync missed a section present only in the root contract"

  # Prose differences are expected and must not fail: only structure is compared.
  sync_fixture '## Roles

Hand the issue to OpenCode review.' '## Roles

Hand the step to the reviewer.'
  sync_run || fail "harness sync compared prose instead of section structure"

  # An adopted project has no templates/harness/ and must not fail on its absence.
  ADOPTEDFIX="$TMP/harness-sync-adopted"
  mkdir -p "$ADOPTEDFIX"
  printf '# Contract\n\n## Roles\n' > "$ADOPTEDFIX/CLAUDE.md"
  AGENTIC_PROJECT_ROOT="$ADOPTEDFIX" "$SYNC" >/dev/null 2>&1 \
    || fail "harness sync failed in an adopted project with no templates/harness"
fi

# A generated consumer must match its complete canonical body. A malformed render
# graph must leave every consumer untouched, including those before the bad one.
if should_run contracts && [ -d "$ROOT/templates/shared" ]; then
  RENDER="$ROOT/scripts/render-shared.sh"
  RENDER_FIX="$TMP/shared-render-fixture"
  mkdir -p "$RENDER_FIX/templates"
  if [ -d "${SOURCE_SNAPSHOT:-}/templates/shared" ]; then
    mkdir -p "$RENDER_FIX/templates/shared"
    while IFS= read -r -d '' shared; do
      shared_rel=${shared#"$SOURCE_SNAPSHOT/templates/shared/"}
      mkdir -p "$RENDER_FIX/templates/shared/$(dirname "$shared_rel")"
      ln "$shared" "$RENDER_FIX/templates/shared/$shared_rel"
    done < <(find "$SOURCE_SNAPSHOT/templates/shared" -type f -print0)
  else
    cp -R "$ROOT/templates/shared" "$RENDER_FIX/templates/"
  fi
  for rel in Makefile templates/harness/Makefile AGENTS.md templates/harness/AGENTS.md \
             CLAUDE.md templates/harness/CLAUDE.md \
             METHODOLOGY.md .agents/skills/plan-to-issues/SKILL.md \
             .claude/skills/plan-to-issues/SKILL.md .agents/skills/create-tags/SKILL.md \
             .claude/skills/create-tags/SKILL.md .agents/skills/review-execution/SKILL.md \
             .opencode/agent/code-reviewer.md; do
    mkdir -p "$RENDER_FIX/$(dirname "$rel")"
    cp "$ROOT/$rel" "$RENDER_FIX/$rel"
  done
  AGENTIC_PROJECT_ROOT="$RENDER_FIX" "$RENDER" --check >/dev/null \
    || fail "pristine shared render fixture drifted"
  printf '\nconsumer drift\n' >> "$RENDER_FIX/.claude/skills/create-tags/SKILL.md"
  AGENTIC_PROJECT_ROOT="$RENDER_FIX" "$RENDER" --check >/dev/null 2>&1 \
    && fail "shared render missed a whole skill drift"
  cp "$ROOT/.claude/skills/create-tags/SKILL.md" "$RENDER_FIX/.claude/skills/create-tags/SKILL.md"
  sed 's/No unbounded anything/Unlimited anything/' "$ROOT/AGENTS.md" > "$RENDER_FIX/AGENTS.md"
  AGENTIC_PROJECT_ROOT="$RENDER_FIX" "$RENDER" --check >/dev/null 2>&1 \
    && fail "shared render missed content drift under an unchanged heading"
  cp "$ROOT/AGENTS.md" "$RENDER_FIX/AGENTS.md"
  sed 's/\*\*Medium\*\*/**Other**/' "$ROOT/.opencode/agent/code-reviewer.md" \
    > "$RENDER_FIX/.opencode/agent/code-reviewer.md"
  AGENTIC_PROJECT_ROOT="$RENDER_FIX" "$RENDER" --check >/dev/null 2>&1 \
    && fail "shared render missed severity drift"
  cp "$ROOT/.opencode/agent/code-reviewer.md" "$RENDER_FIX/.opencode/agent/code-reviewer.md"
  sed '/<!-- BEGIN SHARED REVIEW CONTRACT -->/d' "$ROOT/.opencode/agent/code-reviewer.md" \
    > "$RENDER_FIX/.opencode/agent/code-reviewer.md"
  before=$(tree_digest "$RENDER_FIX")
  AGENTIC_PROJECT_ROOT="$RENDER_FIX" "$RENDER" >/dev/null 2>&1 \
    && fail "shared render accepted a missing marker"
  [ "$before" = "$(tree_digest "$RENDER_FIX")" ] \
    || fail "failed shared render changed a consumer"
  cp "$ROOT/.opencode/agent/code-reviewer.md" "$RENDER_FIX/.opencode/agent/code-reviewer.md"
  printf '\n<!-- BEGIN SHARED REVIEW CONTRACT -->\n' \
    >> "$RENDER_FIX/.opencode/agent/code-reviewer.md"
  before=$(tree_digest "$RENDER_FIX")
  AGENTIC_PROJECT_ROOT="$RENDER_FIX" "$RENDER" >/dev/null 2>&1 \
    && fail "shared render accepted a duplicate marker"
  [ "$before" = "$(tree_digest "$RENDER_FIX")" ] \
    || fail "duplicate-marker render changed a consumer"
  for surface in "$ROOT/.agents/skills/review-execution/SKILL.md" \
                 "$ROOT/.opencode/agent/code-reviewer.md"; do
    grep -qi 'temporary detached checkout' "$surface" \
      || fail "review guidance lacks isolated red-first verification"
    grep -qi 'revert the change, run the test, restore' "$surface" \
      && fail "review guidance mutates the live checkout for red-first verification"
  done
fi

# Contract drift guard. The second plan-to-issues copy is kept for optionality, not need:
# METHODOLOGY.md §6 points at `.claude/skills/plan-to-issues/`, CLAUDE.md lists the skill
# under the Plan role, and AGENTS.md never mentions it — so nothing has Codex running it
# today. Codex scans only .agents/skills and Claude Code only .claude/skills, so the copy is
# what would let the executor take this over if a project ever switched; the guard keeps the
# two identical so that option stays real rather than quietly rotting.
# review-execution needed no such pair for a different reason: OpenCode discovers
# .agents/skills natively, so one copy already served both and the third was deleted.
if active_scope codex && active_scope claude; then
  cmp -s "$ROOT/.agents/skills/plan-to-issues/SKILL.md" \
         "$ROOT/.claude/skills/plan-to-issues/SKILL.md" \
    || fail "plan-to-issues adapter copies diverged"
fi
# shellcheck disable=SC2016 # literal Markdown backticks, not command substitution.
if active_scope codex; then
  grep -q 'Stack profile.*`CLAUDE.md`' "$ROOT/.agents/skills/plan-to-issues/SKILL.md" \
    || fail "plan-to-issues guidance does not name CLAUDE.md as Stack profile owner"
fi

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

# --skip-make-check means the caller already ran an equivalent gate, and `make check` runs
# docs-index.sh --check first. CI ran `make check` and then doctor --skip-make-check, so the
# same command ran twice against the same state — it cannot reach a different verdict.
AGENTIC_SELFTEST=1 "$ROOT/scripts/doctor.sh" --scope repo --skip-make-check \
  > "$TMP/doctor-skip-docs.out" 2>&1 \
  || fail "doctor rejected repo-scope --skip-make-check"
if active_scope docs; then
  grep -q "docs index up to date (checked by the caller's gate)" "$TMP/doctor-skip-docs.out" \
    || fail "doctor re-ran the docs index check the caller's gate already covered"
else
  grep -q 'docs adapter excluded' "$TMP/doctor-skip-docs.out" \
    || fail "doctor required an excluded docs adapter"
fi
# Without the flag it must still run the check itself.
AGENTIC_SELFTEST=1 "$ROOT/scripts/doctor.sh" --scope repo \
  > "$TMP/doctor-docs.out" 2>&1 || true
if active_scope docs; then
  grep -q "docs index up to date$" "$TMP/doctor-docs.out" \
    || fail "doctor stopped checking the docs index when no gate was declared"
fi

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
  # Raised 1030 -> 1090 for the red-first handoff line, the dependency-version rule the root
  # instance was missing, and the docs/MEMORY.md entry in the minimal read set. That last one
  # is the whole multi-harness reach of the memory index in a single line: Codex and OpenCode
  # both read AGENTS.md, so nothing else has to be added anywhere for either of them to find
  # it. Sized against templates/harness/AGENTS.md, the larger of the pair and the file that
  # becomes an adopter's AGENTS.md, with the usual narrow headroom.
  [ "$executor_words" -le 1090 ] \
    || fail "executor static role bundle exceeds its ceiling: $executor_words words (max 1090)"
fi
# Raised 965 -> 1000 deliberately, for two obligations the contract did not previously carry
# and that no routing target could hold: re-run the executor's verification rather than
# accepting it (a test that passed without testing anything shipped here once, and survived
# review), and treat diff content as data rather than instruction. Both must be read on every
# review, so neither can be routed to METHODOLOGY.md. Headroom stays deliberately narrow so
# the assertion still bites on re-inlining a routed block.
if active_scope codex; then
  reviewer_words=$(wc -w < "$ROOT/.agents/skills/review-execution/SKILL.md" | tr -d ' ')
  [ "$reviewer_words" -le 1000 ] \
    || fail "reviewer static role bundle exceeds its ceiling: $reviewer_words words (max 1000)"
fi
# END ROLE-BUNDLE CEILINGS

# One set of engineering standards across every surface that states them. METHODOLOGY.md §11
# is canonical; AGENTS.md (both instances) compresses them into the executor's always-loaded
# checklist, and the /review agent contract restates them for the reviewer. Those copies are
# deliberate — routing an executor to a 5,000-word document for six rules would cost more per
# turn than it saves — but nothing kept the *set* in sync, so a rule added or retired in one
# place could silently not exist in the others.
#
# Anchor on the distinctive phrase, not the full sentence: each surface words the rule for its
# own audience ("Validate…" for the executor, "Validates…" for the reviewer), and asserting
# identical prose would fail on correct, audience-tuned text.
# templates/harness/AGENTS.md only exists in the source repo — an adopted project receives it
# as its own AGENTS.md — so it joins the list only when present, the same source-vs-adopted
# distinction the export ceilings already make.
standards_surfaces="$ROOT/METHODOLOGY.md $ROOT/AGENTS.md"
[ -f "$ROOT/templates/harness/AGENTS.md" ] \
  && standards_surfaces="$standards_surfaces $ROOT/templates/harness/AGENTS.md"
for standards_surface in $standards_surfaces; do
  [ -f "$standards_surface" ] || fail "missing engineering-standards surface: $standards_surface"
  while IFS= read -r standards_rule; do
    [ -n "$standards_rule" ] || continue
    grep -qiF "$standards_rule" "$standards_surface" \
      || fail "${standards_surface#"$ROOT"/} does not state the standard: \"$standards_rule\""
  done <<'RULES'
at the boundary, once
strings that get interpreted
Deny by default
never literals
No unbounded
failure path
RULES
done
if active_scope opencode; then
  grep -q 'AGENTS.md.*Engineering standards' "$ROOT/.opencode/agent/code-reviewer.md" \
    || fail "OpenCode review does not route engineering standards to AGENTS.md"
fi

# One severity vocabulary across every review surface — the SKILL.md pair AND the live
# /review agent contract, which is where the old block/fix/nit scale survived an earlier
# normalization pass precisely because nothing asserted over it.
for review_surface in "$ROOT/.agents/skills/review-execution/SKILL.md" \
                      "$ROOT/.opencode/agent/code-reviewer.md"; do
  case "$review_surface" in
    */.agents/*) active_scope codex || continue ;;
    */.opencode/*) active_scope opencode || continue ;;
  esac
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
if active_scope codex; then
  grep -q 'AGENTS.md.*Engineering standards' "$ROOT/.agents/skills/review-execution/SKILL.md" \
    || fail "review skill does not route engineering standards to AGENTS.md"
fi

# §8 files worktrees under "Optional capabilities", which is true of fanning out and false of
# isolating writers: nothing required isolation for parallel *editing* agents, so a fan-out of
# writers shared one tree. The tree-state cache made that cheaper, not correct. Anchor on the
# distinctive phrase so the requirement cannot be softened back into an optional nicety.
grep -qi 'isolation stops being optional' "$ROOT/METHODOLOGY.md" \
  || fail "METHODOLOGY.md §8 does not require worktree isolation for concurrent editing agents"

# The ensemble entry is the sixth surface that could have restated the severity scale, which
# is already written out in ten places. It must route to §5 and carry the two failure modes
# that make an ensemble worth less than its headcount suggests — otherwise it reads as "more
# reviewers is better", which is the belief it exists to correct.
ensemble_block=$(awk '
  /^- \*\*Multi-reviewer ensemble\*\*/ { inblock = 1; print; next }
  inblock && /^- \*\*/ { exit }
  inblock { print }
' "$ROOT/METHODOLOGY.md")
[ -n "$ensemble_block" ] || fail "METHODOLOGY.md §8 has no multi-reviewer ensemble entry"
printf '%s' "$ensemble_block" | grep -qi 'not a vote' \
  || fail "the ensemble entry does not say aggregation is not a vote"
printf '%s' "$ensemble_block" | grep -qi 'blind spot' \
  || fail "the ensemble entry does not name the correlated-blind-spot failure mode"
printf '%s' "$ensemble_block" | grep -q 'sev:' \
  && fail "the ensemble entry restates the severity labels instead of routing to METHODOLOGY.md §5"

# The shipped-hook count is stated in prose in two exported documents and was wrong in both:
# METHODOLOGY.md §8 offered ideas "beyond the shipped two" and README.md's source-tree
# inventory called scripts/hooks/ "the two hook scripts", while four ship and settings.json
# calls all four. Nothing counted. Derive the count and assert the prose agrees, so adding or
# retiring a hook fails here instead of leaving a stale number in two adopter-facing files.
# Anchored on the distinctive phrase for the same reason as the standards surfaces above.
hook_count=$(find "$ROOT/scripts/hooks" -maxdepth 1 -name '*.sh' | wc -l | tr -d ' ')
case "$hook_count" in
  1) hook_word=one ;;
  2) hook_word=two ;;
  3) hook_word=three ;;
  4) hook_word=four ;;
  5) hook_word=five ;;
  6) hook_word=six ;;
  *) hook_word="" ;;
esac
if [ -z "$hook_word" ]; then
  fail "no english number word for the shipped hook count ($hook_count) — extend the case above"
fi
grep -q "the $hook_word shipped hooks" "$ROOT/METHODOLOGY.md" \
  || fail "METHODOLOGY.md does not say \"the $hook_word shipped hooks\" ($hook_count ship)"
# METHODOLOGY.md is payload and carries this claim into every adoption, so that assertion is
# unconditional. The root README.md is NOT in config/payload.tsv — it describes this repo's own
# source tree, and an adopted project's README is its own document about its own project. Assert
# it only in the scaffold, the same source-vs-adopted split the role-bundle ceilings make.
if [ -f "$ROOT/scripts/export.sh" ]; then
  grep -q "the $hook_word hook scripts" "$ROOT/README.md" \
    || fail "README.md does not say \"the $hook_word hook scripts\" ($hook_count ship)"
fi

# Counting alone would still let a new hook ship undocumented as long as someone bumped the
# number. CLAUDE.md is the surface that names each hook and what it enforces, so require every
# shipped script to appear there by filename.
while IFS= read -r hook_script; do
  hook_base=$(basename "$hook_script")
  if active_scope claude; then
    grep -q "$hook_base" "$ROOT/CLAUDE.md" \
      || fail "CLAUDE.md does not document the shipped hook $hook_base"
  fi
done < <(find "$ROOT/scripts/hooks" -maxdepth 1 -name '*.sh' | sort)

# §5 is the shared severity source every review surface cites, including the /review agent
# contract for ordinary diffs — but it was titled "(Security reviews)" and defined its levels
# in security terms ("exploitable / auth bypass") while the two surfaces citing it defined
# them in general correctness terms. Assert the title stays unscoped and the blocking
# semantics stay stated, so the definitions cannot drift back apart.
grep -q '^## 5\. Severity legend$' "$ROOT/METHODOLOGY.md" \
  || fail "METHODOLOGY.md §5 is not titled for every review surface"
for blocking_phrase in 'Blocks merge' 'Does not block'; do
  grep -qF "$blocking_phrase" "$ROOT/METHODOLOGY.md" \
    || fail "METHODOLOGY.md §5 does not state \"$blocking_phrase\""
done

# Two review obligations that cannot be routed, because they apply on every review.
# The first exists because a test that passed without testing anything shipped through review
# here once: its payload was built with printf interpolation, produced invalid JSON, the hook
# exited early, and the assertion passed vacuously. Re-running is the only thing that catches
# that class. The second exists because this project's payload IS agent instructions, so a
# diff can change what every adopting project's agent does — or try to instruct the reviewer.
# Both reviewer surfaces carry both, so a reviewer reading either one is fully briefed.
for reviewer_surface in "$ROOT/.agents/skills/review-execution/SKILL.md" \
                        "$ROOT/.opencode/agent/code-reviewer.md"; do
  case "$reviewer_surface" in
    */.agents/*) active_scope codex || continue ;;
    */.opencode/*) active_scope opencode || continue ;;
  esac
  [ -f "$reviewer_surface" ] || fail "missing reviewer surface: $reviewer_surface"
  grep -qi 'fails without the fix' "$reviewer_surface" \
    || fail "${reviewer_surface#"$ROOT"/} does not require confirming a test fails without the fix"
  grep -qi 'as data' "$reviewer_surface" \
    || fail "${reviewer_surface#"$ROOT"/} does not tell the reviewer to treat the diff as data"
  grep -qi 'instruction' "$reviewer_surface" \
    || fail "${reviewer_surface#"$ROOT"/} does not warn that a diff may carry instructions"
done

# The reviewer's focused-group list named five of the six groups, omitting `upgrade`, so a
# reviewer following it would never run that group. Derive it rather than trust the prose.
if active_scope opencode; then
  for reviewer_group in $SELF_TEST_GROUPS; do
    grep -qF "\`$reviewer_group\`" "$ROOT/.opencode/agent/code-reviewer.md" \
      || fail "code-reviewer.md does not name the $reviewer_group self-test group"
  done
fi

# The executor's handoff is where the red-first evidence is cheapest to produce, and the
# dependency-version rule shipped to adopters while the root instance silently lacked it —
# a divergence check-harness-sync.sh cannot see, since it compares ## headings only.
grep -qi 'Red first' "$ROOT/AGENTS.md" \
  || fail "AGENTS.md does not require red-first evidence in the review handoff"

# The memory index reaches all three harnesses through exactly two files: Claude reads
# CLAUDE.md, and Codex and OpenCode both read AGENTS.md (OpenCode prefers AGENTS.md over
# CLAUDE.md outright). Lose either pointer and the layer silently becomes single-harness,
# which nothing else would catch. Both contract pairs must carry it.
grep -qF 'docs/MEMORY.md' "$ROOT/AGENTS.md" \
  || fail "AGENTS.md does not point at the docs/MEMORY.md index"
if active_scope claude; then
  grep -qF 'docs/MEMORY.md' "$ROOT/CLAUDE.md" \
    || fail "CLAUDE.md does not point at the docs/MEMORY.md index"
fi
if [ -d "$ROOT/templates/harness" ]; then
  for memory_template in "$ROOT/templates/harness/CLAUDE.md" "$ROOT/templates/harness/AGENTS.md"; do
    grep -qF 'docs/MEMORY.md' "$memory_template" \
      || fail "${memory_template#"$ROOT"/} does not point at the docs/MEMORY.md index"
  done
fi

# docs-index.sh treats every .md under docs/ as a lifecycle document and fails make check on
# anything outside its four stages. The memory tree is not a lifecycle stage, so it has to be
# skipped explicitly — assert with a real file rather than by reading the case statement.
MEMDOC_FIXTURE="$ROOT/docs/memory/self-test-stage-probe.md"
if active_scope docs; then
  printf '%s\n' '# probe' > "$MEMDOC_FIXTURE"
  if ! "$ROOT/scripts/docs-index.sh" --check >/dev/null 2>&1; then
    rm -f "$MEMDOC_FIXTURE"
    fail "docs-index.sh rejects a .md under docs/memory/ — extend its skip list"
  fi
  rm -f "$MEMDOC_FIXTURE"
fi

# The tree ships empty. docs/MEMORY.md must NOT be payload: it accumulates adopter-local
# entries in place, and upgrade --force overwrites a manifest row unconditionally.
grep -q '^docs/memory/\.gitkeep' "$ROOT/config/payload.tsv" \
  || fail "config/payload.tsv does not ship the docs/memory/ tree"
grep -q '^docs/MEMORY\.md' "$ROOT/config/payload.tsv" \
  && fail "docs/MEMORY.md is a manifest row — upgrade --force would overwrite an adopter's index"

# The memory index carries TWO ceilings and the split is the whole point, so it gets a fixture
# rather than a reading of the source. The tight one is this repo's housekeeping and must never
# fire downstream: an adopter's memory is their own project knowledge, and a ceiling sized to
# our habits firing on their content is precisely the bug recorded at the role-bundle ceilings
# ("broke the first real adopter upgrade past this check"). The 200-line one is the reading
# harness's own hard limit, past which entries are silently dropped, so it is true everywhere
# and must fire even with no scripts/export.sh present.
MEMCEIL="$TMP/memory-ceiling"
memceil_index() { # <entry-count>
  rm -rf "$MEMCEIL"
  mkdir -p "$MEMCEIL/docs/memory" "$MEMCEIL/scripts"
  printf '# MEMORY.md — index\n\n| Entry | Type | Description |\n|---|---|---|\n' \
    > "$MEMCEIL/docs/MEMORY.md"
  memceil_i=0
  while [ "$memceil_i" -lt "$1" ]; do
    # shellcheck disable=SC2016 # literal Markdown backticks, not command substitution.
    printf '| `e%s` | trap | filler |\n' "$memceil_i" >> "$MEMCEIL/docs/MEMORY.md"
    printf -- '---\nid: e%s\n---\nbody\n' "$memceil_i" > "$MEMCEIL/docs/memory/e$memceil_i.md"
    memceil_i=$((memceil_i + 1))
  done
}
# `|| true` is load-bearing, not defensive. The checker exits 1 when it finds a problem, and
# under `set -o pipefail` (line 7) that non-zero status propagates through
# `memceil_run | grep -q ...` even when grep matches — so every assertion below would have
# reported "did not fire" regardless of what the checker actually printed, and the
# expect-no-match ones could never have failed at all. Swallow the status; assert on the text.
memceil_run() { AGENTIC_PROJECT_ROOT="$MEMCEIL" "$ROOT/scripts/check-memory-index.sh" 2>&1 || true; }

memceil_index 60
memceil_run | grep -q "50-line ceiling" \
  && fail "the scaffold-only memory ceiling fired in an adopted project — adopters must be allowed their own memories"
touch "$MEMCEIL/scripts/export.sh"
memceil_run | grep -q "50-line ceiling" \
  || fail "the scaffold memory ceiling did not fire on a 60-entry index inside the scaffold"
rm -f "$MEMCEIL/scripts/export.sh"
memceil_index 205
memceil_run | grep -q "200-line read limit" \
  || fail "the harness read-limit ceiling did not fire on a 205-entry index in an adopted project"

# The three ways an index rots apart from size. Same fixture, one entry, so each failure is
# unambiguous.
memceil_index 1
printf -- '---\nid: orphan\n---\nbody\n' > "$MEMCEIL/docs/memory/orphan.md"
memceil_run | grep -q "has no line in docs/MEMORY.md" \
  || fail "an entry file with no index line was not reported"
rm -f "$MEMCEIL/docs/memory/orphan.md"

# shellcheck disable=SC2016 # literal Markdown backticks, not command substitution.
printf '| `ghost` | trap | nothing backs this |\n' >> "$MEMCEIL/docs/MEMORY.md"
memceil_run | grep -q "has a row for ghost" \
  || fail "an index row with no entry file was not reported"

memceil_index 1
# shellcheck disable=SC2016 # literal Markdown backticks, not command substitution.
printf 'cites `scripts/does-not-exist.sh:12`\n' >> "$MEMCEIL/docs/memory/e0.md"
memceil_run | grep -q "does not exist" \
  || fail "a memory citing a nonexistent path was not reported"

# The cited file has to exist in the fixture, or this lands on the "does not exist" branch and
# proves nothing about the line-count check.
memceil_index 1
mkdir -p "$MEMCEIL/config"
printf 'a\nb\nc\n' > "$MEMCEIL/config/payload.tsv"
# shellcheck disable=SC2016 # literal Markdown backticks, not command substitution.
printf 'cites `config/payload.tsv:99999`\n' >> "$MEMCEIL/docs/memory/e0.md"
memceil_run | grep -q "has only 3 lines" \
  || fail "a memory citing a line past end-of-file was not reported"

# A description is prose and will contain inline code spans. Only the first table cell names an
# entry; reading every backticked token as a filename is what the first draft did, and it
# reported `cp` and `merge-policy` as missing files.
memceil_index 1
# shellcheck disable=SC2016 # literal Markdown backticks, not command substitution.
printf '| `e0` | trap | mentions `cp` and `merge-policy` inline |\n' > "$MEMCEIL/docs/MEMORY.md.body"
{ printf '# MEMORY.md\n\n| Entry | Type | Description |\n|---|---|---|\n'; cat "$MEMCEIL/docs/MEMORY.md.body"; } \
  > "$MEMCEIL/docs/MEMORY.md"
rm -f "$MEMCEIL/docs/MEMORY.md.body"
memceil_run | grep -q "memory index ok" \
  || fail "inline code spans in a description were misread as entry filenames"

rm -rf "$MEMCEIL"
grep -qi 'Adding a dependency' "$ROOT/AGENTS.md" \
  || fail "AGENTS.md does not carry the dependency-version rule"
if [ -f "$ROOT/templates/harness/AGENTS.md" ]; then
  grep -qi 'Red first' "$ROOT/templates/harness/AGENTS.md" \
    || fail "templates/harness/AGENTS.md does not require red-first evidence in the handoff"
fi

# Every §N route an agent is told to follow must resolve. Emit each section on a line
# individually: a greedy `.*§([0-9]+)` keeps only the LAST one, so "§3, §5" silently
# stopped checking §3. ADOPTION.md and the docs README carry routes too.
route_inputs=()
for route_path in "$ROOT/CLAUDE.md" "$ROOT/AGENTS.md" "$ROOT/ADOPTION.md" \
  "$ROOT/docs/README.md" "$ROOT/templates" "$ROOT/docs/templates" \
  "$ROOT/.agents" "$ROOT/.opencode" "$ROOT/scripts" "$ROOT/Makefile"; do
  [ -e "$route_path" ] && route_inputs+=( "$route_path" )
done
while IFS= read -r section; do
  grep -q "^## $section\\. " "$ROOT/METHODOLOGY.md" \
    || fail "METHODOLOGY.md §$section reference has no matching section"
done < <(grep -RhoE 'METHODOLOGY\.md[^[:cntrl:]]*' "${route_inputs[@]}" \
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

MEASURE_FIX="$TMP/measure"
mkdir -p "$MEASURE_FIX/root/docs" "$MEASURE_FIX/root/.agents/skills/review-execution" \
  "$MEASURE_FIX/events"
mkdir -p "$MEASURE_FIX/copy-source/tree" "$MEASURE_FIX/copy-target"
printf 'one\n' > "$MEASURE_FIX/copy-source/one"
printf 'two\n' > "$MEASURE_FIX/copy-source/two"
printf 'three\n' > "$MEASURE_FIX/copy-source/tree/three"
printf 'four\n' > "$MEASURE_FIX/copy-source/tree/four"
: > "$MEASURE_FIX/copy.events"
AGENTIC_MEASURE_EVENTS="$MEASURE_FIX/copy.events" cp \
  "$MEASURE_FIX/copy-source/one" "$MEASURE_FIX/copy-source/two" \
  "$MEASURE_FIX/copy-target/"
[ "$(grep -c '^fixture_file_copy$' "$MEASURE_FIX/copy.events")" -eq 2 ] \
  || fail 'multi-source cp was not counted per file'
AGENTIC_MEASURE_EVENTS="$MEASURE_FIX/copy.events" cp -Rp \
  "$MEASURE_FIX/copy-source/tree" "$MEASURE_FIX/copy-target/"
AGENTIC_MEASURE_EVENTS="$MEASURE_FIX/copy.events" measure_copy --recursive \
  "$MEASURE_FIX/copy-source/tree" "$MEASURE_FIX/copy-target/"
AGENTIC_MEASURE_EVENTS="$MEASURE_FIX/copy.events" measure_copy --archive \
  "$MEASURE_FIX/copy-source/tree" "$MEASURE_FIX/copy-target/"
[ "$(grep -c '^fixture_tree_copy$' "$MEASURE_FIX/copy.events")" -eq 3 ] \
  && [ "$(grep -c '^fixture_file_copy$' "$MEASURE_FIX/copy.events")" -eq 8 ] \
  || fail 'recursive cp flags did not count trees and copied files'
# One snapshot can coexist with repeated whole-tree materializations. This
# approved budget applies only in the scaffold, which builds that snapshot.
if [ -f "$ROOT/scripts/export.sh" ]; then
  printf 'source_snapshot_copy\nfixture_tree_copy\nfixture_tree_copy\n' \
    > "$MEASURE_FIX/recopied.events"
  ( assert_cost_budget "$MEASURE_FIX/recopied.events" full ) \
    > "$MEASURE_FIX/recopied.out" 2>&1 \
    && fail 'fixture budget accepted repeated tree copying with one snapshot'
  grep -q 'exceeded one fixture tree copy' "$MEASURE_FIX/recopied.out" \
    || fail 'fixture budget did not identify repeated tree copying'
fi
( PATH='' path_without_tools "$MEASURE_FIX/missing-tools" jq ) \
  > "$MEASURE_FIX/missing-tools.out" 2>&1 \
  && fail 'fixture PATH accepted missing required tools'
grep -q 'required fixture tool missing:' "$MEASURE_FIX/missing-tools.out" \
  || { cat "$MEASURE_FIX/missing-tools.out" >&2; fail 'missing fixture tool was not identified'; }
if [ -f "$ROOT/scripts/export.sh" ]; then
  : > "$MEASURE_FIX/dispatch.events"
  AGENTIC_MEASURE_EVENTS="$MEASURE_FIX/dispatch.events" \
    "$ROOT/scripts/self-test.sh" --fast > "$MEASURE_FIX/dispatch.out" \
    || fail 'nested fast dispatch failed'
  actual_fast_groups=$(awk -F: '$1 == "group" { print $2 }' \
    "$MEASURE_FIX/dispatch.events" | sort -u | tr '\n' ' ')
  [ "$actual_fast_groups" = 'contracts hooks lifecycle plan-to-issues ' ] \
    || fail "fast dispatch included an unexpected group: $actual_fast_groups"
  assert_cost_budget "$MEASURE_FIX/dispatch.events" fast
fi
printf 'shared words\n' > "$MEASURE_FIX/root/CLAUDE.md"
printf 'executor words\n' > "$MEASURE_FIX/root/AGENTS.md"
printf 'memory words\n' > "$MEASURE_FIX/root/docs/MEMORY.md"
printf 'review words\n' > "$MEASURE_FIX/root/.agents/skills/review-execution/SKILL.md"
printf 'group:contracts\ngroup:contracts\nfixture_tree_copy\nfixture_file_copy\n' \
  > "$MEASURE_FIX/events/fast.events"
printf 'group:contracts\npacket_words:12\n' > "$MEASURE_FIX/events/full.events"
measure_cmd=( "$ROOT/scripts/measure-harness.sh" --root "$MEASURE_FIX/root" \
  --events "$MEASURE_FIX/events" --format json )
"${measure_cmd[@]}" > "$MEASURE_FIX/first.json" \
  || fail 'measurement fixture failed'
"${measure_cmd[@]}" > "$MEASURE_FIX/second.json"
cmp -s "$MEASURE_FIX/first.json" "$MEASURE_FIX/second.json" \
  || fail 'measurement output changed for unchanged inputs'
jq -e '.roles.executor.static_words == 6 and .roles.executor.static_files == 3
  and .roles.executor.ceiling == 100 and .roles.executor.generated_packet_words == 12
  and .verification.fast.fast_group_count == 1
  and .verification.fast.fixture_tree_copies == 1
  and .verification.fast.fixture_copied_files == 1' "$MEASURE_FIX/first.json" >/dev/null \
  || fail 'measurement duplicated shared words or miscounted work'
printf 'fixture_tree_copy\nfixture_file_copy\n' >> "$MEASURE_FIX/events/fast.events"
"${measure_cmd[@]}" > "$MEASURE_FIX/added.json"
jq -e '.verification.fast.fixture_tree_copies == 2
  and .verification.fast.fixture_copied_files == 2' "$MEASURE_FIX/added.json" >/dev/null \
  || fail 'new fixture did not move both copy counters'
"$ROOT/scripts/measure-harness.sh" --format yaml --root "$MEASURE_FIX/root" \
  --events "$MEASURE_FIX/events" >/dev/null 2>&1 \
  && fail 'measurement accepted an invalid format'
mv "$MEASURE_FIX/root/AGENTS.md" "$MEASURE_FIX/missing-agents"
"${measure_cmd[@]}" >/dev/null 2>&1 \
  && fail 'measurement accepted a missing bundle input'
mv "$MEASURE_FIX/missing-agents" "$MEASURE_FIX/root/AGENTS.md"
jq '.roles.executor.ceiling = 0' "$MEASURE_FIX/first.json" > "$MEASURE_FIX/ceiling.json"
"${measure_cmd[@]}" --baseline "$MEASURE_FIX/ceiling.json" >/dev/null 2>&1 \
  && fail 'measurement accepted a bundle above its baseline ceiling'
printf 'packet_words:801\n' > "$MEASURE_FIX/events/full.events"
"${measure_cmd[@]}" >/dev/null 2>&1 \
  && fail 'measurement accepted a packet above the absolute cap'
fi

# --- upgrade surface --------------------------------------------------------------------
if should_run upgrade; then
AGENTIC_FLOW_CLI="$ROOT/scripts/agentic-flow"
assert_file "$AGENTIC_FLOW_CLI"

# Assurance state is project-owned. Failures must leave both tracked files untouched.
ASSURANCE="$ROOT/scripts/assurance.sh"
assert_file "$ASSURANCE"
ASSURANCE_FIX="$TMP/assurance"
mkdir -p "$ASSURANCE_FIX/scripts"
cp "$ASSURANCE" "$ASSURANCE_FIX/scripts/assurance.sh"
(cd "$ASSURANCE_FIX" && scripts/assurance.sh status) > "$TMP/assurance-default.out" \
  || fail "missing assurance state did not default to Standard"
grep -q 'standard.*legacy default' "$TMP/assurance-default.out" \
  || fail "assurance status did not identify the legacy default"
(cd "$ASSURANCE_FIX" && scripts/assurance.sh set strict) \
  || fail "assurance raise failed"
grep -qx strict "$ASSURANCE_FIX/.agentic-flow-assurance" || fail "raise was not persisted"
(cd "$ASSURANCE_FIX" && scripts/assurance.sh set standard) > "$TMP/assurance-unaudited.out" 2>&1 \
  && fail "unaudited downgrade succeeded"
grep -qx strict "$ASSURANCE_FIX/.agentic-flow-assurance" || fail "failed downgrade changed state"
(cd "$ASSURANCE_FIX" && scripts/assurance.sh set standard --approved-by human@example.invalid --reason 'Risk review completed') \
  || fail "attributed downgrade failed"
grep -q 'human@example.invalid.*Risk review completed' "$ASSURANCE_FIX/.agentic-flow-assurance-audit" \
  || fail "downgrade audit did not persist attribution and reason"
printf 'malformed audit\n' > "$ASSURANCE_FIX/.agentic-flow-assurance-audit"
(cd "$ASSURANCE_FIX" && scripts/assurance.sh --check) > /dev/null 2>&1 \
  && fail "malformed assurance audit accepted"
(cd "$ASSURANCE_FIX" && scripts/assurance.sh set strict) > /dev/null 2>&1 \
  && fail "state changed over malformed assurance audit"
grep -qx standard "$ASSURANCE_FIX/.agentic-flow-assurance" \
  || fail "malformed audit changed state"
printf '2026-01-01T00:00:00Z\tstrict\tstandard\thuman@example.invalid\tRisk review completed\n' \
  > "$ASSURANCE_FIX/.agentic-flow-assurance-audit"
(cd "$ASSURANCE_FIX" && scripts/assurance.sh set quick --approved-by 'bad identity' --reason ok) > /dev/null 2>&1 \
  && fail "malformed audit identity accepted"
(cd "$ASSURANCE_FIX" && scripts/assurance.sh set quick --approved-by human@example.invalid --reason '') > /dev/null 2>&1 \
  && fail "empty audit reason accepted"
grep -qx standard "$ASSURANCE_FIX/.agentic-flow-assurance" || fail "malformed audit changed state"
printf 'unknown\n' > "$ASSURANCE_FIX/.agentic-flow-assurance"
(cd "$ASSURANCE_FIX" && scripts/assurance.sh --check) > /dev/null 2>&1 \
  && fail "unknown assurance state accepted"
printf 'standard\nstrict\n' > "$ASSURANCE_FIX/.agentic-flow-assurance"
(cd "$ASSURANCE_FIX" && scripts/assurance.sh --check) > /dev/null 2>&1 \
  && fail "multiline assurance state accepted"


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
printf 'strict\n' > "$UPGRADE_TARGET/.agentic-flow-assurance"
(cd "$UPGRADE_TARGET" && "$AGENTIC_FLOW_CLI" upgrade) > "$TMP/upgrade-no-yes.out" 2>"$TMP/upgrade-no-yes.err" \
  && fail "upgrade wrote without --yes in a non-interactive run"
grep -q "pass --yes" "$TMP/upgrade-no-yes.err" \
  || fail "upgrade without --yes did not explain confirmation"

printf '%s\n' '# local project edits' > "$UPGRADE_TARGET/CLAUDE.md"
printf '%s\n' '# occupied candidate' > "$UPGRADE_TARGET/CLAUDE.md.agentic-new"
(cd "$UPGRADE_TARGET" && "$AGENTIC_FLOW_CLI" upgrade --yes) > "$TMP/upgrade-pending.out" \
  || fail "upgrade with merge candidates failed"
grep -qx strict "$UPGRADE_TARGET/.agentic-flow-assurance" \
  || fail "upgrade overwrote customized assurance baseline"
grep -qx 'old+1111111' "$UPGRADE_TARGET/.agentic-flow-version" \
  || fail "upgrade advanced installed version while candidates remained"
assert_file "$UPGRADE_TARGET/.agentic-flow-candidate-version"
assert_no_file "$UPGRADE_TARGET/.agentic-flow-installation"
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
assert_file "$UPGRADE_CLEAN/.agentic-flow-installation"
assert_file "$UPGRADE_CLEAN/.agentic-flow-source-applied"
assert_no_file "$UPGRADE_CLEAN/docs-index-sentinel"

# An installed pre-F-7 upgrader parses the fetched five-column manifest with its
# installed library. Prove that path before the replacement CLI can read new state.
if [ -f "$ROOT/scripts/export.sh" ]; then
LEGACY_SOURCE="$TMP/legacy-upgrade-source"
mkdir -p "$LEGACY_SOURCE/config" "$LEGACY_SOURCE/scripts/lib" "$LEGACY_SOURCE/.codex"
printf '11.0.0\n' > "$LEGACY_SOURCE/VERSION"
printf 'scripts/agentic-flow\tscripts/agentic-flow\tcore\tpreserve\texport\nscripts/lib\tscripts/lib\tcore\tpreserve\texport\n.codex/hooks.json\t.codex/hooks.json\tcodex\tpreserve\texport\nconfig/payload.tsv\tconfig/payload.tsv\tcore\tpreserve\texport\n' \
  > "$LEGACY_SOURCE/config/payload.tsv"
cp "$ROOT/scripts/agentic-flow" "$LEGACY_SOURCE/scripts/agentic-flow"
cp "$ROOT/scripts/lib/payload-apply.sh" "$LEGACY_SOURCE/scripts/lib/payload-apply.sh"
printf '{}\n' > "$LEGACY_SOURCE/.codex/hooks.json"
(
  cd "$LEGACY_SOURCE"
  git init -q .
  git config user.email selftest@example.invalid
  git config user.name selftest
  git config commit.gpgsign false
  git add VERSION config/payload.tsv scripts/agentic-flow scripts/lib/payload-apply.sh .codex/hooks.json
  git commit -q -m 'Seed new payload for old upgrader'
  git branch -M main
)
for legacy_mode in default claude-only pending; do
  LEGACY_TARGET="$TMP/legacy-upgrade-$legacy_mode"
  mkdir -p "$LEGACY_TARGET/config" "$LEGACY_TARGET/scripts/lib"
  git -C "$ROOT" show 9a82aff:scripts/agentic-flow > "$LEGACY_TARGET/scripts/agentic-flow"
  git -C "$ROOT" show 9a82aff:scripts/lib/payload-apply.sh \
    > "$LEGACY_TARGET/scripts/lib/payload-apply.sh"
  chmod +x "$LEGACY_TARGET/scripts/agentic-flow"
  # The pre-F-7 CLI reads past its dispatch after upgrade rewrites it. Bash 3.2 and 5.x
  # disagree about the resulting syntax error's status, so run an unchanging copy.
  LEGACY_CLI="$TMP/legacy-cli-$legacy_mode"
  cp "$LEGACY_TARGET/scripts/agentic-flow" "$LEGACY_CLI"
  cp "$LEGACY_SOURCE/config/payload.tsv" "$LEGACY_TARGET/config/payload.tsv"
  printf 'old+0000000\n' > "$LEGACY_TARGET/.agentic-flow-version"
  printf 'origin file://%s\nref main\n' "$LEGACY_SOURCE" \
    > "$LEGACY_TARGET/.agentic-flow-source"
  if [ "$legacy_mode" = claude-only ]; then
    printf 'codex\n' > "$LEGACY_TARGET/.agentic-flow-scopes-excluded"
  fi
  if [ "$legacy_mode" = pending ]; then
    (cd "$LEGACY_TARGET" && bash "$LEGACY_CLI" upgrade --yes) \
      > "$TMP/legacy-pending.out" 2>&1 \
      || fail "old upgrader rejected the new five-column manifest"
    grep -qx 'old+0000000' "$LEGACY_TARGET/.agentic-flow-version" \
      || fail "old upgrader advanced a pending installation"
    assert_no_file "$LEGACY_TARGET/.agentic-flow-installation"
  else
    (cd "$LEGACY_TARGET" && bash "$LEGACY_CLI" upgrade --yes --force) \
      > "$TMP/legacy-$legacy_mode.out" 2>&1 \
      || fail "old $legacy_mode upgrader rejected the new manifest"
    if [ "$legacy_mode" = claude-only ]; then
      assert_no_file "$LEGACY_TARGET/.codex/hooks.json"
    else
      assert_file "$LEGACY_TARGET/.codex/hooks.json"
    fi
    assert_no_file "$LEGACY_TARGET/.agentic-flow-installation"
    (cd "$LEGACY_TARGET" && scripts/agentic-flow upgrade --yes --force) \
      > "$TMP/legacy-migrate-$legacy_mode.out" 2>&1 \
      || fail "new upgrader did not migrate $legacy_mode installation"
    assert_file "$LEGACY_TARGET/.agentic-flow-installation"
    if [ "$legacy_mode" = claude-only ]; then
      grep -q '^scope=codex$' "$LEGACY_TARGET/.agentic-flow-installation" \
        && fail "migration reinstated excluded Codex scope"
    fi
  fi
done
# The current CLI must not read its replacement after upgrade rewrites it. The release
# appends one line at the running file's end-of-file offset, the next bytes bash would read.
{
  cat "$TMP/legacy-upgrade-default/scripts/agentic-flow"
  printf "printf 'agentic-flow read its replacement\\\\n'\\n"
} > "$LEGACY_SOURCE/scripts/agentic-flow"
(
  cd "$LEGACY_SOURCE"
  printf '11.0.1\n' > VERSION
  git add VERSION scripts/agentic-flow
  git commit -q -m 'Append to the CLI for a self-replacing upgrade'
)
(cd "$TMP/legacy-upgrade-default" && scripts/agentic-flow upgrade --yes --force) \
  > "$TMP/self-replace.out" 2>&1 \
  || fail "current upgrader failed while replacing itself"
grep -q 'read its replacement' "$TMP/self-replace.out" \
  && fail "current upgrader executed its replacement after upgrading"
cmp -s "$LEGACY_SOURCE/scripts/agentic-flow" "$TMP/legacy-upgrade-default/scripts/agentic-flow" \
  || fail "self-replacing upgrade did not install the new CLI"
fi
fi

# --- hook invariants (run everywhere) ----------------------------------------------------
if should_run hooks; then
# Review #110: closing substitutions and adjacent redirects are verb boundaries.
# shellcheck disable=SC2016 # Command strings are hook input, never executed.
for protected_command in 'git push' 'git-claude push' 'gh pr merge'; do
  must_block "$ROOT/scripts/hooks/block-push.sh" 'echo "`'"$protected_command"'`"'
  must_block "$ROOT/scripts/hooks/block-push.sh" 'echo "$('"$protected_command"'>out)"'
  must_block "$ROOT/scripts/hooks/block-push.sh" 'echo "$('"$protected_command"'</dev/null)"'
done
# shellcheck disable=SC2016
must_block "$ROOT/scripts/hooks/scan-secrets.sh" 'echo "`git commit`"'
# shellcheck disable=SC2016
must_block "$ROOT/scripts/hooks/scan-secrets.sh" 'echo "$(git commit>out)"'
# shellcheck disable=SC2016
must_block "$ROOT/scripts/hooks/scan-secrets.sh" 'echo "$(git commit</dev/null)"'
# Single-quoted backticks remain data, including after a parser failure elsewhere.
for guard in block-push block-git-add-all scan-secrets; do
  must_allow "$ROOT/scripts/hooks/$guard.sh" "echo '\`git push\`'"
  must_allow "$ROOT/scripts/hooks/$guard.sh" "echo \$(date); echo '\`git push\`'"
done

# Broken tool-call JSON must still fail closed on a protected operation.
for guard_command in 'block-push:git push' 'block-git-add-all:git add -A' 'scan-secrets:git commit'; do
  status=0
  printf '{"tool_input":{"command":"%s' "${guard_command#*:}" \
    | "$ROOT/scripts/hooks/${guard_command%%:*}.sh" >/dev/null 2>&1 || status=$?
  [ "$status" -eq 2 ] || fail "malformed protected payload allowed: $guard_command (status $status)"
done
# Issue #110: parse failures must distinguish operations from tool mentions.
# shellcheck disable=SC2016 # These command strings are never executed.
for guard in block-push block-git-add-all scan-secrets; do
  guard_path="$ROOT/scripts/hooks/$guard.sh"
  must_allow "$guard_path" 'v=$(jq -r .x package.json); echo "$v"'
  must_allow "$guard_path" 'eval "$(scripts/build-image.sh --print-env)" && docker compose ps'
  must_allow "$guard_path" 'gh issue create --title t --body-file body.md'
done
# shellcheck disable=SC2016
for guard in block-push block-git-add-all; do
  guard_path="$ROOT/scripts/hooks/$guard.sh"
  must_allow "$guard_path" $'cat > body.md <<\'EOF\'\nUses `vite.config.ts`\nEOF\ngh issue create --body-file body.md'
  must_allow "$guard_path" 'for p in a b; do v=$(jq -r .x package.json); done; git log -5; gh pr view 22'
  must_allow "$guard_path" 'echo "$(date)"; grep -n "git push" README.md'
  must_allow "$guard_path" 'echo $(date); grep -n "use git push here" README.md'
  must_allow "$guard_path" 'echo $(date); echo '\''$(git push)'\'''
done
# shellcheck disable=SC2016
must_allow "$ROOT/scripts/hooks/scan-secrets.sh" 'b=$(basename a); git merge-file -p a "$b" c'
# shellcheck disable=SC2016
must_allow "$ROOT/scripts/hooks/block-push.sh" 'echo $(date); git status'
# shellcheck disable=SC2016
must_block "$ROOT/scripts/hooks/block-push.sh" 'git commit -m "Run `make check` first."'
must_allow "$ROOT/scripts/hooks/block-push.sh" $'git commit -F - <<\'EOF\'\nRun `make check` first.\nEOF'

# Literal bodies must stay opaque, but commands following them remain guarded.
for delimiter in "'EOF'" '"EOF"' '\EOF'; do
  for redirect in '<<' '<<-'; do
    literal_body="cat $redirect$delimiter"$'\n\tgit push; git add -A; git commit -m "$(date)"\n'
    if [ "$redirect" = '<<-' ]; then literal_body+=$'\tEOF\n'; else literal_body+=$'EOF\n'; fi
    for guard in block-push block-git-add-all scan-secrets; do
      must_allow "$ROOT/scripts/hooks/$guard.sh" "$literal_body"
    done
    must_block "$ROOT/scripts/hooks/block-push.sh" "${literal_body}git push"
    must_block "$ROOT/scripts/hooks/block-git-add-all.sh" "${literal_body}git add -A"
  done
done
must_allow "$ROOT/scripts/hooks/block-push.sh" $'cat <<\'ONE\' <<"TWO" # literal inputs\n`git push`\nONE\n$(git push)\nTWO\ngit status'
must_block "$ROOT/scripts/hooks/block-push.sh" $'git push <<\'EOF\'\nmissing delimiter'
# shellcheck disable=SC2016
must_block "$ROOT/scripts/hooks/block-push.sh" 'echo $(date); git-claude push'
# shellcheck disable=SC2016
must_block "$ROOT/scripts/hooks/block-push.sh" 'echo $(date); gh pr merge 12'
# shellcheck disable=SC2016
for broad_add in '-A' '.' '--all'; do
  must_block "$ROOT/scripts/hooks/block-git-add-all.sh" 'echo $(date); git add '"$broad_add"
done
# shellcheck disable=SC2016
must_block "$ROOT/scripts/hooks/scan-secrets.sh" 'git commit -m "Run `make check` first."'
must_block "$ROOT/scripts/hooks/scan-secrets.sh" $'git commit -F - <<EOF\n$(date)\nEOF'

NOJQ_PATH=$(path_without_tools "$TMP/nojq-bin" jq)
PATH="$NOJQ_PATH" bash -c 'command -v jq' >/dev/null 2>&1 \
  && fail "jq-less PATH still contains jq"
PATH="$NOJQ_PATH" command -v git >/dev/null 2>&1 \
  || fail "jq-less PATH accidentally removed ordinary git"

HOOK_CRASH="$TMP/crashing-hook"
printf '#!/usr/bin/env bash\necho stub-crash >&2\nexit 1\n' > "$HOOK_CRASH"
chmod +x "$HOOK_CRASH"
( must_block "$HOOK_CRASH" 'git add -A' ) > "$TMP/hook-crash.out" 2>&1 \
  && fail "must_block accepted a hook crash as a policy block"
grep -q 'status 1' "$TMP/hook-crash.out" \
  || fail "must_block crash diagnostic omitted the exit status"
grep -q 'stub-crash' "$TMP/hook-crash.out" \
  || fail "must_block discarded hook stderr"
( must_block_nojq "$HOOK_CRASH" 'git add -A' ) > "$TMP/hook-crash-nojq.out" 2>&1 \
  && fail "must_block_nojq accepted a hook crash as a policy block"
grep -q 'status 1' "$TMP/hook-crash-nojq.out" \
  || fail "must_block_nojq crash diagnostic omitted the exit status"
grep -q 'stub-crash' "$TMP/hook-crash-nojq.out" \
  || fail "must_block_nojq discarded hook stderr"

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
# Global git options between `git` and the verb are everyday usage, not evasion; the
# tolerance previously covered only -C/-c, so `git --no-pager add -A` walked straight past.
must_block "$ADD_GUARD" 'git --no-pager add -A'
must_block "$ADD_GUARD" 'git -p add .'
must_block "$ADD_GUARD" 'git --git-dir=/tmp/x add --all'
must_block "$ADD_GUARD" 'git --no-pager -C /some/path add -A'
must_block "$ADD_GUARD" 'sudo git add -A'
must_block "$ADD_GUARD" 'nohup git add .'
must_allow "$ADD_GUARD" 'git --no-pager add README.md'
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
  (cd "$SECFIX" && must_block "$SECRET_GUARD" $'git commit -F - <<\'EOF\'\nRun `make check` first.\nEOF')
  status=0
  (cd "$SECFIX" && hook_payload 'sudo git commit -m x' | "$SECRET_GUARD") \
    >/dev/null 2>&1 || status=$?
  [ "$status" -eq 2 ] || fail "sudo Git commit bypassed the staged-secret hook"
  status=0
  (cd "$SECFIX" && hook_payload 'nohup git commit -m x' | "$SECRET_GUARD") \
    >/dev/null 2>&1 || status=$?
  [ "$status" -eq 2 ] || fail "nohup Git commit bypassed the staged-secret hook"
  secret_hook 'git-claude commit -m x' && fail "secret scanner allowed a staged AWS-format key"
  secret_hook 'git-codex commit -m x' && fail "secret scanner allowed a Codex wrapper commit"
  secret_hook 'git-opencode commit -m x' && fail "secret scanner allowed an OpenCode wrapper commit"
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
  (cd "$SECFIX" && must_allow "$SECRET_GUARD" $'git commit -F - <<\'EOF\'\nRun `make check` first.\nEOF')

  # The default index is empty. Every redirected invocation below must inspect
  # its own staged content, and a block must use the hook's documented exit 2.
  alt_repo="$TMP/secret-other-repo"
  mkdir -p "$alt_repo"
  alt_repo=$(cd "$alt_repo" && pwd -P)
  space_repo="$TMP/secret other repo"
  ln -s "$alt_repo" "$space_repo"
  (cd "$alt_repo" && git init -q .)
  secret_value="$(printf 'AKIA%s' 'IOSFODNN7EXAMPLE')"
  printf 'key = "%s"\n' "$secret_value" > "$alt_repo/staged.txt"
  (cd "$alt_repo" && git add staged.txt)
  alt_index="$TMP/secret-other.index"
  printf 'key = "%s"\n' "$secret_value" > "$SECFIX/staged.txt"
  (cd "$SECFIX" && GIT_INDEX_FILE="$alt_index" git add staged.txt)

  # A fake first layer records the effective context, then the high-signal
  # layer must independently reject the synthetic staged key.
  gl_bin="$TMP/gitleaks-fixture"
  mkdir -p "$gl_bin"
  cat > "$gl_bin/gitleaks" <<'FAKE_GITLEAKS'
#!/usr/bin/env bash
case " $* " in *" --help "*) exit 0 ;; esac
printf '%s|%s|%s|%s\n' "$PWD" "${GIT_DIR:-}" "${GIT_WORK_TREE:-}" "${GIT_INDEX_FILE:-}" >> "$FAKE_GITLEAKS_LOG"
git diff --cached --name-only > "$FAKE_GITLEAKS_DIFF" || exit 1
exit "${FAKE_GITLEAKS_EXIT:-0}"
FAKE_GITLEAKS
  chmod +x "$gl_bin/gitleaks"
  gl_log="$TMP/gitleaks-context.log"
  gl_diff="$TMP/gitleaks-diff.log"
  assert_redirected_secret() { # <command> <expected-index-or-git-dir>
    : > "$gl_log"
    : > "$gl_diff"
    status=0
    (cd "$SECFIX" && hook_payload "$1" | PATH="$gl_bin:$PATH" \
      FAKE_GITLEAKS_LOG="$gl_log" FAKE_GITLEAKS_DIFF="$gl_diff" \
      "$SECRET_GUARD") > "$TMP/redirected-secret.out" 2>&1 || status=$?
    [ "$status" -eq 2 ] || fail "redirected commit did not block with exit 2: $1 (status $status)"
    grep -q 'Blocked:' "$TMP/redirected-secret.out" \
      || fail "redirected commit lacked a block diagnostic: $1"
    ! grep -qF "$secret_value" "$TMP/redirected-secret.out" \
      || fail "redirected commit printed staged secret text"
    grep -qF "$2" "$gl_log" || fail "gitleaks did not receive redirected context: $1"
    grep -q 'staged.txt' "$gl_diff" || fail "gitleaks did not inspect redirected staged index: $1"
  }
  assert_redirected_secret "git -C '$space_repo' commit -m x" "$alt_repo"
  assert_redirected_secret "git -C \"$space_repo\" commit -m x" "$alt_repo"
  assert_redirected_secret "git -C ${space_repo// /\\ } commit -m x" "$alt_repo"
  assert_redirected_secret 'git -C ../secret-other-repo commit -m x' "$alt_repo"
  assert_redirected_secret "cd '$alt_repo' && git commit -m x" "$alt_repo"
  assert_redirected_secret "GIT_DIR=$alt_repo/.git git commit -m x" "$alt_repo/.git"
  assert_redirected_secret "git --git-dir=$alt_repo/.git --work-tree=$alt_repo commit -m x" "$alt_repo/.git"
  assert_redirected_secret "GIT_INDEX_FILE=$alt_index git commit -m x" "$alt_index"
  assert_redirected_secret "env GIT_INDEX_FILE=$alt_index git commit -m x" "$alt_index"
  assert_redirected_secret "env -- GIT_INDEX_FILE=$alt_index git commit -m x" "$alt_index"
  assert_redirected_secret "GIT_DIR=$alt_repo/.git GIT_INDEX_FILE=$alt_repo/.git/index git commit -m x" "$alt_repo/.git/index"
  # GIT_WORK_TREE changes the worktree while retaining this repository's index.
  # Stage a secret there to ensure the environment reaches both scanners.
  (cd "$SECFIX" && GIT_WORK_TREE="$alt_repo" git add staged.txt)
  assert_redirected_secret "GIT_WORK_TREE=$alt_repo git commit -m x" "$alt_repo"
  secfix_physical=$(cd "$SECFIX" && pwd -P)
  grep -qF "$secfix_physical/.git" "$gl_log" \
    || fail 'gitleaks selected the redirected worktree as the Git directory'
  status=0
  (cd "$SECFIX" && hook_payload 'GIT_COMMON_DIR=/tmp/other git commit -m x' \
    | "$SECRET_GUARD") > "$TMP/unknown-git-env.out" 2>&1 || status=$?
  [ "$status" -eq 2 ] || fail 'unmodeled GIT_* environment variable was allowed'
  grep -q 'GIT_COMMON_DIR' "$TMP/unknown-git-env.out" \
    || fail 'unmodeled GIT_* diagnostic omitted variable name'
  (cd "$SECFIX" && git reset -q)

  # A first-layer failure must block even when the local patterns see ordinary code.
  printf 'const value = 1\n' > "$SECFIX/staged.txt"
  (cd "$SECFIX" && git add staged.txt)
  status=0
  (cd "$SECFIX" && hook_payload 'git commit -m x' | PATH="$gl_bin:$PATH" \
    FAKE_GITLEAKS_LOG="$gl_log" FAKE_GITLEAKS_DIFF="$gl_diff" FAKE_GITLEAKS_EXIT=1 \
    "$SECRET_GUARD") >/dev/null 2>&1 || status=$?
  [ "$status" -eq 2 ] || fail "gitleaks failure did not block with exit 2"
  (cd "$SECFIX" && git reset -q)
fi

PUSH_GUARD="$ROOT/scripts/hooks/block-push.sh"

must_block "$PUSH_GUARD" 'git push'
must_block "$PUSH_GUARD" 'git push origin main --force'
must_block "$PUSH_GUARD" 'git -C /some/path push'
must_block "$PUSH_GUARD" 'git-claude push origin HEAD'
must_block "$PUSH_GUARD" 'git status && git push'
must_block "$PUSH_GUARD" 'gh pr merge 12'
must_block "$PUSH_GUARD" 'gh -R owner/repo pr merge 12'
must_block "$PUSH_GUARD" 'sudo git push'
must_block "$PUSH_GUARD" 'sudo gh pr merge 12'
must_block "$PUSH_GUARD" 'nohup git push'
must_block "$PUSH_GUARD" 'nice git push'
must_block "$PUSH_GUARD" 'timeout 10 git push'
must_block "$PUSH_GUARD" 'time git push'
must_block "$PUSH_GUARD" '! git push'
must_block "$PUSH_GUARD" '>out git push'
must_block "$PUSH_GUARD" '2>&1 git push'
must_block "$PUSH_GUARD" 'if git push; then :; fi'
must_block "$PUSH_GUARD" '{ git push; }'
continued_push=$'git \\\npush'
[[ "$continued_push" == *$'\n'* ]] || fail 'line-continuation fixture lacks a newline'
must_block "$PUSH_GUARD" "$continued_push"
must_allow "$PUSH_GUARD" 'echo use git to push'
must_allow "$PUSH_GUARD" 'echo git push'
must_allow "$PUSH_GUARD" 'sudo echo git push'
must_allow "$PUSH_GUARD" 'man git'
must_allow "$PUSH_GUARD" 'git pull --rebase'
must_allow "$PUSH_GUARD" 'gh pr view 12'
must_allow "$PUSH_GUARD" 'echo push'
must_block "$PUSH_GUARD" 'git --no-pager push'
must_block "$PUSH_GUARD" 'git -p push'
must_block "$PUSH_GUARD" 'git --git-dir=/tmp/x push'
must_block "$PUSH_GUARD" 'git push;'
must_block "$PUSH_GUARD" 'git-opencode push origin HEAD'
must_block "$PUSH_GUARD" 'git-codex push origin HEAD'
must_block "$PUSH_GUARD" 'git status; git push'
must_block "$PUSH_GUARD" 'git -C "a path" push'
must_block "$PUSH_GUARD" 'git -C a\ path push'
must_block "$PUSH_GUARD" 'git push "unterminated'
must_block "$PUSH_GUARD" "echo \"\$(git push)\""
must_block "$PUSH_GUARD" "git -C \"\$(pwd)\" push"
must_block "$PUSH_GUARD" 'env GIT_INDEX_FILE=/tmp/other git push'
must_allow "$PUSH_GUARD" 'rg "git push" METHODOLOGY.md; echo done'
# Quoting a command in prose is not running it. `"` delimits the command inside the raw JSON
# payload, so it counts as a boundary only in the no-jq path — conflating the two blocked
# this.
must_allow "$PUSH_GUARD" 'rg "git push" METHODOLOGY.md'
must_allow "$PUSH_GUARD" 'git commit -m push'
# Verdicts must not change when jq is absent (previously: silent exit 0, guard disabled).
must_block_nojq "$PUSH_GUARD" 'git push'
must_block_nojq "$PUSH_GUARD" 'git-claude push origin HEAD'
must_block_nojq "$PUSH_GUARD" 'gh pr merge 12'
must_block_nojq "$PUSH_GUARD" 'git -C "a path" push'
must_allow_nojq "$PUSH_GUARD" 'rg "git push" METHODOLOGY.md'
must_allow_nojq "$PUSH_GUARD" 'git pull --rebase'

STEP_HOOK="$ROOT/scripts/hooks/require-step-comment.sh"
STEP_HOOK_GH="$TMP/step-hook-gh"
mkdir -p "$STEP_HOOK_GH" "$TMP/step-hook-project/scripts/lib" "$TMP/step-hook-project/docs"
git -C "$TMP/step-hook-project" init -q
cp "$ROOT/scripts/lib/review-policy.sh" "$TMP/step-hook-project/scripts/lib/review-policy.sh"
printf '%s\n' 'version=1' 'workflow=.github/workflows/ci.yml' 'identity-mode=single-operator' \
  'accepted-risk=docs/accepted_risks.md#single-operator-review' \
  'reviewer=wabkebab' 'executor=wabkebab' 'approver=wabkebab' > "$TMP/step-hook-project/.agentic-flow-review-policy"
printf '%s\n' '<a id="single-operator-review"></a>' > "$TMP/step-hook-project/docs/accepted_risks.md"
cat > "$STEP_HOOK_GH/gh" <<'FAKE_GH'
#!/usr/bin/env bash
case "$*" in
  *'--jq .body'*) printf '%s\n' '<!-- agentic-flow:topology:standard -->' ;;
  *'--jq .labels[].name'*) printf '%s\n' "${STEP_HOOK_LABELS:-needs-review}" ;;
  *'--json comments'*)
    [ "${STEP_HOOK_GH_FAIL:-0}" = 0 ] || exit 1
    if [ -n "${STEP_HOOK_COMMENTS_JSON:-}" ]; then
      jq -n --argjson comments "$STEP_HOOK_COMMENTS_JSON" '{comments:$comments}'
    else
      jq -n --arg body "${STEP_HOOK_COMMENT:-}" '{comments:[{body:$body,author:{login:"wabkebab"}}]}'
    fi ;;
  *) exit 2 ;;
esac
FAKE_GH
chmod +x "$STEP_HOOK_GH/gh"
step_hook_status() { # <command> <comment> <labels> <expected status>
  status=0
  hook_payload "$1" | PATH="$STEP_HOOK_GH:$PATH" \
    STEP_HOOK_COMMENT="$2" STEP_HOOK_LABELS="$3" bash -c 'cd "$1" && "$2"' _ "$TMP/step-hook-project" "$STEP_HOOK" \
    > "$TMP/step-hook.out" 2>&1 || status=$?
  [ "$status" -eq "$4" ] \
    || fail "step handoff hook returned $status, expected $4: $(cat "$TMP/step-hook.out")"
}
printf '%s\n' 'reviewer=review-only' >> "$TMP/step-hook-project/.agentic-flow-review-policy"
# shellcheck disable=SC2089 # JSON data parsed by jq, never executed as shell words.
STEP_HOOK_COMMENTS_JSON='[{"body":"Implemented in aaaaaaa","author":{"login":"stranger"}}]'
# shellcheck disable=SC2090 # The fake gh reads this exported value as JSON data.
export STEP_HOOK_COMMENTS_JSON
step_hook_status 'gh issue edit 1 --add-label needs-review' '' needs-execution 2
STEP_HOOK_COMMENTS_JSON='[{"body":"Implemented in aaaaaaa","author":{"login":"review-only"}}]'
step_hook_status 'gh issue edit 1 --add-label needs-review' '' needs-execution 2
STEP_HOOK_COMMENTS_JSON='[{"body":"Implemented in aaaaaaa","author":{"login":"wabkebab"}},{"body":"unrelated","author":{"login":"stranger"}}]'
step_hook_status 'gh issue edit 1 --add-label needs-review' '' needs-execution 0
unset STEP_HOOK_COMMENTS_JSON
STEP_HOOK_GH_FAIL=1; export STEP_HOOK_GH_FAIL
step_hook_status 'gh issue edit 1 --add-label needs-review' '' needs-execution 2
grep -q 'Blocked:.*comments.*issue #1' "$TMP/step-hook.out" || fail 'gh failure blocked silently'
unset STEP_HOOK_GH_FAIL
STEP_APPROVAL='agentic-flow-review: status=approved; step=alpha; head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; role=reviewer'
STEP_FINAL='agentic-flow-review: status=approved; pr=2; head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; run=https://github.com/owner/repo/actions/runs/100; attempt=1; role=reviewer'
step_hook_status 'gh issue edit 1 --add-label "agent:claude,needs-closing"' \
  'changes requested' needs-review 2
step_hook_status 'gh issue edit 1 --add-label "agent:claude,needs-closing"' \
  "$STEP_APPROVAL" needs-review 0
step_hook_status 'gh issue edit 1 --add-label "agent:claude,needs-closing"' \
  "Review approved after checking the failure path.
  $STEP_APPROVAL
Verification passed." needs-review 0
step_hook_status 'gh issue close 1' "$STEP_APPROVAL" needs-review 2
step_hook_status 'gh issue close 1' "$STEP_APPROVAL" needs-closing 2
step_hook_status 'gh issue close 1' "$STEP_FINAL" needs-closing 0
step_hook_status 'gh issue close 1' \
  "Final head and CI checked.
  $STEP_FINAL
Ready for close-out." needs-closing 0
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
if [ -n "${FAKE_GH_CALLS:-}" ]; then
  printf '%s\n' "$*" >> "$FAKE_GH_CALLS"
fi
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
    if [ -n "${FAKE_GH_LIST_OVERRIDE:-}" ]; then
      cat "$FAKE_GH_LIST_OVERRIDE"
      exit 0
    fi
    out="$state/issues.jsonl"
    : > "$out"
    for dir in "$state"/issue-*; do
      [ -d "$dir" ] || continue
      num=${dir##*-}
      jq -n --argjson number "$num" \
        --arg title "$(cat "$dir/title")" \
        --arg body "$(cat "$dir/body")" \
        --arg issue_state "$(cat "$dir/state")" \
        --arg url "https://github.com/owner/repo/issues/$num" \
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
    printf 'https://github.com/owner/repo/issues/%s\n' "$num"
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
for issue_number in 1 2 3; do
  cp "$GHSTATE/issue-$issue_number/body" "$TMP/plan-before-$issue_number.body"
  cp "$GHSTATE/issue-$issue_number/title" "$TMP/plan-before-$issue_number.title"
done
plan_apply "$PLAN_SPEC" || fail "repeated identical plan apply failed"
issue_count=$(find "$GHSTATE" -type d -name 'issue-*' | wc -l | tr -d ' ')
[ "$issue_count" -eq 3 ] || fail "repeated plan apply duplicated issues"
for issue_number in 1 2 3; do
  cmp -s "$GHSTATE/issue-$issue_number/body" "$TMP/plan-before-$issue_number.body" \
    || fail "identical reapply changed issue #$issue_number body"
  cmp -s "$GHSTATE/issue-$issue_number/title" "$TMP/plan-before-$issue_number.title" \
    || fail "identical reapply changed issue #$issue_number title"
done

# Identity validation and discovery ambiguity must stop before mutation.
plan_reject_without_mutation() { # <name> <spec> [issue-list-override]
  : > "$TMP/plan-reject-calls"
  if PATH="$GHFIX:$PATH" FAKE_GH_STATE="$GHSTATE" \
    FAKE_GH_CALLS="$TMP/plan-reject-calls" FAKE_GH_LIST_OVERRIDE="${3:-}" \
    "$PLAN_DRIVER" --apply "$2" > "$TMP/plan-reject.out" 2>&1; then
    fail "plan apply accepted $1"
  fi
  if grep -Eq '(^| )(issue create|issue edit|issue close|label create|--method POST)( |$)' \
      "$TMP/plan-reject-calls"; then
    fail "plan apply mutated GitHub before rejecting $1"
  fi
}
jq '.steps = [{title:"Implicit"},{id:"step-1",title:"Explicit"}]' \
  "$PLAN_SPEC" > "$TMP/plan-collision.json"
plan_reject_without_mutation 'implicit/explicit step-1 collision' "$TMP/plan-collision.json"
grep -q 'uniquely identified' "$TMP/plan-reject.out" \
  || fail 'normalized ID collision lacked a useful error'
jq '.steps[0].id = "bad:id"' "$PLAN_SPEC" > "$TMP/plan-reserved-id.json"
plan_reject_without_mutation 'reserved marker character in step ID' "$TMP/plan-reserved-id.json"
grep -q 'uniquely identified' "$TMP/plan-reject.out" \
  || fail 'reserved marker character lacked a validation error'

PATH="$GHFIX:$PATH" FAKE_GH_STATE="$GHSTATE" gh issue list > "$TMP/plan-existing.json"
jq '.[1] as $step | . + [$step | .number = 99 | .url = "https://github.com/owner/repo/issues/99"]' \
  "$TMP/plan-existing.json" > "$TMP/plan-duplicate-step.json"
plan_reject_without_mutation 'duplicate remote step stamps' "$PLAN_SPEC" "$TMP/plan-duplicate-step.json"
grep -qE '2.*99|99.*2' "$TMP/plan-reject.out" \
  || fail 'duplicate step diagnostic did not name both issue numbers'
jq '.[0] as $tracker | . + [$tracker | .number = 98 | .url = "https://github.com/owner/repo/issues/98"]' \
  "$TMP/plan-existing.json" > "$TMP/plan-duplicate-tracker.json"
plan_reject_without_mutation 'duplicate remote tracker stamps' "$PLAN_SPEC" "$TMP/plan-duplicate-tracker.json"
grep -qE '1.*98|98.*1' "$TMP/plan-reject.out" \
  || fail 'duplicate tracker diagnostic did not name both issue numbers'
jq '.[0].body |= sub("spec:[0-9a-f]+";"spec:zz")' \
  "$TMP/plan-existing.json" > "$TMP/plan-malformed-stamp.json"
plan_reject_without_mutation 'malformed remote stamp' "$PLAN_SPEC" "$TMP/plan-malformed-stamp.json"
grep -q 'malformed identity stamp on issue #1' "$TMP/plan-reject.out" \
  || fail 'malformed stamp diagnostic did not name the issue'
jq -n '[range(1;101) | {number:.,title:"Other",body:"unrelated",state:"OPEN",url:("https://github.com/owner/repo/issues/" + tostring)}]' \
  > "$TMP/plan-full-page.json"
plan_reject_without_mutation '100-result discovery page' "$PLAN_SPEC" "$TMP/plan-full-page.json"
grep -q '100' "$TMP/plan-reject.out" || fail 'full discovery page lacked bound diagnostic'

# step-1 must never select the earlier step-10 issue. Create step-10 first so
# the old substring lookup picks the wrong row on the second apply.
jq '.id = "prefix-plan" | .steps = [{id:"step-10",title:"Ten",body:"ten"},{id:"step-1",title:"One",body:"one"}]' \
  "$PLAN_SPEC" > "$TMP/plan-prefix.json"
PREFIX_STATE="$TMP/gh-prefix-state"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$PREFIX_STATE" \
  "$PLAN_DRIVER" --apply "$TMP/plan-prefix.json" >/dev/null \
  || fail 'prefix fixture first apply failed'
jq '.steps[1].body = "one updated"' "$TMP/plan-prefix.json" > "$TMP/plan-prefix-updated.json"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$PREFIX_STATE" \
  "$PLAN_DRIVER" --apply "$TMP/plan-prefix-updated.json" >/dev/null \
  || fail 'prefix fixture reapply failed'
grep -q 'one updated' "$PREFIX_STATE/issue-3/body" \
  || fail 'step-1 did not update its exact issue'
grep -q 'ten' "$PREFIX_STATE/issue-2/body" \
  || fail 'step-1 update rewrote step-10'

# A reviewed step's live labels must survive a spec reapply unchanged.
printf '%s\n' 'agent:opencode,needs-review' > "$GHSTATE/issue-3/labels"
: > "$TMP/plan-reapply-calls"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$GHSTATE" FAKE_GH_CALLS="$TMP/plan-reapply-calls" \
  "$PLAN_DRIVER" --apply "$PLAN_SPEC" >/dev/null \
  || fail 'reviewer-state reapply failed'
if grep -Eq 'issue edit 3 .*--add-label' "$TMP/plan-reapply-calls"; then
  fail 'reapply reintroduced spec labels on a reviewed step'
fi
[ "$(cat "$GHSTATE/issue-3/labels")" = 'agent:opencode,needs-review' ] \
  || fail 'reapply changed live reviewer labels'

APPROVAL_DOC_ROOT="$TMP/approval-doc-root"
mkdir -p "$APPROVAL_DOC_ROOT/docs/inprogress"
APPROVAL_DOC="$APPROVAL_DOC_ROOT/docs/inprogress/feature-approval.md"
cat > "$APPROVAL_DOC" <<'MD'
## Tracker
- [x] F-1 done
## Status / Implementation status
- **Evidence schema:** v2
- **Tracking issue:** pending
- **Approval:** pending
- **Implementation head:** source=pr-head
- **Implementation PR:** url=https://github.com/owner/repo/pull/2
- **Verification evidence:** source=final-approval-run
- **Review verdict:** source=pr-head-approval
- **Memory:** status=n/a
MD
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$GHSTATE" \
  "$PLAN_DRIVER" --apply --approved-by "Test User" --doc "$APPROVAL_DOC" "$PLAN_SPEC" >/dev/null \
  || fail "plan apply with --approved-by failed against fake GitHub"
tracker_body=$(grep -Rl "agentic-flow:plan:self-test-plan tracker" "$GHSTATE"/issue-*/body | xargs cat)
printf '%s\n' "$tracker_body" | grep -q 'approved-by:Test User approved-at:' \
  || fail "approval stamp did not land in the existing tracker marker"
approved_at=$(printf '%s\n' "$tracker_body" | sed -n 's/.*approved-at:\([^ ]*\) -->.*/\1/p' | head -1)
[ -n "$approved_at" ] || fail "approval stamp did not include approved-at"
grep -qF -- "- **Approval:** status=approved; by=Test User; at=${approved_at%%T*}" "$APPROVAL_DOC" \
  || fail "--doc did not write the canonical Approval status line"
grep -qF -- '- **Tracking issue:** url=https://github.com/owner/repo/issues/1' "$APPROVAL_DOC" \
  || fail "--doc did not write the v2 tracking URL"
AGENTIC_PROJECT_ROOT="$APPROVAL_DOC_ROOT" "$ROOT/scripts/lifecycle-status.sh" --check >/dev/null \
  || fail "lifecycle-status did not recognize the machine-written Approval line"

# Writer validation precedes authentication. Each rejected case must leave the
# mock gh call log empty, rather than merely avoid an issue mutation.
REJECT_DOC="$TMP/rejected-plan-doc.md"
reject_before_gh() { # <case-name> <doc-path> <approved-by>
  rm -f "$TMP/rejected-gh-calls"
  PATH="$GHFIX:$PATH" FAKE_GH_STATE="$GHSTATE" FAKE_GH_CALLS="$TMP/rejected-gh-calls" \
    "$PLAN_DRIVER" --apply --doc "$2" --approved-by "$3" "$PLAN_SPEC" \
    > "$TMP/rejected-plan.out" 2>&1 \
    && fail "plan apply accepted $1"
  [ ! -e "$TMP/rejected-gh-calls" ] \
    || fail "plan apply called gh before rejecting $1"
}
sed 's/Evidence schema:\*\* v2/Evidence schema:** v3/' "$APPROVAL_DOC" > "$REJECT_DOC"
reject_before_gh 'unknown schema' "$REJECT_DOC" 'Test User'
sed '/^- \*\*Evidence schema:/d' "$APPROVAL_DOC" > "$REJECT_DOC"
reject_before_gh 'legacy document' "$REJECT_DOC" 'Test User'
sed 's/source=pr-head-approval/source=not-approved/' "$APPROVAL_DOC" > "$REJECT_DOC"
reject_before_gh 'invalid v2 selector' "$REJECT_DOC" 'Test User'
cp "$APPROVAL_DOC" "$REJECT_DOC"
printf '%s\n' '- **Approval:** status=approved; by=Other; at=2026-01-01' >> "$REJECT_DOC"
reject_before_gh 'duplicate v2 field' "$REJECT_DOC" 'Test User'
reject_before_gh 'missing document' "$TMP/no-such-doc.md" 'Test User'
cp "$APPROVAL_DOC" "$REJECT_DOC"
chmod 444 "$REJECT_DOC"
reject_before_gh 'unwritable document' "$REJECT_DOC" 'Test User'
chmod 644 "$REJECT_DOC"
reject_before_gh 'newline in approver' "$REJECT_DOC" "$(printf 'Test\nUser')"
reject_before_gh 'semicolon in approver' "$REJECT_DOC" 'Test;User'
reject_before_gh 'surrounding whitespace in approver' "$REJECT_DOC" ' Test User '
reject_before_gh 'trailing dot in approver' "$REJECT_DOC" 'John D.'
reject_before_gh 'trailing hyphen in approver' "$REJECT_DOC" 'user-'

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

# Standard creates one work issue. Its packet and approval metadata stay on
# that issue across reapply, and a topology change fails before mutation.
STANDARD_SPEC="$TMP/standard-spec.json"
jq '{profile:"standard",id:"standard-plan",steps:[.steps[0] | .packet = {
  brief:"docs/inprogress/feature.md Step 1",
  definition_of_done:"Failure path and success path pass",
  verification:"make check and make test-one F=plan-to-issues",
  risks:"Malformed input must fail before a GitHub write"
}]}' "$PLAN_SPEC" > "$STANDARD_SPEC"
if [ -n "${AGENTIC_MEASURE_EVENTS:-}" ]; then
  packet_words=$(jq -r '.steps[0].packet |
    "## Executor packet\nProfile: Standard\nBrief: \(.brief)\nDefinition of Done: \(.definition_of_done)\nVerification: \(.verification)\nRisks and edge cases: \(.risks)"' \
    "$STANDARD_SPEC" | wc -w | tr -d ' ')
  measure_event "packet_words:$packet_words"
fi
STANDARD_STATE="$TMP/gh-standard-state"
if PATH="$GHFIX:$PATH" FAKE_GH_STATE="$STANDARD_STATE" \
  "$PLAN_DRIVER" --apply "$STANDARD_SPEC" > "$TMP/standard-unapproved.out" 2>&1; then
  fail 'Standard created an issue without plan approval metadata'
fi
grep -q 'requires --approved-by' "$TMP/standard-unapproved.out" \
  || fail 'Standard missing approval lacked diagnostic'
[ ! -d "$STANDARD_STATE/issue-1" ] || fail 'Standard wrote an unapproved work issue'
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$STANDARD_STATE" \
  "$PLAN_DRIVER" --apply --approved-by "Test User" "$STANDARD_SPEC" >/dev/null \
  || fail 'Standard apply failed'
[ "$(find "$STANDARD_STATE" -type d -name 'issue-*' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail 'Standard created a parent or more than one work issue'
grep -q 'agentic-flow:topology:standard' "$STANDARD_STATE/issue-1/body" \
  || fail 'Standard work issue lacks topology stamp'
grep -q 'approved-by:Test User' "$STANDARD_STATE/issue-1/body" \
  || fail 'Standard approval metadata was not recorded on work issue'
grep -q '## Executor packet' "$STANDARD_STATE/issue-1/body" \
  || fail 'Standard work issue lacks executor packet'
STANDARD_DOC="$TMP/standard-doc.md"
cp "$APPROVAL_DOC" "$STANDARD_DOC"
sed 's@url=https://github.com/owner/repo/issues/1@pending@; s/status=approved; by=Test User; at=[0-9-]*/pending/' \
  "$STANDARD_DOC" > "$TMP/standard-doc-pending.md"
mv "$TMP/standard-doc-pending.md" "$STANDARD_DOC"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$STANDARD_STATE" \
  "$PLAN_DRIVER" --apply --doc "$STANDARD_DOC" "$STANDARD_SPEC" >/dev/null \
  || fail 'Standard apply could not write the work issue URL and approval to the document'
grep -qF -- '- **Tracking issue:** url=https://github.com/owner/repo/issues/1' "$STANDARD_DOC" \
  || fail 'Standard document did not receive the work issue URL'
grep -qF -- '- **Approval:** status=approved; by=Test User;' "$STANDARD_DOC" \
  || fail 'Standard document did not receive approval evidence'
cp "$STANDARD_STATE/issue-1/body" "$TMP/standard-before.body"
: > "$TMP/standard-reapply-calls"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$STANDARD_STATE" FAKE_GH_CALLS="$TMP/standard-reapply-calls" \
  "$PLAN_DRIVER" --apply "$STANDARD_SPEC" >/dev/null \
  || fail 'Standard reapply failed'
cmp -s "$STANDARD_STATE/issue-1/body" "$TMP/standard-before.body" \
  || fail 'Standard reapply changed work issue metadata'
if grep -Eq 'issue edit 1 .*--add-label' "$TMP/standard-reapply-calls"; then
  fail 'Standard reapply reset live work issue labels'
fi

standard_reject() { # <name> <spec>
  : > "$TMP/standard-reject-calls"
  if PATH="$GHFIX:$PATH" FAKE_GH_STATE="$STANDARD_STATE" \
    FAKE_GH_CALLS="$TMP/standard-reject-calls" \
    "$PLAN_DRIVER" --apply "$2" > "$TMP/standard-reject.out" 2>&1; then
    fail "Standard accepted $1"
  fi
  if grep -Eq '(^| )(issue create|issue edit|issue close|label create)( |$)' \
      "$TMP/standard-reject-calls"; then
    fail "Standard mutated GitHub before rejecting $1"
  fi
}
jq '.steps = []' "$STANDARD_SPEC" > "$TMP/standard-zero.json"
standard_reject 'zero steps' "$TMP/standard-zero.json"
jq '.steps += [.steps[0] | .id="second"]' "$STANDARD_SPEC" > "$TMP/standard-two.json"
standard_reject 'two steps' "$TMP/standard-two.json"
jq '.profile="strict"' "$STANDARD_SPEC" > "$TMP/strict-no-parent.json"
standard_reject 'Strict without parent specification' "$TMP/strict-no-parent.json"
jq '.profile="strict" | .tracking={title:"Plan: standard-plan"}' \
  "$STANDARD_SPEC" > "$TMP/topology-change.json"
standard_reject 'topology-changing reapply' "$TMP/topology-change.json"
grep -q 'migration' "$TMP/standard-reject.out" \
  || fail 'topology change lacked migration diagnostic'
jq '.steps[0].packet.brief = ([range(0;801) | "word"] | join(" "))' \
  "$STANDARD_SPEC" > "$TMP/packet-overflow.json"
standard_reject 'packet overflow' "$TMP/packet-overflow.json"
grep -q '800 words' "$TMP/standard-reject.out" \
  || fail 'packet overflow lacked bound diagnostic'

ASSURANCE_FIX="$TMP/assurance-fixture"
mkdir -p "$ASSURANCE_FIX/scripts"
cp "$ROOT/scripts/plan-to-issues.sh" "$ROOT/scripts/assurance.sh" "$ASSURANCE_FIX/scripts/"
printf 'strict\n' > "$ASSURANCE_FIX/.agentic-flow-assurance"
if PATH="$GHFIX:$PATH" FAKE_GH_STATE="$STANDARD_STATE" \
  "$ASSURANCE_FIX/scripts/plan-to-issues.sh" --apply "$STANDARD_SPEC" \
  > "$TMP/standard-downgrade.out" 2>&1; then
  fail 'Standard accepted a downgrade below the project baseline'
fi
grep -q 'downgrade' "$TMP/standard-downgrade.out" \
  || fail 'Standard downgrade lacked diagnostic'

STRICT_SPEC="$TMP/strict-spec.json"
jq '.profile="strict" | .id="strict-plan" |
  .steps |= map(.packet={brief:"approved brief step",definition_of_done:"reviewed behavior",
    verification:"make check",risks:"failure path"})' "$PLAN_SPEC" > "$STRICT_SPEC"
STRICT_STATE="$TMP/gh-strict-state"
PATH="$GHFIX:$PATH" FAKE_GH_STATE="$STRICT_STATE" \
  "$PLAN_DRIVER" --apply "$STRICT_SPEC" >/dev/null \
  || fail 'Strict apply failed'
[ "$(find "$STRICT_STATE" -type d -name 'issue-*' | wc -l | tr -d ' ')" -eq 3 ] \
  || fail 'Strict did not create one tracker and two sub-issues'
grep -q 'agentic-flow:topology:strict' "$STRICT_STATE/issue-1/body" \
  || fail 'Strict parent lacks topology stamp'
grep -q '## Executor packet' "$STRICT_STATE/issue-2/body" \
  || fail 'Strict step lacks executor packet'
fi

# --- lifecycle qualification -------------------------------------------------------------
if should_run lifecycle; then
V2FIX="$TMP/lifecycle-v2"
mkdir -p "$V2FIX/docs/inprogress"
cat > "$V2FIX/docs/inprogress/feature-v2.md" <<'MD'
## Tracker
- [x] F-1 done
## Status / Implementation status
- **Evidence schema:** v2
- **Tracking issue:** url=https://github.com/owner/repo/issues/1
- **Approval:** status=not approved; by=Tester; at=2026-01-01
- **Implementation head:** source=pr-head
- **Implementation PR:** url=https://github.com/owner/repo/pull/2
- **Verification evidence:** source=final-approval-run
- **Review verdict:** source=pr-head-approval
- **Memory:** status=n/a
MD
AGENTIC_PROJECT_ROOT="$V2FIX" "$ROOT/scripts/lifecycle-status.sh" --doc "$V2FIX/docs/inprogress/feature-v2.md" --check \
  > "$TMP/lifecycle-v2-red.out" 2>&1 \
  && fail "v2 lifecycle accepted a negated approval"
grep -q 'BLOCKED.*approval' "$TMP/lifecycle-v2-red.out" \
  || fail "v2 lifecycle did not classify a negated approval as BLOCKED"

# Open work has precedence over any evidence schema, including legacy work.
cat > "$V2FIX/docs/inprogress/feature-active.md" <<'MD'
## Tracker
- [x] F-1 done
- [ ] F-2 open
## Status
- **Approval:** not approved
MD
AGENTIC_PROJECT_ROOT="$V2FIX" "$ROOT/scripts/lifecycle-status.sh" --doc \
  "$V2FIX/docs/inprogress/feature-active.md" --check --verify-evidence \
  > "$TMP/lifecycle-active.out" \
  || fail "open legacy document failed strict verification"
grep -q '^ACTIVE.*feature-active.md' "$TMP/lifecycle-active.out" \
  || fail "open legacy document was not ACTIVE"

sed 's/status=not approved/status=approved/' "$V2FIX/docs/inprogress/feature-v2.md" \
  > "$TMP/valid-v2.md"
cp "$TMP/valid-v2.md" "$V2FIX/docs/inprogress/feature-v2.md"
AGENTIC_PROJECT_ROOT="$V2FIX" "$ROOT/scripts/lifecycle-status.sh" --doc \
  "$V2FIX/docs/inprogress/feature-v2.md" --check > "$TMP/lifecycle-valid.out" \
  || fail "valid local v2 Status failed report validation"
grep -q '^READY.*feature-v2.md' "$TMP/lifecycle-valid.out" \
  || fail "valid local v2 Status was not READY in offline report"

v2_case() { # <sed expression> <expected state> <diagnostic>
  sed "$1" "$TMP/valid-v2.md" > "$V2FIX/docs/inprogress/feature-v2.md"
  if AGENTIC_PROJECT_ROOT="$V2FIX" "$ROOT/scripts/lifecycle-status.sh" --doc \
      "$V2FIX/docs/inprogress/feature-v2.md" --check --verify-evidence \
      > "$TMP/lifecycle-case.out" 2>&1; then
    fail "strict verified lifecycle accepted $3"
  fi
  grep -q "^$2.*$3" "$TMP/lifecycle-case.out" \
    || fail "lifecycle did not classify $3 as $2"
}
v2_case 's/status=approved/status=not approved/' BLOCKED approval
v2_case 's/source=pr-head/source=not-pr-head/' BLOCKED implementation-head
v2_case '/^- \*\*Approval:/d' UNVERIFIED approval
v2_case 's/Evidence schema:\*\* v2/Evidence schema:** v3/' BLOCKED 'Evidence schema'
v2_case 's/Review verdict:/Unknown key:/' BLOCKED 'unknown field'
sed '/^- \*\*Approval:/a\
  not approved' "$TMP/valid-v2.md" > "$V2FIX/docs/inprogress/feature-v2.md"
AGENTIC_PROJECT_ROOT="$V2FIX" "$ROOT/scripts/lifecycle-status.sh" --doc \
  "$V2FIX/docs/inprogress/feature-v2.md" --check > "$TMP/lifecycle-wrapped.out" 2>&1 \
  && fail "v2 lifecycle accepted continuation prose after approval"
grep -q 'BLOCKED.*malformed continuation of Approval' "$TMP/lifecycle-wrapped.out" \
  || fail "v2 lifecycle did not name the malformed Approval continuation"
cat "$TMP/valid-v2.md" > "$V2FIX/docs/inprogress/feature-v2.md"
printf '%s\n' '- **Approval:** status=approved; by=Other; at=2026-01-01' \
  >> "$V2FIX/docs/inprogress/feature-v2.md"
AGENTIC_PROJECT_ROOT="$V2FIX" "$ROOT/scripts/lifecycle-status.sh" --doc \
  "$V2FIX/docs/inprogress/feature-v2.md" --check > "$TMP/lifecycle-duplicate.out" 2>&1 \
  && fail "duplicate v2 field passed"
grep -q 'BLOCKED.*duplicate field Approval' "$TMP/lifecycle-duplicate.out" \
  || fail "duplicate v2 field did not report its name"
cp "$TMP/valid-v2.md" "$V2FIX/docs/inprogress/feature-v2.md"
AGENTIC_PROJECT_ROOT="$V2FIX" "$ROOT/scripts/lifecycle-status.sh" --doc \
  "$V2FIX/docs/inprogress/feature-v2.md" --check --verify-evidence \
  > "$TMP/lifecycle-unresolved.out" 2>&1 \
  && fail "strict verification accepted unresolved v2 evidence"
grep -q '^UNVERIFIED.*feature-v2.md' "$TMP/lifecycle-unresolved.out" \
  || fail "unresolved v2 evidence was not UNVERIFIED"

# A fully checked schema-less document is a migration report, never evidence-ready.
cat > "$V2FIX/docs/inprogress/feature-legacy.md" <<'MD'
## Tracker
- [x] F-1 done
## Status
- **Approval:** approved by Tester
MD
AGENTIC_PROJECT_ROOT="$V2FIX" "$ROOT/scripts/lifecycle-status.sh" --doc \
  "$V2FIX/docs/inprogress/feature-legacy.md" --check --verify-evidence \
  > "$TMP/lifecycle-legacy.out" 2>&1 \
  && fail "strict verification accepted fully checked legacy document"
grep -q '^LEGACY.*feature-legacy.md' "$TMP/lifecycle-legacy.out" \
  || fail "fully checked schema-less document was not LEGACY"

# Phase mismatch is a resolved contradiction, even while later CI/review evidence
# remains unavailable until F-2/F-3.
GH_PHASE="$TMP/gh-phase"
mkdir -p "$GH_PHASE"
cat > "$GH_PHASE/gh" <<'FAKE_GH'
#!/usr/bin/env bash
case "$*" in
  *'issue view'*)
    labels='[{"name":"agent:claude"},{"name":"needs-closing"}]'
    [ -z "${FAKE_ISSUE_LABELS:-}" ] || labels=$FAKE_ISSUE_LABELS
    printf '{"state":"%s","labels":%s}\n' "${FAKE_ISSUE_STATE:-OPEN}" "$labels" ;;
  *) exit 2 ;;
esac
FAKE_GH
chmod +x "$GH_PHASE/gh"
PATH="$GH_PHASE:$PATH" FAKE_ISSUE_STATE=OPEN AGENTIC_PROJECT_ROOT="$V2FIX" \
  "$ROOT/scripts/lifecycle-status.sh" --doc "$V2FIX/docs/inprogress/feature-v2.md" \
  --phase pre-merge --check --verify-evidence > "$TMP/lifecycle-wrong-pre.out" 2>&1 \
  && fail "pre-merge accepted an open issue"
grep -q 'BLOCKED.*phase pre-merge found OPEN' "$TMP/lifecycle-wrong-pre.out" \
  || fail "pre-merge mismatch did not name the phase and state"
PATH="$GH_PHASE:$PATH" FAKE_ISSUE_STATE=CLOSED AGENTIC_PROJECT_ROOT="$V2FIX" \
  "$ROOT/scripts/lifecycle-status.sh" --doc "$V2FIX/docs/inprogress/feature-v2.md" \
  --phase close-out --check --verify-evidence > "$TMP/lifecycle-wrong-close.out" 2>&1 \
  && fail "close-out accepted a closed issue"
grep -q 'BLOCKED.*phase close-out found CLOSED' "$TMP/lifecycle-wrong-close.out" \
  || fail "close-out mismatch did not name the phase and state"
for missing_label in needs-closing agent:claude; do
  case "$missing_label" in
    needs-closing) labels='[{"name":"agent:claude"}]' ;;
    agent:claude) labels='[{"name":"needs-closing"}]' ;;
  esac
  PATH="$GH_PHASE:$PATH" FAKE_ISSUE_STATE=OPEN FAKE_ISSUE_LABELS="$labels" \
    AGENTIC_PROJECT_ROOT="$V2FIX" "$ROOT/scripts/lifecycle-status.sh" \
    --doc "$V2FIX/docs/inprogress/feature-v2.md" --phase close-out \
    --check --verify-evidence > "$TMP/lifecycle-missing-label.out" 2>&1 \
    && fail "close-out accepted an open issue without $missing_label"
  grep -q "BLOCKED.*phase close-out found OPEN without $missing_label" \
    "$TMP/lifecycle-missing-label.out" \
    || fail "close-out did not name missing $missing_label label"
done
for phase_state in 'close-out OPEN' 'pre-merge CLOSED'; do
  read -r phase_name state_name <<< "$phase_state"
  PATH="$GH_PHASE:$PATH" FAKE_ISSUE_STATE="$state_name" AGENTIC_PROJECT_ROOT="$V2FIX" \
    "$ROOT/scripts/lifecycle-status.sh" --doc "$V2FIX/docs/inprogress/feature-v2.md" \
    --phase "$phase_name" --check --verify-evidence > "$TMP/lifecycle-phase.out" 2>&1 \
    && fail "$phase_name accepted unresolved review and CI"
  grep -q '^UNVERIFIED.*review policy missing or invalid' "$TMP/lifecycle-phase.out" \
    || fail "$phase_name did not reach the shared external evidence check"
done

# F-2 reads policy from the adopted project, the PR head from GitHub, and one
# complete comment page from the tracking issue. Each selected run gets exactly
# one Actions lookup, including attempt mismatch and failure cases.
printf '%s\n' 'version=1' 'workflow=.github/workflows/ci.yml' \
  'identity-mode=single-operator' \
  'reviewer=reviewer' 'executor=executor' 'approver=approver' \
  'accepted-risk=docs/accepted_risks.md#single-operator-review' \
  > "$V2FIX/.agentic-flow-review-policy"
mkdir -p "$V2FIX/docs"
printf '%s\n' '<a id="single-operator-review"></a>' > "$V2FIX/docs/accepted_risks.md"
git -C "$V2FIX" init -q
git -C "$V2FIX" remote add origin git@github.com:owner/repo.git
git -C "$V2FIX" -c commit.gpgsign=false -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m base
STEP_HEAD=$(git -C "$V2FIX" rev-parse HEAD)
git -C "$V2FIX" -c commit.gpgsign=false -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m head
LIFE_HEAD=$(git -C "$V2FIX" rev-parse HEAD)
LIFE_RUN_URL=https://github.com/owner/repo/actions/runs/100
LIFE_MARKER="agentic-flow-review: status=approved; pr=2; head=$LIFE_HEAD; run=$LIFE_RUN_URL; attempt=1; role=reviewer"
LIFE_API="$TMP/lifecycle-api"
mkdir -p "$LIFE_API"
cat > "$LIFE_API/gh" <<'FAKE_GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LIFE_CALLS"
case "$*" in
  *'issue view'*)
    if [ -n "${LIFE_ISSUE_BODY_FILE:-}" ]; then
      jq -n --arg state "${LIFE_ISSUE_STATE:-OPEN}" --rawfile body "$LIFE_ISSUE_BODY_FILE" \
        '{state:$state,labels:[{name:"agent:claude"},{name:"needs-closing"}],body:$body}'
    else
      printf '{"state":"%s","labels":[{"name":"agent:claude"},{"name":"needs-closing"}],"body":"<!-- agentic-flow:plan:fixture tracker spec:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->"}\n' "${LIFE_ISSUE_STATE:-OPEN}"
    fi ;;
  *'issue list'*) printf '[{"number":3,"state":"%s","body":"<!-- agentic-flow:plan:fixture step:f-1 spec:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->"}]\n' "${LIFE_STEP_STATE:-CLOSED}" ;;
  *'api repos/owner/repo/pulls/2'*) cat "$LIFE_PR_JSON" ;;
  *'api graphql '*'number=1'*) cat "$LIFE_COMMENTS_JSON" ;;
  *'api graphql '*'number=2'*) cat "$LIFE_PR_COMMENTS_JSON" ;;
  *'api graphql '*'number=3'*) cat "$LIFE_STEP_COMMENTS_JSON" ;;
  *'api repos/owner/repo/actions/runs/100'*)
    [ "${LIFE_RUN_FAIL:-false}" = false ] || exit 1
    cat "$LIFE_RUN_JSON" ;;
  *) exit 2 ;;
esac
FAKE_GH
chmod +x "$LIFE_API/gh"
printf '{"head":{"sha":"%s"}}\n' "$LIFE_HEAD" > "$TMP/lifecycle-pr.json"
printf '{"repository":{"full_name":"owner/repo"},"path":".github/workflows/ci.yml","head_sha":"%s","conclusion":"success","run_attempt":1}\n' \
  "$LIFE_HEAD" > "$TMP/lifecycle-run.json"
jq -n --arg body "$LIFE_MARKER" '{data:{repository:{issue:{comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:"opaque-1",fullDatabaseId:"10",body:$body,author:{login:"reviewer"},lastEditedAt:null}]}}}}}' \
  > "$TMP/lifecycle-comments.json"
jq -n --arg head "$LIFE_HEAD" \
  '{data:{repository:{issue:{comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:"handoff",fullDatabaseId:"10",body:("Implemented in " + $head + " — implementation"),author:{login:"executor"},lastEditedAt:null},{id:"step-review",fullDatabaseId:"11",body:("agentic-flow-review: status=approved; step=f-1; head=" + $head + "; role=reviewer"),author:{login:"reviewer"},lastEditedAt:null}]}}}}}' \
  > "$TMP/lifecycle-step-comments.json"
LIFE_PR_JSON="$TMP/lifecycle-pr.json"
LIFE_RUN_JSON="$TMP/lifecycle-run.json"
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"
LIFE_PR_COMMENTS_JSON="$TMP/lifecycle-comments.json"
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"
LIFE_CALLS="$TMP/lifecycle-calls"
export LIFE_PR_JSON LIFE_RUN_JSON LIFE_COMMENTS_JSON LIFE_PR_COMMENTS_JSON \
  LIFE_STEP_COMMENTS_JSON LIFE_CALLS
bound_case() { # <name> <expected state> <diagnostic> <expected run calls>
  : > "$LIFE_CALLS"
  PATH="$LIFE_API:$PATH" AGENTIC_PROJECT_ROOT="$V2FIX" LIFE_RUN_FAIL="${LIFE_RUN_FAIL:-false}" \
    "$ROOT/scripts/lifecycle-status.sh" --doc "$V2FIX/docs/inprogress/feature-v2.md" \
    --check --verify-evidence > "$TMP/lifecycle-bound.out" 2>&1 \
    && [ "$2" != READY ] && fail "strict verified lifecycle accepted $1"
  grep -q "^$2.*$3" "$TMP/lifecycle-bound.out" \
    || fail "$1 was not $2 with $3: $(cat "$TMP/lifecycle-bound.out")"
  [ "$(grep -c 'api repos/owner/repo/actions/runs/100' "$LIFE_CALLS" || true)" -eq "$4" ] \
    || fail "$1 made the wrong number of Actions lookups"
  [ "$(grep -c 'api graphql .*number=1' "$LIFE_CALLS" || true)" -eq 1 ] \
    || fail "$1 did not make exactly one tracking-thread query"
  if [ "$2" = READY ]; then
    [ "$(grep -c 'api graphql ' "$LIFE_CALLS" || true)" -eq 2 ] \
      || fail "$1 did not query exactly one Strict step thread"
  else
    [ "$(grep -c 'api graphql ' "$LIFE_CALLS" || true)" -eq 1 ] \
      || fail "$1 queried another review thread before selecting evidence"
  fi
}
bound_case 'authenticated correct binding' READY 'review by reviewer' 1
grep -q "$LIFE_HEAD.*comment opaque-1" "$TMP/lifecycle-bound.out" \
  || fail 'bound CI output omitted the resolved head or selected comment'
grep -q 'attempt 1 succeeded' "$TMP/lifecycle-bound.out" || fail 'run attempt not printed'

# Standard uses one open work issue for both the step and final review. The
# same complete comment page must support close-out and the post-close recheck.
STANDARD_LIFE_DOC="$V2FIX/docs/inprogress/feature-standard.md"
cp "$TMP/valid-v2.md" "$STANDARD_LIFE_DOC"
printf '%s\n' \
  '<!-- agentic-flow:plan:standard-plan step:alpha spec:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa approved-by:Tester approved-at:2026-01-01T00:00:00Z -->' \
  '<!-- agentic-flow:topology:standard -->' > "$TMP/standard-life-body"
jq -n --arg head "$LIFE_HEAD" --arg step "$STEP_HEAD" --arg run "$LIFE_RUN_URL" \
  '{data:{repository:{issue:{comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[
    {id:"handoff",fullDatabaseId:"9",body:("Implemented in " + $step + " — implementation"),author:{login:"executor"},lastEditedAt:null},
    {id:"step-review",fullDatabaseId:"10",body:("agentic-flow-review: status=approved; step=alpha; head=" + $step + "; role=reviewer"),author:{login:"reviewer"},lastEditedAt:null},
    {id:"final-review",fullDatabaseId:"11",body:("agentic-flow-review: status=approved; pr=2; head=" + $head + "; run=" + $run + "; attempt=1; role=reviewer"),author:{login:"reviewer"},lastEditedAt:null}
  ]}}}}}' > "$TMP/standard-life-comments.json"
LIFE_ISSUE_BODY_FILE="$TMP/standard-life-body"
LIFE_COMMENTS_JSON="$TMP/standard-life-comments.json"
export LIFE_ISSUE_BODY_FILE LIFE_COMMENTS_JSON
for phase_state in 'close-out OPEN' 'pre-merge CLOSED'; do
  read -r phase_name state_name <<< "$phase_state"
  : > "$LIFE_CALLS"
  PATH="$LIFE_API:$PATH" AGENTIC_PROJECT_ROOT="$V2FIX" LIFE_ISSUE_STATE="$state_name" \
    "$ROOT/scripts/lifecycle-status.sh" --doc "$STANDARD_LIFE_DOC" \
    --phase "$phase_name" --check --verify-evidence > "$TMP/standard-life.out" 2>&1 \
    || fail "Standard $phase_name failed: $(cat "$TMP/standard-life.out")"
  grep -q '^READY' "$TMP/standard-life.out" || fail "Standard $phase_name was not READY"
  [ "$(grep -c 'api graphql ' "$LIFE_CALLS" || true)" -eq 1 ] \
    || fail 'Standard queried more than its one review thread'
done
# Standard's reused tracking page must also reject an approved alternate commit.
STANDARD_ALT=$(printf '%s\n' standard-alternate | git -C "$V2FIX" -c commit.gpgsign=false -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree "${LIFE_HEAD}^{tree}" -p "$STEP_HEAD")
jq --arg old "$STEP_HEAD" --arg new "$STANDARD_ALT" '.data.repository.issue.comments.nodes |= map(.body |= gsub($old; $new))' \
  "$TMP/standard-life-comments.json" > "$TMP/standard-life-alternate.json"
PATH="$LIFE_API:$PATH" AGENTIC_PROJECT_ROOT="$V2FIX" LIFE_COMMENTS_JSON="$TMP/standard-life-alternate.json" \
  "$ROOT/scripts/lifecycle-status.sh" --doc "$STANDARD_LIFE_DOC" --check --verify-evidence \
  > "$TMP/standard-life-alternate.out" 2>&1 && fail 'Standard accepted an approved alternate commit'
grep -q "^BLOCKED.*$STANDARD_ALT.*$LIFE_HEAD" "$TMP/standard-life-alternate.out" \
  || fail 'Standard ancestry rejection lacked both SHAs'
sed 's/approved-by:Tester/approved-by:Other/' "$TMP/standard-life-body" \
  > "$TMP/standard-life-bad-body"
LIFE_ISSUE_BODY_FILE="$TMP/standard-life-bad-body" \
  PATH="$LIFE_API:$PATH" AGENTIC_PROJECT_ROOT="$V2FIX" \
  "$ROOT/scripts/lifecycle-status.sh" --doc "$STANDARD_LIFE_DOC" \
  --check --verify-evidence > "$TMP/standard-life-bad.out" 2>&1 \
  && fail 'Standard accepted mismatched approval metadata'
grep -q 'BLOCKED.*approval stamp differs' "$TMP/standard-life-bad.out" \
  || fail 'Standard approval mismatch lacked diagnostic'
LIFE_ISSUE_BODY_FILE="$TMP/standard-life-body"
jq '.data.repository.issue.comments.nodes |= map(select(.id != "step-review"))' \
  "$TMP/standard-life-comments.json" > "$TMP/standard-life-no-step.json"
LIFE_COMMENTS_JSON="$TMP/standard-life-no-step.json"
export LIFE_COMMENTS_JSON
PATH="$LIFE_API:$PATH" AGENTIC_PROJECT_ROOT="$V2FIX" \
  "$ROOT/scripts/lifecycle-status.sh" --doc "$STANDARD_LIFE_DOC" \
  --check --verify-evidence > "$TMP/standard-life-no-step.out" 2>&1 \
  && fail 'Standard accepted missing step review'
grep -q 'UNVERIFIED.*no review' "$TMP/standard-life-no-step.out" \
  || fail 'Standard missing review lacked diagnostic'
jq '.data.repository.issue.comments.nodes[-1].body |= sub("head=[a-f0-9]{40}";"head=cccccccccccccccccccccccccccccccccccccccc")' \
  "$TMP/standard-life-comments.json" > "$TMP/standard-life-stale.json"
LIFE_COMMENTS_JSON="$TMP/standard-life-stale.json"
export LIFE_COMMENTS_JSON
PATH="$LIFE_API:$PATH" AGENTIC_PROJECT_ROOT="$V2FIX" \
  "$ROOT/scripts/lifecycle-status.sh" --doc "$STANDARD_LIFE_DOC" \
  --check --verify-evidence > "$TMP/standard-life-stale.out" 2>&1 \
  && fail 'Standard accepted stale final-head approval'
grep -q 'UNVERIFIED.*no approval for PR head' "$TMP/standard-life-stale.out" \
  || fail 'Standard stale final-head evidence lacked diagnostic'
LIFE_COMMENTS_JSON="$TMP/standard-life-comments.json"
unset LIFE_ISSUE_BODY_FILE
export LIFE_COMMENTS_JSON

jq '.path = ".github/workflows/ci.yml@main"' "$TMP/lifecycle-run.json" > "$TMP/lifecycle-run-ref.json"
LIFE_RUN_JSON="$TMP/lifecycle-run-ref.json"; export LIFE_RUN_JSON
bound_case 'workflow path with GitHub ref suffix' READY 'review by reviewer' 1
LIFE_RUN_JSON="$TMP/lifecycle-run.json"; export LIFE_RUN_JSON

jq '.repository.full_name = "other/repo"' "$TMP/lifecycle-run.json" > "$TMP/lifecycle-run-case.json"
LIFE_RUN_JSON="$TMP/lifecycle-run-case.json"; export LIFE_RUN_JSON
bound_case 'wrong repository' BLOCKED 'differs from repository' 1
jq '.path = ".github/workflows/other.yml"' "$TMP/lifecycle-run.json" > "$TMP/lifecycle-run-case.json"
bound_case 'wrong workflow' BLOCKED 'differs from repository' 1
jq '.head_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$TMP/lifecycle-run.json" > "$TMP/lifecycle-run-case.json"
bound_case 'copied successful run' BLOCKED 'differs from repository' 1
jq '.conclusion = "failure"' "$TMP/lifecycle-run.json" > "$TMP/lifecycle-run-case.json"
bound_case 'failed run' BLOCKED 'concluded failure' 1
jq '.run_attempt = 2 | .conclusion = "failure"' "$TMP/lifecycle-run.json" > "$TMP/lifecycle-run-case.json"
bound_case 'rerun changed conclusion' BLOCKED 'attempt 2 differs' 1
jq '.run_attempt = 2' "$TMP/lifecycle-run.json" > "$TMP/lifecycle-run-case.json"
bound_case 'live attempt advanced' BLOCKED 'attempt 2 differs' 1
LIFE_RUN_JSON="$TMP/lifecycle-run.json"; export LIFE_RUN_JSON
sed 's/attempt=1/attempt=2/' "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments-case.json"; export LIFE_COMMENTS_JSON
bound_case 'recorded attempt greater' BLOCKED 'attempt 1 differs' 1
sed 's/; attempt=1//' "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
bound_case 'missing attempt' UNVERIFIED 'missing attempt=' 0
sed 's/; attempt=1/; attempt=1; attempt=1/' "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
bound_case 'duplicate attempt' BLOCKED 'malformed review record' 0
sed 's|; run=https://github.com/owner/repo/actions/runs/100|; run=https://github.com/owner/repo/actions/runs/100; run=https://github.com/owner/repo/actions/runs/100|' \
  "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
bound_case 'duplicate run' BLOCKED 'malformed review record' 0
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"; export LIFE_COMMENTS_JSON
LIFE_RUN_FAIL=true
bound_case 'deleted run' UNVERIFIED 'Actions run 100 unavailable' 1
LIFE_RUN_FAIL=false

jq '.data.repository.issue.comments.pageInfo.hasNextPage = true | .data.repository.issue.comments.nodes = ([range(0;100) | {id:("opaque-"+tostring),fullDatabaseId:tostring,body:"prose",author:{login:"reviewer"},lastEditedAt:null}] | .[0].body = .[0].body)' \
  "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
# Keep a valid approval on the first page; pageInfo alone decides completeness.
jq --arg body "$LIFE_MARKER" '.data.repository.issue.comments.nodes[0].body = $body' \
  "$TMP/lifecycle-comments-case.json" > "$TMP/lifecycle-comments-page.json"
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments-page.json"; export LIFE_COMMENTS_JSON
bound_case 'full incomplete page' UNVERIFIED 'exceed one page' 0
jq 'del(.data.repository.issue.comments.pageInfo)' "$TMP/lifecycle-comments-page.json" \
  > "$TMP/lifecycle-comments-case.json"
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments-case.json"; export LIFE_COMMENTS_JSON
bound_case 'missing pageInfo' UNVERIFIED 'pageInfo.hasNextPage missing' 0
jq '.data.repository.issue.comments.pageInfo.hasNextPage = false' "$TMP/lifecycle-comments-page.json" \
  > "$TMP/lifecycle-comments-case.json"
bound_case 'complete 100-node page' READY 'review by reviewer' 1
jq '.errors = [{message:"partial read",path:["repository","issue"]}]' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
bound_case 'GraphQL partial error' UNVERIFIED 'GraphQL error' 0
jq '.data.repository.issue.comments.nodes = null' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
bound_case 'null nodes' UNVERIFIED 'nodes missing' 0
jq '.data.repository.issue.comments.nodes += [null]' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
bound_case 'null node' UNVERIFIED 'node 1 unreadable' 0
jq '.data.repository.issue.comments.nodes[0].fullDatabaseId = null' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
bound_case 'null ordering key' UNVERIFIED 'comment opaque-1 missing valid fullDatabaseId' 0
jq '.data.repository.issue.comments.nodes[0].fullDatabaseId = 10' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
bound_case 'numeric ordering key' UNVERIFIED 'comment opaque-1 missing valid fullDatabaseId' 0
jq '.data.repository.issue.comments.nodes[0].lastEditedAt = "2026-09-24T12:00:00Z"' \
  "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
bound_case 'edited final approval' BLOCKED 'comment opaque-1 was edited' 0
jq 'del(.data.repository.issue.comments.nodes[0].lastEditedAt)' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
bound_case 'missing edit indicator' UNVERIFIED 'comment opaque-1 missing lastEditedAt' 0
jq '.data.repository.issue.comments.nodes = []' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
bound_case 'approval on PR or step issue only' UNVERIFIED 'no approval for PR head' 0
jq --arg old "${LIFE_MARKER/$LIFE_HEAD/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}" \
  '.data.repository.issue.comments.nodes[0].body = $old' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
bound_case 'superseded approval only' UNVERIFIED 'no approval for PR head' 0
jq '.data.repository.issue.comments.nodes[0].body |= sub("status=approved";"status=changes-requested")' \
  "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
bound_case 'changes requested on current head' BLOCKED 'does not approve PR' 0
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"; export LIFE_COMMENTS_JSON

# Later posting wins even when listing order, lexicographic order, and floating
# point conversion each point at the wrong comment.
for ids in '9 10' '9007199254740992 9007199254740993'; do
  read -r low high <<< "$ids"
  jq -n --arg old "${LIFE_MARKER/attempt=1/attempt=2}" --arg new "$LIFE_MARKER" \
    --arg low "$low" --arg high "$high" \
    '{data:{repository:{issue:{comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:"new",fullDatabaseId:$high,body:$new,author:{login:"reviewer"},lastEditedAt:null},{id:"old",fullDatabaseId:$low,body:$old,author:{login:"reviewer"},lastEditedAt:null}]}}}}}' \
    > "$TMP/lifecycle-comments-case.json"
  LIFE_COMMENTS_JSON="$TMP/lifecycle-comments-case.json"; export LIFE_COMMENTS_JSON
  bound_case "decimal order $ids" READY 'review by reviewer.*comment new' 1
done
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"; export LIFE_COMMENTS_JSON

# Project policy is validated independently of the document's own selectors.
cp "$V2FIX/.agentic-flow-review-policy" "$TMP/lifecycle-policy-valid"
for policy_case in 'version=2' 'version=1
version=1' 'version=1
workflow=../ci.yml' 'version=1
workflow=.github/workflows/ci.yml
unknown=value'; do
  printf '%s\n' "$policy_case" > "$V2FIX/.agentic-flow-review-policy"
  : > "$LIFE_CALLS"
  PATH="$LIFE_API:$PATH" AGENTIC_PROJECT_ROOT="$V2FIX" \
    "$ROOT/scripts/lifecycle-status.sh" --doc "$V2FIX/docs/inprogress/feature-v2.md" \
    --check --verify-evidence > "$TMP/lifecycle-policy.out" 2>&1 \
    && fail 'invalid review policy passed'
  grep -q '^UNVERIFIED.*review policy missing or invalid' "$TMP/lifecycle-policy.out" \
    || fail 'invalid policy was not UNVERIFIED'
  if grep -q '^api ' "$LIFE_CALLS"; then fail 'invalid policy made API calls'; fi
done
cp "$TMP/lifecycle-policy-valid" "$V2FIX/.agentic-flow-review-policy"

# F-3: authenticated authors, strict step completeness, and verdict recovery.
review_case() { # <name> <state> <diagnostic>
  : > "$LIFE_CALLS"
  if PATH="$LIFE_API:$PATH" AGENTIC_PROJECT_ROOT="$V2FIX" \
    LIFE_STEP_STATE="${LIFE_STEP_STATE:-CLOSED}" \
    "$ROOT/scripts/lifecycle-status.sh" --doc "$V2FIX/docs/inprogress/feature-v2.md" \
    --check --verify-evidence > "$TMP/lifecycle-review.out" 2>&1; then
    [ "$2" = READY ] || fail "$1 unexpectedly passed"
  else
    [ "$2" != READY ] || fail "$1 unexpectedly failed: $(cat "$TMP/lifecycle-review.out")"
  fi
  grep -q "^$2.*$3" "$TMP/lifecycle-review.out" \
    || fail "$1 did not report $2 and $3: $(cat "$TMP/lifecycle-review.out")"
}
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"; export LIFE_COMMENTS_JSON
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"; export LIFE_STEP_COMMENTS_JSON
# Unlisted authors cannot inject malformed evidence or replace a real handoff.
jq '.data.repository.issue.comments.nodes += [{id:"stranger",body:"agentic-flow-review: malformed",author:{login:"stranger"}}]' "$TMP/lifecycle-comments.json" > "$TMP/stranger-final.json"
jq '.data.repository.issue.comments.nodes += [{id:"stranger",body:"Implemented in bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",author:{login:"stranger"}}]' "$TMP/lifecycle-step-comments.json" > "$TMP/stranger-step.json"
LIFE_COMMENTS_JSON="$TMP/stranger-final.json"
LIFE_STEP_COMMENTS_JSON="$TMP/stranger-step.json"
review_case 'stranger malformed marker and later handoff' READY 'review by reviewer'
grep -q 'EVIDENCE ignored 1' "$TMP/lifecycle-review.out" || fail 'stranger comments not counted'
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"
jq '.data.repository.issue.comments.nodes += [{id:"reviewer-handoff",body:"Implemented in bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",author:{login:"reviewer"}}]' "$TMP/lifecycle-step-comments.json" > "$TMP/reviewer-handoff.json"
LIFE_STEP_COMMENTS_JSON="$TMP/reviewer-handoff.json"
review_case 'reviewer handoff rejected' BLOCKED 'is not an executor'
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"
# Approved commits must remain reachable from the live PR head.
ancestry_case() { # <name> <head> <state> <diagnostic>
  jq --arg head "$2" --arg old "$LIFE_HEAD" '.data.repository.issue.comments.nodes |= map(.body |= gsub($old; $head))' \
    "$TMP/lifecycle-step-comments.json" > "$TMP/ancestry-step.json"
  LIFE_STEP_COMMENTS_JSON="$TMP/ancestry-step.json"
  review_case "$1" "$3" "$4"
}
# An alternate commit models an amended implementation, absent from the PR.
ALT_HEAD=$(printf '%s\n' alternate | git -C "$V2FIX" -c commit.gpgsign=false -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree "${LIFE_HEAD}^{tree}" -p "$STEP_HEAD")
ancestry_case 'amended approved step' "$ALT_HEAD" BLOCKED "$ALT_HEAD.*$LIFE_HEAD"
ancestry_case 'missing approved step' cccccccccccccccccccccccccccccccccccccccc UNVERIFIED 'cccccccccccccccccccccccccccccccccccccccc.*git fetch'
jq '.head.sha = "cccccccccccccccccccccccccccccccccccccccc"' "$TMP/lifecycle-pr.json" > "$TMP/missing-pr.json"
sed "s/$LIFE_HEAD/cccccccccccccccccccccccccccccccccccccccc/g" "$TMP/lifecycle-comments.json" > "$TMP/missing-pr-comments.json"
sed "s/$LIFE_HEAD/cccccccccccccccccccccccccccccccccccccccc/g" "$TMP/lifecycle-run.json" > "$TMP/missing-pr-run.json"
LIFE_PR_JSON="$TMP/missing-pr.json"
LIFE_COMMENTS_JSON="$TMP/missing-pr-comments.json"
LIFE_RUN_JSON="$TMP/missing-pr-run.json"
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"
review_case 'missing PR object' UNVERIFIED 'cccccccccccccccccccccccccccccccccccccccc.*git fetch'
LIFE_PR_JSON="$TMP/lifecycle-pr.json"
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"
LIFE_RUN_JSON="$TMP/lifecycle-run.json"
# A genuine shallow boundary hides an otherwise present ancestor object.
printf '%s\n' "$LIFE_HEAD" > "$V2FIX/.git/shallow"
ancestry_case 'shallow ancestry' "$STEP_HEAD" UNVERIFIED 'git fetch --unshallow'
rm "$V2FIX/.git/shallow"
# Inject only the ancestry command failure; object checks still use real Git.
REAL_LIFE_GIT=$(command -v git)
export REAL_LIFE_GIT
cat > "$LIFE_API/git" <<'FAKE_GIT'
#!/usr/bin/env bash
case "$*" in
  *'merge-base --is-ancestor'*) echo 'fatal: fixture ancestry error' >&2; exit 128 ;;
esac
exec "$REAL_LIFE_GIT" "$@"
FAKE_GIT
chmod +x "$LIFE_API/git"
ancestry_case 'git ancestry error' "$STEP_HEAD" UNVERIFIED 'fatal: fixture ancestry error'
rm "$LIFE_API/git"
ancestry_case 'ancestor approved step' "$STEP_HEAD" READY 'review by reviewer'
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"
review_case 'authenticated final and step' READY 'review by reviewer'
grep -q 'EVIDENCE step f-1.*author=reviewer' "$TMP/lifecycle-review.out" \
  || fail 'step evidence did not print comment and author'
grep -q 'WARN.*single-operator.*not independent review' "$TMP/lifecycle-review.out" \
  || fail 'single-operator evidence lacked the independence warning'
LIFE_STEP_STATE=OPEN
review_case 'open Strict step' BLOCKED 'step f-1 issue 3 is OPEN'
LIFE_STEP_STATE=CLOSED
mkdir -p "$V2FIX/docs/done"
cp "$V2FIX/docs/inprogress/feature-v2.md" "$V2FIX/docs/done/feature-v2.md"
PATH="$LIFE_API:$PATH" AGENTIC_PROJECT_ROOT="$V2FIX" \
  "$ROOT/scripts/lifecycle-status.sh" --doc "$V2FIX/docs/done/feature-v2.md" \
  --phase close-out --check --verify-evidence > "$TMP/lifecycle-closeout.out" 2>&1 \
  || fail 'moved document did not verify before tracker close'
PATH="$LIFE_API:$PATH" LIFE_ISSUE_STATE=CLOSED AGENTIC_PROJECT_ROOT="$V2FIX" \
  "$ROOT/scripts/lifecycle-status.sh" --doc "$V2FIX/docs/done/feature-v2.md" \
  --phase pre-merge --check --verify-evidence > "$TMP/lifecycle-premerge.out" 2>&1 \
  || fail 'same moved document did not verify after tracker close'
grep -q '^READY.*feature-v2.md' "$TMP/lifecycle-premerge.out" \
  || fail 'pre-merge did not report READY after tracker close'
jq 'del(.data.repository.issue.comments.nodes[0].author)' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments-case.json"; export LIFE_COMMENTS_JSON
review_case 'missing final author' UNVERIFIED 'no approval for PR head'
jq '.data.repository.issue.comments.nodes[0].author.login = "intruder"' \
  "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
printf '%s\n' 'version=1' 'workflow=.github/workflows/ci.yml' 'identity-mode=distinct-account' \
  'reviewer=reviewer' 'executor=executor' 'approver=approver' \
  > "$V2FIX/.agentic-flow-review-policy"
review_case 'unauthorized author' UNVERIFIED 'no approval for PR head'
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"; export LIFE_COMMENTS_JSON
review_case 'distinct account reviewer' READY 'review by reviewer'
jq '.data.repository.issue.comments.nodes[0].author.login = "intruder"' \
  "$TMP/lifecycle-step-comments.json" > "$TMP/lifecycle-step-case.json"
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-case.json"; export LIFE_STEP_COMMENTS_JSON
review_case 'unauthorized step handoff' UNVERIFIED 'no full implementation SHA handoff'
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"; export LIFE_STEP_COMMENTS_JSON
printf '%s\n' 'version=1' 'workflow=.github/workflows/ci.yml' 'identity-mode=distinct-account' \
  'reviewer=reviewer' 'executor=reviewer' 'approver=approver' \
  > "$V2FIX/.agentic-flow-review-policy"
review_case 'overlapping reviewer account' UNVERIFIED 'review policy missing or invalid'
cp "$TMP/lifecycle-policy-valid" "$V2FIX/.agentic-flow-review-policy"
sed 's/; role=reviewer/; role=executor/' "$TMP/lifecycle-comments.json" \
  > "$TMP/lifecycle-comments-case.json"
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments-case.json"; export LIFE_COMMENTS_JSON
review_case 'false role claim' BLOCKED 'role claim differs'
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"; export LIFE_COMMENTS_JSON

jq '.data.repository.issue.comments.pageInfo.hasNextPage = true' \
  "$TMP/lifecycle-step-comments.json" > "$TMP/lifecycle-step-case.json"
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-case.json"; export LIFE_STEP_COMMENTS_JSON
review_case 'partial step page' UNVERIFIED 'step f-1 comments exceed one page'
jq 'del(.data.repository.issue.comments.pageInfo)' "$TMP/lifecycle-step-comments.json" \
  > "$TMP/lifecycle-step-case.json"
review_case 'step missing pageInfo' UNVERIFIED 'step f-1 pageInfo.hasNextPage missing'
jq '.errors = [{message:"partial step read",path:["issue"]}]' \
  "$TMP/lifecycle-step-comments.json" > "$TMP/lifecycle-step-case.json"
review_case 'step GraphQL error' UNVERIFIED 'step f-1 GraphQL error'
jq '.data.repository.issue.comments.nodes += [null]' "$TMP/lifecycle-step-comments.json" \
  > "$TMP/lifecycle-step-case.json"
review_case 'step null node' UNVERIFIED 'step f-1 comment node 2 unreadable'
jq '.data.repository.issue.comments.nodes += ([range(2;100) | {id:("prose-"+tostring),fullDatabaseId:tostring,body:"prose",author:{login:"reviewer"},lastEditedAt:null}]) | .data.repository.issue.comments.pageInfo.hasNextPage = false' \
  "$TMP/lifecycle-step-comments.json" > "$TMP/lifecycle-step-case.json"
review_case 'complete 100-node step page' READY 'review by reviewer'
jq 'del(.data.repository.issue.comments.nodes[1].lastEditedAt)' \
  "$TMP/lifecycle-step-comments.json" > "$TMP/lifecycle-step-case.json"
review_case 'step missing edit indicator' UNVERIFIED 'step f-1 comment step-review missing lastEditedAt'
jq '.data.repository.issue.comments.nodes[1].fullDatabaseId = null' \
  "$TMP/lifecycle-step-comments.json" > "$TMP/lifecycle-step-case.json"
review_case 'step null ordering key' UNVERIFIED 'step f-1 comment step-review missing valid fullDatabaseId'
jq '.data.repository.issue.comments.nodes[1].lastEditedAt = "2026-09-25T12:00:00Z"' \
  "$TMP/lifecycle-step-comments.json" > "$TMP/lifecycle-step-case.json"
review_case 'edited authoritative step verdict' BLOCKED 'step f-1 comment step-review was edited'
jq --arg head "$LIFE_HEAD" '.data.repository.issue.comments.nodes += [{id:"fresh",fullDatabaseId:"12",body:("agentic-flow-review: status=approved; step=f-1; head=" + $head + "; role=reviewer"),author:{login:"reviewer"},lastEditedAt:null}]' \
  "$TMP/lifecycle-step-case.json" > "$TMP/lifecycle-step-recovered.json"
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-recovered.json"; export LIFE_STEP_COMMENTS_JSON
review_case 'fresh verdict recovers edit' READY 'review by reviewer'
jq --arg head "$LIFE_HEAD" '.data.repository.issue.comments.nodes[1].body = "review note" | .data.repository.issue.comments.nodes += [{id:"earlier-approval",fullDatabaseId:"9",body:("agentic-flow-review: status=approved; step=f-1; head=" + $head + "; role=reviewer"),author:{login:"reviewer"},lastEditedAt:null}]' \
  "$TMP/lifecycle-step-case.json" > "$TMP/lifecycle-step-recovered.json"
review_case 'removing marker recovers edit' READY 'review by reviewer'
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"; export LIFE_STEP_COMMENTS_JSON

# Above 2^53, adjacent ids collapse if coerced through jq's floating-point number.
# Reverse listing order and share a creation second to rule out both shortcuts.
jq --arg head "$LIFE_HEAD" '.data.repository.issue.comments.nodes = [.data.repository.issue.comments.nodes[0],{id:"new-rejection",fullDatabaseId:"9007199254740993",body:("agentic-flow-review: status=changes-requested; step=f-1; head=" + $head + "; role=reviewer"),author:{login:"reviewer"},createdAt:"2026-09-25T12:00:00Z",lastEditedAt:null},{id:"old-approval",fullDatabaseId:"9007199254740992",body:("agentic-flow-review: status=approved; step=f-1; head=" + $head + "; role=reviewer"),author:{login:"reviewer"},createdAt:"2026-09-25T12:00:00Z",lastEditedAt:null}]' \
  "$TMP/lifecycle-step-comments.json" > "$TMP/lifecycle-step-case.json"
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-case.json"; export LIFE_STEP_COMMENTS_JSON
review_case 'adjacent high step ids and same-second verdicts' BLOCKED 'comment new-rejection does not approve'
jq '.data.repository.issue.comments.nodes[1].lastEditedAt = "2026-09-25T12:00:00Z" | .data.repository.issue.comments.nodes[1].body |= sub("status=changes-requested";"status=approved")' \
  "$TMP/lifecycle-step-case.json" > "$TMP/lifecycle-step-edited.json"
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-edited.json"; export LIFE_STEP_COMMENTS_JSON
review_case 'same-second authoritative edit' BLOCKED 'comment new-rejection was edited'
LIFE_STEP_COMMENTS_JSON="$TMP/lifecycle-step-comments.json"; export LIFE_STEP_COMMENTS_JSON

jq --arg head "$LIFE_HEAD" '.data.repository.issue.comments.nodes += [{id:"duplicate-db-id",fullDatabaseId:"010",body:("agentic-flow-review: status=approved; pr=2; head=" + $head + "; run=https://github.com/owner/repo/actions/runs/100; attempt=1; role=reviewer"),author:{login:"reviewer"},lastEditedAt:null}]' \
  "$TMP/lifecycle-comments.json" > "$TMP/lifecycle-comments-case.json"
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments-case.json"; export LIFE_COMMENTS_JSON
review_case 'normalized duplicate database id' BLOCKED 'duplicate fullDatabaseId'
LIFE_COMMENTS_JSON="$TMP/lifecycle-comments.json"; export LIFE_COMMENTS_JSON

# The review thread is scoped to the current PR head. A new commit makes old
# approval history irrelevant even if the Actions run once succeeded.
jq '.head.sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$TMP/lifecycle-pr.json" \
  > "$TMP/lifecycle-pr-new.json"
LIFE_PR_JSON="$TMP/lifecycle-pr-new.json"; export LIFE_PR_JSON
review_case 'stale approval after PR commit' UNVERIFIED 'no approval for PR head'
LIFE_PR_JSON="$TMP/lifecycle-pr.json"; export LIFE_PR_JSON

printf '%s\n' 'version=1' 'workflow=.github/workflows/ci.yml' 'identity-mode=single-operator' \
  'accepted-risk=docs/accepted_risks.md#missing-entry' > "$V2FIX/.agentic-flow-review-policy"
review_case 'unlinked accepted risk' UNVERIFIED 'review policy missing or invalid'
cp "$TMP/lifecycle-policy-valid" "$V2FIX/.agentic-flow-review-policy"
sed '/^reviewer=/d; /^executor=/d; /^approver=/d' "$TMP/lifecycle-policy-valid" > "$V2FIX/.agentic-flow-review-policy"
review_case 'missing role logins' UNVERIFIED 'review policy missing or invalid'
cp "$TMP/lifecycle-policy-valid" "$V2FIX/.agentic-flow-review-policy"

fi

# --- the run did what the mode promised --------------------------------------------------
# Without this, deleting or mis-guarding a group's `if should_run` block still prints
# "self-test passed." A pass has to mean the groups for this mode actually executed.
if [ -n "$ONLY_GROUP" ]; then
  EXPECTED_GROUPS="$ONLY_GROUP"
elif [ "$SELF_TEST_MODE" = full ]; then
  EXPECTED_GROUPS="$SELF_TEST_GROUPS"
else
  EXPECTED_GROUPS='contracts hooks plan-to-issues lifecycle'
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

# The F-11 table was approved before these limits were set. Keep the two copy
# counters together: fewer snapshots cannot conceal whole-tree derived fixtures.
if [ -z "$ONLY_GROUP" ]; then
  assert_cost_budget "$LOCAL_EVENTS" "$SELF_TEST_MODE"
fi

echo "self-test passed."
