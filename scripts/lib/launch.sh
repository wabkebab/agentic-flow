#!/usr/bin/env bash
# Credential-free headless station launches. The caller owns the ledger.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/roles.sh"

launch_root() { git -C "$1" rev-parse --show-toplevel; }
launch_error() { printf 'preflight: %s\n' "$*" >&2; return 6; }
launch_assignment() { # station worktree
  LAUNCH_ROOT=$(launch_root "$2") || return 6
  if [ -n "${CT_ASSIGNMENTS:-}" ]; then ROLES_JSON=$CT_ASSIGNMENTS
  else roles_load "$LAUNCH_ROOT" || return 6; fi
  LAUNCH_ROW=$(printf '%s' "$ROLES_JSON" | jq -er --arg s "$1" '.[]|select(.station==$s)|[.cli,.model,.effort,.max_turns,.budget_usd,.timeout_s,.profile]|@tsv') || return 6
  IFS=$(printf '\t') read -r LAUNCH_CLI LAUNCH_MODEL LAUNCH_EFFORT LAUNCH_TURNS LAUNCH_BUDGET LAUNCH_TIMEOUT LAUNCH_PROFILE <<< "$LAUNCH_ROW"
  LAUNCH_PROFILE="$LAUNCH_ROOT/$LAUNCH_PROFILE"
  # An unspecified CLI limit still has a bounded controller watchdog.
  [ "$LAUNCH_TIMEOUT" != - ] || LAUNCH_TIMEOUT=2700
  case "$LAUNCH_CLI:$1" in
    codex:executor) LAUNCH_CONTRACT_MODE=native ;;
    codex:reviewer) LAUNCH_CONTRACT_MODE=excluded ;;
    claude:*) if [ -n "${ANTHROPIC_API_KEY:-}" ]; then LAUNCH_CONTRACT_MODE=excluded; else LAUNCH_CONTRACT_MODE=overridden; fi ;;
    opencode:*) LAUNCH_CONTRACT_MODE=overridden ;;
    manual:*) LAUNCH_CONTRACT_MODE=manual ;;
  esac
}

launch_environment() { # worktree scratch; array used with env -i for the CLI itself
  local worktree=$1 scratch=$2 remote count=0
  LAUNCH_ENV=("HOME=$HOME" "PATH=$PATH" "LANG=${LANG:-C}" "TMPDIR=$scratch" "GH_CONFIG_DIR=$scratch/gh" "GIT_CONFIG_NOSYSTEM=1" "GIT_CONFIG_GLOBAL=/dev/null")
  mkdir -p "$scratch/gh"
  # Only model-provider authentication crosses the boundary. No general env passthrough.
  [ -z "${ANTHROPIC_API_KEY:-}" ] || LAUNCH_ENV+=("ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
  [ -z "${OPENAI_API_KEY:-}" ] || LAUNCH_ENV+=("OPENAI_API_KEY=$OPENAI_API_KEY")
  for remote in credential.helper core.sshCommand; do
    LAUNCH_ENV+=("GIT_CONFIG_KEY_$count=$remote")
    case "$remote" in credential.helper) LAUNCH_ENV+=("GIT_CONFIG_VALUE_$count=") ;; *) LAUNCH_ENV+=("GIT_CONFIG_VALUE_$count=false") ;; esac
    count=$((count+1))
  done
  while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    LAUNCH_ENV+=("GIT_CONFIG_KEY_$count=remote.$remote.pushurl" "GIT_CONFIG_VALUE_$count=no-push://disabled")
    count=$((count+1))
  done < <(git -C "$worktree" remote)
  LAUNCH_ENV+=("GIT_CONFIG_COUNT=$count")
}

