# Starting a project — assess the stack first

Before the first line of code on a new project (and when adopting the scaffold into a young
one), **establish what the current stack actually is, then install a modern version of it.**
An agent's default is training-data recall, which skews stale by months to years — it will
happily scaffold last year's major version and pin it.

1. **Assess what's there.** For an existing project: read the manifests and lockfiles
   (`package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`, …) and the installed toolchain
   versions (`node -v`, `python -V`, `cargo -V`, …). Note anything already end-of-life.
2. **Check what's current.** Look up current stable releases from release notes / changelogs
   / official docs — not from memory. Note the LTS line where one exists.
3. **Choose deliberately.** Default to the current stable (or current LTS for runtimes).
   Deviate only for a stated reason — a peer dependency's ceiling, a platform constraint, a
   known-bad release — and write that reason down in `CLAUDE.md` → Gotchas.
4. **Pin it where it executes.** Versions live in the manifests, lockfiles, and `Makefile` —
   the places that run. Prose in `CLAUDE.md` explains; it doesn't pin.
5. **Verify green before building on it.** `make check && make test` on the fresh stack, so a
   later failure is attributable to your code and not the scaffold.

The same discipline applies mid-project when adding a dependency: check the current version
rather than typing the one you remember.
