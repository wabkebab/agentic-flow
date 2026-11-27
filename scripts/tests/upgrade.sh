#!/usr/bin/env bash
# Sourced by self-test.sh; shared fixture context is intentional.
# shellcheck disable=SC1091,SC2030,SC2031,SC2034,SC2153,SC2164,SC2329 # Dispatcher globals, dynamic fixture scope, inherited errexit.
AGENTIC_FLOW_CLI="$ROOT/scripts/agentic-flow"
assert_file "$AGENTIC_FLOW_CLI"

uninstall_terminal() {
  python3 - "$AGENTIC_FLOW_CLI" "$1" <<'PYTHON'
import errno
import os
import pty
import select
import subprocess
import sys
import time

master, slave = pty.openpty()
process = subprocess.Popen([sys.argv[1], "uninstall"], stdin=slave, stdout=slave, stderr=slave)
os.close(slave)
output = bytearray()
prompt = b"Stage these uninstall deletions?"
answered = False
deadline = time.monotonic() + 15
try:
    while time.monotonic() < deadline and len(output) < 1024 * 1024:
        readable, _, _ = select.select([master], [], [], 0.1)
        if not readable:
            continue
        try:
            chunk = os.read(master, 8192)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            break
        if not chunk:
            break
        output.extend(chunk)
        if not answered and prompt in output:
            if sys.argv[2] == "change":
                with open("scripts/doctor.sh", "ab") as changed:
                    changed.write(b"changed after preview\n")
            os.write(master, b"n\n" if sys.argv[2] == "decline" else b"y\n")
            answered = True
    sys.stdout.buffer.write(output)
    sys.exit(process.wait(timeout=1) if output.count(prompt) == 1 else 1)
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    os.close(master)
PYTHON
}

