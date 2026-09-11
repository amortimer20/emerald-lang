# Current handoff

Updated: 2026-09-10. Prepared by Codex for the next agent session.

## Current milestone

Repository preparation for the Zig rewrite. Language design is consolidated; the new
Emerald interpreter has not been implemented. The user requested shared documentation
for sequential work by Codex and Claude. That documentation is now prepared.

## Completed foundation

- The .NET prototype is archived under `legacy/dotnet-v0/`. Its pre-reorganization commit
  is tagged `dotnet-v0-final` at `1f33083`.
- [rewrite-context.md](rewrite-context.md) is the canonical language and architecture
  baseline. The implementation host is Zig.
- Zig `0.16.0` is pinned through [mise.toml](../mise.toml) and
  [toolchain/zig-version.txt](../toolchain/zig-version.txt).
- [tools/check-toolchain.sh](../tools/check-toolchain.sh) verifies the exact version,
  compiles the smoke probe, and runs the resulting executable using temporary caches.
- Latest observed commit: `2187c0c` — `Pin Zig 0.16.0 and add toolchain smoke check`.
  At session start, local `main` matched the local `origin/main` tracking reference.

## Next concrete step

When the user resumes implementation, establish the minimal Zig build layout and source
diagnostics. Inspect Zig 0.16.0's local build APIs before writing `build.zig`. Add
`zig build` and `zig build test`, then source loading and source spans with one useful
diagnostic. There is no root `build.zig`, parser, checker, or interpreter yet.

The first runnable Emerald milestone discussed is integer arithmetic, `var`/`const`,
name and type checking, and `print`:

```emerald
var score = 2 + 3 * 4
print(score) # 14
```

Keep each implementation step small and reviewable. Later language features follow the
sequence in the rewrite context.

## Validation and blockers

- The Zig smoke probe previously compiled and ran successfully with output
  `0.16.0` and `Zig toolchain ready.`
- This handoff change is documentation only; validate its links and whitespace.
- No known blocker to the initial Zig slice. The earlier Odin linker problem does not
  apply to the successful Zig probe.
- Git authentication depends on the environment. Earlier agent pushes lacked credentials;
  the user subsequently synchronized the baseline. Inspect current state before pushing.

## Pending changes

This documentation task adds `AGENTS.md`, `CLAUDE.md`, and `docs/handoff.md`, and links
them from the root README. These changes are uncommitted. No implementation work or
commit/push was requested in this task. Verify the actual diff before continuing.
