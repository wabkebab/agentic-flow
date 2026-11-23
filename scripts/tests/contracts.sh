#!/usr/bin/env bash
# Sourced by self-test.sh; shared fixture context is intentional.
# shellcheck disable=SC1091,SC2030,SC2034,SC2153,SC2164,SC2329 # Intentional fixture subshells and dispatcher context.

# Flow ergonomics scenario 8. Parse the pinned action's single-quoted filter lists.
ci_bookkeeping_check() (
  # shellcheck source=scripts/lib/ci-bookkeeping.sh
  . "$ROOT/scripts/lib/ci-bookkeeping.sh"
  local active=$1 template=$2 probe=$3 workflow globs template_globs source path matched status=0
  globs=$(ci_bookkeeping_globs "$active" --check-docs) || fail "$active must use an all-negated App filter with the every predicate"
  template_globs=$(ci_bookkeeping_globs "$template" --check-docs) || fail "$template must use an all-negated App filter with the every predicate"
  [ "$globs" = "$template_globs" ] || fail 'CI workflows have different bookkeeping lists'

  # Git ignore patterns and the workflow patterns share literal paths, * and **.
  # Anchor the patterns and check in an empty repo so the project's ignore rules
  # and index cannot affect classification.
  mkdir -p "$probe"
  git -C "$probe" init -q --template=
  printf '%s\n' "$globs" | sed 's|^|/|' > "$probe/.gitignore"
  {
    while IFS=$'\t' read -r source _rest; do
      case "$source" in ''|\#*) continue ;; esac
      printf '%s\0' "$source"
      if [ -d "$ROOT/$source" ]; then
        while IFS= read -r -d '' path; do printf '%s\0' "${path#"$ROOT"/}"; done \
          < <(find "$ROOT/$source" \( -type f -o -type l \) -print0)
      fi
    done < "$ROOT/config/payload.tsv"
    printf '%s\0' README.md docs/README.md docs/accepted_risks.md .editorconfig .gitignore
  } | git -C "$probe" -c core.excludesFile=/dev/null check-ignore --no-index -z --stdin \
    > "$probe/matches" || status=$?
  [ "$status" -le 1 ] || fail 'could not check CI bookkeeping against the payload manifest'
  if IFS= read -r -d '' matched < "$probe/matches"; then
    fail "CI bookkeeping matches an App input: $matched"
  fi

  for path in docs/inprogress/plan.md docs/done/plan.md docs/done/security/plan.md \
      docs/backlog/plan.md docs/memory/entry.md docs/MEMORY.md ROADMAP.md docs/agentic-flow-explained.html; do
    git -C "$probe" -c core.excludesFile=/dev/null check-ignore --no-index -q -- "$path" \
      || fail "CI bookkeeping does not cover $path"
  done
  for workflow in "$active" "$template"; do
    assert_ci_gate_needs_asserted "$workflow"
    awk -v enabled="if: needs.changes.outputs.docs == 'true'" '
      /^  [^ ]/ { docs=($1=="docs:") }
      docs && $0=="    " enabled { condition++ }
      docs && /^        run: scripts\/docs-index\.sh --check$/ { index_check++ }
      docs && /^        run: scripts\/check-memory-index\.sh$/ { memory++ }
      END { exit !(condition==1 && index_check==1 && memory==1) }
    ' "$workflow" || fail "$workflow Docs job must run the docs and memory index checks"
  done
)

# Flow ergonomics scenario 9. Use an actual merge tree with the same PR head
# before and after the base moves, and mutate tracked inputs in the index.
ci_app_key_tests() (
  local fixture="$TMP/ci-app-key" expected key base pr change file
  git init -q -b main --template= "$fixture"
  cd "$fixture"
  git config user.name Fixture
  git config user.email fixture@example.invalid
  git config commit.gpgsign false
  mkdir -p .github/workflows docs/done/security ROADMAP.md
  cp "$ci_active" .github/workflows/ci.yml
  printf 'base\n' > base.txt
  printf 'app\n' > 'app input.sh'
  printf 'nested App input\n' > ROADMAP.md/input
  printf 'notes\n' > docs/done/security/plan.md
  printf 'memory\n' > docs/MEMORY.md
  git add -- base.txt 'app input.sh' ROADMAP.md/input docs/done/security/plan.md docs/MEMORY.md
  git commit -qm base
  base=$(git rev-parse HEAD)
  git checkout -qb pr
  printf 'PR\n' > pr.txt
  git add -- pr.txt
  git commit -qm pr
  pr=$(git rev-parse HEAD)
  git checkout -q --detach "$base"
  git merge --no-ff -qm 'Original PR merge' "$pr"
  key=$("$ROOT/scripts/app-input-key.sh") || fail 'could not compute the App key on the merge checkout'
  expected=$(git -c core.quotePath=true ls-files -s -- base.txt 'app input.sh' ROADMAP.md/input pr.txt | shasum -a 256)
  [ "$key" = "${expected%% *}" ] || fail 'App key did not hash the staged App inputs'

  printf 'edited notes\n' > docs/done/security/plan.md
  printf 'new notes\n' > docs/done/.draft.md
  git add -- docs/done
  [ "$key" = "$("$ROOT/scripts/app-input-key.sh")" ] || fail 'bookkeeping changed the App key'
  git reset -q --hard HEAD
  for change in mode rename delete add contents; do
    file='app input.sh'
    case "$change" in
      mode) git update-index --chmod=+x -- "$file" ;;
      rename) git mv -- "$file" app-renamed.sh ;;
      delete) git rm -q -- "$file" ;;
      add) printf 'added\n' > added.sh; git add -- added.sh ;;
      contents) printf 'app!\n' > "$file"; git add -- "$file" ;;
    esac
    expected=$("$ROOT/scripts/app-input-key.sh") || fail "could not compute the App key after $change"
    [ "$key" != "$expected" ] || fail "$change did not change the App key"
    git reset -q --hard HEAD
  done

  git checkout -q main
  printf 'new base\n' > base.txt
  git add -- base.txt
  git commit -qm 'Move base'
  git checkout -q --detach main
  git merge --no-ff -qm 'Updated PR merge' "$pr"
  expected=$("$ROOT/scripts/app-input-key.sh") || fail 'could not compute the App key after the base moved'
  [ "$key" != "$expected" ] || fail 'new base content kept the same App key'
)

ci_job_step() { # <workflow> <job> <step name>
  awk -v job="$2:" -v step="      - name: $3" '
    /^  [^ ]/ { in_job=($1==job); in_step=0 }
    in_job && /^      - / { in_step=($0==step) }
    in_step { print }
  ' "$1"
}

ci_app_cache_tests() (
  local workflow=$1 checkout key restore report marker save body source result
  checkout=$(ci_job_step "$workflow" changes Checkout)
  key=$(ci_job_step "$workflow" changes 'Compute App input key')
  restore=$(ci_job_step "$workflow" changes 'Restore green App result')
  report=$(ci_job_step "$workflow" changes 'Report reused App checks')
  marker=$(ci_job_step "$workflow" app 'Record green App result')
  save=$(ci_job_step "$workflow" app 'Save green App result')
  if ! grep -q 'uses: actions/checkout@' <<< "$checkout" || grep -q '^[[:space:]]*ref:' <<< "$checkout"; then
    fail "$workflow changes job must use the default PR merge checkout"
  fi
  grep -Fq 'scripts/app-input-key.sh' <<< "$key" || fail "$workflow does not compute the App key"
  grep -q 'continue-on-error: true' <<< "$restore" || fail "$workflow cache lookup errors fail the changes job"
  grep -Fxq "        if: steps.app_cache.outcome == 'success' && steps.app_cache.outputs.cache-hit == 'true'" \
    <<< "$report" || fail "$workflow cache lookup errors or misses can be reused"
  grep -Fxq "      app_cached: \${{ steps.app_source.outcome == 'success' && steps.app_source.outputs.cached || 'false' }}" \
    "$workflow" || fail "$workflow accepts a cache hit without source evidence"
  grep -Fxq "    if: needs.changes.outputs.app == 'true' && needs.changes.outputs.app_cached != 'true'" \
    "$workflow" || fail "$workflow App job ignores the cache verdict"
  grep -Fxq "          key: app-green-v1-\${{ steps.app_key.outputs.key }}" <<< "$restore" \
    || fail "$workflow restores a cache entry with the wrong key"
  grep -Fxq "          key: app-green-v1-\${{ needs.changes.outputs.app_key }}" <<< "$save" \
    || fail "$workflow saves a cache entry with the wrong key"
  grep -Fxq "        if: success() && steps.app_green.outcome == 'success'" <<< "$save" \
    || fail "$workflow could save after an App failure"
  awk '/^  app:/ { app=1 } /^  docs:/ { app=0 }
    app && /^      - name:/ { before=last; last=$0 }
    END { exit !(before ~ /Record green App result$/ && last ~ /Save green App result$/) }
  ' "$workflow" || fail "$workflow saves the green result before App checks finish"

  export APP_CACHE_FILE="$TMP/ci-app-green" GITHUB_STEP_SUMMARY="$TMP/ci-app-summary" \
    GITHUB_OUTPUT="$TMP/ci-app-output" GITHUB_SERVER_URL=https://github.com \
    GITHUB_REPOSITORY=owner/repo GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=2
  source=https://github.com/owner/repo/actions/runs/123/attempts/2
  body=$(sed -n '/^        run: |$/,$s/^          //p' <<< "$marker")
  bash -e -c "$body"
  body=$(sed -n '/^        run: |$/,$s/^          //p' <<< "$report")
  : > "$GITHUB_OUTPUT"
  bash -e -c "$body"
  if ! grep -Fq "$source" "$GITHUB_STEP_SUMMARY" || ! grep -Fxq 'cached=true' "$GITHUB_OUTPUT"; then
    fail "$workflow does not identify the reused run and attempt"
  fi
  : > "$GITHUB_OUTPUT"
  : > "$APP_CACHE_FILE"
  bash -e -c "$body" 2>/dev/null && fail "$workflow accepted an empty green marker"
  [ ! -s "$GITHUB_OUTPUT" ] || fail "$workflow emitted a cache hit for an empty marker"

  for result in skipped failure cancelled; do
    body=$(ci_job_step "$workflow" ci-gate 'Assert no upstream job failed or was cancelled' \
      | sed -n '/^        run: |$/,$s/^          //p' \
      | sed -e "s/\${{ needs\.app\.result }}/$result/g" -e 's/${{ needs\.[a-z-]*\.result }}/success/g')
    case "$result" in
      skipped) bash -e -c "$body" || fail "$workflow rejected a skipped App job" ;;
      *) if bash -e -c "$body" >/dev/null; then fail "$workflow accepted an App job that ended in $result"; fi ;;
    esac
  done
)

