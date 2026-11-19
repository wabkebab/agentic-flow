#!/usr/bin/env bash
# Sourced by self-test.sh; shared fixture context is intentional.
# shellcheck disable=SC1091,SC2034,SC2153,SC2164,SC2329 # Dispatcher globals (including ROOT), indirect fixture calls, inherited errexit.
# Run installed guards with adopter commands and a real staged diff. The full
# suite reuses export's twin; standalone hook runs build the same fixture once.
if [ -f "$ROOT/scripts/export.sh" ]; then
  adopter_twin_build
  (
    cd "$ADOPTER_TWIN"
    twin_hooks="$ADOPTER_TWIN/scripts/hooks"
    for twin_adapter in .claude/settings.json .codex/hooks.json; do
      jq -e 'any(.hooks.PreToolUse[]?.hooks[]?; .command=="test -f CLAUDE.md") and
        any(.hooks.Stop[]?.hooks[]?; .command=="test -f Makefile")' "$twin_adapter" >/dev/null \
        || fail "adopter twin lost extra hooks in $twin_adapter"
    done
    must_block "$twin_hooks/block-git-add-all.sh" 'git add -A'
    must_allow "$twin_hooks/block-git-add-all.sh" 'git add CLAUDE.md Makefile'
    must_block "$twin_hooks/block-push.sh" 'git push origin main'
    must_allow "$twin_hooks/block-push.sh" 'make test-adopter'
    must_allow "$twin_hooks/require-step-comment.sh" 'make adopter-lint'
    "$twin_hooks/session-context.sh" > "$TMP/adopter-session.out" 2>&1 \
      || fail 'adopter twin session hook failed without an active plan'

    touch .adopter-check-fails
    twin_status=0
    printf '{"stop_hook_active":false}' | "$twin_hooks/check-gate.sh" \
      > "$TMP/adopter-stop-red.out" 2>&1 || twin_status=$?
    [ "$twin_status" -eq 2 ] || fail 'adopter twin Stop hook allowed a failing customized check'
    rm .adopter-check-fails
    printf '{"stop_hook_active":false}' | "$twin_hooks/check-gate.sh" \
      > "$TMP/adopter-stop.out" 2>&1 \
      || { cat "$TMP/adopter-stop.out" >&2; fail 'adopter twin Stop hook blocked a green customized check'; }

    printf 'aws_key = "%s"\n' "$(printf 'AKIA%s' 'IOSFODNN7EXAMPLE')" > .adopter-change
    git add .adopter-change
    must_block "$twin_hooks/scan-secrets.sh" 'git -c commit.gpgsign=false commit -F .adopter-commit-message'
    git reset -q HEAD -- .adopter-change
    printf 'Reviewed adopter change\n' > .adopter-change
    git add .adopter-change
    cat > .adopter-commit-message <<'ADOPTER_COMMIT'
Document the adopter's release process

Run `make check`, then `make test-adopter` and `make package` before release.
ADOPTER_COMMIT
    twin_command='git -c commit.gpgsign=false commit -F .adopter-commit-message'
    # shellcheck disable=SC2016 # Literal heredoc input exercises historical #110.
    twin_heredoc=$'git -c commit.gpgsign=false commit -F - <<\'MSG\'\nRun `make check` before release.\nMSG'
    for twin_guard in block-git-add-all block-push scan-secrets require-step-comment; do
      must_allow "$twin_hooks/$twin_guard.sh" "$twin_command"
      must_allow "$twin_hooks/$twin_guard.sh" "$twin_heredoc"
    done
    make commit-adopter > "$TMP/adopter-commit.out" 2>&1 \
      || { cat "$TMP/adopter-commit.out" >&2; fail 'adopter twin could not execute its real commit command'; }
    git log -1 --format=%B > "$TMP/adopter-commit-body"
    # shellcheck disable=SC2016 # Assert literal Markdown, never shell expansion.
    grep -Fq 'Run `make check`, then `make test-adopter` and `make package`' "$TMP/adopter-commit-body" \
      || fail 'adopter twin commit lost its literal message'
  )
