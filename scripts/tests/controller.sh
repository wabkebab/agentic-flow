#!/usr/bin/env bash
# Sourced by self-test.sh; no network and no real model invocations.
# shellcheck disable=SC1091,SC2030,SC2031,SC2016,SC2329 # Shared harness helpers and child programs.
[ -f "$ROOT/scripts/lib/launch.sh" ] || fail 'station launcher is missing'
[ -f "$ROOT/scripts/lib/ledger.sh" ] || fail 'run ledger is missing'
C1="$TMP/controller"
mkdir -p "$C1/project/config" "$C1/bin" "$C1/home/.codex" "$C1/operator"
mkdir -p "$C1/project/config/stations"
ln "$ROOT/config/stations/"* "$C1/project/config/stations/"
ln "$ROOT/config/roles.tsv" "$C1/project/config/roles.tsv"
ln "$ROOT/config/stations/codex.config.toml" "$C1/home/.codex/agentic-station.config.toml"
mkdir -p "$C1/project/.agents/skills/review-execution" "$C1/project/scripts/lib" "$C1/project/docs"
ln "$ROOT/AGENTS.md" "$C1/project/AGENTS.md"
# Protected source inodes cannot be hard-linked; a read-only fixture reference
# needs no byte copy in that case either. Neither path is mutated by the tests.
ln "$ROOT/.agents/skills/review-execution/SKILL.md" "$C1/project/.agents/skills/review-execution/SKILL.md" 2>/dev/null \
  || ln -s "$ROOT/.agents/skills/review-execution/SKILL.md" "$C1/project/.agents/skills/review-execution/SKILL.md"
ln "$ROOT/scripts/lib/station-output.jq" "$ROOT/scripts/lib/station-config.pl" "$ROOT/scripts/lib/roles.sh" "$C1/project/scripts/lib/"
printf 'PLANNER_MUST_NOT_BE_THE_STATION_CONTRACT\n' > "$C1/project/CLAUDE.md"
printf '0.15.0\n' > "$C1/project/.agentic-flow-version"
printf 'fixture packet\n' > "$C1/packet with spaces.md"
git -C "$C1/project" init -q
git -C "$C1/project" config user.email fixture@example.invalid
git -C "$C1/project" config user.name Fixture
git -C "$C1/project" config commit.gpgsign false
git -C "$C1/project" remote add origin https://github.com/fixture/project.git
# A second remote must also be unable to push.
git -C "$C1/project" remote add second https://github.com/fixture/second.git
git -C "$C1/project" add config AGENTS.md CLAUDE.md scripts .agents docs .agentic-flow-version
git -C "$C1/project" commit -qm 'Controller fixture'
cat > "$C1/bin/gh" <<'FAKE'
#!/usr/bin/env bash
[ "$*" = 'auth status' ] || exit 2
[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${GH_ENTERPRISE_TOKEN:-}${GITHUB_ENTERPRISE_TOKEN:-}" ] || exit 0
[ -d "${GH_CONFIG_DIR:-/nonexistent}" ] || exit 0
[ -z "$(ls -A "$GH_CONFIG_DIR")" ] || exit 0
exit 1
FAKE
cat > "$C1/bin/station" <<'FAKE'
#!/usr/bin/env bash
set -eu
cli=${0##*/}
behavior=$(cat "$PWD/../behavior" 2>/dev/null || true)
if [ "$cli" = codex ] && [ "${1:-}" = app-server ]; then
  if [ "$behavior" = unsafe-config ]; then
    while IFS= read -r request; do
      case "$request" in *config/read*) printf '%s\n' '{"id":2,"result":{"config":{"approval_policy":"never","sandbox_mode":"workspace-write","web_search":"disabled","sandbox_workspace_write":{"network_access":true}}}}' ;; esac
    done
    exit 0
  fi
  if [ "$behavior" = unsafe-apps ]; then
    while IFS= read -r request; do
      case "$request" in *config/read*) printf '%s\n' '{"id":2,"result":{"config":{"approval_policy":"never","sandbox_mode":"workspace-write","web_search":"disabled","sandbox_workspace_write":{"network_access":false},"features":{"apps":true},"mcp_servers":{}}}}' ;; esac
    done
    exit 0
  fi
  # The config RPC is headless and never invokes the model fake.
  while IFS= read -r request; do
    case "$request" in *config/read*)
      enabled=true
      case "$*" in *'mcp_servers."fixture".enabled=false'*) enabled=false ;; esac
      printf '{"id":2,"result":{"config":{"approval_policy":"never","sandbox_mode":"workspace-write","web_search":"disabled","sandbox_workspace_write":{"network_access":false},"features":{"apps":false},"mcp_servers":{"fixture":{"enabled":%s}}}}}\n' "$enabled"
      ;; esac
  done
  exit 0
fi
if [ "$cli" = opencode ] && [ "${3:-}" = config ]; then
  if [ "$behavior" = weak-opencode ]; then
    printf '%s\n' '[{"path":"weak","info":{"permissions":[{"action":"shell","resource":"*","effect":"allow"}]}}]'
    exit 0
  fi
  jq -n --arg path "$OPENCODE_CONFIG" --slurpfile config "$OPENCODE_CONFIG" '[{path:$path,info:$config[0]}]'
  exit 0
fi
out="$PWD/../observed"
mkdir -p "$out"
printf '%s\n' "$@" > "$out/argv"
env > "$out/env"
cat > "$out/prompt"
[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${GH_ENTERPRISE_TOKEN:-}${GITHUB_ENTERPRISE_TOKEN:-}" ] || exit 31
if gh auth status; then exit 32; fi
git remote get-url --push origin > "$out/pushurl"
git remote get-url --push second > "$out/second-pushurl"
if git push --dry-run origin HEAD > "$out/push.out" 2>&1; then exit 33; fi
case "$behavior" in
  timeout|callback-failure|normal-child)
    : > "$out/heartbeat"
    (for ((tick=0; tick<300; tick++)); do printf . >> "$out/heartbeat"; sleep 0.1; done) &
    child=$!; echo "$child" > "$out/child"
    case "$behavior" in
      timeout) wait "$child" ;;
      callback-failure)
        printf '%s\n' '{"type":"thread.started","thread_id":"codex-session"}'
        wait "$child"; exit 0 ;;
    esac ;;
  malformed) printf 'not-json\n'; exit 0 ;;
  failure) exit 17 ;;
esac
case "$cli" in
  codex)
    printf '%s\n' '{"type":"thread.started","thread_id":"codex-session"}' '{"type":"item.completed","item":{"type":"agent_message","text":"{\"v\":1,\"station\":\"executor\",\"outcome\":\"ask\",\"summary\":\"fixture\",\"question\":\"fixture?\"}"}}' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}' ;;
  claude)
    printf '%s\n' '{"type":"result","session_id":"claude-session","structured_output":{"v":1,"station":"executor","outcome":"ask","summary":"fixture","question":"fixture?"},"usage":{"input_tokens":8,"output_tokens":4},"total_cost_usd":0.01}' ;;
  opencode)
    printf '%s\n' '{"type":"text","sessionID":"opencode-session","part":{"text":"{\"v\":1,\"station\":\"reviewer\",\"outcome\":\"ask\",\"summary\":\"fixture\",\"question\":\"fixture?\"}"}}' '{"type":"step_finish","sessionID":"opencode-session","part":{"tokens":{"input":6,"output":3},"cost":0.02}}' ;;
esac
FAKE
chmod +x "$C1/bin/gh" "$C1/bin/station"
for cli in codex claude opencode; do ln -s station "$C1/bin/$cli"; done

