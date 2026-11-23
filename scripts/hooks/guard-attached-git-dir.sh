#!/usr/bin/env bash
# Codex prefix rules cannot match the variable part of an attached Git option.
# Receive Bash tool JSON and check only the owner-approved residual form.
set -uo pipefail
raw=$(head -c 65537)
[ "${#raw}" -le 65536 ] || exit 2
cmd=$(jq -er '.tool_input.command | strings' <<< "$raw") || exit 2
path='("[^"]+"|'\''[^'\'']+'\''|[^[:space:];|&]+)'
attached='^[[:space:]]*git(-(claude|codex|opencode))?[[:space:]]+--git-dir='${path}'[[:space:]]+'
operation='(push|add[[:space:]]+(--[[:space:]]+)?(-A|--all|\.|:/))([[:space:];|&)"}]|$)'
if [[ "$cmd" =~ ${attached}${operation} ]]; then
  echo 'Blocked: do not push or stage all files through an attached --git-dir option.' >&2
  exit 2
fi