if [ -f "$ROOT/scripts/export.sh" ]; then
  ci_active="$ROOT/.github/workflows/ci.yml"
  ci_template="$ROOT/templates/ci/ci.yml"
  if [ "$SELF_TEST_MODE" = fast ] && [ -z "$ONLY_GROUP" ]; then
    ci_bookkeeping_check "$ci_active" "$ci_template" "$TMP/ci-bookkeeping"
  else
    ci_app_key_tests
    ci_bookkeeping_check "$ci_active" "$ci_template" "$TMP/ci-bookkeeping"
    ci_app_cache_tests "$ci_active"
    ci_app_cache_tests "$ci_template"
    ci_bad="$TMP/ci-invalid"
    mkdir -p "$ci_bad"
    for ci_mutation in payload drift gate result readers; do
      ci_probe_active=$ci_active
      ci_probe_template=$ci_template
      case "$ci_mutation" in
        payload)
          ci_probe_active="$ci_bad/active"
          ci_probe_template="$ci_bad/template"
          sed "s|'!docs/done/\*\*/\*.md'|'!docs/done/**'|" "$ci_active" > "$ci_probe_active"
          sed "s|'!docs/done/\*\*/\*.md'|'!docs/done/**'|" "$ci_template" > "$ci_probe_template"
          ci_expected='CI bookkeeping matches an App input'
          ;;
        drift)
          ci_probe_template="$ci_bad/template"
          sed '/!ROADMAP\.md/d' "$ci_template" > "$ci_probe_template"
          ci_expected='CI workflows have different bookkeeping lists'
          ;;
        gate)
          ci_probe_active="$ci_bad/active"
          sed 's/needs: \[changes, secrets-scan, app, docs\]/needs: [changes, secrets-scan, app]/' \
            "$ci_active" > "$ci_probe_active"
          ci_expected='does not match its actual job set'
          ;;
        result)
          ci_probe_active="$ci_bad/active"
          sed 's/needs\.docs\.result/needs.app.result/' "$ci_active" > "$ci_probe_active"
          ci_expected="ci-gate loop does not assert on job 'docs'"
          ;;
        readers)
          ci_probe_active="$ci_bad/active"
          sed '/run: scripts\/check-memory-index\.sh/d' "$ci_active" > "$ci_probe_active"
          ci_expected='Docs job must run the docs and memory index checks'
          ;;
      esac
      ci_bookkeeping_check "$ci_probe_active" "$ci_probe_template" "$TMP/ci-bookkeeping" > "$ci_bad/out" 2>&1 \
        && fail "CI bookkeeping check accepted the $ci_mutation fixture"
      grep -Fq "$ci_expected" "$ci_bad/out" || fail "CI bookkeeping check missed the $ci_mutation diagnostic"
    done
  fi
fi
if [ "$SELF_TEST_MODE" = fast ] && [ -z "$ONLY_GROUP" ]; then return 0; fi

# Scenario 11: advance a private clock from inert group and scenario bodies.
wall_ceiling_tests() (
  local fixture="$TMP/wall-ceilings" key tag gate missing
  mkdir -p "$fixture/scripts/tests" "$fixture/config"
  ln "$ROOT/scripts/self-test.sh" "$fixture/scripts/self-test.sh"
  cat "$ROOT/scripts/tests/helpers.sh" > "$fixture/scripts/tests/helpers.sh"
  cat >> "$fixture/scripts/tests/helpers.sh" <<'CLOCK'
self_test_now() { printf '%s\n' "${FIXTURE_CLOCK:-0}"; }
CLOCK
  for key in $SELF_TEST_GROUPS; do
    case "$key" in
      controller|stations)
        awk '
          /^if should_run_scenario / {
            print
            print "  FIXTURE_CLOCK=$((${FIXTURE_CLOCK:-0} + ${STEP_" toupper($3) ":-0}))"
            next
          }
          /^fi # scenario$/ { print }
        ' "$ROOT/scripts/tests/$key.sh" > "$fixture/scripts/tests/$key.sh"
        ;;
      *)
        cat > "$fixture/scripts/tests/$key.sh" <<'BODY'
FIXTURE_CLOCK=${STEP_GROUP:-0}
BODY
        ;;
    esac
  done
  {
    for key in $SELF_TEST_GROUPS upgrade:upstream; do printf '%s\t5\n' "$key"; done
    for tag in $CONTROLLER_SCENARIOS; do printf 'controller:%s\t5\n' "$tag"; done
    for tag in $STATIONS_SCENARIOS; do printf 'stations:%s\t5\n' "$tag"; done
  } > "$fixture/ceilings"
  cat "$fixture/ceilings" > "$fixture/config/test-wall-ceilings.tsv"

  ceiling_probe() {
    local expected=$1 status=0
    shift
    : > "$fixture/events"
    AGENTIC_MEASURE_EVENTS="$fixture/events" "$fixture/scripts/self-test.sh" "$@" \
      > "$fixture/out" 2>&1 || status=$?
    [ "$status" = "$expected" ] || fail "wall ceiling ($*) returned $status, expected $expected: $(cat "$fixture/out")"
  }
  STEP_GROUP=6 ceiling_probe 1 --only hooks
  grep -Fq 'hooks took 6 seconds (ceiling: 5 seconds)' "$fixture/out" \
    || fail 'whole-group ceiling failure lacked the group and measured and allowed seconds'
  STEP_PACKET=6 ceiling_probe 1 --only stations --scenario packet
  grep -Fq 'stations:packet took 6 seconds (ceiling: 5 seconds)' "$fixture/out" \
    || fail 'tag ceiling failure lacked the tag and measured and allowed seconds'
  STEP_GROUP=5 ceiling_probe 0 --only hooks
  grep -Fxq 'group:hooks:5' "$fixture/events" || fail 'group boundary did not record its seconds'
  STEP_PACKET=5 ceiling_probe 0 --only stations --scenario packet
  grep -Fxq 'group:stations:packet:5' "$fixture/events" || fail 'tag boundary did not record its seconds'
  # The launch tag uses three blocks, and the union exceeds the group ceiling.
  STEP_LAUNCH=1 STEP_PACKET=5 STEP_VERIFY=60 ceiling_probe 0 --only stations --scenario packet,launch
  grep -Fxq 'group:stations:launch:3' "$fixture/events" || fail 'disjoint tag blocks did not sum their seconds'
  if grep -Eq '^group:stations:(verify:|[0-9]+$)' "$fixture/events"; then
    fail 'partial run recorded a group or an unselected tag'
  fi
  STEP_LAUNCH=1 STEP_PACKET=6 ceiling_probe 1 --only stations --scenario launch,packet
  grep -Fq 'stations:packet took 6 seconds (ceiling: 5 seconds)' "$fixture/out" \
    || fail 'scenario union missed an over-ceiling selected tag'
  STEP_LAUNCH=1 STEP_PACKET=3 ceiling_probe 1 --only stations
  grep -Fq 'stations took 6 seconds (ceiling: 5 seconds)' "$fixture/out" \
    || fail 'whole tagged group missed its group ceiling'
  STEP_LAUNCH=1 STEP_PACKET=3 ceiling_probe 1 --full --jobs 2
  grep -Fq 'stations took 6 seconds (ceiling: 5 seconds)' "$fixture/out" \
    || fail 'full suite missed the combined seconds for a tagged group'
  grep -Fxq 'group:stations:6' "$fixture/events" || fail 'full run did not record its aggregate group seconds'
  grep -Fxq 'group_failure:stations' "$fixture/events" || fail 'full run did not record the over-ceiling group'
  STEP_LAUNCH=1 STEP_PACKET=2 ceiling_probe 0 --full --jobs 2

  # Use the real check recipe, with unrelated gates stubbed.
  ln "$ROOT/Makefile" "$fixture/Makefile"
  for gate in shell-inventory check-payload-manifest check-harness-sync check-memory-index check-action-pins; do
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fixture/scripts/$gate.sh"
    chmod +x "$fixture/scripts/$gate.sh"
  done
  for missing in hooks stations:verify; do
    awk -v missing="$missing" '$1 != missing' "$fixture/ceilings" > "$fixture/config/test-wall-ceilings.tsv"
    make -s -C "$fixture" check > "$fixture/out" 2>&1 \
      && fail "make check accepted a missing wall-time ceiling for $missing"
    grep -Fq "missing wall-time ceiling: $missing" "$fixture/out" \
      || fail "make check did not identify the missing wall-time ceiling for $missing"
  done
)
wall_ceiling_tests

# Scenario 10: exercise the full dispatcher with small, independent shard bodies.
parallel_shard_tests() (
  local fixture="$TMP/parallel-shards" status=0 group shard count selection actual expected
  mkdir -p "$fixture/scripts/tests" "$fixture/bin" "$fixture/roots"
  link_test_wall_ceilings "$fixture"
  cat "$ROOT/scripts/self-test.sh" > "$fixture/scripts/self-test.sh"
  chmod +x "$fixture/scripts/self-test.sh"
  printf '#!/usr/bin/env bash\necho 2\n' > "$fixture/bin/nproc"
  chmod +x "$fixture/bin/nproc"
  for group in $SELF_TEST_GROUPS; do
    case "$group" in
      controller|stations)
        awk '
          /^if should_run_scenario / { print; print "  record_fixture"; next }
          /^fi # scenario$/ { print }
        ' "$ROOT/scripts/tests/$group.sh" > "$fixture/scripts/tests/$group.sh"
        ;;
      *) printf 'record_fixture\n' > "$fixture/scripts/tests/$group.sh" ;;
    esac
  done
  cat "$ROOT/scripts/tests/helpers.sh" > "$fixture/scripts/tests/helpers.sh"
  cat >> "$fixture/scripts/tests/helpers.sh" <<'SHARD_PROBE'
