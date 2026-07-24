#!/usr/bin/env bash
# lifecycle-status.sh — derive whether active implementation docs are eligible to close.
#
# Usage:
#   scripts/lifecycle-status.sh                    report ACTIVE / READY / BLOCKED
#   scripts/lifecycle-status.sh --check            fail when an all-checked tracker is BLOCKED
#   scripts/lifecycle-status.sh --verify-evidence  query GitHub Actions run evidence when possible
set -euo pipefail

ROOT=${AGENTIC_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
STRICT=false
VERIFY_EVIDENCE=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) STRICT=true ;;
    --verify-evidence) VERIFY_EVIDENCE=true ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

# A field's FULL value: its "- **Label:**" line plus any continuation lines, up to the next
# bullet or a blank line. A single grep on the label's own line (the old approach) made a
# value that wraps onto a second line invisible to the check — issue #19.
field_block() { # <doc> <exact label text, e.g. "Approval">
  awk -v label="$2" '
    grabbing && /^- / { exit }
    grabbing && /^[[:space:]]*$/ { exit }
    grabbing { print; next }
    $0 ~ ("^- \\*\\*" label ":\\*\\*") { print; grabbing = 1 }
  ' "$1"
}

# Every "- **Label:**" bullet actually present in the doc, one label per line — used to
# tell "the field is genuinely absent" apart from "the field is there under a name that
# doesn't match the schema" (the #19 bug: a doc recording "Approved:" and one recording
# nothing at all produced byte-identical "missing: approval" output).
present_labels() { # <doc>
  grep -oE '^- \*\*[^*]+:\*\*' "$1" | sed -E 's/^- \*\*//; s/:\*\*$//'
}

# True when candidate label $2 looks like a near-miss spelling of canonical label $1 — same
# first 5 lowercase characters, but not an exact case-insensitive match. This only decides
# whether to report "unrecognized" instead of "missing" (so the message points at real data
# instead of asking someone to add a field that already exists under the wrong name). It
# deliberately does NOT make the candidate satisfy the check — the schema stays
# single-valued, per the issue's own note against loosening the match.
looks_like_near_miss() { # <canonical> <candidate>
  local a b
  a=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  b=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  [ "$a" = "$b" ] && return 1
  [ "${a:0:5}" = "${b:0:5}" ]
}

# Evaluate one Status field, appending its field-id to $missing (no matching content — the
# label is absent with nothing similar nearby, or present but its content doesn't satisfy
# the pattern) or to $unrecognized (a near-miss label exists under a different name).
check_field() { # <doc> <canonical-label> <field-id> <content-pattern>
  local doc="$1" label="$2" field_id="$3" pattern="$4" block candidate
  block=$(field_block "$doc" "$label")
  if [ -n "$block" ]; then
    printf '%s' "$block" | grep -Eiq "$pattern" || missing="$missing $field_id"
    return
  fi
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if looks_like_near_miss "$label" "$candidate"; then
      unrecognized="$unrecognized $field_id (found \"$candidate:\")"
      return
    fi
  done < <(present_labels "$doc")
  missing="$missing $field_id"
}

verify_evidence() { # <verification-evidence block>
  local block="$1" url owner repo run_id conclusion path_without_host
  url=$(printf '%s\n' "$block" |
    grep -Eo 'https://github\.com/[^/[:space:]]+/[^/[:space:]]+/actions/runs/[0-9]+' |
    head -n 1 || true)
  if [ -z "$url" ]; then
    evidence_status=UNVERIFIED
    evidence_reason="verification evidence is not a GitHub Actions run URL"
    return
  fi

  path_without_host=${url#https://github.com/}
  owner=${path_without_host%%/*}
  path_without_host=${path_without_host#*/}
  repo=${path_without_host%%/*}
  run_id=${url##*/}

  if ! command -v gh >/dev/null 2>&1; then
    evidence_status=UNVERIFIED
    evidence_reason="gh is not available to resolve GitHub Actions evidence"
    return
  fi

  conclusion=$(gh run view "$run_id" --repo "$owner/$repo" --json conclusion --jq .conclusion 2>/dev/null || true)
  if [ -z "$conclusion" ]; then
    evidence_status=UNVERIFIED
    evidence_reason="could not resolve GitHub Actions run $owner/$repo#$run_id"
    return
  fi

  if [ "$conclusion" = success ]; then
    evidence_status=READY
    evidence_reason="GitHub Actions run $owner/$repo#$run_id concluded success"
  else
    evidence_status=BLOCKED
    evidence_reason="GitHub Actions run $owner/$repo#$run_id concluded $conclusion"
  fi
}

blocked=0
found=0
while IFS= read -r doc; do
  tracker_lines=$(grep -Ec '^- \[[ xX]\] ' "$doc" || true)
  [ "$tracker_lines" -gt 0 ] || continue
  found=$((found + 1))
  open=$(grep -Ec '^- \[ \] ' "$doc" || true)
  checked=$(grep -Ec '^- \[[xX]\] ' "$doc" || true)
  rel="${doc#"$ROOT"/}"

  if [ "$open" -gt 0 ]; then
    printf 'ACTIVE  %s  %s/%s tracker items complete\n' "$rel" "$checked" "$tracker_lines"
    continue
  fi

  missing=""
  unrecognized=""
  check_field "$doc" "Approval" approval 'approved|accepted|user approved'
  check_field "$doc" "Tracking issue" tracking-link 'https?://'
  check_field "$doc" "Verification evidence" verification-evidence 'https?://'
  check_field "$doc" "Review verdict" review-verdict 'approved|pass|accepted'

  if [ -z "$missing" ] && [ -z "$unrecognized" ]; then
    if [ "$VERIFY_EVIDENCE" = true ]; then
      evidence_status=""
      evidence_reason=""
      verify_evidence "$(field_block "$doc" "Verification evidence")"
      case "$evidence_status" in
        READY)
          printf 'READY   %s  %s\n' "$rel" "$evidence_reason"
          ;;
        BLOCKED)
          printf 'BLOCKED %s  %s\n' "$rel" "$evidence_reason"
          blocked=$((blocked + 1))
          ;;
        UNVERIFIED)
          printf 'UNVERIFIED %s  %s\n' "$rel" "$evidence_reason"
          ;;
      esac
    else
      printf 'READY   %s  eligible to move to done/\n' "$rel"
    fi
  else
    printf 'BLOCKED %s  all tracker items checked;' "$rel"
    [ -z "$missing" ] || printf ' missing:%s' "$missing"
    [ -z "$unrecognized" ] || printf ' unrecognized:%s' "$unrecognized"
    printf '\n'
    blocked=$((blocked + 1))
  fi
done < <(find "$ROOT/docs/inprogress" -type f -name '*.md' | sort)

[ "$found" -gt 0 ] || echo "No active implementation trackers found."
if [ "$STRICT" = true ] && [ "$blocked" -gt 0 ]; then
  exit 1
fi