# shellcheck disable=SC2016 # jq expressions use jq variables.
uninstall_scenarios() (
  local fixture="$TMP/uninstall" report="$TMP/uninstall.json" status before text_report
  local head digest line workflow
  mkdir -p "$fixture"
  cd "$fixture"
  git init -q -b main
  git config user.name 'Uninstall fixture'
  git config user.email uninstall@example.invalid
  git config commit.gpgsign false
  git config core.fileMode true
  printf 'before adoption\n' > adopter
  git add -- adopter
  git commit -qm base
  mkdir -p docs/done .github/workflows scripts .agentic-flow
  printf 'fixture\n' > .agentic-flow-version
  printf 'offered-version\n' > .agentic-flow-candidate-version
  printf 'settings\n' > .agentic-flow/config
  for path in docs/done/.gitkeep later adopter-neutral edited mode-only pending \
    scripts/self-test.sh scripts/doctor.sh 'literal*' docs/pristine.md CLAUDE.md Makefile \
    pending.agentic-new edited.agentic-new later.agentic-new.offered-version \
    loose.agentic-new stranger.agentic-new.extra; do
    printf 'shipped fixture\n' > "$path"
  done
  digest=$(git hash-object --no-filters --stdin < scripts/self-test.sh) # candidate name uses Git's hash prefix
  printf 'shipped fixture\n' > "later.agentic-new.offered-version.${digest:0:12}"
  digest=$(payload_sha256 scripts/self-test.sh)
  printf 'version=1\nscope=core\nscope=docs\n' > .agentic-flow-installation
  for path in docs/done/.gitkeep adopter-neutral edited mode-only pending \
    scripts/self-test.sh scripts/doctor.sh 'literal*' docs/pristine.md CLAUDE.md Makefile later; do
    printf 'file=%s  %s\n' "$digest" "$path" >> .agentic-flow-installation
  done
  # Write accepted hashes for each installation row and a still pending offer.
  sed -n 's/^file=/accepted=/p' .agentic-flow-installation > .agentic-flow-upstream
  printf 'offered=%s  pending\n' "$digest" >> .agentic-flow-upstream
  printf 'version=1\norigin=export\n' > .agentic-flow-ownership
  for path in edited mode-only pending scripts/self-test.sh scripts/doctor.sh 'literal*' docs/pristine.md CLAUDE.md Makefile; do
    printf 'created=%s  %s\n' "$digest" "$path" >> .agentic-flow-ownership
  done
  for path in pending.agentic-new edited.agentic-new loose.agentic-new; do
    printf 'candidate=%s  %s\n' "$digest" "$path" >> .agentic-flow-ownership
  done
  printf 'shipped fixture\n' > owned-pending-only.agentic-new
  printf 'candidate=%s  owned-pending-only.agentic-new\n' "$digest" >> .agentic-flow-ownership
  printf 'shipped fixture\n' > pending-only
  printf 'created=%s  pending-only\n' "$digest" >> .agentic-flow-ownership
  printf 'accepted=%s  pending-only\n' "$digest" >> .agentic-flow-upstream
  printf 'check:\n\tbash scripts/self-test.sh\n' > Makefile
  printf 'Project guidance invokes agentic-flow.\n' > CLAUDE.md
  printf 'run: scripts/doctor.sh\n' > .github/workflows/ci.yml
  git add -- .agentic-flow-version .agentic-flow-candidate-version .agentic-flow-installation \
    .agentic-flow-upstream .agentic-flow-ownership .agentic-flow/config docs/done/.gitkeep \
    adopter-neutral edited mode-only pending scripts/self-test.sh scripts/doctor.sh \
    ':(literal)literal*' docs/pristine.md CLAUDE.md Makefile .github/workflows/ci.yml \
    pending.agentic-new owned-pending-only.agentic-new pending-only edited.agentic-new
  git commit -qm adoption
  head=$(git rev-parse HEAD)
  git add -- later
  git commit -qm later
  printf 'edited\n' > edited
  printf 'edited candidate\n' > edited.agentic-new
  chmod +x mode-only .agentic-flow-version
  git config core.hooksPath scripts/git-hooks
  git update-ref refs/agentic-flow/salvage/fixture "$head"
  mkdir -p .git/agentic-flow/ledger
  printf 'journal\n' > .git/agentic-flow/ledger/events

  uninstall_snapshot() {
    git ls-files --stage
    git diff --cached --no-ext-diff
    git config --local --list
    git for-each-ref
    tree_digest "$PWD"
    local common
    common=$(git rev-parse --path-format=absolute --git-common-dir)
    (cd "$common" && find . -type f ! -name index -exec cksum {} + | LC_ALL=C sort)
    find . -type f -perm -100 -print | LC_ALL=C sort
  }
  uninstall_report() {
    status=0
    before=$(uninstall_snapshot)
    "$AGENTIC_FLOW_CLI" uninstall --json "$@" > "$report" || status=$?
    [ "$before" = "$(uninstall_snapshot)" ] || fail 'uninstall dry run wrote to the checkout or common dir'
  }
  uninstall_expect() {
    jq -e "$@" "$report" >/dev/null || { cat "$report" >&2; fail 'uninstall report did not match the expected plan'; }
  }
  kept() { uninstall_expect --arg p "$1" --arg r "$2" 'any(.kept[]; .path == $p and .why == $r)'; }
  removed() { uninstall_expect --arg p "$1" --arg k "$2" 'any(.remove[]; .path == $p and .kind == $k)'; }
  refused() {
    [ "$status" = 3 ] || fail "expected uninstall refusal $1, got exit $status"
    uninstall_expect --arg r "$1" 'any(.refusals[]; .reason == $r)'
  }

  # Scenario 5: refuse before any write and report all independent blockers.
  mkdir -p .git/agentic-flow/{plans,locks,worktree-locks}
  printf 'open\tfixture\tmain\n' > .git/agentic-flow/plans/fixture
  mkdir .git/agentic-flow/locks/controller .git/agentic-flow/worktree-locks/cleanup
  printf 'staged\n' > adopter
  git add -- adopter
  chmod +x scripts/self-test.sh
  git config core.fileMode false
  printf 'upgrade\n' > scripts/doctor.sh
  digest=$(payload_sha256 scripts/doctor.sh)
  sed 's/^accepted=.*  scripts\/doctor\.sh$/accepted='"$digest"'  scripts\/doctor.sh/' .agentic-flow-upstream > .agentic-flow-upstream.tmp
  mv .agentic-flow-upstream.tmp .agentic-flow-upstream
  uninstall_report
  refused staged-changes
  refused plan-open
  refused lock-present
  refused uncommitted-install
  uninstall_expect 'any(.refusals[]; .reason == "plan-open" and .command == "agentic-flow clean fixture") and ([.refusals[] | select(.reason == "lock-present")] | length == 2)'
  uninstall_report --yes
  refused staged-changes
  refused plan-open
  refused lock-present
  refused uncommitted-install
  git restore --source=HEAD --staged --worktree -- adopter scripts/doctor.sh .agentic-flow-upstream
  chmod -x scripts/self-test.sh
  git config core.fileMode true
  rmdir .git/agentic-flow/locks/controller .git/agentic-flow/worktree-locks/cleanup
  printf 'closed\tfixture\tmain\n' > .git/agentic-flow/plans/fixture

  # Scenarios 1–4: lack of ownership, candidate provenance, pristine bytes and Git mode.
  uninstall_report --claim-adoption
  [ "$status" = 0 ] || fail 'valid uninstall dry run refused'
  uninstall_expect 'keys == (["v","root","version","origin","adoption_commit","refusals","remove","kept","dangling_references","dangling_truncated","git","git_state","outside"] | sort) and .v == 1 and .origin == "export" and .version == "fixture" and .adoption_commit == null and .refusals == [] and all(.remove[]; (.sha256 | test("^[0-9a-f]{64}$")) and (.mode | test("^100(644|755)$")))'
  kept docs/done/.gitkeep no-ownership
  kept later no-ownership
  removed pending.agentic-new candidate
  removed owned-pending-only.agentic-new candidate
  removed pending-only payload
  kept loose.agentic-new untracked
  uninstall_expect 'any(.kept[]; .path == "loose.agentic-new" and .command == "rm -- loose.agentic-new")'
  kept edited.agentic-new edited-candidate
  kept later.agentic-new.offered-version legacy-candidate
  kept stranger.agentic-new.extra unrecognized-candidate
  kept pending pending-offer
  removed 'literal*' payload
  removed scripts/self-test.sh payload
  kept edited edited
  kept CLAUDE.md edited
  kept mode-only mode-changed
  kept .agentic-flow-version mode-changed
  kept .agentic-flow/config project-state-kept
  uninstall_report --keep-docs --remove-project-state
  kept docs/pristine.md keep-docs
  removed .agentic-flow/config project
  git config core.fileMode false
  uninstall_report
  removed .agentic-flow-version stamp
  removed mode-only payload
  git config core.fileMode true

  # Scenario 9: reports reference locations, config, refs and common state.
  uninstall_expect 'any(.dangling_references[]; .file == "Makefile" and .line == 2 and .ref == "scripts/self-test.sh") and any(.dangling_references[]; .file == ".github/workflows/ci.yml" and .line == 1 and .ref == "scripts/doctor.sh") and any(.git[]; .what == "core.hooksPath" and .command == "git config --local --unset core.hooksPath") and any(.git[]; .what == "salvage-ref") and any(.git_state[]; (.dir | endswith("/ledger")) and .class == "record" and .entries == 1 and .bytes > 0) and (.outside | length >= 5)'
  text_report=$("$AGENTIC_FLOW_CLI" uninstall)
  [[ "$text_report" == *'make check'* && "$text_report" == *'CI'* && "$text_report" == *'only copy'* ]] ||
    fail 'uninstall text report omitted the reference or ledger warning'
  for ((line=0; line<23; line++)); do
    printf 'agentic-flow scripts/doctor.sh\n' >> Makefile
  done
  uninstall_report
  uninstall_expect '[.dangling_references[] | select(.file == "Makefile")] | length == 20'
  uninstall_expect '.dangling_truncated == 4'
  for ((workflow=0; workflow<10; workflow++)); do
    cp -- Makefile ".github/workflows/references-$workflow"
  done
  printf 'agentic-flow\0binary\n' > .github/workflows/binary
  (printf 'agentic-flow\n'; dd if=/dev/zero bs=1048576 count=1 2>/dev/null) > .github/workflows/oversize
  uninstall_report
  uninstall_expect '(.dangling_references | length) == 200 and .dangling_truncated == 66 and all(.dangling_references[]; .file != ".github/workflows/binary" and .file != ".github/workflows/oversize")'

  # Scenario 8: claim only pristine additions from adoption, and never without upstream.
  sed 's/^origin=export$/origin=upgrade/' .agentic-flow-ownership > .agentic-flow-ownership.tmp
  mv .agentic-flow-ownership.tmp .agentic-flow-ownership
  uninstall_report --claim-adoption
  uninstall_expect --arg head "$head" '.adoption_commit == $head and any(.remove[]; .path == "adopter-neutral" and .why == "claimed")'
  kept later no-ownership
  mv .agentic-flow-upstream "$TMP/uninstall-upstream"
  uninstall_report --claim-adoption
  uninstall_expect 'all(.remove[]; .why != "claimed")'
  text_report=$("$AGENTIC_FLOW_CLI" uninstall --claim-adoption)
  [[ "$text_report" == *'agentic-flow upgrade'* ]] || fail 'legacy uninstall did not print the upgrade command'
  mv "$TMP/uninstall-upstream" .agentic-flow-upstream

  git worktree add -qb fixture-linked "$TMP/uninstall-linked"
  uninstall_report
  refused plan-open
  (cd "$TMP/uninstall-linked" && uninstall_report; refused linked-worktree)
  git worktree remove "$TMP/uninstall-linked"
  mkdir nested
  printf 'fixture\n' > nested/.agentic-flow-version
  (cd nested && uninstall_report; refused not-git-toplevel)
  mv .agentic-flow-installation "$TMP/uninstall-installation"
  uninstall_report
  refused no-installation
  mv "$TMP/uninstall-installation" .agentic-flow-installation
  printf 'unknown=invalid\n' >> .agentic-flow-installation
  uninstall_report
  refused invalid-record
  git restore -- .agentic-flow-installation
  rm -- scripts/doctor.sh
  ln -s "$TMP/uninstall-installation" scripts/doctor.sh
  uninstall_report
  uninstall_expect 'any(.kept[]; .path == "scripts/doctor.sh") and all(.remove[]; .path != "scripts/doctor.sh")'

  git restore -- .agentic-flow-ownership scripts/doctor.sh
  printf 'wildcard neighbour\n' > literal-neighbour
  chmod +x scripts/self-test.sh
  git add -- literal-neighbour scripts/self-test.sh
  git commit -qm 'Keep a wildcard neighbour and record an executable payload'
  git update-index --assume-unchanged -- pending-only

  before=$(uninstall_snapshot)
  uninstall_terminal decline > "$TMP/uninstall-terminal.log" || fail 'interactive uninstall did not accept a no response'
  [ "$before" = "$(uninstall_snapshot)" ] || fail 'interactive uninstall wrote after a no response'
  status=0
  uninstall_terminal change > "$TMP/uninstall-terminal.log" || status=$?
  if [ "$status" != 3 ] || ! grep -q 'plan-changed' "$TMP/uninstall-terminal.log"; then
    fail 'confirmation accepted a changed plan'
  fi
  git restore -- scripts/doctor.sh
  [ "$before" = "$(uninstall_snapshot)" ] || fail 'changed interactive plan wrote to the checkout or common dir'

  uninstall_apply_scenarios
)