fi

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

# Session context must be shipped and wired in both adapters.
[ -x "$ROOT/scripts/hooks/session-context.sh" ] || fail 'session context hook is missing'
for session_adapter in .claude/settings.json .codex/hooks.json; do
  jq -e '.hooks.SessionStart[]?.hooks[]? | select(.command | contains("scripts/hooks/session-context.sh"))' "$ROOT/$session_adapter" >/dev/null \
    || fail "SessionStart is not wired in $session_adapter"
done

SESSION_FIX="$TMP/session-context"
mkdir -p "$SESSION_FIX/docs/inprogress" "$SESSION_FIX/scripts"
ln -s "$ROOT/scripts/lib" "$SESSION_FIX/scripts/lib"
git -C "$SESSION_FIX" init -q
git -C "$SESSION_FIX" checkout -qb topic
cat > "$SESSION_FIX/docs/inprogress/plan.md" <<'SESSION'
# Feature — Session
# Part B — Implementation Brief
```agentic-flow-plan
id: session
profile: strict
tracking: Plan: Session
branch: topic
steps: s-1 s-2
```
## S-1 — First
**DoD:** done
**Verify:** `make check`
**Red-first:** none
**Risks:** risk
## S-2 — Second
**DoD:** done
**Verify:** `make check`
**Red-first:** none
**Risks:** risk
SESSION
session_run() { (cd "$SESSION_FIX" && "$ROOT/scripts/hooks/session-context.sh"); }
session_quiet() {
  session_run > "$TMP/session.out" 2> "$TMP/session.err" || fail 'session hook blocked'
  [ ! -s "$TMP/session.out" ] && [ ! -s "$TMP/session.err" ] || fail "session hook noisy: $1"
}
session_quiet 'missing cache'
mkdir -p "$SESSION_FIX/.git/agentic-flow/state"
SESSION_CACHE="$SESSION_FIX/.git/agentic-flow/state/session.tsv"
printf 'corrupt\n' > "$SESSION_CACHE"
session_quiet 'corrupt cache'
printf '1\ts-1\tapproved\tnone\tnone\t2026-11-14T12:00:00Z\n2\ts-2\texecuting\tnone\tnone\t2026-11-14T12:00:00Z\n' > "$SESSION_CACHE"
session_run > "$TMP/session.out" || fail 'session context failed'
for expected in 'Plan: session' 'Doc: docs/inprogress/plan.md' 'Open step: s-2 (#2)' 'State: executing (cached)' 'Next command: scripts/agentic-flow brief docs/inprogress/plan.md s-2'; do
  grep -Fq "$expected" "$TMP/session.out" || fail "session context omitted $expected"
done
[ "$(wc -w < "$TMP/session.out")" -le 120 ] || fail 'session context exceeded word limit'
cp "$SESSION_CACHE" "$TMP/session-cache"
cat "$TMP/session-cache" >> "$SESSION_CACHE"
session_quiet 'duplicate cache rows'
cat "$TMP/session-cache" > "$SESSION_CACHE"
sed 's/executing/reviewing/' "$TMP/session-cache" > "$SESSION_CACHE"
session_run > "$TMP/session.out" || fail 'reviewing session failed'
grep -Fq 'State: reviewing (cached)' "$TMP/session.out" || fail 'reviewing state omitted'
sed 's/executing/escalated/' "$TMP/session-cache" > "$SESSION_CACHE"
session_run > "$TMP/session.out" || fail 'escalated session failed'
grep -Fq 'Next command: scripts/agentic-flow handoff 2 resume --as approver' "$TMP/session.out" \
  || fail 'escalated session omitted approver resume guidance'