controller_tests() (
  export HOME="$C1/home" XDG_CONFIG_HOME="$C1/operator" PATH="$C1/bin:$PATH"
  # Hostile inherited credentials are intentionally nonspecific fixture values.
  export GH_TOKEN=fixture GITHUB_TOKEN=fixture GH_ENTERPRISE_TOKEN=fixture GITHUB_ENTERPRISE_TOKEN=fixture
  export UNLISTED_HOST_VALUE=must-not-cross
  unset ANTHROPIC_API_KEY OPENAI_API_KEY
  . "$ROOT/scripts/lib/launch.sh"
  find_root() { printf '%s\n' "$C1/project"; }
  roles_load "$C1/project" || fail 'default roles failed'
  printf '%s' "$ROLES_JSON" | jq -e 'length==2 and all(.layer=="harness")' >/dev/null || fail 'defaults lost harness provenance'
  roles_cmd --json | jq -e 'length==2' >/dev/null || fail 'roles JSON display failed'
  roles_cmd set reviewer unknown --scope project > /dev/null 2>&1 && fail 'unknown CLI accepted'
  roles_cmd set reviewer claude --profile missing --scope project > /dev/null 2>&1 && fail 'missing profile accepted'
  [ ! -f "$C1/project/.agentic-flow-roles" ] || fail 'invalid set wrote project file'
  roles_cmd set reviewer claude --scope project || fail 'project set failed'
  printf '%s' "$ROLES_JSON" | jq -e '.[]|select(.station=="reviewer")|.cli=="claude" and .model=="-" and .effort=="-" and .profile=="config/stations/claude.settings.json" and .layer=="project"' >/dev/null || fail 'CLI change did not reset fields'
  git -C "$C1/project" diff --cached --name-only | grep -Fxq .agentic-flow-roles || fail 'project assignment not staged'
  roles_cmd set reviewer codex || fail 'operator set failed'
  printf '%s' "$ROLES_JSON" | jq -e '.[]|select(.station=="reviewer")|.cli=="codex" and .layer=="operator"' >/dev/null || fail 'operator precedence wrong'
  roles_cmd unset reviewer || fail 'operator unset failed'
  printf '%s' "$ROLES_JSON" | jq -e '.[]|select(.station=="reviewer")|.cli=="claude" and .layer=="project"' >/dev/null || fail 'unset did not fall back'
  roles_cmd set reviewer claude --model fixture-model --timeout-s 12 --scope project || fail 'field edit failed'
  roles_cmd set reviewer claude --budget-usd nope --scope project > /dev/null 2>&1 && fail 'invalid numeric field accepted'
  roles_cmd set reviewer claude --timeout-s - --scope project > /dev/null 2>&1 || fail 'default timeout refused'
  launch_assignment reviewer "$C1/project" || fail 'default timeout assignment failed'
  [ "$LAUNCH_TIMEOUT" = 2700 ] || fail 'default timeout has no controller watchdog'
  roles_cmd set reviewer codex --scope project >/dev/null 2>&1 || fail 'codex reassign failed'
  roles_same_model "$C1/project" > "$C1/preflight" 2>&1 && fail 'same-model pair passed without risk'
  grep -q same-model-review "$C1/preflight" || fail 'same-model gap unnamed'
  roles_cmd set reviewer codex --model different --scope project >/dev/null 2>&1 || fail 'different model set failed'
  roles_same_model "$C1/project" >/dev/null 2>&1 || fail 'different model pair gated'
  roles_cmd manual reviewer || fail 'manual set failed'
  launch_preflight reviewer "$C1/project" || fail 'manual preflight checked the station'
  launch_station reviewer "$C1/project" "$C1/packet with spaces.md" "$C1/result" > /dev/null 2>&1 && fail 'manual station launched'
  roles_cmd unset reviewer || fail 'manual unset failed'
  roles_cmd set reviewer opencode --scope project >/dev/null 2>&1 || fail 'OpenCode assignment failed'
  launch_preflight reviewer "$C1/project" > "$C1/preflight" 2>&1 && fail 'OpenCode risk missing but preflight passed'
  grep -q opencode-station-network "$C1/preflight" || fail 'OpenCode risk gap unnamed'
  printf '<a id="opencode-station-network"></a>\n## OpenCode\n**Status:** Accepted risk\n' > "$C1/project/docs/accepted_risks.md"
  launch_preflight reviewer "$C1/project" > "$C1/preflight" 2>&1 || fail 'accepted OpenCode preflight failed'
  grep -q 'warning: accepted risk opencode-station-network' "$C1/preflight" || fail 'OpenCode warning absent'
  mv "$HOME/.codex/agentic-station.config.toml" "$C1/saved-profile"
  launch_preflight executor "$C1/project" > "$C1/preflight" 2>&1 && fail 'missing installed Codex profile accepted'
  grep -q 'missing Codex profile' "$C1/preflight" || fail 'missing Codex profile gap unnamed'
  mv "$C1/saved-profile" "$HOME/.codex/agentic-station.config.toml"
  launch_preflight executor "$C1/project" > "$C1/preflight" 2>&1 || fail 'Codex preflight failed'
  echo unsafe-config > "$C1/behavior"
  launch_preflight executor "$C1/project" > "$C1/preflight" 2>&1 && fail 'unsafe merged Codex settings passed'
  grep -q 'effective sandbox/network/connector' "$C1/preflight" || fail 'unsafe Codex gap unnamed'
  echo unsafe-apps > "$C1/behavior"
  launch_preflight executor "$C1/project" > "$C1/preflight" 2>&1 && fail 'Codex built-in Apps remained enabled'
  grep -q 'effective sandbox/network/connector' "$C1/preflight" || fail 'unsafe Codex Apps gap unnamed'
  echo weak-opencode > "$C1/behavior"
  launch_preflight reviewer "$C1/project" > "$C1/preflight" 2>&1 && fail 'weakened OpenCode settings passed'
  grep -q 'effective deny settings' "$C1/preflight" || fail 'unsafe OpenCode gap unnamed'
  rm "$C1/behavior"
  printf 'reviewer\tunknown\t-\t-\t-\t-\t12\tconfig/stations/opencode.json\n' > "$C1/operator/agentic-flow/roles/fixture/project.tsv"
  roles_load "$C1/project" > "$C1/invalid" 2>&1 && fail 'bad operator row accepted'
  grep -q 'project.tsv:1: unknown CLI' "$C1/invalid" || fail 'operator error lacks line'
  roles_load "$C1/project" false || fail 'gate unexpectedly reads operator layer'
  : > "$C1/operator/agentic-flow/roles/fixture/project.tsv"
  cat "$C1/project/.agentic-flow-roles" > "$C1/saved-roles"
  printf 'reviewer\tunknown\t-\t-\t-\t-\t12\tconfig/stations/opencode.json\n' > "$C1/project/.agentic-flow-roles"
  ( ROOT="$C1/project"; fast_check_group controller ) > "$C1/gate" 2>&1 && fail 'make check fast gate accepted hand-edited bad project CLI'
  grep -q 'unknown CLI' "$C1/gate" || fail 'bad project CLI gap unnamed'
  printf 'reviewer\topencode\t-\t-\t-\t-\t12\tmissing-profile\n' > "$C1/project/.agentic-flow-roles"
  ( ROOT="$C1/project"; fast_check_group controller ) > "$C1/gate" 2>&1 && fail 'make check fast gate accepted missing project profile'
  grep -q 'missing profile' "$C1/gate" || fail 'bad project profile gap unnamed'
  mv "$C1/saved-roles" "$C1/project/.agentic-flow-roles"
  # Each CLI can serve each station with the correct bundle and mode.
  for cli in claude codex opencode; do
    for station in executor reviewer; do
      roles_cmd set "$station" "$cli" --scope project > /dev/null 2>&1 || fail 'matrix assignment failed'
      launch_station "$station" "$C1/project" "$C1/packet with spaces.md" "$C1/result" > "$C1/launch.json" || fail "launch failed: $cli $station"
      jq -e '.exit==0 and .usage.input!=null and .usage.output!=null' "$C1/launch.json" >/dev/null || fail 'launch metadata missing'
      [ "$(head -n 1 "$C1/observed/prompt")" = "You are the $station station for step unknown." ] || fail 'preamble is not first'
      if [ "$station" = executor ]; then grep -q 'ENGINEERING STANDARDS' "$C1/observed/prompt" || fail 'executor lacks live standards'; else grep -q '# Review execution' "$C1/observed/prompt" || fail 'reviewer lacks reviewer contract'; fi
      ! grep -q PLANNER_MUST "$C1/observed/prompt" || fail 'planner contract passed to station'
      ! grep -Eq '^(GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|GITHUB_ENTERPRISE_TOKEN|UNLISTED_HOST_VALUE)=' "$C1/observed/env" || fail 'environment allowlist failed'
      [ "$(cat "$C1/observed/pushurl")" = no-push://disabled ] || fail 'origin push not disabled'
      [ "$(cat "$C1/observed/second-pushurl")" = no-push://disabled ] || fail 'second remote push not disabled'
      case "$cli:$station" in codex:executor) mode=native ;; codex:reviewer) mode=excluded ;; *) mode=overridden ;; esac
      jq -e --arg mode "$mode" '.contract_mode==$mode' "$C1/launch.json" >/dev/null || fail 'wrong contract mode'
      LAUNCH_RESUME_CLI=wrong LAUNCH_RESUME_PROFILE=wrong launch_station "$station" "$C1/project" "$C1/packet with spaces.md" "$C1/result" --resume old > /dev/null 2>&1 && fail 'mismatched session accepted'
    done
  done
  roles_cmd set executor claude --scope project > /dev/null 2>&1 || fail 'Claude assignment failed'
  ANTHROPIC_API_KEY=fixture launch_station executor "$C1/project" "$C1/packet with spaces.md" "$C1/result" > "$C1/launch.json" || fail 'API-key Claude failed'
  grep -Fxq -- --bare "$C1/observed/argv" || fail 'API-key Claude lacks bare'
  jq -e '.contract_mode=="excluded"' "$C1/launch.json" >/dev/null || fail 'bare Claude mode wrong'
  echo failure > "$C1/behavior"
  status=0
  launch_station executor "$C1/project" "$C1/packet with spaces.md" "$C1/result" > "$C1/launch.json" || status=$?
  [ "$status" = 17 ] || fail 'station failure exit was lost'
  jq -e '.exit==17 and .result==null' "$C1/launch.json" >/dev/null || fail 'failed station reused stale result'
  echo malformed > "$C1/behavior"
  launch_station executor "$C1/project" "$C1/packet with spaces.md" "$C1/result" > "$C1/launch.json" || fail 'malformed capture failed'
  jq -e '.result==null and .usage.input==null' "$C1/launch.json" >/dev/null || fail 'malformed stream guessed output'
  echo timeout > "$C1/behavior"
  roles_cmd set executor claude --timeout-s 1 --scope project >/dev/null 2>&1 || fail 'timeout assignment failed'
  status=0
  launch_station executor "$C1/project" "$C1/packet with spaces.md" "$C1/result" > "$C1/launch.json" || status=$?
  [ "$status" = 124 ] || fail 'station timeout not enforced'
  jq -e '.exit==124' "$C1/launch.json" >/dev/null || fail 'timeout metadata missing'
  before=$(wc -c < "$C1/observed/heartbeat")
  sleep 0.4
  after=$(wc -c < "$C1/observed/heartbeat")
  [ "$before" = "$after" ] || fail 'timeout left a live descendant'
  rm "$C1/behavior"
  roles_cmd set executor codex --timeout-s 12 --scope project >/dev/null 2>&1 || fail 'Codex resume assignment failed'
  launch_session_record() { printf '%s\n' "$1" > "$C1/session-record"; }
  LAUNCH_RESUME_CLI=codex LAUNCH_RESUME_PROFILE=config/stations/codex.config.toml launch_station executor "$C1/project" "$C1/packet with spaces.md" "$C1/result" --resume codex-session > "$C1/launch.json" || fail 'compatible resume failed'
  grep -Fxq codex-session "$C1/session-record" || fail 'Codex session callback missing'
  grep -Fxq resume "$C1/observed/argv" || fail 'compatible resume not passed'
  grep -Fxq 'mcp_servers."fixture".enabled=false' "$C1/observed/argv" || fail 'configured Codex connector was not disabled'
  grep -Fxq features.apps=false "$C1/observed/argv" || fail 'built-in Codex Apps were not disabled'
  grep -Fxq -- --output-schema "$C1/observed/argv" || fail 'resume schema not passed'
  echo callback-failure > "$C1/behavior"
  launch_session_record() { return 1; }
  rm -f "$C1/observed/child"
  status=0
  launch_station executor "$C1/project" "$C1/packet with spaces.md" "$C1/result" > "$C1/launch.json" || status=$?
  [ "$status" = 2 ] || fail 'failed session callback did not fail the launch'
  [ -s "$C1/observed/child" ] || fail 'callback failure did not exercise a live station child'
  before=$(wc -c < "$C1/observed/heartbeat")
  sleep 0.4
  after=$(wc -c < "$C1/observed/heartbeat")
  [ "$before" = "$after" ] || fail 'failed session callback left the station group running'
  unset -f launch_session_record
  echo normal-child > "$C1/behavior"
  rm -f "$C1/observed/child"
  launch_station executor "$C1/project" "$C1/packet with spaces.md" "$C1/result" > "$C1/launch.json" || fail 'station with background child failed normally'
  jq -e '.exit==0' "$C1/launch.json" >/dev/null || fail 'normal station exit was changed by cleanup'
  [ -s "$C1/observed/child" ] || fail 'normal-exit test did not launch a background child'
  before=$(wc -c < "$C1/observed/heartbeat")
  sleep 0.4
  after=$(wc -c < "$C1/observed/heartbeat")
  [ "$before" = "$after" ] || fail 'normal station exit left a background child running'
  rm "$C1/behavior"
  roles_cmd set executor claude --scope project >/dev/null 2>&1 || fail 'Claude sandbox assignment failed'
  launch_assignment executor "$C1/project" || fail 'Claude sandbox assignment missing'
  jq 'del(.sandbox)' "$LAUNCH_PROFILE" > "$C1/claude-unsafe.json"
  LAUNCH_PROFILE="$C1/claude-unsafe.json"
  launch_profile_check > "$C1/preflight" 2>&1 && fail 'Claude without sandbox settings passed'
  grep -q 'strict sandbox/network' "$C1/preflight" || fail 'Claude sandbox gap unnamed'
  # Missing usage is null for every parser; a reported zero stays zero.
  for cli in claude codex opencode; do
    printf '{}\n' | jq -s --arg cli "$cli" -f "$ROOT/scripts/lib/station-output.jq" | jq -e '.usage=={input:null,output:null,cost_usd:null}' >/dev/null || fail "missing usage guessed: $cli"
  done
  printf '<a id="same-model-review"></a>\n## Model diversity\n**Status:** Accepted risk\n' >> "$C1/project/docs/accepted_risks.md"
  roles_cmd set executor claude --scope project >/dev/null 2>&1 || fail 'same pair executor set failed'
  roles_cmd set reviewer claude --scope project >/dev/null 2>&1 || fail 'same pair set failed'
  roles_same_model "$C1/project" >/dev/null 2>&1 || fail 'accepted same-model pair gated'
  sed 's/Accepted risk/Retired/' "$C1/project/docs/accepted_risks.md" > "$C1/retired"
  mv "$C1/retired" "$C1/project/docs/accepted_risks.md"
  roles_same_model "$C1/project" >/dev/null 2>&1 && fail 'retired same-model risk accepted'
  return 0
)
controller_tests || fail 'controller regressions failed'
for action in set unset manual; do
  must_block "$ROOT/scripts/hooks/require-step-comment.sh" "scripts/agentic-flow roles $action reviewer claude"
  must_block "$ROOT/scripts/hooks/require-step-comment.sh" "rtk proxy scripts/agentic-flow roles $action reviewer claude"