# shellcheck disable=SC2016 # jq expressions use jq variables.
uninstall_apply_scenarios() {
  local stage contents modes pause_pid undo_script receipt_two initial_head output
  local before_dir="$TMP/uninstall-pauses" diagnostics="$TMP/uninstall.stderr"
  stage=$(git ls-files --stage)
  contents=$(tree_digest "$PWD")
  modes=$(find . -path ./.git -prune -o -type f -perm -100 -print | LC_ALL=C sort)
  mkdir -p "$before_dir"

  start_paused() { # <run> <point>
    mkdir -p "$before_dir/$1/$2"
    AGENTIC_UNINSTALL_TESTING=1 AGENTIC_UNINSTALL_TEST_PAUSES="$before_dir/$1" \
      "$AGENTIC_FLOW_CLI" uninstall --yes --json > "$before_dir/$1.json" 2> "$before_dir/$1.err" &
    pause_pid=$!
    local i
    for ((i=0; i<400; i++)); do
      [ ! -f "$before_dir/$1/$2/ready" ] || return 0
      kill -0 "$pause_pid" 2>/dev/null || break
      sleep 0.05
    done
    cat "$before_dir/$1.err" >&2
    fail "uninstall did not reach $2 for $1"
  }
  finish_paused() { # <run> <point> <pid> <exit>
    touch "$before_dir/$1/$2/continue"
    status=0
    wait "$3" || status=$?
    report="$before_dir/$1.json"
    diagnostics="$before_dir/$1.err"
    [ "$status" = "$4" ] || { cat "$report" "$diagnostics" >&2; fail "unexpected apply status for $1: $status"; }
    undo_script=$(jq -r '.receipt.undo' "$report")
    grep -Fq -- "bash $(printf '%q' "$undo_script")" "$diagnostics" || fail 'uninstall omitted its printed undo command'
  }
  check_restored() {
    [ "$stage" = "$(git ls-files --stage)" ] && git diff --cached --quiet &&
      [ "$contents" = "$(tree_digest "$PWD")" ] &&
      [ "$modes" = "$(find . -path ./.git -prune -o -type f -perm -100 -print | LC_ALL=C sort)" ] ||
      fail 'undo did not restore the index, bytes, and Git modes'
  }

  # Scenario 7: Git refuses the whole batch after a planned file becomes dirty.
  start_paused dirty before-rm
  printf 'racing worktree edit\n' > scripts/doctor.sh
  finish_paused dirty before-rm "$pause_pid" 4
  uninstall_expect '.outcome == "unchanged" and .verified_deletions == []'
  [ "$(cat scripts/doctor.sh)" = 'racing worktree edit' ] && [ "$stage" = "$(git ls-files --stage)" ] ||
    fail 'Git refusal changed the index or lost the worktree edit'
  git restore -- scripts/doctor.sh
  check_restored

  # Scenario 7: an interrupted apply keeps new adopter content and lists receipts on retry.
  start_paused recreated before-check
  printf 'new adopter worktree content\n' > 'literal*'
  finish_paused recreated before-check "$pause_pid" 4
  uninstall_expect '.outcome == "incomplete" and .incomplete == [{path: "literal*", index: false, worktree: true}]'
  if ! grep -Fq 'different content or mode: inspect it' "$diagnostics" || grep -Fq 'rm --' "$diagnostics"; then
    fail 'incomplete apply gave the wrong advice for recreated content'
  fi
  uninstall_report --yes
  refused staged-changes
  uninstall_expect --arg undo "$undo_script" '.receipts_present | length >= 6 and any(.[]; .path == $undo and (.modified_utc | endswith("Z")))'
  for edit in unstaged staged; do
    if [ "$edit" = staged ]; then
      printf 'distinct staged edit\n' > 'literal*'
      git --literal-pathspecs add -- 'literal*'
      printf 'distinct worktree edit\n' > 'literal*'
    fi
    before=$(uninstall_snapshot)
    status=0
    bash "$undo_script" > "$diagnostics" 2>&1 || status=$?
    [ "$status" = 3 ] && grep -Fq 'literal\*' "$diagnostics" && [ "$before" = "$(uninstall_snapshot)" ] ||
      fail 'undo touched distinct adopter content'
  done
  git --literal-pathspecs rm --cached -qf -- 'literal*'
  rm -- 'literal*'
  bash "$undo_script"
  check_restored

  # Scenario 7: Git stages the deletion but cannot unlink a file in an unwritable parent.
  if [ "$(id -u)" != 0 ]; then
    start_paused unlink before-rm
    chmod a-w docs
    finish_paused unlink before-rm "$pause_pid" 4
    uninstall_expect '.outcome == "incomplete" and .incomplete == [{path: "docs/pristine.md", index: false, worktree: true}]'
    if ! grep -Fq 'matches the receipt' "$diagnostics" || grep -Eq '(^Verified|rm --)' "$diagnostics"; then
      fail 'unlink failure was reported as success or advised deleting the leftover'
    fi
    local inode
    inode=$(perl -e 'print((lstat $ARGV[0])[1])' docs/pristine.md)
    chmod u+w docs
    bash "$undo_script"
    [ "$inode" = "$(perl -e 'print((lstat $ARGV[0])[1])' docs/pristine.md)" ] || fail 'undo replaced the leftover file'
    check_restored
  fi

  # Scenarios 4 and 7: removal is literal and verifies only its own paths.
  start_paused scoped before-check
  printf 'unrelated staged edit\n' > adopter
  git add -- adopter
  finish_paused scoped before-check "$pause_pid" 0
  uninstall_expect '.outcome == "complete" and .verified_deletions == [.remove[].path] and
    (.verified_deletions | index("literal*") != null and index("literal-neighbour") == null and index("adopter") == null) and
    any(.kept[]; .path == "pending-only" and .why == "index-flags")'
  grep -Fq 'Other staged changes are outside this check' "$diagnostics" && [ -f literal-neighbour ] &&
    [ -f edited ] && [ -f CLAUDE.md ] && [ -f pending-only ] && [ -x mode-only ] && [ -x .agentic-flow-version ] ||
    fail 'apply altered kept content or overclaimed its verification'
  git restore --source=HEAD --staged --worktree -- adopter
  if [ "$(id -u)" != 0 ]; then
    mkdir -p scripts
    chmod a-w scripts
    status=0
    bash "$undo_script" > "$diagnostics" 2>&1 || status=$?
    chmod u+w scripts
    [ "$status" = 4 ] && grep -Fq 'scripts/self-test.sh (index restored, file missing)' "$diagnostics" &&
      [ "$stage" = "$(git ls-files --stage)" ] && [ ! -e scripts/self-test.sh ] || fail 'undo did not report partial work'
  fi
  bash "$undo_script"
  check_restored
  bash "$undo_script"
  check_restored

  # Scenario 7: overlapping applies use distinct receipts and only one stages anything.
  local first_pid
  start_paused first before-rm
  first_pid=$pause_pid
  start_paused second before-rm
  finish_paused first before-rm "$first_pid" 0
  output=$undo_script
  finish_paused second before-rm "$pause_pid" 4
  receipt_two=$undo_script
  [ "$output" != "$receipt_two" ] && [ -s "$output" ] && [ -s "$receipt_two" ] || fail 'overlapping applies shared a receipt'
  git switch -qc other-branch
  before=$(uninstall_snapshot)
  status=0
  bash "$output" > "$diagnostics" 2>&1 || status=$?
  [ "$status" = 3 ] && grep -Fq "git checkout $(git rev-parse HEAD)" "$diagnostics" &&
    [ "$before" = "$(uninstall_snapshot)" ] || fail 'undo changed the index on another branch'
  git switch -q main
  bash "$output"
  check_restored

  initial_head=$(git rev-parse HEAD)
  start_paused moved before-check
  git commit -qm 'Commit the removal before its final check'
  finish_paused moved before-check "$pause_pid" 4
  uninstall_expect --arg head "$initial_head" '.outcome == "head-moved" and .commit == $head and .verified_deletions == []'
  before=$(uninstall_snapshot)
  status=0
  bash "$undo_script" > "$diagnostics" 2>&1 || status=$?
  [ "$status" = 3 ] && grep -Fq "git checkout $initial_head" "$diagnostics" &&
    [ "$before" = "$(uninstall_snapshot)" ] || fail 'undo touched a moved HEAD or omitted the manual route'
}

