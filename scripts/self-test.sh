#!/usr/bin/env bash
# self-test.sh — offline regression checks for the agentic-flow scaffold.
#
# --full runs every group in the scaffold source (scripts/export.sh present). In an
# exported project it runs local groups, adding scaffold groups on payload-destination
# changes against the integration base (or when Git cannot compute that changed set).
# --full --all-groups forces every group. --jobs or AGENTIC_TEST_JOBS sets the
# full-run worker limit, capped at the available CPUs. --fast runs the smoke gate.
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
SHIP_GATE=0
ALL_GROUPS=0
JOBS_SET=0
REQUESTED_JOBS=""
SCENARIO_SET=0
SCENARIOS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fast)
      SELF_TEST_MODE=fast
      shift
      ;;
    --ship-gate)
      SHIP_GATE=1
      shift
      ;;
    --full)
      SELF_TEST_MODE=full
      shift
      ;;
    --all-groups)
      ALL_GROUPS=1
      shift
      ;;
    --jobs)
      [ "$#" -ge 2 ] || { echo "error: --jobs requires a positive integer" >&2; exit 2; }
      JOBS_SET=1
      REQUESTED_JOBS="$2"
      shift 2
      ;;
    --only)
      [ "$#" -ge 2 ] || { echo "error: --only requires a group" >&2; exit 2; }
      ONLY_GROUP="$2"
      shift 2
      ;;
    --scenario)
      [ "$#" -ge 2 ] || { echo "error: --scenario requires tags" >&2; exit 2; }
      SCENARIO_SET=1
      SCENARIOS="$2"
      shift 2
      ;;
    -h|--help)
      echo "usage: $0 [--ship-gate|--fast|--full [--jobs N] [--all-groups]|--only export|contracts|hooks|plan-to-issues|lifecycle|upgrade|stations|controller] [--scenario TAG[,TAG] (controller: launch,ledger,recovery,ship,andon; stations: launch,packet,verify,handoff)]" >&2
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done
if [ "$JOBS_SET" = 1 ]; then
  [ "$SELF_TEST_MODE" = full ] && [ -z "$ONLY_GROUP" ] && [ "$SHIP_GATE" = 0 ] \
    || { echo 'error: --jobs requires --full' >&2; exit 2; }
elif [ "$SELF_TEST_MODE" = full ] && [ -z "$ONLY_GROUP" ]; then
  REQUESTED_JOBS=${AGENTIC_TEST_JOBS:-}
fi
if [ "$JOBS_SET" = 1 ] || [ -n "$REQUESTED_JOBS" ]; then
  case "$REQUESTED_JOBS" in
    *[!0-9]*) echo 'error: self-test jobs must be a positive integer' >&2; exit 2 ;;
  esac
  REQUESTED_JOBS=${REQUESTED_JOBS#"${REQUESTED_JOBS%%[!0]*}"}
  [ -n "$REQUESTED_JOBS" ] || { echo 'error: self-test jobs must be a positive integer' >&2; exit 2; }
fi
# Use the historical serial order for the full run and its log report.
SELF_TEST_GROUPS="export contracts upgrade hooks plan-to-issues lifecycle stations controller"
# Groups inspecting installed contracts/wiring stay local; fixture regressions are scaffold.
SELF_TEST_GROUP_SCOPES="export:scaffold contracts:local hooks:local plan-to-issues:scaffold lifecycle:scaffold upgrade:scaffold stations:scaffold controller:scaffold"
# GROUP SCOPE VALIDATION BEGIN: also runs in --fast, before any fixtures.
scope_seen=" "
for scope_entry in $SELF_TEST_GROUP_SCOPES; do
  scope_group=${scope_entry%%:*}
  scope_kind=${scope_entry#*:}
  case " $SELF_TEST_GROUPS " in
    *" $scope_group "*) ;;
    *) echo "self-test failed: scope for unknown group: $scope_group" >&2; exit 1 ;;
  esac
  case "$scope_kind" in
    local|scaffold) ;;
    *) echo "self-test failed: invalid scope: $scope_entry" >&2; exit 1 ;;
  esac
  case "$scope_seen" in
    *" $scope_group "*) echo "self-test failed: duplicate scope: $scope_group" >&2; exit 1 ;;
  esac
  scope_seen="$scope_seen$scope_group "
