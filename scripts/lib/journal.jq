# Input is already normalized at the API boundary. No GitHub I/O here.
def authorized($role; $author):
  (if $role=="executor" then $executors elif $role=="reviewer" then $reviewers
   elif $role=="approver" then $approvers else "" end | split(" ") | index($author)) != null;
def successor($state; $event; $bounces; $return):
  [$rules[] | select(.[0]=="transition" and .[1]==$topology and .[2]==$event and .[4]==$state) |
    select($event!="bounce" or (.[6]=="findings,bounces<2" and $bounces<2) or
      (.[6]=="findings,bounces=2" and $bounces==2)) | select($event!="resume" or .[5]==$return) | {state:.[5],role:.[3]}] |
  if length==1 then .[0] else null end;
def accept($t; $c; $old):
  successor(.state; $t.event; .bounces; .return_to) as $next |
  if $next==null or $next.role!=$t.role or (authorized($t.role;$c.author)|not) or
    $t.seq!=(.seq+1) or $t.from!=.state or
    ($t.event=="submit" and (($t.head|test("^[a-f0-9]{40}$")|not) or $t.head==.last_bounced_head)) or
    ($t.event=="approve" and $t.head!=.submitted_head) or
    ($t.event=="bounce" and ($c.body|split("\n")|.[1:]|join("\n")|test("\\S")|not)) or
    (($t.event=="ask" or $t.event=="resume") and ($c.body|split("\n")|.[1:]|join("\n")|test("\\S")|not))
    or ($t.event!="resume" and $t.return!=null)
    or ($t.event=="resume" and $t.return!=null and $t.return!=.return_to)
  then if $old then .unjournaled=$c.id else .skipped+=1 end
  else .state=$next.state | .seq+=1 |
    .latest=($t + {comment_id:$c.id,dbid:$c.dbid,last_edited_at:$c.last_edited_at,legacy:$old}) |
    .accepted += [.latest] |
    if $t.event=="submit" then .submitted_head=$t.head
    elif $t.event=="approve" then .approved_head=$t.head
    elif $t.event=="bounce" then .bounces+=1 | .last_bounced_head=.submitted_head | if .state=="escalated" then .return_to="executing" else . end
    elif $t.event=="ask" then .return_to=$t.from
    elif $t.event=="resume" then .bounces=0 else . end
  end;
def transition($c):
  try ($c.body|split("\n")[0] |
    capture("^agentic-flow-transition: v=1; id=(?<plan>[a-z0-9][a-z0-9._-]*)/(?<step>[a-z0-9][a-z0-9._-]*)/(?<seq>[1-9][0-9]{0,5})/(?<event>submit|bounce|resume|approve|notify|close|ask); event=(?<same>submit|bounce|resume|approve|notify|close|ask); from=(?<from>[a-z-]+); role=(?<role>executor|reviewer|approver); head=(?<head>[a-f0-9]{40}|none)(; return=(?<return>executing|reviewing))?$") |
    select(.event==.same and ($plan=="" or .plan==$plan) and ($step=="" or .step==$step)) |
    .seq|=tonumber | .id="\(.plan)/\(.step)/\(.seq)/\(.event)") catch null;
def legacy_marker($c):
  if authorized("executor";$c.author) then
    (try ($c.body|capture("Implemented in (?<head>[a-f0-9]{40})([^a-f0-9]|$)") |
      {event:"submit",role:"executor",head}) catch null)
  else null end //
  (if authorized("reviewer";$c.author) then
    (try ($c.body|split("\n")[] |
      capture("^[ \\t]*agentic-flow-review: status=(?<status>approved|changes-requested); step=(?<step>[a-z0-9][a-z0-9._-]*); head=(?<head>[a-f0-9]{40}); role=reviewer$") |
      select($step=="" or .step==$step) |
      {event:(if .status=="approved" then "approve" else "bounce" end),role:"reviewer",head}) catch null)
  else null end);
if type!="array" or length>100 then error("invalid or oversized journal") else . end |
reduce .[] as $c
  ({state:(if $topology=="tracker" then "open" else "executing" end), seq:0,
    return_to:"executing",bounces:0,submitted_head:"none",approved_head:"none",last_bounced_head:"none",
    latest:null,skipped:0,accepted:[],unjournaled:null,prefix:$legacy};
    if .unjournaled!=null then .
    elif ($c.body|startswith("agentic-flow-transition:")) then
      .prefix=false | ([transition($c)] | map(select(.!=null)) | .[0]) as $t |
      if $t==null then .skipped+=1 else accept($t;$c;false) end
    elif .prefix then
      ([legacy_marker($c)]|map(select(.!=null))|.[0]) as $t |
      if $t==null then . else
        # Historical prose findings were followed by a second executor handoff.
        if $t.event=="submit" and .state=="reviewing" then
          . as $s | accept({event:"bounce",role:"reviewer",head:"none",seq:(.seq+1),from:.state,
            id:"\($plan)/\($step)/\(.seq+1)/bounce"};
            ($c+{author:($reviewers|split(" ")|map(select(length>0))|.[0]),body:"implied\nbounce"});true)
        else . end |
        accept($t+{seq:(.seq+1),from:.state,id:"\($plan)/\($step)/\(.seq+1)/\($t.event)"};$c;true)
      end
    else . end) | del(.prefix)
