#!/usr/bin/env bash
# A packet may quote the findings source, but the file always keeps it intact.

packet_findings_error() { packet_error "findings-incomplete: $*"; return 13; }

packet_findings_source() { # plan issue admitted bounce comment JSON-file output-file
  local plan=$1 issue=$2 bounce=$3 comment=$4 output=$5 metadata seq head run
  metadata=$(jq -c '
    .body|split("\n") |
    if (.[0]|startswith("<!-- agentic-flow-transition:")) then
      [limit(1;range(1;length) as $i|select(.[$i]=="-->")|$i)] as $end |
      .[1:($end[0]//1)] | map(select(startswith("findings-complete=")))
    else [] end' "$comment") || return 1
  seq=$(printf '%s' "$bounce" | jq .seq)
  head=$(printf '%s' "$bounce" | jq -r .head)
  case "$metadata" in
    '[]') jq -c '[{body}]' "$comment" > "$output" || return 1 ;;
    '["findings-complete=true; findings-shown='*)
      jq -ce --argjson metadata "$metadata" '
        ($metadata|select(length==1)|.[0]|capture("^findings-complete=true; findings-shown=(?<shown>[0-9]+)/(?<total>[0-9]+)$")) as $m |
        [.body|split("\n")|.[1:(index("-->"))][]|select(startswith("findings-json: "))|ltrimstr("findings-json: ")] |
        select(length==1) | .[0]|@base64d|fromjson |
        select(type=="array" and length==($m.shown|tonumber) and $m.shown==$m.total)' "$comment" > "$output" || return 1 ;;
    '["findings-complete=false; findings-shown='*)
      jq -e 'length==1 and (.[0]|test("^findings-complete=false; findings-shown=[0-9]+/[0-9]+$"))' \
        <<< "$metadata" >/dev/null || return 1
      run=$(jq -er '
        [.body|split("\n")[]|select(startswith("agentic-flow-run: "))] |
        select(length==1)|.[0]|capture("^agentic-flow-run: run=(?<id>[a-zA-Z0-9/._-]+); host=[a-zA-Z0-9._-]+$").id' "$comment") || return 1
      ledger_init "$PWD" && ledger_read "$plan" > "$output.ledger" || return 1
      jq -ce --arg run "$run" --arg head "$head" --argjson issue "$issue" --argjson seq "$seq" --argjson metadata "$metadata" '
        ($metadata[0]|capture("findings-shown=(?<shown>[0-9]+)/(?<total>[0-9]+)$")) as $m |
        select(($m.shown|tonumber)<=($m.total|tonumber)) |
        select(any(.[]; .kind=="intent" and .run==$run and .issue==$issue and .seq_before==($seq-1) and .station=="reviewer")) |
        [.[]|select(.kind=="station" and .run==$run and .exit==0 and .invalid_reason==null and
          .result.outcome=="bounce" and .result.head==$head)] |
        select(length==1)|.[0].result.findings|select(length==($m.total|tonumber))' "$output.ledger" > "$output" || return 1 ;;
    *) return 1 ;;
  esac
  jq -e 'type=="array" and length>0 and length<=100 and all(.[];
    (.body|type)=="string" or (keys==["file","line","severity","text"] and
    (.severity|IN("P1","P2","P3")) and (.file|type)=="string" and (.text|type)=="string" and
    (.line==null or (.line|type)=="number")))' "$output" >/dev/null
}

packet_findings_publish() ( # source-file destination-file [station-scratch]
  local source=$1 dest=$2 scratch=${3:-} staged='' published hash copied count
  umask 077
  trap 'if [ -n "$staged" ]; then rm -f "$staged"; fi' EXIT
  mkdir -p "${dest%/*}" || return 1
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    [ -f "$dest" ] && [ ! -L "$dest" ] || return 1
  fi
  staged=$(mktemp "${dest%/*}/.findings.XXXXXX") || return 1
  cat "$source" > "$staged" && mv -f "$staged" "$dest" || return 1
  hash=$(shasum -a 256 < "$source") || return 1
  published=$(shasum -a 256 < "$dest") || return 1
  [ "${hash%% *}" = "${published%% *}" ] || return 1
  count=$(jq length "$source") || return 1
  if [ -n "$scratch" ]; then
    cp "$dest" "$scratch/findings.json" || return 1
    dest="$scratch/findings.json"
    copied=$(shasum -a 256 < "$dest") || return 1
    [ "${hash%% *}" = "${copied%% *}" ] || return 1
  fi
  jq -nc --arg file "$dest" --arg sha "${hash%% *}" --argjson count "$count" \
    '{path:$file,count:$count,sha256:$sha}'
)

packet_findings_index() { # full source, words remaining in packet -> bounded lines
  jq -c --argjson available "$2" '
    def words: [scan("\\S+")];
    def flat: gsub("\\s+";" ");
    length as $n | ([$available,1200]|min) as $cap |
    map(if has("body") then "Review note — "+(.body|words|.[0:25]|join(" "))
        else "\(.severity) \((.file+":"+(.line//"?"|tostring))|flat|.[0:120]) — \(.text|words|.[0:25]|join(" "))" end) |
    reduce .[] as $row ({index:[],words:0,cut:false};
      ($row|words|length) as $cost |
      if .cut or .words+$cost>($cap-12) then .cut=true
      else .index+=[$row] | .words+=$cost end) |
    .index+(if .cut then ["index shows \(.index|length) of \($n); read the file for all"] else [] end)' "$1"
}