record_fixture() {
  local shard="$ONLY_GROUP${SCENARIOS:+/$SCENARIOS}" i
  printf '%s\t%s\t%s\t%s\n' "$TMP" "$HOME" "$XDG_CONFIG_HOME" "$$" \
    > "$ROOT/roots/${shard//\//-}"
  echo "fixture shard $shard started"
  case "${SHARD_PROBE:-}:$shard" in
    failure:export)
      # The second shard must reach its body while the first is still running.
      for ((i=0; i<100; i++)); do
        if [ -s "$ROOT/roots/contracts" ]; then
          sleep 0.2
          [ ! -e "$ROOT/roots/upgrade" ] || fail 'parallel dispatcher exceeded two CPUs'
          touch "$ROOT/roots/released"
          fail 'injected export shard failure'
        fi
        sleep 0.05
      done
      fail 'contracts shard did not overlap export'
      ;;
    failure:contracts)
      for ((i=0; i<100; i++)); do
        [ ! -f "$ROOT/roots/released" ] || break
        sleep 0.05
      done
      ;;
    failure:hooks) fail 'injected hooks shard failure' ;;
    budget:export|budget:contracts|budget:hooks)
      for ((i=0; i<80; i++)); do measure_event fixture_file_copy; done
      ;;
  esac
  echo "fixture shard $shard finished"
}
SHARD_PROBE
  parallel_probe() { # <expected status> <probe mode> [full-mode options]
    local want="$1" mode="$2"
    shift 2
    rm -f "$fixture/roots/"*
    : > "$fixture/events"
    status=0
    PATH="$fixture/bin:$PATH" SHARD_PROBE="$mode" AGENTIC_TEST_JOBS='' AGENTIC_MEASURE_EVENTS="$fixture/events" \
      "$fixture/scripts/self-test.sh" --full "$@" > "$fixture/out" 2>&1 || status=$?
    [ "$status" = "$want" ] || fail "parallel dispatcher returned $status expected $want: $(cat "$fixture/out")"
  }
  for selection in 999999999999999999999 default; do
    if [ "$selection" = default ]; then parallel_probe 1 failure
    else parallel_probe 1 failure --jobs "$selection"; fi
    grep -q 'injected export shard failure' "$fixture/out" || fail 'parallel dispatcher did not overlap the first two shards within the CPU limit'
    grep -q 'injected hooks shard failure' "$fixture/out" || fail 'parallel dispatcher omitted another failing shard'
    grep -q 'fixture shard controller/recovery finished' "$fixture/out" || fail 'parallel dispatcher stopped after a failed shard'
    for shard in export hooks; do
      grep -q "shard $shard exited" "$fixture/out" || fail "parallel dispatcher omitted failed shard status for $shard"
    done
    # Cover the macOS probe when nproc is absent.
    printf '#!/usr/bin/env bash\nexit 127\n' > "$fixture/bin/nproc"
    printf '#!/usr/bin/env bash\necho 2\n' > "$fixture/bin/getconf"
    chmod +x "$fixture/bin/getconf"
  done

  # A worker can exit zero despite an absent group marker. Another shard's
  # marker must never stand in for its own.
  # shellcheck disable=SC2016 # The sed script edits a literal shell expression.
  sed '/measure_event "group:\$1"/s/^  /  [ "$1" = hooks ] || /' \
    "$ROOT/scripts/self-test.sh" > "$fixture/scripts/self-test.sh"
  parallel_probe 1 missing --jobs 2
  grep -q "shard 'hooks' never executed" "$fixture/out" || fail 'parallel dispatcher accepted a missing group marker'
  cat "$ROOT/scripts/self-test.sh" > "$fixture/scripts/self-test.sh"

  # Individual copy counts fit within budget. The merged count does not.
  git -C "$fixture" init -q
  : > "$fixture/scripts/export.sh"
  parallel_probe 1 budget --jobs 2
  grep -q 'full mode made 240 fixture file copies; limit 194' "$fixture/out" || fail 'parallel dispatcher missed the combined copy budget'
  [ "$(cost_count "$fixture/events" source_snapshot_copy)" -eq 1 ] || fail 'parallel dispatcher duplicated the source snapshot'

  expected='export contracts upgrade hooks plan-to-issues lifecycle stations/launch stations/verify stations/handoff stations/packet controller/launch controller/ship controller/andon controller/ledger controller/recovery '
  for selection in 1 default; do
    if [ "$selection" = 1 ]; then parallel_probe 0 pass --jobs 1
    else parallel_probe 0 pass; fi
    actual=$(sed -n 's/^--- self-test shard: \(.*\) ---$/\1/p' "$fixture/out" | tr '\n' ' ')
    [ "$actual" = "$expected" ] || fail "parallel shard logs out of order: $actual"
    count=$(printf '%s\n' "$expected" | wc -w | tr -d ' ')
    for group in 1 2 3 4; do
      [ "$(cut -f "$group" "$fixture/roots/"* | sort -u | wc -l | tr -d ' ')" = "$count" ] \
        || fail "parallel shards shared a fixture directory or process (field $group)"
    done
  done
  for selection in 0 -1 '' 1x; do parallel_probe 2 invalid --jobs "$selection"; done
  parallel_probe 2 invalid --jobs
)
parallel_shard_tests

# Scenario 9: exercise the real dispatcher with only station block bodies inert.
stations_selector_tests() (
  local fixture selection status expected actual group mf
  fixture="$TMP/stations-selector"
  mkdir -p "$fixture/scripts/tests"
  link_test_wall_ceilings "$fixture"
  ln "$ROOT/scripts/tests/helpers.sh" "$fixture/scripts/tests/helpers.sh"
  cat "$ROOT/scripts/self-test.sh" > "$fixture/scripts/self-test.sh"
  chmod +x "$fixture/scripts/self-test.sh"
  awk '
    /^if should_run_scenario / { print; print "  :"; next }
    /^fi # scenario$/ { print }
  ' "$ROOT/scripts/tests/stations.sh" > "$fixture/blocks"
  cat "$fixture/blocks" > "$fixture/scripts/tests/stations.sh"
  stations_select_run() {
    expected=$1; shift; status=0
    : > "$fixture/events"
    AGENTIC_MEASURE_EVENTS="$fixture/events" "$fixture/scripts/self-test.sh" "$@" \
      > "$fixture/out" 2> "$fixture/err" || status=$?
    [ "$status" = "$expected" ] \
      || fail "stations selector returned $status expected $expected: $(cat "$fixture/err")"
  }
  stations_select_markers() {
    actual=$(sed -n 's/^scenario://p' "$fixture/events" | sort | tr '\n' ' ')
    [ "$actual" = "$1" ] || fail "stations markers '$actual', expected '$1'"
  }
  for selection in unknown ledger '' ',packet' 'packet,' 'packet,,verify' 'packet verify'; do
    stations_select_run 2 --only stations --scenario "$selection"
    [ ! -s "$fixture/events" ] || fail 'invalid stations selection ran a group'
  done
  stations_select_run 2 --only stations --scenario
  for group in export contracts hooks plan-to-issues lifecycle upgrade; do
    stations_select_run 2 --only "$group" --scenario launch
    [ ! -s "$fixture/events" ] || fail 'scenario accepted for an unsupported group'
  done
  stations_select_run 2 --full --scenario launch
  # Removing all guards must fail, as must losing just one selected block.
  sed 's/^if should_run_scenario .*; then$/if false; then/' "$fixture/blocks" \
    > "$fixture/scripts/tests/stations.sh"
  stations_select_run 1 --only stations --scenario packet
  grep -q 'no stations scenario block executed' "$fixture/err" \
    || fail 'empty stations selection lacked a diagnosis'
  sed 's/^if should_run_scenario launch watchdogs; then$/if false; then/' "$fixture/blocks" \
    > "$fixture/scripts/tests/stations.sh"
  stations_select_run 1 --only stations
  grep -q "stations scenario block 'watchdogs:launch' never executed" "$fixture/err" \
    || fail 'stations whole group missed a deleted block'
  sed 's/^if should_run_scenario packet packet; then$/if should_run_scenario typo packet; then/' "$fixture/blocks" \
    > "$fixture/scripts/tests/stations.sh"
  stations_select_run 1 --only stations --scenario packet
  grep -q 'unknown stations scenario block at call site' "$fixture/err" \
    || fail 'stations accepted a drifted block tag'
  cat "$fixture/blocks" > "$fixture/scripts/tests/stations.sh"
  for selection in launch packet verify handoff; do
    stations_select_run 0 --only stations --scenario "$selection"
    case "$selection" in
      launch) stations_select_markers 'launch:settings launch:slice launch:watchdogs ' ;;
      packet) stations_select_markers 'packet:packet ' ;;
      verify) stations_select_markers 'verify:cache verify:interrupt verify:red-first ' ;;
      handoff) stations_select_markers 'handoff:cli handoff:closeout handoff:journal ' ;;
    esac
  done
  stations_select_run 0 --only stations --scenario packet,launch
  stations_select_markers 'launch:settings launch:slice launch:watchdogs packet:packet '
  stations_select_run 0 --only stations --scenario packet,packet
  stations_select_markers 'packet:packet '
  stations_select_run 0 --only stations
  stations_select_markers 'handoff:cli handoff:closeout handoff:journal launch:settings launch:slice launch:watchdogs packet:packet verify:cache verify:interrupt verify:red-first '
  for mf in "$ROOT/Makefile" "$ROOT/templates/harness/Makefile"; do
    [ -f "$mf" ] || continue
    : > "$fixture/events"
    env -u MAKEFLAGS -u MFLAGS -u MAKEOVERRIDES S=launch \
      AGENTIC_MEASURE_EVENTS="$fixture/events" make -s -C "$fixture" -f "$mf" \
      test-one F=stations S=packet,launch > "$fixture/make.out" \
      || fail 'Makefile did not forward stations union'
    stations_select_markers 'launch:settings launch:slice launch:watchdogs packet:packet '
    : > "$fixture/events"
    env -u MAKEFLAGS -u MFLAGS -u MAKEOVERRIDES S=packet \
      AGENTIC_MEASURE_EVENTS="$fixture/events" make -s -C "$fixture" -f "$mf" \
      test-one F=stations > "$fixture/make.out" || fail 'environment S affected stations'
    stations_select_markers 'handoff:cli handoff:closeout handoff:journal launch:settings launch:slice launch:watchdogs packet:packet verify:cache verify:interrupt verify:red-first '
    status=0
    env -u MAKEFLAGS -u MFLAGS -u MAKEOVERRIDES make -s -C "$fixture" -f "$mf" \
      test-one F=stations S= > "$fixture/make.out" 2> "$fixture/make.err" || status=$?
    [ "$status" = 2 ] || fail 'Makefile accepted an empty stations selector'
  done
)
stations_selector_tests

