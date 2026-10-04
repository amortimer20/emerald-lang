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
- Review the staged diff, stage specific files, and use a focused commit message. Commit,
  push, and merge only as the roles below allow; the user's current instructions take
  precedence over them.
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

## Roles and workflow

The user works with two agents, one after the other or side by side, and coordinates them
through this repository.

- **Claude** writes design plans (`docs/<topic>-design-plan.md`) whose decisions carry a
  recommendation for the user to accept or change; reviews the other agent's branches by
  reading the whole diff and running real programs; fixes what review finds and records it in
  the plan; and opens and merges pull requests. The user has given Claude standing permission
  to commit once work is verified, to push its own branches, and to merge a pull request after
  the full local gate passes and CI is green. Claude also makes design choices that come up
  in a review, using Emerald's philosophy, rather than asking.
- **Codex** implements an accepted plan slice by slice on a `codex/<name>` branch, one commit
  per slice with its validation in the message, and updates the handoff and journal before
  each commit. It does not merge. If the plan disagrees with the source, it stops, records the
  mismatch in the plan and handoff, and asks rather than inventing behavior.
- **A plan starts as `Status: proposed`.** Once the user accepts its decisions (often "accept
  your recommendations"), the status becomes `accepted` and the implementing agent begins. Do
  not reopen an accepted decision.
- **Website copy is Claude's.** The user wants one voice on the site, so Codex does not edit
  `emerald-website` prose (pages, install text, release notes). If a code change makes a page
  wrong, say which page and what changed in the handoff, and Claude updates it.
- **Never share a working tree.** Whichever agent the user started in owns the main checkout.
  Claude works from `git worktree` directories under `~/.cache/emerald-worktrees/` (not
  `/tmp`, which environment restarts wipe).
- **Markdown-only changes** (plans, the handoff, the journal, reference pages) may go straight to
  `main` after `zig build test -j1` passes locally; CI skips them. Anything that touches code,
  build files, or workflows goes through a branch, a pull request, and green CI.
- **History:** amending and force-pushing need the user's explicit authorization, as above. A
  plain `git push` from this machine asks for credentials;
  `git -c credential.helper='!gh auth git-credential' push` works.
- **An intermittent test failure is a real bug until shown otherwise.** Do not rerun it until
  it passes or widen a timing margin; find the cause.

## Before changing these areas

- **Built-in members** (`String`, `List`, `Dict`, `Set`, `Int`, `Float`, `Bool`, `Range`,
  `Bytes`, `Math`, `Program`) are written in three places with no shared table: the checker's
  name-check chains (`typeOfBytesMethod` and its siblings), the interpreter's dispatch, and the
  hand-written "did you mean" hint text. The language server offers none of them. Change all
  three, and the docs.
- **The prelude** (`src/prelude.em`) is parsed when Emerald is built, so an unparseable prelude
  fails the build. A run checks only the prelude bodies it reaches (`Checker.reachKey`,
  `prelude_reached`, `Interpreter.requireChecked`), and each body sees only the module variables
  it uses (`moduleViewFor`, `body_module_uses`). A native that calls Emerald code must call
  `Interpreter.reach` on it, and a new namespace needs lines in
  `conformance/run/prelude-reach.em`. Module-level variables in the prelude are unsupported.
- **Typed calls** (`Json.decode`/`Csv.decode(text, as: Type)`, `Json.encode`, `Csv.encode`,
  `Console.table`): the parser reads `as:` as a type only on those callees
  (`Parser.isDecodeCallee`); the checker records the static type in `json_encodes`, keyed by the
  call's callee node; the interpreter reads it back. Anything that copies or rewrites those AST
  nodes breaks the link.
- **Ownership** is described in the header of `src/Heap.zig`: counts must never be too low but
  may be too high, an error unwinding can skip a release (`deinit` frees what is left), and
  closures make cycles, which the collector handles. A native pairs `evaluateBound` with
  `releaseBound`. Debug tests run under the testing allocator, so a leak fails them.
- **Native routing** in `Interpreter.evaluateCall` is a chain of string-key comparisons, and the
  order matters.
- **Generated files** are never edited by hand: `src/unicode/tables.zig` (from
  `tools/unicode/`), `src/tzdata/` (from `tools/update-tzdata.py`), and the prelude's syntax
  tree (from `tools/prelude_ast.zig`).
- **Golden files:** diagnostic wording appears in many `conformance/**/*.expected` files. A
  `runtime-errors` case compares only the failure diagnostic, not standard output.
- **HTTP** is Zig's `std.http.Client` on a threaded `std.Io`, with a `Select` race for the
  deadline. Cancellation and the connection pool are subtle; read the journal entry of
  2026-09-28 before touching it.
- **The large files** (`Checker.zig`, `Interpreter.zig`, `Parser.zig`, `Lsp.zig`) repeat
  patterns, so scripted edits can match the wrong copy. Check the diff.