sed 's/executing/approved/' "$TMP/session-cache" > "$SESSION_CACHE"
session_quiet 'all steps approved'
head -n 1 "$TMP/session-cache" > "$SESSION_CACHE"
session_quiet 'incomplete cache'
cat "$TMP/session-cache" > "$SESSION_CACHE"
cp "$SESSION_FIX/docs/inprogress/plan.md" "$SESSION_FIX/docs/inprogress/duplicate.md"
session_quiet 'ambiguous branch'
rm "$SESSION_FIX/docs/inprogress/duplicate.md"
git -C "$SESSION_FIX" symbolic-ref HEAD refs/heads/main
session_quiet 'main branch'
# A detached HEAD can point at an existing object without requiring a fixture commit.
SESSION_TREE=$(git -C "$SESSION_FIX" mktree < /dev/null)
SESSION_COMMIT=$(printf 'session fixture\n' | git -C "$SESSION_FIX" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit-tree "$SESSION_TREE")
git -C "$SESSION_FIX" update-ref --no-deref HEAD "$SESSION_COMMIT"
session_quiet 'detached HEAD'
git -C "$SESSION_FIX" symbolic-ref HEAD refs/heads/topic
mkdir -p "$TMP/session-nojq"
for session_tool in bash perl git; do ln -s "$(command -v "$session_tool")" "$TMP/session-nojq/$session_tool"; done
(cd "$SESSION_FIX" && PATH="$TMP/session-nojq" "$ROOT/scripts/hooks/session-context.sh") > "$TMP/session.out" 2> "$TMP/session.err" \
  || fail 'missing jq blocked session'
[ ! -s "$TMP/session.out" ] && [ ! -s "$TMP/session.err" ] || fail 'missing jq was noisy'
# Even a hung local helper is killed within the hook bound, with no output.
mkdir -p "$TMP/session-slow"
printf '#!/bin/sh\nexec /bin/sleep 5\n' > "$TMP/session-slow/git"
chmod +x "$TMP/session-slow/git"
SESSION_START=$SECONDS
(cd "$SESSION_FIX" && PATH="$TMP/session-slow:$PATH" "$ROOT/scripts/hooks/session-context.sh") > "$TMP/session.out" 2> "$TMP/session.err" \
  || fail 'slow helper blocked session'
[ $((SECONDS - SESSION_START)) -le 2 ] || fail 'session hook exceeded timeout bound'
[ ! -s "$TMP/session.out" ] && [ ! -s "$TMP/session.err" ] || fail 'timeout emitted partial context'

