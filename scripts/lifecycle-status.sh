#!/usr/bin/env bash
# lifecycle-status.sh — report or verify implementation-document close-out state.
# Usage: scripts/lifecycle-status.sh [--check] [--verify-evidence]
#        [--doc <exact-path>] [--phase close-out|pre-merge]
#        [--doc <exact-path>] --validate-doc-status
set -euo pipefail

ROOT=${AGENTIC_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
STRICT=false
VERIFY_EVIDENCE=false
VALIDATE_DOC_STATUS=false
DOC=""
PHASE=close-out
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) STRICT=true ;;
    --verify-evidence) VERIFY_EVIDENCE=true ;;
    --validate-doc-status) VALIDATE_DOC_STATUS=true ;;
    --doc)
      [ "$#" -ge 2 ] || { echo 'error: --doc needs a path' >&2; exit 2; }
      DOC=$2; shift ;;
    --phase)
      [ "$#" -ge 2 ] || { echo 'error: --phase needs a value' >&2; exit 2; }
      PHASE=$2; shift ;;
    -h|--help) awk 'NR==1 {next} /^#/ {print; next} {exit}' "$0"; exit 0 ;;
    *) echo "error: unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$PHASE" in close-out|pre-merge) ;; *) echo "error: unknown phase: $PHASE" >&2; exit 2 ;; esac
[ -z "$DOC" ] || [ -f "$DOC" ] || { echo "error: --doc file not found: $DOC" >&2; exit 2; }

# Parse exactly one Status block. Fields cannot wrap or repeat, and only the eight
# declared keys are allowed. The tab-delimited result is internal and never evaluated.
status_fields() { # <doc>
  awk '
    /^## Status([[:space:]]|$)/ { if (status_seen++) { print "ERROR\tduplicate Status block"; exit }; in_status=1; next }
    in_status && /^#{1,2} / { in_status=0 }
    !in_status { next }
    /^- \*\*[^*]+:\*\*/ {
      line=$0
      sub(/^- \*\*/, "", line)
      split(line, parts, ":\\*\\*")
      key=parts[1]
      value=substr(line, length(key)+5)
      sub(/^[[:space:]]*/, "", value)
      if (key != "Evidence schema" && key != "Tracking issue" && key != "Approval" &&
          key != "Implementation head" && key != "Implementation PR" &&
          key != "Verification evidence" && key != "Review verdict" && key != "Memory") {
        print "ERROR\tunknown field " key; exit
      }
      if (seen[key]++) { print "ERROR\tduplicate field " key; exit }
      if (length(value) > 4096 || value ~ /\t/) { print "ERROR\tmalformed field " key; exit }
      print key "\t" value
      last_key=key
      next
    }
    last_key && /^[[:space:]]+[^[:space:]]/ {
      print "ERROR\tmalformed continuation of " last_key; exit
    }
    /^[[:space:]]*$/ { last_key="" }
    /^- / { last_key="" }
  ' "$1"
}

valid_value() { # <key> <value>
  case "$1" in
    'Evidence schema') [ "$2" = v2 ] ;;
    'Tracking issue') [[ "$2" =~ ^url=https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*$ ]] ;;
    Approval) [[ "$2" =~ ^status=approved\;\ by=[A-Za-z0-9]([A-Za-z0-9._\ -]*[A-Za-z0-9])?\;\ at=[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$ ]] ;;
    'Implementation head') [ "$2" = source=pr-head ] ;;
    'Implementation PR') [[ "$2" =~ ^url=https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*$ ]] ;;
    'Verification evidence') [ "$2" = source=final-approval-run ] ;;
    'Review verdict') [ "$2" = source=pr-head-approval ] ;;
    Memory) [ "$2" = status=n/a ] || [[ "$2" =~ ^path=docs/memory/[A-Za-z0-9._-]+\.md$ ]] ;;
  esac
}

# Local writer pre-flight uses the same parser as lifecycle reports. Pending is
# valid while work is active, but no undeclared value can be written through.
if [ "$VALIDATE_DOC_STATUS" = true ]; then
  [ -n "$DOC" ] || { echo 'error: --validate-doc-status requires --doc' >&2; exit 2; }
  parsed=$(status_fields "$DOC")
  if printf '%s\n' "$parsed" | grep -q '^ERROR'; then
    printf '%s\n' "$parsed" | grep '^ERROR' >&2
    exit 1
  fi
  for key in 'Evidence schema' 'Tracking issue' Approval 'Implementation head' \
             'Implementation PR' 'Verification evidence' 'Review verdict' Memory; do
    value=$(printf '%s\n' "$parsed" | awk -F '\t' -v k="$key" '$1 == k { print $2 }')
    [ -n "$value" ] || { echo "error: missing $key" >&2; exit 1; }
    if [ "$key" != 'Evidence schema' ] && [ "$value" = pending ]; then continue; fi
    valid_value "$key" "$value" || { echo "error: invalid $key" >&2; exit 1; }
  done
  exit 0
fi

