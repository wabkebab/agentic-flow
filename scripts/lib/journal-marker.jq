# Only the first line may carry a transition or hold marker. Strip one exact
# opener and leave the marker text intact for the caller's validation.
def journal_marker_line: (split("\n")[0] // "") | ltrimstr("<!-- ");

def journal_legacy_pin:
  "review.max_bounces=2 review.block_at=judgment andon.station-infrastructure=hold";

def journal_pin:
  [capture("\\Areview\\.max_bounces=(?<max_bounces>[1-5]) review\\.block_at=(?<block_at>judgment|high|medium|low) andon\\.station-infrastructure=(?<infra>hold|retry:[1-3])\\z")] |
  if length==1 then .[0] | .max_bounces |= tonumber else error("invalid policy pin") end;

def journal_identity($prefix):
  select(startswith($prefix)) | . as $line | ltrimstr($prefix) |
  capture("\\A(?<plan>[a-z0-9][a-z0-9._-]*) (?<identity>tracker|step:[a-z0-9][a-z0-9._-]*) spec:(?<spec>[^ ]+)(?<extra>[^\\n]*) -->\\z") |
  ([.extra | scan("(?:^| )journal=([a-z0-9][a-z0-9._-]*)(?= |$)") | .[0]]) as $versions |
  ([.extra | scan("(?:^| )approved=([a-f0-9]{40})(?= |$)") | .[0]]) as $revisions |
  {plan, identity, spec, line:$line, versions:$versions, approved:($revisions|if length==1 then .[0] else null end),
   step:(if .identity=="tracker" then "tracker" else .identity[5:] end)};

def journal_stamp_lines($prefix):
  [split("\n")[] | select(startswith($prefix))] as $lines |
  if ($lines|length)<1 or ($lines|length)>2 then error("expected one identity stamp and at most one policy line") else . end |
  [$lines[] | journal_identity($prefix)] as $identities |
  if ($identities|length)!=1 then error("expected one identity stamp") else $identities[0] end |
  . as $identity |
  ($lines - [.line] | .[0]) as $policy_line |
  (if (.versions|length)>1 then error("ambiguous journal version")
  elif .versions==["v2"] then
    [$policy_line | strings | ltrimstr($prefix) |
      capture("\\A(?<plan>[a-z0-9][a-z0-9._-]*) policy:v1 (?<policy>[^\\n]+) -->\\z") |
      select(.plan==$identity.plan) | .policy] |
    if length==1 then .[0] else error("journal=v2 requires a policy line for the same plan") end
  elif $policy_line!=null then error("unexpected prefixed line on an issue without journal=v2")
  else journal_legacy_pin end) as $policy |
  ($policy | journal_pin) as $pin |
  $identity + {legacy:((.versions | any(.=="v1" or .=="v2"))|not),
    journal:.versions[0], policy:$policy, policy_line:$policy_line, pin:$pin} | del(.versions);