# Scenario 7: first remove an assertion, then remove an executable group.
split_regression_tests() (
  local fixture group bootstrap_status=0
  fixture="$TMP/split-regression"
  mkdir -p "$fixture/scripts/tests"
  link_test_wall_ceilings "$fixture"
  # The approved t-4 red-first paths copy only the dispatcher and contracts.
  # Missing split dependencies must produce an assertion, not a source error.
  mkdir -p "$fixture/bootstrap/scripts/tests"
  ln "$ROOT/scripts/self-test.sh" "$fixture/bootstrap/scripts/self-test.sh"
  ln "$ROOT/scripts/tests/contracts.sh" "$fixture/bootstrap/scripts/tests/contracts.sh"
  "$fixture/bootstrap/scripts/self-test.sh" --only contracts \
    > "$TMP/split-bootstrap.out" 2>&1 || bootstrap_status=$?
  [ "$bootstrap_status" = 1 ] || fail 'missing test helpers returned the wrong status'
  grep -Fxq 'self-test failed: missing self-test helper file: scripts/tests/helpers.sh' \
    "$TMP/split-bootstrap.out" || fail 'missing test helpers did not produce an assertion'
  [ -f "$ROOT/scripts/tests/export.sh" ] || fail 'split export group is missing'
  for group in $SELF_TEST_GROUPS; do
    [ -f "$ROOT/scripts/tests/$group.sh" ] || fail "split group is missing: $group"
    ln "$ROOT/scripts/tests/$group.sh" "$fixture/scripts/tests/$group.sh"
  done
  ln "$ROOT/scripts/self-test.sh" "$fixture/scripts/self-test.sh"
  ln "$ROOT/scripts/tests/helpers.sh" "$fixture/scripts/tests/helpers.sh"
  ln "$ROOT/scripts/tests/assertion-messages.pl" "$fixture/scripts/tests/assertion-messages.pl"
  ln "$ROOT/scripts/tests/assertion-messages.txt" "$fixture/scripts/tests/assertion-messages.txt"
  ln "$ROOT/scripts/tests/assertion-additions.txt" "$fixture/scripts/tests/assertion-additions.txt"
  # Unlink before editing: the fixture must never alter the source inode.
  rm "$fixture/scripts/tests/export.sh"
  sed '/export --dry-run failed against an empty target/d' "$ROOT/scripts/tests/export.sh" \
    > "$fixture/scripts/tests/export.sh"
  cmp -s "$ROOT/scripts/tests/export.sh" "$fixture/scripts/tests/export.sh" \
    && fail 'assertion deletion fixture did not delete an assertion'
  perl "$ROOT/scripts/tests/assertion-messages.pl" "$fixture" --check \
    > "$TMP/split-deleted.out" 2>&1 && fail 'assertion inventory accepted a deleted assertion'
  grep -q 'missing: fail' "$TMP/split-deleted.out" \
    || fail 'assertion inventory did not identify the deleted assertion'
  rm "$fixture/scripts/tests/hooks.sh"
  sed '/git --no-pager -C \/some\/path add -A/d' "$ROOT/scripts/tests/hooks.sh" \
    > "$fixture/scripts/tests/hooks.sh"
  cmp -s "$ROOT/scripts/tests/hooks.sh" "$fixture/scripts/tests/hooks.sh" \
    && fail 'helper deletion fixture did not delete an assertion'
  perl "$ROOT/scripts/tests/assertion-messages.pl" "$fixture" --check \
    > "$TMP/split-helper.out" 2>&1 && fail 'assertion inventory accepted a deleted helper call'
  grep -q 'missing: must_block' "$TMP/split-helper.out" \
    || fail 'assertion inventory did not identify the deleted helper call'
  mv "$fixture/scripts/tests/hooks.sh" "$fixture/scripts/tests/hooks.renamed"
  "$fixture/scripts/self-test.sh" --only hooks > "$TMP/split-missing.out" 2>&1 \
    && fail 'dispatcher accepted a renamed group file'
  grep -q 'missing self-test group file: hooks' "$TMP/split-missing.out" \
    || fail 'dispatcher did not name the missing group file'
  perl "$ROOT/scripts/tests/assertion-messages.pl" "$ROOT" --check \
    || fail 'assertion inventory differs after the split'
  [ "$SELF_TEST_GROUPS" = 'export contracts upgrade hooks plan-to-issues lifecycle stations controller' ] \
    || fail 'split changed the self-test group names'
  # Exercise the real dispatcher with inert bodies to check order and completion
  # without recursively executing the suite. Each file has a private inode.
  for group in $SELF_TEST_GROUPS; do
    rm -f "$fixture/scripts/tests/$group.sh"
    printf ':\n' > "$fixture/scripts/tests/$group.sh"
  done
  cat > "$fixture/scripts/tests/controller.sh" <<'BLOCKS'
for block in $CONTROLLER_BLOCKS; do
  should_run_scenario "${block#*:}" "${block%:*}" || continue
done
BLOCKS
  cat > "$fixture/scripts/tests/stations.sh" <<'BLOCKS'
for block in $STATIONS_BLOCKS; do
  should_run_scenario "${block#*:}" "${block%:*}" || continue
done
BLOCKS
  AGENTIC_MEASURE_EVENTS="$fixture/events" "$fixture/scripts/self-test.sh" --full \
    > "$TMP/split-full.out" 2>&1 || fail 'split full dispatcher failed'
  [ "$(sed -n 's/^group:\([^:]*\)$/\1/p' "$fixture/events" | awk '!seen[$0]++' | tr '\n' ' ')" = \
    'export contracts upgrade hooks plan-to-issues lifecycle stations controller ' ] \
    || fail 'split changed the full-suite group order'
  grep -qx 'self-test passed.' "$TMP/split-full.out" \
    || fail 'split changed the full-suite completion message'
)

# Dispatcher scope, ship-gate and ceiling regressions need the source layout.
if [ -f "$ROOT/scripts/export.sh" ]; then
  # Test the real startup, selector and completion assertion with inert group bodies:
  # these cases measure dispatch, without recursively executing the regression suite.
  SCOPE_FIX="$TMP/group-scope"
  mkdir -p "$SCOPE_FIX/scripts/tests" "$SCOPE_FIX/config" "$SCOPE_FIX/bin"
  link_test_wall_ceilings "$SCOPE_FIX"
  ln "$ROOT/scripts/tests/helpers.sh" "$SCOPE_FIX/scripts/tests/helpers.sh"
  awk '/^FULL_FAILED=0$/ { exit } { print }' "$ROOT/scripts/self-test.sh" \
    > "$SCOPE_FIX/scripts/self-test.sh"
  cat >> "$SCOPE_FIX/scripts/self-test.sh" <<'SELECTOR'
fast_check_group() { :; }
assert_cost_budget() { :; }
FULL_FAILED=0
for scope_group in $SELF_TEST_GROUPS; do
  if should_run "$scope_group"; then :; fi
done
SELECTOR
  awk '/^# --- the run did what the mode promised / { emit=1 } emit' "$ROOT/scripts/self-test.sh" \
    >> "$SCOPE_FIX/scripts/self-test.sh"
  chmod +x "$SCOPE_FIX/scripts/self-test.sh"
  # Scope validation is part of --fast (and hence make check), before any group runs.
  grep -q '^SELF_TEST_GROUP_SCOPES=' "$SCOPE_FIX/scripts/self-test.sh" \
    || fail 'self-test groups do not declare scopes'
  for scope_case in missing unknown invalid duplicate; do
    case "$scope_case" in
      missing) scope_edit='s/contracts:local//g' ;;
      unknown) scope_edit='s/contracts:local/absent:local/g' ;;
      invalid) scope_edit='s/contracts:local/contracts:other/g' ;;
      duplicate) scope_edit='s/contracts:local/contracts:local contracts:local/g' ;;
    esac
    sed "$scope_edit" "$SCOPE_FIX/scripts/self-test.sh" > "$SCOPE_FIX/scripts/bad.sh"
    bash "$SCOPE_FIX/scripts/bad.sh" --fast > "$TMP/scope.out" 2>&1 \
      && fail "scope validation accepted $scope_case declaration"
    grep -q 'self-test failed:.*scope' "$TMP/scope.out" \
      || fail "scope validation did not explain $scope_case declaration"
  done
  rm "$SCOPE_FIX/scripts/bad.sh"
  # Deliberately use a mapped destination: installed paths come from column two.
  printf 'source/tool\tscripts\tcore\tpreserve\texport\nsource/contract\tAGENTS.md\tcore\tpreserve\texport\nsource/private\tprivate\tsource-only\tnone\tsource-only\n' \
    > "$SCOPE_FIX/config/payload.tsv"
  scope_expect() { # <expected groups> <case name> [runner flags]
    local expected="$1" name="$2" actual
    shift 2
    : > "$TMP/scope.events"
    AGENTIC_BASE_REF="${SCOPE_BASE_REF:-}" GITHUB_BASE_REF="${SCOPE_PR_BASE:-}" \
      AGENTIC_MEASURE_EVENTS="$TMP/scope.events" "$SCOPE_FIX/scripts/self-test.sh" --full "$@" \
      > "$TMP/scope.out" 2>&1 \
      || { cat "$TMP/scope.out" >&2; fail "scope dispatch failed: $name"; }
    actual=$(sed -n 's/^group:\([^:]*\)$/\1/p' "$TMP/scope.events" | tr '\n' ' ' | sed 's/ $//')
    [ "$actual" = "$expected" ] || fail "scope dispatch $name: '$actual', expected '$expected'"
  }
  # Failure paths first: no repository, no remote, missing refs, a git command error,
  # and a shallow feature checkout whose integration branch has no merge base.
  scope_expect "$SELF_TEST_GROUPS" 'not a repository'
  git -C "$SCOPE_FIX" init -q
  git -C "$SCOPE_FIX" config user.name Fixture
  git -C "$SCOPE_FIX" config user.email fixture@example.invalid
  git -C "$SCOPE_FIX" config commit.gpgsign false
  git -C "$SCOPE_FIX" add scripts/self-test.sh scripts/tests/helpers.sh config/payload.tsv config/test-wall-ceilings.tsv
  git -C "$SCOPE_FIX" commit -qm 'Scope fixture base'
  scope_base=$(git -C "$SCOPE_FIX" rev-parse HEAD)
  scope_expect "$SELF_TEST_GROUPS" 'no remote'
  git -C "$SCOPE_FIX" remote add origin "$TMP/missing-remote"
  scope_expect "$SELF_TEST_GROUPS" 'missing origin refs'
  git -C "$SCOPE_FIX" update-ref refs/remotes/origin/main "$scope_base"
  scope_git=$(command -v git)
  cat > "$SCOPE_FIX/bin/git" <<'GIT_ERROR'
#!/usr/bin/env bash
case " $* " in
  *" $SCOPE_GIT_FAIL "*) exit 1 ;;
