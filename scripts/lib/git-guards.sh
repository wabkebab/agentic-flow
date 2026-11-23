#!/usr/bin/env bash
# Configure and prove the Git pre-commit scanner at the repository boundary.

git_guard_scrub_environment() {
  local var
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_CONFIG
  for var in ${!GIT_CONFIG_@}; do unset "$var"; done
}

git_guard_enable() ( # <project root>
  local project="$1" current top status=0
  git_guard_scrub_environment
  top=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ "$top" = "$project" ] || return 1
  current=$(git -C "$project" config --get core.hooksPath) || status=$?
  case "$status" in
    1) git -C "$project" config --local core.hooksPath scripts/git-hooks ;;
    0)
      if [ "$current" != scripts/git-hooks ]; then
        printf 'custom core.hooksPath (%s) kept. Chain the secret scan from pre-commit:\n' "$current"
        printf '  %q || exit $?\n' "$project/scripts/git-hooks/pre-commit"
      fi ;;
    *) return 1 ;;
  esac
)

git_guard_probe() ( # <project root>; no writes to the adopter
  local project="$1" hook_path scratch actual
  git_guard_scrub_environment
  unset AGENTIC_ALLOW_SECRET
  actual=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null) &&
    [ "$actual" = "$project" ] || return 1
  hook_path=$(git -C "$project" config --get --path core.hooksPath 2>/dev/null) || return 1
  [ -n "$hook_path" ] || return 1
  case "$hook_path" in /*) ;; *) hook_path="$project/$hook_path" ;; esac
  git_guard_temp=$(mktemp -d "${TMPDIR:-/tmp}/agentic-git-hook.XXXXXX") || return 1
  trap 'rm -rf -- "$git_guard_temp"' EXIT
  scratch=$(cd "$git_guard_temp" && pwd -P) || return 1
  git -C "$scratch" init --quiet --template= || return 1
  actual=$(git -C "$scratch" rev-parse --absolute-git-dir) &&
    [ "$actual" = "$scratch/.git" ] || return 1
  actual=$(git -C "$scratch" rev-parse --show-toplevel) &&
    [ "$actual" = "$scratch" ] || return 1
  actual=$(git -C "$scratch" rev-parse --path-format=absolute --git-path index) &&
    [ "$actual" = "$scratch/.git/index" ] || return 1
  git -C "$scratch" config --local core.hooksPath "$hook_path" &&
    git -C "$scratch" config --local user.name 'Agentic Flow hook probe' &&
    git -C "$scratch" config --local user.email probe@example.invalid || return 1
  if [ "$hook_path" != "$project/scripts/git-hooks" ]; then
    # Custom pre-commit hooks may chain the scanner relative to the worktree.
    # Supply the same scanner in the probe without pointing writes at live files.
    mkdir -p "$scratch/scripts/git-hooks" "$scratch/scripts/lib" &&
      command cp -p "$project/scripts/git-hooks/pre-commit" "$scratch/scripts/git-hooks/" &&
      command cp -p "$project/scripts/lib/staged-secrets.sh" "$scratch/scripts/lib/" || return 1
  fi
  printf 'key = "%s"\n' "$(printf 'AKIA%s' 'IOSFODNN7EXAMPLE')" > "$scratch/fixture" &&
    git -C "$scratch" add -- fixture || return 1
  if git -C "$scratch" -c commit.gpgsign=false commit --quiet -m 'Probe staged credential' > "$scratch/commit.log" 2>&1; then
    return 1
  fi
  grep -qx 'agentic-flow: staged credential blocked' "$scratch/commit.log"
)
