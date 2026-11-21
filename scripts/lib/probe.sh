#!/usr/bin/env bash
# Real-CLI canary. Only doctor --stations and changed unattended launches call it.
# shellcheck disable=SC1091,SC2034,SC2329 # Shared launch/ledger context.
. "$(dirname "${BASH_SOURCE[0]}")/launch.sh"
. "$(dirname "${BASH_SOURCE[0]}")/ledger.sh"

probe_script() {
  cat <<'SCRIPT'
#!/usr/bin/env bash
set -u
log=.agentic-flow-probe.log
: > "$log"
common=$(git rev-parse --path-format=absolute --git-common-dir) || exit 1
nonce=${PWD%/worktree}; nonce=${nonce##*/}
attempt() {
  local operation=$1 error rc=0; shift
  error=$("$@" 2>&1) || rc=$?
  jq -cn --arg op "$operation" --argjson exit "$rc" --arg error "$error" \
    '{operation:$op,exit:$exit,error:$error}' >> "$log"
}
write_file() { printf 'station probe\n' > "$1"; }
commit_files() {
  git add -- .probe-worktree .agents/.probe-file &&
    git -c core.hooksPath=/dev/null -c user.name=StationProbe -c user.email=probe@example.invalid \
      -c commit.gpgsign=false commit -qm 'Station probe write'
}
attempt worktree write_file .probe-worktree
attempt agents write_file .agents/.probe-file
attempt commit_paths commit_files
attempt verify_dir write_file "$common/agentic-flow/verify/.probe-$nonce"
attempt ledger_dir write_file "$common/agentic-flow/ledger/.probe-$nonce"
head=$(git rev-parse HEAD)
outcome=submitted; [ "$1" != reviewer ] || outcome=approve
jq -cn --arg station "$1" --arg outcome "$outcome" --arg head "$head" \
  '{v:1,station:$station,outcome:$outcome,head:$head,summary:"Station probe",findings:[],question:null,evidence:null}'
SCRIPT
}

probe_attempts() { # log -> bounded evidence, absent/duplicate/malformed entries fail
  if [ -f "$1" ] && [ "$(wc -c < "$1")" -le 32768 ]; then
    jq -s '.[0:] as $rows | reduce ["worktree","agents","commit_paths","verify_dir","ledger_dir"][] as $op ({};
      [$rows[]|select(.operation==$op)] as $r |
      .[$op]=(if ($r|length)==1 and ($r[0].exit|type)=="number" and ($r[0].exit|floor==. and .>=0 and .<=255) and ($r[0].error|type)=="string"
        then {ran:true,exit:$r[0].exit,error:$r[0].error}
        else {ran:false,exit:null,error:"attempt not made"} end))' "$1" 2>/dev/null && return 0
  fi
  jq -n 'reduce ["worktree","agents","commit_paths","verify_dir","ledger_dir"][] as $op ({};
    .[$op]={ran:false,exit:null,error:"attempt not made"})'
}

probe_cleanup() {
  if [ -n "$PROBE_PID" ]; then launch_abort "$PROBE_PID" "$PROBE_SCRATCH/pgid"; fi
  if [ -n "$PROBE_SCRATCH" ]; then
    git -C "$PROBE_ROOT" worktree remove --force "$PROBE_SCRATCH/worktree" >/dev/null 2>&1 || true
    rm -f "$PROBE_COMMON/agentic-flow/verify/.probe-${PROBE_SCRATCH##*/}" "$PROBE_COMMON/agentic-flow/ledger/.probe-${PROBE_SCRATCH##*/}"
    rm -rf "$PROBE_SCRATCH"
  fi
  if [ "$PROBE_BRANCH_OWNED" = true ]; then git -C "$PROBE_ROOT" branch -D "$PROBE_BRANCH" >/dev/null 2>&1 || true; fi
}

