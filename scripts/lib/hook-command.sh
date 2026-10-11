#!/usr/bin/env bash
# Bounded, non-evaluating lexer for Bash tool commands. This recognizes simple
# command boundaries and Git invocation context; it never executes input text.
# shellcheck disable=SC2034

# This is the canonical wrapper list. Role contracts refer here rather than
# maintaining another list that can drift from hook enforcement.
GIT_COMMAND_WRAPPERS='git git-claude git-codex git-opencode'
hook_is_git_wrapper() {
  case " $GIT_COMMAND_WRAPPERS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

hook_read_command() {
  local raw="$1" value='' tail char escaped=0 i slash=$'\\'
  HOOK_COMMAND=''
  [ "${#raw}" -le 65536 ] || return 1
  if command -v jq >/dev/null 2>&1; then
    HOOK_COMMAND=$(printf '%s' "$raw" | jq -er '.tool_input.command | strings' 2>/dev/null) || return 1
    return 0
  fi
  # Minimal JSON string decoder for the documented tool_input.command shape.
  # Unknown escapes fail closed; silently scanning raw JSON misclassifies prose.
  [[ "$raw" =~ \"command\"[[:space:]]*:[[:space:]]*\" ]] || return 1
  tail=${raw#*"${BASH_REMATCH[0]}"}
  for ((i=0; i<${#tail}; i++)); do
    char=${tail:i:1}
    if [ "$escaped" -eq 1 ]; then
      case "$char" in
        '"'|"$slash"|'/') value+="$char" ;;
        n) value+=$'\n' ;;
        r) value+=$'\r' ;;
        t) value+=$'\t' ;;
        *) return 1 ;;
      esac
      escaped=0
    elif [ "$char" = "$slash" ]; then
      escaped=1
    elif [ "$char" = '"' ]; then
      HOOK_COMMAND=$value
      return 0
    else
      value+="$char"
    fi
  done
  return 1
}

# Parse a literal heredoc delimiter using shell quote removal, without evaluation.
# Bodies are consumed in declaration order at the next newline, not at the <<.
hook_heredoc() {
  local input="$1" i="$2" c quote='' delimiter='' quoted=0 tabs=0 slash=$'\\'
  i=$((i+2))
  if [ "${input:i:1}" = '-' ]; then tabs=1; i=$((i+1)); fi
  while [[ "${input:i:1}" = ' ' || "${input:i:1}" = $'\t' ]]; do i=$((i+1)); done
  while [ "$i" -lt "${#input}" ]; do
    c=${input:i:1}
    if [ "$quote" = "'" ]; then
      if [ "$c" = "'" ]; then quote=''; else delimiter+="$c"; fi
    elif [ "$c" = "$slash" ]; then
      quoted=1; i=$((i+1))
      [ "$i" -lt "${#input}" ] || return 1
      c=${input:i:1}
      if [ "$quote" = '"' ] && [[ "$c" != '$' && "$c" != '`' && "$c" != '"' && "$c" != "$slash" ]]; then
        delimiter+="$slash"
      fi
      delimiter+="$c"
    elif [ "$quote" = '"' ]; then
      if [ "$c" = '"' ]; then quote=''; else delimiter+="$c"; fi
    else
      case "$c" in
        "'"|'"') quote=$c; quoted=1 ;;
        ' '|$'\t'|$'\r'|$'\n'|';'|'&'|'|'|'('|')'|'<'|'>') break ;;
        *) delimiter+="$c" ;;
      esac
    fi
    i=$((i+1))
  done
  [ -z "$quote" ] && [ "$quoted" -eq 1 ] || return 1
  HOOK_HEREDOC_DELIMITERS+=("$delimiter")
  HOOK_HEREDOC_TABS+=("$tabs")
  HOOK_LEX_I=$((i-1))
}