blocked=0
unverified=0
legacy=0
found=0
check_doc() { # <doc>
  local doc=$1 rel tracker_lines open checked parsed key value field_id schema="" tracking="" missing="" invalid="" \
    parser_error="" state_json issue_state labels
  tracker_lines=$(grep -Ec '^- \[[ xX]\] ' "$doc" || true)
  [ "$tracker_lines" -gt 0 ] || return 0
  found=$((found + 1))
  open=$(grep -Ec '^- \[ \] ' "$doc" || true)
  checked=$((tracker_lines - open))
  rel=${doc#"$ROOT"/}
  if [ "$open" -gt 0 ]; then
    printf 'ACTIVE  %s  %s/%s tracker items complete\n' "$rel" "$checked" "$tracker_lines"
    return
  fi
  parsed=$(status_fields "$doc")
  while IFS="$(printf '\t')" read -r key value; do
    [ -n "$key" ] || continue
    if [ "$key" = ERROR ]; then parser_error=$value; break; fi
    case "$key" in
      'Evidence schema') schema=$value ;;
      'Tracking issue') tracking=${value#url=} ;;
    esac
  done <<< "$parsed"
  if [ -n "$parser_error" ]; then
    printf 'BLOCKED %s  %s\n' "$rel" "$parser_error"
    blocked=$((blocked + 1)); return
  fi
  if [ -z "$schema" ]; then
    printf 'LEGACY  %s  migrate Status using the v2 Feature/Security template\n' "$rel"
    legacy=$((legacy + 1)); return
  fi
  if [ "$schema" != v2 ]; then
    printf 'BLOCKED %s  invalid Evidence schema\n' "$rel"
    blocked=$((blocked + 1)); return
  fi
  for key in 'Evidence schema' 'Tracking issue' Approval 'Implementation head' \
             'Implementation PR' 'Verification evidence' 'Review verdict' Memory; do
    field_id=$(printf '%s' "$key" | tr '[:upper:] ' '[:lower:]-')
    value=$(printf '%s\n' "$parsed" | awk -F '\t' -v k="$key" '$1 == k { print $2 }')
    if [ -z "$value" ] || [ "$value" = pending ]; then
      missing="$missing $field_id"; continue
    fi
    if ! valid_value "$key" "$value"; then invalid="$invalid $field_id"; fi
  done
  if [ -n "$invalid" ]; then
    printf 'BLOCKED %s  invalid:%s\n' "$rel" "$invalid"
    blocked=$((blocked + 1)); return
  fi
  if [ -n "$missing" ]; then
    printf 'UNVERIFIED %s  missing:%s\n' "$rel" "$missing"
    unverified=$((unverified + 1)); return
  fi
  if [ "$VERIFY_EVIDENCE" = false ]; then
    printf 'READY   %s  local v2 Status valid; external evidence unresolved\n' "$rel"
    return
  fi
  if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    printf 'UNVERIFIED %s  gh or jq unavailable for issue evidence\n' "$rel"
    unverified=$((unverified + 1)); return
  fi
  state_json=$(gh issue view "$tracking" --json state,labels 2>/dev/null) || state_json=""
  if ! printf '%s' "$state_json" | jq -e '(.state == "OPEN" or .state == "CLOSED") and (.labels | type == "array")' >/dev/null 2>&1; then
    printf 'UNVERIFIED %s  could not resolve tracking issue state\n' "$rel"
    unverified=$((unverified + 1)); return
  fi
  issue_state=$(printf '%s' "$state_json" | jq -r .state)
  labels=$(printf '%s' "$state_json" | jq -r '[.labels[].name] | join(",")')
  case "$PHASE:$issue_state:$labels" in
    close-out:OPEN:*)
      case ",$labels," in *,needs-closing,*) ;; *)
        printf 'BLOCKED %s  phase close-out found OPEN without needs-closing\n' "$rel"
        blocked=$((blocked + 1)); return ;; esac
      case ",$labels," in *,agent:claude,*) ;; *)
        printf 'BLOCKED %s  phase close-out found OPEN without agent:claude\n' "$rel"
        blocked=$((blocked + 1)); return ;; esac ;;
    pre-merge:CLOSED:*) ;;
    *) printf 'BLOCKED %s  phase %s found %s tracking issue\n' "$rel" "$PHASE" "$issue_state"
       blocked=$((blocked + 1)); return ;;
  esac
  printf 'UNVERIFIED %s  final review and CI evidence unresolved\n' "$rel"
  unverified=$((unverified + 1))
}

if [ -n "$DOC" ]; then
  check_doc "$DOC"
else
  while IFS= read -r doc; do check_doc "$doc"; done < <(find "$ROOT/docs/inprogress" -type f -name '*.md' | sort)
fi
[ "$found" -gt 0 ] || echo 'No active implementation trackers found.'
if [ "$STRICT" = true ] && [ "$blocked" -gt 0 ]; then exit 1; fi
if [ "$STRICT" = true ] && [ "$VERIFY_EVIDENCE" = true ] && [ "$((unverified + legacy))" -gt 0 ]; then exit 1; fi
