C-1 real CLI captures, 2026-11-15. Prompt: reply OK, use no tools.
Captured in a scratch repository. Session/event/snapshot IDs are scrubbed;
Claude timing, model metadata and credential-expiry metadata are omitted.

- Claude Code 2.1.325: print JSON; input_tokens=2, output_tokens=65,
  total_cost_usd=0.0308938. Cache fields remain separate from input.
- Codex 0.169.0: exec JSONL; thread.started carries thread_id; turn.completed
  reports input_tokens=15265 and output_tokens=5; no cost field.
- OpenCode 2.3.0: standalone run, opencode/beam-free (the default paid
  workspace was at its spending limit); step_finish reports tokens.input=6776,
  tokens.output=2 and cost=0.

Codex exec resume accepts --output-schema, --json, -o and -m. Its named
--profile flag belongs before resume (on exec). Claude and OpenCode also accept
model selection with resume; launch accepts only the creating CLI/profile.
Codex debug prompt-input with project_doc_max_bytes=0 excluded a sentinel in
AGENTS.md (exit 0); the key is applied to reviewer launches. OpenCode debug config
reports instruction sources but does not establish AGENTS.md exclusion, so its
contract mode remains overridden. Claude OAuth likewise remains overridden;
API-key auth permits --bare with the explicit appended bundle.