hook_lex() {
  local input="$1" mode="${2:-strict}" i=0 c quote='' word='' active=0 count=0 slash=$'\\'
  local h line start found
  HOOK_TOKENS=()
  HOOK_KINDS=()
  HOOK_HEREDOC_DELIMITERS=()
  HOOK_HEREDOC_TABS=()
  HOOK_ERROR=''
  [ "${#input}" -le 16384 ] || { HOOK_ERROR='command exceeds parser bound'; return 1; }
  while [ "$i" -lt "${#input}" ]; do
    c=${input:i:1}
    if [ "$quote" = "'" ]; then
      if [ "$c" = "'" ]; then
        quote=''
      elif [ "$mode" = fallback ] && [[ "$c" = '$' || "$c" = '`' ]]; then
        # Literal substitution markers must not become executable-looking
        # words in the fallback operation detector after quote removal.
        word+='?'
      else word+="$c"; fi
    elif [ "$quote" = '"' ]; then
      case "$c" in
        '"') quote='' ;;
        '$')
          [ "$mode" = fallback ] || [ "${input:i+1:1}" != '(' ] \
            || { HOOK_ERROR='command substitution is not supported'; return 1; }
          word+="$c" ;;
        '`')
          [ "$mode" = fallback ] || { HOOK_ERROR='command substitution is not supported'; return 1; }
          word+="$c" ;;
        "$slash")
          [ "$i" -lt "$((${#input}-1))" ] || { HOOK_ERROR='trailing escape'; return 1; }
          i=$((i+1))
          [ "${input:i:1}" = $'\n' ] || word+="${input:i:1}" ;;
        *) word+="$c" ;;
      esac
    else
      case "$c" in
        "'"|'"') quote=$c; active=1 ;;
        '$')
          [ "$mode" = fallback ] || [ "${input:i+1:1}" != '(' ] \
            || { HOOK_ERROR='command substitution is not supported'; return 1; }
          word+="$c"; active=1 ;;
        '`')
          [ "$mode" = fallback ] || { HOOK_ERROR='command substitution is not supported'; return 1; }
          if [ "$active" -eq 1 ]; then HOOK_TOKENS+=("$word"); HOOK_KINDS+=(word); word=''; active=0; fi
          HOOK_TOKENS+=("$c"); HOOK_KINDS+=(separator) ;;
        "$slash")
          [ "$i" -lt "$((${#input}-1))" ] || { HOOK_ERROR='trailing escape'; return 1; }
          i=$((i+1))
          if [ "${input:i:1}" != $'\n' ]; then
            word+="${input:i:1}"; active=1
          fi ;;
        ' '|$'\t'|$'\r')
          if [ "$active" -eq 1 ]; then HOOK_TOKENS+=("$word"); HOOK_KINDS+=(word); word=''; active=0; fi ;;
        '<')
          if [ "${input:i+1:1}" = '<' ]; then
            if [ "$active" -eq 1 ]; then HOOK_TOKENS+=("$word"); HOOK_KINDS+=(word); word=''; active=0; fi
            hook_heredoc "$input" "$i" || { HOOK_ERROR='unsupported heredoc delimiter'; return 1; }
            i=$HOOK_LEX_I
          else word+="$c"; active=1; fi ;;
        ';'|'&'|'|'|'('|')'|$'\n')
          if [ "$active" -eq 1 ]; then HOOK_TOKENS+=("$word"); HOOK_KINDS+=(word); word=''; active=0; fi
          HOOK_TOKENS+=("$c"); HOOK_KINDS+=(separator)
          if [ "$c" = $'\n' ]; then
            for ((h=0; h<${#HOOK_HEREDOC_DELIMITERS[@]}; h++)); do
              found=0
              while [ "$i" -lt "$((${#input}-1))" ]; do
                i=$((i+1)); start=$i
                while [ "$i" -lt "${#input}" ] && [ "${input:i:1}" != $'\n' ]; do i=$((i+1)); done
                line=${input:start:i-start}
                if [ "${HOOK_HEREDOC_TABS[h]}" -eq 1 ]; then
                  while [ "${line:0:1}" = $'\t' ]; do line=${line:1}; done
                fi
                if [ "$line" = "${HOOK_HEREDOC_DELIMITERS[h]}" ]; then found=1; break; fi
              done
              [ "$found" -eq 1 ] || { HOOK_ERROR='unterminated heredoc'; return 1; }
            done
            HOOK_HEREDOC_DELIMITERS=(); HOOK_HEREDOC_TABS=()
          fi ;;
        '#')
          if [ "$active" -eq 0 ]; then
            while [ "$i" -lt "${#input}" ] && [ "${input:i:1}" != $'\n' ]; do i=$((i+1)); done
            # Let the newline branch consume any pending heredoc bodies.
            i=$((i-1))
          else word+="$c"; fi ;;
        *) word+="$c"; active=1 ;;
      esac
    fi
    i=$((i+1))
    count=$((count+1))
    [ "$count" -le 16384 ] || { HOOK_ERROR='command exceeds parser bound'; return 1; }
    [ "${#HOOK_TOKENS[@]}" -le 512 ] || { HOOK_ERROR='too many command words'; return 1; }
  done
  [ -z "$quote" ] || { HOOK_ERROR='unterminated quote'; return 1; }
  [ "${#HOOK_HEREDOC_DELIMITERS[@]}" -eq 0 ] || { HOOK_ERROR='unterminated heredoc'; return 1; }
  if [ "$active" -eq 1 ]; then HOOK_TOKENS+=("$word"); HOOK_KINDS+=(word); fi
}