probe_worker() { # Called only as a background child by probe_station.
  local station=$1 root=$2 common='' scratch='' branch='' probe_pid='' start=0 finish=0 rc=1 fingerprint=''
  local cli=unknown launched=false session_captured=false result_parsed=false attempts='{}'
  local writable='{"worktree":false,"agents":false,"commit_paths":false}' denied='{"verify_dir":false,"ledger_dir":false}' error='' metadata='{}'
  local CT_ASSIGNMENTS=${CT_ASSIGNMENTS:-}
  local base='' head='' parsed_session='' run="station-probe/1/0/$station/1/1" plan=station-probe
  start=$(date +%s)
  common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir) || exit 1
  # Trap context survives Bash 3.2 unwinding function locals at exit.
  PROBE_ROOT=$root PROBE_COMMON=$common PROBE_SCRATCH='' PROBE_BRANCH='' PROBE_BRANCH_OWNED=false PROBE_PID=''
  trap probe_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  probe_body() {
    launch_assignment "$station" "$root" || { error='station is unconfigured'; return 6; }
    CT_ASSIGNMENTS=$ROLES_JSON
    cli=$LAUNCH_CLI
    [ "$cli" != manual ] || { error='manual station skipped'; return 6; }
    fingerprint=$(launch_fingerprint "$station" "$root" 2>&1) || { error="launcher fingerprint failed: $fingerprint"; return 1; }
    launch_preflight "$station" "$root" || { error='station preflight failed'; return 1; }
    mkdir -p "$common/agentic-flow/probe" "$common/agentic-flow/verify" "$common/agentic-flow/ledger" || return 1
    scratch=$(mktemp -d "$common/agentic-flow/probe/run.XXXXXXXX") || return 1
    PROBE_SCRATCH=$scratch
    branch="agentic-flow/probe/$station-${scratch##*/}"
    PROBE_BRANCH=$branch
    if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then error='probe branch already exists'; return 1; fi
    # Defer signals across the atomic branch creation/ownership bookkeeping.
    local setup_signal=0
    trap 'setup_signal=130' INT
    trap 'setup_signal=143' TERM
    if git -C "$root" branch "$branch" HEAD; then PROBE_BRANCH_OWNED=true
    else error='cannot create probe branch'; return 1; fi
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [ "$setup_signal" = 0 ] || exit "$setup_signal"
    git -C "$root" worktree add -q "$scratch/worktree" "$branch" || return 1
    mkdir -p "$scratch/worktree/.agents" || return 1
    probe_script > "$scratch/worktree/.agentic-flow-probe.sh"
    git -C "$scratch/worktree" add -- .agentic-flow-probe.sh &&
      git -C "$scratch/worktree" -c core.hooksPath=/dev/null -c user.name=StationProbe -c user.email=probe@example.invalid \
        -c commit.gpgsign=false commit -qm 'Install station probe' || return 1
    base=$(git -C "$scratch/worktree" rev-parse HEAD) || return 1
    # Exercise the real ledger schema/order without polluting plan metrics.
    LEDGER_DIR="$scratch/ledger"
    local session='' mode=$LAUNCH_CONTRACT_MODE profile=${LAUNCH_PROFILE#"$LAUNCH_ROOT"/}
    if [ "$cli" = claude ]; then session=$(perl -e 'printf "%08x-%04x-4%03x-8%03x-%012x",time,int(rand(65536)),int(rand(4096)),int(rand(4096)),int(rand(2**48))'); fi
    jq -n --arg run "$run" --arg plan "$plan" --arg station "$station" --arg cli "$cli" --arg model "$LAUNCH_MODEL" \
      --arg base "$base" --arg profile "$profile" --arg mode "$mode" --arg session "$session" \
      '{v:1,kind:"intent",run:$run,chain:($run|split("/")|.[0:5]|join("/")),replaces:null,reason:"initial",plan:$plan,issue:1,step:"probe",
        station:$station,cli:$cli,model:$model,profile:$profile,contract_mode:$mode,resume_of:null,
        session:(if $session=="" then null else $session end),session_mode:"new",reassigned_from:null,seq_before:0,
        base_head:$base,packet_sha256:("0"*64),host:"probe",started:(now|floor)}' > "$scratch/intent"
    ledger_intent "$plan" "$scratch/intent" >/dev/null || { error='probe ledger intent rejected'; return 1; }
    launch_session_record() {
      jq -n --arg run "$run" --arg session "$1" '{v:1,kind:"session",run:$run,session:$session,at:(now|floor)}' > "$scratch/session"
      ledger_session "$plan" "$scratch/session" >/dev/null
    }
    # Do not inherit the controller's prior station session, issue or pgid file.
    LAUNCH_SESSION=$session LAUNCH_PGID_FILE="$scratch/pgid" LAUNCH_STEP=probe LAUNCH_ISSUE=1
    launched=true
    launch_station "$station" "$scratch/worktree" /dev/null "$scratch/result" --probe > "$scratch/metadata" 2> "$scratch/stderr" &
    probe_pid=$!; PROBE_PID=$probe_pid
    local status=0
    wait "$probe_pid" || status=$?
    probe_pid=''; PROBE_PID=''
    metadata=$(cat "$scratch/metadata")
    printf '%s' "$metadata" | jq -e 'type=="object"' >/dev/null 2>&1 || metadata='{}'
    parsed_session=$(printf '%s' "$metadata" | jq -r '.session//empty')
    if [ -n "$parsed_session" ]; then
      ledger_read "$plan" | jq -e --arg session "$parsed_session" 'any(.[];(.kind=="session" and .session==$session) or (.kind=="intent" and .session==$session))' >/dev/null && session_captured=true
    fi
    if jq -e --arg station "$station" --arg base "$base" '
      type=="object" and .v==1 and .station==$station and .head!=null and .head!=$base and
      .summary=="Station probe" and .findings==[] and .question==null and
      .outcome==(if $station=="executor" then "submitted" else "approve" end)' "$scratch/result" >/dev/null 2>&1; then result_parsed=true; fi
    attempts=$(probe_attempts "$scratch/worktree/.agentic-flow-probe.log")
    head=$(git -C "$root" rev-parse "refs/heads/$branch") || return 1
    local worktree=false agents=false commit=false verify=false ledger=false op target
    if printf '%s' "$attempts" | jq -e '.worktree.ran and .worktree.exit==0' >/dev/null && [ -f "$scratch/worktree/.probe-worktree" ]; then worktree=true; fi
    if printf '%s' "$attempts" | jq -e '.agents.ran and .agents.exit==0' >/dev/null && [ -f "$scratch/worktree/.agents/.probe-file" ]; then agents=true; fi
    if printf '%s' "$attempts" | jq -e '.commit_paths.ran and .commit_paths.exit==0' >/dev/null &&
      [ "$head" != "$base" ] && [ "$(git -C "$root" show -s --format=%P "$head")" = "$base" ] &&
      git -C "$root" cat-file -e "$head:.probe-worktree" && git -C "$root" cat-file -e "$head:.agents/.probe-file"; then commit=true; fi
    for op in verify_dir ledger_dir; do
      case "$op" in verify_dir) target="$common/agentic-flow/verify/.probe-${scratch##*/}" ;; *) target="$common/agentic-flow/ledger/.probe-${scratch##*/}" ;; esac
      if printf '%s' "$attempts" | jq -e --arg op "$op" '.[$op]|.ran and .exit!=0 and (.error|test("permission denied|operation not permitted|read-only file system|access denied";"i"))' >/dev/null &&
        [ ! -e "$target" ] && [ ! -L "$target" ]; then
        case "$op" in verify_dir) verify=true ;; *) ledger=true ;; esac
      fi
    done
    writable=$(jq -n --argjson w "$worktree" --argjson a "$agents" --argjson c "$commit" '{worktree:$w,agents:$a,commit_paths:$c}')
    denied=$(jq -n --arg cli "$cli" --argjson v "$verify" --argjson l "$ledger" \
      '{verify_dir:(if $cli=="opencode" then "unenforced" else $v end),ledger_dir:(if $cli=="opencode" then "unenforced" else $l end)}')
    if [ "$status" != 0 ]; then error="station exit $status: $(tail -c 2048 "$scratch/stderr")"; return 1; fi
    if [ "$session_captured" != true ]; then error='session capture or ledger session record failed'; return 1; fi
    if [ "$result_parsed" != true ]; then error='station result did not parse'; return 1; fi
    error=$(printf '%s' "$attempts" | jq -r 'to_entries[]|select(.value.ran!=true)|"\(.key): attempt not made"')
    [ -z "$error" ] || return 1
    if [ "$worktree:$agents:$commit" != true:true:true ] || { [ "$cli" != opencode ] && [ "$verify:$ledger" != true:true ]; }; then
      error="probe filesystem properties failed: writable=$writable denied=$denied"; return 1
    fi
    jq -n --arg fingerprint "$fingerprint" --argjson seconds "$(( $(date +%s)-start ))" \
      '{fingerprint:$fingerprint,passed_at:(now|floor),seconds:$seconds}' > "$scratch/state" || return 1
    mv "$scratch/state" "$common/agentic-flow/probe/$station.json" || return 1
  }
  rc=0; probe_body || rc=$?
  finish=$(date +%s)
  [ "$rc" = 0 ] || [ -n "$error" ] || error='probe setup failed'
  jq -n --arg station "$station" --arg cli "$cli" --argjson launched "$launched" --argjson meta "$metadata" \
    --argjson session "$session_captured" --argjson result "$result_parsed" --argjson writable "$writable" --argjson denied "$denied" \
    --argjson attempts "$attempts" --argjson seconds "$((finish-start))" --arg error "$error" \
    '{station:$station,cli:$cli,launched:$launched,exit:($meta.exit//null),session_captured:$session,result_parsed:$result,
      writable:$writable,denied:$denied,attempts:$attempts,seconds:$seconds,error:(if $error=="" then null else $error end)}'
  exit "$rc"
}

