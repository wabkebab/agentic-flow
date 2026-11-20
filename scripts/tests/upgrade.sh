#!/usr/bin/env bash
# Sourced by self-test.sh; shared fixture context is intentional.
# shellcheck disable=SC1091,SC2034,SC2153,SC2164,SC2329 # Dispatcher globals (including ROOT), indirect fixture calls, inherited errexit.
AGENTIC_FLOW_CLI="$ROOT/scripts/agentic-flow"
assert_file "$AGENTIC_FLOW_CLI"

# The red-first overlay contains only this group and helpers. Guard the owning
# groups' holdout wiring as well, so a pristine-only suite cannot pass scenario 8.
for twin_group in export hooks; do
  grep -Eq '^[[:space:]]*adopter_twin_build([[:space:]]|$)' "$ROOT/scripts/tests/$twin_group.sh" \
    || fail "adopter twin holdout missing from $twin_group group"
done

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

# Customized adopter holdout. Installed projects deliberately omit the exporter
# and its pristine templates, just as for the export group's source-only cases.
if [ -f "$ROOT/scripts/export.sh" ]; then
  adopter_twin_build
  (
    cd "$ADOPTER_TWIN"
    twin_before=$(tree_digest "$ADOPTER_TWIN")
    scripts/agentic-flow upgrade > "$TMP/adopter-upgrade-no-yes.out" 2>&1 \
      && fail 'adopter twin upgrade wrote without confirmation'
    [ "$twin_before" = "$(tree_digest "$ADOPTER_TWIN")" ] \
      || fail 'unconfirmed adopter twin upgrade changed the project'
    twin_status=0
    scripts/agentic-flow upgrade --yes > "$TMP/adopter-upgrade.out" 2>&1 || twin_status=$?
    [ "$twin_status" -eq 0 ] \
      || { cat "$TMP/adopter-upgrade.out" >&2; fail 'adopter twin upgrade did not report pending merges'; }
    adopter_twin_preserved
    for twin_file in CLAUDE.md Makefile .claude/settings.json .codex/hooks.json; do
      case "$twin_file" in
        CLAUDE.md|Makefile) twin_source="templates/harness/$twin_file" ;;
        *) twin_source="$twin_file" ;;
      esac
      cmp -s "$twin_file.agentic-new" "$ADOPTER_TWIN_SOURCE/$twin_source" \
        || fail "adopter twin upgrade omitted the pristine candidate for $twin_file"
    done
    assert_file .agentic-flow-candidate-version
    twin_before=$(tree_digest "$ADOPTER_TWIN")
    twin_status=0
    scripts/agentic-flow upgrade --yes > "$TMP/adopter-upgrade-rerun.out" 2>&1 || twin_status=$?
    [ "$twin_status" -eq 0 ] && [ "$twin_before" = "$(tree_digest "$ADOPTER_TWIN")" ] \
      || fail 'adopter twin repeated upgrade changed pending files'

    # A pristine-green, adopter-breaking overwrite must trip the holdout.
    cat "$ADOPTER_TWIN_SOURCE/templates/harness/Makefile" > Makefile
    (adopter_twin_preserved) > "$TMP/adopter-overwrite.out" 2>&1 \
      && fail 'adopter twin accepted an overwritten customized Makefile'
    grep -q 'adopter twin lost project customizations' "$TMP/adopter-overwrite.out" \
      || fail 'adopter twin overwrite failed for an unrelated reason'
    git checkout -- Makefile
    adopter_twin_preserved
  )
fi
