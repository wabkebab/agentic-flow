# Normalize only reported usage. Cache-specific counts remain CLI-specific;
# input is each CLI's reported input_tokens/input, never a cost estimate.
def sum_reported: if length == 0 then null else add end;
if $cli == "claude" then
  (map(select(.type == "result")) | last // {}) as $r |
  {session:($r.session_id // null), result:($r.structured_output // $r.result // null),
   usage:{input:($r.usage.input_tokens // null),output:($r.usage.output_tokens // null),cost_usd:($r.total_cost_usd // null)}}
elif $cli == "codex" then
  {session:(map(select(.type == "thread.started") | .thread_id) | last // null),
   result:(map(select(.type == "item.completed" and .item.type == "agent_message") | .item.text) | last // null),
   usage:{input:(map(select(.type == "turn.completed") | .usage.input_tokens | numbers) | sum_reported),
          output:(map(select(.type == "turn.completed") | .usage.output_tokens | numbers) | sum_reported),cost_usd:null}}
elif $cli == "opencode" then
  {session:(map(.sessionID // empty) | last // null),
   result:((map(select(.type == "text")) | last // {}) as $last |
     map(select(.type == "text" and .part.messageID == $last.part.messageID) | .part.text // empty) | join("")),
   usage:{input:(map(select(.type == "step_finish") | .part.tokens.input | numbers) | sum_reported),
          output:(map(select(.type == "step_finish") | .part.tokens.output | numbers) | sum_reported),
          cost_usd:(map(select(.type == "step_finish") | .part.cost | numbers) | sum_reported)}}
else error("unknown station CLI") end
# A station that cannot enforce a schema (OpenCode) often explains first and ends with the JSON,
# sometimes fenced. Take the last line-leading object that parses; anything else stays a string.
| .result |= (if type == "string" then
    (. as $raw | try fromjson catch (
      ([$raw | match("(^|\n)\\{"; "g").offset] | reverse) as $starts
      | first($starts[] as $o | $raw[$o:] | sub("\\s*```\\s*$"; "") | try fromjson catch empty | select(type == "object"))
      // $raw))
  else . end)