probe_station() { # station worktree; forward signals to the child that owns cleanup
  # The dispatcher/controller run this wrapper in a dedicated child, so their
  # own signal handlers stay intact while this child forwards to the worker.
  local worker status=0 interrupted=0
  probe_worker "$@" &
  worker=$!
  trap 'interrupted=130; kill -TERM "$worker" 2>/dev/null || true; wait "$worker" 2>/dev/null || true' INT
  trap 'interrupted=143; kill -TERM "$worker" 2>/dev/null || true; wait "$worker" 2>/dev/null || true' TERM
  wait "$worker" || status=$?
  trap - INT TERM
  [ "$interrupted" = 0 ] || return "$interrupted"
  return "$status"
}

probe_needed() { # station worktree; fail closed on unreadable/old state
  local fingerprint common state
  fingerprint=$(launch_fingerprint "$1" "$2") || return 0
  common=$(git -C "$2" rev-parse --path-format=absolute --git-common-dir) || return 0
  state="$common/agentic-flow/probe/$1.json"
  [ -f "$state" ] && [ ! -L "$state" ] && [ "$(wc -c < "$state")" -le 4096 ] || return 0
  if jq -e --arg f "$fingerprint" '.fingerprint==$f and (.passed_at|type)=="number" and (.seconds|type)=="number"' "$state" >/dev/null 2>&1; then return 1; fi
  return 0
}

