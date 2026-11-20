#!/usr/bin/env bash
# Print the SHA-256 of the staged App inputs for this checkout. In Actions,
# checkout supplies the PR merge tree and its active workflow.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=scripts/lib/ci-bookkeeping.sh
. "$script_dir/lib/ci-bookkeeping.sh"
root=$(git rev-parse --show-toplevel)
cd "$root"
globs=$(ci_bookkeeping_globs .github/workflows/ci.yml) || {
  echo 'Cannot read the App bookkeeping filter from .github/workflows/ci.yml' >&2
  exit 1
}

# Git glob pathspecs support the filter's * and **. Force literal rules to
# match as globs too, so ROADMAP.md excludes just that exact path and cannot
# hide tracked files inside a directory named ROADMAP.md.
exclusions=()
while IFS= read -r glob; do
  case "$glob" in
    *'*'*) ;;
    *) glob="${glob%?}[${glob: -1}]" ;;
  esac
  exclusions+=(":(top,glob,exclude)$glob")
done <<< "$globs"

git -c core.quotePath=true ls-files -s -- "${exclusions[@]}" | shasum -a 256 | cut -d ' ' -f 1