launch_timed() { # seconds pgid-file|- command...; reap the whole group on every exit
  local seconds=$1 pgid_file=$2
  shift 2
  # Perl ships on the supported macOS/Linux operator environments. setsid is used
  # in the child so a timeout cannot kill the controller's process group.
  perl -MPOSIX=setsid,WNOHANG -e '
    my $limit=shift; my $pgid_file=shift;
    my $pid=fork(); defined $pid or die "fork: $!";
    if (!$pid) {
      setsid() or die "setsid: $!";
      if ($pgid_file ne "-") {
        open my $fh, ">", $pgid_file or die "pgid file: $!";
        print $fh "$$\n"; close $fh or die "pgid close: $!";
      }
      exec @ARGV; die "exec: $!";
    }
    $SIG{ALRM}=sub { kill "TERM", -$pid; select undef,undef,undef,0.2; kill "KILL", -$pid; waitpid($pid,0); exit 124; };
    $SIG{INT}=$SIG{TERM}=sub { kill "KILL", -$pid; waitpid($pid,0); exit 130; };
    alarm $limit; waitpid($pid,0); my $status=$?; alarm 0;
    kill "KILL", -$pid;
    exit(($status & 127) ? 128+($status & 127) : $status >> 8);
  ' "$seconds" "$pgid_file" "$@"
}


launch_abort() { # background wrapper pid, child-created pgid file
  local wrapper=$1 file=$2 pgid=''
  if [ -f "$file" ]; then IFS= read -r pgid < "$file" || true; fi
  # The child writes this before exec, so a session event implies a ready pgid.
  if [[ "$pgid" =~ ^[1-9][0-9]*$ ]] && [ "$pgid" -gt 1 ]; then
    kill -TERM -- "-$pgid" 2>/dev/null || true
    sleep 0.2
    kill -KILL -- "-$pgid" 2>/dev/null || true
  fi
  wait "$wrapper" 2>/dev/null || true
}

launch_profile_check() { # called after assignment; reject gaps by name
  case "$LAUNCH_CLI" in
    codex)
      local installed="$HOME/.codex/agentic-station.config.toml"
      [ -f "$installed" ] || { launch_error 'missing Codex profile ~/.codex/agentic-station.config.toml'; return 6; }
      cmp -s "$LAUNCH_PROFILE" "$installed" || { launch_error 'Codex installed profile differs from station profile'; return 6; }
      # These are also CLI overrides, so later project config cannot weaken them.
      local setting
      for setting in 'approval_policy = "never"' 'sandbox_mode = "workspace-write"' 'web_search = "disabled"' 'network_access = false'; do
        grep -Fxq "$setting" "$LAUNCH_PROFILE" || { launch_error "Codex profile missing $setting"; return 6; }
      done ;;
    claude)
      jq -e '.sandbox.enabled==true and .sandbox.allowUnsandboxedCommands==false and .sandbox.failIfUnavailable==true and .sandbox.network.allowedDomains==[] and .sandbox.network.strictAllowlist==true' "$LAUNCH_PROFILE" >/dev/null \
        || { launch_error 'Claude profile missing strict sandbox/network settings'; return 6; }
      case "$(uname -s)" in
        Darwin) command -v sandbox-exec >/dev/null || { launch_error 'Claude sandbox-exec unavailable'; return 6; } ;;
        Linux) if ! command -v bwrap >/dev/null || ! command -v socat >/dev/null; then launch_error 'Claude sandbox requires bwrap and socat'; return 6; fi ;;
        *) launch_error 'Claude sandbox platform unsupported'; return 6 ;;
      esac
      jq -e '.permissions.deny | index("Bash(gh:*)") != null and index("Bash(gh *)") != null and index("WebFetch(domain:github.com)") != null and index("WebFetch(domain:api.github.com)") != null and index("WebFetch(domain:raw.githubusercontent.com)") != null' "$LAUNCH_PROFILE" >/dev/null \
        || { launch_error 'Claude profile missing GitHub deny settings'; return 6; } ;;
    opencode)
      jq -e '[.permissions[]|select(.effect=="deny")|[.action,.resource]] as $d |
        [["shell","gh"],["shell","gh *"],["webfetch","https://github.com/*"],["webfetch","https://api.github.com/*"],["webfetch","https://raw.githubusercontent.com/*"]] | all(. as $x | any($d[]; . == $x))' "$LAUNCH_PROFILE" >/dev/null \
        || { launch_error 'OpenCode profile missing GitHub deny settings'; return 6; } ;;
  esac
}