hook_is_assignment() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; }

# An executable prefix we do not model may change user, environment, or
# working directory. Identify a protected suffix without pretending we know
# its execution context. Callbacks block only their own protected operation.
hook_find_unmodeled_suffix() {
  local j k option p
  for ((j=1; j<${#HOOK_WORDS[@]}; j++)); do
    # These commands consume later words as data, including a literal
    # "git push" written without quotes. Keep prose searches usable even
    # when a simple execution prefix precedes the data command.
    for ((p=0; p<j; p++)); do
      case "${HOOK_WORDS[p]}" in
        echo|printf|rg|grep|egrep|fgrep|man|cat|sed|awk) return 0 ;;
      esac
    done
    if hook_is_git_wrapper "${HOOK_WORDS[j]}"; then
      k=$((j+1))
      while [ "$k" -lt "${#HOOK_WORDS[@]}" ]; do
        option=${HOOK_WORDS[k]}
        case "$option" in
          -C|-c|--git-dir|--work-tree|--namespace|--config-env) k=$((k+2)) ;;
          -C?*|-c?*|--git-dir=*|--work-tree=*|--namespace=*|--config-env=*|-p|--no-pager|--bare|--no-replace-objects)
            k=$((k+1)) ;;
          *) break ;;
        esac
      done
      case "${HOOK_WORDS[k]:-}" in
        push|commit|add)
          HOOK_KIND=ambiguous_git
          HOOK_VERB=${HOOK_WORDS[k]}
          HOOK_VERB_INDEX=$k
          return 0 ;;
      esac
    elif [ "${HOOK_WORDS[j]}" = gh ]; then
      k=$((j+1))
      while [ "$k" -lt "${#HOOK_WORDS[@]}" ]; do
        option=${HOOK_WORDS[k]}
        case "$option" in
          -R|--repo|--hostname) k=$((k+2)) ;;
          -R?*|--repo=*|--hostname=*) k=$((k+1)) ;;
          *) break ;;
        esac
      done
      if [ "${HOOK_WORDS[k]:-}" = pr ] && [ "${HOOK_WORDS[k+1]:-}" = merge ]; then
        HOOK_KIND=ambiguous_gh
        HOOK_VERB='pr'
        HOOK_VERB_INDEX=$k
        return 0
      fi
    fi
  done
}

# Callback receives globals HOOK_KIND, HOOK_WORDS, HOOK_ENV, HOOK_GIT_ARGS,
# HOOK_VERB, HOOK_VERB_INDEX, HOOK_CWD, HOOK_ERROR. Return 2 to block.
hook_dispatch() {
  local callback="$1" i=0 word option
  [ "${#HOOK_WORDS[@]}" -gt 0 ] || return 0
  HOOK_ENV=(); HOOK_GIT_ARGS=(); HOOK_KIND=''; HOOK_VERB=''; HOOK_VERB_INDEX=0; HOOK_ERROR=''
  while [ "$i" -lt "${#HOOK_WORDS[@]}" ] && hook_is_assignment "${HOOK_WORDS[i]}"; do
    HOOK_ENV+=("${HOOK_WORDS[i]}"); i=$((i+1))
  done
  if [ "${HOOK_WORDS[i]:-}" = env ]; then
    i=$((i+1))
    while [ "$i" -lt "${#HOOK_WORDS[@]}" ]; do
      word=${HOOK_WORDS[i]}
      if hook_is_assignment "$word"; then HOOK_ENV+=("$word"); i=$((i+1)); continue; fi
      case "$word" in
        --) i=$((i+1)); continue ;;
        -i|--ignore-environment) HOOK_ENV+=("$word"); i=$((i+1)); continue ;;
        -u|--unset) HOOK_ENV+=("$word" "${HOOK_WORDS[i+1]:-}"); i=$((i+2)); continue ;;
        -*) HOOK_ERROR='unsupported env option'; i=$((i+1)); continue ;;
      esac
      break
    done
  fi
  case "${HOOK_WORDS[i]:-}" in command|exec) i=$((i+1)) ;; esac
  word=${HOOK_WORDS[i]:-}
  if hook_is_git_wrapper "$word"; then
    HOOK_KIND=git; i=$((i+1))
    while [ "$i" -lt "${#HOOK_WORDS[@]}" ]; do
      option=${HOOK_WORDS[i]}
      case "$option" in
        -C|-c|--git-dir|--work-tree|--namespace|--config-env)
          [ "$((i+1))" -lt "${#HOOK_WORDS[@]}" ] || { HOOK_ERROR='missing Git option argument'; break; }
          HOOK_GIT_ARGS+=("$option" "${HOOK_WORDS[i+1]}"); i=$((i+2)) ;;
        -C?*|-c?*|--git-dir=*|--work-tree=*|--namespace=*|--config-env=*|-p|--no-pager|--bare|--no-replace-objects)
          HOOK_GIT_ARGS+=("$option"); i=$((i+1)) ;;
        -*) HOOK_ERROR='unsupported Git global option'; i=$((i+1)) ;;
        *) HOOK_VERB=$option; HOOK_VERB_INDEX=$i; break ;;
      esac
    done
  elif [ "$word" = gh ]; then
    HOOK_KIND=gh; i=$((i+1))
    while [ "$i" -lt "${#HOOK_WORDS[@]}" ]; do
      option=${HOOK_WORDS[i]}
      case "$option" in
        -R|--repo|--hostname) i=$((i+2)) ;;
        -R?*|--repo=*|--hostname=*) i=$((i+1)) ;;
        *) break ;;
      esac
    done
    HOOK_VERB=${HOOK_WORDS[i]:-}; HOOK_VERB_INDEX=$i
  elif [ "$word" = cd ]; then
    HOOK_KIND='cd'; HOOK_VERB_INDEX=$i
  fi
  [ -n "$HOOK_KIND" ] || hook_find_unmodeled_suffix
  [ -z "$HOOK_ERROR" ] || return 1
  "$callback"
}