done
must_allow "$ROOT/scripts/hooks/require-step-comment.sh" 'scripts/agentic-flow roles --json'
# Real captured output is the parser contract, independently of adapter fakes.
for cli in claude codex opencode; do
  parsed=$(jq -s --arg cli "$cli" -f "$ROOT/scripts/lib/station-output.jq" "$ROOT/scripts/tests/fixtures/controller/$cli.jsonl") || fail "captured $cli output did not parse"
  printf '%s' "$parsed" | jq -e '.session!=null and .result=="OK"' >/dev/null || fail "captured $cli session/result incorrect"
  case "$cli" in claude) expected='{"input":2,"output":65,"cost_usd":0.0308938}' ;;
    codex) expected='{"input":15265,"output":5,"cost_usd":null}' ;;
    opencode) expected='{"input":6776,"output":2,"cost_usd":0}' ;; esac
  printf '%s' "$parsed" | jq -e --argjson expected "$expected" '.usage==$expected' >/dev/null || fail "captured $cli usage incorrect"
done
# Upgrade replaces only harness defaults, including when a source tries to claim
# the project layer as a payload destination.
controller_upgrade_test() (
  local source="$C1/upgrade-source" target="$C1/upgrade-target"
  mkdir -p "$source/config" "$source/scripts/lib" "$target/config" "$target/scripts/lib"
  printf '10.0.0\n' > "$source/VERSION"
  printf 'config/roles.tsv\tconfig/roles.tsv\tcore\tpreserve\texport\nconfig/payload.tsv\tconfig/payload.tsv\tcore\tpreserve\texport\n' > "$source/config/payload.tsv"
  ln "$ROOT/config/roles.tsv" "$source/config/roles.tsv"
  ln "$ROOT/scripts/lib/payload-apply.sh" "$source/scripts/lib/"
  git -C "$source" init -q
  git -C "$source" config user.email fixture@example.invalid
  git -C "$source" config user.name Fixture
  git -C "$source" config commit.gpgsign false
  git -C "$source" add VERSION config/roles.tsv config/payload.tsv scripts/lib/payload-apply.sh
  git -C "$source" commit -qm 'Upgrade roles fixture'
  git -C "$source" branch -M main
  printf 'old\n' > "$target/.agentic-flow-version"
  printf 'origin file://%s\nref main\n' "$source" > "$target/.agentic-flow-source"
  printf '# old harness defaults\n' > "$target/config/roles.tsv"
  printf 'project-owned choice\n' > "$target/.agentic-flow-roles"
  printf 'config/roles.tsv\tconfig/roles.tsv\tcore\tpreserve\texport\nconfig/payload.tsv\tconfig/payload.tsv\tcore\tpreserve\texport\n' > "$target/config/payload.tsv"
  ln "$ROOT/scripts/lib/payload-apply.sh" "$target/scripts/lib/"
  (cd "$target" && "$ROOT/scripts/agentic-flow" upgrade --force --yes) > "$C1/upgrade.out" 2>&1 || fail 'role defaults upgrade failed'
  cmp -s "$source/config/roles.tsv" "$target/config/roles.tsv" || fail 'upgrade did not replace harness defaults'
  grep -Fxq 'project-owned choice' "$target/.agentic-flow-roles" || fail 'upgrade touched project roles'
  printf 'malicious fixture\n' > "$source/config/project-choice.tsv"
  printf 'config/project-choice.tsv\t.agentic-flow-roles\tcore\tpreserve\texport\n' >> "$source/config/payload.tsv"
  git -C "$source" add config/payload.tsv config/project-choice.tsv
  git -C "$source" commit -qm 'Malicious role destination fixture'
  (cd "$target" && "$ROOT/scripts/agentic-flow" upgrade --force --yes) > "$C1/upgrade.out" 2>&1 && fail 'upgrade admitted project-owned role destination'
  grep -q project-owned "$C1/upgrade.out" || fail "upgrade refusal did not name ownership: $(cat "$C1/upgrade.out")"
  grep -Fxq 'project-owned choice' "$target/.agentic-flow-roles" || fail 'rejected upgrade touched project roles'
)
controller_upgrade_test || fail 'role upgrade regressions failed'
# Reviewer contracts travel with the station, including in non-Codex exports.
if [ -f "$ROOT/scripts/export.sh" ]; then
  (
    # shellcheck disable=SC2034 # Consumed by the sourced payload library.
    PAYLOAD_EXCLUDED_SCOPES=codex
    payload_load_manifest "$ROOT/config/payload.tsv"
    payload_expand_files "$ROOT"
    printf '%s\n' "${DESTS[@]}" | grep -Fxq .agents/skills/review-execution/SKILL.md || fail 'excluding Codex removed the vendor-neutral reviewer bundle'
    printf '%s\n' "${DESTS[@]}" | grep -Fxq .agents/skills/plan-to-issues/SKILL.md && fail 'station bundle swept Codex-only skills back in'
    exit 0
  ) || fail 'station contract export regression failed'