esac
exec "$SCOPE_REAL_GIT" "$@"
GIT_ERROR
  chmod +x "$SCOPE_FIX/bin/git"
  for scope_command in diff ls-files; do
    SCOPE_REAL_GIT="$scope_git" SCOPE_GIT_FAIL="$scope_command" PATH="$SCOPE_FIX/bin:$PATH" \
      scope_expect "$SELF_TEST_GROUPS" "git $scope_command error"
  done
  rm "$SCOPE_FIX/bin/git"
  # Build genuinely shallow history, then fetch an unrelated base tip without ancestry.
  git -C "$SCOPE_FIX" checkout -q -b shallow-feature "$scope_base"
  git -C "$SCOPE_FIX" commit --allow-empty -qm 'Shallow feature tip'
  git clone -q --depth 1 --branch shallow-feature "file://$SCOPE_FIX" "$TMP/shallow-scope"
  git -C "$TMP/shallow-scope" fetch -q --depth 1 origin "$scope_base:refs/remotes/origin/main"
  git -C "$TMP/shallow-scope" merge-base HEAD origin/main >/dev/null \
    && fail 'shallow fixture unexpectedly has a merge base'
  SCOPE_ORIGINAL=$SCOPE_FIX
  SCOPE_FIX="$TMP/shallow-scope"
  scope_expect "$SELF_TEST_GROUPS" 'shallow clone without merge base'
  SCOPE_FIX=$SCOPE_ORIGINAL
  mv "$SCOPE_FIX/config/payload.tsv" "$SCOPE_FIX/config/payload.saved"
  scope_expect "$SELF_TEST_GROUPS" 'missing manifest'
  mv "$SCOPE_FIX/config/payload.saved" "$SCOPE_FIX/config/payload.tsv"
  printf 'malformed manifest row\n' >> "$SCOPE_FIX/config/payload.tsv"
  scope_expect "$SELF_TEST_GROUPS" 'malformed manifest'
  git -C "$SCOPE_FIX" checkout -- config/payload.tsv
  scope_locals='contracts hooks'
  scope_expect "$scope_locals" 'clean integration base'
  printf 'app\n' > "$SCOPE_FIX/app.txt"
  scope_expect "$scope_locals" 'untracked application file'
  printf 'private\n' > "$SCOPE_FIX/private"
  scope_expect "$scope_locals" 'source-only destination'
  printf '\n# unstaged harness edit\n' >> "$SCOPE_FIX/scripts/self-test.sh"
  scope_expect "$SELF_TEST_GROUPS" 'unstaged harness edit'
  git -C "$SCOPE_FIX" checkout -- scripts/self-test.sh
  printf 'contract\n' > "$SCOPE_FIX/AGENTS.md"
  git -C "$SCOPE_FIX" add AGENTS.md
  scope_expect "$SELF_TEST_GROUPS" 'staged-only harness edit'
  git -C "$SCOPE_FIX" reset -q HEAD -- AGENTS.md
  rm "$SCOPE_FIX/AGENTS.md"
  printf 'new harness file\n' > "$SCOPE_FIX/scripts/untracked file"
  scope_expect "$SELF_TEST_GROUPS" 'untracked harness edit'
  rm "$SCOPE_FIX/scripts/untracked file"
  rm "$SCOPE_FIX/app.txt" "$SCOPE_FIX/private"
  printf '\n# committed harness edit\n' >> "$SCOPE_FIX/scripts/self-test.sh"
  git -C "$SCOPE_FIX" add scripts/self-test.sh
  git -C "$SCOPE_FIX" commit -qm 'Committed harness change'
  scope_expect "$SELF_TEST_GROUPS" 'committed harness edit'
  # Tracking the pushed feature branch (at HEAD) must never hide its harness edit.
  git -C "$SCOPE_FIX" branch -M feature
  git -C "$SCOPE_FIX" update-ref refs/remotes/origin/feature HEAD
  git -C "$SCOPE_FIX" branch --set-upstream-to=origin/feature feature >/dev/null
  [ -z "$(git -C "$SCOPE_FIX" status --porcelain)" ] || fail 'pushed feature fixture is not clean'
  scope_expect "$SELF_TEST_GROUPS" 'pushed feature upstream equals HEAD'
  git -C "$SCOPE_FIX" update-ref refs/remotes/origin/integration HEAD
  SCOPE_BASE_REF=origin/integration scope_expect "$scope_locals" 'explicit base precedence'
  SCOPE_PR_BASE=integration scope_expect "$scope_locals" 'PR base precedence'
  SCOPE_BASE_REF=origin/missing SCOPE_PR_BASE=integration \
    scope_expect "$scope_locals" 'first resolving base'
  # A detached PR merge with fetched base and only application changes skips scaffolds.
  git -C "$SCOPE_FIX" checkout -qb app-pr "$scope_base"
  printf 'app\n' > "$SCOPE_FIX/app.txt"
  git -C "$SCOPE_FIX" add app.txt
  git -C "$SCOPE_FIX" commit -qm 'Application-only PR'
  git -C "$SCOPE_FIX" checkout -q --detach "$scope_base"
  git -C "$SCOPE_FIX" merge --no-ff -qm 'Detached PR merge' app-pr
  SCOPE_PR_BASE=main scope_expect "$scope_locals" 'detached PR merge'
  SCOPE_BASE_REF=origin/main scope_expect "$scope_locals" 'explicit CI base'
  scope_expect "$SELF_TEST_GROUPS" 'forced groups' --all-groups
  printf '# source exporter marker\n' > "$SCOPE_FIX/scripts/export.sh"
  scope_expect "$SELF_TEST_GROUPS" 'source full suite'
  rm "$SCOPE_FIX/scripts/export.sh"
  # Rename a harness file out of its owned directory; the deleted source still counts.
  printf 'contract\n' > "$SCOPE_FIX/AGENTS.md"
  git -C "$SCOPE_FIX" add AGENTS.md
  git -C "$SCOPE_FIX" commit -qm 'Installed contract'
  git -C "$SCOPE_FIX" update-ref refs/remotes/origin/main HEAD
  git -C "$SCOPE_FIX" mv AGENTS.md app-contract.txt
  scope_expect "$SELF_TEST_GROUPS" 'renamed harness path'
  git -C "$SCOPE_FIX" reset -q --hard HEAD
  # CI must supply both integration history and the PR base in the app test job.
  awk '/^  app:/ { app=1 }
    app && /^      - name:/ { checkout=($0 ~ /Checkout$/); test=($0 ~ /Test suite$/) }
    app && checkout && /fetch-depth: 0/ { depth=1 }
    app && test && /AGENTIC_BASE_REF: origin\/\$\{\{ github.base_ref \}\}/ { base=1 }
    /^  docs:/ { exit } END { exit !(depth && base) }' "$ROOT/templates/ci/ci.yml" \
    || fail 'CI app job does not fetch history and export the PR base'

  # Exercise the exported suite and lint in order without recursively running the
  # full suite. The exported runner reports a group and a controlled copy count.
  GATE_FIX="$TMP/ship-gate"
  mkdir -p "$GATE_FIX/scripts/tests" "$GATE_FIX/bin"
  link_test_wall_ceilings "$GATE_FIX"
  ln "$ROOT/scripts/tests/helpers.sh" "$GATE_FIX/scripts/tests/helpers.sh"
  ln "$ROOT/scripts/self-test.sh" "$GATE_FIX/scripts/self-test.sh"
  ln "$ROOT/scripts/shell-inventory.sh" "$GATE_FIX/scripts/shell-inventory.sh"
  printf 'scripts/probe.sh\tscripts/probe.sh\tcore\tpreserve\texport\n' > "$GATE_FIX/config/payload.tsv"
  printf '#!/usr/bin/env bash\nunused=1\n' > "$GATE_FIX/scripts/probe.sh"
  if ! command -v shellcheck >/dev/null 2>&1; then
    # The contracts and fast gates also run on machines without ShellCheck.
    cat > "$GATE_FIX/bin/shellcheck" <<'LINT'
#!/usr/bin/env bash
if grep -Fxq 'unused=1' "$2"; then
  echo "fixture ShellCheck: $2: SC2034"
  exit 1
fi
LINT
    chmod +x "$GATE_FIX/bin/shellcheck"
  fi
  cat > "$GATE_FIX/scripts/export.sh" <<'SH'
#!/usr/bin/env bash
set -eu
mkdir -p "$1/scripts"
cat > "$1/scripts/self-test.sh" <<'RUNNER'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$GATE_CALLS"
printf 'group:hooks\n' >> "$AGENTIC_MEASURE_EVENTS"
for ((i=0; i<GATE_COPIES; i++)); do
  printf 'fixture_file_copy\n' >> "$AGENTIC_MEASURE_EVENTS"
done
[ "${GATE_FAIL:-0}" = 0 ]
RUNNER
chmod +x "$1/scripts/self-test.sh"
SH
  chmod +x "$GATE_FIX/scripts/export.sh"
  gate_make() {
    : > "$TMP/gate.calls"
    PATH="$GATE_FIX/bin:$PATH" GATE_CALLS="$TMP/gate.calls" GATE_COPIES="$1" \
      make -C "$GATE_FIX" -f "$ROOT/Makefile" ship-gate > "$TMP/gate.out" 2>&1
  }
  gate_rc=0
  GATE_FAIL=1 gate_make 0 || gate_rc=$?
  [ "$gate_rc" -ne 0 ] || fail 'ship-gate accepted a failing exported suite'
  grep -q 'group: hooks' "$TMP/gate.out" || fail 'ship-gate did not name the failing exported group'

  gate_copy_limit=117
  gate_copy_over=$((gate_copy_limit+1))
  gate_make "$gate_copy_over" && fail 'ship-gate accepted one fixture copy over the exported limit'
  grep -Fq "exported full mode made $gate_copy_over fixture file copies; limit $gate_copy_limit" "$TMP/gate.out" \
    || fail 'ship-gate did not name the exported copy count and limit'
  gate_make "$gate_copy_limit" && fail 'ship-gate accepted a ShellCheck warning in a shipped script'
  grep -q '^ship-gate passed (exported full suite)\.$' "$TMP/gate.out" \
    || fail 'ship-gate did not complete the exported suite before lint'
  grep -q 'SC2034' "$TMP/gate.out" || fail 'ship-gate did not report the ShellCheck warning'

  printf '#!/usr/bin/env bash\n:\n' > "$GATE_FIX/scripts/probe.sh"
  gate_make "$gate_copy_limit" || { cat "$TMP/gate.out" >&2; fail 'ship-gate rejected a passing exported suite'; }
  grep -qx -- '--full --all-groups' "$TMP/gate.calls" || fail 'ship-gate did not run the exported full suite'
  # CI keeps the costly exported suite as a separate step after everyday tests.
  awk '/run: make test$/ { test=NR } /run: make ship-gate$/ { gate=NR } END { exit !(test && gate>test) }' \
    "$ROOT/.github/workflows/ci.yml" || fail 'CI does not run ship-gate after make test'
  grep -q '^#ship-gate:' "$ROOT/templates/harness/Makefile" \
    || fail 'template Makefile does not document the optional ship-gate target'

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
    "$ROOT/scripts/tests/contracts.sh" \
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

# The red-first overlay carries this test file without the updated inventory.
# Exercise the ship-gate regression before checking the inventory itself.
split_regression_tests
workflow_contract_check
# T-1: keep the gate cadence identical in the live and exported role contracts.
# shellcheck disable=SC2016 # Literal Markdown command references.
cadence_contract='For each step, executors run `make check` and its Verify command; run the full `make test` once at the end of the plan. Under the controller, do not run `verify-step`.'
for cadence_file in AGENTS.md CLAUDE.md templates/harness/AGENTS.md templates/harness/CLAUDE.md \
                    .agents/skills/review-execution/SKILL.md; do
  case "$cadence_file" in
    templates/*) [ -d "$ROOT/templates/harness" ] || continue ;;
    .agents/*) active_scope codex || continue ;;
    CLAUDE.md) active_scope claude || continue ;;
  esac
  tr '\n' ' ' < "$ROOT/$cadence_file" | sed 's/[[:space:]][[:space:]]*/ /g' \
    | grep -Fq "$cadence_contract" || fail "gate cadence missing from $cadence_file"
done
# S-9: the workflow is generated once; installed projects keep rendered contracts.
if [ -d "$ROOT/templates/shared" ]; then
  [ -f "$ROOT/templates/shared/workflow.md" ] || fail 'canonical rendered workflow is missing'
  grep -q '^<!-- BEGIN SHARED WORKFLOW -->$' "$ROOT/METHODOLOGY.md" || fail 'methodology workflow region is missing'
  "$ROOT/scripts/render-shared.sh" --check >/dev/null || fail 'workflow render is stale'
  for role in CLAUDE.md AGENTS.md .agents/skills/review-execution/SKILL.md; do
    case "$role" in CLAUDE.md) baseline=1515 ;; AGENTS.md) baseline=1088 ;; *) baseline=996 ;; esac
    [ "$(wc -w < "$ROOT/$role")" -lt "$baseline" ] || fail "S-9 role did not shrink: $role"
  done
  for contract in CLAUDE.md AGENTS.md templates/harness/CLAUDE.md templates/harness/AGENTS.md \
      .opencode/agent/code-reviewer.md .agents/skills/review-execution/SKILL.md \
      .agents/skills/plan-to-issues/SKILL.md ADOPTION.md docs/README.md; do
    grep -Eq 'agent:(claude|codex|opencode)|needs-(execution|review|closing|human)' "$ROOT/$contract" \
      && fail "duplicated workflow labels in $contract"
  done