uninstall_empty_apply() (
  mkdir "$TMP/uninstall-empty"
  cd "$TMP/uninstall-empty"
  git init -q -b main
  printf 'version=1\nscope=core\n' > .agentic-flow-installation
  GIT_TRACE="$TMP/uninstall-empty.trace" "$AGENTIC_FLOW_CLI" uninstall --yes --json > "$TMP/uninstall-empty.json" ||
    fail 'an empty uninstall apply refused'
  jq -e '.remove == [] and .refusals == [] and (has("receipt") | not)' "$TMP/uninstall-empty.json" >/dev/null &&
    [ ! -e .git/agentic-flow ] && [ -f .agentic-flow-installation ] || fail 'empty apply created a receipt or touched the installation'
  if grep -q 'built-in: git rm ' "$TMP/uninstall-empty.trace"; then fail 'empty apply called git rm'; fi
)

# Scenario 6: run the installed CLI, including after Git unlinks it.
uninstall_export_roundtrip() (
  local common="$TMP/uninstall export" pre_export remove_list git_config
  mkdir "$common"
  cd "$common"
  git init -q -b main
  git config user.name 'Uninstall fixture'
  git config user.email uninstall@example.invalid
  git config commit.gpgsign false
  git commit --allow-empty -qm 'Before export'
  pre_export=$(git rev-parse HEAD)
  "$ROOT/scripts/export.sh" "$common" > "$TMP/uninstall-export.log"
  git ls-files --others --exclude-standard -z | xargs -0 git add --
  git commit -qm 'Install the harness'
  git config core.hooksPath scripts/git-hooks
  git_config=$(git config --local --list)
  GIT_TRACE="$TMP/uninstall-export.trace" scripts/agentic-flow uninstall --yes --json \
    > "$TMP/uninstall-export-apply.json" 2> "$TMP/uninstall-export-apply.err" ||
    { cat "$TMP/uninstall-export-apply.err" >&2; fail 'the installed CLI did not survive removing itself'; }
  [ "$(grep -c 'built-in: git rm ' "$TMP/uninstall-export.trace")" = 1 ] || fail 'apply did not call git rm exactly once'
  remove_list=$(jq -r '.remove[].path' "$TMP/uninstall-export-apply.json" | LC_ALL=C sort)
  [ -n "$remove_list" ] && [ ! -e scripts/agentic-flow ] &&
    [ "$remove_list" = "$(git -c core.quotePath=false diff --cached --name-status | sed -n 's/^D\t//p' | LC_ALL=C sort)" ] &&
    [ -z "$(git diff --cached --name-only --diff-filter=d)" ] &&
    [ "$git_config" = "$(git config --local --list)" ] || fail 'export uninstall staged a different set from the report'
  jq -e '.outcome == "complete" and .verified_deletions == [.remove[].path] and
    any(.git[]; .what == "core.hooksPath" and .command == "git config --local --unset core.hooksPath")' \
    "$TMP/uninstall-export-apply.json" >/dev/null || fail 'export uninstall omitted verification or the hooks command'
  git commit -qm 'Stage-only uninstall reviewed by the adopter'
  [ "$(git diff --name-status "$pre_export" HEAD)" = $'A\t.agentic-flow-assurance\nA\t.agentic-flow-review-policy\nA\tdocs/README.md' ] ||
    fail 'uninstalled export left unexpected files in the committed tree'
)

