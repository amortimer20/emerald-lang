# selftest

The test-only vendor library (docs/vendor-libraries-design-plan.md, decision 13). It proves
the mechanism without a real library, and it is the model for the next library: a copy of it
with the names blanked is `vendor/_template`.

## Upstream

- Project and URL: none. `selftest.c` is written for Emerald and is about a hundred lines.
- Version and hash: not applicable.
- License: Emerald's own (MIT, in `LICENSE`).
- Why this library: every kind of value a native can take or give, an error with help, and a
  handle that must be closed, so the loader, the call path, the resolver's load-on-name, and
  the checks run on every platform in CI.

## What it exposes

`Selftest.add`, `halve`, `invert`, `shout`, `reverse`, `ping`, `fails`, `open_count`, and
`counter`, a `SelftestCounter` with `next` and `close`, and `SelftestError`. Each is a short
Emerald function over a native named `_something`.

## What it leaves out, and why

Nothing that a vendor library needs is left out; the library never ships, and a program can
name it only when `EMERALD_VENDOR_TEST` is set or the conformance suite is running.

## Build

`zig build vendor-test-modules` builds `emerald-selftest` for the host and installs it in
`zig-out/vendor-test-modules/`. It links only the C library.

## Testing

`conformance/vendor/selftest/` and `conformance/vendor-errors/selftest/` run its programs;
`conformance/diagnostics/vendor-wrong-argument.em` checks a type error against its declaration.
To try it by hand:

```bash
EMERALD_VENDOR_TEST=1 EMERALD_MODULE_PATH=zig-out/vendor-test-modules zig-out/bin/emerald run conformance/vendor/selftest/values.em
```
