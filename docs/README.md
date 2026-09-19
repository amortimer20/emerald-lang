# Emerald documentation

This directory is Emerald's canonical documentation source. It lives with the parser,
checker, interpreter, examples, and conformance suite so a language or library change can
update its behavior, tests, and explanation together.

It has two audiences:

- [`language/`](language/) explains how to write Emerald programs.
- [`library/`](library/) records the standard-library surface and its behavior.

`rewrite-context.md` remains the design baseline. The guides and reference translate settled
design into material a programmer can use; they do not silently redefine the language.

## Documentation contract

Every reference entry should state its signature or shape, result, and any observable edge
semantics. Call out these rules where they apply:

- A method ending in `!` changes a value and needs a changeable receiver.
- A result written `T?` can be `nothing` and must be handled as an optional.
- A trailing block is a callback; document its parameters, result requirement, order, and
  whether it may short-circuit.
- A value-dependent failure deserves an explicit **Raises** note and a correction.

Examples should be short Emerald programs. Until a documentation-example runner exists,
prefer a matching file in `examples/` or `conformance/run/` and link to it directly. Do not
copy an example into a guide and treat it as independently authoritative.

## Site boundary

A future Astro site may consume these Markdown sources or a generated form of them. Site
navigation, styling, search, and deployment belong in that presentation project. Language
semantics, API signatures, examples, and cross-links to executable conformance stay here.

## Initial work order

1. Complete the core-language guide outline in [`language/`](language/). Done.
2. Complete the API inventory in [`library/inventory.md`](library/inventory.md). Done.
3. Turn each inventory family into a reference page with runnable examples. Done.
4. Add an automated check that examples referenced by documentation remain executable. Done:
   `bash tools/check-doc-examples.sh` (after `zig build`) confirms every `.em` file a
   documentation page links to still exists, and actually runs every linked `examples/` file
   to completion — `conformance/` links are only checked for existence, since `zig build
   test` already verifies their exact behavior continuously.
