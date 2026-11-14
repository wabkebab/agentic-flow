# Station launch profiles

`agentic-flow packet <issue> --station executor|reviewer [--json]` is the controller's
input builder. Run it outside the isolated station, then pass only its output to the
station. Rejected admission prints no packet. Comments by outsiders are counted,
not quoted; policy authors remain trusted. Packets are limited to 3,000 words.
Reviewer packets include the latest accepted submit and a SHA/tree/implementation-
matched verification record, preserving its provenance, or a request to regenerate it.

These files are launch inputs, not automatically active project settings. Phase 2's
controller must load them, remove GitHub credentials (including on-disk credential
stores and connected tools), and enforce network isolation. Do not launch an agent
with a prompt sourced directly from a raw issue thread.

## Claude

Load `claude.settings.json` using Claude Code's `--settings` option. Its deny rules
block direct `gh` calls and GitHub WebFetch domains. Tests parse the file and assert
the deny entries. Shell tool permissions do not block arbitrary alternate programs
or replace OS network isolation. Do not use a permission-bypass launch mode.

Reference: [Claude permissions](https://code.claude.com/docs/en/permissions).

## Codex

Use `codex.config.toml` as a named user profile, installed by the operator as
`~/.codex/agentic-station.config.toml`, then select `codex exec --profile agentic-station`.
Current Codex (confirmed with 0.167.2) uses a separate profile file with top-level keys;
legacy `[profiles.name]` tables are no longer supported. The profile requests a
workspace-write sandbox with no outbound network, no approval escalation, disabled
web search, and an environment filter excluding GitHub tokens. It also disables
shell-profile loading and default secret-variable inheritance.

Project/CLI/managed layers may override or constrain a named profile. The controller
must verify the effective configuration and withhold credentials from the entire
station process, not just its shell children. The profile does not remove on-disk
`gh` credentials or already-connected tools, and cannot provide a raw-`gh` tool deny
rule by itself. End-to-end headless isolation remains controller work.

References: [profiles](https://learn.chatgpt.com/docs/config-file/config-advanced#profiles)
and [configuration](https://learn.chatgpt.com/docs/config-file/config-reference).

## OpenCode

Load `opencode.json` as the station configuration using `OPENCODE_CONFIG` in the
controller's isolated environment. This is the current v2 format (installed CLI:
2.3.0): ordered `permissions` entries with the `shell` action. It denies `gh` and
`gh *`, and direct WebFetch requests to GitHub domains. V1's `permission`/`bash`
format is incompatible; this profile must not be used unconverted on v1.

The v2 shell scanner applies command permissions, but shell programs still run with
the host user's authority. Direct-command deny rules do not stop every alternate
GitHub client or filesystem credential read. The controller must supply the OS
network and credential boundary and check effective merged permissions.

Reference: [OpenCode permissions](https://opencode.ai/docs/permissions/).

## Red-first amendment

The human approved Option A on tracker #124, implemented with S-7: exit 0 is green;
exit 124 (timeout) and 130/143 (interrupts) are invalid; other non-zero exits are red
only when output matches `RED_FIRST_SIGNATURE`. A missing/mismatched signature is
invalid. Native Cargo 101 and make 2 are preserved in the record rather than
normalized. Prefer raw runner selectors so the recorded exit remains informative.
S-9 carries this rule and selector guidance into shared contracts and brief templates.