probe_cmd_cleanup() {
  if [ -n "$PROBE_CMD_CHILD" ]; then
    kill -TERM "$PROBE_CMD_CHILD" 2>/dev/null || true
    wait "$PROBE_CMD_CHILD" 2>/dev/null || true
  fi
  rm -f "$PROBE_CMD_OUTPUT"
}

probe_cmd() {
  local station='' json=false root selected status=0 rc report='[]' item
  [ "${1:-}" = --stations ] || { echo 'usage: agentic-flow doctor --stations [--station executor|reviewer] [--json]' >&2; return 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --station) [ "$#" -ge 2 ] || return 2; station=$2; case "$station" in executor|reviewer) ;; *) return 2 ;; esac; shift 2 ;;
      --json) json=true; shift ;;
      *) return 2 ;;
    esac
  done
  root=$(git rev-parse --show-toplevel) || return 2
  PROBE_CMD_CHILD=''
  PROBE_CMD_OUTPUT=$(mktemp "${TMPDIR:-/tmp}/agentic-probe-report.XXXXXXXX") || return 1
  trap probe_cmd_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  for selected in ${station:-executor reviewer}; do
    rc=0
    probe_station "$selected" "$root" > "$PROBE_CMD_OUTPUT" &
    PROBE_CMD_CHILD=$!
    wait "$PROBE_CMD_CHILD" || rc=$?
    PROBE_CMD_CHILD=''
    item=$(cat "$PROBE_CMD_OUTPUT")
    case "$rc" in 0) ;; 6) [ "$status" != 0 ] || status=6 ;; *) status=1 ;; esac
    report=$(printf '%s' "$report" | jq --argjson item "$item" '.+[$item]') || return 1
  done
  if [ "$json" = true ]; then printf '%s\n' "$report"
  else printf '%s' "$report" | jq -r '.[]|"\(.station) (\(.cli)): \(if .error==null then "passed" else .error end)"'; fi
  return "$status"
}
