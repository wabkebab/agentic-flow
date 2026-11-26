include "journal-marker";

def one_of($values): . as $v | $values | index($v) != null;
def uint($max): type == "number" and . >= 0 and . <= $max and floor == .;
def issue_number: uint(9999999999) and . > 0;
def identifier: type == "string" and test("\\A[a-z0-9][a-z0-9._-]{0,79}\\z");
def timestamp: type == "string" and test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\z")
  and (try (fromdateiso8601 | todateiso8601) catch null) == .;
def epoch: if type == "number" then . else fromdateiso8601 end;
def seconds_since: [0, ((now | floor) - epoch)] | max;
def time_value: uint(4000000000000) or timestamp;
def doc_path:
  type == "string" and test("\\Adocs/(inprogress|done)(/[A-Za-z0-9_.-]+)+\\.md\\z")
  and (split("/") | all(. != "." and . != ".."));

def valid(ok):
  if .state == "ok" then
    if (try (.value | ok) catch false) then . else {state:"missing"} end
  else . end;
def json_source:
  if .state == "ok" then try {state:"ok", value:(.raw | fromjson)} catch {state:"missing"}
  else . end;

def pid_start: type == "object" and (.pid | uint(2147483647) and . > 0)
  and (.start | type == "string" and length > 0);
def host_id: type == "string" and test("\\A[a-f0-9]{12}\\z");
def lock_owner($claimant):
  pid_start and ($claimant or ((.host | host_id) and (.run | type == "string" and length > 0)));
def heartbeat($plan):
  pid_start and .v == 1 and .plan == $plan and (.doc | doc_path)
  and (.host | host_id) and (.run | type == "string" and length > 0)
  and (.ownership | one_of(["owner", "recovering"]))
  and (.turn | uint(1000000000)) and (.turn_cap | uint(1000000000) and . > 0)
  and (.updated_at | time_value)
  and (if .phase == "waiting-human" then (.waiting | type == "object")
       else has("waiting") and .waiting == null end)
  and (if .phase == "station" then
    (.station | type == "object" and (.issue | issue_number) and (.step | identifier)
      and (.station | one_of(["executor", "reviewer"]))
      and (.cli | one_of(["claude", "codex", "opencode"]))
      and (.run | type == "string" and length > 0) and (.started | time_value)
      and (.timeout_s | uint(1000000000) and . > 0)) and has("exit") and .exit == null
  elif .phase == "stopped" then has("station") and .station == null and (.exit | uint(255))
  else (.phase | one_of(["reconciling", "waiting-human"]))
    and has("station") and .station == null and has("exit") and .exit == null
  end);

def parse_steps:
  if .state != "ok" then . else
    (.raw | sub("\n$";"") | split("\n") | if . == [""] then [] else . end) as $lines |
    if ($lines | length) > 200 then {state:"over_limit"}
    else
      [$lines[] | split("\t")] as $rows |
      if all($rows[]; length == 6 and (.[0] | test("\\A[1-9][0-9]{0,9}\\z"))
          and (.[1] | identifier)
          and (.[2] | one_of(["executing","reviewing","escalated","approved","open","closing","closed"]))
          and (.[3] | length > 0 and length <= 512)
          and (.[4] | test("\\A(none|[a-f0-9]{40})\\z"))
          and (.[5] | timestamp))
        and ([$rows[][0]] | length == (unique | length))
        and ([$rows[][1]] | length == (unique | length))
      then {state:"ok", value:[$rows[] | {issue:(.[0]|tonumber),step:.[1],state:.[2],latest:.[3],at:.[5]}]}
      else {state:"missing"} end
    end
  end;

def with_cap(entries; $max):
  if .state == "ok" and (try (.value | entries | type == "array" and length > $max) catch false)
  then {state:"over_limit"} else . end;