# --- Stop gate (check-gate.sh) -----------------------------------------------------------
# The highest-leverage hook and previously untested (ROADMAP 1.5.4). All four paths matter:
# a green check must not block, a red one must, the loop-safety escape must fire on the
# retry, and the no-Makefile path must stay out of the way.
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

  # A verified dirty fix cannot certify the broken committed tree beneath it.
  gate_makefile 'exit 1'
  (cd "$GATEFIX" && git add Makefile && git commit -q --no-gpg-sign -m "fixture") >/dev/null 2>&1 \
    || fail "gate fixture commit failed (git exit $?) — fixture is not hermetic"
  gate_makefile true
  gate_run false || fail "Stop gate blocked the uncommitted fix"
  (cd "$GATEFIX" && git checkout -- Makefile)
  gate_run false && fail "Stop gate allowed broken clean HEAD after discarding a verified fix"
  gate_run false && fail "Stop gate allowed a red commit on a clean tree"

  # Reuse only the complete state that passed. Keep the counter outside the fixture:
  # writing it inside would itself change the tree being measured.
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

  # Mutation fixtures keep their counters outside the tree being hashed.
  gate_reset() {
    rm -f "$GATEFIX/.git/agentic-flow-check-gate-state" "$GATEFIX/.git/agentic-flow-check-gate-red"
    : > "$GATE_RUNS"
  }
  gate_capture() {
    gate_status=0
    (cd "$GATEFIX" && printf '{"stop_hook_active":%s}' "$1" | "$GATE") >"$TMP/gate-result" 2>&1 || gate_status=$?
    [ "$gate_status" = "$2" ] || fail "Stop gate expected exit $2, got $gate_status"
  }
  gate_stamp="$GATEFIX/.git/agentic-flow-check-gate-state"
  gate_red="$GATEFIX/.git/agentic-flow-check-gate-red"
  gate_mutator() { # once|always|red
    printf 'check:\n\t@echo run >> %s; ' "$GATE_RUNS" > "$GATEFIX/Makefile"
    case "$1" in
      once) printf 'if [ ! -f mutation ]; then echo x > mutation; fi\n' ;;
      always) printf 'echo x >> mutation\n' ;;
      red) printf 'if [ -f mutation ]; then exit 1; fi; echo x > mutation\n' ;;
    esac >> "$GATEFIX/Makefile"
    rm -f "$GATEFIX/mutation"
    gate_reset
  }

  gate_mutator always
  gate_capture false 2
  [ "$(gate_runs)" = 2 ] || fail "changing gate did not stop after two runs"
  [ ! -f "$gate_stamp" ] || fail "changing gate wrote a green stamp"
  grep -q 'tree changed during' "$TMP/gate-result" || fail "missing tree-change diagnostic"

  gate_mutator red
  gate_capture false 2
  [ "$(gate_runs)" = 2 ] || fail "red rerun was not attempted"
  [ ! -f "$gate_stamp" ] || fail "red rerun wrote a green stamp"

  gate_mutator once
  gate_capture false 0
  [ "$(gate_runs)" = 2 ] || fail "one edit did not trigger exactly one rerun"
  [ -s "$gate_stamp" ] || fail "stable rerun did not stamp its final state"
  gate_capture false 0
  [ "$(gate_runs)" = 2 ] || fail "final state stamp did not match the tree"
  saved_green=$(cat "$gate_stamp")
  printf 'check:\n\t@echo run >> %s; exit 1\n' "$GATE_RUNS" > "$GATEFIX/Makefile"
  gate_capture true 0
  [ "$(cat "$gate_stamp")" = "$saved_green" ] || fail "red retry overwrote green stamp"
  [ -s "$gate_red" ] || fail "red retry did not record acknowledged state"
  saved_red=$(cat "$gate_red")
  red_runs=$(gate_runs)
  gate_capture false 0
  [ "$(gate_runs)" = "$red_runs" ] || fail "acknowledged red reran the gate"
  grep -q 'Warning:' "$TMP/gate-result" || fail "acknowledged red skipped silently"
  printf 'changed\n' >> "$GATEFIX/mutation"
  gate_capture false 2
  [ "$(cat "$gate_red")" = "$saved_red" ] || fail "ordinary red stop acknowledged a new state"

  gate_mutator always
  printf '%s\n' "$saved_green" > "$gate_stamp"
  gate_capture true 0
  [ "$(cat "$gate_stamp")" = "$saved_green" ] || fail "changing retry overwrote green stamp"
  [ -s "$gate_red" ] || fail "changing retry did not record its final state"
  gate_capture false 0
  [ "$(gate_runs)" = 2 ] || fail "acknowledged changing state reran the gate"

  rm -f "$GATEFIX/mutation"
  printf 'check:\n\t@echo run >> %s\n' "$GATE_RUNS" > "$GATEFIX/Makefile"
  (cd "$GATEFIX" && git add Makefile && git commit -q --no-gpg-sign -m green)
  gate_reset
  gate_capture false 0
  gate_capture false 0
  [ "$(gate_runs)" = 1 ] || fail "clean green state was not checked exactly once"
  printf 'new tree\n' > "$GATEFIX/committed"
  (cd "$GATEFIX" && git add committed && git commit -q --no-gpg-sign -m moved)
  gate_capture false 0
  [ "$(gate_runs)" = 2 ] || fail "moved clean HEAD reused another tree's stamp"

  # Inject write denial without chmod: this also works under privileged test runners.
  # Pre-existing green records must not bypass the writeability probe.
  probe_bin="$TMP/gate-denied-bin"
  mkdir -p "$probe_bin"
  # Deny the atomic rename for records while preserving normal git operations.
  real_mv=$(command -v mv)
  printf '#!/usr/bin/env bash\ncase "$*" in *agentic-flow-check-gate*) exit 1 ;; esac\nexec "%s" "$@"\n' "$real_mv" > "$probe_bin/mv"
  chmod +x "$probe_bin/mv"
  PATH="$probe_bin:$PATH" gate_capture false 0
  PATH="$probe_bin:$PATH" gate_capture false 0
  [ "$(gate_runs)" = 4 ] || fail "unwritable metadata reused a gate record"

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
mkdir -p "$STEP_HOOK_GH"
cat > "$STEP_HOOK_GH/gh" <<'FAKE_GH'
#!/usr/bin/env bash
[ "${STEP_HOOK_GH_FAIL:-0}" = 0 ] || exit 1
printf '%s\n' "${STEP_HOOK_BODY:-<!-- agentic-flow:plan:fixture step:alpha spec:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->}"
FAKE_GH
chmod +x "$STEP_HOOK_GH/gh"
for mutation in \
  'gh issue edit 1 --add-label needs-review' \
  'rtk gh issue edit --add-label=needs-review 1' \
  'gh -R owner/repo issue edit 1 --remove-label agent:codex' \
  'gh issue edit 1 --add-label "bug,needs-human"' \
  'gh api repos/owner/repo/issues/1 -X PATCH -f labels[]=needs-review' \
  'gh api repos/owner/repo/issues/1/labels -X DELETE' \
  'gh api repos/owner/repo/issues/1 --method PATCH --input file.json' \
  'gh api repos/owner/repo/issues/1 -X PATCH -f state=closed' \
  'scripts/agentic-flow ship docs/inprogress/plan.md' \
  'rtk proxy scripts/agentic-flow ship docs/inprogress/plan.md --wait-review' \
  'bash -lc "scripts/agentic-flow ship docs/inprogress/plan.md"' \
  'scripts/agentic-flow approve docs/inprogress/plan.md --by owner' \
  'scripts/agentic-flow hold clear docs/inprogress/plan.md fixture/hold/1' \
  'scripts/agentic-flow token reviewer' \
  'rtk proxy scripts/agentic-flow token executor' \
  'bash -lc "scripts/agentic-flow token reviewer"' \
  'gh api graphql -f query=mutation' \
  'gh api graphql --input request.json' \
  'bash -c "echo ok"; gh issue edit 1 --add-label needs-review'; do
  must_block "$STEP_HOOK" "$mutation"
