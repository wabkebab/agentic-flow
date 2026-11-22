# Native command policy coverage

This inventory covers the blocking Bash hook cases in [the hook regression suite](../../scripts/tests/hooks.sh).
Repeated assertions of the same form share a row. SessionStart and Stop hooks stay
outside the command policy. Read the coverage columns as provisional until the
hook-free probes exercise the actual interactive configuration and station profiles.

- **M** means Codex's native rule checker matched a forbidden fixed prefix. Both
  modes can use that rule syntax. Neither mode has been verified through a launch.
- **N** means the native rule cannot express the tested condition with the proposed
  patterns while preserving the related allowed commands.
- **P** means runtime validation is pending. Shell composition and parsing cases
  particularly depend on what each CLI passes to its native matcher.

## Installed CLI probes

- Claude Code **2.1.328** returned its effective `permissions.deny` from the CLI's
  stream-JSON `get_settings` request, including `Bash(git push:*)` and
  `Bash(git -C * push *)`. The bare tool-use probe stopped at authentication
  before Bash dispatch.
- Codex CLI **0.171.0** evaluated isolated rules via `codex execpolicy check`.
  Bare push, signing-wrapper push and blanket staging matched; named staging,
  a wrapper commit and the controller's handoff command had no match. In a
  path or assignment token position, `*` matched literally. The variable
  `git -C`, `env GIT_INDEX_FILE=…`, ordered Git options and GitHub flag cases
  below need a rule broader than their protected operations if passed as argv.
- OpenCode **2.3.0** could report its version with temporary XDG paths. Its
  standalone server failed to bind in the station sandbox, blocking checks of
  both the legacy `permission.bash` agent format and the station profile's
  `permissions` resource rules.

## Decisions required before retiring hooks

- Variable Git paths, global options and environment assignments. Codex
  cannot match arbitrary argument values before `push` or `add`, or before
  a blanket staging or hook-bypass flag. A wider prefix also catches routine
  named staging, read-only commands or normal commits.
- Variable wrapper arguments and shell payloads. A `timeout` duration or the
  complete `bash -lc` script occupies a token before the operation can be
  identified. Confirm whether each CLI reliably extracts operations from
  compound commands, substitutions, redirects, heredocs and parser failures.
- GitHub repository selectors and API mutations. A token prefix cannot classify
  variable `-R` values or method flags after an arbitrary API route. A
  command pattern also cannot classify the contents of a GraphQL input file.
  The approved interface already specifies broad issue edit, close and reopen
  denies. The existing station GitHub deny entries cover direct `gh` calls
  in Claude and OpenCode settings, subject to the runtime probes.
- Malformed tool-call JSON is a hook input rather than a command. Native CLI
  validation needs separate proof for these cases. The commit-message
  fail-closed push guard assertion also needs a disposition if CLI parsing
  yields a different result.
- Staged content inspection moves to Git's pre-commit hook in s-5 under the
  approved plan. Coverage for an unmodeled Git environment and for bypass
  flags after variable arguments still needs a disposition.

For the open rows, the approved brief calls for an owner choice of a thin
hook, a wider deny, or an accepted risk. The pre-commit migration and any
broader rule need a passing hook-free probe before existing guards are retired.

## Push and merge