def metrics($plan):
  json_source | with_cap(.rows; 200) | valid(
    type == "object" and .v == 1 and .plan == $plan and (.refreshed_at | timestamp)
    and (.rows | type == "array" and length == (unique_by(.issue) | length))
    and all(.rows[];
      .issue as $issue | .step as $step |
      ($issue | issue_number) and ($step | identifier)
      and (.topology | one_of(["step-strict","work-standard","tracker"]))
      and (.state | one_of(["executing","reviewing","escalated","approved","open","closing","closed"]))
      and (.events | type == "array" and length <= 100 and length == (unique_by(.id) | length))
      and all(.events[];
        (.event | one_of(["submit","bounce","resume","approve","notify","close","ask"]))
        and (.role | one_of(["executor","reviewer","approver"]))
        and (.at == null or (.at | timestamp))
        and (.event as $event | .id | type == "string" and
          (split("/") | length == 4 and .[0] == $plan and .[1] == $step
            and (.[2] | test("\\A[1-9][0-9]{0,8}\\z")) and .[3] == $event)))));
def holds($plan):
  json_source | with_cap(.; 100) | valid(
    type == "array" and length == (unique_by(.id) | length)
    and all(.[]; (.issue | issue_number) and (.reason | type == "string")
      and (.id | type == "string" and startswith($plan + "/hold/")
        and (split("/") | length == 3 and (.[2] | test("\\A[1-9][0-9]{0,5}\\z"))))));

# Summarize a validated ledger in a single pass. Never infer liveness from an intent alone.
def ledger_view:
  reduce .[] as $r ({open:{}, newest:{}, ended:{}, cost_usd:null};
    if $r.kind == "intent" then
      .open[$r.run] = ($r | {issue,step,cli,run,station,chain,started}) | .newest[$r.chain] = $r.run
    elif $r.kind == "station" then
      del(.open[$r.run]) | .cost_usd += $r.usage.cost_usd
    elif $r.kind == "end" then .ended[$r.chain] = true
    else . end)
  | . as $ledger
  | {cost_usd, runs: ([.open[] | .eligible = (.run == $ledger.newest[.chain] and $ledger.ended[.chain] == null)]
      | group_by(.issue) | map({key:(.[0].issue | tostring), value:.}) | from_entries)};

def status_ledger:
  # ledger_read may precede its single compact JSON line with a torn-tail warning.
  (split("\n") | map(select(startswith("["))) | first) as $records |
  if $records != null then {state:"ok", value:($records | fromjson | ledger_view)}
  elif contains("ledger: ledger lock timed out\n") then {state:"busy"}
  else {state:"error"} end;

def workflow_rules:
  split("\n") | map(split("\t")) | {
    states:(map(select(.[0] == "state")) | group_by(.[1]) |
      map({key:.[0][1], value:map(.[2])}) | from_entries)
  };

def controller_view($heartbeat; $state):
  $heartbeat | {state:$state, pid, phase, turn, turn_cap, updated_at, exit};

def next_action($owner; $action; $command):
  {owner:$owner, action:$action, command:$command};

