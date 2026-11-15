#!/usr/bin/env bash
# Sourced by self-test.sh; no network and no real model invocations.
# shellcheck disable=SC1091,SC2030,SC2031,SC2016,SC2329 # Shared harness helpers and child programs.
[ -f "$ROOT/scripts/lib/launch.sh" ] || fail 'station launcher is missing'
C1="$TMP/controller"
mkdir -p "$C1/project/config" "$C1/bin" "$C1/home/.codex" "$C1/operator"
mkdir -p "$C1/project/config/stations"
ln "$ROOT/config/stations/"* "$C1/project/config/stations/"
ln "$ROOT/config/roles.tsv" "$C1/project/config/roles.tsv"
ln "$ROOT/config/stations/codex.config.toml" "$C1/home/.codex/agentic-station.config.toml"
mkdir -p "$C1/project/.agents/skills/review-execution" "$C1/project/scripts/lib" "$C1/project/docs"
ln "$ROOT/AGENTS.md" "$C1/project/AGENTS.md"
cp "$ROOT/.agents/skills/review-execution/SKILL.md" "$C1/project/.agents/skills/review-execution/SKILL.md"
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
  # The config RPC is headless and never invokes the model fake.
  while IFS= read -r request; do
    case "$request" in *config/read*)
      enabled=true
      case "$*" in *'mcp_servers."fixture".enabled=false'*) enabled=false ;; esac
      printf '{"id":2,"result":{"config":{"approval_policy":"never","sandbox_mode":"workspace-write","web_search":"disabled","sandbox_workspace_write":{"network_access":false},"mcp_servers":{"fixture":{"enabled":%s}}}}}\n' "$enabled"
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
  timeout) sleep 30 & child=$!; echo "$child" > "$out/child"; wait "$child" ;;
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
  child=$(cat "$C1/observed/child")
  # A killed child can briefly remain a zombie; it must not remain running.
  state=$(ps -o stat= -p "$child" 2>/dev/null || true)
  case "$state" in ''|*Z*) ;; *) fail 'timeout left a live descendant' ;; esac
  rm "$C1/behavior"
  roles_cmd set executor codex --timeout-s 12 --scope project >/dev/null 2>&1 || fail 'Codex resume assignment failed'
  launch_session_record() { printf '%s\n' "$1" > "$C1/session-record"; }
  LAUNCH_RESUME_CLI=codex LAUNCH_RESUME_PROFILE=config/stations/codex.config.toml launch_station executor "$C1/project" "$C1/packet with spaces.md" "$C1/result" --resume codex-session > "$C1/launch.json" || fail 'compatible resume failed'
  grep -Fxq codex-session "$C1/session-record" || fail 'Codex session callback missing'
  grep -Fxq resume "$C1/observed/argv" || fail 'compatible resume not passed'
  grep -Fxq 'mcp_servers."fixture".enabled=false' "$C1/observed/argv" || fail 'configured Codex connector was not disabled'
  grep -Fxq -- --output-schema "$C1/observed/argv" || fail 'resume schema not passed'
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
  cp "$ROOT/config/roles.tsv" "$source/config/roles.tsv"
  cp "$ROOT/scripts/lib/payload-apply.sh" "$source/scripts/lib/"
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
  cp "$source/config/payload.tsv" "$target/config/"
  cp "$ROOT/scripts/lib/payload-apply.sh" "$target/scripts/lib/"
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
