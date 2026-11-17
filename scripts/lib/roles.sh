#!/usr/bin/env bash
# Layered, whole-row station assignments. Source from the CLI or launch library.
roles_error() { printf 'roles: %s\n' "$*" >&2; return 2; }

roles_validate() { # root file; absent override files are empty layers
  local root=$1 file=$2 row station cli model effort turns budget seconds profile n=0 seen=' '
  [ -f "$file" ] || return 0
  [ "$(wc -c < "$file")" -le 65536 ] || { roles_error "$file: file exceeds 64 KiB"; return 2; }
  while IFS= read -r row || [ -n "$row" ]; do
    n=$((n+1))
    case "$row" in ''|'#'*) continue ;; esac
    # read collapses empty TSV fields; reject them before splitting.
    if ! printf '%s\n' "$row" | awk -F '\t' 'NF!=8 {exit 1} {for(i=1;i<=NF;i++) if($i=="") exit 1}'; then
      roles_error "$file:$n: expected eight nonempty tab-separated fields"; return 2
    fi
    IFS=$(printf '\t') read -r station cli model effort turns budget seconds profile <<< "$row"
    case "$station" in executor|reviewer) ;; *) roles_error "$file:$n: unknown station $station"; return 2 ;; esac
    case "$seen" in *" $station "*) roles_error "$file:$n: duplicate station $station"; return 2 ;; esac
    seen="$seen$station "
    case "$cli" in claude|codex|opencode|manual) ;; *) roles_error "$file:$n: unknown CLI $cli"; return 2 ;; esac
    if ! printf '%s\n' "$turns" | LC_ALL=C grep -Eq '^(-|[1-9][0-9]{0,5})$' \
      || ! printf '%s\n' "$budget" | LC_ALL=C grep -Eq '^(-|[0-9]{1,6}(\.[0-9]{1,6})?)$' \
      || ! printf '%s\n' "$seconds" | LC_ALL=C grep -Eq '^(-|[1-9][0-9]{0,5})$'; then
      roles_error "$file:$n: invalid numeric max-turns, budget-usd or timeout-s"; return 2
    fi
    case "$profile" in /*|..|../*|*/../*|*/..|-) roles_error "$file:$n: profile must be a project-relative file"; return 2 ;; esac
    [ -f "$root/$profile" ] || { roles_error "$file:$n: missing profile $profile"; return 2; }
  done < "$file"
}

roles_operator_path() { # root; never consult an arbitrary URL as a path
  local url owner repo
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || { roles_error 'origin remote is required for the operator layer'; return 2; }
  url=${url%.git}
  case "$url" in https://github.com/*) url=${url#https://github.com/} ;; git@github.com:*) url=${url#git@github.com:} ;;
    *) roles_error 'origin must name a github.com owner/repository'; return 2 ;; esac
  owner=${url%%/*}; repo=${url#*/}
  printf '%s\n' "$owner/$repo" | LC_ALL=C grep -Eq '^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$' \
    || { roles_error 'invalid origin owner/repository'; return 2; }
  case "$repo" in .|..) roles_error 'invalid origin repository'; return 2 ;; esac
  printf '%s/agentic-flow/roles/%s/%s.tsv\n' "${XDG_CONFIG_HOME:-$HOME/.config}" "$owner" "$repo"
}

roles_load() { # root [include-operator=true]; JSON in ROLES_JSON
  local root=$1 operator=${2:-true} file layer rows
  [ -f "$root/config/roles.tsv" ] || { roles_error 'missing config/roles.tsv'; return 2; }
  ROLES_JSON='[]'
  for layer in harness project operator; do
    case "$layer" in harness) file="$root/config/roles.tsv" ;; project) file="$root/.agentic-flow-roles" ;;
      operator) [ "$operator" = true ] || continue; file=$(roles_operator_path "$root") || return 2 ;; esac
    roles_validate "$root" "$file" || return 2
    [ -f "$file" ] || continue
    rows=$(jq -Rn --arg layer "$layer" '[inputs | select(length>0 and (startswith("#")|not)) | split("\t") |
      {station:.[0],cli:.[1],model:.[2],effort:.[3],max_turns:.[4],budget_usd:.[5],timeout_s:.[6],profile:.[7],layer:$layer}]' < "$file") || return 2
    ROLES_JSON=$(jq -cn --argjson old "$ROLES_JSON" --argjson new "$rows" '$old + $new | group_by(.station) | map(last)') || return 2
  done
  [ "$(printf '%s' "$ROLES_JSON" | jq length)" = 2 ] || { roles_error 'executor and reviewer defaults are required'; return 2; }
}