fi
# S-2: these tests travel alone to the red base, so a missing library is an assertion.
[ -f "$ROOT/scripts/lib/identity.sh" ] || fail 'identity library is missing'
IDENTITY_FIX="$TMP/identity"
mkdir -p "$IDENTITY_FIX/project/scripts/lib" "$IDENTITY_FIX/bin" "$IDENTITY_FIX/config/agentic-flow/identities/owner"
mkdir -p "$IDENTITY_FIX/project/config/stations" "$IDENTITY_FIX/codex/rules"
# This fixture exercises token and doctor, which read these inputs.
ln "$ROOT/scripts/agentic-flow" "$ROOT/scripts/doctor.sh" "$IDENTITY_FIX/project/scripts/"
ln "$ROOT/scripts/lib/identity.sh" "$ROOT/scripts/lib/review-policy.sh" \
   "$ROOT/scripts/lib/payload-apply.sh" "$ROOT/scripts/lib/git-guards.sh" "$IDENTITY_FIX/project/scripts/lib/"
ln "$ROOT/config/stations/command-policy.rules" "$IDENTITY_FIX/project/config/stations/"
ln "$ROOT/config/stations/command-policy.rules" "$IDENTITY_FIX/codex/rules/agentic-flow.rules"
(
  cd "$IDENTITY_FIX/project"
  git init -q
  git remote add origin git@github.com:owner/repo.git
)
printf 'version=1\nworkflow=.github/workflows/ci.yml\nidentity-mode=distinct-account\nreviewer=review-app[bot]\nexecutor=execute-app[bot]\napprover=plan-app[bot]\n' > "$IDENTITY_FIX/project/.agentic-flow-review-policy"
IDENTITY_CONFIG="$IDENTITY_FIX/config/agentic-flow/identities/owner/repo.tsv"
printf 'executor\texecute-app[bot]\t123\t456\ttest key\n' > "$IDENTITY_CONFIG"
openssl genrsa -out "$IDENTITY_FIX/key" 2048 >/dev/null 2>&1
openssl rsa -in "$IDENTITY_FIX/key" -pubout -out "$IDENTITY_FIX/public" >/dev/null 2>&1
cat > "$IDENTITY_FIX/bin/security" <<'MOCK'
#!/usr/bin/env bash
[ "$*" = 'find-generic-password -s test key -w' ] || exit 1
[ "${IDENTITY_CASE:-}" != key-failure ] || exit 1
if [ "${IDENTITY_CASE:-}" = invalid-key ]; then printf 'invalid'; exit 0; fi
if [ "${IDENTITY_CASE:-}" = encoded-key ]; then openssl base64 -A < "$IDENTITY_FIX/key"; exit 0; fi
cat "$IDENTITY_FIX/key"
MOCK
cat > "$IDENTITY_FIX/bin/secret-tool" <<'MOCK'
#!/usr/bin/env bash
[ "$*" = 'lookup service agentic-flow key-ref test key' ] || exit 1
cat "$IDENTITY_FIX/key"
MOCK
cat > "$IDENTITY_FIX/bin/uname" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${IDENTITY_OS:-Darwin}"
MOCK
cat > "$IDENTITY_FIX/bin/gh" <<'MOCK'
#!/usr/bin/env bash
# Token minting must never use the ambient gh identity.
printf 'ambient gh used\n' >> "$IDENTITY_FIX/ambient"
exit 1
MOCK
cat > "$IDENTITY_FIX/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
config=$(cat)
jwt=${config#*Bearer }; jwt=${jwt%%\"*}
[ "$*" != "${*#*https://api.github.com/app/installations/456/access_tokens}" ]
request=''
while [ "$#" -gt 0 ]; do
  case "$1" in --data-binary) request=$2; shift ;; esac
  shift
done
printf '%s' "$request" | jq -e '.repositories == ["repo"] and .permissions == {issues:"write",pull_requests:"write",contents:"read",metadata:"read"}' >/dev/null
base64url_decode() { local v=$1; while [ "$((${#v} % 4))" -ne 0 ]; do v="${v}="; done; printf '%s' "$v" | tr '_-' '/+' | openssl base64 -d -A; }
payload=${jwt#*.}; payload=${payload%%.*}
claims=$(base64url_decode "$payload")
printf '%s' "$claims" | jq -e --argjson now "$(date +%s)" '.iss == "123" and .iat <= $now and .exp > $now and .exp <= ($now+600)' >/dev/null
printf '%s' "${jwt%.*}" | openssl dgst -sha256 -verify "$IDENTITY_FIX/public" -signature <(base64url_decode "${jwt##*.}") >/dev/null
case "${IDENTITY_CASE:-}" in
  mint-failure) exit 22 ;;
  timeout) exit 28 ;;
  malformed) printf 'not-json'; exit 0 ;;
  broad) permission=write ;;
  *) permission=read ;;
esac
jq -n --arg contents "$permission" --arg value 'fixture-installation-value' --arg mode "${IDENTITY_CASE:-}" '
  {token:$value,expires_at:"2099-01-01T00:00:00Z",permissions:{issues:"write",pull_requests:"write",contents:$contents,metadata:"read"},repositories:[{full_name:"owner/repo"}]} |
  if $mode == "wrong-repo" then .repositories[0].full_name="owner/other"
  elif $mode == "extra-permission" then .permissions.administration="write"
  elif $mode == "expired" then .expires_at="2000-01-01T00:00:00Z"
  elif $mode == "missing-token" then del(.token) else . end'
MOCK
# Doctor's workstation inventory is unrelated to identity behavior; keep it hermetic
# on CI runners that do not install local signing wrappers or gitleaks.
for tool in git-claude git-codex gitleaks; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$IDENTITY_FIX/bin/$tool"
done
chmod +x "$IDENTITY_FIX/bin/"*
identity_run() { # role optional flags; capture output only from fake credentials
  local status=0
  # shellcheck disable=SC2097,SC2098 # Fixture env is passed to the child, not used by the parent.
  ( cd "$IDENTITY_FIX/project"; PATH="$IDENTITY_FIX/bin:$PATH" XDG_CONFIG_HOME="$IDENTITY_FIX/config" \
    IDENTITY_FIX="$IDENTITY_FIX" IDENTITY_CASE="${IDENTITY_CASE:-}" IDENTITY_OS="${IDENTITY_OS:-Darwin}" \
    scripts/agentic-flow token "$@" ) > "$TMP/identity.out" 2> "$TMP/identity.err" || status=$?
  return "$status"
}
identity_fails() { # expected-exit role flags
  local expected=$1 status=0
  shift
  identity_run "$@" || status=$?
  [ "$status" -eq "$expected" ] || fail "identity returned $status, expected $expected: $(cat "$TMP/identity.err")"
  [ ! -s "$TMP/identity.out" ] || fail 'identity failure printed credential material'
}
identity_fails 6 reviewer
for IDENTITY_CASE in key-failure invalid-key mint-failure timeout malformed broad wrong-repo extra-permission expired missing-token; do
  identity_fails 5 executor --check
done
IDENTITY_CASE=''
identity_run executor || fail "configured identity did not mint: $(cat "$TMP/identity.err")"
[ "$(cat "$TMP/identity.out")" = fixture-installation-value ] || fail 'wrong minted value'
identity_run executor --check || fail 'identity check failed'
[ ! -s "$TMP/identity.out" ] || fail 'identity check printed a token'
IDENTITY_OS=Linux identity_run executor --check || fail 'Linux keychain mint failed'
IDENTITY_CASE=encoded-key identity_run executor --check || fail 'base64 keychain mint failed'
[ ! -e "$IDENTITY_FIX/ambient" ] || fail 'identity fell back to ambient gh'
(
  . "$ROOT/scripts/lib/review-policy.sh"
  read_review_policy "$IDENTITY_FIX/project"
) || fail 'App logins rejected by review policy'
for invalid in 'review[other]' 'review[bot]tail' 'review[bot][bot]'; do
  sed "s/review-app\[bot\]/$invalid/" "$IDENTITY_FIX/project/.agentic-flow-review-policy" > "$IDENTITY_FIX/policy-bad"
  ( . "$ROOT/scripts/lib/review-policy.sh"; mkdir -p "$IDENTITY_FIX/bad"; cp "$IDENTITY_FIX/policy-bad" "$IDENTITY_FIX/bad/.agentic-flow-review-policy"; read_review_policy "$IDENTITY_FIX/bad" ) >/dev/null 2>&1 \
    && fail "invalid App login accepted: $invalid"
done
. "$ROOT/scripts/lib/review-policy.sh"
normalized=$(printf '%s' '[{"author":{"login":"review-app","__typename":"Bot"}},{"user":{"login":"review-app[bot]","type":"Bot"}},{"author":{"login":"review-app","__typename":"User"}}]' | review_normalize_comments | jq -c '[.[].author.login]')
[ "$normalized" = '["review-app[bot]","review-app[bot]","review-app"]' ] || fail 'bot author normalization conflated humans and Apps'
IDENTITY_CASE=broad identity_fails 5 executor
cp "$IDENTITY_CONFIG" "$IDENTITY_FIX/config-valid"
for defect in duplicate unknown-role invalid-id wrong-login trailing; do
  case "$defect" in
    duplicate) cat "$IDENTITY_FIX/config-valid" "$IDENTITY_FIX/config-valid" > "$IDENTITY_CONFIG" ;;
    unknown-role) printf 'stranger\texecute-app[bot]\t123\t456\ttest key\n' > "$IDENTITY_CONFIG" ;;
    invalid-id) printf 'executor\texecute-app[bot]\tinvalid\t456\ttest key\n' > "$IDENTITY_CONFIG" ;;
    wrong-login) printf 'executor\tunlisted-app[bot]\t123\t456\ttest key\n' > "$IDENTITY_CONFIG" ;;
    trailing) printf 'executor\texecute-app[bot]\t123\t456\ttest key\t\n' > "$IDENTITY_CONFIG" ;;
  esac
  identity_fails 5 executor --check
