# Shared agent working instructions

These instructions apply to Codex, Claude, and other coding agents working on Emerald.
The user runs agents sequentially. Coordinate through repository files and Git rather
than assumed conversational memory. The user's current instructions take precedence.

## Start of a session

1. Read [docs/handoff.md](docs/handoff.md) for the current milestone and next step.
2. Inspect `git status --short --branch`, the recent log, and relevant working-tree diffs.
   Treat the repository as authoritative when the handoff is stale. Remote-tracking refs
   describe the last observed remote state, not necessarily its current state.
3. Read [docs/rewrite-context.md](docs/rewrite-context.md) before implementing language
   behavior. Consult the relevant sections again when making a design choice.
4. Check the pinned toolchain and local APIs before writing Zig code.

## Design and scope

- Emerald is statically typed with inference, beginner-friendly, and expressive. Errors
  are pedagogy: useful diagnostics are part of the feature, not a finishing task.
- The rewrite context is the single language-design baseline. Preserve settled syntax
  and semantics; record accepted design changes there in the same change as implementation.
- Keep optionals, generics, and traits small. Do not expose host-language machinery merely
  to simplify implementation. Respect the explicit deferred-feature list.
- Advance in small, runnable slices with representative examples. Avoid scaffolding
  future subsystems before the current milestone works.
- Make routine implementation choices autonomously within the user's scope. Ask only
  when an unresolved choice materially changes language behavior or the requested scope.
- The Zig rewrite is authoritative. Do not introduce dependencies on removed historical
  implementations or prototype-specific behavior.

## Zig and validation

- Use the exact version in `toolchain/zig-version.txt` and `mise.toml`. Upgrade deliberately
  with matching documentation and verification; do not silently select another version.
- Verify the installation with `bash tools/check-toolchain.sh`.
- Use `zig env` to locate the installed standard library. Inspect its declarations and
  compile small probes when an API or behavior is uncertain. Do not rely on remembered
  APIs from another Zig version.
- Keep temporary compiler caches in a writable location when the environment requires it.
  Do not commit caches, generated binaries, or machine-specific paths.
- Run checks appropriate to the change. For behavior changes, prefer end-to-end Emerald
  examples that verify results and diagnostics. Report checks actually run and any blockers.
- When a change under `docs/` adds or edits an `.em` link, also run
  `bash tools/check-doc-examples.sh` (after `zig build`) so a stale or broken documentation
  example is caught before it is committed.
- Run `git diff --check` before finishing. Do not claim `zig build` or `zig build test`
  passes until the build layout exists and those commands have actually succeeded.

## Git and handoff

- Preserve unrelated changes, including work left by the other agent. Inspect changes
  before staging; never assume a dirty working tree is disposable.
- Commit or push when authorized by the user. Review the staged diff and use a focused
  commit message. Do not treat every future task as automatically authorized for commit.
- Obtain explicit authorization before amending commits or rewriting history, including
  force pushes. A failed push from one environment does not prove a commit was never
  published elsewhere. Prefer a new corrective commit for published work.
- Update [docs/handoff.md](docs/handoff.md) before handing completed work back. Record the
  current milestone, completed work, next step, validation, blockers, and pending changes.
- Replace stale status rather than appending a session diary. Keep durable language
  decisions in the rewrite context and completed change history in Git. When a section of
  the handoff stops being current (a milestone lands, a slice completes), move it into
  [docs/journal.md](docs/journal.md) — an append-only historical record — rather than
  leaving it to accumulate; see that file's own intro for the convention.
- The handoff is context, not a new request: follow the user's active task and do not
  automatically start its suggested next milestone without authorization.