scenario_group_begin upgrade
if should_run_scenario uninstall uninstall; then
  uninstall_scenarios
  uninstall_empty_apply
  if [ -f "$ROOT/scripts/export.sh" ]; then uninstall_export_roundtrip; fi
  if [ -z "$ONLY_GROUP" ]; then
    uninstall_seconds=$(( $(self_test_now) - SCENARIO_START_SECONDS ))
    measure_event "group:upgrade:uninstall:$uninstall_seconds"
    check_wall_ceiling upgrade:uninstall "$uninstall_seconds"
  fi
fi
assert_scenarios_ran
[ "$SCENARIO_SET" = 0 ] || return 0

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
ln "$ROOT/scripts/lib/git-guards.sh" "$STATUS_FIX/scripts/lib/git-guards.sh"
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
# Scenario 3. One candidate is already present with exactly the offered bytes.
printf '# adopter docs script\n' > "$UPGRADE_TARGET/scripts/docs-index.sh"
cp "$UPGRADE_SOURCE/scripts/docs-index.sh" "$UPGRADE_TARGET/scripts/docs-index.sh.agentic-new"
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
candidate=$(find "$UPGRADE_TARGET" -type f -name 'CLAUDE.md.agentic-new.*' -print -quit)
candidate_row="candidate=$(shasum -a 256 "$candidate" | cut -d ' ' -f 1)  ${candidate##*/}"
ownership="$UPGRADE_TARGET/.agentic-flow-ownership"
if ! grep -Fxq 'origin=upgrade' "$ownership" || ! grep -Fxq "$candidate_row" "$ownership" ||
  [ "$(grep -c '^candidate=' "$ownership")" -ne 1 ] || grep -q '^created=' "$ownership"; then
  fail 'pending legacy upgrade did not distinguish its new candidate from existing files and reused candidates'
fi
grep -Fq 'scripts/docs-index.sh.agentic-new   (pending' "$TMP/upgrade-pending.out" \
  || fail 'pending legacy upgrade did not reuse the adopter candidate'
candidate_count_before=$(find "$UPGRADE_TARGET" -type f -name 'CLAUDE.md.agentic-new*' | wc -l | tr -d ' ')
ownership_before=$(cat "$ownership")
(cd "$UPGRADE_TARGET" && "$AGENTIC_FLOW_CLI" upgrade --yes) > "$TMP/upgrade-rerun.out" \
  || fail "rerunning upgrade with pending candidates failed"
candidate_count_after=$(find "$UPGRADE_TARGET" -type f -name 'CLAUDE.md.agentic-new*' | wc -l | tr -d ' ')
[ "$candidate_count_before" = "$candidate_count_after" ] \
  || fail "rerunning upgrade duplicated existing merge candidates"
[ "$(cat "$ownership")" = "$ownership_before" ] || fail 'pending upgrade retry changed ownership'

printf 'unexpected=1\n' >> "$ownership"
before=$(tree_digest "$UPGRADE_TARGET")
for operation in apply merged; do
  case "$operation" in
    apply) upgrade_args=(--yes --force) ;;
    merged) upgrade_args=(--merged CLAUDE.md) ;;
  esac
  (cd "$UPGRADE_TARGET" && "$AGENTIC_FLOW_CLI" upgrade "${upgrade_args[@]}") \
    > "$TMP/upgrade-bad-ownership.out" 2>&1 && fail "upgrade $operation accepted malformed ownership"
  grep -q 'ownership.*unknown record key' "$TMP/upgrade-bad-ownership.out" &&
    [ "$before" = "$(tree_digest "$UPGRADE_TARGET")" ] \
    || fail "upgrade $operation wrote before refusing malformed ownership"
done
printf '%s\n' "$ownership_before" > "$ownership"
(cd "$UPGRADE_TARGET" && "$AGENTIC_FLOW_CLI" upgrade --merged CLAUDE.md) > "$TMP/upgrade-ownership-merged.out" \
  || fail 'upgrade --merged rejected an owned candidate'
[ "$(cat "$ownership")" = $'version=1\norigin=upgrade' ] && [ ! -e "$candidate" ] &&
  [ ! -e "$UPGRADE_TARGET/CLAUDE.md.agentic-new" ] && [ -f "$UPGRADE_TARGET/scripts/docs-index.sh.agentic-new" ] \
  || fail 'upgrade --merged did not drop the ownership of the candidates it removed'

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

# Scenario 2. A new release ships bytes the adopter already has at a new path.
printf 'already here\n' > "$UPGRADE_CLEAN/adopter-file"
printf 'already here\n' > "$UPGRADE_SOURCE/adopter-file"
printf 'adopter-file\tadopter-file\tcore\tpreserve\texport\n' >> "$UPGRADE_SOURCE/config/payload.tsv"
git -C "$UPGRADE_SOURCE" add adopter-file config/payload.tsv
git -C "$UPGRADE_SOURCE" commit -qm 'Ship a destination that exists in the adopter'
(cd "$UPGRADE_CLEAN" && "$AGENTIC_FLOW_CLI" upgrade --yes) > "$TMP/upgrade-identical.out" \
  || fail 'upgrade failed on an identical adopter file at a new destination'
ownership="$UPGRADE_CLEAN/.agentic-flow-ownership"
if ! grep -Fxq 'origin=upgrade' "$ownership" || grep -Eq '^created=.*  adopter-file$' "$ownership"; then
  fail 'upgrade claimed an identical adopter file at a new destination'
fi
rm -- "$UPGRADE_CLEAN/adopter-file"
(cd "$UPGRADE_CLEAN" && "$AGENTIC_FLOW_CLI" upgrade --yes) > "$TMP/upgrade-recreate.out" \
  || fail 'upgrade could not re-create a deleted path'
adopter_hash=$(shasum -a 256 "$UPGRADE_SOURCE/adopter-file" | cut -d ' ' -f 1)
if ! cmp -s "$UPGRADE_SOURCE/adopter-file" "$UPGRADE_CLEAN/adopter-file" ||
  ! grep -Fxq "created=$adopter_hash  adopter-file" "$ownership"; then
  fail 'upgrade did not record the path it re-created'
fi

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
  export CODEX_HOME="$TMP/upgrade-codex-home"
  git -C "$ADOPTER_TWIN" config --local core.hooksPath scripts/git-hooks
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