done
mv "$IDENTITY_CONFIG" "$IDENTITY_FIX/config-invalid"
identity_fails 6 executor
cp "$IDENTITY_FIX/config-valid" "$IDENTITY_CONFIG"
printf 'reviewer\treview-app[bot]\t123\t456\ttest key\napprover\tplan-app[bot]\t123\t456\ttest key\n' >> "$IDENTITY_CONFIG"
identity_doctor() {
  # shellcheck disable=SC2097,SC2098 # Pass fixture state to the child.
  PATH="$IDENTITY_FIX/bin:$PATH" XDG_CONFIG_HOME="$IDENTITY_FIX/config" IDENTITY_FIX="$IDENTITY_FIX" \
    CODEX_HOME="$IDENTITY_FIX/codex" \
    "$IDENTITY_FIX/project/scripts/doctor.sh" --check --scope env > "$TMP/identity-doctor.out" 2>&1
}
identity_doctor || fail "doctor rejected valid role identities: $(cat "$TMP/identity-doctor.out")"
grep -q 'ok.*identity approver login and token scope' "$TMP/identity-doctor.out" || fail 'doctor skipped configured identity'
IDENTITY_CASE=broad; export IDENTITY_CASE
identity_doctor && fail 'doctor accepted broader permissions'
unset IDENTITY_CASE
if grep -q 'fixture-installation-value' "$TMP/identity-doctor.out"; then fail 'doctor leaked a token'; fi
WORKFLOW_FIX="$TMP/workflow"
mkdir -p "$WORKFLOW_FIX/config"
workflow_reject() { # <description> <expected diagnostic>
  local output status=0
  output=$(workflow_load "$WORKFLOW_FIX" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "workflow accepted $1"
  printf '%s\n' "$output" | grep -Eq 'workflow.tsv:[0-9]+:' \
    || fail "workflow diagnostic omitted file and line: $output"
  printf '%s\n' "$output" | grep -Fq "$2" || fail "workflow diagnostic: $output"
}
for defect in spaces trailing unknown-label duplicate unreachable missing-state self-loop role requirement; do
  case "$defect" in
    spaces) printf 'state step-strict executing agent:codex,needs-execution open\n' > "$WORKFLOW_FIX/config/workflow.tsv"; diagnostic='fields' ;;
    trailing) printf 'state\tstep-strict\texecuting\tagent:codex,needs-execution\topen\t\n' > "$WORKFLOW_FIX/config/workflow.tsv"; diagnostic='fields' ;;
    unknown-label) sed 's/needs-execution/unknown-label/' "$ROOT/config/workflow.tsv" > "$WORKFLOW_FIX/config/workflow.tsv"; diagnostic='label' ;;
    duplicate) cat "$ROOT/config/workflow.tsv" > "$WORKFLOW_FIX/config/workflow.tsv"; printf 'transition\tstep-strict\tsubmit\texecutor\texecuting\treviewing\thead,head≠last-bounced-head\n' >> "$WORKFLOW_FIX/config/workflow.tsv"; diagnostic='duplicate' ;;
    unreachable) cat "$ROOT/config/workflow.tsv" > "$WORKFLOW_FIX/config/workflow.tsv"; printf 'state\tstep-strict\torphan\t-\tclosed\n' >> "$WORKFLOW_FIX/config/workflow.tsv"; diagnostic='unreachable' ;;
    missing-state) sed 's/	reviewing	head/	absent	head/' "$ROOT/config/workflow.tsv" > "$WORKFLOW_FIX/config/workflow.tsv"; diagnostic='unknown state' ;;
    self-loop) sed 's/	executing	reviewing	/	executing	executing	/' "$ROOT/config/workflow.tsv" > "$WORKFLOW_FIX/config/workflow.tsv"; diagnostic='self-loop' ;;
    role) sed 's/	executor	/	stranger	/' "$ROOT/config/workflow.tsv" > "$WORKFLOW_FIX/config/workflow.tsv"; diagnostic='role' ;;
    requirement) sed 's/head=submitted/anything/' "$ROOT/config/workflow.tsv" > "$WORKFLOW_FIX/config/workflow.tsv"; diagnostic='requirement' ;;
  esac
  workflow_reject "$defect" "$diagnostic"
done
workflow_load "$ROOT" || fail 'valid workflow rejected'
[ "$(workflow_successor step-strict reviewing bounce 1)" = executing ] || fail 'second bounce did not execute'
[ "$(workflow_successor step-strict reviewing bounce 2)" = escalated ] || fail 'third bounce did not escalate'
[ "$(workflow_successor work-standard reviewing approve 0)" = closing ] || fail 'Standard approval did not close out'
[ "$(workflow_successor step-strict reviewing approve 0)" = approved ] || fail 'Strict approval did not approve'
[ "$(workflow_successor tracker open notify 0)" = closing ] || fail 'tracker notify did not close out'
[ "$(workflow_state_labels step-strict approved)" = '-' ] || fail 'approved labels not empty'
workflow_successor step-strict executing approve 0 >/dev/null 2>&1 && fail 'illegal successor accepted'
workflow_successor step-strict reviewing bounce bad >/dev/null 2>&1 && fail 'invalid bounce count accepted'
workflow_state_labels tracker absent >/dev/null 2>&1 && fail 'unknown state labels accepted'
mkdir -p "$WORKFLOW_FIX/scripts/lib" "$WORKFLOW_FIX/scripts/hooks"
cp "$ROOT/config/workflow.tsv" "$WORKFLOW_FIX/config/workflow.tsv"
cp "$ROOT/scripts/lib/workflow.sh" "$WORKFLOW_FIX/scripts/lib/workflow.sh"
cp "$ROOT/scripts/create-tags.sh" "$WORKFLOW_FIX/scripts/create-tags.sh"
reader=scripts/lifecycle-status.sh
  cp "$ROOT/scripts/hooks/require-step-comment.sh" "$WORKFLOW_FIX/scripts/hooks/require-step-comment.sh"
  sed 's/needs-closing/needs-unknown/g' "$ROOT/$reader" > "$WORKFLOW_FIX/$reader"
  ( workflow_contract_check "$WORKFLOW_FIX" ) > "$TMP/workflow-drift.out" 2>&1 \
    && fail "workflow accepted drift in $reader"
  grep -Fq 'hard-coded workflow labels drifted' "$TMP/workflow-drift.out" \
    || fail 'workflow drift diagnostic missing'
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

  # A customized adopter may predate installation records. Sources are not installed.
  inventory_adopter="$TMP/inventory-adopter"
  "$ROOT/scripts/export.sh" --exclude-scope=codex "$inventory_adopter" >/dev/null
  rm "$inventory_adopter/.agentic-flow-installation"
  (cd "$inventory_adopter" && scripts/shell-inventory.sh --syntax) \
    > "$TMP/inventory-adopter.out" 2>&1 \
    || { cat "$TMP/inventory-adopter.out" >&2; fail "recordless adopter syntax gate failed"; }
  (cd "$inventory_adopter" && make check) > "$TMP/inventory-adopter-check.out" 2>&1 \
    || { cat "$TMP/inventory-adopter-check.out" >&2; fail "recordless adopter make check failed"; }
  # Excluded destinations remain absent; deleting an active destination must fail by name.
  [ ! -e "$inventory_adopter/.codex/hooks.json" ] \
    || fail "inventory fixture unexpectedly installed excluded scope"
  rm "$inventory_adopter/scripts/agentic-flow"
  (cd "$inventory_adopter" && scripts/shell-inventory.sh --syntax) \
    > "$TMP/inventory-missing.out" 2>&1 \
    && fail "recordless inventory accepted a missing active script"
  grep -q 'shell inventory: missing installed file scripts/agentic-flow; run scripts/doctor.sh' \
    "$TMP/inventory-missing.out" \
    || fail "recordless inventory did not name the missing installed script"
  rm "$inventory_adopter/AGENTS.md"
  (cd "$inventory_adopter" && scripts/shell-inventory.sh --syntax) \
    > "$TMP/inventory-missing.out" 2>&1 \
    && fail "recordless inventory accepted a missing mapped destination"
  grep -q 'shell inventory: missing installed file AGENTS.md; run scripts/doctor.sh' \
    "$TMP/inventory-missing.out" \
    || fail "recordless inventory did not check mapped destinations"

  if command -v shellcheck >/dev/null 2>&1; then
    lint_fix="$TMP/shell-lint-fixture"
    mkdir -p "$lint_fix/config" "$lint_fix/scripts" "$lint_fix/fixtures" "$lint_fix/bin"
    touch "$lint_fix/scripts/export.sh"
    printf 'fixtures\tscripts\tcore\tpreserve\texport\n' > "$lint_fix/config/payload.tsv"
    # shellcheck disable=SC2016 # Deliberate unquoted expansion for the failure fixture.
    printf '#!/usr/bin/env bash\nprintf %%s $unquoted\n' > "$lint_fix/fixtures/01-bad.sh"
    printf '#!/usr/bin/env bash\nprintf clean\n' > "$lint_fix/fixtures/02-clean file.sh"
    cat > "$lint_fix/bin/shellcheck" <<'SH'
#!/usr/bin/env bash
printf '%s\n' call "$@" >> "$SHELLCHECK_CALL_LOG"
exec "$REAL_SHELLCHECK" "$@"
SH
    chmod +x "$lint_fix/bin/shellcheck"
    real_shellcheck=$(command -v shellcheck)
    printf '%s\n' call -x "$lint_fix/fixtures/01-bad.sh" call -x "$lint_fix/fixtures/02-clean file.sh" \
      > "$lint_fix/expected-calls"
    PATH="$lint_fix/bin:$PATH" REAL_SHELLCHECK="$real_shellcheck" \
      SHELLCHECK_CALL_LOG="$lint_fix/calls" AGENTIC_PROJECT_ROOT="$lint_fix" \
      "$ROOT/scripts/shell-inventory.sh" --lint > "$lint_fix/out" 2>&1 \
      && fail "ShellCheck gate accepted a fixture with a finding"
    grep -Fq "$lint_fix/fixtures/01-bad.sh" "$lint_fix/out" \
      || fail "ShellCheck gate lost the failing file's path"
    grep -q SC2086 "$lint_fix/out" \
      || fail "ShellCheck gate lost the failing file's diagnostic"
    cmp -s "$lint_fix/expected-calls" "$lint_fix/calls" \
      || fail "ShellCheck must lint every file separately with -x, in inventory order, after a failure"

    printf '#!/usr/bin/env bash\nprintf clean\n' > "$lint_fix/fixtures/01-bad.sh"
    cat > "$lint_fix/fixtures/02-clean file.sh" <<'SH'
#!/usr/bin/env bash
helper_value=used
# shellcheck source-path=SCRIPTDIR
. ./helper.sh
SH
    # No shebang: this helper is followed through source, not linted as an inventory file.
    # shellcheck disable=SC2016 # The generated helper consumes the caller's variable.
    printf 'printf "%%s\\n" "$helper_value"\n' > "$lint_fix/fixtures/helper.sh"
    : > "$lint_fix/calls"
    PATH="$lint_fix/bin:$PATH" REAL_SHELLCHECK="$real_shellcheck" \
      SHELLCHECK_CALL_LOG="$lint_fix/calls" AGENTIC_PROJECT_ROOT="$lint_fix" \
      "$ROOT/scripts/shell-inventory.sh" --lint > "$lint_fix/out" 2>&1 \
      || { cat "$lint_fix/out" >&2; fail "ShellCheck gate rejected clean files with a sourced helper"; }
    [ ! -s "$lint_fix/out" ] || fail "ShellCheck gate reported findings for clean files"
    cmp -s "$lint_fix/expected-calls" "$lint_fix/calls" \
      || fail "ShellCheck omitted or combined clean inventory files"
  fi

  shell_fix="$TMP/shell-inventory-fixture"
  mkdir -p "$shell_fix/source/config" "$shell_fix/source/scripts" \
    "$shell_fix/source/harness-src" "$shell_fix/source/scoped-src"
  cp "$ROOT/scripts/shell-inventory.sh" "$shell_fix/source/scripts/"
  touch "$shell_fix/source/scripts/export.sh"
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
  # shellcheck disable=SC2016 # Literal Makefile variable references.
  grep -q 'scripts/self-test.sh --only "$(F)" --scenario "$(S)"' "$mf" \
    || fail "$mf does not forward controller scenario selection"
  grep -q 'usage: make test-one .*S=' "$mf" \
    || fail "$mf usage omits S="