launch_codex_config() { # worktree scratch; exact overrides shared by inspect and exec
  local worktree=$1 scratch=$2 name
  LAUNCH_CODEX_ARGS=(-c 'approval_policy="never"' -c 'sandbox_mode="workspace-write"' -c 'web_search="disabled"' -c features.apps=false -c sandbox_workspace_write.network_access=false -c 'shell_environment_policy.inherit="core"' -c shell_environment_policy.experimental_use_profile=false -c shell_environment_policy.ignore_default_excludes=false)
  # A linked worktree keeps its index and the shared objects/refs outside the workspace,
  # so a station could never commit. Grant only what a commit writes, not all of .git.
  local gitdir common roots
  gitdir=$(cd "$worktree" && git rev-parse --absolute-git-dir 2>/dev/null) || gitdir=
  common=$(cd "$worktree" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=
  if [ -n "$gitdir" ] && [ -n "$common" ]; then
    # Codex marks .agents read-only under a root; as a root of its own it is writable.
    roots=$(jq -cn --arg g "$gitdir" --arg c "$common" --arg a "$worktree/.agents" '[$g, $c+"/objects", $c+"/refs/heads", $c+"/logs", $a]')
    LAUNCH_CODEX_ARGS+=(-c "sandbox_workspace_write.writable_roots=$roots")
  fi
  # Inspect before launching, then explicitly disable every configured connector.
  # Empty map overrides merge with TOML maps and do NOT reliably remove servers.
  (cd "$worktree" && launch_timed 20 - env -i "${LAUNCH_ENV[@]}" perl "$LAUNCH_ROOT/scripts/lib/station-config.pl" "$worktree" "${LAUNCH_CODEX_ARGS[@]}") > "$scratch/config.json" 2> "$scratch/config.err" \
    || { launch_error 'Codex effective config could not be read'; return 6; }
  # Codex takes quotes in a -c key literally, so use bare keys whenever TOML allows them.
  while IFS= read -r name; do
    LAUNCH_CODEX_ARGS+=(-c "mcp_servers.$name.enabled=false")
  done < <(jq -r '(.mcp_servers // {}) | keys[] | if test("^[A-Za-z0-9_-]+$") then . else @json end' "$scratch/config.json")
  (cd "$worktree" && launch_timed 20 - env -i "${LAUNCH_ENV[@]}" perl "$LAUNCH_ROOT/scripts/lib/station-config.pl" "$worktree" "${LAUNCH_CODEX_ARGS[@]}") > "$scratch/effective.json" 2> "$scratch/config.err" \
    || { launch_error 'Codex effective isolation config could not be read'; return 6; }
  jq -e '.approval_policy=="never" and .sandbox_mode=="workspace-write" and .web_search=="disabled" and .features.apps==false and .sandbox_workspace_write.network_access==false and all((.mcp_servers // {})[]; .enabled==false)' "$scratch/effective.json" >/dev/null \
    || { launch_error 'Codex effective sandbox/network/connector settings are unsafe'; return 6; }
}

launch_opencode_config() { # worktree scratch; deny additions must survive config layering
  local worktree=$1 scratch=$2
  (cd "$worktree" && launch_timed 20 - env -i "${LAUNCH_ENV[@]}" "OPENCODE_CONFIG=$LAUNCH_PROFILE" opencode --standalone debug config) > "$scratch/effective.json" 2> "$scratch/config.err" \
    || { launch_error 'OpenCode effective config could not be read'; return 6; }
  # v2 exposes ordered sources, not a flat config. Reject shell/webfetch allows
  # conservatively; project settings must not weaken the selected deny profile.
  jq -e --arg profile "$LAUNCH_PROFILE" '
    any(.[]; .path==$profile and (.info.permissions|type)=="array") and
    ([.[].info.permissions[]? | select(.action=="shell" or .action=="webfetch" or .action=="*")] |
      length>0 and all(.effect=="deny"))' "$scratch/effective.json" >/dev/null \
    || { launch_error 'OpenCode effective deny settings are missing or weakened'; return 6; }
}

launch_preflight() { # station [worktree=$PWD]; unattended checks, no model invocation
  local station=$1 worktree=${2:-$PWD} scratch status=0
  launch_assignment "$station" "$worktree" || return 6
  [ "$LAUNCH_CLI" != manual ] || return 0
  command -v "$LAUNCH_CLI" >/dev/null 2>&1 || { launch_error "missing CLI $LAUNCH_CLI"; return 6; }
  command -v perl >/dev/null 2>&1 || { launch_error 'missing timeout runtime perl'; return 6; }
  launch_profile_check || return 6
  if [ "$LAUNCH_CLI" = opencode ]; then
    roles_risk_accepted "$LAUNCH_ROOT" opencode-station-network || { launch_error 'opencode-station-network accepted risk is required'; return 6; }
    echo 'warning: accepted risk opencode-station-network' >&2
  fi
  echo "preflight: $station contract_mode=$LAUNCH_CONTRACT_MODE" >&2
  [ "$LAUNCH_CONTRACT_MODE" != overridden ] || echo "warning: $station project instructions are overridden, not excluded" >&2
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/agentic-preflight.XXXXXX") || return 6
  launch_environment "$worktree" "$scratch"
  case "$LAUNCH_CLI" in
    codex) launch_codex_config "$worktree" "$scratch" || { rm -rf "$scratch"; return 6; } ;;
    opencode) launch_opencode_config "$worktree" "$scratch" || { rm -rf "$scratch"; return 6; } ;;
  esac
  # A credential probe uses exactly the CLI process environment. A broken/missing gh
  # is a gap, not evidence of unauthenticated operation.
  # shellcheck disable=SC2016 # Probe code expands only in the scrubbed child.
  if ! command -v gh >/dev/null 2>&1; then
    launch_error 'missing gh credential probe'; status=6
  elif (cd "$worktree" && launch_timed 15 - env -i "${LAUNCH_ENV[@]}" bash --noprofile --norc -c '
    for var in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
      if env | grep -q "^${var}="; then exit 1; fi
    done
    gh auth status >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 1 ] || exit 1
    [ "$(git config --get credential.helper)" = "" ] || exit 1
    [ "$(git config --get core.sshCommand)" = false ] || exit 1
    for remote in $(git remote); do
      [ "$(git remote get-url --push "$remote")" = no-push://disabled ] || exit 1
    done
  '); then :; else launch_error 'station credential/push isolation probe failed'; status=6; fi
  rm -rf "$scratch"
  return "$status"
}