if [ -f "$ROOT/scripts/export.sh" ]; then
  # Run the installed 0.19.0 entry point, with the current worktree as the release.
  legacy_release="$TMP/legacy-guard-release"
  legacy_twin="$TMP/legacy-guard-adopter"
  bridge_temp="$TMP/bridge-temp"
  mkdir -p "$legacy_release" "$bridge_temp"
  git -C "$ROOT" archive 3a8930a | tar -x -C "$legacy_release"
  fresh_export "$legacy_release" "$legacy_twin"
  (
    cd "$legacy_twin"
    export TMPDIR="$bridge_temp"
    touch "$bridge_temp/keep"
    git init -q
    git config user.name 'Legacy adopter'
    git config user.email legacy@example.invalid
    git config commit.gpgsign false
    jq '.hooks.PreToolUse[0].hooks += [{type:"command",command:"test -f CLAUDE.md"}]' \
      .claude/settings.json > customized
    mv customized .claude/settings.json
    printf 'origin file://%s\nref main\n' "$ADOPTER_TWIN_SOURCE" > .agentic-flow-source
    git ls-files --others --exclude-standard -z | xargs -0 git add --
    git commit -qm 'Install and customize 0.19.0'

    legacy_snapshot() {
      git rev-parse HEAD
      git for-each-ref --format='%(refname) %(objectname)'
      cksum .git/index
      tree_digest "$PWD"
    }
    before=$(legacy_snapshot)
    status=0
    scripts/agentic-flow diff --json > "$TMP/legacy-diff.out" || status=$?
    if [ "$status" -ne 1 ] || ! jq -e .changes_available "$TMP/legacy-diff.out" >/dev/null; then
      fail 'legacy diff did not report the available upgrade'
    fi
    [ "$before" = "$(legacy_snapshot)" ] || fail 'legacy diff wrote to the adopter'

    mkdir "$bridge_temp/not-a-fetch" "$TMP/agentic-flow-fetch.XYZ999"
    ln -s "$TMP/agentic-flow-fetch.XYZ999" "$bridge_temp/agentic-flow-fetch.XYZ999"
    for forged in "$bridge_temp/not-a-fetch" "$TMP/agentic-flow-fetch.XYZ999" "$bridge_temp/agentic-flow-fetch.XYZ999"; do
      status=0
      "$AGENTIC_FLOW_CLI" upgrade --bridged-from "$forged" --confirmed > "$TMP/bridge-reject.out" 2>&1 || status=$?
      if [ "$status" -ne 2 ] || ! grep -q 'invalid upgrade fetch directory' "$TMP/bridge-reject.out"; then
        fail 'forged bridge directory was not rejected'
      fi
      [ "$before" = "$(legacy_snapshot)" ] || fail 'forged bridge changed the adopter'
    done
    if [ "$(id -u)" -eq 0 ]; then
      foreign_fetch="$bridge_temp/agentic-flow-fetch.ABC123"
      git clone --quiet "$ADOPTER_TWIN_SOURCE" "$foreign_fetch/source"
      chown 65534 "$foreign_fetch"
      status=0
      "$foreign_fetch/source/scripts/agentic-flow" upgrade --bridged-from "$foreign_fetch" --confirmed \
        > "$TMP/bridge-owner.out" 2>&1 || status=$?
      [ "$status" -eq 2 ] && [ -d "$foreign_fetch/source" ] \
        && [ "$before" = "$(legacy_snapshot)" ] || fail 'foreign-owned bridge directory was not rejected'
      mv "$foreign_fetch" "$bridge_temp/foreign-owner-rejected"
    fi

    status=0
    python3 - > "$TMP/bridge-pty.out" 2>&1 <<'PYTHON' || status=$?
import errno
import os
import pty
import select
import subprocess
import sys
import time

master, slave = pty.openpty()
process = subprocess.Popen(
    ["scripts/agentic-flow", "upgrade"], stdin=slave, stdout=slave, stderr=slave
)
os.close(slave)
output = bytearray()
prompt = b"Apply agentic-flow upgrade now?"
answered = False
deadline = time.monotonic() + 30
try:
    while time.monotonic() < deadline and len(output) < 1024 * 1024:
        readable, _, _ = select.select([master], [], [], 0.2)
        if not readable:
            continue
        try:
            chunk = os.read(master, 8192)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            break
        if not chunk:
            break
        output.extend(chunk)
        if not answered and prompt in output:
            os.write(master, b"y\n")
            answered = True
        if output.count(prompt) > 1:
            break
    sys.stdout.buffer.write(output)
    sys.exit(process.wait(timeout=1) if output.count(prompt) == 1 else 1)
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    os.close(master)
PYTHON
    [ "$status" -eq 0 ] || { cat "$TMP/bridge-pty.out" >&2; fail 'legacy interactive upgrade did not complete'; }
    [ "$(awk '/Apply agentic-flow upgrade now/ {n++} END {print n+0}' "$TMP/bridge-pty.out")" -eq 1 ] \
      || fail 'legacy interactive upgrade did not prompt exactly once'
    [ -f "$bridge_temp/keep" ] &&
      [ -z "$(find "$bridge_temp" -type d -name 'agentic-flow-fetch.*' -print)" ] \
      || fail 'bridge did not clean exactly its fetched release'
    [ "$(git config --local --get core.hooksPath)" = scripts/git-hooks ] \
      || { cat "$TMP/bridge-pty.out" >&2; fail 'legacy upgrade did not enable Git hooks'; }
    jq -e 'any(.hooks.PreToolUse[]?.hooks[]?; .command=="test -f CLAUDE.md")' \
      .claude/settings.json >/dev/null || fail 'legacy upgrade removed a custom hook'
    for live_settings in .claude/settings.json .codex/hooks.json; do
      jq -e 'all(.hooks.PreToolUse[]?.hooks[]?; (.command // "") |
        test("scripts/hooks/(block-git-add-all|block-push|require-step-comment|scan-secrets)\\.sh$") | not)' \
        "$live_settings" >/dev/null || fail "legacy upgrade left retired hooks in $live_settings"
    done
    cmp -s config/stations/command-policy.rules "$CODEX_HOME/rules/agentic-flow.rules" \
      || fail 'legacy upgrade did not install the interactive Codex policy'
    for denied in 'git push' 'git add -A' 'gh issue edit'; do
      jq -e --arg deny "Bash($denied:*)" '.permissions.deny | index($deny) != null' \
        .claude/settings.json >/dev/null || fail "upgraded CLI settings allow $denied"
    done
    printf 'key = "%s"\n' "$(printf 'AKIA%s' 'IOSFODNN7EXAMPLE')" > credential
    git add credential
    git commit -qm 'Probe upgraded scanner' > "$TMP/upgraded-scan.out" 2>&1 \
      && fail 'upgraded twin committed a credential'
    grep -qx 'agentic-flow: staged credential blocked' "$TMP/upgraded-scan.out" \
      || fail 'upgraded commit failed outside the scanner'

    # shellcheck source=scripts/lib/git-guards.sh
    . "$PWD/scripts/lib/git-guards.sh"
    probe_project="$TMP/legacy-probe-alias"
    ln -s "$(pwd -P)" "$probe_project"
    for probe_case in scanner inherited-env missing other-rejection custom-chain; do
      mkdir -p custom-hooks
      case "$probe_case" in
        scanner|inherited-env) git config --local core.hooksPath scripts/git-hooks ;;
        *) git config --local core.hooksPath custom-hooks ;;
      esac
      case "$probe_case" in
        other-rejection) printf '#!/bin/sh\necho another hook rejected >&2\nexit 1\n' > custom-hooks/pre-commit ;;
        custom-chain) printf '#!/bin/sh\nexec scripts/git-hooks/pre-commit\n' > custom-hooks/pre-commit ;;
      esac
      [ ! -f custom-hooks/pre-commit ] || chmod +x custom-hooks/pre-commit
      before=$(legacy_snapshot)
      status=0
      if [ "$probe_case" = inherited-env ]; then
        GIT_DIR="$PWD/.git" GIT_WORK_TREE="$PWD" GIT_INDEX_FILE="$PWD/.git/index" \
          GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=missing \
          git_guard_probe "$probe_project" || status=$?
      else
        git_guard_probe "$probe_project" || status=$?
      fi
      case "$probe_case" in
        scanner|inherited-env|custom-chain) [ "$status" -eq 0 ] || fail "Git probe failed ($probe_case)" ;;
        *) [ "$status" -ne 0 ] || fail "Git probe accepted a non-scanner verdict ($probe_case)" ;;
      esac
      [ "$before" = "$(legacy_snapshot)" ] || fail "Git probe touched the adopter ($probe_case)"
    done
    git config --local --unset core.hooksPath
    git_guard_enable "$probe_project" &&
      [ "$(git config --local --get core.hooksPath)" = scripts/git-hooks ] \
      || fail 'could not enable the Git hook through a directory alias'
    # Reuse the upgraded files with the twin's original registrations to
    # exercise failed activation and an unproven custom hooks path.
    # shellcheck source=scripts/lib/guard-migration.sh
    . "$ROOT/scripts/lib/guard-migration.sh"
    scopes='core claude codex opencode ci docs'
    git checkout HEAD -- .claude/settings.json .codex/hooks.json
    codex_before=$(cksum .codex/hooks.json)
    for bad_adapter in conflicting malformed; do
      case "$bad_adapter" in
        conflicting)
          jq '.permissions = false' .claude/settings.json > conflicting
          mv conflicting .claude/settings.json ;;
        malformed) printf '{' >> .claude/settings.json ;;
      esac
      guard_before=$(cksum .claude/settings.json)
      migrate_guards "$ADOPTER_TWIN_SOURCE" "$PWD" "$scopes" \
        > "$TMP/activation-error.out" 2>&1 && fail "migration accepted $bad_adapter adapter settings"
      grep -q 'pending: command policy not active' "$TMP/activation-error.out" \
        || fail "migration did not report $bad_adapter adapter settings"
      [ "$guard_before" = "$(cksum .claude/settings.json)" ] &&
        [ "$codex_before" = "$(cksum .codex/hooks.json)" ] || fail 'failed activation retired guards'
      git checkout HEAD -- .claude/settings.json
    done
    conflict_home="$TMP/codex-rules-conflict"
    conflict_path="$conflict_home/rules/agentic-flow.rules"
    mkdir -p "$conflict_path"
    claude_hooks_before=$(jq -c .hooks .claude/settings.json)
    CODEX_HOME="$conflict_home" migrate_guards "$ADOPTER_TWIN_SOURCE" "$PWD" "$scopes" \
      > "$TMP/rules-conflict.out" 2>&1 && fail 'migration completed without installing Codex rules'
    grep -q 'pending: command policy not active' "$TMP/rules-conflict.out" \
      || fail 'migration did not report the conflicting Codex rules path'
    [ "$claude_hooks_before" = "$(jq -c .hooks .claude/settings.json)" ] &&
      [ "$codex_before" = "$(cksum .codex/hooks.json)" ] &&
      [ -z "$(ls -A "$conflict_path")" ] || fail 'conflicting Codex rules path changed the guards or destination'
    must_block "$PWD/scripts/hooks/block-push.sh" 'git push'
    must_block "$PWD/scripts/hooks/block-git-add-all.sh" 'git add -A'
    must_block "$PWD/scripts/hooks/require-step-comment.sh" 'gh issue edit 1 --add-label needs-review'
    must_block "$PWD/scripts/hooks/scan-secrets.sh" 'git commit -m probe'

    git config --local core.hooksPath custom-broken
    migrate_guards "$ADOPTER_TWIN_SOURCE" "$PWD" "$scopes" \
      > "$TMP/custom-hook-upgrade.out" 2>&1 && fail 'unproven custom hook path completed migration'
    grep -q 'custom core.hooksPath (custom-broken) kept' "$TMP/custom-hook-upgrade.out" \
      || fail 'upgrade did not report the custom hook path'
    [ "$(git config --local --get core.hooksPath)" = custom-broken ] \
      || fail 'upgrade replaced the custom hook path'
    jq -e 'any(.hooks.PreToolUse[]?.hooks[]?; .command | endswith("/scripts/hooks/scan-secrets.sh"))' \
      .claude/settings.json >/dev/null || fail 'upgrade retired the scanner behind a broken custom hook'
  )
