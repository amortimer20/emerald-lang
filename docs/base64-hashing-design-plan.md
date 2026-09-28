# Base64 and hashing: design and implementation plan

Status: accepted, 2026-09-28. The user accepted all five recommendations below. Rewrite-context
15.7 lists "`Base64` and one or two hash/digest functions" as small utilities with no open
design question; writing the plan turned up a few, and they are settled here. Slice 1 is next.

The executor makes the remaining judgement calls within a slice and records each one under
that slice's "Settled while building" note. At the start of each slice, reread `git status`,
the recent `git log`, and docs/handoff.md.

## What beginner programs need

The API is judged by these programs. Each should read naturally, and a mistake should say what
was wrong and where.

```emerald
# Sign in to an API that uses HTTP Basic authentication.
const credentials = Base64.encode("ada:lovelace".to_bytes())
const response = Http.get("https://api.example.com/me",
    headers: ["Authorization": "Basic #{credentials}"])

# Put a small image straight into a web page.
const logo = Base64.encode(File.read_binary("logo.png"))
File.write("page.html", "<img src=\"data:image/png;base64,#{logo}\">")

# Read a value an API sent as Base64.
const note = Base64.decode(response.json()["note"].string()).to_string()

# Check that a download arrived intact.
const expected = File.read("emerald.zip.sha256").split(" ")[0].trim()
const actual = Digest.sha256(File.read_binary("emerald.zip")).to_hex()
if actual == expected {
    print("The download is intact.")
} else {
    print("The download is damaged: try again.")
}

# Tell whether two files hold the same data without comparing them byte by byte.
print(Digest.sha256(File.read_binary("a.png")) == Digest.sha256(File.read_binary("b.png")))
```

## Principles

1. **Text and bytes stay separate.** Base64 and digests work on `Bytes`, because that is what
   they are defined on. A program converts text with `to_bytes()` and back with `to_string()`,
   the same two steps it already uses for binary files. `Base64.encode("hi")` is a checking
   error whose hint says to write `"hi".to_bytes()`, in the style of the existing `+` hint
   for Bytes (`Checker.zig`, "`+` joins two Bytes").
2. **Errors say where.** A bad Base64 or hex character is reported with its index and the
   character itself; a length that cannot be right says so in words.
3. **One obvious name per job.** One Base64 codec with one option, one digest, and one hex
   form. Nothing broken is offered, so nothing broken gets copied out of a tutorial.
4. **A digest is not `hash()`.** `Hashable.hash()` is a per-run value for dictionaries, which
   15.7 and 8.4 say must never be saved or shown. A digest is the opposite: the same input
   gives the same result on every machine forever. The two get different names so that a
   student never mixes them up (decision 1).

## Verified constraints (checked against source, 2026-09-28)

- **Zig 0.16's standard library has everything needed:**
  - `std.base64` has `standard`, `standard_no_pad`, `url_safe`, and `url_safe_no_pad` codecs.
  - `std.crypto.hash.sha2.Sha256` gives SHA-256.
  - `std.crypto.auth.hmac` gives HMAC, if decision 4 takes it.
  - Nothing new is vendored, and `THIRD_PARTY_NOTICES.md` does not change.
- **`Bytes` instance members are checker and interpreter special cases**, not prelude methods:
  - checking is around `Checker.zig`'s `to_bytes`/`to_string_maybe` handling;
  - running is around `Interpreter.zig`'s Bytes method dispatch (`"to_bytes"`, `"to_string_maybe"`).
  - `to_hex` joins them there. `Bytes.from_hex` is a type-level function beside `Bytes.from_list` in the prelude's
    `class Bytes`, routed the way `from_list` is.
- **Native namespaces route by prelude key** in `Interpreter.evaluateCall`: see the
  `.Json::` and `.Http::` prefixes. `Base64` and `Digest` follow the same pattern, as
  prelude classes whose bodies give the type-level signatures, like `class File` and
  `class Http`.
