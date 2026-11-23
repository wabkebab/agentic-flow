#!/usr/bin/env bash
# export.sh — copy the agentic-flow standard into a target project.
#
# Usage:
#   scripts/export.sh <target-dir>            non-destructive copy (default)
#   scripts/export.sh --dry-run <target-dir>  show what would happen, write nothing
#   scripts/export.sh --force <target-dir>    overwrite existing files (destructive)
#   scripts/export.sh --exclude-scope=codex <target-dir>
#                                             skip every manifest row in that scope
#                                             (repeatable: claude|codex|opencode|ci)
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
. "$SRC/scripts/lib/payload-apply.sh"

DRY=false
FORCE=false
DST=""
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY=true ;;
    -f|--force)   FORCE=true ;;
    # Repeatable. `=` form because this loop does not shift.
    --exclude-scope=*)
      PAYLOAD_EXCLUDED_SCOPES="${PAYLOAD_EXCLUDED_SCOPES:-} ${arg#*=}" ;;
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
requested_scopes="$PAYLOAD_EXCLUDED_SCOPES"
payload_load_manifest "$MANIFEST"
payload_resolve_installation "$DST" "$MANIFEST" "$requested_scopes"
payload_load_manifest "$MANIFEST"

# Generated adapter copies must agree with their canonical sources before any
# destination write. The manifest still owns which scopes and files are exported.
if [ -d "$SRC/templates/shared" ]; then
  "$SRC/scripts/render-shared.sh" --check || die "render shared contracts before exporting"
fi

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

PAYLOAD_DST_ROOT="$DST"
payload_expand_files "$SRC"
for protected_dest in "${DESTS[@]}"; do
  case "$protected_dest" in .agentic-flow-assurance|.agentic-flow-assurance-audit)
    die "assurance state is project-owned and cannot be a payload destination" ;;
  esac
done
payload_upstream_load "$DST" export

# Assurance is project-owned state, outside the upgrade payload. Seed only a new
# installation and validate an existing choice before touching payload files.
[ ! -L "$DST/.agentic-flow-assurance" ] || die "assurance state must be a regular file"
"$SRC/scripts/assurance.sh" --check-for-root "$DST"
if [ ! -e "$DST/.agentic-flow-assurance" ] && [ "$DRY" = false ]; then
  printf 'standard\n' > "$DST/.agentic-flow-assurance"
fi

echo "Exporting agentic-flow standard"
echo "  from: $SRC"
echo "  to:   $DST"
echo "  mode: $([ "$FORCE" = true ] && echo FORCE-overwrite || echo non-destructive)$($DRY && echo ' (dry-run)')"
echo

# Two-part stamp: a human-facing semver (bumped deliberately in VERSION on a contract
# change) plus a `+`-joined git short SHA (semver build-metadata syntax) that machines can
# diff exactly, since two exports on the same unreleased semver still need to compare.
version=$(payload_compute_version "$SRC")
PAYLOAD_VERSION="$version"
PAYLOAD_DRY="$DRY"
PAYLOAD_FORCE="$FORCE"
PAYLOAD_DST_ROOT="$DST"
source_origin=$(git -C "$SRC" remote get-url origin 2>/dev/null || true)
source_ref=${AGENTIC_FLOW_SOURCE_REF:-main}
created=0; overwritten=0; merge=0; same=0; candidate_created=0; candidate_reused=0
i=0
while [ "$i" -lt "${#FILES[@]}" ]; do
  rel="${FILES[$i]}"
  dest="${DESTS[$i]}"
  i=$((i + 1))

  payload_is_excluded "$rel" && continue
  s="$SRC/$rel"; d="$DST/$dest"
  payload_apply_entry "$s" "$d" "$([ "$FORCE" = true ] && echo force || echo apply)" >/dev/null
  classification="$PAYLOAD_RESULT_CLASSIFICATION"
  case "$classification" in
    same)
      same=$((same + 1))
      ;;
    overwrite)
      echo "  overwrite   $dest"; overwritten=$((overwritten + 1))
      ;;
    candidate|pending)
      if [ "$classification" = candidate ]; then
        candidate_created=$((candidate_created + 1))
      else
        candidate_reused=$((candidate_reused + 1))
      fi
      echo "  exists →    ${PAYLOAD_RESULT_PATH#"$DST"/}   ($PAYLOAD_RESULT_CANDIDATE_ACTION — merge by hand)"
      merge=$((merge + 1))
      ;;
    create)
      echo "  create      $dest"; created=$((created + 1))
      ;;
  esac
done
payload_upstream_write "$DST"

if [ -n "$source_origin" ]; then
  if [ -f "$DST/.agentic-flow-source" ]; then
    recorded_origin=$(sed -n '1s/^origin[[:space:]]*//p' "$DST/.agentic-flow-source")
    if [ "$recorded_origin" != "$source_origin" ]; then
      echo "  source      .agentic-flow-source preserved (recorded origin differs: $recorded_origin)"
    else
      echo "  source      .agentic-flow-source preserved"
    fi
  else
    if [ "$DRY" = false ]; then
      {
        printf 'origin %s\n' "$source_origin"
        printf 'ref %s\n' "$source_ref"
      } > "$DST/.agentic-flow-source"
    fi
    echo "  source      .agentic-flow-source ($source_origin @ $source_ref)"
  fi
else
  echo "  source      not recorded (source repo has no origin remote)"
fi

echo
echo "Summary: $created created, $overwritten overwritten, $merge to-merge, $same already up to date."
if [ "$merge" -gt 0 ]; then
  echo "         $candidate_created merge candidate(s) created, $candidate_reused already pending."
fi

# Seed the docs index in the target (best-effort; needs the markers in docs/README.md).
if [ "$DRY" = false ] && [ -x "$DST/scripts/docs-index.sh" ]; then
  if (cd "$DST" && ./scripts/docs-index.sh) >/dev/null 2>&1; then
    echo "Seeded docs index in target."
  else
    echo "Note: run scripts/docs-index.sh in the target once docs/README.md has the markers."
  fi
fi
if [ "$DRY" = false ] && { [ "$FORCE" = true ] || [ "$merge" -eq 0 ]; }; then
  payload_write_installation "$DST" "$MANIFEST"
fi
payload_stamp_version "$SRC" "$DST" "$merge"
if [ "$FORCE" = true ] || [ "$merge" -eq 0 ]; then
  echo "  installed   .agentic-flow-version ($version)"
else
  echo "  pending     .agentic-flow-candidate-version ($version)"
fi

if [ "$merge" -gt 0 ]; then
  echo
  echo "⚠ $merge file(s) already existed and differ — installed version was not advanced."
  echo "  Review the merge candidates, merge them into the active files, then export again:"
  echo "    find \"$DST\" -name '*.agentic-new*'"
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
