#!/usr/bin/env bash
# Deterministic, offline role-context and self-test work report.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
FORMAT=text
EVENT_DIR=""
BASELINE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --format)
      [ "$#" -ge 2 ] || { echo 'missing --format value' >&2; exit 2; }
      FORMAT="$2"; shift 2 ;;
    --events)
      [ "$#" -ge 2 ] || { echo 'missing --events value' >&2; exit 2; }
      EVENT_DIR="$2"; shift 2 ;;
    --baseline)
      [ "$#" -ge 2 ] || { echo 'missing --baseline value' >&2; exit 2; }
      BASELINE="$2"; shift 2 ;;
    --root)
      [ "$#" -ge 2 ] || { echo 'missing --root value' >&2; exit 2; }
      ROOT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$FORMAT" in text|json) ;; *) echo "invalid output format: $FORMAT" >&2; exit 2 ;; esac

die() { echo "measure-harness: $*" >&2; exit 1; }
for file in CLAUDE.md AGENTS.md docs/MEMORY.md .agents/skills/review-execution/SKILL.md; do
  [ -f "$ROOT/$file" ] || die "missing bundle input: $file"
done

cleanup=""
if [ -z "$EVENT_DIR" ]; then
  EVENT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/harness-measure.XXXXXX")
  cleanup="$EVENT_DIR"
  trap 'rm -rf "$cleanup"' EXIT
  for mode in fast full; do
    : > "$EVENT_DIR/$mode.events"
    AGENTIC_MEASURE_EVENTS="$EVENT_DIR/$mode.events" \
      "$ROOT/scripts/self-test.sh" "--$mode" >/dev/null
  done
fi
for mode in fast full; do
  [ -f "$EVENT_DIR/$mode.events" ] || die "missing event input: $mode.events"
done

word_count() { wc -w < "$ROOT/$1" | tr -d ' '; }
planner_words=$(( $(word_count CLAUDE.md) + $(word_count docs/MEMORY.md) ))
executor_words=$(( $(word_count AGENTS.md) + $(word_count CLAUDE.md) + $(word_count docs/MEMORY.md) ))
reviewer_words=$(( $(word_count CLAUDE.md) + $(word_count .agents/skills/review-execution/SKILL.md) + $(word_count docs/MEMORY.md) ))
ceiling() { echo $(( (($1 + 99) / 100) * 100 )); }

count_event() { awk -v event="$2" '$0 == event { n++ } END { print n+0 }' "$1"; }
packet_words=$(awk -F: '$1 == "packet_words" { n=$2 } END { print n+0 }' "$EVENT_DIR/full.events")
[ "$packet_words" -gt 0 ] || die 'missing generated executor packet measurement'
[ "$packet_words" -le 800 ] || die "executor packet exceeds 800 words: $packet_words"
revision=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)

report=$(jq -n \
  --arg revision "$revision" \
  --argjson planner "$planner_words" --argjson executor "$executor_words" \
  --argjson reviewer "$reviewer_words" --argjson packet "$packet_words" \
  --argjson planner_ceiling "$(ceiling "$planner_words")" \
  --argjson executor_ceiling "$(ceiling "$executor_words")" \
  --argjson reviewer_ceiling "$(ceiling "$reviewer_words")" \
  --argjson fast_groups "$(awk -F: '$1 == "group" { seen[$2]=1 } END { for (x in seen) n++; print n+0 }' "$EVENT_DIR/fast.events")" \
  --argjson fast_export "$(count_event "$EVENT_DIR/fast.events" group:export)" \
  --argjson fast_upgrade "$(count_event "$EVENT_DIR/fast.events" group:upgrade)" \
  --argjson fast_paths "$(count_event "$EVENT_DIR/fast.events" path_directory_scan)" \
  --argjson fast_snapshots "$(count_event "$EVENT_DIR/fast.events" source_snapshot_copy)" \
  --argjson fast_trees "$(count_event "$EVENT_DIR/fast.events" fixture_tree_copy)" \
  --argjson fast_files "$(count_event "$EVENT_DIR/fast.events" fixture_file_copy)" \
  --argjson full_groups "$(awk -F: '$1 == "group" { seen[$2]=1 } END { for (x in seen) n++; print n+0 }' "$EVENT_DIR/full.events")" \
  --argjson full_snapshots "$(count_event "$EVENT_DIR/full.events" source_snapshot_copy)" \
  --argjson full_trees "$(count_event "$EVENT_DIR/full.events" fixture_tree_copy)" \
  --argjson full_files "$(count_event "$EVENT_DIR/full.events" fixture_file_copy)" \
  --argjson full_paths "$(count_event "$EVENT_DIR/full.events" path_directory_scan)" '
  {revision:$revision, measurement:"offline words and executed self-test events",
   roles:{
     planner:{files:["CLAUDE.md","docs/MEMORY.md"],static_files:2,static_words:$planner,generated_packet_words:0,ceiling:$planner_ceiling},
     executor:{files:["AGENTS.md","CLAUDE.md","docs/MEMORY.md"],static_files:3,static_words:$executor,generated_packet_words:$packet,ceiling:$executor_ceiling},
     reviewer:{files:["CLAUDE.md",".agents/skills/review-execution/SKILL.md","docs/MEMORY.md"],static_files:3,static_words:$reviewer,generated_packet_words:0,ceiling:$reviewer_ceiling}},
   workflows:{standard_step:{role_boots:3,handoffs:2,validation_groups:2},strict_step:{role_boots:3,handoffs:2,validation_groups:3}},
   verification:{
     fast:{fast_group_count:$fast_groups,fast_export_runs:$fast_export,fast_upgrade_runs:$fast_upgrade,path_directory_scans:$fast_paths,source_snapshot_copies:$fast_snapshots,fixture_tree_copies:$fast_trees,fixture_copied_files:$fast_files},
     full:{group_count:$full_groups,path_directory_scans:$full_paths,source_snapshot_copies:$full_snapshots,fixture_tree_copies:$full_trees,fixture_copied_files:$full_files}}}' )

if [ -n "$BASELINE" ]; then
  [ -f "$BASELINE" ] || die "missing baseline: $BASELINE"
  jq -e --argjson current "$report" '
    . as $baseline | all(["planner","executor","reviewer"][];
      . as $role | $baseline.roles[$role].ceiling >= $current.roles[$role].static_words)' "$BASELINE" >/dev/null \
    || die 'a role bundle exceeds its approved ceiling'
fi

if [ "$FORMAT" = json ]; then
  printf '%s\n' "$report" | jq -S .
else
  printf '%s\n' "$report" | jq -r '
    "revision: \(.revision)",
    (.roles | to_entries[] | "\(.key): \(.value.static_words) static words / \(.value.static_files) files [\(.value.files | join(", "))]; ceiling \(.value.ceiling); packet \(.value.generated_packet_words) words"),
    "fast: \(.verification.fast | tojson)", "full: \(.verification.full | tojson)"'
fi