done
PATH="$STEP_HOOK_GH:$PATH" must_block "$STEP_HOOK" 'gh issue close 1'
PATH="$STEP_HOOK_GH:$PATH" must_block "$STEP_HOOK" 'gh issue reopen 1'
PATH="$STEP_HOOK_GH:$PATH" STEP_HOOK_GH_FAIL=1 must_block "$STEP_HOOK" 'gh issue close 1'
PATH="$STEP_HOOK_GH:$PATH" STEP_HOOK_BODY='ordinary issue' must_allow "$STEP_HOOK" 'gh issue close 1'
# shellcheck disable=SC2016 # Literal shell input for the hook lexer, never evaluated.
for read_command in \
  'scripts/agentic-flow final-approve docs/done/plan.md' \
  'gh issue view 1 --json body,comments' \
  'rtk gh issue view 127' \
  'bash -lc "n=$(echo 127); gh issue view 127"' \
  'gh issue edit 1 --add-label bug' \
  'gh api repos/owner/repo/issues/1' \
  'gh api repos/owner/repo/issues/1 --method GET' \
  'rg "gh issue edit --add-label needs-review" AGENTS.md' \
  'scripts/agentic-flow handoff 1 submit --as executor --head abc'; do
  must_allow "$STEP_HOOK" "$read_command"
done
