#!/usr/bin/env bash
# export.sh — copy the agentic-flow standard into a target project.
#
# Usage:
#   scripts/export.sh <target-dir>            non-destructive copy (default)
#   scripts/export.sh --dry-run <target-dir>  show what would happen, write nothing
#   scripts/export.sh --force <target-dir>    overwrite existing files (destructive)
#
# Copies the allow-list (METHODOLOGY/CLAUDE/AGENTS/Makefile, .claude/settings.json,
# .claude/skills, scripts, templates/ci, docs skeleton) and leaves behind this repo's meta:
# README.md, ROADMAP.md, .git, .claude/settings.local.json, and export.sh itself.
#
# Default mode never overwrites: a file that already exists in the target and differs is
# written next to it as `<file>.agentic-new` so you can diff and MERGE (important for a
# CLAUDE.md / Makefile / settings.json the target has already filled in). Identical files
# are skipped. Use --force to overwrite (it will clobber filled-in recipes — be sure).
set -euo pipefail

SRC=$(cd "$(dirname "$0")/.." && pwd -P)

DRY=false
FORCE=false
DST=""
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY=true ;;
    -f|--force)   FORCE=true ;;
    -h|--help)    sed -n '2,18p' "$0"; exit 0 ;;
    -*)           echo "unknown flag: $arg" >&2; exit 2 ;;
    *)            DST="$arg" ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
[ -n "$DST" ] || die "no target dir. Usage: $0 [--dry-run|--force] <target-dir>"

# Allow-list of items to export (files copied as-is; dirs copied file-by-file).
ITEMS=(
  METHODOLOGY.md
  ADOPTION.md
  templates/harness/CLAUDE.md=CLAUDE.md
  templates/harness/AGENTS.md=AGENTS.md
  templates/harness/Makefile=Makefile
  .claude/settings.json
  .claude/skills
  scripts
  templates/ci
  docs/templates
  docs/README.md
  docs/accepted_risks.md
  docs/backlog/.gitkeep
  docs/inprogress/.gitkeep
  docs/done/.gitkeep
  docs/done/security/.gitkeep
)
# Never export these (basenames anywhere, or exact relative paths).
EXCLUDE_BASENAMES=( settings.local.json .DS_Store )
EXCLUDE_PATHS=( scripts/export.sh )

is_excluded() {
  local rel="$1" base; base=$(basename "$rel")
  local x
  for x in "${EXCLUDE_BASENAMES[@]}"; do [ "$base" = "$x" ] && return 0; done
  for x in "${EXCLUDE_PATHS[@]}";     do [ "$rel"  = "$x" ] && return 0; done
  return 1
}

# Create / validate target.
if [ ! -d "$DST" ]; then
  if $DRY; then
    echo "(dry-run) would create target dir: $DST"
  else
    mkdir -p "$DST"; echo "created target dir: $DST"
  fi
fi
DST=$(cd "$DST" 2>/dev/null && pwd -P || echo "$DST")
[ "$DST" != "$SRC" ] || die "target is the agentic-flow repo itself"

# Expand the allow-list into parallel source/destination file lists (bash 3.2 safe — no mapfile).
FILES=()
DESTS=()
for item in "${ITEMS[@]}"; do
  src_item="${item%%=*}"
  if [ "$src_item" = "$item" ]; then
    dst_item="$src_item"
  else
    dst_item="${item#*=}"
  fi

  if [ -f "$SRC/$src_item" ]; then
    FILES+=("$src_item")
    DESTS+=("$dst_item")
  elif [ -d "$SRC/$src_item" ]; then
    while IFS= read -r f; do
      rel="${f#"$SRC"/}"
      FILES+=("$rel")
      if [ "$src_item" = "$dst_item" ]; then
        DESTS+=("$rel")
      else
        suffix="${rel#"$src_item"/}"
        DESTS+=("$dst_item/$suffix")
      fi
    done < <(find "$SRC/$src_item" -type f)
  fi
done

echo "Exporting agentic-flow standard"
echo "  from: $SRC"
echo "  to:   $DST"
echo "  mode: $([ "$FORCE" = true ] && echo FORCE-overwrite || echo non-destructive)$($DRY && echo ' (dry-run)')"
echo

created=0; overwritten=0; merge=0; same=0
i=0
while [ "$i" -lt "${#FILES[@]}" ]; do
  rel="${FILES[$i]}"
  dest="${DESTS[$i]}"
  i=$((i + 1))

  is_excluded "$rel" && continue
  s="$SRC/$rel"; d="$DST/$dest"
  if [ -e "$d" ]; then
    if cmp -s "$s" "$d"; then
      same=$((same + 1)); continue
    fi
    if [ "$FORCE" = true ]; then
      $DRY || { mkdir -p "$(dirname "$d")"; cp -p "$s" "$d"; }
      echo "  overwrite   $dest"; overwritten=$((overwritten + 1))
    else
      $DRY || cp -p "$s" "$d.agentic-new"
      echo "  exists →    $dest.agentic-new   (differs — merge by hand)"; merge=$((merge + 1))
    fi
  else
    $DRY || { mkdir -p "$(dirname "$d")"; cp -p "$s" "$d"; }
    echo "  create      $dest"; created=$((created + 1))
  fi
done

version=$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || printf '%s\n' unknown)
if [ "$DRY" = false ]; then
  printf '%s\n' "$version" > "$DST/.agentic-flow-version"
fi
echo "  stamp       .agentic-flow-version ($version)"

echo
echo "Summary: $created created, $overwritten overwritten, $merge to-merge (.agentic-new), $same already up to date."

# Seed the docs index in the target (best-effort; needs the markers in docs/README.md).
if [ "$DRY" = false ] && [ -x "$DST/scripts/docs-index.sh" ]; then
  if (cd "$DST" && ./scripts/docs-index.sh) >/dev/null 2>&1; then
    echo "Seeded docs index in target."
  else
    echo "Note: run scripts/docs-index.sh in the target once docs/README.md has the markers."
  fi
fi

if [ "$merge" -gt 0 ]; then
  echo
  echo "⚠ $merge file(s) already existed and differ — review the .agentic-new copies and merge:"
  echo "    find \"$DST\" -name '*.agentic-new'"
fi

cat <<EOF

Next, in the target:
  1. Fill in the Makefile recipes (check / test / test-one / build / run).
  2. Edit CLAUDE.md (project name, Stack-profile explainer + gotchas, architecture, opt-outs)
     and AGENTS.md (project name). Merge any .agentic-new copies.
  3. Ensure git-claude / git-codex are on PATH (or note the Claude-only opt-out in CLAUDE.md).
  4. Wire up CI: templates/ci/ci.yml is inert until you copy it to .github/workflows/.
     See templates/ci/README.md — make 'CI gate' the only required status check.
  5. Commit the harness.
EOF