done
for scope_group in $SELF_TEST_GROUPS; do
  case "$scope_seen" in
    *" $scope_group "*) ;;
    *) echo "self-test failed: missing scope: $scope_group" >&2; exit 1 ;;
  esac
done
# GROUP SCOPE VALIDATION END
GROUPS_RAN=" "
case " $SELF_TEST_GROUPS " in
  *" $ONLY_GROUP "*) ;;
  *) [ -z "$ONLY_GROUP" ] || { echo "unknown self-test group: $ONLY_GROUP" >&2; exit 2; } ;;
esac
# SCENARIO DISPATCH BEGIN: validate before fixtures or group checks run.
# Order tags by the first block that uses each tag in the serial runner.
CONTROLLER_SCENARIOS="launch ship andon ledger recovery"
CONTROLLER_BLOCKS="timing:launch ship:ship andon:andon launch:launch ledger:ledger recovery:recovery"
STATIONS_SCENARIOS="launch verify handoff packet"
STATIONS_BLOCKS="watchdogs:launch cache:verify slice:launch journal:handoff cli:handoff interrupt:verify red-first:verify packet:packet closeout:handoff settings:launch"
SCENARIO_BLOCKS_RAN=" "
if [ "$SCENARIO_SET" = 1 ]; then
  case "$ONLY_GROUP" in
    controller) SCENARIO_TAGS=$CONTROLLER_SCENARIOS ;;
    stations) SCENARIO_TAGS=$STATIONS_SCENARIOS ;;
    *) echo 'error: --scenario requires --only controller or --only stations' >&2; exit 2 ;;
  esac
  case "$SCENARIOS" in
    ''|,*|*,|*,,*) echo 'error: --scenario requires a nonempty comma-separated selection' >&2; exit 2 ;;
  esac
  scenario_rest=$SCENARIOS
  while [ -n "$scenario_rest" ]; do
    scenario=${scenario_rest%%,*}
    case "$scenario" in
      *[!a-z]*) echo "unknown $ONLY_GROUP scenario: $scenario" >&2; exit 2 ;;
    esac
    case " $SCENARIO_TAGS " in
      *" $scenario "*) ;;
      *) echo "unknown $ONLY_GROUP scenario: $scenario" >&2; exit 2 ;;
    esac
    case "$scenario_rest" in *,*) scenario_rest=${scenario_rest#*,} ;; *) break ;; esac
  done
fi
# SCENARIO DISPATCH END
TMPDIR_ROOT=${TMPDIR:-/tmp}
TMP=$(mktemp -d "$TMPDIR_ROOT/agentic-flow-test.XXXXXX")
SHARD_DIR=${AGENTIC_SELF_TEST_SHARD_DIR:-}
unset AGENTIC_SELF_TEST_SHARD_DIR
LOCAL_EVENTS="${SHARD_DIR:-$TMP}/local-events"
: > "$LOCAL_EVENTS"
REPORT_EVENTS=${AGENTIC_MEASURE_EVENTS:-}
PROJECT_TOKEN="$(printf '{%sPROJECT_NAME}%s' '{' '}')"
# Matches only real scaffold placeholders (double-brace UPPER_SNAKE), not the
# dollar-brace expression syntax that shipped docs quote when documenting CI workflows.
# Built with printf so this file never contains a literal placeholder to self-match.
TOKEN_RE="$(printf '{%s[A-Z][A-Z0-9_]*}%s' '{' '}')"
# TIMING BEGIN: separate from cost events; disabled runs do no clock/file work.
TEST_TIMING=0
case "${AGENTIC_TEST_TIMING:-}" in
  ''|*[!0-9]*) ;;
  *) case "$AGENTIC_TEST_TIMING" in *[1-9]*) TEST_TIMING=1 ;; esac ;;
