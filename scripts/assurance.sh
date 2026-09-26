#!/usr/bin/env bash
# Project-owned assurance baseline. This script is installed with the core harness.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
if [ "${1:-}" = --check-for-root ]; then
  [ "$#" -eq 2 ] || { echo 'error: --check-for-root requires a directory' >&2; exit 2; }
  ROOT="$2"
  set -- --check
fi
STATE="$ROOT/.agentic-flow-assurance"
AUDIT="$ROOT/.agentic-flow-assurance-audit"

die() { printf 'error: %s\n' "$*" >&2; exit 2; }
usage() {
  cat <<'EOF'
usage: scripts/assurance.sh status | --check
       scripts/assurance.sh set <quick|standard|strict> [--approved-by <identity> --reason <text>]

Missing state means standard (legacy default). Downgrades require a human identity
and reason; the recorded claim is not machine authentication of approval.
EOF
}
rank() {
  case "$1" in quick) echo 1 ;; standard) echo 2 ;; strict) echo 3 ;; *) return 1 ;; esac
}
read_state() {
  local value lines
  [ ! -L "$STATE" ] || die "assurance state must be a regular file"
  [ -e "$STATE" ] || { printf 'standard\n'; return; }
  [ -f "$STATE" ] && [ ! -L "$STATE" ] || die "assurance state must be a regular file"
  [ "$(wc -c < "$STATE" | tr -d ' ')" -le 16 ] || die "assurance state is malformed"
  lines=$(wc -l < "$STATE" | tr -d ' ')
  [ "$lines" -eq 1 ] || die "assurance state must have one newline-terminated line"
  value=$(cat "$STATE")
  rank "$value" >/dev/null || die "unknown assurance state: $value"
  [ "$(printf '%s\n' "$value" | wc -c | tr -d ' ')" -eq "$(wc -c < "$STATE" | tr -d ' ')" ] \
    || die "assurance state is malformed"
  printf '%s\n' "$value"
}
check_audit() {
  local line="" count old new
  [ ! -L "$AUDIT" ] || die "assurance audit must be a regular file"
  [ -e "$AUDIT" ] || return 0
  [ -f "$AUDIT" ] && [ ! -L "$AUDIT" ] || die "assurance audit must be a regular file"
  count=$(wc -l < "$AUDIT" | tr -d ' ')
  [ "$count" -le 1000 ] || die "assurance audit exceeds 1000 records; archive it with human review"
  [ "$(wc -c < "$AUDIT" | tr -d ' ')" -le 1048576 ] || die "assurance audit is too large"
  while IFS= read -r line; do
    # ISO UTC time, old/new tiers, identity, and reason are tab-separated.
    [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'\t'[^[:space:]]+$'\t'[^[:space:]]+$'\t'[A-Za-z0-9._@-]+$'\t'[^[:cntrl:]]+$ ]] \
      || die "malformed assurance audit record"
    IFS=$'\t' read -r _ old new _ <<< "$line"
    rank "$old" >/dev/null && rank "$new" >/dev/null \
      && [ "$(rank "$new")" -lt "$(rank "$old")" ] \
      || die "assurance audit has an invalid downgrade"
  done < "$AUDIT"
  [ -z "$line" ] || die "assurance audit must end with newline"
}

[ "$#" -gt 0 ] || { usage; exit 2; }
case "$1" in
  status)
    [ "$#" -eq 1 ] || die "status takes no arguments"
    current=$(read_state)
    check_audit
    if [ -e "$STATE" ]; then echo "$current (state file)"; else echo "$current (legacy default)"; fi
    ;;
  --check)
    [ "$#" -eq 1 ] || die "--check takes no arguments"
    read_state >/dev/null
    check_audit
    ;;
  set)
    [ "$#" -ge 2 ] || die "set requires a tier"
    target="$2"; shift 2
    rank "$target" >/dev/null || die "unknown assurance tier: $target"
    approved_by="" reason=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --approved-by) [ "$#" -ge 2 ] || die "--approved-by requires a value"; approved_by="$2"; shift 2 ;;
        --reason) [ "$#" -ge 2 ] || die "--reason requires a value"; reason="$2"; shift 2 ;;
        *) die "unknown set argument: $1" ;;
      esac
    done
    current=$(read_state)
    check_audit
    if [ -n "$approved_by$reason" ]; then
      [[ "$approved_by" =~ ^[A-Za-z0-9._@-]{1,128}$ ]] || die "invalid approval identity"
      [ -n "$reason" ] && [ "${#reason}" -le 512 ] \
        && [[ ! "$reason" =~ [[:cntrl:]] ]] || die "invalid audit reason"
    fi
    if [ "$(rank "$target")" -ge "$(rank "$current")" ] && [ -n "$approved_by$reason" ]; then
      die "audit attribution is only accepted for a downgrade"
    fi
    if [ "$(rank "$target")" -lt "$(rank "$current")" ]; then
      [ -n "$approved_by" ] && [ -n "$reason" ] \
        || die "lowering assurance requires --approved-by and --reason"
      [ -e "$AUDIT" ] && [ "$(wc -l < "$AUDIT" | tr -d ' ')" -ge 1000 ] \
        && die "assurance audit is full"
      audit_tmp=$(mktemp "$ROOT/.agentic-flow-assurance-audit.XXXXXX")
      trap 'rm -f "${audit_tmp:-}" "${state_tmp:-}"' EXIT
      [ ! -e "$AUDIT" ] || cat "$AUDIT" > "$audit_tmp"
      printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$current" "$target" "$approved_by" "$reason" >> "$audit_tmp"
      mv "$audit_tmp" "$AUDIT"
    fi
    state_tmp=$(mktemp "$ROOT/.agentic-flow-assurance.XXXXXX")
    trap 'rm -f "${audit_tmp:-}" "${state_tmp:-}"' EXIT
    printf '%s\n' "$target" > "$state_tmp"
    mv "$state_tmp" "$STATE"
    echo "$current -> $target"
    ;;
  -h|--help) usage ;;
  *) die "unknown command: $1" ;;
esac
