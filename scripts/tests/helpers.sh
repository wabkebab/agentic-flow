#!/usr/bin/env bash
# Sourced by self-test.sh; shared fixture context is intentional.
# shellcheck disable=SC1091,SC2034,SC2153,SC2164,SC2329 # Dispatcher globals (including ROOT), indirect fixture calls, inherited errexit.
source_snapshot() {
  [ -z "${SOURCE_SNAPSHOT:-}" ] || return 0
  SOURCE_SNAPSHOT="$TMP/source-snapshot"
  mkdir -p "$SOURCE_SNAPSHOT"
  measure_event source_snapshot_copy
  measure_event fixture_tree_copy
  local tracked
  while IFS= read -r -d '' tracked; do
    [ -e "$ROOT/$tracked" ] || continue
    mkdir -p "$SOURCE_SNAPSHOT/$(dirname "$tracked")"
    command cp -p "$ROOT/$tracked" "$SOURCE_SNAPSHOT/$tracked"
  done < <(cd "$ROOT" && git ls-files -co --exclude-standard -z)
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

# Shared by stations and recovery, including the approved red-first paths.
# shellcheck disable=SC2034 # Sourced ledger consumes fixture context.
controller_salvage_ledger_tests() (
  local fixture run=fixture/1/0/executor/1/1 before clear
  fixture=$(mktemp -d "$TMP/controller-salvage-ledger.XXXXXX") || fail 'salvage ledger fixture creation failed'
  # shellcheck disable=SC1091
  . "$ROOT/scripts/lib/ledger.sh"
  LEDGER_DIR="$fixture/ledger"
  jq -n --arg run "$run" '{v:1,kind:"intent",run:$run,chain:"fixture/1/0/executor/1",replaces:null,
    reason:"initial",plan:"fixture",issue:1,step:"alpha",station:"executor",cli:"codex",model:"fixture",
    resume_of:null,session:null,session_mode:"new",reassigned_from:null,seq_before:0,
    base_head:("a"*40),packet_sha256:("b"*64),started:1,host:"fixture"}' > "$fixture/intent"
  ledger_intent fixture "$fixture/intent" >/dev/null || fail 'salvage ledger intent failed'
  jq -n --arg run "$run" '{v:1,kind:"salvage",run:$run,chain:"fixture/1/0/executor/1",
    ref:("refs/agentic-flow/salvage/"+$run),head:("a"*40),index_commit:("b"*40),worktree_commit:("c"*40),
    index_tree:("d"*40),worktree_tree:("e"*40),paths:[],at:2}' > "$fixture/original"
  ledger_salvage fixture "$fixture/original" >/dev/null || fail 'original salvage append failed'
  before=$(shasum "$LEDGER_DIR/fixture.jsonl")
  ledger_salvage fixture "$fixture/original" > "$fixture/error" 2>&1 && fail 'duplicate ordinary salvage accepted'
  jq '.rebaseline="fixture/hold/1"|.ref+="-rebaseline"|.head=("f"*40)' "$fixture/original" > "$fixture/rebaseline"
  ledger_salvage fixture "$fixture/rebaseline" > "$fixture/error" 2>&1 && fail 'salvage accepted missing clear'
  [ "$before" = "$(shasum "$LEDGER_DIR/fixture.jsonl")" ] || fail 'rejected salvage changed ledger'
  jq -n '{v:1,kind:"end",chain:"fixture/1/0/executor/1",how:"held",hold:null,at:3}' > "$fixture/end"
  ledger_end fixture "$fixture/end" >/dev/null || fail 'salvage chain end failed'
  # A plain clear cannot authorize a second snapshot of an owned run.
  for clear in 1 2 3; do
    jq -n --arg id "fixture/hold/$clear" --arg run "$run" '{v:1,kind:"hold",plan:"fixture",hold:$id,
      issue:1,reason:"worktree-changed-after-salvage",run:$run,comment_id:null,at:3}' > "$fixture/hold"
    ledger_hold fixture "$fixture/hold" >/dev/null || fail 'salvage hold append failed'
    jq -n --arg id "fixture/hold/$clear" --argjson flagged "$(if [ "$clear" = 1 ]; then echo false; else echo true; fi)" '
      {v:1,kind:"clear",plan:"fixture",hold:$id,by:"approver",note:"resolved",rebaseline:$flagged,at:4}' > "$fixture/clear"
    ledger_clear fixture "$fixture/clear" >/dev/null || fail 'salvage clear append failed'
    jq --arg id "fixture/hold/$clear" '.rebaseline=$id|.ref+=$id' "$fixture/rebaseline" > "$fixture/next"
    if [ "$clear" = 1 ]; then
      ledger_salvage fixture "$fixture/next" > "$fixture/error" 2>&1 && fail 'salvage accepted plain clear'
    else
      ledger_salvage fixture "$fixture/next" >/dev/null || fail 'authorized rebaseline rejected for owned run'
      before=$(shasum "$LEDGER_DIR/fixture.jsonl")
      ledger_salvage fixture "$fixture/next" > "$fixture/error" 2>&1 && fail 'clear authorized two salvages'
      # The same clear cannot be consumed again under an orphan run either.
      jq '.orphan=true|.chain=null|.run=("fixture/unowned/"+("a"*24))' "$fixture/next" > "$fixture/orphan"
      ledger_salvage fixture "$fixture/orphan" > "$fixture/error" 2>&1 && fail 'clear reused for orphan salvage'
      [ "$before" = "$(shasum "$LEDGER_DIR/fixture.jsonl")" ] || fail 'duplicate rebaseline changed ledger'
    fi
  done
  ledger_read fixture | jq -e '[.[]|select(.kind=="salvage")]|length==3 and .[0].rebaseline==null and
    .[0].head==("a"*40) and .[1].rebaseline=="fixture/hold/2" and .[2].rebaseline=="fixture/hold/3"' >/dev/null || fail 'rebaseline ledger lost original/history'
)

