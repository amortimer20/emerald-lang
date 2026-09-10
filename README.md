# Emerald

Emerald is an experimental, statically typed programming language designed to be
approachable for beginners and expressive enough to remain enjoyable as programs grow.

Emerald is being reimplemented from scratch in Zig. The current language baseline,
implementation architecture, staged plan, and evidence-driven roadmap live in
[`docs/rewrite-context.md`](docs/rewrite-context.md).

## Rewrite status

The rewrite is at the executable-specification stage. The first implementation slice will
establish a minimal end-to-end path through source loading, diagnostics, parsing, checking,
and interpretation.

New source, tests, examples, and tools will be added at the repository root as their first
working slices are implemented. Language behavior should follow the rewrite context and
its conformance tests rather than behavior inherited from the implementation host.

## Historical .NET prototype

The original C#/.NET implementation is preserved in
[`legacy/dotnet-v0/`](legacy/dotnet-v0/). It remains useful as design history and as a
source of examples, diagnostics, and tests worth reconsidering. It is not the specification
for the rewrite and is no longer maintained.

The last committed state before the reorganization is tagged `dotnet-v0-final`.
