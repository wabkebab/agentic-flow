#!/usr/bin/env bash
# Activate replacement guards before retiring the legacy registrations.

# shellcheck source=scripts/lib/git-guards.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-guards.sh"

install_interactive_rules() { # <project root>
  local root="$1" rules_dir="${CODEX_HOME:-$HOME/.codex}/rules" temporary
  mkdir -p "$rules_dir" || return 1
  temporary=$(mktemp "$rules_dir/.agentic-flow.XXXXXX") || return 1
  if ! { cat "$root/config/stations/command-policy.rules" > "$temporary" &&
    mv -f "$temporary" "$rules_dir/agentic-flow.rules"; }; then
    rm -f "$temporary"
    return 1
  fi
}

render_retired_hooks() { # <adapter> <remove scanner?> <live configuration>
  local cli="$1" scan="$2" file="$3" prefix
  # shellcheck disable=SC2016 # Literal command prefixes from the adapter JSON.
  case "$cli" in
    claude) prefix='"$CLAUDE_PROJECT_DIR"/' ;;
    codex) prefix='"$(git rev-parse --show-toplevel)"/' ;;
  esac
  jq -e --arg cli "$cli" --arg prefix "$prefix" --argjson scan "$scan" '
    def matches($entry; $script):
      ("scripts/hooks/" + $script + ".sh") as $path |
      ($entry.type == "command" and
        ($entry.command == ($prefix + $path) or
         $entry.command == $path or $entry.command == ("./" + $path)));
    if type != "object" then error("invalid hook configuration") else . end |
    if .hooks.PreToolUse == null then . else
      .hooks.PreToolUse |= map(
        . as $group |
        .hooks |= map(. as $entry | select(
          (matches($entry; "block-git-add-all") or matches($entry; "block-push") or
           matches($entry; "require-step-comment") or ($scan and matches($entry; "scan-secrets"))) | not)) |
        select(.hooks != [] or $group.hooks == []))
    end |
    if $cli == "codex" then
      if any(.hooks.PreToolUse[]?; .matcher == "Bash" and
        any(.hooks[]?; matches(.; "guard-attached-git-dir"))) then . else
        .hooks.PreToolUse += [{matcher:"Bash", hooks:[{type:"command",
          command:($prefix + "scripts/hooks/guard-attached-git-dir.sh"), timeout:10}]}]
      end
    elif .hooks.PreToolUse == [] then del(.hooks.PreToolUse) else . end
  ' "$file"
}

migrate_guards() ( # <fetched root> <project root> <active scopes>
  local release="$1" project="$2" scopes="$3" scan=false cli file tmp i
  local -a adapters=()
  guard_migration_temps=()
  trap 'rm -f -- "${guard_migration_temps[@]+"${guard_migration_temps[@]}"}"' EXIT
  for cli in claude codex; do
    payload_has_word "$cli" "$scopes" && adapters+=("$cli")
  done
  if ! {
    # Validate both adapters before changing either. The renderer's --check
    # also checks OpenCode agents and the policy installed for stations.
    cli=''
    for cli in "${adapters[@]+"${adapters[@]}"}"; do
      case "$cli" in claude) file=.claude/settings.json ;; codex) file=.codex/hooks.json ;; esac
      render_retired_hooks "$cli" false "$project/$file" >/dev/null || break
      cli=''
    done
    [ -z "$cli" ] &&
      cmp -s "$release/config/command-policy.tsv" "$project/config/command-policy.tsv" &&
      AGENTIC_PROJECT_ROOT="$project" "$release/scripts/render-command-policy.sh" &&
      { ! payload_has_word codex "$scopes" || install_interactive_rules "$project"; } &&
      AGENTIC_PROJECT_ROOT="$project" "$release/scripts/render-command-policy.sh" --check
  }; then
    echo 'pending: command policy not active' >&2
    return 1
  fi
  if git_guard_enable "$project" && git_guard_probe "$project"; then
    scan=true
  else
    echo 'pending: the active pre-commit hook did not prove staged-secret scanning' >&2
  fi
  for cli in "${adapters[@]+"${adapters[@]}"}"; do
    case "$cli" in claude) file=.claude/settings.json ;; codex) file=.codex/hooks.json ;; esac
    tmp=$(mktemp "$project/$file.XXXXXX") || return 1
    guard_migration_temps+=("$tmp")
    render_retired_hooks "$cli" "$scan" "$project/$file" > "$tmp" || return 1
  done
  i=0
  for cli in "${adapters[@]+"${adapters[@]}"}"; do
    case "$cli" in claude) file=.claude/settings.json ;; codex) file=.codex/hooks.json ;; esac
    tmp=${guard_migration_temps[i]}
    i=$((i + 1))
    if ! cmp -s "$tmp" "$project/$file"; then
      mv -f "$tmp" "$project/$file" || return 1
    fi
  done
  [ "$scan" = true ]
)
