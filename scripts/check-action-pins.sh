#!/usr/bin/env bash
# check-action-pins.sh — keep GitHub Actions pins honest.
#
# Usage:
#   scripts/check-action-pins.sh            offline: structure (fatal) + staleness (warn)
#   scripts/check-action-pins.sh --strict   offline, but staleness is fatal too
#   scripts/check-action-pins.sh --online   also resolve pins against GitHub (needs gh + network)
#   scripts/check-action-pins.sh --stamp    rewrite the verification date to today
#
# Scans .github/workflows/*.yml and templates/ci/*.yml.
#
# Two failure modes, deliberately graded differently:
#
#   STRUCTURE (always fatal) — a `uses:` must be pinned to a full 40-char commit SHA and
#   carry a `# vX.Y.Z` comment. A tag is mutable: whoever controls it controls what runs in
#   CI with your secrets. A SHA without the comment is unreadable, so it never gets updated.
#
#   STALENESS (warning; fatal only under --strict) — pins decay with the calendar, not with
#   edits. Failing the fast gate on age would turn a repo red with no change to it, and
#   since the Stop hook runs `make check`, would block agents from ending turns over the
#   date. So the fast gate nags; a scheduled --strict run is what enforces.
set -euo pipefail

ROOT=${AGENTIC_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
STAMP_LABEL="Action pins verified:"
MAX_AGE_DAYS=${ACTION_PIN_MAX_AGE_DAYS:-180}

STRICT=false
ONLINE=false
STAMP=false
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=true ;;
    --online) ONLINE=true ;;
    --stamp)  STAMP=true ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/action-pins.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/errors"
: > "$TMP/warnings"

err()  { echo "  ✗ $*" >> "$TMP/errors"; }
warn() { echo "  ! $*" >> "$TMP/warnings"; }

today=$(date -u +%Y-%m-%d)

# Workflow files to scan. Bash 3.2: no mapfile, and a non-matching glob must not be
# mistaken for a filename.
: > "$TMP/files"
for dir in "$ROOT/.github/workflows" "$ROOT/templates/ci"; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*.yml "$dir"/*.yaml; do
    [ -f "$f" ] && printf '%s\n' "$f" >> "$TMP/files"
  done
done

if [ ! -s "$TMP/files" ]; then
  echo "No workflow files found (.github/workflows, templates/ci) — nothing to check."
  exit 0
fi

HAVE_PYTHON=false
command -v python3 >/dev/null 2>&1 && HAVE_PYTHON=true

# Days between an ISO date and today. macOS ships BSD date, which can't do this portably.
days_since() { # <YYYY-MM-DD> -> integer, or empty if unparseable
  python3 - "$1" <<'PY' 2>/dev/null || true
import datetime, sys
try:
    d = datetime.date.fromisoformat(sys.argv[1])
except ValueError:
    sys.exit(1)
print((datetime.date.today() - d).days)
PY
}

# Emit "lineno<TAB>action<TAB>comment" for every non-local `uses:` in a file.
# The `|| true` matters: a workflow with no `uses:` at all is legal (all `run:` steps),
# and under `set -o pipefail` grep's exit 1 would otherwise abort the whole script.
uses_lines() { # <file>
  { grep -nE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[^[:space:]]' "$1" 2>/dev/null || true; } \
  | while IFS= read -r hit; do
      lineno="${hit%%:*}"
      spec=$(printf '%s' "$hit" | sed -E 's/^[0-9]+:[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*//')
      action=$(printf '%s' "$spec" | awk '{print $1}')
      comment=$(printf '%s' "$spec" | sed -n 's/.*#[[:space:]]*//p')
      case "$action" in ./*|.\\*) continue ;; esac   # local actions are exempt
      printf '%s\t%s\t%s\n' "$lineno" "$action" "$comment"
    done
}

# --- --stamp: refresh the verification date and exit --------------------------
if [ "$STAMP" = true ]; then
  while IFS= read -r f; do
    if grep -q "$STAMP_LABEL" "$f"; then
      # BSD and GNU sed disagree on -i, so write through a temp file.
      sed "s/${STAMP_LABEL} [0-9-]*/${STAMP_LABEL} ${today}/" "$f" > "$TMP/stamped" \
        && cat "$TMP/stamped" > "$f"
      echo "  stamped ${f#"$ROOT"/} → $today"
    else
      echo "  ! ${f#"$ROOT"/} has no '$STAMP_LABEL <date>' line to stamp" >&2
    fi
  done < "$TMP/files"
  exit 0