esac
if [ "$TEST_TIMING" = 1 ]; then
  TEST_TIMING_EVENTS="$TMP/timing"
  : > "$TEST_TIMING_EVENTS"
fi

test_timing_begin() { # <block|call|reset> <name> [caller depth]
  [ "$TEST_TIMING" = 1 ] || return 0
  local depth=${3:-0}
  printf 'begin\t%s\t%s\t%s\t%s:%s\n' "$SECONDS" "$1" "$2" \
    "${BASH_SOURCE[$((depth+1))]}" "${BASH_LINENO[$depth]}" >> "$TEST_TIMING_EVENTS"
}

test_timing_end() { # Preserve the last command's status and its errexit context.
  local status=$?
  if [ "$TEST_TIMING" = 1 ]; then
    printf 'end\t%s\n' "$SECONDS" >> "$TEST_TIMING_EVENTS"
  fi
  return "$status"
}

test_timing_report() {
  [ "$TEST_TIMING" = 1 ] || return 0
  [ -s "$TEST_TIMING_EVENTS" ] || return 0
  # Begin records survive a failing subshell or exit; unfinished spans end here.
  awk -F '\t' -v now="$SECONDS" '
    $1=="begin" { n++; stack[++depth]=n; started[n]=$2; kind[n]=$3; name[n]=$4; site[n]=$5 }
    $1=="end" { elapsed[stack[depth]]=$2-started[stack[depth]]; done[stack[depth]]=1; depth-- }
    END {
      for (i=1; i<=n; i++) {
        seconds=(done[i] ? elapsed[i] : now-started[i])
        if (kind[i]=="block") printf "block %s: %d seconds%s\n", name[i], seconds, (done[i] ? "" : " (incomplete)")
        if (kind[i]=="reset") { resets++; reset_seconds+=seconds }
        if (kind[i]=="call") { calls++; times[calls]=seconds; sites[calls]=site[i] }
      }
      print "slowest c4_run/c5_run calls (seconds file:line):"
      # Only 15 selections, regardless of how many calls the suite adds.
      for (rank=1; rank<=15 && rank<=calls; rank++) {
        best=0
        for (i=1; i<=calls; i++) if (!used[i] && (!best || times[i]>times[best])) best=i
        printf "%d %s\n", times[best], sites[best]; used[best]=1
      }
      printf "resets: %d calls, %d seconds total (includes nested resets)\n", resets, reset_seconds
    }
  ' "$TEST_TIMING_EVENTS" >&2
}
trap 'test_timing_report; rm -rf "$TMP"' EXIT
# TIMING END

if [ -n "$SHARD_DIR" ]; then
  export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/config-home"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME"
  shared_snapshot="${SHARD_DIR%/*}/source-snapshot"
  if [ -d "$shared_snapshot" ]; then SOURCE_SNAPSHOT="$shared_snapshot"; fi
fi

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

# A red-first overlay can contain only the dispatcher and contracts tests.
# Fail as an assertion before sourcing an absent split dependency.
if [ ! -f "$ROOT/scripts/tests/helpers.sh" ]; then
  echo 'self-test failed: missing self-test helper file: scripts/tests/helpers.sh' >&2
  exit 1
fi
# shellcheck source=scripts/tests/helpers.sh
. "$ROOT/scripts/tests/helpers.sh"

cost_count() { # <event-file> <event>
  awk -v event="$2" '$0 == event { n++ } END { print n+0 }' "$1"
}

