# Regex

A `Regex` is a pattern for finding text: `Regex('\d+')` matches one or more digits. Write
patterns in single quotes, which keep every backslash as it is. Run
[`examples/regex.em`](../../examples/regex.em) for the programs below, and
[`conformance/run/regex-basics.em`](../../conformance/run/regex-basics.em),
[`conformance/run/regex-replace-split.em`](../../conformance/run/regex-replace-split.em),
[`conformance/run/regex-groups.em`](../../conformance/run/regex-groups.em), and
[`conformance/run/regex-graphemes.em`](../../conformance/run/regex-graphemes.em) for the
details.

```emerald
const numbers = Regex('\d+').find_all("3 apples, 12 pears").map { found => found.text.to_int() }
print(numbers.sum())                                  # 15
print(Regex('[,\s]+').split("red, green,blue"))       # ["red", "green", "blue"]
print(Regex('\s+').replace_all("too    many   spaces", " "))
```

No pattern can hang a program: matching takes time in proportion to the pattern times the
text, whatever the pattern. That is why Emerald's patterns have no backreferences or
lookaround, which other languages' engines pay for by sometimes taking exponential time.

A character is a grapheme here, as everywhere in Emerald: `.` matches `é`, an emoji, or a
flag whole, however many code points it has, and positions count characters as indexing
does. Text is compared canonically, as `==` compares it, so `Regex('é')` matches `é` whether
it was typed as one code point or as `e` and a combining accent.

## Regex(pattern: String, ignore_case: Bool = false, multiline: Bool = false) -> Regex

A pattern, checked when it is built. `ignore_case: true` compares letters without regard to
case (by Unicode simple case folding). `multiline: true` makes `^` and `$` match at the start
and end of every line, not only of the whole text.

**Raises** `RegexError` for a pattern that is not valid. The message quotes the pattern, gives
the position of the problem in it (counting characters from 0), and says what to write
instead. A pattern written as a string literal is checked before the program runs, and the
mistake is reported at the character inside the literal, in `emerald check` and in an editor
alike; see
[`conformance/diagnostics/regex-literal-pattern.em`](../../conformance/diagnostics/regex-literal-pattern.em)
and [`conformance/run/regex-errors.em`](../../conformance/run/regex-errors.em).

## Regex.escape(text: String) -> String

A pattern that matches `text` exactly: every character with a meaning in patterns gets a
backslash. `Regex(Regex.escape("$4.99"))` finds a price, not "any character".

## pattern -> String, ignore_case -> Bool, multiline -> Bool

What the regex was built from. A `Regex` prints as its pattern, and two are equal when their
patterns and options are, so a `Regex` can be a `const` or a dictionary key.

## matches?(text: String) -> Bool

Whether the whole of `text` matches: `Regex('\d+').matches?("42")` is `true`, and
`matches?("42 cats")` is `false`.

## contains_match?(text: String) -> Bool

Whether some part of `text` matches.

## find(text: String) -> Regex.Match?

The first match, or `nothing`. Among matches that start at the same place, the pattern's own
preferences decide: repetition takes as much as it can (`*`, `+`, `?`, `{2,5}`) or, followed
by `?`, as little; and the first alternative of `x|y` that matches wins.

## find_all(text: String) -> List[Regex.Match]

Every match, from left to right, none overlapping. After a match of nothing, the search moves
on one character, so `Regex('x*').find_all("ab")` finds three empty matches, at 0, 1, and 2. A
match of nothing just where the previous match ended does not count.

## replace(text: String, replacement: String) -> String

`text` with its first match replaced. The replacement is used exactly as written: `"$1"` is
a dollar sign and a one, never a group. To use a match's groups, use `replace_each`.

## replace_all(text: String, replacement: String) -> String

`text` with every match replaced, as `find_all` finds them.

## replace_each(text: String, block { found: Regex.Match => String }) -> String

`text` with each match replaced by what the block returns for it:

```emerald
print(Regex('\d+').replace_each("3 apples") { found => (found.text.to_int() * 2).to_string() })   # 6 apples
```

## split(text: String) -> List[String]

The pieces of `text` between matches. Empty pieces are kept, as `String.split` keeps them:
`Regex(',').split(",a,,b")` is `["", "a", "", "b"]`. A match of nothing at the very start or
end of the text splits nothing off, so a pattern that matches nothing splits between every
character: `Regex('').split("abc")` is `["a", "b", "c"]`.

