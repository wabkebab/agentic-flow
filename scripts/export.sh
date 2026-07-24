#!/usr/bin/env bash
# export.sh — copy the agentic-flow standard into a target project.
#
# Usage:
#   scripts/export.sh <target-dir>            non-destructive copy (default)
#   scripts/export.sh --dry-run <target-dir>  show what would happen, write nothing
#   scripts/export.sh --force <target-dir>    overwrite existing files (destructive)
#
# Copies the entries declared in config/payload.tsv and leaves behind entries marked
# source-only plus this repo's live docs and metadata.
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

# The manifest is the one source of truth for payload membership. Export, doctor, and
# self-test all consume or validate it so a new adapter cannot silently exist only here.
MANIFEST="$SRC/config/payload.tsv"
[ -f "$MANIFEST" ] || die "payload manifest not found: $MANIFEST"

# Never export these basenames anywhere. Exact source-only paths come from the manifest.
EXCLUDE_BASENAMES=( settings.local.json .DS_Store )
EXCLUDE_PATHS=()
ITEM_SRCS=()
ITEM_DSTS=()

while IFS="$(printf '\t')" read -r src_item dst_item scope merge_policy disposition; do
  case "${src_item:-}" in ""|\#*) continue ;; esac
  [ -n "${dst_item:-}" ] || die "manifest entry has no destination: $src_item"
  case "${disposition:-}" in
    export)
      ITEM_SRCS+=("$src_item")
      ITEM_DSTS+=("$dst_item")
      ;;
    source-only)
      EXCLUDE_PATHS+=("$src_item")
      ;;
    *)
      die "manifest entry has invalid disposition '${disposition:-}': $src_item"
      ;;
  esac
  case "${merge_policy:-}" in preserve|force|none) ;; *)
    die "manifest entry has invalid merge policy '$merge_policy': $src_item" ;;
  esac
  [ -n "${scope:-}" ] || die "manifest entry has no scope: $src_item"
done < "$MANIFEST"

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

# Expand the manifest into parallel source/destination file lists (bash 3.2 safe).
FILES=()
DESTS=()
manifest_i=0
while [ "$manifest_i" -lt "${#ITEM_SRCS[@]}" ]; do
  src_item="${ITEM_SRCS[$manifest_i]}"
  dst_item="${ITEM_DSTS[$manifest_i]}"
  manifest_i=$((manifest_i + 1))

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
    done < <(find "$SRC/$src_item" -type f | sort)
  else
    die "manifest source does not exist: $src_item"
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