assert_cost_budget() { # <event-file> <fast|full>
  local events="$1" mode="$2" file_copies
  file_copies=$(cost_count "$events" fixture_file_copy)
  if [ "$mode" = fast ]; then
    [ "$(cost_count "$events" source_snapshot_copy)" -eq 0 ] || fail 'fast mode built a source snapshot'
    [ "$(cost_count "$events" fixture_tree_copy)" -eq 0 ] || fail 'fast mode copied a fixture tree'
    [ "$file_copies" -le 33 ] || fail "fast mode made $file_copies fixture file copies; limit 33"
  elif [ -f "$ROOT/scripts/export.sh" ]; then
    # Exported projects omit the source-only exporter and never build this
    # snapshot. The approved full-copy limits describe scaffold verification.
    [ "$(cost_count "$events" source_snapshot_copy)" -eq 1 ] || fail 'full mode did not reuse one source snapshot'
    [ "$(cost_count "$events" fixture_tree_copy)" -le 1 ] || fail 'full mode exceeded one fixture tree copy'
    # Approved 2026-11-18: the first full run with the snapshot uncounted
    # (989e849) measured 190 test copies; the derived 188 was two short.
    # The snapshot is counted once above; retain the one-tree and fast limits.
    [ "$file_copies" -le 190 ] || fail "full mode made $file_copies fixture file copies; limit 190"
  fi
  [ "$(cost_count "$events" path_directory_scan)" -eq 0 ] || fail "$mode mode scanned PATH directories"
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
  elif [ "$SELF_TEST_MODE" = full ]; then
    case " $SELECTED_FULL_GROUPS " in *" $1 "*) ;; *) return 1 ;; esac
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

# SCENARIO HELPERS BEGIN
scenario_group_begin() { # <controller|stations>; isolate markers in whole-suite runs.
  SCENARIO_GROUP=$1
  case "$1" in
    controller) SCENARIO_BLOCKS=$CONTROLLER_BLOCKS ;;
    stations) SCENARIO_BLOCKS=$STATIONS_BLOCKS ;;
  esac
  SCENARIO_BLOCKS_RAN=" "
}

scenario_selected() { # <tag>; no flag means every scenario, including CI's --full run.
  [ "$SCENARIO_SET" = 1 ] || return 0
  case ",$SCENARIOS," in *",$1,"*) return 0 ;; esac
  return 1
}

should_run_scenario() { # <tag> <unique-block-name>
  case " $SCENARIO_BLOCKS " in
    *" $2:$1 "*) ;;
    *) if [ "$SCENARIO_GROUP" = controller ]; then
         fail "unknown controller scenario block at call site: $2:$1"
       else fail "unknown stations scenario block at call site: $2:$1"; fi ;;
  esac
  scenario_selected "$1" || return 1
  SCENARIO_BLOCKS_RAN="$SCENARIO_BLOCKS_RAN $2:$1 "
  measure_event "scenario:$1:$2"
  return 0
}

assert_scenarios_ran() {
  local block tag
  if [ "$SCENARIO_BLOCKS_RAN" = ' ' ]; then
    if [ "$SCENARIO_GROUP" = controller ]; then fail 'no controller scenario block executed'
    else fail 'no stations scenario block executed'; fi
  fi
  for block in $SCENARIO_BLOCKS; do
    tag=${block#*:}
    scenario_selected "$tag" || continue
    case "$SCENARIO_BLOCKS_RAN" in
      *" $block "*) ;;
      *) if [ "$SCENARIO_GROUP" = controller ]; then
           fail "controller scenario block '$block' never executed"
         else fail "stations scenario block '$block' never executed"; fi ;;
    esac
  done
}
# SCENARIO HELPERS END

workflow_contract_check() {
  local workflow_root=${1:-$ROOT}
  [ -f "$workflow_root/scripts/lib/workflow.sh" ] || fail 'workflow library is missing'
  # shellcheck disable=SC1091
  . "$workflow_root/scripts/lib/workflow.sh"
  workflow_load "$workflow_root" || fail 'workflow validation failed'
  # These legacy readers mention only part of the label set. Include label creation
  # when comparing the union, so the new escalation label is covered as well.
  local legacy_labels
  legacy_labels=$(grep -Eoh 'agent:[a-z]+|needs-[a-z-]+' \
    "$workflow_root/scripts/hooks/require-step-comment.sh" "$workflow_root/scripts/lifecycle-status.sh" \
    "$workflow_root/scripts/create-tags.sh" | LC_ALL=C sort -u)
  [ "$legacy_labels" = "$(workflow_labels)" ] || fail 'hard-coded workflow labels drifted from config/workflow.tsv'
}

