#!/usr/bin/env bash
# init.sh — adopt the agentic-flow scaffold into a target project.
#
# Usage:
#   scripts/init.sh <target-dir> --name <kebab> [--stack none|node] [--claude-only] [--git-init] [--yes] [--dry-run]
#
# Non-interactive core: every promptable choice has a flag. The interactive layer is a
# thin wrapper added separately; this core must stay scriptable for agents and CI.
set -euo pipefail

SRC=$(cd "$(dirname "$0")/.." && pwd -P)
PROJECT_NAME=""
STACK="none"
CLAUDE_ONLY=false
GIT_INIT=false
YES=false
DRY=false
DST=""
TOKEN="$(printf '{%sPROJECT_NAME}%s' '{' '}')"
TOKEN_OPEN="$(printf '{%s' '{')"

usage() {
  sed -n '2,7p' "$0" >&2
}

die() {
  echo "error: $*" >&2
  exit 1
}

is_kebab() {
  case "$1" in
    ""|*-|-*|*--*) return 1 ;;
  esac
  case "$1" in
    *[!a-z0-9-]*) return 1 ;;
  esac
  return 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name)
      [ "$#" -ge 2 ] || die "--name requires a value"
      PROJECT_NAME="$2"; shift 2 ;;
    --name=*)
      PROJECT_NAME="${1#--name=}"; shift ;;
    --stack)
      [ "$#" -ge 2 ] || die "--stack requires a value"
      STACK="$2"; shift 2 ;;
    --stack=*)
      STACK="${1#--stack=}"; shift ;;
    --claude-only)
      CLAUDE_ONLY=true; shift ;;
    --git-init)
      GIT_INIT=true; shift ;;
    --yes)
      YES=true; shift ;;
    --dry-run|-n)
      DRY=true; shift ;;
    --help|-h)
      usage; exit 0 ;;
    -*)
      die "unknown flag: $1" ;;
    *)
      [ -z "$DST" ] || die "multiple target dirs provided"
      DST="$1"; shift ;;
  esac
done

[ -n "$DST" ] || { usage; die "no target dir provided"; }
[ -n "$PROJECT_NAME" ] || { usage; die "--name is required in non-interactive mode"; }
is_kebab "$PROJECT_NAME" || die "--name must be kebab-case lowercase letters, numbers, and hyphens"
case "$STACK" in
  none|node) ;;
  *) die "--stack must be 'none' or 'node'" ;;
esac

if [ ! -d "$DST" ]; then
  TARGET_ABS="$DST"
else
  TARGET_ABS=$(cd "$DST" && pwd -P)
fi
[ "$TARGET_ABS" != "$SRC" ] || die "target is the agentic-flow repo itself"

if [ "$DRY" = true ]; then
  "$SRC/scripts/export.sh" --dry-run "$DST"
  echo
  echo "Dry run only; no files were initialized."
  exit 0
fi

if [ ! -d "$DST" ]; then
  mkdir -p "$DST"
fi
TARGET_ABS=$(cd "$DST" && pwd -P)

if [ "$GIT_INIT" = true ]; then
  if git -C "$TARGET_ABS" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "--git-init is only allowed when the target is not already inside a git repo"
  fi
  git -C "$TARGET_ABS" init >/dev/null
  echo "initialized git repo: $TARGET_ABS"
fi

preexisting_claude=false
preexisting_agents=false
preexisting_makefile=false
[ -e "$TARGET_ABS/CLAUDE.md" ] && preexisting_claude=true
[ -e "$TARGET_ABS/AGENTS.md" ] && preexisting_agents=true
[ -e "$TARGET_ABS/Makefile" ] && preexisting_makefile=true

"$SRC/scripts/export.sh" "$TARGET_ABS"

fill_project_name() {
  local file="$1" tmp
  [ -f "$file" ] || return 0
  tmp="$file.tmp.$$"
  sed "s/$TOKEN/$PROJECT_NAME/g" "$file" > "$tmp"
  mv "$tmp" "$file"
}

apply_claude_only() {
  local file="$1" tmp opt
  [ -f "$file" ] || return 0
  opt="This project opts out of the default two-agent split: Claude both plans/reviews and executes; keep the document lifecycle and review discipline, drop agent:codex labels and git-codex."
  tmp="$file.tmp.$$"
  awk -v opt="$opt" '
    in_block == 0 && /<!-- OPT-OUT:/ { print opt; in_block=1; next }
    in_block == 1 {
      if ($0 ~ /-->/) in_block=0
      next
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

apply_node_preset() {
  local file="$1" tmp
  [ -f "$file" ] || return 0
  tmp="$file.tmp.$$"
  awk '
    skip == 1 && /^[A-Za-z0-9_.-]+:/ { skip=0 }
    skip == 1 { next }
    /^check:/ {
      print
      print "\t@for f in scripts/*.sh scripts/hooks/*.sh; do bash -n \"$$f\" || exit 1; done"
      print "\t@scripts/docs-index.sh --check"
      print "\t@scripts/self-test.sh"
      print "\t@npm run typecheck"
      print "\t@npm run lint"
      skip=1
      next
    }
    /^test:/ {
      print
      print "\t@npm run test:run"
      skip=1
      next
    }
    /^test-one:/ {
      print
      print "\t@npx vitest run $(F)"
      skip=1
      next
    }
    /^build:/ {
      print
      print "\t@npm run build"
      skip=1
      next
    }
    /^run:/ {
      print
      print "\t@npm run dev"
      skip=1
      next
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

if [ "$preexisting_claude" = false ]; then
  fill_project_name "$TARGET_ABS/CLAUDE.md"
fi
if [ "$preexisting_agents" = false ]; then
  fill_project_name "$TARGET_ABS/AGENTS.md"
fi
fill_project_name "$TARGET_ABS/CLAUDE.md.agentic-new"
fill_project_name "$TARGET_ABS/AGENTS.md.agentic-new"
if [ "$CLAUDE_ONLY" = true ]; then
  if [ "$preexisting_claude" = false ]; then
    apply_claude_only "$TARGET_ABS/CLAUDE.md"
  fi
  if [ "$preexisting_agents" = false ]; then
    apply_claude_only "$TARGET_ABS/AGENTS.md"
  fi
  apply_claude_only "$TARGET_ABS/CLAUDE.md.agentic-new"
  apply_claude_only "$TARGET_ABS/AGENTS.md.agentic-new"
fi

if [ "$STACK" = "node" ]; then
  if [ "$preexisting_makefile" = false ]; then
    apply_node_preset "$TARGET_ABS/Makefile"
  fi
  apply_node_preset "$TARGET_ABS/Makefile.agentic-new"
  echo "Applied node stack preset; verify these recipes match package.json."
fi

token_files=""
for f in "$TARGET_ABS/CLAUDE.md" "$TARGET_ABS/AGENTS.md" \
         "$TARGET_ABS/CLAUDE.md.agentic-new" "$TARGET_ABS/AGENTS.md.agentic-new"; do
  if [ -f "$f" ] && grep -q "$TOKEN_OPEN" "$f"; then
    token_files="${token_files}
$f"
  fi
done
[ -z "$token_files" ] || die "unfilled template tokens remain:$token_files"

echo
(cd "$TARGET_ABS" && scripts/doctor.sh)

echo
echo "Initialized agentic-flow scaffold in $TARGET_ABS."
if [ "$YES" = true ]; then
  echo "Ran non-interactively with --yes."
fi
