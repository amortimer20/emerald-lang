# Section 15.4: a pattern written as a string literal is compiled before the
# program runs, and a mistake is reported at the character where it is.
const unclosed = Regex('(\d+')
const lookahead = Regex('price(?= USD)', ignore_case: true)
const named = Regex(pattern: '[z-a]')
const emoji = Regex('😀 x{5,2}')

# With escapes in the literal, the report covers the whole literal and gives
# the position within the pattern.
const escaped = Regex("caf\u{E9}[")

# Valid patterns, and patterns built as the program runs, are not reported.
const valid = Regex('\d+')
const built = Regex("(" + "a")