fi

# --- C-2 durable local ledger and offline metrics -----------------------------------------
ledger_tests() (
  . "$ROOT/scripts/lib/ledger.sh"
  ledger_init "$C1/project" || fail 'ledger common-dir initialization failed'
  local c2="$TMP/ledger-c2" before after stored digest run
  mkdir -p "$c2"
  printf 'findings\nlínea two ☃\n' > "$c2/body"
  # Worktrees must resolve the same physical common directory, not private .git files.
  before=$LEDGER_DIR
  git -C "$C1/project" worktree add --quiet --detach "$c2/worktree" HEAD || fail 'ledger worktree fixture failed'
  ledger_init "$c2/worktree" || fail 'linked worktree ledger initialization failed'
  [ "$LEDGER_DIR" = "$before" ] || fail 'worktree got a private ledger'
  git -C "$C1/project" worktree remove "$c2/worktree" || fail 'ledger worktree fixture cleanup failed'
  ledger_init "$C1/project" || fail 'ledger initialization restore failed'
  c2_send() { # kind plan; JSON on stdin
    cat > "$c2/record.json"
    ledger_append "$1" "$2" "$c2/record.json" > "$c2/last.json"
  }
  c2_intent() { # run [reason] [replaces] [preassigned-session]
    local id=$1 reason=${2:-initial} replaces=${3:-} session=${4:-}
    jq -n --arg run "$id" --arg reason "$reason" --arg replaces "$replaces" --arg session "$session" '
      ($run|split("/")) as $p |
      {v:1,kind:"intent",run:$run,chain:($p[0:5]|join("/")),replaces:(if $replaces=="" then null else $replaces end),
       reason:$reason,plan:$p[0],issue:($p[1]|tonumber),step:("c-"+$p[1]),station:$p[3],cli:"codex",model:"fixture",
       resume_of:null,session:(if $session=="" then null else $session end),session_mode:"new",reassigned_from:null,
       seq_before:($p[2]|tonumber),base_head:("a"*40),packet_sha256:("b"*64),started:100,host:"fixture"}' |
      c2_send intent "${id%%/*}"
  }
  c2_station() { # run outcome [invalid reason] [usage JSON]
    local id=$1 outcome=$2 invalid=${3:-} usage=${4:-'{"input":10,"output":5,"cost_usd":0.5}'}
    jq -n --arg run "$id" --arg outcome "$outcome" --arg invalid "$invalid" --argjson usage "$usage" '
      ($run|split("/")[3]) as $station |
      {v:1,kind:"station",run:$run,exit:0,seconds:10,usage:$usage,ended:200,
       invalid_reason:(if $invalid=="" then null else $invalid end),
       result:(if $invalid!="" then null else
         {v:1,station:$station,outcome:$outcome,head:(if $outcome=="ask" then null else "a"*40 end),
          summary:"fixture",question:(if $outcome=="ask" then "Which approach?" else null end),
          findings:(if $outcome=="bounce" then [{severity:"P2",file:"fixture",line:1,text:"fix it"}] else [] end)} end)}' |
      c2_send station "${id%%/*}"
  }
  c2_verify() {
    jq -n --arg run "$1" --arg status "$2" '{v:1,kind:"verify",run:$run,head:("a"*40),record:"fixture.json",status:$status,at:250}' |
      c2_send verify "${1%%/*}"
  }
  c2_decision() {
    local sum
    sum=$(shasum -a 256 "$c2/body"); sum=${sum%% *}
    jq -n --arg run "$1" --arg action "$2" --arg file "$c2/body" --arg sum "$sum" '
      {v:1,kind:"decision",run:$run,action:$action,event:$action,head:("a"*40),body_file:$file,body_sha256:$sum,at:300}' |
      c2_send decision "${1%%/*}"
  }
  c2_handoff() {
    jq -n --arg run "$1" --argjson attempt "$2" --argjson exit "$3" --arg event "${4:-ask}" '
      {v:1,kind:"handoff",run:$run,attempt:$attempt,event:$event,after:($run|split("/")[2]|tonumber),
       exit:$exit,seq_after:(if $exit==0 then 1 else null end),at:400}' |
      c2_send handoff "${1%%/*}"
  }
  c2_expect() {
    ledger_chains "$1" > "$c2/chains.json" || fail 'chain derivation failed'
    jq -e "$2" "$c2/chains.json" >/dev/null || fail "ledger chain expectation: $2"
  }
  # Literal prefix table: each durable boundary maps to its head, pending item
  # and complete allowance vector. A replaced run never becomes open again.
  ledger_chains table | jq -e 'length==0' >/dev/null || fail 'empty prefix has chain heads'
  while IFS='|' read -r operation expected_run pending invalid_left fix_left recovery_left closed_count; do
    case "$operation" in
      intent1) c2_intent 'table/1/0/executor/1/1' || fail 'prefix intent failed' ;;
      session1|session2)
        run="table/1/0/executor/1/${operation#session}"
        jq -n --arg run "$run" '{v:1,kind:"session",run:$run,session:"fixture-session",at:110}' |
          c2_send session table || fail 'prefix session failed' ;;
      station1|station2)
        c2_station "table/1/0/executor/1/${operation#station}" submitted || fail 'prefix station failed' ;;
      red) c2_verify 'table/1/0/executor/1/1' red || fail 'prefix red gate failed' ;;
      intent2) c2_intent 'table/1/0/executor/1/2' fix 'table/1/0/executor/1/1' || fail 'prefix replacement failed' ;;
      green) c2_verify 'table/1/0/executor/1/2' green || fail 'prefix green gate failed' ;;
      decision) c2_decision 'table/1/0/executor/1/2' submit || fail 'prefix decision failed' ;;
      retry) c2_handoff 'table/1/0/executor/1/2' 1 5 submit || fail 'prefix handoff retry failed' ;;
      success) c2_handoff 'table/1/0/executor/1/2' 2 0 submit || fail 'prefix handoff completion failed' ;;
      *) fail 'unknown prefix-table operation' ;;
    esac
    ledger_chains table | jq -e --arg n "$expected_run" --arg pending "$pending" \
      --argjson invalid "$invalid_left" --argjson fix "$fix_left" --argjson recovery "$recovery_left" --argjson closed "$closed_count" '
      .[0] | .head==(if $n=="none" then null else "table/1/0/executor/1/"+$n end)
      and .pending==(if $pending=="none" then null else $pending end)
      and .remaining=={resume_valid:$invalid,fix:$fix,recovery:$recovery}
      and (.closed_runs|length)==$closed' >/dev/null || fail "incorrect chain prefix: $operation"
  done <<'PREFIXES'