# shellcheck disable=SC2030,SC2031,SC2034,SC2329 # Sourced controller consumes fixture context.
controller_reuse_tests() (
  local fixture head base resumed_base key plan source_file
  local verify_run=fixture/1/2/executor/1/1 original_record recorded_verification
  fixture=$(mktemp -d "$TMP/controller-verify-reuse.XXXXXX") || fail 'controller cache fixture creation failed'
  mkdir -p "$fixture/scripts"
  git -C "$fixture" init -q
  git -C "$fixture" config user.name Fixture
  git -C "$fixture" config user.email fixture@example.invalid
  git -C "$fixture" config commit.gpgsign false
  printf 'check:\n\t@:\n' > "$fixture/Makefile"
  git -C "$fixture" add Makefile
  git -C "$fixture" commit -qm 'Controller cache fixture'
  base=$(git -C "$fixture" rev-parse HEAD)
  git -C "$fixture" commit --allow-empty -qm 'Implementation before human resume'
  resumed_base=$(git -C "$fixture" rev-parse HEAD)
  git -C "$fixture" commit --allow-empty -qm 'Implementation after human resume'
  head=$(git -C "$fixture" rev-parse HEAD)
  CT_WORKTREE=$fixture CT_COMMON="$fixture/.git" CT_DOC=docs/plan.md CT_TMP="$fixture/tmp"
  mkdir -p "$CT_TMP" "$CT_COMMON/agentic-flow/verify"
  # shellcheck disable=SC1091
  . "$ROOT/scripts/lib/controller.sh"
  # shellcheck disable=SC2016 # Brief commands use literal Markdown backticks.
  CT_SPEC='{"steps":[{"id":"alpha","packet":{"verification":"`make focused`"},"red_first":null}]}'
  CT_RECORDS=$(jq -nc --arg head "$head" --arg base "$base" --arg resumed_base "$resumed_base" --arg run "$verify_run" '[
    {kind:"intent",run:"fixture/2/0/executor/1/1",issue:2,station:"executor",step:"beta",base_head:$resumed_base},
    {kind:"intent",run:"fixture/1/0/reviewer/1/1",issue:1,station:"reviewer",step:"alpha",base_head:$resumed_base},
    {kind:"intent",run:"fixture/1/0/executor/1/1",issue:1,station:"executor",step:"alpha",base_head:$base},
    {kind:"intent",run:$run,issue:1,station:"executor",step:"alpha",base_head:$resumed_base},
    {kind:"station",run:$run,result:{outcome:"submitted",head:$head}}] |
    map(if .kind=="intent" then .+{plan:"fixture"} else . end) |
    [{kind:"intent",plan:"foreign",run:"foreign/1/0/executor/1/1",issue:1,station:"executor",step:"alpha",base_head:$resumed_base}] + .')
  CT_REPORT='{"issues":[{"number":1}]}'
  plan=$(verify_record_plan "$(printf '%s' "$CT_SPEC" | jq -c '.steps[0]')")
  key=$(cd "$fixture" && verify_record_key "$head" "$CT_DOC" alpha "$base" "$plan") || fail 'controller cache key failed'
  source_file="$CT_COMMON/agentic-flow/verify/$head.json"
  original_record=$(printf '%s' "$key" | jq '.+{passed:true,prepare:{role:"prepare",exit:0},red_first:"not-declared",
    commands:[{cmd:"make check",role:"green",exit:0},{cmd:"make focused",role:"green",exit:0}]} |
    .verifier.signature_source.pattern=""') || fail 'controller cache record creation failed'
  printf '%s\n' "$original_record" > "$source_file"
  cat > "$fixture/scripts/agentic-flow" <<'VERIFY_STUB'
#!/usr/bin/env bash
touch verifier-launched
printf '%s\n' "$@" > verifier-args
exit 1
VERIFY_STUB
  chmod +x "$fixture/scripts/agentic-flow"
  controller_head_valid() { return 0; }
  controller_record() { recorded_verification=$(cat "$CT_TMP/record"); }
  controller_fault() { :; }
  # A resumed execution base already contains the implementation. Never reuse
  # its weaker red-first evidence, even though it matches the current intent.
  jq --arg base "$resumed_base" '.red_base=$base' "$source_file" > "$fixture/weaker-record"
  cat "$fixture/weaker-record" > "$source_file"
  controller_verify "$verify_run" || fail 'controller resumed verification failed'
  [ -f "$fixture/verifier-launched" ] || fail 'controller reused verification against resumed execution base'
  [ "$(sed -n '/^--red-base$/{n;p;}' "$fixture/verifier-args")" = "$base" ] || fail 'controller reran against resumed execution base'
  printf '%s' "$recorded_verification" | jq -e '.status=="red" and .reused==false' >/dev/null || fail 'controller resumed fallback not recorded'
  printf '%s\n' "$original_record" > "$source_file"
  rm "$fixture/verifier-launched"
  controller_verify "$verify_run" || fail 'controller cache verification failed'
  [ ! -f "$fixture/verifier-launched" ] || fail 'controller launched verifier for fresh record'
  printf '%s' "$recorded_verification" | jq -e '.kind=="verify" and .status=="green" and .reused==true' >/dev/null || fail 'controller did not ledger reuse'
  jq '.passed=false' "$source_file" > "$fixture/failed"
  cat "$fixture/failed" > "$source_file"
  controller_verify "$verify_run" || fail 'controller failed record path failed'
  [ -f "$fixture/verifier-launched" ] || fail 'controller reused failed record'
  printf '%s' "$recorded_verification" | jq -e '.status=="red" and .reused==false' >/dev/null || fail 'controller fallback not recorded'
  # With no earlier attempt of this plan/step, its own base remains authoritative.
  CT_RECORDS=$(printf '%s' "$CT_RECORDS" | jq --arg run "$verify_run" '[.[]|select(.kind!="intent" or .plan!="fixture" or .issue!=1 or .station!="executor" or .run==$run)]')
  controller_verify "$verify_run" || fail 'first attempt verification failed'
  [ "$(sed -n '/^--red-base$/{n;p;}' "$fixture/verifier-args")" = "$resumed_base" ] || fail 'first attempt borrowed another plan base'
)

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

