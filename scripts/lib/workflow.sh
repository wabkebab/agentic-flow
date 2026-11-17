#!/usr/bin/env bash
# Source, then workflow_load <project-root>. Queries use only the validated snapshot.
workflow_load() {
  local file="$1/config/workflow.tsv" parsed
  WORKFLOW_DATA=''
  [ -f "$file" ] || { echo "$file:1: missing workflow" >&2; return 1; }
  # A small data contract, never executable shell. Bound both input and graph work.
  [ "$(wc -c < "$file")" -le 65536 ] || {
    echo "$file:1: workflow exceeds 65536 bytes" >&2; return 1;
  }
  parsed=$(awk -F '\t' '
    function bad(line, message) {
      print FILENAME ":" line ": " message > "/dev/stderr"; failed=1; exit 1
    }
    function topology(t) { return t == "step-strict" || t == "work-standard" || t == "tracker" }
    function tokens(value, allowed, what,    a,n,i,seen) {
      n=split(value,a,",")
      for (i=1;i<=n;i++) {
        if (a[i] == "" || index(allowed,"|" a[i] "|") == 0) bad(NR,"unknown " what ": " a[i])
        if (seen[a[i]]++) bad(NR,"duplicate " what ": " a[i])
      }
    }
    NR > 256 { bad(NR,"workflow exceeds 256 lines") }
    /^#/ || /^$/ { next }
    {
      if (($1 == "state" && NF != 5) || ($1 == "transition" && NF != 7)) bad(NR,"invalid tab-separated fields")
      if ($1 != "state" && $1 != "transition") bad(NR,"unknown kind or non-tab-separated fields")
      for (i=1;i<=NF;i++) if ($i == "") bad(NR,"empty fields")
      if (!topology($2)) bad(NR,"unknown topology")
      data[++count]=$0
      if ($1 == "state") {
        if ($3 !~ /^[a-z][a-z-]*$/) bad(NR,"invalid state")
        key=$2 SUBSEP $3
        if (key in states) bad(NR,"duplicate state")
        states[key]=NR; labels[key]=$4
        if ($4 != "-") tokens($4,"|plan|agent:claude|agent:codex|agent:opencode|needs-review|needs-execution|needs-closing|needs-human|","label")
        if ($5 != "open" && $5 != "closed") bad(NR,"invalid issue status")
      } else {
        roles["submit"]="executor"; roles["bounce"]="reviewer"; roles["resume"]="approver"
        roles["approve"]="reviewer"; roles["notify"]="reviewer"; roles["close"]="approver"
        roles["ask"]=$4
        if (!($3 in roles)) bad(NR,"unknown event")
        if (($3=="ask" && !(($4=="executor" && $5=="executing") || ($4=="reviewer" && $5=="reviewing"))) || $4 != roles[$3]) bad(NR,"invalid role for event")
        if ($5 == $6) bad(NR,"self-loop transition")
        tokens($7,"|-|head|head≠last-bounced-head|findings|bounces<2|bounces=2|note|head=submitted|all-steps-approved|lifecycle-ready|question|return=executing|return=reviewing|","requirement")
        if ($3 == "bounce" && $7 != "findings,bounces<2" && $7 != "findings,bounces=2") bad(NR,"invalid bounce requirement")
        expected["submit"]="head,head≠last-bounced-head"; expected["resume"]="note"
        expected["approve"]="head=submitted"; expected["notify"]="all-steps-approved"; expected["close"]="lifecycle-ready"
        expected["ask"]="question"
        if ($3=="resume" && $7!="note,return=" $6) bad(NR,"invalid resume requirement")
        if ($3 != "bounce" && $3 != "resume" && $7 != expected[$3]) bad(NR,"invalid event requirement")
        guard=($3 == "bounce" || $3 == "resume" ? $7 : "-")
        key=$2 SUBSEP $5 SUBSEP $3 SUBSEP guard
        if (key in transitions) bad(NR,"duplicate transition")
        transitions[key]=NR
        t[++nt]=$2; from[nt]=$5; to[nt]=$6; lines[nt]=NR
      }
    }
    END {
      if (failed) exit 1
      for (i=1;i<=nt;i++) {
        if (!((t[i] SUBSEP from[i]) in states) || !((t[i] SUBSEP to[i]) in states)) bad(lines[i],"unknown state in transition")
      }
      roots["step-strict"]="executing"; roots["work-standard"]="executing"; roots["tracker"]="open"
      for (top in roots) {
        key=top SUBSEP roots[top]
        if (!(key in states)) bad(1,"missing initial state for " top)
        reachable[key]=1
      }
      # At most one state is discovered per pass, bounded by the validated row cap.
      for (pass=1;pass<=count;pass++) {
        changed=0
        for (i=1;i<=nt;i++) if (reachable[t[i] SUBSEP from[i]] && !reachable[t[i] SUBSEP to[i]]) {
          reachable[t[i] SUBSEP to[i]]=1; changed=1
        }
        if (!changed) break
      }
      for (key in states) if (!reachable[key]) bad(states[key],"unreachable state")
      for (i=1;i<=count;i++) print data[i]
    }
  ' "$file") || return 1
  WORKFLOW_DATA=$parsed
}

workflow_state_labels() {
  [ -n "${WORKFLOW_DATA:-}" ] || return 1
  printf '%s\n' "$WORKFLOW_DATA" | awk -F '\t' -v t="$1" -v s="$2" '
    $1 == "state" && $2 == t && $3 == s { print $4; found=1 }
    END { if (!found) exit 1 }
  '
}

workflow_successor() { # topology state event bounces; caller enforces other requirements
  [ -n "${WORKFLOW_DATA:-}" ] || return 1
  case "$4" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$WORKFLOW_DATA" | awk -F '\t' -v t="$1" -v s="$2" -v e="$3" -v b="$4" -v r="${5:-executing}" '
    $1 == "transition" && $2 == t && $3 == e && $5 == s {
      if (e == "bounce" && !(($7 == "findings,bounces<2" && b+0 < 2) || ($7 == "findings,bounces=2" && b+0 == 2))) next
      if (e == "resume" && $6 != r) next
      print $6; found=1
    }
    END { if (!found) exit 1 }
  '
}

workflow_labels() {
  [ -n "${WORKFLOW_DATA:-}" ] || return 1
  printf '%s\n' "$WORKFLOW_DATA" | awk -F '\t' '
    $1 == "state" && $4 != "-" { n=split($4,a,","); for (i=1;i<=n;i++) if (a[i] != "plan") labels[a[i]]=1 }
    END { for (label in labels) print label }
  ' | LC_ALL=C sort
}