fi

if [ -f "$ROOT/scripts/export.sh" ]; then
  # Scenario 8. Start with the customized twin and its installed 0.19.0 entry point.
  upstream_started=$(self_test_now)
  adopter_twin_build
  (
    cd "$ADOPTER_TWIN"
    for legacy_file in scripts/agentic-flow scripts/lib/payload-apply.sh; do
      git -C "$ROOT" show "3a8930a:$legacy_file" > "$legacy_file"
    done
    record=.agentic-flow-upstream
    assert_no_file "$record"

    twin_upgrade() {
      scripts/agentic-flow upgrade --yes > "$TMP/upstream-upgrade.out" 2>&1 \
        || { cat "$TMP/upstream-upgrade.out" >&2; fail 'upstream tracking upgrade failed'; }
    }
    twin_upstream_hash() {
      shasum -a 256 "$ADOPTER_TWIN_SOURCE/$1" | cut -d ' ' -f 1
    }
    twin_release() {
      git -C "$ADOPTER_TWIN_SOURCE" add -- "$@"
      git -C "$ADOPTER_TWIN_SOURCE" commit -qm 'Release upstream tracking fixture'
    }

    twin_upgrade
    offered=$(twin_upstream_hash templates/harness/CLAUDE.md)
    grep -Fxq "offered=$offered  CLAUDE.md" "$record" \
      || fail 'legacy entry did not record the upstream candidate'
    cmp -s CLAUDE.md.agentic-new "$ADOPTER_TWIN_SOURCE/templates/harness/CLAUDE.md" \
      || fail 'legacy entry did not offer the changed upstream bytes'
    # Complete the tool upgrade before invoking a flag the 0.19.0 CLI never parsed.
    for tool in scripts/agentic-flow scripts/lib/payload-apply.sh; do
      mv "$tool.agentic-new" "$tool"
    done
    printf 'accepted=%s  obsolete-payload-file\n' "$offered" >> "$record"
    printf 'accepted=%s  ../outside-payload\n' "$offered" >> "$record"
    before=$(tree_digest "$PWD")
    scripts/agentic-flow upgrade --yes > "$TMP/upstream-unsafe.out" 2>&1 \
      && fail 'upgrade accepted a traversal in the upstream record'
    grep -q 'unsafe.*path' "$TMP/upstream-unsafe.out" && [ "$before" = "$(tree_digest "$PWD")" ] \
      || fail 'upgrade did not reject the unsafe path before changing the adopter'
    sed '$d' "$record" > "$record.next"
    mv "$record.next" "$record"
    before=$(tree_digest "$PWD")
    scripts/agentic-flow upgrade --merged templates/ci/README.md > "$TMP/upstream-no-candidate.out" 2>&1 \
      && fail 'upgrade acknowledged a path with no candidate'
    if ! grep -q 'no candidate' "$TMP/upstream-no-candidate.out" || [ "$before" != "$(tree_digest "$PWD")" ]; then
      cat "$TMP/upstream-no-candidate.out" >&2
      fail 'upgrade did not reject the missing candidate before changing the adopter'
    fi

    printf '\nAdopter reconciled the first upstream release.\n' >> CLAUDE.md
    scripts/agentic-flow upgrade --merged CLAUDE.md > "$TMP/upstream-merged.out" \
      || fail 'explicit acknowledgment of a hand merge failed'
    assert_no_file CLAUDE.md.agentic-new
    grep -Fxq "accepted=$offered  CLAUDE.md" "$record" \
      || fail 'explicit acknowledgment did not accept the offered hash'
    # Keep the twin's other customizations and its generated docs index.
    rm -- Makefile.agentic-new .claude/settings.json.agentic-new .codex/hooks.json.agentic-new docs/README.md.agentic-new
    candidate_version=$(cat .agentic-flow-candidate-version)
    twin_upgrade
    if ! grep -q 'kept *CLAUDE.md$' "$TMP/upstream-upgrade.out" ||
      ! grep -q 'kept *Makefile$' "$TMP/upstream-upgrade.out"; then
      fail 'retry did not keep both explicitly and implicitly acknowledged customizations'
    fi
    grep -Fxq "accepted=$(twin_upstream_hash templates/harness/Makefile)  Makefile" "$record" \
      || fail 'deleting a candidate did not accept its upstream hash'
    if grep -q 'obsolete-payload-file' "$record"; then fail 'upgrade retained an obsolete upstream entry'; fi
    grep -Fxq "$candidate_version" .agentic-flow-version \
      || { cat "$TMP/upstream-upgrade.out" >&2; fail 'retry did not advance the installed version'; }
    assert_no_file .agentic-flow-candidate-version
    assert_no_file CLAUDE.md.agentic-new
    customized=$(shasum -a 256 CLAUDE.md | cut -d ' ' -f 1)
    grep -Fxq "file=$customized  CLAUDE.md" .agentic-flow-installation \
      || fail 'retry did not record the hand-merged file as installed'
    if ! grep -Fxq 'origin=upgrade' .agentic-flow-ownership ||
      grep -Eq '^candidate=.*  (CLAUDE|Makefile).*\.agentic-new' .agentic-flow-ownership; then
      fail 'retry retained ownership rows for removed candidates'
    fi

    upstream="$ADOPTER_TWIN_SOURCE/templates/harness/CLAUDE.md"
    { cat "$upstream"; printf '\n'; } > "$upstream.next"
    mv "$upstream.next" "$upstream"
    pristine=templates/ci/README.md
    printf 'Updated CI notes.\n' > "$ADOPTER_TWIN_SOURCE/$pristine.next"
    mv "$ADOPTER_TWIN_SOURCE/$pristine.next" "$ADOPTER_TWIN_SOURCE/$pristine"
    twin_release templates/harness/CLAUDE.md "$pristine"
    twin_upgrade
    cmp -s "$upstream" CLAUDE.md.agentic-new && grep -Fxq "$candidate_version" .agentic-flow-version &&
      [ "$customized" = "$(shasum -a 256 CLAUDE.md | cut -d ' ' -f 1)" ] \
      || fail 'whitespace-only upstream change did not preserve and offer a merge for the customized file'
    cmp -s "$ADOPTER_TWIN_SOURCE/$pristine" "$pristine" \
      || fail 'upgrade did not overwrite a pristine file'

    printf '10.1.0\n' > "$ADOPTER_TWIN_SOURCE/VERSION.next"
    mv "$ADOPTER_TWIN_SOURCE/VERSION.next" "$ADOPTER_TWIN_SOURCE/VERSION"
    twin_release VERSION
    twin_upgrade
    grep -q 'CLAUDE.md.agentic-new .*pending' "$TMP/upstream-upgrade.out" &&
      grep -Fxq "$candidate_version" .agentic-flow-version &&
      [ "$(find . -name 'CLAUDE.md.agentic-new*' | wc -l)" -eq 1 ] \
      || fail 'unchanged unresolved upstream did not stay pending without a duplicate candidate'

    printf '\nNext upstream guidance.\n' >> "$upstream"
    twin_release templates/harness/CLAUDE.md
    twin_upgrade
    newest="CLAUDE.md.agentic-new.$(cat .agentic-flow-candidate-version)"
    cmp -s "$upstream" "$newest" || fail 'new upstream did not produce a versioned candidate'
    mv CLAUDE.md.agentic-new "$TMP/older-candidate"
    twin_upgrade
    if ! grep -Fq "$newest   (pending" "$TMP/upstream-upgrade.out" ||
      ! grep -Fxq "$candidate_version" .agentic-flow-version; then
      fail 'deleting only the older candidate acknowledged the unresolved offer'
    fi
    mv "$TMP/older-candidate" CLAUDE.md.agentic-new
    scripts/agentic-flow upgrade --merged CLAUDE.md > "$TMP/upstream-merged.out" \
      || fail 'upgrade did not acknowledge the newest of two candidates'
    assert_no_file CLAUDE.md.agentic-new
    assert_no_file "$newest"
    if ! grep -Fxq '  removed    CLAUDE.md.agentic-new' "$TMP/upstream-merged.out" ||
      ! grep -Fxq "  removed    $newest" "$TMP/upstream-merged.out" ||
      ! grep -Fxq "accepted=$(twin_upstream_hash templates/harness/CLAUDE.md)  CLAUDE.md" "$record"; then
      fail 'acknowledgment did not list both candidates and accept the newest hash'
    fi
  )
  upstream_seconds=$(( $(self_test_now) - upstream_started ))
  measure_event "group:upgrade:upstream:$upstream_seconds"
  check_wall_ceiling upgrade:upstream "$upstream_seconds"
fi
