#!/usr/bin/env bash
# init.sh — adopt the agentic-flow scaffold into a target project.
#
# Usage:
#   scripts/init.sh <target-dir> --name <kebab> [--stack <profile>]
#                   [--claude-only] [--git-init] [--yes] [--dry-run]
#
# Every promptable choice has a matching flag. Non-TTY runs never prompt.
set -euo pipefail

SRC=$(cd "$(dirname "$0")/.." && pwd -P)
PROJECT_NAME=""
OWNER_LOGIN=""
STACK=""
CLAUDE_ONLY=false
GIT_INIT=false
YES=false
DRY=false
DST=""
STACK_SET=false
CLAUDE_ONLY_SET=false
GIT_INIT_SET=false
TOKEN="$(printf '{%sPROJECT_NAME}%s' '{' '}')"
TOKEN_RE="$(printf '{%s[A-Z][A-Z0-9_]*}%s' '{' '}')"

usage() {
  sed -n '2,7p' "$0" >&2
}

die() {
  echo "error: $*" >&2
  exit 1
}

detect_stack() {
  local target="$1" profile_file profile marker
  for profile_file in "$SRC"/profiles/*.tsv; do
    profile=$(basename "$profile_file" .tsv)
    [ "$profile" = generic ] && continue
    while IFS="$(printf '\t')" read -r key marker; do
      [ "$key" = detect ] || continue
      if [ -f "$target/$marker" ]; then
        printf '%s\n' "$profile"
        return
      fi
    done < "$profile_file"
  done
  printf '%s\n' generic
}

available_profiles() {
  local profile_file names=""
  for profile_file in "$SRC"/profiles/*.tsv; do
    names="${names}${names:+|}$(basename "$profile_file" .tsv)"
  done
  printf '%s\n' "$names"
}

target_in_git_repo() {
  local target="$1"
  [ -d "$target" ] || return 1
  git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

prompt_required_name() {
  local value
  while true; do
    printf 'Project name (--name): ' >&2
    IFS= read -r value || die "failed to read --name"
    if is_kebab "$value"; then
      PROJECT_NAME="$value"
      return
    fi
    echo "Enter kebab-case lowercase letters, numbers, and hyphens." >&2
  done
}

prompt_stack() {
  local default value
  default=$(detect_stack "$TARGET_ABS")
  while true; do
    printf 'Stack profile (--stack) [%s, default: %s]: ' "$(available_profiles)" "$default" >&2
    IFS= read -r value || die "failed to read --stack"
    [ -n "$value" ] || value="$default"
    [ "$value" = none ] && value=generic
    if [ -f "$SRC/profiles/$value.tsv" ]; then
      STACK="$value"
      return
    fi
    echo "Enter one of: $(available_profiles)." >&2
  done
}

prompt_yes_no() {
  local prompt="$1" default="$2" value
  while true; do
    printf '%s ' "$prompt" >&2
    IFS= read -r value || die "failed to read prompt"
    [ -n "$value" ] || value="$default"
    case "$value" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) echo "Enter yes or no." >&2 ;;
    esac
  done
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
    --owner-login)
      [ "$#" -ge 2 ] || die "--owner-login requires a value"
      OWNER_LOGIN="$2"; shift 2 ;;
    --owner-login=*) OWNER_LOGIN="${1#*=}"; shift ;;
    --name)
      [ "$#" -ge 2 ] || die "--name requires a value"
      PROJECT_NAME="$2"; shift 2 ;;
    --name=*)
      PROJECT_NAME="${1#--name=}"; shift ;;
    --stack)
      [ "$#" -ge 2 ] || die "--stack requires a value"
      STACK="$2"; STACK_SET=true; shift 2 ;;
    --stack=*)
      STACK="${1#--stack=}"; STACK_SET=true; shift ;;
    --claude-only)
      CLAUDE_ONLY=true; CLAUDE_ONLY_SET=true; shift ;;
    --git-init)
      GIT_INIT=true; GIT_INIT_SET=true; shift ;;
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
if [ ! -d "$DST" ]; then
  TARGET_ABS="$DST"
else
  TARGET_ABS=$(cd "$DST" && pwd -P)
fi
[ "$TARGET_ABS" != "$SRC" ] || die "target is the agentic-flow repo itself"

if [ "$YES" = false ] && [ ! -t 0 ]; then
  YES=true
fi

if [ "$YES" = false ]; then
  [ -n "$PROJECT_NAME" ] || prompt_required_name
  if [ "$STACK_SET" = false ]; then
    prompt_stack
  fi
  if [ "$CLAUDE_ONLY_SET" = false ]; then
    if prompt_yes_no "Claude-only mode (--claude-only)? [y/N]:" "n"; then
      CLAUDE_ONLY=true
    fi
  fi
  if [ "$GIT_INIT_SET" = false ] && ! target_in_git_repo "$TARGET_ABS"; then
    if prompt_yes_no "Initialize git repo (--git-init)? [y/N]:" "n"; then
      GIT_INIT=true
    fi
  fi
else
  [ -n "$PROJECT_NAME" ] || { usage; die "--name is required in non-interactive mode"; }
  if [ "$STACK_SET" = false ]; then
    STACK=$(detect_stack "$TARGET_ABS")
  fi
fi

is_kebab "$PROJECT_NAME" || die "--name must be kebab-case lowercase letters, numbers, and hyphens"
[ "$STACK" = none ] && STACK=generic
[ -f "$SRC/profiles/$STACK.tsv" ] \
  || die "--stack must name a profile in profiles/ ('none' aliases generic)"

if [ -z "$OWNER_LOGIN" ]; then
  OWNER_LOGIN=$(gh api user --jq .login 2>/dev/null) || OWNER_LOGIN=""
fi
[[ "$OWNER_LOGIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]] || die "provide a valid --owner-login (gh api user unavailable)"

# Claude-only means the Codex and OpenCode adapters are dead weight in the target: hooks
# that no tool reads, skills no runtime scans. AGENTS.md is deliberately not in this set —
# it is `core` scope and ships with its OPT-OUT banner so CLAUDE.md's link still resolves.
EXCLUDE_SCOPE_ARGS=()
if [ "$CLAUDE_ONLY" = true ]; then
  EXCLUDE_SCOPE_ARGS=( --exclude-scope=codex --exclude-scope=opencode )
fi

if [ "$DRY" = true ]; then
  "$SRC/scripts/export.sh" --dry-run "${EXCLUDE_SCOPE_ARGS[@]+"${EXCLUDE_SCOPE_ARGS[@]}"}" "$DST"
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
preexisting_ci_template=false
[ -e "$TARGET_ABS/CLAUDE.md" ] && preexisting_claude=true
[ -e "$TARGET_ABS/AGENTS.md" ] && preexisting_agents=true
[ -e "$TARGET_ABS/Makefile" ] && preexisting_makefile=true
[ -e "$TARGET_ABS/templates/ci/ci.yml" ] && preexisting_ci_template=true

"$SRC/scripts/export.sh" "${EXCLUDE_SCOPE_ARGS[@]+"${EXCLUDE_SCOPE_ARGS[@]}"}" "$TARGET_ABS"

owner_token=$(printf '{%sOWNER_LOGIN}%s' '{' '}')
for policy in "$TARGET_ABS/.agentic-flow-review-policy" "$TARGET_ABS/.agentic-flow-review-policy.agentic-new"; do
  [ -f "$policy" ] || continue
  sed "s/$owner_token/$OWNER_LOGIN/g" "$policy" > "$policy.tmp.$$"
  mv "$policy.tmp.$$" "$policy"
done

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

if [ "$preexisting_makefile" = false ]; then
  "$SRC/scripts/render-stack-profile.sh" "$STACK" "$TARGET_ABS/Makefile"
  printf '%s\n' "$STACK" > "$TARGET_ABS/.agentic-flow-stack"
else
  printf '%s\n' "$STACK" > "$TARGET_ABS/.agentic-flow-stack-candidate"
fi
"$SRC/scripts/render-stack-profile.sh" "$STACK" "$TARGET_ABS/Makefile.agentic-new" \
  2>/dev/null || true
if [ "$preexisting_ci_template" = false ]; then
  "$SRC/scripts/render-stack-profile.sh" "$STACK" --ci "$TARGET_ABS/templates/ci/ci.yml"
else
  "$SRC/scripts/render-stack-profile.sh" "$STACK" --ci "$TARGET_ABS/templates/ci/ci.yml.agentic-new" \
    2>/dev/null || true
fi
echo "Applied $STACK stack profile; verify its Make recipes match the project."

token_files=""
for f in "$TARGET_ABS/CLAUDE.md" "$TARGET_ABS/AGENTS.md" \
         "$TARGET_ABS/CLAUDE.md.agentic-new" "$TARGET_ABS/AGENTS.md.agentic-new"; do
  if [ -f "$f" ] && grep -Eq "$TOKEN_RE" "$f"; then
    token_files="${token_files}
$f"
  fi
done
[ -z "$token_files" ] || die "unfilled template tokens remain:$token_files"

# Initialization deliberately fills project names and renders a stack profile after export.
# Refresh the successful installation record to describe those installed bytes.
if [ ! -f "$TARGET_ABS/.agentic-flow-candidate-version" ]; then
  # shellcheck disable=SC1091 # The helper is sourced from this scaffold checkout.
  . "$SRC/scripts/lib/payload-apply.sh"
  payload_resolve_installation "$TARGET_ABS" "$SRC/config/payload.tsv"
  payload_load_manifest "$SRC/config/payload.tsv"
  payload_expand_files "$SRC"
  payload_write_installation "$TARGET_ABS" "$SRC/config/payload.tsv"
fi

echo
(cd "$TARGET_ABS" && scripts/doctor.sh)

echo
if command -v gh >/dev/null 2>&1 && (cd "$TARGET_ABS" && gh repo view >/dev/null 2>&1); then
  (cd "$TARGET_ABS" && scripts/create-tags.sh) \
    || echo "warning: could not create GitHub workflow labels — rerun scripts/create-tags.sh later." >&2
else
  echo "Skipping GitHub workflow labels (no gh auth / GitHub remote yet) — run scripts/create-tags.sh once the repo exists on GitHub."
fi

echo
echo "Initialized agentic-flow scaffold in $TARGET_ABS."
if [ "$YES" = true ]; then
  echo "Ran non-interactively with --yes."
fi