fast_check_group() { # <group>; fast mode only
  case "$1" in
    contracts)
      workflow_contract_check
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
    controller)
      ( . "$ROOT/scripts/lib/roles.sh"; roles_load "$ROOT" false ) || fail 'invalid station assignments'
      ;;
    stations)
      [ -f "$ROOT/scripts/lib/journal.sh" ] || fail "journal library is missing"
      ;;
    lifecycle)
      [ -x "$ROOT/scripts/lifecycle-status.sh" ] || fail 'lifecycle gate is missing'
      bash -n "$ROOT/scripts/lifecycle-status.sh" || fail 'lifecycle gate has invalid syntax'
      ;;
  esac
}

# A conservative, stateless predicate over the integration base and manifest destinations.
# Return true on a harness change OR any inability to compute the changed set.
harness_changed() {
  local ref resolved="" base path destination
  for ref in "${AGENTIC_BASE_REF:-}" "${GITHUB_BASE_REF:+origin/$GITHUB_BASE_REF}" \
             origin/HEAD origin/main origin/master; do
    [ -n "$ref" ] || continue
    if resolved=$(git -C "$ROOT" rev-parse --verify --end-of-options "$ref^{commit}" 2>/dev/null); then
      break
    fi
    resolved=""
  done
  [ -n "$resolved" ] || return 0
  base=$(git -C "$ROOT" merge-base HEAD "$resolved" 2>/dev/null) || return 0
  # --no-renames keeps the deleted harness path when a file moves outside the payload.
  git -C "$ROOT" diff --no-renames --name-only -z "$base" -- > "$TMP/harness-changes" 2>/dev/null \
    || return 0
  git -C "$ROOT" ls-files --others --exclude-standard -z >> "$TMP/harness-changes" 2>/dev/null \
    || return 0
  [ -r "$ROOT/config/payload.tsv" ] || return 0
  # Validate that destination enumeration succeeded rather than treating an empty or
  # broken manifest as proof that no path is owned. NUL paths preserve spaces/newlines.
  awk -F '\t' '
    /^#/ || /^$/ { next }
    NF != 5 { exit 1 }
    $5 == "export" { if ($2 == "") exit 1; found=1; print $2 }
    END { if (!found) exit 1 }
  ' "$ROOT/config/payload.tsv" > "$TMP/harness-destinations" || return 0
  while IFS= read -r -d '' path; do
    while IFS= read -r destination; do
      case "$path" in "$destination"|"$destination"/*) return 0 ;; esac
    done < "$TMP/harness-destinations"
  done < "$TMP/harness-changes"
  return 1
}

SELECTED_FULL_GROUPS=$SELF_TEST_GROUPS
if [ "$SELF_TEST_MODE" = full ] && [ -z "$ONLY_GROUP" ] && [ "$ALL_GROUPS" = 0 ] \
   && [ ! -f "$ROOT/scripts/export.sh" ] && ! harness_changed; then
  SELECTED_FULL_GROUPS=""
  for scope_entry in $SELF_TEST_GROUP_SCOPES; do
    case "$scope_entry" in
      *:local) SELECTED_FULL_GROUPS="${SELECTED_FULL_GROUPS}${SELECTED_FULL_GROUPS:+ }${scope_entry%:*}" ;;
    esac
  done
fi

if [ "$SHIP_GATE" = 1 ]; then
  [ -z "$ONLY_GROUP" ] && [ "$SCENARIO_SET" = 0 ] \
    || { echo 'error: --ship-gate cannot select groups or scenarios' >&2; exit 2; }
  [ -x "$ROOT/scripts/export.sh" ] || fail 'ship-gate requires the scaffold source checkout'
  fresh_export "$ROOT" "$TMP/ship-export" || fail 'ship-gate export failed'
  gate_events="$TMP/ship-gate.events"
  : > "$gate_events"
  if ! (cd "$TMP/ship-export" && AGENTIC_MEASURE_EVENTS="$gate_events" scripts/self-test.sh --full --all-groups); then
    gate_group=$(awk '
      /^group:/ { group=substr($0,7) }
      /^shard_failure:/ { failed=failed (failed ? ", " : "") substr($0,15) }
      END { print (failed ? failed : (group ? group : "startup")) }
    ' "$gate_events")
    fail "exported full suite failed (group: $gate_group)"
  fi
  echo 'ship-gate passed (exported full suite).'
  exit 0
fi

# Compare lengths before arithmetic so very large input safely hits the cap.
limit_jobs() { # <current limit> <positive decimal candidate>
  local limit="$1" candidate="$2"
  if [ "${#candidate}" -le "${#limit}" ] && [ "$candidate" -lt "$limit" ]; then
    printf '%s\n' "$candidate"
  else
    printf '%s\n' "$limit"
  fi
}

self_test_cpus() {
  local cpus
  cpus=$(nproc 2>/dev/null) || cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || cpus=1
  case "$cpus" in
    ''|0*|*[!0-9]*) cpus=1 ;;
  esac
  printf '%s\n' "$cpus"
}

run_full_shards() {
  local group tag shard dir report seen jobs running=0 next=0 slot pid status
  local -a shards=() pids=() statuses=() args
  for group in $SELECTED_FULL_GROUPS; do
    case "$group" in
      controller) for tag in $CONTROLLER_SCENARIOS; do shards+=("$group/$tag"); done ;;
      stations) for tag in $STATIONS_SCENARIOS; do shards+=("$group/$tag"); done ;;
      *) shards+=("$group") ;;
    esac
  done
  jobs=$(limit_jobs "${#shards[@]}" "$(self_test_cpus)")
  if [ -n "$REQUESTED_JOBS" ]; then jobs=$(limit_jobs "$jobs" "$REQUESTED_JOBS"); fi
  if [ -f "$ROOT/scripts/export.sh" ]; then source_snapshot; fi

  # Bash 3.2 has no wait -n. Reap whichever worker finishes first so a slow
  # shard cannot keep an otherwise free slot idle. Print logs after collection.
  for shard in "${shards[@]}"; do
    while [ "$running" -ge "$jobs" ]; do
      for ((slot=0; slot<next; slot++)); do
        pid=${pids[$slot]}
        if [ "$pid" != 0 ] && ! kill -0 "$pid" 2>/dev/null; then
          status=0
          wait "$pid" || status=$?
          statuses[slot]=$status
          pids[slot]=0
          running=$((running-1))
        fi
      done
      if [ "$running" -ge "$jobs" ]; then sleep 0.1; fi
    done
    dir="$TMP/$next"
    mkdir "$dir"
    # Keep the local budget stream separate from the optional report, which
    # also includes events emitted by nested self-test invocations.
    report=""
    if [ -n "$REPORT_EVENTS" ]; then report="$dir/report-events"; fi
    args=(--only "${shard%%/*}")
    case "$shard" in */*) args+=(--scenario "${shard#*/}") ;; esac
    AGENTIC_SELF_TEST_SHARD_DIR="$dir" AGENTIC_MEASURE_EVENTS="$report" \
      bash "$ROOT/scripts/self-test.sh" "${args[@]}" > "$dir/log" 2>&1 &
    pids[next]=$!
    running=$((running+1))
    next=$((next+1))
  done

  for ((slot=0; slot<next; slot++)); do
    shard=${shards[$slot]}
    group=${shard%%/*}
    dir="$TMP/$slot"
    pid=${pids[$slot]}
    status=${statuses[$slot]:-0}
    if [ "$pid" != 0 ]; then wait "$pid" || status=$?; fi
    printf '%s\n' "--- self-test shard: $shard ---"
    cat "$dir/log"
    seen=""
    if [ -f "$dir/local-events" ]; then
      cat "$dir/local-events" >> "$LOCAL_EVENTS"
      seen=$(sed -n 's/^group://p' "$dir/local-events")
    fi
    if [ -n "$REPORT_EVENTS" ] && [ -f "$dir/report-events" ]; then
      cat "$dir/report-events" >> "$REPORT_EVENTS"
    fi
    if [ "$status" != 0 ]; then
      echo "self-test failed: shard $shard exited $status" >&2
    fi
    if [ "$seen" = "$group" ]; then
      GROUPS_RAN="$GROUPS_RAN $group "
    else
      echo "self-test failed: shard '$shard' never executed group '$group' exactly once" >&2
    fi
    if [ "$status" != 0 ] || [ "$seen" != "$group" ]; then
      measure_event "shard_failure:$shard"
      FULL_FAILED=1
    fi
  done
}

FULL_FAILED=0
if [ "$SELF_TEST_MODE" = full ] && [ -z "$ONLY_GROUP" ]; then
  run_full_shards
else
# --- export invariants (scaffold repo only, full suite only) -----------------------------
if should_run export; then
  [ -f "$ROOT/scripts/tests/export.sh" ] || fail "missing self-test group file: export"
  # shellcheck source=scripts/tests/export.sh
  . "$ROOT/scripts/tests/export.sh"
fi

if should_run contracts; then
  [ -f "$ROOT/scripts/tests/contracts.sh" ] || fail "missing self-test group file: contracts"
  # shellcheck source=scripts/tests/contracts.sh
  . "$ROOT/scripts/tests/contracts.sh"
fi

if should_run upgrade; then
  [ -f "$ROOT/scripts/tests/upgrade.sh" ] || fail "missing self-test group file: upgrade"
  # shellcheck source=scripts/tests/upgrade.sh
  . "$ROOT/scripts/tests/upgrade.sh"
fi

if should_run hooks; then
  [ -f "$ROOT/scripts/tests/hooks.sh" ] || fail "missing self-test group file: hooks"
  # shellcheck source=scripts/tests/hooks.sh
  . "$ROOT/scripts/tests/hooks.sh"
fi

if should_run plan-to-issues; then
  [ -f "$ROOT/scripts/tests/plan-to-issues.sh" ] || fail "missing self-test group file: plan-to-issues"
  # shellcheck source=scripts/tests/plan-to-issues.sh
  . "$ROOT/scripts/tests/plan-to-issues.sh"
fi

if should_run lifecycle; then
  [ -f "$ROOT/scripts/tests/lifecycle.sh" ] || fail "missing self-test group file: lifecycle"
  # shellcheck source=scripts/tests/lifecycle.sh
  . "$ROOT/scripts/tests/lifecycle.sh"
fi

if should_run stations; then
  scenario_group_begin stations
  [ -f "$ROOT/scripts/tests/stations.sh" ] || fail "missing self-test group file: stations"
  # shellcheck source=scripts/tests/stations.sh
  . "$ROOT/scripts/tests/stations.sh"
  assert_scenarios_ran
fi

if should_run controller; then
  scenario_group_begin controller
  [ -f "$ROOT/scripts/tests/controller.sh" ] || fail "missing self-test group file: controller"
  # shellcheck source=scripts/tests/controller.sh
  . "$ROOT/scripts/tests/controller.sh"
  assert_scenarios_ran
fi
fi

# --- the run did what the mode promised --------------------------------------------------
# Without this, deleting or mis-guarding a group's `if should_run` block still prints
# "self-test passed." A pass has to mean the groups for this mode actually executed.
if [ -n "$ONLY_GROUP" ]; then
  EXPECTED_GROUPS="$ONLY_GROUP"
elif [ "$SELF_TEST_MODE" = full ]; then
  EXPECTED_GROUPS="$SELECTED_FULL_GROUPS"
else
  EXPECTED_GROUPS='contracts hooks plan-to-issues lifecycle stations controller'
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

[ "$FULL_FAILED" = 0 ] || exit 1
if [ -z "$SHARD_DIR" ]; then echo "self-test passed."; fi