fi

echo "Checking action pins in:"
sed "s|^$ROOT/|  |" "$TMP/files"

# --- offline: structure + staleness ------------------------------------------
while IFS= read -r file; do
  rel="${file#"$ROOT"/}"

  uses_lines "$file" > "$TMP/uses"
  while IFS="$(printf '\t')" read -r lineno action comment; do
    [ -n "${action:-}" ] || continue
    ref="${action##*@}"
    name="${action%@*}"

    if [ "$ref" = "$action" ]; then
      err "$rel:$lineno  $action is unpinned (no @ref at all)"
    elif ! printf '%s' "$ref" | grep -qE '^[0-9a-f]{40}$'; then
      err "$rel:$lineno  $name is pinned to '$ref', not a 40-char commit SHA — a tag can be re-pointed"
    elif ! printf '%s' "$comment" | grep -qE '^v?[0-9]+\.'; then
      err "$rel:$lineno  $name pin has no '# vX.Y.Z' comment — nobody can tell what version it is"
    fi
  done < "$TMP/uses"

  stamp=$(sed -n "s/.*${STAMP_LABEL}[[:space:]]*\([0-9][0-9-]*\).*/\1/p" "$file" | head -1)
  if [ -z "$stamp" ]; then
    warn "$rel has no '# $STAMP_LABEL <YYYY-MM-DD>' line — pin freshness is unverifiable"
  elif [ "$HAVE_PYTHON" = false ]; then
    warn "$rel: python3 not found, cannot age-check the '$stamp' stamp"
  else
    age=$(days_since "$stamp")
    if [ -z "$age" ]; then
      warn "$rel has an unparseable verification date: '$stamp'"
    elif [ "$age" -gt "$MAX_AGE_DAYS" ]; then
      warn "$rel pins last verified $stamp ($age days ago, limit $MAX_AGE_DAYS) — re-check, then --stamp"
    fi
  fi
done < "$TMP/files"

# --- online: does the pin point where the comment claims? ---------------------
# Offline proves a pin is well-formed. Only this proves it is the version it says it is,
# and whether a newer release exists.
if [ "$ONLINE" = true ]; then
  if ! command -v gh >/dev/null 2>&1; then
    warn "gh not found — online verification skipped"
  else
    while IFS= read -r file; do
      rel="${file#"$ROOT"/}"
      uses_lines "$file" > "$TMP/uses"
      while IFS="$(printf '\t')" read -r lineno action comment; do
        [ -n "${action:-}" ] || continue
        ref="${action##*@}"
        printf '%s' "$ref" | grep -qE '^[0-9a-f]{40}$' || continue
        # owner/repo, dropping any subdirectory (owner/repo/sub@sha).
        repo=$(printf '%s' "${action%@*}" | cut -d/ -f1,2)
        tag=$(printf '%s' "$comment" | awk '{print $1}')

        actual=$(gh api "repos/$repo/commits/$tag" --jq .sha 2>/dev/null || true)
        if [ -z "$actual" ]; then
          warn "$rel:$lineno  $repo: could not resolve tag '$tag' (renamed, deleted, or rate-limited)"
        elif [ "$actual" != "$ref" ]; then
          err "$rel:$lineno  $repo pin does not match its '$tag' comment: pinned $ref, $tag is $actual"
        fi

        latest=$(gh api "repos/$repo/releases/latest" --jq .tag_name 2>/dev/null || true)
        if [ -n "$latest" ] && [ "$latest" != "$tag" ]; then
          warn "$rel:$lineno  $repo $tag → $latest available"
        fi
      done < "$TMP/uses"
    done < "$TMP/files"
  fi
fi

# --- verdict ------------------------------------------------------------------
error_count=$(wc -l < "$TMP/errors" | tr -d ' ')
warn_count=$(wc -l < "$TMP/warnings" | tr -d ' ')

echo
[ "$error_count" -eq 0 ] || cat "$TMP/errors" >&2
[ "$warn_count" -eq 0 ]  || cat "$TMP/warnings" >&2

if [ "$error_count" -gt 0 ]; then
  echo "action pins: $error_count error(s), $warn_count warning(s)" >&2
  exit 1
fi
if [ "$warn_count" -gt 0 ]; then
  if [ "$STRICT" = true ]; then
    echo "action pins: $warn_count staleness warning(s) — failing because --strict" >&2
    exit 1
  fi
  echo "action pins: structure ok, $warn_count staleness warning(s) above (not fatal)"
  exit 0
fi
echo "action pins ok."
