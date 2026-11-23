#!/usr/bin/env bash
# Render the canonical command policy while retaining unrelated adopter settings.
set -euo pipefail

ROOT=${AGENTIC_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
LIB=$(cd "$(dirname "$0")/lib" && pwd -P)
# shellcheck source=scripts/lib/command-policy.sh
. "$LIB/command-policy.sh"

mode=${1:-write}
case "$#:$mode" in 0:write|1:--check) ;; *) echo 'usage: render-command-policy.sh [--check]' >&2; exit 2 ;; esac
command_policy_load "$ROOT/config/command-policy.tsv"
old_prefixes='[]'
rules_file="$ROOT/config/stations/command-policy.rules"
if [ -f "$rules_file" ] && [ "$(wc -c < "$rules_file")" -le 200000 ]; then
  snapshot=$(sed -n '2s/^# Policy prefixes: //p' "$rules_file")
  if [ -n "$snapshot" ] && jq -e 'type=="array" and length<=256 and
    all(.[]; type=="string" and length<=200 and test("^[a-zA-Z0-9_./-][a-zA-Z0-9_.~/:* =-]*$"))' \
    <<< "$snapshot" >/dev/null 2>&1 &&
    COMMAND_POLICY_PREFIXES="$snapshot" command_policy_codex | cmp -s "$rules_file" -; then
    old_prefixes=$snapshot
  fi
fi

scopes='claude opencode'
if [ -f "$ROOT/.agentic-flow-installation" ]; then
  # shellcheck source=scripts/lib/payload-apply.sh
  . "$LIB/payload-apply.sh"
  payload_resolve_installation "$ROOT" "$ROOT/config/payload.tsv"
  scopes=$PAYLOAD_ACTIVE_SCOPES
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/agentic-command-policy.XXXXXX")
temp=''
trap 'rm -rf "$scratch"; [ -z "$temp" ] || rm -f "$temp"' EXIT
failed=0
save() { # relative path; scratch/rendered contains the new bytes
  local path="$ROOT/$1"
  if cmp -s "$scratch/rendered" "$path"; then return 0; fi
  if [ "$mode" = --check ]; then
    printf 'command policy differs in %s; run scripts/render-command-policy.sh\n' "$1" >&2
    failed=1
    return 0
  fi
  temp=$(mktemp "$path.XXXXXX")
  cat "$scratch/rendered" > "$temp"
  mv -f "$temp" "$path"
  temp=''
}

render_claude() {
  jq --argjson rules "$claude" --argjson retired "$retired_claude" '
    .permissions.deny |= reduce $rules[] as $rule ((. // []) - $retired;
      if index($rule)==null then .+[$rule] else . end)' "$ROOT/$1" > "$scratch/rendered"
  save "$1"
}

render_agent() {
  # Rewrite only the managed region of the YAML frontmatter. The initial scalar
  # default becomes a catch-all so its original behavior survives the mapping.
  awk -v rules="$scratch/bash" '
    function emit(    line) {
      print "    # BEGIN AGENTIC-FLOW COMMAND POLICY"
      while ((getline line < rules)>0) print line
      close(rules)
      print "    # END AGENTIC-FLOW COMMAND POLICY"
      emitted=1
    }
    NR==1 && $0=="---" {front=1; print; next}
    front && /^    # BEGIN AGENTIC-FLOW COMMAND POLICY$/ {old=1; next}
    front && old {
      if ($0=="    # END AGENTIC-FLOW COMMAND POLICY") old=0
      next
    }
    front && /^  bash:([[:space:]]|$)/ {
      if (bash++) exit 2
      if ($0 ~ /^  bash: (allow|ask|deny)$/) {
        print "  bash:"
        print "    \"*\": " $2
      } else if ($0=="  bash:") print
      else exit 2
      mapping=1
      next
    }
    front && mapping && /^[^ ]|^  [^ ]/ {emit(); mapping=0}
    front && /^permission:[[:space:]]*$/ {permission=1}
    front && $0=="---" {
      if (!bash) {
        if (permission) exit 2
        print "permission:"
        print "  bash:"
        emit()
      }
      front=0
    }
    {print}
    END {if (old || front || !emitted) exit 2}
  ' "$ROOT/$1" > "$scratch/rendered" || { printf 'command policy cannot merge bash permissions in %s\n' "$1" >&2; return 2; }
  save "$1"
}

claude=$(command_policy_claude)
opencode=$(command_policy_opencode)
old_claude=$(COMMAND_POLICY_PREFIXES="$old_prefixes" command_policy_claude)
old_opencode=$(COMMAND_POLICY_PREFIXES="$old_prefixes" command_policy_opencode)
retired_claude=$(jq -cn --argjson old "$old_claude" --argjson new "$claude" '$old-$new')
retired_opencode=$(jq -cn --argjson old "$old_opencode" --argjson new "$opencode" '$old-$new')
render_claude config/stations/claude.settings.json
jq --argjson rules "$opencode" --argjson retired "$retired_opencode" '
  .permissions |= reduce $rules[] as $rule ((. // []) - $retired;
    map(select(.action!=$rule.action or .resource!=$rule.resource)) + [$rule])' \
  "$ROOT/config/stations/opencode.json" > "$scratch/rendered"
save config/stations/opencode.json
command_policy_codex > "$scratch/rendered"
save config/stations/command-policy.rules

case " $scopes " in *" claude "*) render_claude .claude/settings.json ;; esac
case " $scopes " in *" opencode "*)
  jq -nr --argjson rules "$opencode" '$rules[] | "    " + (.resource|tojson) + ": deny"' > "$scratch/bash"
  for agent in "$ROOT"/.opencode/agent/*.md; do
    [ -f "$agent" ] || { echo 'command policy: missing OpenCode agent files' >&2; exit 2; }
    render_agent "${agent#"$ROOT/"}"
  done ;;
esac
exit "$failed"
