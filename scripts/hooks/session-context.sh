#!/usr/bin/env bash
# Advisory, offline context; errors and timeouts never fail a session.
set -uo pipefail

session_context() {
  command -v jq >/dev/null 2>&1 || return 1
  local root branch common doc spec match='' plan='' steps='' count=0 size cache selected step number state next
  root=$(git rev-parse --show-toplevel) || return 1
  cd "$root" || return 1
  branch=$(git symbolic-ref --quiet --short HEAD) || return 1
  [ "$branch" != main ] || return 1
  # shellcheck disable=SC1091 # Installed beside the hooks.
  . "$root/scripts/lib/brief.sh"
  for doc in docs/inprogress/*.md; do
    [ -f "$doc" ] || continue
    case "$doc" in *[!A-Za-z0-9_./-]*) return 1 ;; esac
    count=$((count + 1)); [ "$count" -le 100 ] || return 1
    size=$(wc -c < "$doc"); [ "$size" -le 1048576 ] || return 1
    # Unrelated product/analysis docs need not carry a plan block.
    grep -q '^```agentic-flow-plan$' "$doc" || continue
    spec=$(brief_parse "$doc" "$doc" local) || return 1
    [ "$(printf %s "$spec" | jq -r .branch)" = "$branch" ] || continue
    [ -z "$match" ] || return 1
    match=$doc
    plan=$(printf %s "$spec" | jq -r .id)
    steps=$(printf %s "$spec" | jq -r '.steps[].id')
  done
  [ -n "$match" ] || return 1
  common=$(git rev-parse --git-common-dir) || return 1
  cache="$common/agentic-flow/state/$plan.tsv"
  [ -f "$cache" ] || return 1
  size=$(wc -c < "$cache"); [ "$size" -le 65536 ] || return 1
  # shellcheck disable=SC2031 # brief_cmd uses a subshell-local root; this root is unchanged.
  brief_alerts "$root" "$plan"
  selected=$(jq -Rrse --arg steps "$steps" '
    ($steps|split("\n")) as $order |
    split("\n") | if .[-1]=="" then .[:-1] else . end |
    map(split("\t")) as $rows |
    if ($rows|length)>101 or ($rows|length)==0 or
       any($rows[]; length!=6 or (.[0]|test("^[1-9][0-9]*$")|not) or
         (.[1]|test("^[a-z0-9][a-z0-9._-]*$")|not) or
         (.[2]|test("^(executing|reviewing|approved|escalated|open|closing|closed)$")|not) or
         (.[3]|test("^[a-zA-Z0-9/._-]+$")|not) or
         (.[4]|test("^(none|[a-f0-9]{40})$")|not) or
         (.[5]|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")|not)) or
       ([$rows[][0]]|unique|length)!=($rows|length) or
       ([$rows[][1]]|unique|length)!=($rows|length) or
       any($rows[]; .[1] as $s | $s!="tracker" and ($order|index($s))==null) or
       any($order[]; . as $s | ([$rows[]|select(.[1]==$s)]|length)!=1)
    then error("invalid cache") else
      ([$order[] as $s | $rows[] | select(.[1]==$s and .[2]=="escalated")] +
       [$order[] as $s | $rows[] | select(.[1]==$s and .[2]!="approved" and .[2]!="closed")])[0]
      | select(.!=null) | @tsv
    end' "$cache") || return 1
  IFS=$'\t' read -r number step state _ <<< "$selected"
  case "$state" in
    escalated) next="scripts/agentic-flow handoff $number resume --as approver" ;;
    executing|reviewing) next="scripts/agentic-flow brief $match $step" ;;
    *) next="scripts/agentic-flow handoff $number reconcile" ;;
  esac
  printf 'Plan: %s\nDoc: %s\nOpen step: %s (#%s)\nState: %s (cached)\nNext command: %s\n' "$plan" "$match" "$step" "$number" "$state" "$next" |
    awk '{for(i=1;i<=NF;i++) {if(++n>120) exit; printf "%s%s",$i,(i==NF?"\n":" ")}}'
}

if [ "${1:-}" = --context ]; then
  session_context 2>/dev/null
  exit $?
fi
# Buffer output and bound all work, including slow filesystem/git helpers.
command -v perl >/dev/null 2>&1 || exit 0
context=$(perl -MPOSIX=setpgid -e '
  my $pid=fork(); defined($pid) or exit 1;
  if (!$pid) {setpgid(0,0); exec @ARGV; exit 1;}
  setpgid($pid,$pid);
  $SIG{ALRM}=sub {kill "KILL", -$pid; waitpid($pid,0); exit 1;};
  alarm 1; waitpid($pid,0); my $status=$?; alarm 0;
  exit(($status & 127) ? 1 : ($status >> 8));
' bash "$0" --context 2>/dev/null) && printf '%s\n' "$context"
exit 0
