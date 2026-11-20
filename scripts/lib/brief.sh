#!/usr/bin/env bash
# Strict, offline parsing shared by the plan and station commands.
brief_normalize() { # stdin; preserve every byte outside the bookkeeping lines
  local line ending tracker=false status=false
  while :; do
    ending=$'\n'
    if ! IFS= read -r line; then
      [ -n "$line" ] || break
      ending=''
    fi
    case "$line" in
      '> **Type:** '*' · **Status:** '*) continue ;;
      '## Tracker') tracker=true; continue ;;
      '## '*|'# '*|'---') tracker=false ;;
    esac
    [ "$tracker" = false ] || continue
    case "$line" in
      '## Status'|'## Implementation status'|'## Status / Implementation status') status=true ;;
      '## '*|'# '*) status=false ;;
    esac
    if [ "$status" = true ]; then
    case "$line" in
      '- **Evidence schema:** '*|'- **Tracking issue:** '*|'- **Approval:** '*|\
      '- **Implementation head:** '*|'- **Implementation PR:** '*|\
      '- **Verification evidence:** '*|'- **Review verdict:** '*|'- **Memory:** '*) continue ;;
    esac
    fi
    printf '%s%s' "$line" "$ending"
  done
}

# Issue layout keeps Markdown that the canonical spec omits. The writer
# removes it before hashing so previously approved specs keep their identity.
brief_parse() { # file, display path, revision, optional issue-layout -> JSON spec
  awk -v path="$2" -v rev="$3" -v issue_layout="${4:-}" '
    function bad(message) {print path ":" NR ": " message > "/dev/stderr"; failed=1; exit 1}
    function quote(s) {gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/\t/,"\\t",s); gsub(/\r/,"\\r",s); gsub(/\n/,"\\n",s); return "\"" s "\""}
    function trim(s) {sub(/\n+$/,"",s); return s}
    function layout_trim(s) {
      s=trim(s)
      while (sub(/\n---$/,"",s)) s=trim(s)
      return s
    }
    issue_layout!="" {
      if (!layout_fence && /^## Verification commands$/) layout_verify=1
      else if (layout_verify) {
        if (!layout_fence && /^##? /) layout_verify=0
        else {
          layout_verification=layout_verification $0 "\n"
          if (match($0,/^(````*|~~~~*)/)) {
            fence=substr($0,1,RLENGTH)
            if (!layout_fence) layout_fence=fence
            else if (index(fence,layout_fence)==1 && substr($0,RLENGTH+1) ~ /^[ \t]*$/) layout_fence=""
          }
        }
      }
    }
    /^##? / {verify=0}
    /^# Part B / {part=1}
    /^```agentic-flow-plan$/ {if (++blocks>1 || !part) bad("expected one plan block in Part B"); block=1; next}
    block && /^```$/ {block=0; next}
    block {
      key=$0; sub(/:.*/,"",key); value=$0; sub(/^[^:]*: /,"",value)
      if (key !~ /^(id|profile|tracking|branch|base|steps)$/ || value==$0 || value=="") bad("invalid plan field")
      if (key in plan) bad("duplicate plan field " key)
      plan[key]=value; next
    }
    part && /^## [A-Za-z0-9][A-Za-z0-9._-]* — / {
      id=tolower($2); if (id in heading) bad("duplicate step " id)
      heading[id]=substr($0,4); order[++sections]=id; active=""; layout_active=""; next
    }
    part && /^##? / {id=""; active=""; layout_active=""}
    id!="" && /^\*\*Red-first:\*\*/ {
      value=$0; sub(/^\*\*Red-first:\*\* /,"",value)
      if (value!="none" && value !~ /^`[^`]+` — [A-Za-z0-9_.\/-]+( [A-Za-z0-9_.\/-]+)*$/) bad("malformed Red-first line")
      if ((value=="none" && red[id]) || none[id]) bad("conflicting Red-first lines")
      red[id]++; if(value=="none") none[id]=1
      else {
        selector=value; sub(/^`/,"",selector); sub(/` — .*/,"",selector)
        paths=value; sub(/^`[^`]+` — /,"",paths)
        n=split(paths,p," ")
        for(k=1;k<=n;k++) if(p[k] ~ /^\// || p[k] ~ /(^|\/)\.\.(\/|$)/) bad("Red-first path must stay inside the repository")
        selectors[id,red[id]]=selector; redpaths[id,red[id]]=paths
      }
      active=""; layout_active=""; next
    }
    id!="" && /^\*\*[^*]+:\*\*/ {
      active=""; layout_active=""; label=$0; sub(/^\*\*/,"",label); sub(/:\*\*.*/,"",label)
      if (label ~ /^(DoD|Verify|Risks)$/) {
        if ((id SUBSEP label) in fields) bad("duplicate " label " for " id)
        value=$0; sub(/^\*\*[^*]+:\*\*( |$)/,"",value)
        if (value==$0 || (value=="" && label!="Risks")) bad("empty " label)
        fields[id,label]=value; active=label
        if (label=="Risks" && value=="") bullet_risks[id]=1
        if (issue_layout!="" && label!="Risks") {layout_active=label; layout_fields[id,label]=value}
      }
      next
    }
    id!="" && layout_active!="" {layout_fields[id,layout_active]=layout_fields[id,layout_active] "\n" $0}
    id!="" && active=="Risks" && bullet_risks[id] && $0!="---" {
      if ($0 ~ /^[-+*][ \t]+[^ \t]/) {
        value=$0; sub(/^[-+*][ \t]+/,"",value)
        fields[id,"Risks"]=fields[id,"Risks"] (fields[id,"Risks"]=="" ? "" : "\n") "- " value
      } else if (fields[id,"Risks"]!="" && ($0=="" || $0 ~ /^  /)) {
        fields[id,"Risks"]=fields[id,"Risks"] "\n" $0
      } else if ($0!="") bad("expected a Risks bullet")
      next
    }
    id!="" && active!="" {
      if ($0=="---") {active=""; next}
      fields[id,active]=fields[id,active] "\n" $0
    }
    /^## Verification commands$/ {verify=1; next}
    verify && /^```/ {next}
    verify && $0!="" {verification=verification $0 "\n"}
    END {
      if (failed) exit 1
      if (layout_fence) bad("unclosed verification fence")
      if (block || blocks!=1) bad("missing or unclosed plan block")
      if (plan["id"] !~ /^[a-z0-9][a-z0-9._-]*$/ || length(plan["id"])>80) bad("invalid plan id")
      if (plan["profile"]!="strict" && plan["profile"]!="standard") bad("invalid profile")
      if (plan["branch"]=="" || plan["steps"]=="") bad("missing branch or steps")
      if ((plan["profile"]=="strict") != (plan["tracking"]!="")) bad("tracking is required only for Strict")
      count=split(plan["steps"],steps," ")
      if (count>100 || (plan["profile"]=="standard" && count!=1)) bad("invalid step count")
      for(i=1;i<=count;i++) {
        step=steps[i]
        if(step !~ /^[a-z0-9][a-z0-9._-]*$/ || length(step)>80 || seen[step]++) bad("invalid or duplicate step id " step)
        if(!(step in heading)) bad("no section for " step)
        if(!red[step]) bad("missing Red-first for " step)
        if(fields[step,"DoD"]=="" || fields[step,"Verify"]=="" || fields[step,"Risks"]=="") bad("missing DoD, Verify or Risks for " step)
      }
      for(i=1;i<=sections;i++) if(!(order[i] in seen)) bad("section has no steps entry: " order[i])
      printf "{\"id\":%s,\"profile\":%s,\"branch\":%s,\"labels\":[\"plan\"],",quote(plan["id"]),quote(plan["profile"]),quote(plan["branch"])
      if(plan["base"]!="") printf "\"base\":%s,",quote(plan["base"])
      if(plan["profile"]=="strict") printf "\"tracking\":{\"title\":%s},",quote(plan["tracking"])
      printf "\"steps\":["
      for(i=1;i<=count;i++) {
        step=steps[i]; if(i>1) printf ","
        printf "{\"id\":%s,\"title\":%s,\"labels\":[\"agent:codex\",\"needs-execution\"],\"packet\":{",quote(step),quote(heading[step])
        printf "\"brief\":%s,\"definition_of_done\":%s,\"verification\":%s,\"risks\":%s}",quote(path "@" rev "#" heading[step]),quote(trim(fields[step,"DoD"])),quote(trim(fields[step,"Verify"]) "\n" trim(verification)),quote(trim(fields[step,"Risks"]))
        printf ",\"red_first\":"
        if(none[step]) printf "\"none\""
        else {
          printf "["
          for(j=1;j<=red[step];j++) {
            if(j>1) printf ","
            printf "{\"selector\":%s,\"paths\":[",quote(selectors[step,j])
            n=split(redpaths[step,j],p," ")
            for(k=1;k<=n;k++) {if(k>1) printf ","; printf "%s",quote(p[k])}
            printf "]}"
          }
          printf "]"
        }
        printf "}"
      }
      printf "]"
      if (issue_layout=="issue-layout") {
        printf ",\"issue_layout\":{\"verification_commands\":%s,\"steps\":{",quote(layout_trim(layout_verification))
        for (i=1;i<=count;i++) {
          step=steps[i]; if (i>1) printf ","
          printf "%s:{\"definition_of_done\":%s,\"verify\":%s,\"bullet_risks\":%s}",quote(step),quote(layout_trim(layout_fields[step,"DoD"])),quote(layout_trim(layout_fields[step,"Verify"])),(bullet_risks[step] ? "true" : "false")
        }
        printf "}}"
      }
      print "}"
    }
  ' "$1"
}

brief_approval() { # file -> approved revision and human identity (tab-separated)
  local line re
  line=$(sed -n 's/^- \*\*Approval:\*\* //p' "$1")
  re='^status=approved; by=([A-Za-z0-9]([A-Za-z0-9._ -]*[A-Za-z0-9])?); at=[0-9]{4}-[0-9]{2}-[0-9]{2}; rev=([a-f0-9]{40})$'
  [[ "$line" =~ $re ]] || { echo 'Approval requires status=approved and rev=<sha40>' >&2; return 1; }
  printf '%s\t%s\n' "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}"
}

brief_approved_at_head() { # repository-relative doc path, revision
  local doc=$1 rev=$2 current approved commit previous changed
  if ! git cat-file -e "$rev^{commit}" 2>/dev/null || ! git merge-base --is-ancestor "$rev" HEAD; then
    echo "approval is for $rev; revision is missing or not an ancestor: re-approve" >&2; return 1;
  fi
  current=$(git show "HEAD:$doc" | brief_normalize | git hash-object --stdin) || return 1
  approved=$(git show "$rev:$doc" | brief_normalize | git hash-object --stdin) || return 1
  [ "$current" != "$approved" ] || return 0
  previous=$approved
  changed=HEAD
  while IFS= read -r commit; do
    current=$(git show "$commit:$doc" | brief_normalize | git hash-object --stdin) || return 1
    if [ "$current" != "$previous" ]; then changed=$commit; break; fi
  done < <(git rev-list --reverse "$rev..HEAD" -- "$doc")
  echo "approval is for $rev; the plan changed at $changed: re-approve" >&2
  return 1
}

brief_alerts() { # root plan; advisory offline cache only, never raw comment text
  local common cache
  common=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return 0
  case "$common" in /*) ;; *) common="$1/$common" ;; esac
  cache="$common/agentic-flow/state/$2.holds.json"
  if [ -f "$cache" ] && [ "$(wc -c < "$cache")" -le 65536 ]; then
    jq -r 'if type=="array" and length<=100 then .[] |
      select((.id|test("^[a-z0-9][a-z0-9._-]*/hold/[0-9]+$")) and
        (.reason|test("^[a-z0-9-]{1,80}$")) and (.issue|type)=="number") |
      "Open hold: \(.id) #\(.issue) \(.reason) (cached)" else empty end' "$cache" 2>/dev/null || true
  fi
  cache="$common/agentic-flow/state/$2.tsv"
  if [ -f "$cache" ] && [ "$(wc -c < "$cache")" -le 65536 ]; then
    awk -F '\t' 'NF==6 && $1~/^[0-9]+$/ && $2~/^[a-z0-9._-]+$/ && $3=="escalated" {print "Escalated: #" $1 " " $2 " (cached)"}' "$cache"
  fi
  return 0
}

brief_cmd() ( # <doc> <step-id> [--at <sha>] [--analysis]
  [ "$#" -ge 2 ] || { echo 'usage: agentic-flow brief <doc> <step-id> [--at <sha>] [--analysis]' >&2; return 2; }
  local show_alerts=true
  local doc=$1 step=$2 rev='' analysis=false root tmp approval spec heading
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --at) show_alerts=false; [ "$#" -ge 2 ] || return 2; rev=$2; shift 2 ;;
      --analysis) analysis=true; shift ;;
      *) echo "unknown brief flag: $1" >&2; return 2 ;;
    esac
  done
  root=$(git rev-parse --show-toplevel) || return 2
  cd "$root" || return 2
  case "$doc" in ''|/*|../*|*/../*|*/..) echo 'brief path must be repository-relative' >&2; return 2 ;; esac
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/agentic-flow-brief.XXXXXX") || return 2
  trap 'rm -rf "$tmp"' EXIT
  if [ -z "$rev" ]; then
    git show "HEAD:$doc" > "$tmp/head" || return 2
    approval=$(brief_approval "$tmp/head") || return 2
    rev=${approval%%$'\t'*}
  fi
  rev=$(git rev-parse --verify --end-of-options "$rev^{commit}") || return 2
  git show "$rev:$doc" > "$tmp/doc" || return 2
  spec=$(brief_parse "$tmp/doc" "$doc" "$rev") || return 2
  heading=$(printf '%s' "$spec" | jq -er --arg step "$step" '.steps[] | select(.id==$step) | .title') \
    || { echo "unknown step: $step" >&2; return 2; }
  [ "$show_alerts" = false ] || brief_alerts "$root" "$(printf '%s' "$spec" | jq -r .id)"
  BRIEF_SLICE_HEADING="$heading" awk -v analysis="$analysis" '
    BEGIN {heading=ENVIRON["BRIEF_SLICE_HEADING"]}
    /^# / {
      if (!title++) {print; next}
      if (/^# Part A /) {part="a"; if(analysis=="true") print; next}
      if (/^# Part B /) {part="b"; emit=0; next}
      part=""; emit=0; next
    }
    part=="a" {if(analysis=="true") print; next}
    part=="b" && /^## / {
      section=substr($0,4)
      emit=(section==heading || section=="Branch" || section ~ /^Word ceilings/ ||
            section ~ /^Definition of done/ || section=="Verification commands")
    }
    part=="b" && emit {print}
  ' "$tmp/doc"
)
