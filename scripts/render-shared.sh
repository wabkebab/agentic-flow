#!/usr/bin/env bash
# Render source-repository contracts. Installed projects receive the rendered files.
set -euo pipefail

ROOT=${AGENTIC_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
CHECK=false
case "${1:-}" in
  --check) CHECK=true ;;
  '') ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: $0 [--check]" >&2; exit 2; }

# Adopters do not receive the source templates and have no pairs to render.
if [ ! -d "$ROOT/templates/shared" ] && [ ! -d "$ROOT/templates/harness" ]; then
  echo "shared render skipped (installed project)."
  exit 0
fi

die() { echo "shared render: $*" >&2; exit 1; }
tmp=$(mktemp -d "$ROOT/.agentic-flow-render.XXXXXX") || die 'cannot create staging directory'
complete=false
replaced=0
cleanup() {
  if [ "$complete" = false ] && [ "$replaced" -gt 0 ]; then
    j=1
    while [ "$j" -le "$replaced" ]; do
      if [ -f "$tmp/$j.old" ]; then
        previous=$(sed -n "${j}p" "$tmp/consumers")
        mv "$tmp/$j.old" "$ROOT/$previous" || echo "shared render: rollback failed: $previous" >&2
      fi
      j=$((j + 1))
    done
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# Each row names one canonical source, one consumer, and either a whole file or
# a single marked region. This is a render graph, not an export membership list.
spec=$(cat <<'SPEC'
templates/shared/plan-to-issues.SKILL.md|.agents/skills/plan-to-issues/SKILL.md|whole
templates/shared/plan-to-issues.SKILL.md|.claude/skills/plan-to-issues/SKILL.md|whole
templates/shared/create-tags.SKILL.md|.agents/skills/create-tags/SKILL.md|whole
templates/shared/create-tags.SKILL.md|.claude/skills/create-tags/SKILL.md|whole
templates/shared/shell-gate.mk|Makefile|SHELL GATE
templates/shared/shell-gate.mk|templates/harness/Makefile|SHELL GATE
templates/shared/engineering-standards.md|AGENTS.md|ENGINEERING STANDARDS
templates/shared/engineering-standards.md|templates/harness/AGENTS.md|ENGINEERING STANDARDS
templates/shared/claude-tools.md|CLAUDE.md|CLAUDE TOOLS
templates/shared/claude-tools.md|templates/harness/CLAUDE.md|CLAUDE TOOLS
templates/shared/review-contract.md|.agents/skills/review-execution/SKILL.md|REVIEW CONTRACT
templates/shared/review-contract.md|.opencode/agent/code-reviewer.md|REVIEW CONTRACT
templates/shared/review-contract.md|METHODOLOGY.md|REVIEW CONTRACT
templates/shared/workflow.md|templates/shared/workflow.md|whole
templates/shared/workflow.md|METHODOLOGY.md|WORKFLOW
SPEC
)

render_region() { # source consumer marker output
  local source=$1 consumer=$2 marker=$3 output=$4 begin end
  case "$consumer" in *.mk|*/Makefile|Makefile) begin="# BEGIN SHARED $marker"; end="# END SHARED $marker" ;;
    *) begin="<!-- BEGIN SHARED $marker -->"; end="<!-- END SHARED $marker -->" ;;
  esac
  [ "$(grep -Fxc "$begin" "$consumer" || true)" -eq 1 ] || die "missing or duplicate begin marker in ${consumer#"$ROOT"/}"
  [ "$(grep -Fxc "$end" "$consumer" || true)" -eq 1 ] || die "missing or duplicate end marker in ${consumer#"$ROOT"/}"
  if grep -E '^(<!-- |# )(BEGIN|END) SHARED ' "$consumer" | grep -Ev '^(<!-- |# )(BEGIN|END) SHARED (SHELL GATE|ENGINEERING STANDARDS|CLAUDE TOOLS|REVIEW CONTRACT|WORKFLOW)( -->)?$' >/dev/null; then
    die "unknown region in ${consumer#"$ROOT"/}"
  fi
  awk -v b="$begin" -v e="$end" -v src="$source" '
    $0 == b { if (inside) exit 3; print; while ((getline line < src) > 0) print line; close(src); inside=1; next }
    $0 == e { if (!inside) exit 3; inside=0; print; next }
    !inside { print }
    END { if (inside) exit 3 }
  ' "$consumer" > "$output" || die "cannot render ${consumer#"$ROOT"/}"
}

