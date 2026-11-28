# Engineering standards

The practices that make review cheap and bugs rare. [The methodology](../../METHODOLOGY.md)
covers the workflow. The practices below follow the order in which they apply.

### 11.1 Automate what a human should never review

Anything a machine can catch must not cost review attention. In value-per-effort order:

1. **Linter + formatter, failing the build.** Ends style argument permanently and catches a
   real bug class — unused variables, shadowing, unreachable code. Formatting is not a
   review topic.
2. **Static analysis / type checking, strict mode on.** The single highest-yield item if the
   language has it. Strict from day one; retrofitting strictness onto a grown codebase is a
   project, not a setting.
3. **Dependency scanning, blocking on high severity.** `npm audit`, `pip-audit`,
   `cargo audit` or Dependabot. Wire the check into [CI](ci-cd.md#ciyml--job-structure).
4. **Secret scanning at the commit boundary.** The scaffold's Git pre-commit hook runs
   `scripts/hooks/scan-secrets.sh` against the staged diff before the commit exists.
   If a secret reaches a commit, rotate it.

   **Layer scanners; never let one substitute for another.** The hook runs `gitleaks` *and*
   a local pattern set, always both. Treating the local set as a fallback made the hook
   weaker on machines that had gitleaks, whose default config allowlists documented sample
   credentials — a staged AWS example key came back clean and nothing else ran. Any gate
   whose strength depends on which tools happen to be installed will eventually be green for
   the wrong reason: see also `make test` silently skipping `shellcheck`.

> **The ratchet:** when a reviewer catches the same *class* of issue twice, it stops being a
> review comment and becomes a lint rule, a type, or a test. A review that repeats itself is
> a missing automation.

Wire each of these into `make check` / `make test` so local and CI enforce identically —
never into CI alone, or the feedback arrives after the context is gone.

### 11.2 Design stage — before any code

These go in the Feature/Security doc (Part A), not in the implementer's head:

- **Write the interface before the implementation.** Function signatures, endpoint
  contracts, data shapes. Most architecture problems are visible here, where they cost
  nothing to fix, and invisible once there's code to be attached to.
- **Threat-model in one paragraph.** Who are the untrusted actors, what data actually
  matters, what is the worst thing an attacker could do. Ten minutes, mandatory for anything
  touching auth, money, or user data. The Security template has a slot; the Feature template
  now does too.
- **Decide the failure behavior up front.** For each external call: what happens on timeout,
  on a malformed response, on partial success. Decided during coding, these become ad-hoc
  guesses that no one revisits.
- **Choose the simplest design that meets the goal.** Before adding a mechanism (a new
  record, lock, state machine, recovery path or flag), first look for a simpler route:
  - refactor the existing code;
  - reuse a tool that already covers the case, for example Git's own rollback;
  - refuse with clear instructions;
  - print the command for the human to run;
  - accept and document the risk.

  Prefer rolling back over rolling forward when the operation can be undone. A mechanism
  that adds cost to every command, or obliges every future script to take part, needs a
  strong reason.
- **Answer review findings by subtraction first.** A valid edge case does not oblige new
  machinery. For each finding, weigh how likely it is and what it would cost, and offer
  the simpler options alongside "add handling". Revise the design rather than stacking
  patches on it. When scope is cut, also remove the mechanisms that the cut scope
  justified.
- **Show the owner the alternatives in the draft.** When a design adds structure, put the
  simplest workable option beside the recommended one, each with pros and cons, and make a
  recommendation. The owner chooses before approval, not after review rounds.
- **Check existing libraries and tools before building.** Compare "build it" with each
  serious candidate: what it covers, maintenance and license, size and transitive
  dependencies, and how well it fits the stack. List pros and cons and recommend one. A
  dependency that replaces a few lines of code is bloat.
- **Propose versions in a table.** For each runtime or dependency the plan adds or
  upgrades, list the candidate versions (latest stable, LTS where one exists, the current
  pin), with pros, cons and a recommendation. Look current releases up rather than recall
  them ([stack assessment](stack-assessment.md)), and respect the project's support floor.
- **No option without a current user.** Do not add a config key, flag, parameter or
  extension point unless something in this plan uses it.

### 11.3 Coding stage

- **Build it where it belongs, or stop.** Each change lands in the module that owns the
  concern, with clear separation from its neighbours. If it can only be bolted on, stop
  before writing it and recommend the refactor that would make it fit: the planner proposes
  it to the owner, and the executor raises an andon `ask`. Modular does not mean abstract:
  do not add a layer or interface that has one caller.

- **Validate at the boundary, once.** All external input — HTTP, files, env, DB rows — is
  parsed into a validated type at the edge. Interior code then trusts its inputs. Defensive
  checks scattered through the interior is the anti-pattern: it never adds up to a guarantee,
  and it hides where the real contract is.
- **Never build strings that get interpreted.** Parameterized queries, argument *arrays* for
  subprocesses, no string-concatenated HTML or paths. This removes most of the injection
  category by construction rather than by vigilance.
- **Deny by default, at a chokepoint.** Authorization in middleware or a decorator, not
  per-handler. Per-handler means you will eventually miss one, and the miss is silent.
- **Secrets from config, never literals.** Including in tests. Including "temporarily" — the
  commit boundary is where temporary becomes permanent.
- **No unbounded anything.** Every query has a limit, every loop over external data has a
  cap, every outbound request has a timeout.
- **Make illegal states unrepresentable** where the language allows it. A type that cannot
  hold the bad value needs no runtime check and no test.

### 11.4 Verification

- **Test the failure path first.** Everyone tests the happy path; the bugs are in the other
  one. If a step's tests only cover success, the step is not done.
- **Every bug fix starts with a failing test that reproduces it.** This is already the
  contract for [Security fixes](../../METHODOLOGY.md#3-document-types). It prevents
  regressions and helps identify the cause. The brief specifies when to record and verify
  a red-first selector.
- **Test behavior, not implementation.** If a refactor that preserves behavior breaks the
  tests, the tests were asserting the wrong thing and are now blocking the cleanup.

### 11.5 Review

- **Small diffs.** A 200-line PR gets a real review; a 2000-line one gets a rubber stamp.
  The [commit contract](../../METHODOLOGY.md#7-commit-contract) requires one logical
  commit per step. [Issue generation](../../METHODOLOGY.md#6-plan--github-issues) creates
  one issue per independently shippable step.
- **Explain the change in writing before submitting.** Half the problems surface while
  writing the explanation. Use the *why*-first [commit body](../../METHODOLOGY.md#7-commit-contract)
  to describe the problem, approach and scope before review.
- **State each finding's likelihood and cheapest fix.** Say how likely the triggering
  condition is, and name the cheapest remedy that resolves it: refuse, report, roll back,
  accept the risk, or add handling. The planner can then weigh structural cost against the
  case without redoing the analysis.
- **Use a checklist, not vibes.** Minimum viable version, applied to every change:
  1. Is all external input validated at the boundary?
  2. Are the failure paths handled — timeout, malformed, partial?
  3. Is there enough logging to debug this at 2am without a debugger?
  4. Is this the simplest design that works? Could a refactor, an existing tool or a
     refusal replace any new mechanism?