- **`Bytes.to_string()` on invalid UTF-8 raises a `FileError`** (`raiseFileMessage`, "these
  Bytes are not valid UTF-8 text"), although the bytes may never have touched a file. That
  becomes an `EncodingError` (decision 3).
- **A run checks only the prelude bodies its program reaches**, and the prelude is parsed
  when Emerald is built (startup milestone). New prelude classes cost nothing for programs
  that do not use them. Measure anyway with `tools/startup-benchmark.py`, as the CSV
  milestone did, and add `Base64` and `Digest` lines to `run/prelude-reach`.
- **Python's `base64`, `binascii`, `hashlib`, and `hmac` modules** serve as differential
  references, as Python's `json` and `csv` did (`tools/json/differential.py`).

## Proposed API

All of it is in the `Emerald` namespace.

```emerald
# Base64 (RFC 4648)
Base64.encode(bytes: Bytes, url_safe: Bool = false): String
Base64.decode(text: String, url_safe: Bool = false): Bytes
Base64.decode_maybe(text: String, url_safe: Bool = false): Bytes?

# Digests
Digest.sha256(bytes: Bytes): Bytes                        # 32 bytes
Digest.hmac_sha256(bytes: Bytes, key: Bytes): Bytes       # decision 4

# Hexadecimal, on Bytes itself
bytes.to_hex(): String                                    # "0aff", lowercase
Bytes.from_hex(text: String): Bytes                       # either case
Bytes.from_hex_maybe(text: String): Bytes?

class EncodingError extends RuntimeError {}
```

- **`Base64.encode`** writes the standard alphabet (`+`, `/`) with `=` padding. With
  `url_safe: true` it writes `-` and `_` and no padding (decision 2).
- **`Base64.decode`**:
  - It takes the same alphabet choice.
  - It accepts text with or without its padding.
  - It ignores spaces and line breaks, because Base64 in email, PEM files, and copied
    terminal output is wrapped.
  - It rejects every other character not in the alphabet, which includes the other
    alphabet's `+`/`/` or `-`/`_`, so a mix-up is reported rather than guessed.
  - Leftover bits in the last character that are not zero are rejected too, so every
    `Bytes` value has exactly one encoding and decoding round-trips.
- **`Digest.sha256`** returns the 32 raw bytes. `to_hex()` is the form people compare and
  print. Returning `Bytes` keeps a digest usable as an HMAC key or as input to another
  digest, and costs the common case one short call.
- **`to_hex` and `from_hex`** use two digits per byte, with no separators and no `0x`.
  `from_hex` accepts upper and lower case, and rejects an odd length or a non-hex character.
  Surrounding spaces are not trimmed, because a checksum file's trailing newline should be
  removed with `trim()`, visibly, by the program.
- **Each decoder has a `_maybe` form** that returns `nothing` instead of raising, following
  `Json.parse_maybe`, `Date.parse_maybe`, and `Bytes.to_string_maybe`. It suits checking
  whether text is valid at all; the raising form is for when the message matters.

## Decisions

All five were accepted as recommended on 2026-09-28. The alternatives are kept for the record.

1. **The digest namespace is `Digest` (recommended),** because `Hash` would read as the
   dictionary `hash()` of `Hashable`, whose values are deliberately unstable (8.4, "Hash
   values … are runtime details"). Alternatives: `Hash` (Ruby's `Digest` and Python's
   `hashlib` split the difference), or methods on `Bytes` such as `bytes.sha256()`, which
   are easier to discover through completion but put a cryptographic algorithm on a basic
   data type.
2. **URL-safe Base64 writes no padding (recommended).**
   - URL-safe is used in URLs and tokens (JWT, RFC 7515), where `=` must itself be escaped
     and the standards drop it.
   - Decoding accepts either form, so nothing is lost.
   - Alternative: a second option, `padding: Bool`, which adds a choice a beginner has no
     reason to make.
3. **One `EncodingError` for Base64, hex, and UTF-8 (recommended).**
   - `Base64.decode`, `Bytes.from_hex`, and `Bytes.to_string()` on invalid UTF-8 all raise
     `EncodingError`, which extends `RuntimeError`.
   - This fixes `to_string()` raising a `FileError` for bytes that may never have been in a
     file. A `catch RuntimeError` still catches it; only a `catch FileError` that relied on
     the old type changes, and that was the bug.
   - Alternative: separate `Base64Error` and `HexError`, with `to_string()` left as it is.
4. **Digests: SHA-256, plus HMAC-SHA256 (recommended).**
   - SHA-256 covers checksums and "are these the same file".
   - HMAC-SHA256 is the other thing an HTTP program meets: verifying a webhook's signature,
     or signing a request to an API that asks for it. It is one more function over code Zig
     already has.
   - MD5 and SHA-1 are deliberately not provided. Both are broken for security; a student
     checking an old download that lists only one of them is the one case that loses out.
   - The reference says, once and plainly, that none of these are for storing passwords,
     and what to use instead is out of Emerald's scope for now.
   - Alternative: SHA-256 alone, adding HMAC when a program asks for it.
5. **Hex lives on `Bytes` (recommended),** since it is how a program shows any bytes, not just
   digests, and `Bytes` already prints in hex (`Bytes[3: 41 00 ff]`). Alternative: a `Hex`
   namespace (`Hex.encode`, `Hex.decode`) that mirrors `Base64`.

## Errors

`EncodingError` extends `RuntimeError`. Match these messages in wording; indexes count
characters from 0, as string indexing does.

| Case | Message |
|---|---|
| Bad Base64 character | ``Base64 text has `%` at index 12, which is not a Base64 character`` |
| Wrong Base64 alphabet | ``Base64 text has `-` at index 4, which belongs to URL-safe Base64`` with the help ``Decode it with `url_safe: true`.`` (and the reverse for `+` and `/` with `url_safe: true`) |
| Bad length | ``Base64 text ends partway through a group: it has 1 character too many, or is missing some`` |
| Misplaced padding | ``Base64 text has `=` at index 6, before its end`` |
| Nonzero leftover bits | ``Base64 text's last character, `R` at index 3, is not a possible final character`` with help naming the canonical one when there is one |
| Bad hex character | ``hex text has `g` at index 5, which is not a hex digit`` |
| Odd hex length | ``hex text has 7 digits, but every byte takes two`` |
| Invalid UTF-8 | ``these Bytes are not valid UTF-8 text`` (unchanged wording, new type) |

The checker reports the wrong argument type before the program runs:

| Call | Message | Help |
|---|---|---|
| `Base64.encode("hi")` | ``Base64.encode takes Bytes, but this is String`` | ``Convert text with `"hi".to_bytes()`.`` |
| `Digest.sha256("hi")` | ``Digest.sha256 takes Bytes, but this is String`` | ``Convert text with `"hi".to_bytes()`.`` |

## Slices

Each slice ends with the full validation below passing, and one commit or a short series of
commits.

### Slice 1: `EncodingError` and hex

- Add `EncodingError` to the prelude beside the other error classes.
- Make `Bytes.to_string()` raise it (decision 3), and update every test or doc that names the
  old type.
- Add `bytes.to_hex()`, `Bytes.from_hex(text)`, and `Bytes.from_hex_maybe(text)`, with the checker's type and the
  interpreter's behaviour.
- Conformance: `conformance/run/bytes-hex.em` covers the empty value, every byte value
  round-tripping, mixed case, and each error; `conformance/diagnostics/` covers a wrong
  argument type.
- Settled while building: hex input is walked as Emerald grapheme characters, not UTF-8
  bytes, so a non-ASCII invalid character receives the same index a program would see with
  string indexing. `to_hex` allocates its ordinary String result directly in the shared
  immutable text storage, as `Bytes` itself already does. `EncodingError`'s uncaught
  diagnostic help is deliberately general ("Check that this text uses the expected
  encoding."), because the caught message gives the precise Base64, hex, or UTF-8 cause.

### Slice 2: Base64

- `Base64.encode`, `decode`, and `decode_maybe` as natives over `std.base64`, with the rules above.
  - `std.base64`'s decoder rejects whitespace and does not report where it failed. Expect to
    write a small wrapper that skips whitespace and finds the offending index for the message.
  - Check the canonical-final-character rule explicitly; do not assume the library enforces
    it.
- The checker's special case for a `String` argument, with its help.
- Known-answer tests:
  - RFC 4648 §10 (`""`, `f`, `fo`, `foo`, `foob`, `fooba`, `foobar`) in both alphabets;
  - text wrapped at 76 characters;
  - each error in the table.
- `tools/base64/differential.py`:
  - random byte strings of lengths 0–300, compared against Python's `base64.b64encode` and
    `urlsafe_b64encode` (with `=` stripped for URL-safe);
  - decoding of random valid and corrupted text, compared against `base64.b64decode(...,
    validate=True)` after the documented whitespace removal.
  - Report the case count and seed, as the JSON and CSV differentials do.
- Settled while building: decoding removes ASCII spaces, tabs, and line endings before
  validation, then uses Zig's no-padding codec after explicitly accepting and checking a
  standard padding suffix. This makes the accepted padded and unpadded forms one path while
  keeping a character-indexed Emerald error before Zig sees malformed input.

### Slice 3: Digests

- `Digest.sha256`, and `Digest.hmac_sha256` if decision 4 is accepted.
- Known-answer tests:
  - FIPS 180-4 examples for SHA-256 (`""`, `"abc"`, the 448-bit two-block message, and one
    million `a`s);
  - RFC 4231 test cases 1–4 and 6–7 for HMAC-SHA256, including a key longer than the
    block size.
- Extend the differential tool (or add `tools/digest/differential.py`) against `hashlib` and
  `hmac` for random inputs.
- Settled while building: (record here)

### Slice 4: Documentation and integration

- Reference pages:
  - `docs/library/base64.md` and `docs/library/digest.md`;
  - `bytes.md` gains hex and the new error type;
  - `errors.md` lists `EncodingError`;
  - a row in `inventory.md`;
  - a password warning in `digest.md`.
- `examples/encoding.em`, runnable, built from the programs at the top of this plan, without
  the network call (use a fixed string where the HTTP response was).
- Rewrite-context:
  - a new 15.12 records the settled design and the decisions;
  - 15.7's backlog marks "Small utilities" as done;
  - section 22 gets a row for any decision that closes an alternative.
- A fuzz template for valid programs using `Base64`, `Digest`, and hex, and a
  `run/prelude-reach` line for each namespace.
- Update docs/handoff.md and add a journal entry.
- Settled while building: (record here)

## Validation

Every slice must pass, on the pinned Zig 0.16.0 and with `-j1`, since parallel builds run out of
memory on the development machine:

- `zig build test -j1` in Debug and ReleaseSafe;
- `zig build -j1`;
- `bash tools/check-doc-examples.sh`;
- `zig fmt --check` on changed Zig files;
- `git diff --check`;
- Windows and macOS cross-builds.

Slices 2 and 3 must also have their differential tools run clean, with the case count and
seed recorded in the commit message.

Slice 4 must also pass an alternating ReleaseSafe startup comparison against `main` with
`tools/startup-benchmark.py`, showing no measurable cost for a program that does not use these
namespaces.

## Out of scope

These are deliberately not in this plan:

- streaming digests over a file read in pieces;
- other digests (SHA-512, BLAKE3) and the broken ones (MD5, SHA-1);
- password hashing;
- encryption, random tokens (`Random` is not cryptographic, and a secure-random source is its
  own design question);
- Base32 and Base85;
- percent-encoding (the HTTP client already builds query strings).

Each needs a concrete program to earn it, per 15.1.