# Validate and stage every consumer before any replacement. Refuse unknown
# region names and missing inputs; a bad graph cannot partially rewrite files.
# Validate the bounded data contract before generating any output.
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/workflow.sh"
workflow_load "$ROOT" || die 'invalid workflow'
{
  # shellcheck disable=SC2016 # Literal Markdown command references.
  printf 'Generated from `config/workflow.tsv`; edit the data, then run `scripts/render-shared.sh`.\n\n'
  printf '| Topology | State | Labels | Issue status |\n|---|---|---|---|\n'
  printf '%s\n' "$WORKFLOW_DATA" | awk -F '\t' '$1 == "state" { printf "| %s | %s | %s | %s |\n", $2,$3,$4,$5 }'
  printf '\n| Topology | Event | Role | From | To | Requires |\n|---|---|---|---|---|---|\n'
  printf '%s\n' "$WORKFLOW_DATA" | awk -F '\t' '$1 == "transition" { printf "| %s | %s | %s | %s | %s | %s |\n", $2,$3,$4,$5,$6,$7 }'
} > "$tmp/workflow.md"

i=0
while IFS='|' read -r source consumer mode; do
  [ -n "$source" ] || continue
  case "$mode" in whole|'SHELL GATE'|'ENGINEERING STANDARDS'|'CLAUDE TOOLS'|'REVIEW CONTRACT'|WORKFLOW) ;;
    *) die "unknown region: $mode" ;;
  esac
  [ "$source" = templates/shared/workflow.md ] || [ -f "$ROOT/$source" ] || die "missing canonical source: $source"
  [ -f "$ROOT/$consumer" ] || die "missing consumer: $consumer"
  i=$((i + 1))
  source_path="$ROOT/$source"
  [ "$source" != templates/shared/workflow.md ] || source_path="$tmp/workflow.md"
  consumer_path="$ROOT/$consumer"
  # Later regions of one consumer build on its already-staged version.
  if [ -f "$tmp/consumers" ]; then
    previous_index=$(awk -v c="$consumer" '$0 == c { n=NR } END { if (n) print n }' "$tmp/consumers")
    [ -z "$previous_index" ] || consumer_path="$tmp/$previous_index.new"
  fi
  if [ "$mode" = whole ]; then
    cp "$source_path" "$tmp/$i.new" || die "cannot stage $consumer"
  else
    render_region "$source_path" "$consumer_path" "$mode" "$tmp/$i.new"
  fi
  printf '%s\n' "$consumer" >> "$tmp/consumers"
done <<< "$spec"

i=0
changed=0
while IFS= read -r consumer; do
  i=$((i + 1))
  if ! cmp -s "$ROOT/$consumer" "$tmp/$i.new"; then
    if [ "$CHECK" = true ]; then
      echo "shared render drift: $consumer" >&2
      changed=1
    else
      cp -p "$ROOT/$consumer" "$tmp/$i.old" || die "cannot back up $consumer"
      chmod --reference="$ROOT/$consumer" "$tmp/$i.new" 2>/dev/null || chmod "$(stat -f %Lp "$ROOT/$consumer" 2>/dev/null || stat -c %a "$ROOT/$consumer")" "$tmp/$i.new"
    fi
  fi
done < "$tmp/consumers"
[ "$changed" -eq 0 ] || exit 1
# Backups and replacement files are all prepared before the first rename.
if [ "$CHECK" = false ]; then
  i=0
  while IFS= read -r consumer; do
    i=$((i + 1))
    if [ -f "$tmp/$i.old" ]; then
      mv "$tmp/$i.new" "$ROOT/$consumer" || die "cannot replace $consumer"
    fi
    replaced=$i
  done < "$tmp/consumers"
fi
complete=true
echo "shared render ok."