def plan_view($plan; $doc):
  # The inputs are framed by the reader and already validated at each source.
  if length != 10 then error("incomplete status inputs") else . end |
  . as [$plan_src,$heartbeat,$owner,$claimant,$steps,$holds,$metrics,$workflow,$ledger,$controller] |
  ($plan_src.value.policy // journal_legacy_pin | journal_pin | .max_bounces) as $limit |
  (if $plan_src.value.profile == "strict" or
    ($plan_src.value == null and any($steps.value[]?; .step == "tracker"))
    then "step-strict" else "work-standard" end) as $topology |
  ($plan_src.value.steps // [] | map(.id)) as $planned |
  ($planned + if $topology == "step-strict" then ["tracker"] else [] end) as $expected |
  [($steps.value // [])[] |
    .topology = (if .step == "tracker" and $topology == "step-strict" then "tracker" else $topology end) |
    .topology as $row_topology |
    select(($plan_src.state != "ok" or (.step | one_of($expected))) and
      (.state | one_of($workflow.states[$row_topology] // [])))] as $rows |
  ($steps.state == "ok" and $plan_src.state == "ok" and
    ([$rows[].step] | sort) == ($expected | sort) and ($steps.value | length) == ($expected | length)) as $steps_ok |
  ($holds.state == "ok" and all($holds.value[]; .issue | one_of([$rows[].issue]))) as $holds_ok |
  [$holds.value[]? | select($holds_ok) | {id, issue, reason,
    command:("agentic-flow hold clear " + $doc + " " + .id)}] as $open_holds |
  ($metrics.value.rows // [] | map({key:(.issue|tostring), value:.}) | from_entries) as $evidence |
  [$rows[] | select(.state == "escalated") | . as $row |
    (($evidence[.issue|tostring] | select(.step == $row.step and .topology == $row.topology) | .events[-1]) // null) as $last |
    {issue, step, by:(if $last.id == .latest and ($last.event | one_of(["ask","bounce"])) then $last.role else null end),
     return_state:(if $last.id != .latest then null
       elif $last.event == "ask" and $last.role == "reviewer" then "reviewing"
       elif ($last.event == "ask" and $last.role == "executor") or ($last.event == "bounce" and $last.role == "reviewer") then "executing"
       else null end),
     command:("agentic-flow handoff " + (.issue|tostring) + " resume --as approver --body-file decision.md")}
  ] as $escalations |
  [$rows[] | . as $row |
    ($evidence[.issue|tostring] | if .step == $row.step and .topology == $row.topology then [.events[] | select(.event == "bounce")] | length else null end) as $bounces |
    ($ledger.value.runs[.issue|tostring] // [] | map(select(.step == $row.step))) as $runs |
    ($heartbeat.value.station) as $beat |
    ([$runs[] | select($controller.state == "alive" and $controller.phase == "station" and
      .eligible and .run == $beat.run and .issue == $beat.issue and .step == $beat.step and
      .station == $beat.station and .cli == $beat.cli and .started == $beat.started)] | first) as $active |
    {issue, step, state, bounces:$bounces, bounce_limit:(if .topology=="tracker" then null else $limit end),
     station:(if $active == null then null else ($active | {cli, run,
       elapsed_s:(.started | seconds_since), timeout_s:$beat.timeout_s}) end),
     interrupted:(if $ledger.state != "ok" then null else [$runs[] | select(.run != $active.run) | .run] end)}
  ] as $view_steps |
  ({plan:$plan_src, heartbeat:$heartbeat, owner:$owner, claimant:$claimant, steps:$steps, holds:$holds, metrics:$metrics}
   | to_entries | map(select(.value.state == "over_limit") | .key)) as $oversized |
  ([if $plan_src.state != "ok" and $plan_src.state != "over_limit" then "plan" else empty end,
    if ($steps_ok|not) and $steps.state != "over_limit" then "steps" else empty end,
    if ($holds_ok|not) and $holds.state != "over_limit" then "holds" else empty end,
    if $metrics.state == "missing" then "metrics" else empty end]) as $missing |
  ($steps_ok and $holds_ok and ($oversized | length == 0)) as $complete |
  ($rows | map(select(.topology != "step-strict")) | first | .state) as $plan_state |
  ($controller.state | one_of(["alive","recovering"])) as $live |
  ($view_steps | any(.station != null)) as $working |
  ($view_steps | if length > 100 and any(.[100:][]; .station != null)
    then .[:99] + [.[100:][] | select(.station != null)] else .[:100] end) as $shown_steps |
  (if $holds_ok and ($open_holds|length) > 0 then
    $open_holds[0] | next_action("human"; "Read the hold note on #\(.issue), then clear the hold"; .command)
  elif $steps_ok and $holds_ok and ($escalations|length) > 0 then
    $escalations[0] | next_action("human"; "Record the decision on #\(.issue)"; .command)
  elif $live then
    next_action((if $working then "station" else "controller" end);
      ((if $working then "Station working" else "Controller \($controller.phase)" end) +
        if $complete then "" else ". Cache incomplete; the controller will refresh it" end); null)
  elif $complete and $plan_state == "closed" then
    next_action("none"; "Plan closed. After the merge, run agentic-flow clean " + $plan; null)
  elif $complete | not then
    next_action("human"; "Refresh the incomplete cache"; "agentic-flow run " + $doc + " --reconcile-only")
  elif ($topology == "work-standard" and $plan_state == "closing") or
    ($topology == "step-strict" and ($plan_state | one_of(["open","closing"])) and
      all($rows[]; .topology == "tracker" or .state == "approved")) then
    next_action("human"; "Ship the plan"; "agentic-flow ship " + $doc + " --wait-review")
  else next_action("human"; "Run the controller"; "agentic-flow run " + $doc)
  end) as $next |
  {v:1, plan:$plan, doc:$doc,
   snapshot:{complete:$complete, missing:$missing, over_limit:$oversized,
     cache_at:([$rows[].at] | max), ledger:$ledger.state},
   controller:$controller, steps:$shown_steps, holds:$open_holds, escalations:$escalations,
   usage:{cost_usd:$ledger.value.cost_usd}, next:$next};

# Remove terminal sequences and control characters in both formats.
def clean: gsub("\u001b\\[[0-?]*[ -/]*[@-~]"; "") | gsub("[\u0000-\u001f\u007f-\u009f]"; "");
def clean_fields: walk(if type == "string" then clean else . end);
def clip: if type == "string" then .[:120] else . end;
def plan_text:
  "Plan: \(.plan | clip) (\(.doc | clip))",
  "Controller: \(.controller.state)\(
    if .controller.pid == null then "" else " (pid \(.controller.pid), \(.controller.phase), turn \(.controller.turn)/\(.controller.turn_cap))" end)\(
    if .controller.exit == null then "" else ", exit \(.controller.exit)" end)",
  "Cache: \(if .snapshot.complete then "complete" else "incomplete" end)\(
    if .snapshot.cache_at == null then "" else " as of \(.snapshot.cache_at) (\(.snapshot.cache_at | seconds_since)s ago)" end)",
  (if .snapshot.missing == [] then empty else "  Missing or invalid: \(.snapshot.missing | join(", "))" end),
  (if .snapshot.over_limit == [] then empty else "  Over limit: \(.snapshot.over_limit | join(", "))" end),
  "ledger: \(.snapshot.ledger)",
  (.steps[] | "  #\(.issue) \(.step | clip): \(.state), bounces \(.bounces // "?")/\(.bounce_limit // "?")",
    (.station | select(. != null) | "    \(.cli) \(.run | clip), elapsed \(.elapsed_s)s / \(.timeout_s)s"),
    (.interrupted[]? | "    interrupted: \(. | clip)")),
  (.holds[] | "Hold \(.id | clip) on #\(.issue): \(.reason | clip)", "  \(.command)"),
  (.escalations[] | "Escalation on #\(.issue) (\(.step | clip)\(if .by then ", " + .by else "" end)), return state: \(.return_state // "see #\(.issue)")",
    "  \(.command)"),
  "Usage: \(if .usage.cost_usd == null then "cost unknown" else "USD \(.usage.cost_usd)" end)",
  "Next (\(.next.owner)): \(.next.action)",
  (.next.command | select(. != null) | "  \(.)");

def summary_row($plan):
  . as [$heartbeat,$steps] | {plan:$plan, phase:$heartbeat.value.phase,
    states:([$steps.value[]?.state] | group_by(.) | map({key:.[0],value:length}) | from_entries)};
def summary_text:
  "plans:",
  (.items[] | "  \(.plan | clip)  last phase \(.phase // "unknown")\(
    if .states == {} then "" else "  " + (.states | to_entries | map("\(.value) \(.key)") | join(", ")) end)"),
  (if .items == [] then "  none" elif .more > 0 then "  \(.more) more" else empty end);
