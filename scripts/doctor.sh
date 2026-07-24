#!/usr/bin/env bash
# doctor.sh — adoption checklist for a project using the agentic-flow scaffold.
#
# Usage:
#   scripts/doctor.sh          report required-tool and scaffold gaps
#   scripts/doctor.sh --check  same report; exits non-zero when gaps are found
set -euo pipefail

CHECK=false
case "${1:-}" in
  --check) CHECK=true ;;
  -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac

# Resolve from this script, not the enclosing git worktree. A harness installed in a
# monorepo subdirectory owns that subdirectory; `git rev-parse --show-toplevel` would make
# doctor inspect the parent project instead.
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
failures=0
warnings=0
TOKEN_RE="$(printf '{%s[A-Z][A-Z0-9_]*}%s' '{' '}')"

ok() { printf 'ok      %s\n' "$*"; }
warn() { printf 'warning %s\n' "$*"; warnings=$((warnings + 1)); }
fail() { printf 'missing %s\n' "$*"; failures=$((failures + 1)); }

require_file() {
  if [ -f "$ROOT/$1" ]; then ok "$1"; else fail "$1"; fi
}

require_executable() {
  if [ -x "$ROOT/$1" ]; then ok "$1 executable"; else fail "$1 executable"; fi
}

require_tool() {
  if command -v "$1" >/dev/null 2>&1; then ok "tool: $1"; else fail "tool: $1"; fi
}

optional_tool() {
  if command -v "$1" >/dev/null 2>&1; then
    ok "optional tool: $1"
  else
    warn "optional tool not found: $1"
  fi
}

pretool_hook_wired() {
  local file="$1" script="$2"
  jq -e --arg script "$script" '
    [.hooks.PreToolUse[]?
      | select(.matcher == "Bash")
      | .hooks[]?
      | .command?
      | strings]
    | any(contains($script))
  ' "$file" >/dev/null 2>&1
}

stop_hook_wired() {
  local file="$1" event="$2"
  jq -e --arg event "$event" '
    .hooks[$event]?
    | type == "array" and
      any(.[]?.hooks[]?.command?; strings | contains("scripts/hooks/check-gate.sh"))
  ' "$file" >/dev/null 2>&1
}

real_make_target() {
  local target="$1"
  if ! grep -Eq "^${target}:" "$ROOT/Makefile" 2>/dev/null; then
    fail "Makefile target: $target"
    return
  fi
  if awk -v target="$target" '
    $0 ~ "^" target ":" {in_target=1; next}
    in_target && /^[[:alnum:]_.-]+:/ {exit}
    in_target && /TODO: define/ {found=1}
    END {exit found ? 0 : 1}
  ' "$ROOT/Makefile"; then
    fail "Makefile target still placeholder: $target"
  else
    ok "Makefile target wired: $target"
  fi
}

echo "agentic-flow adoption checklist"
echo "root: $ROOT"
echo

require_tool bash
require_tool make
require_tool git
require_tool jq
require_tool gh
require_tool shellcheck
require_tool gitleaks
if grep -q "This project opts out of the default two-agent split" "$ROOT/CLAUDE.md" 2>/dev/null; then
  ok "execution mode: Claude-only"
  require_tool git-claude
  optional_tool git-codex
else
  ok "execution mode: Claude + Codex"
  require_tool git-claude
  require_tool git-codex
fi

echo
require_file METHODOLOGY.md
require_file ADOPTION.md
require_file CLAUDE.md
require_file AGENTS.md
require_file Makefile
require_file config/payload.tsv
require_file .claude/settings.json
require_file .codex/hooks.json
require_file .agents/skills/plan-to-issues/SKILL.md
require_file scripts/docs-index.sh
require_file scripts/lifecycle-status.sh
require_file scripts/render-stack-profile.sh
require_file scripts/plan-to-issues.sh
require_file scripts/doctor.sh
require_file scripts/self-test.sh
require_file scripts/hooks/check-gate.sh
require_file scripts/hooks/block-git-add-all.sh
require_file scripts/hooks/block-push.sh
require_file scripts/hooks/scan-secrets.sh
require_file docs/README.md
require_file docs/accepted_risks.md

if [ -f "$ROOT/config/payload.tsv" ]; then
  manifest_failures=0
  while IFS="$(printf '\t')" read -r source destination scope merge_policy disposition; do
    case "${source:-}" in ""|\#*) continue ;; esac
    case "${disposition:-}" in
      export)
        if [ ! -e "$ROOT/$destination" ]; then
          fail "manifest destination: $destination"
          manifest_failures=$((manifest_failures + 1))
        fi
        ;;
      source-only) ;;
      *)
        fail "manifest disposition for $source"
        manifest_failures=$((manifest_failures + 1))
        ;;
    esac
    [ -n "${scope:-}" ] || {
      fail "manifest scope for $source"
      manifest_failures=$((manifest_failures + 1))
    }
    case "${merge_policy:-}" in preserve|force|none) ;; *)
      fail "manifest merge policy for $source"
      manifest_failures=$((manifest_failures + 1))
      ;;
    esac
  done < "$ROOT/config/payload.tsv"
  if [ "$manifest_failures" -eq 0 ]; then
    ok "payload manifest destinations present"
  fi
