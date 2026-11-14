#!/usr/bin/env bash
# Operator-only identities; keys and issued credentials stay in memory.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/review-policy.sh"

identity_repository() { # project root; only github.com repository origins
  local origin
  origin=$(git -C "$1" config --get remote.origin.url) || return 1
  case "$origin" in
    git@github.com:*) origin=${origin#git@github.com:} ;;
    https://github.com/*) origin=${origin#https://github.com/} ;;
    ssh://git@github.com/*) origin=${origin#ssh://git@github.com/} ;;
    *) return 1 ;;
  esac
  origin=${origin%.git}
  [[ "$origin" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 1
  printf '%s\n' "$origin"
}

identity_config_path() {
  local repo
  repo=$(identity_repository "$1") || return 1
  printf '%s/agentic-flow/identities/%s.tsv\n' "${XDG_CONFIG_HOME:-$HOME/.config}" "$repo"
}

identity_load() { # root role; 6 means absent, 5 means invalid configured identity
  local root=$1 role=$2 file parsed
  IDENTITY_LOGIN='' IDENTITY_APP='' IDENTITY_INSTALLATION='' IDENTITY_KEY_REF=''
  file=$(identity_config_path "$root") || { echo 'identity: cannot resolve repository origin' >&2; return 5; }
  [ -f "$file" ] || { echo "no identity: $role" >&2; return 6; }
  [ "$(wc -c < "$file")" -le 16384 ] || { echo "$file:1: identity config too large" >&2; return 5; }
  parsed=$(awk -F '\t' '
    function bad(message) { print FILENAME ":" NR ": " message > "/dev/stderr"; exit 1 }
    NR>32 { bad("too many identity rows") }
    /^#/ || /^$/ { next }
    { if (NF != 5) bad("expected five tab-separated fields")
      if ($1 !~ /^(executor|reviewer|approver)$/ || seen[$1]++) bad("unknown or duplicate role")
      if ($2 !~ /^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])$/) bad("expected App login")
      if ($3 !~ /^[1-9][0-9]*$/ || $4 !~ /^[1-9][0-9]*$/) bad("invalid App or installation id")
      if ($5 !~ /^[A-Za-z0-9][A-Za-z0-9 ._:\/-]*$/) bad("invalid key-ref")
      print
    }
  ' "$file") || return 5
  read_review_policy "$root" || return 5
  local row_role login app installation key_ref roles
  while IFS=$'\t' read -r row_role login app installation key_ref; do
    [ -n "$row_role" ] || continue
    review_valid_login "$login" || { echo "$file: invalid App login" >&2; return 5; }
    case "$row_role" in executor) roles=$REVIEW_EXECUTORS ;; reviewer) roles=$REVIEW_REVIEWERS ;; approver) roles=$REVIEW_APPROVERS ;; esac
    case "$roles" in *" $login "*) ;; *) echo "identity: $row_role login is not in policy" >&2; return 5 ;; esac
    if [ "$row_role" = "$role" ]; then
      IDENTITY_LOGIN=$login IDENTITY_APP=$app IDENTITY_INSTALLATION=$installation IDENTITY_KEY_REF=$key_ref
    fi
  done <<< "$parsed"
  [ -n "$IDENTITY_LOGIN" ] || { echo "no identity: $role" >&2; return 6; }
}

identity_token() ( # root role [--check]; subshell keeps secrets and trace state local
  set +x
  set -o pipefail
  local root=$1 role=$2 check=${3:-} repo key now header claims signing signature jwt request response
  case "$role" in executor|reviewer|approver) ;; *) echo 'identity: unknown role' >&2; return 2 ;; esac
  [ -z "$check" ] || [ "$check" = --check ] || return 2
  identity_load "$root" "$role" || return $?
  repo=$(identity_repository "$root") || return 5
  case "$(uname -s)" in
    Darwin) key=$(review_bounded security find-generic-password -s "$IDENTITY_KEY_REF" -w 2>/dev/null) || { echo 'identity: keychain lookup failed' >&2; return 5; } ;;
    Linux) key=$(review_bounded secret-tool lookup service agentic-flow key-ref "$IDENTITY_KEY_REF" 2>/dev/null) || { echo 'identity: keychain lookup failed' >&2; return 5; } ;;
    *) echo 'identity: unsupported keychain platform' >&2; return 5 ;;
  esac
  [ -n "$key" ] || { echo 'identity: empty signing key' >&2; return 5; }
  [ "${#key}" -le 16384 ] || { echo 'identity: signing key too large' >&2; return 5; }
  # macOS security's interactive command protocol accepts a single-line value.
  # Support base64-wrapped PEM there, as well as raw PEM from either keychain.
  case "$key" in
    '-----BEGIN '*) ;;
    *) key=$(printf '%s' "$key" | openssl base64 -d -A 2>/dev/null) || {
      echo 'identity: invalid signing key encoding' >&2; return 5;
    } ;;
  esac
  now=$(date +%s)
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=') || return 5
  claims=$(jq -nc --arg iss "$IDENTITY_APP" --argjson now "$now" '{iss:$iss,iat:($now-60),exp:($now+540)}' | openssl base64 -A | tr '+/' '-_' | tr -d '=') || return 5
  signing="$header.$claims"
  signature=$(printf '%s' "$signing" | review_bounded openssl dgst -sha256 -sign <(printf '%s\n' "$key") 2>/dev/null | openssl base64 -A | tr '+/' '-_' | tr -d '=') || { echo 'identity: signing failed' >&2; return 5; }
  unset key
  jwt="$signing.$signature"
  request=$(jq -nc --arg repo "${repo#*/}" '{repositories:[$repo],permissions:{issues:"write",pull_requests:"write",contents:"read",metadata:"read"}}') || return 5
  # curl config on stdin keeps the JWT out of argv. Disable user curl config,
  # redirects and retries; a failed mint must never use ambient gh credentials.
  response=$(printf 'header = "Authorization: Bearer %s"\n' "$jwt" |
    curl --disable --config - --silent --fail --max-time 20 --connect-timeout 10 \
      --max-filesize 65536 --request POST --header 'Accept: application/vnd.github+json' \
      --header 'Content-Type: application/json' --header 'X-GitHub-Api-Version: 2022-11-28' \
      --data-binary "$request" "https://api.github.com/app/installations/$IDENTITY_INSTALLATION/access_tokens" 2>/dev/null) || {
        echo 'identity: token mint failed' >&2; return 5;
      }
  unset jwt
  [ "${#response}" -le 65536 ] || { echo 'identity: oversized token response' >&2; return 5; }
  # Enforce least privilege on every mint, including the check-only command.
  printf '%s' "$response" | jq -e --arg repo "$repo" '
    (.token | type == "string" and length > 0 and (test("[\\r\\n]") | not)) and
    (.expires_at | fromdateiso8601) > now and
    .permissions == {issues:"write",pull_requests:"write",contents:"read",metadata:"read"} and
    (.repositories | type == "array" and length == 1) and
    (.repositories[0].full_name | ascii_downcase) == ($repo | ascii_downcase)
  ' >/dev/null 2>&1 || { echo 'identity: invalid token response or scope' >&2; return 5; }
  [ "$check" != --check ] || return 0
  printf '%s' "$response" | jq -r '.token'
)
