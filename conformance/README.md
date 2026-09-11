# Conformance suite

These cases are written in Emerald, and their expectations are Emerald behavior. They are
deliberately not Zig unit tests: section 19.6 of the rewrite context requires language
semantics to be defined once in backend-neutral tests, and section 23 requires an
end-to-end behavioral test for anything a future backend could inherit incorrectly from its
host. A replacement backend is acceptable only when it passes these same files unchanged.

Run them with `zig build test`. The runner is [`src/conformance.zig`](../src/conformance.zig).

## Layout

| Directory | Assertion |
| --- | --- |
| `valid/` | The program produces no diagnostics. |
| `diagnostics/` | The program produces exactly the text in its `.expected` file. |

Cases run in sorted order, and every case runs even after one fails, so a single run
reports the whole picture.

## Adding a case

For a program that should be accepted, add a `.em` file to `valid/`. Write a complete,
plausible program rather than a fragment: as the parser and checker land, these files are
held to more of the language, and a fragment will start failing for reasons that have
nothing to do with what the case was written to prove.

For a program that should be rejected, add a `.em` file to `diagnostics/` and a `.expected`
file beside it holding the exact output. Generate it by running the compiler from this
directory, so the paths in the expected text stay relative and machine-independent:

```bash
cd conformance
../zig-out/bin/emerald check diagnostics/your-case.em 2> diagnostics/your-case.expected
```

Then read what was generated before committing it. A golden file that was never read only
records what the compiler did, not what it should do. Check the line and column, the width
of the underline, and whether the message and its correction would actually help the person
who hit it — section 17 treats diagnostic text as part of the product, not as debug output.

## Coverage so far

Only encoding and lexical structure are checked, because the parser, checker, and
interpreter do not exist yet. Programs under `valid/` are therefore only proven to
tokenize. As later slices land, these same files start proving more, and cases that assert
program output belong here too.
