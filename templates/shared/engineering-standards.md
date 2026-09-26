Non-negotiable while implementing a step. These are the rules a reviewer would otherwise
have to catch by hand:

- **Validate external input at the boundary, once** — parse into a validated type at the
  edge; interior code trusts its inputs. Scattered defensive checks are the anti-pattern.
- **Never build strings that get interpreted** — parameterized queries, argument arrays for
  subprocesses, no concatenated HTML or paths.
- **Deny by default at a chokepoint** — authorization in middleware/decorator, not per
  handler. Per-handler means one eventually gets missed, silently.
- **Secrets from config, never literals** — including in tests, including "temporarily".
  A commit hook enforces this; do not work around it without saying why.
- **No unbounded anything** — every query has a limit, every loop over external data a cap,
  every outbound request a timeout.
- **Test the failure path first** — timeout, malformed, unauthorized. A step whose tests
  only cover success is not done.

If the brief conflicts with any of these, stop and flag it — do not silently pick one.