launch_bundle() { # station step packet scratch
  local station=$1 step=$2 packet=$3 scratch=$4
  awk -v station="$station" -v step="$step" '{gsub(/@STATION@/,station);gsub(/@STEP@/,step);print}' "$LAUNCH_ROOT/config/stations/preamble.md" > "$scratch/bundle.md" || return 2
  if [ "$station" = executor ]; then
    # Consume the live executor contract, including its canonical render-shared
    # ENGINEERING STANDARDS region. Never maintain a second executor contract.
    cat "$LAUNCH_ROOT/AGENTS.md" >> "$scratch/bundle.md" || return 2
  else cat "$LAUNCH_ROOT/.agents/skills/review-execution/SKILL.md" >> "$scratch/bundle.md" || return 2; fi
  cat "$scratch/bundle.md" "$packet" > "$scratch/prompt.md" || return 2
  printf '\nReturn only the station result JSON matching this schema:\n' >> "$scratch/prompt.md"
  cat "$LAUNCH_ROOT/config/stations/result.schema.json" >> "$scratch/prompt.md"
  if [ "$station" = executor ]; then
    printf '\nCommit with Fixes #%s. Never amend a commit. Never push.\n' "${LAUNCH_ISSUE:-unknown}" >> "$scratch/prompt.md"
  fi
}