## Regex.Match

One match, from `find`, `find_all`, or `replace_each`. It prints as
`Regex.Match("42" at 3..<5)`. A program cannot build one itself.

### text -> String, start -> Int, end -> Int

The matched text and where it is: `text[found.start..<found.end]` is `found.text`.

### group(number: Int) -> String

A group's text. Group 0 is the whole match; groups 1 and up count opening parentheses from the
left, so in `((\w+)@(\w+))`, group 1 is the whole address and groups 2 and 3 its parts. A
group repeated by `*` or `+` holds what it matched the last time round.

**Raises** `RegexError` when the group took no part in the match, as `(x)?` without an `x`, or
the branch of `(a)|(b)` not taken; and when the pattern has no such group, naming the groups
it has.

### group_maybe(number: Int) -> String?

As `group`, but `nothing` for a group that took no part in the match. Asking for a group the
pattern does not have still raises, since that is always a mistake.

### named(name: String) -> String

The text of the group written `(?<name>...)`. **Raises** as `group` does.

### named_maybe(name: String) -> String?

As `named`, but `nothing` for a group that took no part in the match.

## Patterns

| Pattern | Matches |
| --- | --- |
| `a`, `\.`, `\\`, `\n`, `\t`, `\u{1F600}` | That character; punctuation after a backslash always means itself |
| `.` | Any one character except a line break (`\n`, or `\r\n`, which is one character) |
| `[abc]`, `[a-z]`, `[^0-9]`, `[\w-]` | One character in (or, with `^`, not in) the set |
| `\d` `\D` | A digit 0 to 9, and not |
| `\w` `\W` | A word character: a letter, mark, or decimal digit in any script, or connector punctuation such as `_`; and not |
| `\s` `\S` | White space, and not |
| `^` `$` | The start and end of the text, or of any line with `multiline: true` |
| `\b` `\B` | A boundary between a word character and anything else, and not |
| `x*` `x+` `x?` `x{3}` `x{2,}` `x{2,5}` | Repetition, as many as possible (at most 1000 for a count) |
| `x*?` `x+?` `x??` `x{2,5}?` | Repetition, as few as possible |
| `x\|y` | Either, preferring the first |
| `(x)` `(?<name>x)` `(?:x)` | A numbered group, a named group, and a group that captures nothing |

A character belongs to a set by its first code point in composed form, so `[a-z]` does not
match `é` (the accent is part of the character), while `[é]` does. A range such as `[a-z]`
runs by code point.

## Differences from other languages

Most patterns written for JavaScript, Python, Java, Go, or Rust work unchanged. These
differences are deliberate:

- **No backreferences, lookahead, lookbehind, atomic groups, or possessive repetition**
  (`\1`, `(?=`, `(?<=`, `(?>`, `a++`). They are what can make matching take exponential time.
  Each is refused with a message saying so, never treated as literal text.
- **Options are named arguments,** not inline flags: write `Regex('abc', ignore_case: true)`,
  not `(?i)abc`. Named groups are `(?<name>...)`, not Python's `(?P<name>...)`. Write `^`
  and `$` rather than `\A` and `\z`. Unicode property classes such as `\p{L}` are not
  supported yet.
- **`.` and sets see whole characters,** not code points, and text compares canonically, as
  everywhere in Emerald. Positions count characters, as indexing does.
- **`\d` is only 0 to 9,** so what it matches always converts with `to_int`. `\w` covers
  every script's letters and digits.
- **`$` matches only at the very end** (or a line's end with `multiline: true`), not also
  before a final line break as in Python and Perl.
- **Replacement text is literal:** `$1` and `\1` mean themselves. Compute replacements with
  `replace_each`.
- **A repeated group never takes an empty round:** `(a|)*` on `"b"` leaves group 1 unset,
  where Python and Perl report it as `""`. Go, Rust, and RE2 behave as Emerald does.
- **`\B` matches an empty text,** which has no word boundary, as in Go and Rust.
- **Empty matches in `find_all` and `split`** follow Go and Rust: none just where the last
  match ended, and none splitting off the start or end of the text.

## RegexError

A `RuntimeError` for a pattern that is not valid, or a group a match does not have. See
[`conformance/runtime-errors/regex-invalid-pattern.em`](../../conformance/runtime-errors/regex-invalid-pattern.em).