done
if [ -f "$ROOT/templates/harness/Makefile" ]; then
  sed -n '/^test-one:/,/^$/p' "$ROOT/Makefile" > "$TMP/root-test-one"
  sed -n '/^test-one:/,/^$/p' "$ROOT/templates/harness/Makefile" > "$TMP/template-test-one"
  cmp -s "$TMP/root-test-one" "$TMP/template-test-one" \
    || fail 'root and template Makefile test-one call sites differ'
fi

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

# Scenario 10 (Phase 4): catch dangling documentation links and require an actual
# command example for every command listed in the CLI's public usage.
reference_docs_tests() (
  # The explainer and the repository-wide documentation scan are scaffold checks.
  # The export group scans its fresh adopter with the host's tools.
  [ -f "$ROOT/scripts/export.sh" ] || return 0
  local fixture="$TMP/reference-docs" checker="$ROOT/scripts/lib/check-doc-links.pl"
  local usage explainer command
  mkdir -p "$fixture/docs"
  printf '[Missing reference](docs/missing.md)\n' > "$fixture/README.md"
  if perl "$checker" "$fixture" > "$fixture/out" 2>&1; then
    fail 'documentation link check accepted a missing target'
  fi
  grep -Fq 'README.md:1: broken local link: docs/missing.md' "$fixture/out" \
    || { cat "$fixture/out" >&2; fail 'documentation link check did not report the dangling link'; }
  cat > "$fixture/docs/missing.md" <<'MARKDOWN'
# Reference

`[Example](example-only.md)`
MARKDOWN
  perl "$checker" "$fixture" || fail 'documentation link check rejected a restored target'
  printf '<a href="docs/missing.md#wrong">Reference</a>\n' > "$fixture/README.md"
  if perl "$checker" "$fixture" > "$fixture/out" 2>&1; then
    fail 'documentation link check accepted a missing fragment'
  fi
  grep -Fq 'README.md:1: broken local link: docs/missing.md#wrong' "$fixture/out" \
    || fail 'documentation link check did not name the missing fragment'
  printf '<a href="docs/missing.md#reference">Reference</a>\n' > "$fixture/README.md"
  perl "$checker" "$fixture" || fail 'documentation link check rejected a valid fragment'

  perl "$checker" "$ROOT" || fail 'scaffold documentation has broken local links'
  explainer="$ROOT/docs/agentic-flow-explained.html"
  [ -f "$explainer" ] || fail 'missing scaffold workflow explainer'
  usage=$("$ROOT/scripts/agentic-flow" --help 2>&1) || fail 'could not read agentic-flow usage'
  usage=$(awk '$1 == "agentic-flow" && $2 ~ /^[a-z][a-z0-9_-]*$/ {print $2}' <<< "$usage" | sort -u)
  [ -n "$usage" ] || fail 'no subcommands found in agentic-flow usage'
  while IFS= read -r command; do
    grep -Eq "<code>(scripts/)?agentic-flow ${command}(</code>|[[:space:]])" "$explainer" \
      || fail "workflow explainer is missing an agentic-flow $command command example"
  done <<< "$usage"
)
reference_docs_tests

# --- harness/template section sync -------------------------------------------------------
# CLAUDE.md and AGENTS.md exist twice on purpose and their prose legitimately differs, so
# nothing compared them and a section added to one side shipped unnoticed. The guard asserts
# structure only; assert it fires in both directions, or it is decoration.
SYNC="$ROOT/scripts/check-harness-sync.sh"
if [ -x "$SYNC" ]; then
  SYNCFIX="$TMP/harness-sync-fixture"
  mkdir -p "$SYNCFIX/templates/harness" "$SYNCFIX/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SYNCFIX/scripts/render-command-policy.sh"
  chmod +x "$SYNCFIX/scripts/render-command-policy.sh"
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

  # An adopted project can retain a pre-split methodology after upgrading.
  ADOPTEDFIX="$TMP/harness-sync-adopted"
  mkdir -p "$ADOPTEDFIX/scripts"
  ln "$SYNCFIX/scripts/render-command-policy.sh" "$ADOPTEDFIX/scripts/render-command-policy.sh"
  printf '# Contract\n\n## Roles\n' > "$ADOPTEDFIX/CLAUDE.md"
  printf '# Methodology\n\n## 9. Starting a project\n\nAdopter guidance.\n' > "$ADOPTEDFIX/METHODOLOGY.md"
  AGENTIC_PROJECT_ROOT="$ADOPTEDFIX" "$SYNC" >/dev/null 2>&1 \
    || fail "harness sync failed in an adopted project with no templates/harness"

fi

# A generated consumer must match its complete canonical body. A malformed render
# graph must leave every consumer untouched, including those before the bad one.
if [ -d "$ROOT/templates/shared" ]; then
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
  for rel in config/workflow.tsv scripts/lib/workflow.sh \
             Makefile templates/harness/Makefile AGENTS.md templates/harness/AGENTS.md \
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
  sed 's/needs-human/needs-review/g' "$ROOT/config/workflow.tsv" > "$RENDER_FIX/config/workflow.tsv"
  AGENTIC_PROJECT_ROOT="$RENDER_FIX" "$ROOT/scripts/render-shared.sh" --check > "$TMP/workflow-drift.out" 2>&1 \
    && fail 'changed workflow data was accepted as fresh'
  grep -q 'shared render drift: templates/shared/workflow.md' "$TMP/workflow-drift.out" || fail 'workflow drift did not name generated source'
  AGENTIC_PROJECT_ROOT="$RENDER_FIX" "$ROOT/scripts/render-shared.sh" >/dev/null || fail 'workflow regeneration failed'
  AGENTIC_PROJECT_ROOT="$RENDER_FIX" "$ROOT/scripts/render-shared.sh" --check >/dev/null || fail 'regenerated workflow is stale'
  installed_render_fix="$TMP/installed-render"
  mkdir -p "$installed_render_fix"
  AGENTIC_PROJECT_ROOT="$installed_render_fix" "$ROOT/scripts/render-shared.sh" --check >/dev/null \
    || fail 'installed project requires absent render sources'
  # Invalid input must leave every consumer untouched.
  cp "$RENDER_FIX/METHODOLOGY.md" "$TMP/workflow-before"
  printf 'invalid\n' >> "$RENDER_FIX/config/workflow.tsv"
  AGENTIC_PROJECT_ROOT="$RENDER_FIX" "$ROOT/scripts/render-shared.sh" > "$TMP/workflow-invalid.out" 2>&1 \
    && fail 'invalid workflow rendered successfully'
  cmp -s "$RENDER_FIX/METHODOLOGY.md" "$TMP/workflow-before" || fail 'invalid workflow partially rewrote contracts'
  cp "$ROOT/config/workflow.tsv" "$RENDER_FIX/config/workflow.tsv"
  AGENTIC_PROJECT_ROOT="$RENDER_FIX" "$RENDER" >/dev/null || fail 'workflow restore failed'
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
    grep -q 'verify-step' "$surface" \
      || fail "review guidance does not route isolated red-first verification through verify-step"
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

# One set of engineering standards across every surface that states them. The reference
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
standards_surfaces=("$ROOT/docs/reference/engineering-standards.md" "$ROOT/AGENTS.md")
[ -f "$ROOT/templates/harness/AGENTS.md" ] \
  && standards_surfaces+=("$ROOT/templates/harness/AGENTS.md")
for standards_surface in "${standards_surfaces[@]}"; do
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

# Legacy hook scripts remain in the payload for adopters pending migration.
# The contracts describe the active command policy and hooks.
if active_scope claude; then
  for hook_base in command-policy.tsv scripts/git-hooks/pre-commit check-gate.sh \
                   session-context.sh guard-attached-git-dir.sh; do
    grep -Fq "$hook_base" "$ROOT/CLAUDE.md" \
      || fail "CLAUDE.md does not document the shipped hook $hook_base"
  done
fi

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
  if ! grep -q 'verify-step' "$reviewer_surface" || ! grep -q 'sha.*and.*tree' "$reviewer_surface"; then
    fail "${reviewer_surface#"$ROOT"/} does not bind verification reuse to sha and tree"
  fi
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
mkdir -p "$DISPATCH_FIX/tests"
link_test_wall_ceilings "${DISPATCH_FIX%/scripts}"
ln "$ROOT/scripts/tests/helpers.sh" "$DISPATCH_FIX/tests/helpers.sh"
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

# Memory entries must leave the fixture's lifecycle index unchanged.
rm -r "$DOC_STAGE_FIX/docs/unknown"
mkdir "$DOC_STAGE_FIX/docs/memory"
AGENTIC_PROJECT_ROOT="$DOC_STAGE_FIX" "$ROOT/scripts/docs-index.sh" >/dev/null
printf '%s\n' '# probe' > "$DOC_STAGE_FIX/docs/memory/self-test-stage-probe.md"
AGENTIC_PROJECT_ROOT="$DOC_STAGE_FIX" "$ROOT/scripts/docs-index.sh" --check >/dev/null 2>&1 \
  || fail "docs-index.sh rejects a .md under docs/memory/ — extend its skip list"

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
  printf 'source_snapshot_copy\nfixture_tree_copy\n' > "$MEASURE_FIX/full-files.events"
  for ((copy_i=0; copy_i<195; copy_i++)); do
    printf 'fixture_file_copy\n' >> "$MEASURE_FIX/full-files.events"
  done
  ( assert_cost_budget "$MEASURE_FIX/full-files.events" full ) \
    > "$MEASURE_FIX/full-files.out" 2>&1 \
    && fail 'full fixture budget accepted 195 copies'
  grep -q 'full mode made 195 fixture file copies; limit 194' "$MEASURE_FIX/full-files.out" \
    || fail 'full fixture copy failure did not name the count and approved limit'
  sed '$d' "$MEASURE_FIX/full-files.events" > "$MEASURE_FIX/full-boundary.events"
  assert_cost_budget "$MEASURE_FIX/full-boundary.events" full \
    || fail 'full fixture budget rejected its approved 194-copy boundary'
fi
: > "$MEASURE_FIX/fast-files.events"
for ((copy_i=0; copy_i<34; copy_i++)); do
  printf 'fixture_file_copy\n' >> "$MEASURE_FIX/fast-files.events"
done
( assert_cost_budget "$MEASURE_FIX/fast-files.events" fast ) \
  > "$MEASURE_FIX/fast-files.out" 2>&1 \
  && fail 'fast fixture budget accepted 34 copies'
grep -q 'fast mode made 34 fixture file copies; limit 33' "$MEASURE_FIX/fast-files.out" \
  || fail 'fast fixture copy failure did not name the count and approved limit'
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
  [ "$actual_fast_groups" = 'contracts controller hooks lifecycle plan-to-issues stations ' ] \
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

# The final negative case returns nonzero when it passes; sourcing must succeed.
:
