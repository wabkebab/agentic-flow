# Station launch profiles

`agentic-flow packet <issue> --station executor|reviewer [--json]` is the controller's
input builder. Run it outside the isolated station, then pass only its output to the
station. Rejected admission prints no packet. Comments by outsiders are counted,
not quoted; policy authors remain trusted. Packets are limited to 3,000 words.
Reviewer packets include the latest accepted submit and a SHA/tree/implementation-
matched verification record, preserving its provenance, or a request to regenerate it.

`agentic-flow roles [--json]` shows each effective assignment and its layer.
Defaults in `config/roles.tsv` are overridden by a whole project row in
`.agentic-flow-roles`, then by the operator file under
`$XDG_CONFIG_HOME/agentic-flow/roles/<owner>/<repo>.tsv` (default `~/.config`).
Only the human sets, unsets or makes a station manual. Project changes are staged;
upgrades replace harness defaults and preserve project/operator choices.

`scripts/lib/launch.sh` activates these profiles in a whole-process `env -i`
environment. Its preflight probes gh authentication and every remote push URL,
checks effective settings, and reports contract mode and accepted-risk gaps.
The controller caller uses `LAUNCH_STEP` and optionally `LAUNCH_SESSION` for the
preamble and preassigned session. A resume also requires the creating intent's
`LAUNCH_RESUME_CLI` and `LAUNCH_RESUME_PROFILE` (project-relative profile path).
Codex's `launch_session_record` callback receives the first `thread.started` id;
C-2/C-5 own ledger persistence. Launch metadata includes raw reported usage and
whether turn/budget limits are advisory. A `-` timeout still gets a 2,700-second
controller watchdog; explicit timeouts override it. Every process group is reaped
on completion, timeout or a failed session callback. `ulimit -f 65536` caps each
file written by the CLI at 64 MiB (Bash uses 1,024-byte blocks), including capture
files and session/database files under HOME. A larger existing CLI database may
therefore reject writes; this is a per-file process limit, not a capture-only cap.

Executor bundles read the live AGENTS.md, including its render-shared engineering
standards; reviewer bundles read the live review-execution skill. The preamble
wins over vendor instruction roles. Codex reviewer launches exclude AGENTS.md;
Claude excludes vendor instructions only under API-key authentication with `--bare`.
OAuth Claude and OpenCode report `overridden`. OpenCode has no OS network boundary; its unattended use requires the accepted risk
`opencode-station-network`. An identical CLI/model pair requires `same-model-review`.

## Claude

Load `claude.settings.json` using Claude Code's `--settings` option. Its deny rules
block direct `gh` calls and GitHub WebFetch domains. Tests parse the file and assert
the deny entries. Shell tool permissions do not block arbitrary alternate programs. The station profile
also requires the Bash sandbox, refuses unsandboxed retries and unavailable sandbox
runtimes, and uses a strict empty outbound domain allow-list. Preflight checks these
settings and the platform sandbox dependencies. Do not use a permission-bypass launch mode.
See [sandbox configuration](https://code.claude.com/docs/en/sandboxing).

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

The launcher installs the generated command rules in the station
`CODEX_HOME/rules/agentic-flow.rules`. To enable the same rules interactively,
run these from the repository root:

```sh
mkdir -p ~/.codex/rules
cp config/stations/command-policy.rules ~/.codex/rules/agentic-flow.rules
```

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

## Probe the command policy

Run `scripts/agentic-flow doctor --stations` to exercise the assigned CLI's
station policy. Add `--interactive` to exercise the local rules installed for
interactive use in the disposable probe worktree. Both modes require working
model authentication. A case passes when the CLI reports a native refusal and
the protected command's PATH sentinel is absent. The report lists unprobed
canaries. See [the coverage matrix](../../docs/reference/command-policy-coverage.md)
for rule limits and host verification status.

## Run ledger and metrics

Source `scripts/lib/ledger.sh`, then call `ledger_init <worktree>`. All linked
worktrees resolve the same Git common directory. Each `ledger_<kind> <plan>
<record-json-file>` writer validates one record, takes a bounded append lock,
and publishes one JSONL line with one write followed by fsync. The controller
adds its longer-lived per-plan lock. Duplicate once-only records, stale
replacement heads and invalid record order are refused. `ledger_ship` records a
human invocation as `{v:1,kind:"ship",plan,ship:<unique-id>,at}`.

Executor verification records use
`{v:1,kind:"verify",run,head,record,status:"green"|"red",tail?,at}`.
`record` is the verify-step record path. The optional `tail` contains the final
16,384 bytes at most of verify-step stderr, bounded before the ledger append.
Fix-resume packets use this durable diagnostic suffix across controller restarts
without reopening the record path. Older records without `tail` remain valid.

`ledger_chains <plan> [context-json-file]` reports every chain's latest run,
open head, closed runs, pending item and remaining retry allowances. Context is
an object keyed by run id with optional boolean `commit` and `dirty` flags;
the caller supplies worktree observations. Replacement runs preserve chain-wide
limits. `ledger_generation` advances only after a chain end. These are local
recovery hints; the controller still replays the journal before any transition.

Ledgers are limited to 50,000 lines / 32 MiB per plan, records and decision bodies
to 256 KiB, and plan scans to 1,000 ledgers. Reads cover the entire selected plan.
A malformed crash suffix is ignored with a warning. A subsequent append seals
its exact byte length and SHA-256 in reserved framing metadata, preserving the
old bytes even after repeated interrupted repairs. Malformed interior records
without such framing are rejected. Decision bodies are fsynced before their
record; `ledger_body <plan> <run>` verifies the stored body hash before returning
any bytes.

`agentic-flow metrics [--plan <id>] [--since <UTC-date>] [--json]` reads local
ledgers and the handoff-generated `.metrics.json` state-cache companion. The
existing six-column session cache is unchanged. Missing journal history or usage
is `null` in JSON and `n/a` in text. Incomplete or partially reported usage totals remain unknown;
reported zeroes stay zero. No network call is made.

First-pass yield is approved steps without any bounce divided by approved steps.
Bounce rate is admitted bounce events divided by bounce plus approve events.
Touch count is admitted resume + approve events + unique ship invocations;
handoff retries add no touches or bounces. Station quality metrics use the issues
that station ran. Lead time is the first intent to the journaled tracker/work
close, in UTC seconds. Wall time sums completed station records. `--since` filters
run activity and journal events; lead time retains the full lifecycle interval.
The JSON includes per-plan/per-station totals and per-step station usage/cost.

## Red-first amendment

The human approved Option A on tracker #124, implemented with S-7: exit 0 is green;
exit 124 (timeout) and 130/143 (interrupts) are invalid; other non-zero exits are red
only when output matches `RED_FIRST_SIGNATURE`. A missing/mismatched signature is
invalid. Native Cargo 101 and make 2 are preserved in the record rather than
normalized. Prefer raw runner selectors so the recorded exit remains informative.
S-9 carries this rule and selector guidance into shared contracts and brief templates.