# Both everyday export assertions and the close-out gate build the same layout.
fresh_export() { # <source checkout> <destination>
  "$1/scripts/export.sh" "$2" >/dev/null
}

# Source-only holdout: full runs reuse the last pristine export; focused groups
# build it once. Resets use Git, never another tree copy. The local upgrade source
# shares the suite's immutable snapshot but owns its Git metadata.
adopter_twin_build() { # [existing pristine export]
  local copies_before
  copies_before=$(cost_count "$LOCAL_EVENTS" fixture_file_copy)
  if [ -n "${ADOPTER_TWIN:-}" ]; then
    git -C "$ADOPTER_TWIN" reset --hard -q HEAD
    git -C "$ADOPTER_TWIN" clean -fdq
    return
  fi
  source_snapshot
  ADOPTER_TWIN_SOURCE="$TMP/adopter-twin-source"
  link_snapshot_files "$ADOPTER_TWIN_SOURCE"
  local source_file adapter
  local -a source_files=()
  while IFS= read -r -d '' source_file; do
    source_files+=("${source_file#"$ADOPTER_TWIN_SOURCE/"}")
  done < <(find "$ADOPTER_TWIN_SOURCE" -type f -print0)
  (
    cd "$ADOPTER_TWIN_SOURCE"
    git init -q
    git config user.name 'Adopter fixture'
    git config user.email adopter@example.invalid
    git config commit.gpgsign false
    git add -- "${source_files[@]}"
    git commit -qm 'Seed offline adopter upgrade source'
    git branch -M main
  )
  ADOPTER_TWIN=${1:-"$TMP/adopter twin"}
  if [ ! -d "$ADOPTER_TWIN" ]; then
    fresh_export "$ADOPTER_TWIN_SOURCE" "$ADOPTER_TWIN"
  fi
  sed 's/^test:/test-adopter:/; s/^build:/package:/; s/^run:/serve:/;
    s/^\.PHONY: check test test-one build run help$/.PHONY: check test-adopter test-one package serve help/' \
    "$ADOPTER_TWIN/Makefile" > "$TMP/adopter-makefile"
  cat "$TMP/adopter-makefile" > "$ADOPTER_TWIN/Makefile"
  cat >> "$ADOPTER_TWIN/Makefile" <<'ADOPTER_MAKE'

.PHONY: test-adopter package serve adopter-lint commit-adopter
check: adopter-lint
adopter-lint:
	@test ! -e .adopter-check-fails
commit-adopter:
	@git -c commit.gpgsign=false commit -F .adopter-commit-message
ADOPTER_MAKE
  cat >> "$ADOPTER_TWIN/CLAUDE.md" <<'ADOPTER_DOC'

## Adopter stack profile
Run `make test-adopter` for application tests, `make package` for a release,
and `make serve` for development. `make check` also runs `adopter-lint`.
Commit reviewed changes with `make commit-adopter`, reading the message from
`.adopter-commit-message`. This project keeps its own deployment targets.
ADOPTER_DOC
  for adapter in .claude/settings.json .codex/hooks.json; do
    jq '.hooks.PreToolUse += [{matcher:"Bash",hooks:[{type:"command",command:"test -f CLAUDE.md"}]}] |
        .hooks.Stop += [{hooks:[{type:"command",command:"test -f Makefile"}]}]' \
      "$ADOPTER_TWIN/$adapter" > "$TMP/adopter-hooks"
    cat "$TMP/adopter-hooks" > "$ADOPTER_TWIN/$adapter"
  done
  printf 'origin file://%s\nref main\n' "$ADOPTER_TWIN_SOURCE" > "$ADOPTER_TWIN/.agentic-flow-source"
  printf 'older-adopter\n' > "$ADOPTER_TWIN/.agentic-flow-version"
  (
    cd "$ADOPTER_TWIN"
    git init -q
    git config user.name 'Adopter fixture'
    git config user.email adopter@example.invalid
    git config commit.gpgsign false
    source_files=()
    while IFS= read -r -d '' source_file; do source_files+=("$source_file"); done \
      < <(git ls-files --others --exclude-standard -z)
    git add -- "${source_files[@]}"
    git commit -qm 'Seed customized adopter project'
  )
  [ "$copies_before" = "$(cost_count "$LOCAL_EVENTS" fixture_file_copy)" ] \
    || fail 'adopter twin added fixture file copies'
}

adopter_twin_preserved() (
  cd "$ADOPTER_TWIN"
  git diff --exit-code HEAD -- CLAUDE.md Makefile .claude/settings.json .codex/hooks.json \
    .agentic-flow-version .agentic-flow-installation >/dev/null \
    || fail 'adopter twin lost project customizations or installed state'
)

adopter_twin_check() (
  cd "$ADOPTER_TWIN"
  # Failure first: the customized prerequisite must actually participate in check.
  touch .adopter-check-fails
  make check > "$TMP/adopter-check-red.out" 2>&1 \
    && fail 'adopter twin make check ignored the customized lint target'
  rm .adopter-check-fails
  make check > "$TMP/adopter-check.out" 2>&1 \
    || { cat "$TMP/adopter-check.out" >&2; fail 'make check failed in the adopter twin'; }
)