roles_same_model() { # root; preflight for the pair, independent of per-station preflight
  local root=$1 a b am bm
  a=$(printf '%s' "$ROLES_JSON" | jq -r '.[]|select(.station=="executor")|.cli')
  b=$(printf '%s' "$ROLES_JSON" | jq -r '.[]|select(.station=="reviewer")|.cli')
  [ "$a" != manual ] && [ "$b" != manual ] && [ "$a" = "$b" ] || return 0
  am=$(printf '%s' "$ROLES_JSON" | jq -r '.[]|select(.station=="executor")|.model')
  bm=$(printf '%s' "$ROLES_JSON" | jq -r '.[]|select(.station=="reviewer")|.model')
  if [ "$am" != "$bm" ]; then echo 'warning: same CLI, different models; diversity depends on the configured models' >&2; return 0; fi
  roles_risk_accepted "$root" same-model-review || { echo 'preflight: same-model-review accepted risk is required' >&2; return 6; }
  echo 'warning: accepted risk same-model-review' >&2
}

roles_risk_accepted() { # root anchor; status must belong to this entry
  [ -f "$1/docs/accepted_risks.md" ] || return 1
  # Pass only the id: escape processing in -v values differs between awks
  # (GNU awk did not turn \" into a quote, so the anchor never matched on Linux).
  awk -v id="$2" '
    BEGIN {anchor="<a id=\"" id "\"></a>"}
    /^<a id=/ {inside=($0==anchor); headings=0}
    inside && /^## / {headings++; if(headings>1) inside=0}
    inside && $0=="**Status:** Accepted risk" {found=1}
    END {exit !found}' "$1/docs/accepted_risks.md"
}

roles_cmd() {
  local root action=${1:-show} scope=operator station='' cli='' key value row file temp model effort turns budget seconds profile
  root=$(find_root) || root=$(git rev-parse --show-toplevel) || { roles_error 'not inside an agentic-flow project'; return 2; }
  roles_load "$root" || return 2
  case "$action" in show|--json)
    [ "$#" -le 1 ] || { roles_error 'unexpected roles arguments'; return 2; }
    if [ "$action" = --json ]; then printf '%s\n' "$ROLES_JSON"; else
      printf '%s\n' "$ROLES_JSON" | jq -r '.[] | [.station,.cli,.model,.effort,.max_turns,.budget_usd,.timeout_s,.profile,.layer] | @tsv'
    fi; return 0 ;;
    set|unset|manual) shift ;; *) roles_error "unknown action $action"; return 2 ;;
  esac
  [ "$#" -ge 1 ] || { roles_error 'station required'; return 2; }
  station=$1; shift
  case "$station" in executor|reviewer) ;; *) roles_error "unknown station $station"; return 2 ;; esac
  row=$(printf '%s' "$ROLES_JSON" | jq -r --arg s "$station" '.[]|select(.station==$s)|[.cli,.model,.effort,.max_turns,.budget_usd,.timeout_s,.profile]|@tsv')
  IFS=$(printf '\t') read -r cli model effort turns budget seconds profile <<< "$row"
  if [ "$action" = set ]; then
    [ "$#" -ge 1 ] || { roles_error 'CLI required'; return 2; }
    value=$1; shift
    if [ "$value" != "$cli" ]; then
      model=-; effort=-
      case "$value" in claude) profile=config/stations/claude.settings.json ;; codex) profile=config/stations/codex.config.toml ;;
        opencode|manual) profile=config/stations/opencode.json ;; *) roles_error "unknown CLI $value"; return 2 ;; esac
    fi
    cli=$value
  elif [ "$action" = manual ]; then cli=manual; fi
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || { roles_error "missing value for $1"; return 2; }
    key=$1; value=$2; shift 2
    # TSV cannot represent embedded separators or line breaks.
    case "$value" in *$'\t'*|*$'\n'*|*$'\r'*|'') roles_error "invalid $key value"; return 2 ;; esac
    if [ "$key" = --scope ]; then scope=$value; continue; fi
    [ "$action" = set ] || { roles_error "$key is only valid with set"; return 2; }
    case "$key" in --model) model=$value ;; --effort) effort=$value ;;
      --max-turns) turns=$value ;; --budget-usd) budget=$value ;; --timeout-s) seconds=$value ;;
      --profile) profile=$value ;; *) roles_error "unknown option $key"; return 2 ;; esac
  done
  case "$scope" in project) file="$root/.agentic-flow-roles" ;; operator) file=$(roles_operator_path "$root") || return 2 ;;
    *) roles_error 'scope must be operator or project'; return 2 ;; esac
  mkdir -p "$(dirname "$file")" || return 2
  temp=$(mktemp "${file}.XXXXXX") || return 2
  if [ -f "$file" ]; then awk -F '\t' -v s="$station" '$1!=s' "$file" > "$temp"; fi
  if [ "$action" != unset ]; then printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$station" "$cli" "$model" "$effort" "$turns" "$budget" "$seconds" "$profile" >> "$temp"; fi
  if ! roles_validate "$root" "$temp"; then rm -f "$temp"; return 2; fi
  mv "$temp" "$file" || return 2
  [ "$scope" != project ] || git -C "$root" add -- .agentic-flow-roles || return 2
  roles_load "$root" || return 2
  if [ "$action" != unset ]; then
    if [ "$cli" = opencode ] && ! roles_risk_accepted "$root" opencode-station-network; then echo 'roles: opencode-station-network accepted risk required for unattended use' >&2; fi
    roles_same_model "$root" || true
  fi
}