| Command form | Hook test lines | Claude interactive | Claude station | Codex interactive | Codex station | OpenCode interactive | OpenCode station |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `git push` | [661, 709](../../scripts/tests/hooks.sh#L661) | P | P | M | M | P | P |
| `git push origin main` | [17](../../scripts/tests/hooks.sh#L17) | P | P | M | M | P | P |
| `git push origin main --force` | [662](../../scripts/tests/hooks.sh#L662) | P | P | M | M | P | P |
| `git-claude push origin HEAD` | [664, 710](../../scripts/tests/hooks.sh#L664) | P | P | M | M | P | P |
| `git-opencode push origin HEAD` | [693](../../scripts/tests/hooks.sh#L693) | P | P | M | M | P | P |
| `git-codex push origin HEAD` | [694](../../scripts/tests/hooks.sh#L694) | P | P | M | M | P | P |
| `gh pr merge 12` | [666, 711](../../scripts/tests/hooks.sh#L666) | P | P | M | M | P | P |
| `git --no-pager push` | [689](../../scripts/tests/hooks.sh#L689) | P | P | M | M | P | P |
| `git -p push` | [690](../../scripts/tests/hooks.sh#L690) | P | P | M | M | P | P |
| `sudo git push` | [668](../../scripts/tests/hooks.sh#L668) | P | P | M | M | P | P |
| `sudo gh pr merge 12` | [669](../../scripts/tests/hooks.sh#L669) | P | P | M | M | P | P |
| `nohup git push` | [670](../../scripts/tests/hooks.sh#L670) | P | P | M | M | P | P |
| `nice git push` | [671](../../scripts/tests/hooks.sh#L671) | P | P | M | M | P | P |
| `time git push` | [673](../../scripts/tests/hooks.sh#L673) | P | P | P | P | P | P |
| `timeout 10 git push` | [672](../../scripts/tests/hooks.sh#L672) | P | P | N | N | P | P |
| `! git push` | [674](../../scripts/tests/hooks.sh#L674) | P | P | P | P | P | P |
| `>out git push` | [675](../../scripts/tests/hooks.sh#L675) | P | P | P | P | P | P |
| `2>&1 git push` | [676](../../scripts/tests/hooks.sh#L676) | P | P | P | P | P | P |
| `if git push; then :; fi` | [677](../../scripts/tests/hooks.sh#L677) | P | P | P | P | P | P |
| `{ git push; }` | [678](../../scripts/tests/hooks.sh#L678) | P | P | P | P | P | P |
| `git push` with a line continuation before `push` | [679–681](../../scripts/tests/hooks.sh#L679) | P | P | P | P | P | P |
| `git push;` | [692](../../scripts/tests/hooks.sh#L692) | P | P | P | P | P | P |
| `git status && git push` | [665](../../scripts/tests/hooks.sh#L665) | P | P | P | P | P | P |
| `git status; git push` | [695](../../scripts/tests/hooks.sh#L695) | P | P | P | P | P | P |
| `echo $(date); git-claude push` | [126](../../scripts/tests/hooks.sh#L126) | P | P | P | P | P | P |
| `echo $(date); gh pr merge 12` | [128](../../scripts/tests/hooks.sh#L128) | P | P | P | P | P | P |
| `` echo "`git push`" `` | [63](../../scripts/tests/hooks.sh#L63) | P | P | P | P | P | P |
| `` echo "`git-claude push`" `` | [63](../../scripts/tests/hooks.sh#L63) | P | P | P | P | P | P |
| `` echo "`gh pr merge`" `` | [63](../../scripts/tests/hooks.sh#L63) | P | P | P | P | P | P |
| `echo "$(git push>out)"` | [64](../../scripts/tests/hooks.sh#L64) | P | P | P | P | P | P |
| `echo "$(git-claude push>out)"` | [64](../../scripts/tests/hooks.sh#L64) | P | P | P | P | P | P |
| `echo "$(gh pr merge>out)"` | [64](../../scripts/tests/hooks.sh#L64) | P | P | P | P | P | P |
| `echo "$(git push</dev/null)"` | [65](../../scripts/tests/hooks.sh#L65) | P | P | P | P | P | P |
| `echo "$(git-claude push</dev/null)"` | [65](../../scripts/tests/hooks.sh#L65) | P | P | P | P | P | P |
| `echo "$(gh pr merge</dev/null)"` | [65](../../scripts/tests/hooks.sh#L65) | P | P | P | P | P | P |
| `echo "$(git push)"` | [699](../../scripts/tests/hooks.sh#L699) | P | P | P | P | P | P |
| `git push following a literal heredoc (six delimiter/redirection combinations)` | [112–122](../../scripts/tests/hooks.sh#L112) | P | P | P | P | P | P |
| `git push with an unterminated heredoc` | [124](../../scripts/tests/hooks.sh#L124) | P | P | P | P | P | P |
| `git push "unterminated` | [698](../../scripts/tests/hooks.sh#L698) | P | P | P | P | P | P |
| `git -C /some/path push` | [663](../../scripts/tests/hooks.sh#L663) | P | P | N | N | P | P |
| `git -C "a path" push` | [696, 712](../../scripts/tests/hooks.sh#L696) | P | P | N | N | P | P |
| `git -C a\ path push` | [697](../../scripts/tests/hooks.sh#L697) | P | P | N | N | P | P |
| `git -C "$(pwd)" push` | [700](../../scripts/tests/hooks.sh#L700) | P | P | N | N | P | P |
| `git --git-dir=/tmp/x push` | [691](../../scripts/tests/hooks.sh#L691) | P | P | N | N | P | P |
| `env GIT_INDEX_FILE=/tmp/other git push` | [701](../../scripts/tests/hooks.sh#L701) | P | P | N | N | P | P |
| `gh -R owner/repo pr merge 12` | [667](../../scripts/tests/hooks.sh#L667) | P | P | N | N | P | P |

## Blanket staging

| Command form | Hook test lines | Claude interactive | Claude station | Codex interactive | Codex station | OpenCode interactive | OpenCode station |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `git add -A` | [15, 146–155, 161–163, 187](../../scripts/tests/hooks.sh#L15) | P | P | M | M | P | P |
| `git add .` | [166](../../scripts/tests/hooks.sh#L166) | P | P | M | M | P | P |
| `git add --all` | [131](../../scripts/tests/hooks.sh#L131) | P | P | M | M | P | P |
| `git-claude add --all` | [167](../../scripts/tests/hooks.sh#L167) | P | P | M | M | P | P |
| `git-codex add .` | Brief Part A | P | P | M | M | P | P |
| `git-opencode add -A` | Brief Part A | P | P | M | M | P | P |
| `git --no-pager add -A` | [179](../../scripts/tests/hooks.sh#L179) | P | P | M | M | P | P |
| `git -p add .` | [180](../../scripts/tests/hooks.sh#L180) | P | P | M | M | P | P |
| `sudo git add -A` | [183](../../scripts/tests/hooks.sh#L183) | P | P | M | M | P | P |
| `nohup git add .` | [184](../../scripts/tests/hooks.sh#L184) | P | P | M | M | P | P |
| `git -C /some/path add -A` | [170](../../scripts/tests/hooks.sh#L170) | P | P | N | N | P | P |
| `git -C /some/path add --all` | [188](../../scripts/tests/hooks.sh#L188) | P | P | N | N | P | P |
| `git -c user.name=x add .` | [171](../../scripts/tests/hooks.sh#L171) | P | P | N | N | P | P |
| `git -C /some/path -c core.pager=cat add --all` | [172](../../scripts/tests/hooks.sh#L172) | P | P | N | N | P | P |
| `git --git-dir=/tmp/x add --all` | [181](../../scripts/tests/hooks.sh#L181) | P | P | N | N | P | P |
| `git --no-pager -C /some/path add -A` | [182](../../scripts/tests/hooks.sh#L182) | P | P | N | N | P | P |
| `env GIT_INDEX_FILE=/tmp/index git add -A` | Brief scenario 6 | P | P | N | N | P | P |
| `git add named-file -A` | Broad staging with an option after a path | P | P | N | N | P | P |
| `echo $(date); git add -A` | [131](../../scripts/tests/hooks.sh#L131) | P | P | P | P | P | P |
| `echo $(date); git add .` | [131](../../scripts/tests/hooks.sh#L131) | P | P | P | P | P | P |
| `echo $(date); git add --all` | [131](../../scripts/tests/hooks.sh#L131) | P | P | P | P | P | P |
| `git add -A following a literal heredoc (six delimiter/redirection combinations)` | [112–122](../../scripts/tests/hooks.sh#L112) | P | P | P | P | P | P |

## Workflow writes and controller operations

| Command form | Hook test lines | Claude interactive | Claude station | Codex interactive | Codex station | OpenCode interactive | OpenCode station |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `gh issue edit 1 --add-label needs-review` | [726](../../scripts/tests/hooks.sh#L726) | P | P | M | M | P | P |
| `rtk gh issue edit --add-label=needs-review 1` | [727](../../scripts/tests/hooks.sh#L727) | P | P | M | M | P | P |
| `gh -R owner/repo issue edit 1 --remove-label agent:codex` | [728](../../scripts/tests/hooks.sh#L728) | P | P | N | N | P | P |
| `gh issue edit 1 --add-label "bug,needs-human"` | [729](../../scripts/tests/hooks.sh#L729) | P | P | M | M | P | P |
| `gh api repos/owner/repo/issues/1 -X PATCH -f labels[]=needs-review` | [730](../../scripts/tests/hooks.sh#L730) | P | P | N | N | P | P |
| `gh api repos/owner/repo/issues/1/labels -X DELETE` | [731](../../scripts/tests/hooks.sh#L731) | P | P | N | N | P | P |
| `gh api repos/owner/repo/issues/1 --method PATCH --input file.json` | [732](../../scripts/tests/hooks.sh#L732) | P | P | N | N | P | P |
| `gh api repos/owner/repo/issues/1 -X PATCH -f state=closed` | [733](../../scripts/tests/hooks.sh#L733) | P | P | N | N | P | P |
| `gh api graphql -f query=mutation` | [742](../../scripts/tests/hooks.sh#L742) | P | P | N | N | P | P |
| `gh api graphql --input request.json` | [743](../../scripts/tests/hooks.sh#L743) | N | N | N | N | N | N |
| `gh issue close 1 (workflow issue)` | [747](../../scripts/tests/hooks.sh#L747) | P | P | M | M | P | P |
| `gh issue reopen 1 (workflow issue)` | [748](../../scripts/tests/hooks.sh#L748) | P | P | M | M | P | P |
| `gh issue close 1 (issue lookup failed)` | [749](../../scripts/tests/hooks.sh#L749) | P | P | M | M | P | P |
| `scripts/agentic-flow ship docs/inprogress/plan.md` | [734](../../scripts/tests/hooks.sh#L734) | P | P | M | M | P | P |
| `rtk proxy scripts/agentic-flow ship docs/inprogress/plan.md --wait-review` | [735](../../scripts/tests/hooks.sh#L735) | P | P | M | M | P | P |
| `bash -lc "scripts/agentic-flow ship docs/inprogress/plan.md"` | [736](../../scripts/tests/hooks.sh#L736) | P | P | N | N | P | P |
| `scripts/agentic-flow approve docs/inprogress/plan.md --by owner` | [737](../../scripts/tests/hooks.sh#L737) | P | P | M | M | P | P |
| `scripts/agentic-flow hold clear docs/inprogress/plan.md fixture/hold/1` | [738](../../scripts/tests/hooks.sh#L738) | P | P | M | M | P | P |
| `scripts/agentic-flow token reviewer` | [739](../../scripts/tests/hooks.sh#L739) | P | P | M | M | P | P |
| `rtk proxy scripts/agentic-flow token executor` | [740](../../scripts/tests/hooks.sh#L740) | P | P | M | M | P | P |
| `bash -lc "scripts/agentic-flow token reviewer"` | [741](../../scripts/tests/hooks.sh#L741) | P | P | N | N | P | P |
| `bash -c "echo ok"; gh issue edit 1 --add-label needs-review` | [744](../../scripts/tests/hooks.sh#L744) | P | P | P | P | P | P |

## Commit and staged content

| Command form | Hook test lines | Claude interactive | Claude station | Codex interactive | Codex station | OpenCode interactive | OpenCode station |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `git -c commit.gpgsign=false commit -F .adopter-commit-message` | [35](../../scripts/tests/hooks.sh#L35) | N | N | N | N | N | N |
| `` echo "`git commit`" `` | [68](../../scripts/tests/hooks.sh#L68) | N | N | N | N | N | N |
| `echo "$(git commit>out)"` | [70](../../scripts/tests/hooks.sh#L70) | N | N | N | N | N | N |
| `echo "$(git commit</dev/null)"` | [72](../../scripts/tests/hooks.sh#L72) | N | N | N | N | N | N |
| `` git commit -m "Run `make check` first." `` | [134](../../scripts/tests/hooks.sh#L134) | N | N | N | N | N | N |
| `git commit -F - with expanding heredoc` | [135](../../scripts/tests/hooks.sh#L135) | N | N | N | N | N | N |
| `git commit -F - with literal heredoc and a staged credential` | [527](../../scripts/tests/hooks.sh#L527) | N | N | N | N | N | N |
| `sudo git commit -m x` | [529–531](../../scripts/tests/hooks.sh#L529) | N | N | N | N | N | N |
| `nohup git commit -m x` | [533–535](../../scripts/tests/hooks.sh#L533) | N | N | N | N | N | N |
| `git-claude commit -m x with a staged credential` | [536, 539–542](../../scripts/tests/hooks.sh#L536) | N | N | N | N | N | N |
| `git-codex commit -m x with a staged credential` | [537](../../scripts/tests/hooks.sh#L537) | N | N | N | N | N | N |
| `git-opencode commit -m x with a staged credential` | [538](../../scripts/tests/hooks.sh#L538) | N | N | N | N | N | N |
| `git commit -m x with a staged private key` | [548–550](../../scripts/tests/hooks.sh#L548) | N | N | N | N | N | N |
| `git commit -m x with a staged hardcoded password` | [555–557](../../scripts/tests/hooks.sh#L555) | N | N | N | N | N | N |
| `git -C '<path with spaces>' commit -m x` | [623](../../scripts/tests/hooks.sh#L623) | N | N | N | N | N | N |
| `git -C "<path with spaces>" commit -m x` | [624](../../scripts/tests/hooks.sh#L624) | N | N | N | N | N | N |
| `git -C <backslash-escaped path> commit -m x` | [625](../../scripts/tests/hooks.sh#L625) | N | N | N | N | N | N |
| `git -C ../secret-other-repo commit -m x` | [626](../../scripts/tests/hooks.sh#L626) | N | N | N | N | N | N |
| `cd '<repo>' && git commit -m x` | [627](../../scripts/tests/hooks.sh#L627) | N | N | N | N | N | N |
| `GIT_DIR=<repo>/.git git commit -m x` | [628](../../scripts/tests/hooks.sh#L628) | N | N | N | N | N | N |
| `git --git-dir=<repo>/.git --work-tree=<repo> commit -m x` | [629](../../scripts/tests/hooks.sh#L629) | N | N | N | N | N | N |
| `GIT_INDEX_FILE=<index> git commit -m x` | [630](../../scripts/tests/hooks.sh#L630) | N | N | N | N | N | N |
| `env GIT_INDEX_FILE=<index> git commit -m x` | [631](../../scripts/tests/hooks.sh#L631) | N | N | N | N | N | N |
| `env -- GIT_INDEX_FILE=<index> git commit -m x` | [632](../../scripts/tests/hooks.sh#L632) | N | N | N | N | N | N |
| `GIT_DIR=<repo>/.git GIT_INDEX_FILE=<repo>/.git/index git commit -m x` | [633](../../scripts/tests/hooks.sh#L633) | N | N | N | N | N | N |
| `GIT_WORK_TREE=<repo> git commit -m x` | [637](../../scripts/tests/hooks.sh#L637) | N | N | N | N | N | N |
| `GIT_COMMON_DIR=/tmp/other git commit -m x` | [642–645](../../scripts/tests/hooks.sh#L642) | P | P | N | N | P | P |
| `git commit -m x when staged scanning fails` | [652–656](../../scripts/tests/hooks.sh#L652) | N | N | N | N | N | N |
| `git commit --no-verify` | Brief interface | P | P | M | M | P | P |
| `git commit -n` | Brief interface | P | P | M | M | P | P |
| `git commit -m x --no-verify (flag after a variable argument)` | Brief interface | P | P | N | N | P | P |
| `git commit -m x -n (flag after a variable argument)` | Brief interface | P | P | N | N | P | P |

## Tool input and parser failures

| Command form | Hook test lines | Claude interactive | Claude station | Codex interactive | Codex station | OpenCode interactive | OpenCode station |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `Malformed tool JSON beginning with git push` | [80–84](../../scripts/tests/hooks.sh#L80) | N | N | N | N | N | N |
| `Malformed tool JSON beginning with git add -A` | [80–84](../../scripts/tests/hooks.sh#L80) | N | N | N | N | N | N |
| `Malformed tool JSON beginning with git commit` | [80–84](../../scripts/tests/hooks.sh#L80) | N | N | N | N | N | N |
| `` git commit -m "Run `make check` first." (push guard's fail-closed assertion) `` | [108](../../scripts/tests/hooks.sh#L108) | P | P | P | P | P | P |