intent1|1|relaunch|1|1|3|0
session1|1|resume-packet|1|1|3|0
station1|1|verify|1|1|3|0
red|1|fix|1|1|3|0
intent2|2|relaunch|1|0|3|1
session2|2|resume-packet|1|0|3|1
station2|2|verify|1|0|3|1
green|2|decide|1|0|3|1
decision|2|handoff|1|0|3|1
retry|2|handoff|1|0|3|1
success|none|none|1|0|3|2
PREFIXES
  printf '{"v":1,"kind":"unknown"}\n' | c2_send station demo > "$c2/error" 2>&1 && fail 'malformed record accepted'
  [ ! -e "$LEDGER_DIR/demo.jsonl" ] || fail 'rejected record created ledger'
  mkfifo "$c2/fifo" || fail 'record FIFO fixture failed'
  ledger_append station demo "$c2/fifo" > "$c2/error" 2>&1 && fail 'record writer accepted a blocking FIFO'
  c2_intent 'demo/1/0/executor/1/1' || fail 'initial intent failed'
  mkfifo "$LEDGER_DIR/pipe.jsonl" || fail 'ledger FIFO fixture failed'
  ledger_read pipe > "$c2/error" 2>&1 && fail 'reader accepted a blocking ledger FIFO'
  rm "$LEDGER_DIR/pipe.jsonl"
  c2_expect demo '.[0]|.head=="demo/1/0/executor/1/1" and .pending=="relaunch" and .remaining=={resume_valid:1,fix:1,recovery:3}'
  printf '{"demo/1/0/executor/1/1":{"commit":true}}\n' > "$c2/context"
  ledger_chains demo "$c2/context" | jq -e '.[0].pending=="fresh-result"' >/dev/null || fail 'commit recovery without session wrong'
  printf '{"demo/1/0/executor/1/1":{"dirty":true}}\n' > "$c2/context"
  ledger_chains demo "$c2/context" | jq -e '.[0].pending=="fresh-dirty"' >/dev/null || fail 'dirty recovery without session wrong'
  jq -n '{v:1,kind:"session",run:"demo/1/0/executor/1/1",session:"codex-session",at:110}' |
    c2_send session demo || fail 'session record failed'
  ledger_session demo "$c2/record.json" > "$c2/error" 2>&1 && fail 'duplicate session accepted'
  c2_expect demo '.[0]|.pending=="resume-packet" and .session=="codex-session"'
  printf '{"demo/1/0/executor/1/1":{"commit":true}}\n' > "$c2/context"
  ledger_chains demo "$c2/context" | jq -e '.[0].pending=="resume-result"' >/dev/null || fail 'commit recovery with session wrong'
  printf '{"demo/1/0/executor/1/1":{"dirty":true}}\n' > "$c2/context"
  ledger_chains demo "$c2/context" | jq -e '.[0].pending=="resume-dirty"' >/dev/null || fail 'dirty recovery with session wrong'
  c2_station 'demo/1/0/executor/1/1' submitted || fail 'station record failed'
  c2_expect demo '.[0].pending=="verify"'
  before=$(wc -c < "$LEDGER_DIR/demo.jsonl")
  c2_station 'demo/1/0/executor/1/1' submitted > "$c2/error" 2>&1 && fail 'duplicate station accepted'
  [ "$(wc -c < "$LEDGER_DIR/demo.jsonl")" = "$before" ] || fail 'rejected station changed ledger'
  c2_verify 'demo/1/0/executor/1/1' red || fail 'red verification failed'
  c2_expect demo '.[0]|.pending=="fix" and .remaining.fix==1'
  c2_intent 'demo/1/0/executor/1/2' fix 'demo/1/0/executor/1/1' || fail 'fix replacement failed'
  c2_expect demo '.[0]|.head=="demo/1/0/executor/1/2" and .remaining.fix==0 and .closed_runs==["demo/1/0/executor/1/1"]'
  c2_intent 'demo/1/0/executor/1/3' relaunch 'demo/1/0/executor/1/1' > "$c2/error" 2>&1 && fail 'stale replaces accepted'
  grep -q 'not the open chain head' "$c2/error" || fail 'stale replacement gap unnamed'
  c2_station 'demo/1/0/executor/1/2' ask malformed || fail 'first invalid station failed'
  c2_expect demo '.[0]|.pending=="resume-valid" and .counts.invalid_results==1 and .remaining.resume_valid==1'
  c2_intent 'demo/1/0/executor/1/3' resume-valid 'demo/1/0/executor/1/2' || fail 'validity retry failed'
  c2_station 'demo/1/0/executor/1/3' ask malformed || fail 'second invalid station failed'
  c2_expect demo '.[0]|.pending=="decide" and .escalation=="malformed station result" and .remaining.resume_valid==0 and (.closed_runs|length)==2'
  c2_intent 'demo/2/0/executor/1/1' || fail 'red-chain intent failed'
  c2_station 'demo/2/0/executor/1/1' submitted || fail 'red-chain station failed'
  c2_verify 'demo/2/0/executor/1/1' red || fail 'red-chain verify failed'
  c2_intent 'demo/2/0/executor/1/2' fix 'demo/2/0/executor/1/1' || fail 'red-chain fix failed'
  c2_station 'demo/2/0/executor/1/2' submitted || fail 'red-chain fixed station failed'
  c2_verify 'demo/2/0/executor/1/2' red || fail 'second red gate failed'
  c2_expect demo '.[]|select(.chain=="demo/2/0/executor/1")|.pending=="decide" and .escalation=="gate still red after fix" and .remaining.fix==0'
  c2_intent 'demo/3/0/executor/1/1' || fail 'recovery intent failed'
  for n in 2 3 4; do
    c2_intent "demo/3/0/executor/1/$n" relaunch "demo/3/0/executor/1/$((n-1))" || fail 'recovery replacement failed'
    c2_expect demo ".[]|select(.chain==\"demo/3/0/executor/1\")|.remaining.recovery==$((4-n)) and (.closed_runs|length)==$((n-1))"
  done
  c2_expect demo '.[]|select(.chain=="demo/3/0/executor/1")|.pending=="decide" and .escalation=="station keeps failing to finish"'
  c2_intent 'demo/4/0/reviewer/1/1' initial '' preassigned || fail 'reviewer intent failed'
  c2_expect demo '.[]|select(.chain=="demo/4/0/reviewer/1")|.pending=="relaunch"'
  c2_station 'demo/4/0/reviewer/1/1' ask || fail 'reviewer ask failed'
  c2_expect demo '.[]|select(.chain=="demo/4/0/reviewer/1")|.pending=="decide"'
  c2_decision 'demo/4/0/reviewer/1/1' ask || fail 'decision failed'
  c2_expect demo '.[]|select(.chain=="demo/4/0/reviewer/1")|.pending=="handoff"'
  c2_decision 'demo/4/0/reviewer/1/1' ask > "$c2/error" 2>&1 && fail 'duplicate decision accepted'
  ledger_body demo 'demo/4/0/reviewer/1/1' > "$c2/body-copy" || fail 'stored body unavailable'
  cmp -s "$c2/body" "$c2/body-copy" || fail 'stored body changed bytes'
  stored=$(ledger_read demo | jq -r '.[]|select(.kind=="decision")|.body_file')
  printf 'tamper' >> "$stored"
  ledger_body demo 'demo/4/0/reviewer/1/1' > "$c2/body-copy" 2> "$c2/error" && fail 'tampered decision body accepted'
  [ ! -s "$c2/body-copy" ] || fail 'tampered body leaked to replay'
  printf 'findings\nlínea two ☃\n' > "$stored"
  c2_handoff 'demo/4/0/reviewer/1/1' 1 5 || fail 'retryable handoff failed'
  c2_expect demo '.[]|select(.chain=="demo/4/0/reviewer/1")|.pending=="handoff"'
  c2_handoff 'demo/4/0/reviewer/1/1' 2 0 || fail 'successful handoff failed'
  c2_expect demo '.[]|select(.chain=="demo/4/0/reviewer/1")|.head==null and .pending==null and (.closed_runs|length)==1'
  for exit in 3 4 7; do
    run="demo/$((10+exit))/0/reviewer/1/1"
    c2_intent "$run" || fail 'terminal intent failed'
    c2_station "$run" ask || fail 'terminal station failed'
    c2_decision "$run" ask || fail 'terminal decision failed'
    c2_handoff "$run" 1 "$exit" || fail 'terminal handoff failed'
    c2_expect demo ".[]|select(.latest==\"$run\")|.head==null and .pending==null"
  done
  c2_intent 'demo/5/0/executor/1/1' || fail 'end intent failed'
  jq -n '{v:1,kind:"end",chain:"demo/5/0/executor/1",how:"held",hold:"fixture",at:410}' |
    c2_send end demo || fail 'chain end failed'
  [ "$(ledger_generation demo 5 0 executor)" = 2 ] || fail 'ended generation not advanced'
  c2_intent 'demo/5/0/executor/2/1' || fail 'new generation failed'
  c2_expect demo '.[]|select(.chain=="demo/5/0/executor/2")|.remaining=={resume_valid:1,fix:1,recovery:3}'
  c2_intent 'green/1/0/executor/1/1' || fail 'green intent failed'
  c2_station 'green/1/0/executor/1/1' submitted || fail 'green station failed'
  c2_decision 'green/1/0/executor/1/1' submit > "$c2/error" 2>&1 && fail 'unverified submit decision accepted'
  c2_verify 'green/1/0/executor/1/1' green || fail 'green verify failed'
  c2_verify 'green/1/0/executor/1/1' green > "$c2/error" 2>&1 && fail 'duplicate verification accepted'
  c2_expect green '.[0].pending=="decide"'
  c2_decision 'green/1/0/executor/1/1' submit || fail 'verified submit decision failed'
  c2_handoff 'green/1/0/executor/1/1' 1 0 submit || fail 'green handoff failed'
  c2_expect green '.[0].head==null and .[0].closed_runs==["green/1/0/executor/1/1"]'
  jq -n '{v:1,kind:"salvage",run:"green/1/0/executor/1/1",chain:"green/1/0/executor/1",
    ref:"refs/agentic-flow/salvage/green/1/0/executor/1/1",head:("a"*40),index_commit:("a"*40),
    worktree_commit:("a"*40),index_tree:("a"*40),worktree_tree:("a"*40),paths:[],at:410}' |
    c2_send salvage green || fail 'post-completion salvage failed'
  c2_expect green '.[0].head==null and .[0].pending==null'
  c2_intent 'salvage/1/0/executor/1/1' || fail 'salvage intent failed'
  jq -n '{v:1,kind:"salvage",run:"salvage/1/0/executor/1/1",chain:"salvage/1/0/executor/1",
    ref:"refs/agentic-flow/salvage/salvage/1/0/executor/1/1",head:("a"*40),index_commit:("a"*40),
    worktree_commit:("a"*40),index_tree:("a"*40),worktree_tree:("a"*40),paths:[{path:"dirty.txt",status:"M"}],at:200}' |
    c2_send salvage salvage || fail 'salvage record failed'
  ledger_salvage salvage "$c2/record.json" > "$c2/error" 2>&1 && fail 'duplicate salvage accepted'
  c2_expect salvage '.[0].pending=="relaunch"'
  # Competing callers serialize validation and the single O_APPEND write.
  c2_intent 'race/1/0/executor/1/1' || fail 'concurrent writer intent failed'
  jq -n '{v:1,kind:"station",run:"race/1/0/executor/1/1",exit:1,seconds:1,
    usage:{input:null,output:null,cost_usd:null},result:null,invalid_reason:"fixture",ended:200}' > "$c2/race-record"
  (rc=0; ledger_station race "$c2/race-record" > "$c2/race-a.out" 2> "$c2/race-a.err" || rc=$?; echo "$rc" > "$c2/race-a.status") &
  pid_a=$!
  (rc=0; ledger_station race "$c2/race-record" > "$c2/race-b.out" 2> "$c2/race-b.err" || rc=$?; echo "$rc" > "$c2/race-b.status") &
  pid_b=$!
  wait "$pid_a" || fail 'first writer test process failed'
  wait "$pid_b" || fail 'second writer test process failed'
  case "$(cat "$c2/race-a.status"):$(cat "$c2/race-b.status")" in 0:2|2:0) ;; *) fail 'concurrent writers admitted duplicate station' ;; esac
  ledger_read race | jq -e 'length==2' >/dev/null || fail 'concurrent append interleaved records'
  mkdir -p "$c2/café project"
  git -C "$c2/café project" init -q || fail 'Unicode path fixture failed'
  ledger_init "$c2/café project" || fail 'Unicode common-dir initialization failed'
  c2_intent 'unicode/1/0/executor/1/1' || fail 'Unicode intent failed'
  c2_station 'unicode/1/0/executor/1/1' ask || fail 'Unicode station failed'
  c2_decision 'unicode/1/0/executor/1/1' ask || fail 'Unicode decision failed'
  ledger_body unicode 'unicode/1/0/executor/1/1' > "$c2/unicode-body" || fail 'Unicode body path was serialized incorrectly'
  cmp -s "$c2/body" "$c2/unicode-body" || fail 'Unicode body bytes were changed'
  ledger_init "$C1/project" || fail 'ledger restore after Unicode fixture failed'

  c2_intent 'torn/1/0/executor/1/1' || fail 'torn intent failed'
  printf '{"v":1,"kind":' >> "$LEDGER_DIR/torn.jsonl"
  digest=$(shasum -a 256 "$LEDGER_DIR/torn.jsonl"); digest=${digest%% *}
  before=$(wc -c < "$LEDGER_DIR/torn.jsonl")
  ledger_read torn > "$c2/torn.json" 2> "$c2/warning" || fail 'torn tail broke read'
  jq -e 'length==1' "$c2/torn.json" >/dev/null || fail 'torn tail was treated as committed'
  grep -q 'torn last line' "$c2/warning" || fail 'torn tail warning absent'
  c2_station 'torn/1/0/executor/1/1' ask > /dev/null 2> "$c2/warning" || fail 'append after torn tail failed'
  after=$(head -c "$before" "$LEDGER_DIR/torn.jsonl" | shasum -a 256); after=${after%% *}
  [ "$after" = "$digest" ] || fail 'torn recovery rewrote existing bytes'
  ledger_read torn | jq -e 'length==2' >/dev/null || fail 'sealed fragment broke subsequent read'
  # Simulate another crash after the repair's separator and partial new record.
  c2_intent 'twice/1/0/executor/1/1' || fail 'double-crash fixture intent failed'
  printf '{"first":\n{"second":' >> "$LEDGER_DIR/twice.jsonl"
  ledger_read twice > "$c2/torn.json" 2> "$c2/warning" || fail 'double torn suffix broke read'
  jq -e 'length==1' "$c2/torn.json" >/dev/null || fail 'double torn suffix became a record'
  c2_station 'twice/1/0/executor/1/1' ask > /dev/null 2> "$c2/warning" || fail 'double torn suffix could not be sealed'
  ledger_read twice | jq -e 'length==2' >/dev/null || fail 'double repair lost records'
  c2_intent 'no-lf/1/0/executor/1/1' || fail 'complete-no-LF intent failed'
  before=$(cat "$LEDGER_DIR/no-lf.jsonl")
  printf '%s' "$before" > "$LEDGER_DIR/no-lf.jsonl"
  ledger_read no-lf | jq -e 'length==1' >/dev/null || fail 'complete JSON without LF was discarded'
  c2_station 'no-lf/1/0/executor/1/1' ask || fail 'missing LF separator was not completed'
  ledger_read no-lf | jq -e 'length==2' >/dev/null || fail 'append joined two JSON objects'
  c2_intent 'bad/1/0/executor/1/1' || fail 'bad fixture intent failed'
  before=$(cat "$LEDGER_DIR/bad.jsonl")
  printf 'broken interior\n%s\n' "$before" > "$LEDGER_DIR/bad.jsonl"
  ledger_read bad > "$c2/invalid" 2>&1 && fail 'malformed interior record silently ignored'
  rm "$LEDGER_DIR/bad.jsonl"
  c2_intent 'old/1/0/executor/1/1' || fail 'old pending intent failed'
  perl -MJSON::PP -MDigest::SHA=sha256_hex -e '
    my ($dir,$template_file)=@ARGV; my $json=JSON::PP->new;
    open my $input,"<",$template_file or die $!;
    my $template=$json->decode(do {local $/; <$input>}); close $input;
    for my $plan (qw(old other)) {
      open my $fh,">>","$dir/$plan.jsonl" or die $!;
      for my $i (1001..4750) {
        my $run="$plan/$i/0/executor/1/1";
        my @records=(
          {%$template,plan=>$plan,issue=>$i,step=>"c-$i",run=>$run,chain=>"$plan/$i/0/executor/1",started=>101},
          {v=>1,kind=>"station",run=>$run,exit=>0,seconds=>1,usage=>{input=>1,output=>1,cost_usd=>0},ended=>200,invalid_reason=>undef,
            result=>{v=>1,station=>"executor",outcome=>"ask",summary=>"fixture",question=>"fixture?",findings=>[],head=>undef}},
          {v=>1,kind=>"decision",run=>$run,action=>"ask",event=>"ask",head=>undef,body_file=>"$dir/runs/$run/decision.md",body_sha256=>sha256_hex("fixture"),at=>210},
          {v=>1,kind=>"handoff",run=>$run,event=>"ask",attempt=>1,after=>0,exit=>0,seq_after=>1,at=>220});
        print $fh $json->encode($_),"\n" for @records;
      }
      close $fh;
    }' "$LEDGER_DIR" "$c2/record.json" || fail 'large-ledger fixture failed'
  c2_expect old '.[0]|.head=="old/1/0/executor/1/1" and .pending=="relaunch"'
  perl -e 'open my $f,">",$ARGV[0] or die $!; truncate($f,33554433) or die $!' "$LEDGER_DIR/oversize.jsonl"
  ledger_read oversize > "$c2/error" 2>&1 && fail 'oversize ledger was partially read'
  rm "$LEDGER_DIR/oversize.jsonl"
  perl -e 'open my $f,">",$ARGV[0] or die $!; print $f "{}\n" for 1..50001' "$LEDGER_DIR/too-many.jsonl"
  ledger_read too-many > "$c2/error" 2>&1 && fail 'ledger line cap absent'
  rm "$LEDGER_DIR/too-many.jsonl"

  c2_intent 'measured/1/0/executor/1/1' || fail 'metric executor intent failed'
  c2_station 'measured/1/0/executor/1/1' submitted '' '{"input":10,"output":4,"cost_usd":0.1}' || fail 'metric executor failed'
  c2_intent 'measured/1/1/reviewer/1/1' || fail 'metric reviewer intent failed'
  c2_station 'measured/1/1/reviewer/1/1' approve '' '{"input":5,"output":2,"cost_usd":null}' || fail 'metric reviewer failed'
  c2_intent 'measured/2/0/executor/1/1' || fail 'metric second intent failed'
  c2_station 'measured/2/0/executor/1/1' ask '' '{"input":null,"output":3,"cost_usd":0.2}' || fail 'metric second station failed'
  jq -c 'if .kind=="intent" and .station=="reviewer" then .started=210
    elif .kind=="intent" and .issue==2 then .started=300
    elif .kind=="station" and (.run|contains("/reviewer/")) then .ended=230|.seconds=20
    elif .kind=="station" and (.run|contains("/2/")) then .ended=350|.seconds=30
    else . end' "$LEDGER_DIR/measured.jsonl" > "$c2/adjusted"
  mv "$c2/adjusted" "$LEDGER_DIR/measured.jsonl"
  c2_decision 'measured/2/0/executor/1/1' ask || fail 'metric ask decision failed'
  c2_handoff 'measured/2/0/executor/1/1' 1 5 || fail 'metric handoff retry failed'
  c2_handoff 'measured/2/0/executor/1/1' 2 5 || fail 'metric repeated handoff failed'
  c2_handoff 'measured/2/0/executor/1/1' 3 0 || fail 'metric final handoff failed'
  jq -n '{v:1,kind:"hold",plan:"measured",hold:"network",issue:2,reason:"network gap",run:null,comment_id:null,at:400}' |
    c2_send hold measured || fail 'metric hold failed'
  ledger_hold measured "$c2/record.json" > "$c2/error" 2>&1 && fail 'duplicate hold accepted'
  jq -n '{v:1,kind:"clear",plan:"measured",hold:"network",by:"fixture",note:"resolved",at:410}' |
    c2_send clear measured || fail 'metric clear failed'
  ledger_clear measured "$c2/record.json" > "$c2/error" 2>&1 && fail 'duplicate clear accepted'
  for n in 1 2; do
    jq -n --arg id "ship-$n" --argjson at "$((550+20*n))" '{v:1,kind:"ship",plan:"measured",ship:$id,at:$at}' |
      c2_send ship measured || fail 'metric ship failed'
  done
  ledger_ship measured "$c2/record.json" > "$c2/error" 2>&1 && fail 'duplicate ship accepted'
  mkdir -p "$LEDGER_STATE_DIR"
  jq -n 'def e($step;$seq;$event;$role;$at):
    {id:("measured/"+$step+"/"+($seq|tostring)+"/"+$event),event:$event,role:$role,at:$at};
    {v:1,plan:"measured",rows:[
      {issue:1,step:"c-1",state:"approved",topology:"step-strict",events:[e("c-1";1;"submit";"executor";150),e("c-1";2;"approve";"reviewer";500)]},
      {issue:2,step:"c-2",state:"approved",topology:"step-strict",events:[
        e("c-2";1;"submit";"executor";310),e("c-2";2;"bounce";"reviewer";320),
        e("c-2";3;"submit";"executor";330),e("c-2";4;"bounce";"reviewer";340),
        e("c-2";5;"submit";"executor";350),e("c-2";6;"bounce";"reviewer";360),
        e("c-2";7;"resume";"approver";450),e("c-2";8;"submit";"executor";460),e("c-2";9;"approve";"reviewer";550)]},
      {issue:3,step:"tracker",state:"closed",topology:"tracker",events:[e("tracker";1;"notify";"reviewer";560),e("tracker";2;"close";"approver";600)]}]}' \
    > "$LEDGER_STATE_DIR/measured.metrics.json"
  (cd "$C1/project" && "$ROOT/scripts/agentic-flow" metrics --plan measured --json) > "$c2/metrics.json" || fail 'metrics command failed'
  jq -e '.plans[0]|.runs==3 and .completed==3 and .wall_seconds==60 and .usage=={input:null,output:9,cost_usd:null}
    and .lead_seconds==500 and .first_pass_yield==0.5 and .bounce_rate==0.6 and .human_touches=={resumes:1,approvals:2,ships:2,total:5}
    and .andon=={"ask":1,"network gap":1} and .stations.executor.wall_seconds==40 and .stations.reviewer.wall_seconds==20
    and .stations.reviewer.lead_seconds==390 and .stations.reviewer.first_pass_yield==1
    and .stations.reviewer.bounce_rate==0 and .stations.executor.first_pass_yield==0.5' "$c2/metrics.json" >/dev/null || fail 'metrics differ from hand-computed fixture'
  (cd "$C1/project" && "$ROOT/scripts/agentic-flow" metrics --plan measured --since 1970-01-01T00:04:00Z --json) > "$c2/metrics.json" || fail 'filtered metrics failed'
  jq -e '.plans[0]|.runs==1 and .usage=={input:null,output:3,cost_usd:0.2}' "$c2/metrics.json" >/dev/null || fail 'since filter used local time or wrong record'
  (cd "$C1/project" && "$ROOT/scripts/agentic-flow" metrics --plan measured) > "$c2/text" || fail 'text metrics failed'
  grep -q 'n/a' "$c2/text" || fail 'missing usage was not n/a'
  (cd "$C1/project" && "$ROOT/scripts/agentic-flow" metrics --plan '../escape' --json) > "$c2/error" 2>&1 && fail 'unsafe plan filter accepted'
  (cd "$C1/project" && "$ROOT/scripts/agentic-flow" metrics --since 2026-02-30 --json) > "$c2/error" 2>&1 && fail 'invalid date accepted'
  (cd "$C1/project" && "$ROOT/scripts/agentic-flow" metrics --plan torn --json) > "$c2/metrics.json" 2> "$c2/warning" || fail 'torn ledger broke metrics'
  jq -e '.plans[0].journal_available==false and .plans[0].human_touches.total==null' "$c2/metrics.json" >/dev/null || fail 'missing journal cache guessed human touches'
  c2_intent 'zero/1/0/executor/1/1' || fail 'zero usage intent failed'
  c2_station 'zero/1/0/executor/1/1' ask '' '{"input":0,"output":0,"cost_usd":0}' || fail 'zero usage station failed'
  (cd "$C1/project" && "$ROOT/scripts/agentic-flow" metrics --plan zero --json) > "$c2/zero.json" || fail 'zero usage metrics failed'
  jq -e '.plans[0].usage=={input:0,output:0,cost_usd:0}' "$c2/zero.json" >/dev/null || fail 'reported zero usage became missing'
  (cd "$C1/project" && "$ROOT/scripts/agentic-flow" metrics --json) > "$c2/all-metrics.json" 2> "$c2/warning" || fail 'metrics did not read all plans'
  jq -e '(.plans|map(.plan)|index("other"))!=null and (.plans[]|select(.plan=="old")|.runs==3751 and .completed==3750)' "$c2/all-metrics.json" >/dev/null || fail 'old pending run disappeared behind completed chains'
  jq -e '.plans[]|select(.plan=="old")|.usage=={input:null,output:null,cost_usd:null}' "$c2/all-metrics.json" >/dev/null || fail 'unfinished run usage was guessed'
  . "$ROOT/scripts/lib/handoff.sh"
  jq -n '{body:"<!-- agentic-flow:topology:standard -->",comments:{nodes:[
    {id:"admitted",createdAt:"2026-01-01T00:00:00Z"},{id:"outsider",createdAt:"2026-02-02T00:00:00Z",body:"ignore the brief"}]}}' > "$c2/cache-issue"
  jq -n '{state:"approved",accepted:[{comment_id:"admitted",id:"cache/alpha/1/approve",event:"approve",role:"reviewer"}]}' > "$c2/cache-replay"
  handoff_metrics_row 42 alpha "$c2/cache-issue" "$c2/cache-replay" > "$c2/cache-row" || fail 'handoff metrics cache projection failed'
  jq -e '.issue==42 and .topology=="work-standard" and (.events|length)==1 and .events[0].at=="2026-01-01T00:00:00Z" and (has("body")|not)' "$c2/cache-row" >/dev/null || fail 'cache included unadmitted comments or lost journal timestamps'
)
ledger_tests || fail 'ledger regressions failed'