fi

candidate_files=$(find "$ROOT" -type f -name '*.agentic-new*' -print 2>/dev/null | head -20)
if [ -n "$candidate_files" ]; then
  fail "unresolved scaffold merge candidates:"
  printf '%s\n' "$candidate_files" | sed "s|^$ROOT/|        |"
else
  ok "no unresolved scaffold merge candidates"
fi

if grep -Eq "$TOKEN_RE" "$ROOT/CLAUDE.md" "$ROOT/AGENTS.md" 2>/dev/null; then
  fail "unfilled template tokens in CLAUDE.md or AGENTS.md"
else
  ok "CLAUDE.md and AGENTS.md tokens filled"
fi

if [ -f "$ROOT/.agentic-flow-version" ]; then
  version=$(sed -n '1p' "$ROOT/.agentic-flow-version")
  ok "scaffold version: $version"
else
  warn "scaffold version stamp not found: .agentic-flow-version"
fi
if [ -f "$ROOT/.agentic-flow-candidate-version" ]; then
  candidate_version=$(sed -n '1p' "$ROOT/.agentic-flow-candidate-version")
  warn "scaffold update pending merge: $candidate_version"
fi
if [ -f "$ROOT/.agentic-flow-stack" ]; then
  stack_profile=$(sed -n '1p' "$ROOT/.agentic-flow-stack")
  if [ -f "$ROOT/profiles/$stack_profile.tsv" ]; then
    ok "stack profile: $stack_profile"
    if [ "$stack_profile" = generic ]; then
      warn "generic stack profile validates the harness only; customize project recipes"
    fi
  else
    fail "unknown stack profile: $stack_profile"
  fi
else
  warn "stack profile stamp not found: .agentic-flow-stack"
fi
if [ -f "$ROOT/.agentic-flow-stack-candidate" ]; then
  candidate_stack=$(sed -n '1p' "$ROOT/.agentic-flow-stack-candidate")
  warn "stack profile pending Makefile merge: $candidate_stack"
fi

require_executable scripts/docs-index.sh
require_executable scripts/lifecycle-status.sh
require_executable scripts/render-stack-profile.sh
require_executable scripts/plan-to-issues.sh
require_executable scripts/doctor.sh
require_executable scripts/self-test.sh
require_executable scripts/hooks/check-gate.sh
require_executable scripts/hooks/block-git-add-all.sh
require_executable scripts/hooks/block-push.sh
require_executable scripts/hooks/scan-secrets.sh

echo
real_make_target check
real_make_target test
real_make_target test-one
real_make_target build
real_make_target run

for adapter in .claude/settings.json .codex/hooks.json; do
  if jq -e . "$ROOT/$adapter" >/dev/null 2>&1; then
    ok "$adapter valid JSON"
  else
    fail "$adapter valid JSON"
    continue
  fi
  if stop_hook_wired "$ROOT/$adapter" Stop \
     && stop_hook_wired "$ROOT/$adapter" SubagentStop; then
    ok "$adapter Stop hooks wired"
  else
    fail "$adapter Stop/SubagentStop hooks wired to check-gate.sh"
  fi
  for guard in block-git-add-all.sh block-push.sh scan-secrets.sh; do
    if pretool_hook_wired "$ROOT/$adapter" "scripts/hooks/$guard"; then
      ok "$adapter PreToolUse: $guard"
    else
      fail "$adapter PreToolUse wired to scripts/hooks/$guard"
    fi
  done
done

if [ -f "$ROOT/.github/workflows/ci.yml" ]; then
  ok "CI workflow active: .github/workflows/ci.yml"
elif [ -f "$ROOT/templates/ci/ci.yml" ]; then
  warn "CI template is inert; activate it when project Make targets are ready"
else
  fail "CI workflow or inert template"
fi

if "$ROOT/scripts/docs-index.sh" --check >/dev/null 2>&1; then
  ok "docs index up to date"
else
  fail "docs index up to date (run scripts/docs-index.sh)"
fi

# Behavior-derived, not text-derived: a `check` recipe can look wired yet still be red.
if [ "${AGENTIC_SELFTEST:-}" = "1" ]; then
  ok "make check passes (skipped inside self-test recursion guard)"
elif (cd "$ROOT" && make check) >/dev/null 2>&1; then
  ok "make check passes"
else
  fail "make check passes (run 'make check' to see why)"
fi

echo
echo "Summary: $failures missing/failed, $warnings warning(s)."

if [ "$CHECK" = true ] && [ "$failures" -gt 0 ]; then
  exit 1
fi

exit 0
