#!/usr/bin/env bash
# One cache key and freshness predicate for verifier, controller and packet.

verify_record_digest() {
  local directory digest
  directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || return 1
  digest=$(cat "$directory/verify-step.sh" "$directory/verify-record.sh" | shasum -a 256) || return 1
  printf '%s\n' "${digest%% *}"
}

verify_record_plan() { # selected step JSON (or empty for check-only)
  if [ -n "$1" ]; then
    printf '%s' "$1" | jq -c '{green:(["make check"]+[.packet.verification|split("\n")[0]|scan("`([^`]+)`")|.[0]]),red_first:(if (.red_first|type)=="array" then .red_first else [] end)}'
  else printf '%s\n' '{"green":["make check"],"red_first":[]}'; fi
}

verify_record_key() { # sha, doc, step, red base, command plan; no worktrees or recipes
  local sha=$1 doc=$2 step=$3 base=$4 plan=$5 tree source source_tree blob version tools digest commands_hash
  tree=$(git rev-parse "$sha^{tree}") || return 1
  source=$(git rev-parse HEAD) || return 1
  source_tree=$(git rev-parse "$source^{tree}") || return 1
  blob=$(git rev-parse "$source:Makefile") || return 1
  version=$(git show "$sha:.agentic-flow-version" 2>/dev/null) || version=unknown
  tools=$(jq -n --arg bash "$BASH_VERSION" --arg git "$(git --version)" --arg make "$(make --version | head -1)" --arg jq "$(jq --version)" '{bash:$bash,git:$git,make:$make,jq:$jq}') || return 1
  digest=$(verify_record_digest) || return 1
  commands_hash=$(printf '%s' "$plan" | shasum -a 256) || return 1
  jq -n --arg sha "$sha" --arg tree "$tree" --arg doc "$doc" --arg step "$step" --arg base "$base" \
    --arg version "$version" --argjson tools "$tools" --arg impl "$digest" --arg source "$source" --arg source_tree "$source_tree" \
    --arg blob "$blob" --arg commands "${commands_hash%% *}" --argjson plan "$plan" --argjson timeout "${AGENTIC_VERIFY_TIMEOUT:-1800}" \
    '{v:1,sha:$sha,tree:$tree,doc:$doc,step:$step,red_base:$base,harness_version:$version,tools:$tools,
      commands_sha256:$commands,command_plan:$plan,verifier:{implementation_sha256:$impl,timeout_seconds:$timeout,
      signature_source:{sha:$source,tree:$source_tree,makefile_blob:$blob}}}'
}

verify_record_fresh() { # record path, expected key; stdout is the bounded record
  local file=$1 key=$2 record size
  [ -f "$file" ] && [ -r "$file" ] || return 1
  size=$(wc -c < "$file") || return 1
  [ "$size" -le 262144 ] || return 1
  # Bound the read too, including a concurrently replaced/growing record.
  record=$(head -c 262145 "$file") || return 1
  size=$(printf '%s' "$record" | wc -c) || return 1
  [ "$size" -le 262144 ] || return 1
  printf '%s' "$record" | jq -se --argjson key "$key" '
    length==1 and (.[0] | . as $r |
    all($key|to_entries[]; if .key=="verifier" then
      .value as $v | $r.verifier.implementation_sha256==$v.implementation_sha256 and
      $r.verifier.timeout_seconds==$v.timeout_seconds and
      ($r.verifier.signature_source as $s | all($v.signature_source|to_entries[]; $s[.key]==.value))
      else $r[.key]==.value end) and
    (.verifier.signature_source.pattern|type)=="string" and .passed==true and
    (.commands|type)=="array" and (.commands|length)>0 and
    (.prepare.role=="prepare" and .prepare.exit==0) and
    all(.commands[]; (.exit|type)=="number" and
      if .role=="green" or .role=="prepare" then .exit==0
      elif .role=="red-first" then .exit!=0 and .exit!=124 and .exit!=130 and .exit!=143
      else false end) and
    ([.commands[]|select(.role=="green")|.cmd]==.command_plan.green) and
    ([.commands[]|select(.role=="red-first")|{selector:.cmd,exit:.exit}]==
      (if (.red_first|type)=="array" then [.red_first[]|{selector,exit}] else [] end)) and
    (if (.red_first|type)=="array" then
      all(.red_first[];.status=="red" and (.exit|type)=="number" and .exit!=0) and
      [.red_first[]|{selector,paths}]==.command_plan.red_first
      else .red_first=="not-declared" and .command_plan.red_first==[] end))
  ' >/dev/null 2>&1 || return 1
  printf '%s\n' "$record"
}
