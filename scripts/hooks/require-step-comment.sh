#!/usr/bin/env bash
# PreToolUse: workflow writes go through handoff. Kept at the installed hook path
# so existing Claude/Codex wiring and trust hashes have one migration to review.
# shellcheck disable=SC2329,SC1091
set -uo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/../lib/hook-command.sh"
. "$(dirname "$0")/../lib/workflow.sh"
. "$(dirname "$0")/../lib/review-policy.sh"
HOOK_ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
workflow_load "$HOOK_ROOT" || exit 2
WORKFLOW_LABELS=$(workflow_labels)
block_handoff() {
  echo 'Blocked: use agentic-flow handoff <issue> <event> --as <role>; workflow state and role tokens belong to handoff.' >&2
  return 2
}
check_handoff_write() {
  local i=0 j word operation='' number='' endpoint='' method='' opaque=false payload='' repo=''
  local -a read_args
  if [ "$HOOK_KIND" = cd ]; then HANDOFF_HOOK_CWD_CHANGED=true; return 0; fi
  # Literal examples passed to data commands are not executable invocations.
  case "${HOOK_WORDS[0]:-}" in echo|printf|rg|grep|sed|jq|cat) return 0 ;; esac
  for ((i=0;i<${#HOOK_WORDS[@]};i++)); do
    word=${HOOK_WORDS[i]}
    if [ "${word##*/}" = agentic-flow ]; then
      case "${HOOK_WORDS[i+1]:-}:${HOOK_WORDS[i+2]:-}" in
        token:*|ship:*|roles:set|roles:unset|roles:manual|approve:*|hold:clear) block_handoff; return 2 ;;
        uninstall:*) echo 'Blocked: the human uninstalls.' >&2; return 2 ;;
      esac
      if [ "${HOOK_WORDS[i+1]:-}" = handoff ] && [ "${HOOK_WORDS[i+3]:-}" = hold-clear ]; then block_handoff; return 2; fi
    fi
    case "${word##*/}" in
      bash|sh|zsh)
        case "${HOOK_WORDS[i+1]:-}" in
          -c|-lc|-ic)
            local nested=${HOOK_WORDS[i+2]:-} depth=${HANDOFF_HOOK_DEPTH:-0} nested_status=0
            [ "$depth" -lt 4 ] || { block_handoff; return 2; }
            ( HANDOFF_HOOK_DEPTH=$((depth+1)) hook_walk "$nested" check_handoff_write ) || nested_status=$?
            if [ "$nested_status" -eq 1 ]; then
              nested_status=0
              ( HANDOFF_HOOK_DEPTH=$((depth+1)) hook_walk "$nested" check_handoff_write fallback ) || nested_status=$?
            fi
            [ "$nested_status" -ne 1 ] || { block_handoff; return 2; }
            return "$nested_status" ;;
        esac ;;
    esac
    [ "${word##*/}" = gh ] || continue
    j=$((i+1))
    while [ "$j" -lt "${#HOOK_WORDS[@]}" ]; do
      case "${HOOK_WORDS[j]}" in
        -R|--repo|--hostname) repo=${HOOK_WORDS[j+1]:-}; j=$((j+2)) ;;
        -R?*) repo=${HOOK_WORDS[j]#-R}; j=$((j+1)) ;;
        --repo=*) repo=${HOOK_WORDS[j]#--repo=}; j=$((j+1)) ;;
        *) break ;;
      esac
    done
    if [ "${HOOK_WORDS[j]:-}" = issue ]; then
      operation=${HOOK_WORDS[j+1]:-}
      case "$operation" in
        edit)
          for ((j=j+2;j<${#HOOK_WORDS[@]};j++)); do
            word=${HOOK_WORDS[j]}
            case "$word" in
              --add-label|--remove-label|--add-label=*|--remove-label=*)
                local labels=${word#*=} label
                [ "$labels" != "$word" ] || labels=${HOOK_WORDS[j+1]:-}
                labels=$(printf '%s' "$labels" | tr -d '[:space:]')
                while IFS= read -r label; do
                  case ",$labels," in *",$label,"*) block_handoff; return 2 ;; esac
                done <<< "$WORKFLOW_LABELS"
                # Expansion is opaque to the lexer; fail closed for label writes.
                case "$labels" in *'$'*|*'`'*) block_handoff; return 2 ;; esac ;;
            esac
          done ;;
        close|reopen)
          # The lexer does not execute cd. An unknown read context fails closed.
          [ "${HANDOFF_HOOK_CWD_CHANGED:-false}" = false ] || { block_handoff; return 2; }
          for ((j=j+2;j<${#HOOK_WORDS[@]};j++)); do
            word=${HOOK_WORDS[j]}
            case "$word" in
              -R|--repo) repo=${HOOK_WORDS[j+1]:-}; j=$((j+1)) ;;
              --repo=*) repo=${word#*=} ;;
              [0-9]*|https://github.com/*/issues/*) number=$word ;;
            esac
          done
          [ -n "$number" ] || { block_handoff; return 2; }
          read_args=(issue view "$number" --json body --jq .body)
          [ -z "$repo" ] || read_args+=(--repo "$repo")
          payload=$(review_bounded gh "${read_args[@]}" 2>/dev/null) || { block_handoff; return 2; }
          if [[ "$payload" = *'agentic-flow:plan:'* ]]; then block_handoff; return 2; fi ;;
      esac
    elif [ "${HOOK_WORDS[j]:-}" = api ]; then
      for ((j=j+1;j<${#HOOK_WORDS[@]};j++)); do
        word=${HOOK_WORDS[j]}
        case "$word" in
          -X|--method) method=${HOOK_WORDS[j+1]:-}; j=$((j+1)) ;;
          -X?*) method=${word#-X} ;;
          --method=*) method=${word#--method=} ;;
          --input|--input=*) opaque=true ;;
          -f|-F|--field|--raw-field) [ -n "$method" ] || method=POST ;;
          *repos/*/issues*|graphql|/graphql) endpoint=$word ;;
        esac
        payload="$payload $word"
      done
      case "$method" in GET|HEAD) continue ;; esac
      case "$endpoint" in
        */issues*)
          if [ "$opaque" = true ]; then block_handoff; return 2; fi
          local label
          while IFS= read -r label; do
            case "$payload" in *"$label"*) block_handoff; return 2 ;; esac
          done <<< "$WORKFLOW_LABELS"
          case "$payload:$method" in *state=closed*|*state=open*|*state_reason=*|*/labels*:DELETE) block_handoff; return 2 ;; esac ;;
        *graphql*)
          [ "$opaque" = false ] || { block_handoff; return 2; }
          case "$payload" in *mutation*) block_handoff; return 2 ;; esac ;;
      esac
    fi
  done
  return 0
}
raw=$(head -c 65537)
if ! hook_read_command "$raw"; then
  # Without a trustworthy decode, never authorize an apparent GitHub mutation.
  if [[ "$raw" = *gh* || "$raw" = *agentic-flow* ]]; then block_handoff; exit 2; fi
  exit 0
fi
status=0
hook_walk "$HOOK_COMMAND" check_handoff_write || status=$?
if [ "$status" -eq 1 ]; then
  # Run the permissive lexer only to identify protected operations, never execute.
  status=0
  hook_walk "$HOOK_COMMAND" check_handoff_write fallback || status=$?
  [ "$status" -ne 1 ] || { block_handoff; exit 2; }
fi
exit "$status"