launch_station() { # station worktree packet result [--resume session]
  local station=$1 worktree=$2 packet=$3 result=$4 resume='' scratch started ended status=0 step
  shift 4
  worktree=$(cd "$worktree" && pwd -P) || return 2
  case "$packet" in /*) ;; *) packet="$PWD/$packet" ;; esac
  case "$result" in /*) ;; *) result="$PWD/$result" ;; esac
  launch_assignment "$station" "$worktree" || return 6
  [ "$LAUNCH_CLI" != manual ] || { echo "$station is manual: run it interactively" >&2; return 12; }
  [ "$#" -eq 0 ] || { [ "$#" -eq 2 ] && [ "$1" = --resume ] || return 2; resume=$2; }
  # The caller supplies the creating intent's identity. Fail closed if it has no
  # identity rather than assuming a session belongs to the newly selected CLI.
  if [ -n "$resume" ]; then
    if [ "${LAUNCH_RESUME_CLI:-}" != "$LAUNCH_CLI" ] || { [ "${LAUNCH_RESUME_PROFILE:-}" != "${LAUNCH_PROFILE#"$LAUNCH_ROOT"/}" ] && [ "${LAUNCH_RESUME_PROFILE:-}" != "$LAUNCH_PROFILE" ]; }; then
      echo 'launch: incompatible resume CLI/profile' >&2; return 2
    fi
  fi
  command -v perl >/dev/null 2>&1 || { launch_error 'missing timeout runtime perl'; return 6; }
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/agentic-launch.XXXXXX") || return 6
  step=${LAUNCH_STEP:-unknown}
  launch_bundle "$station" "$step" "$packet" "$scratch" || { rm -rf "$scratch"; return 2; }
  launch_environment "$worktree" "$scratch"
  local -a argv
  case "$LAUNCH_CLI" in
    claude)
      argv=(claude -p --output-format json --json-schema "$(cat "$LAUNCH_ROOT/config/stations/result.schema.json")" --settings "$LAUNCH_PROFILE" --setting-sources '' --strict-mcp-config --mcp-config '{"mcpServers":{}}' --append-system-prompt-file "$scratch/bundle.md" --system-prompt-snapshot off)
      [ "$LAUNCH_CONTRACT_MODE" != excluded ] || argv+=(--bare)
      [ "$LAUNCH_MODEL" = - ] || argv+=(--model "$LAUNCH_MODEL")
      [ "$LAUNCH_EFFORT" = - ] || argv+=(--effort "$LAUNCH_EFFORT")
      [ "$LAUNCH_TURNS" = - ] || argv+=(--max-turns "$LAUNCH_TURNS")
      [ "$LAUNCH_BUDGET" = - ] || argv+=(--max-budget-usd "$LAUNCH_BUDGET")
      if [ -n "$resume" ]; then argv+=(--resume "$resume"); elif [ -n "${LAUNCH_SESSION:-}" ]; then argv+=(--session-id "$LAUNCH_SESSION"); fi ;;
    codex)
      launch_codex_config "$worktree" "$scratch" || { rm -rf "$scratch"; return 6; }
      argv=(codex exec --profile agentic-station "${LAUNCH_CODEX_ARGS[@]}")
      [ "$station" != reviewer ] || argv+=(-c project_doc_max_bytes=0)
      [ "$LAUNCH_EFFORT" = - ] || argv+=(-c "model_reasoning_effort=$(printf '%s' "$LAUNCH_EFFORT" | jq -Rs .)")
      [ -z "$resume" ] || argv+=(resume "$resume")
      argv+=(--output-schema "$LAUNCH_ROOT/config/stations/result.schema.json" --json -o "$result")
      [ -n "$resume" ] || argv+=(-C "$worktree")
      [ "$LAUNCH_MODEL" = - ] || argv+=(-m "$LAUNCH_MODEL") ;;
    opencode)
      # Standalone prevents a pre-existing server from retaining ambient credentials.
      # OPENCODE_CONFIG_CONTENT supplies the selected role and its deny rules.
      LAUNCH_ENV+=("OPENCODE_CONFIG=$LAUNCH_PROFILE" "OPENCODE_CONFIG_CONTENT=$(jq -cn --arg s "$station" --rawfile p "$scratch/bundle.md" --slurpfile profile "$LAUNCH_PROFILE" '{mcp:{},agent:{($s):{mode:"primary",prompt:$p,permissions:$profile[0].permissions}}}')")
      argv=(opencode --standalone run --format json --agent "$station")
      [ "$LAUNCH_MODEL" = - ] || argv+=(--model "$LAUNCH_MODEL")
      if [ -n "$resume" ]; then argv+=(--session "$resume"); elif [ -n "${LAUNCH_SESSION:-}" ]; then argv+=(--session "$LAUNCH_SESSION"); fi ;;
  esac
  : > "$result" || { rm -rf "$scratch"; return 2; }
  started=$(date +%s)
  # Codex stdout is consumed as it arrives. The callback lets C-2 persist the first
  # thread.started session before the CLI exits; no ledger is invented here.
  if [ "$LAUNCH_CLI" = codex ]; then
    # No file-size cap here: Codex appends to global state databases that already exceed
    # 32 MB, and a cap kills it with SIGXFSZ (exit 153). Its sandbox bounds where it writes.
    (cd "$worktree" && launch_timed "$LAUNCH_TIMEOUT" "${LAUNCH_PGID_FILE:-$scratch/pgid}" env -i "${LAUNCH_ENV[@]}" "${argv[@]}" < "$scratch/prompt.md") > "$scratch/events" 2> "$scratch/stderr" &
    local pid=$! session notified=false
    # Use a FIFO-free append reader: tailing is bounded by the launch timeout.
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$notified" = false ] && [ -s "$scratch/events" ]; then
        session=$(jq -Rr 'fromjson? | select(.type=="thread.started") | .thread_id // empty' "$scratch/events" | head -n 1)
        if [ -n "$session" ]; then
          notified=true
          if declare -F launch_session_record >/dev/null; then launch_session_record "$session" || { launch_abort "$pid" "${LAUNCH_PGID_FILE:-$scratch/pgid}"; rm -rf "$scratch"; return 2; }; fi
        fi
      fi
      sleep 0.1
    done
    wait "$pid" || status=$?
    if [ "$notified" = false ]; then
      session=$(jq -Rr 'fromjson? | select(.type=="thread.started") | .thread_id // empty' "$scratch/events" | head -n 1)
      if [ -n "$session" ] && declare -F launch_session_record >/dev/null; then
        launch_session_record "$session" || { rm -rf "$scratch"; return 2; }
      fi
    fi
  else
    (cd "$worktree" && ulimit -f 65536 && launch_timed "$LAUNCH_TIMEOUT" "${LAUNCH_PGID_FILE:-$scratch/pgid}" env -i "${LAUNCH_ENV[@]}" "${argv[@]}" < "$scratch/prompt.md") > "$scratch/events" 2> "$scratch/stderr" || status=$?
  fi
  ended=$(date +%s)
  local parsed
  parsed=$(jq -s --arg cli "$LAUNCH_CLI" -f "$LAUNCH_ROOT/scripts/lib/station-output.jq" "$scratch/events" 2>/dev/null) || parsed='{"session":null,"result":null,"usage":{"input":null,"output":null,"cost_usd":null}}'
  # OpenCode creates its own session, so its id only exists in the events. Codex recorded its own live.
  if [ "$LAUNCH_CLI" = opencode ] && [ -z "${LAUNCH_SESSION:-}" ] && declare -F launch_session_record >/dev/null; then
    session=$(printf '%s' "$parsed" | jq -r '.session // empty')
    if [ -n "$session" ]; then launch_session_record "$session" || { rm -rf "$scratch"; return 2; }; fi
  fi
  # The -o file is authoritative for Codex, including a resumed final result.
  if [ "$LAUNCH_CLI" = codex ] && [ -s "$result" ]; then
    parsed=$(printf '%s' "$parsed" | jq --rawfile r "$result" '.result=($r|try fromjson catch null)')
  else printf '%s' "$parsed" | jq '.result' > "$result"; fi
  printf '%s' "$parsed" | jq --argjson exit "$status" --argjson seconds "$((ended-started))" --arg mode "$LAUNCH_CONTRACT_MODE" \
    --arg cli "$LAUNCH_CLI" --arg turns "$LAUNCH_TURNS" --arg budget "$LAUNCH_BUDGET" \
    '. + {exit:$exit,seconds:$seconds,contract_mode:$mode,limits:{max_turns:$turns,budget_usd:$budget,mode:(if $cli=="claude" then "enforced" else "advisory" end)}}'
  cat "$scratch/stderr" >&2
  rm -rf "$scratch"
  return "$status"
}