hook_walk() { # <command> <callback> [lex mode]
  local input="$1" callback="$2" i
  hook_lex "$input" "${3:-strict}" || return 1
  HOOK_WORDS=()
  HOOK_CWD=$PWD
  for ((i=0; i<${#HOOK_TOKENS[@]}; i++)); do
    if [ "${HOOK_KINDS[i]}" = separator ]; then
      hook_dispatch "$callback" || return $?
      HOOK_WORDS=()
    else
      HOOK_WORDS+=("${HOOK_TOKENS[i]}")
    fi
  done
  hook_dispatch "$callback"
}

hook_fallback_operation() {
  local word
  case "$HOOK_KIND:$HOOK_VERB" in
    git:"$verb"|ambiguous_git:"$verb") return 2 ;;
    gh:pr|ambiguous_gh:pr)
      if [ "$verb" = push ] && [ "${HOOK_WORDS[HOOK_VERB_INDEX+1]:-}" = merge ]; then return 2; fi ;;
  esac
  for word in "${HOOK_WORDS[@]+"${HOOK_WORDS[@]}"}"; do
    # Double-quoted substitutions execute; ordinary quoted prose is data.
    # shellcheck disable=SC2016 # Match literal shell syntax without evaluation.
    if [[ "$word" = *'$('* || "$word" = *'`'* ]]; then
      [[ "$word" =~ $git_pattern || ( "$verb" = push && "$word" =~ $gh_pattern ) ]] && return 2
    fi
  done
  return 0
}

hook_maybe_protected() { # <unparsed command> <protected Git verb> [raw JSON]
  local input="$1" verb="$2" git_pattern gh_pattern status=0 boundary
  # Require a tool and its operation in the same command segment. A quote
  # before the tool is deliberately not a boundary: grep "git push" is data.
  # Parentheses/backticks remain boundaries for real command substitutions.
  boundary="(^|[[:space:];|&()\`])"
  # If JSON decoding failed, its command-opening quote is a tool boundary.
  [ "${3:-}" != raw ] || boundary="(^|[[:space:];|&()\`\"'])"
  git_pattern="$boundary(git|git-[[:alnum:]_-]+)[[:space:]]+([^;|&"$'\n'"]*[[:space:]])?[\"']?($verb)([[:space:]\"';|&()]|$)"
  gh_pattern="${boundary}gh[[:space:]]+([^;|&"$'\n'"]*[[:space:]])?pr[[:space:]]+merge([[:space:]\"';|&()]|$)"
  # A permissive token pass is only an operation detector. It never authorizes
  # a protected invocation or executes substitutions. Preserve the dispatcher's
  # data-command exemptions when an earlier unrelated substitution broke parsing.
  if [ "${3:-}" = raw ]; then status=1; else hook_walk "$input" hook_fallback_operation fallback || status=$?; fi
  case "$status" in 2) return 0 ;; 0) return 1 ;; esac
  # Malformed quotes, expanding heredocs, parser bounds, or unknown options
  # cannot use token context. Keep the bounded operation-specific text check.
  [[ "$input" =~ $git_pattern || ( "$verb" = push && "$input" =~ $gh_pattern ) ]]
}
