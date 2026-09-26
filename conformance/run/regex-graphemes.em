# Section 15.4 matches characters as `count` sees them: graphemes, compared
# canonically, as `==` does.
const composed = "caf\u{E9}"
const decomposed = "cafe\u{301}"
print(composed == decomposed, composed.count, decomposed.count)
print(Regex('caf\u{E9}').matches?(decomposed), Regex('cafe\u{301}').matches?(composed), Regex('café').matches?(decomposed))
print(Regex('caf.').matches?(decomposed), Regex('e').contains_match?(decomposed))

# A set decides by a character's first code point in its composed form, so
# é is not in [a-z] however it is written, but is in [é] both ways.
print(Regex('[a-z]+').matches?(decomposed), Regex('[a-z]+').matches?(composed))
print(Regex('caf[é]').matches?(decomposed), Regex('caf[é]').matches?(composed))

# `.` is one whole character, an emoji family or flag included.
const family = "👨‍👩‍👧"
print(family.count, Regex('^.$').matches?(family), Regex('.').find_all("a🇯🇵b👍🏽").count)

# "\r\n" is one character, a line break, which `.` does not match.
print("a\r\nb".count, Regex('a.b').matches?("a\r\nb"), Regex('a\r\nb').matches?("a\r\nb"), Regex('a\sb').matches?("a\r\nb"))
print(Regex('^b', multiline: true).find("a\r\nb"))

# \w covers every script's letters, marks, and digits; \d is only 0 to 9, so
# what it matches always converts with to_int.
print(Regex('\w+').find_all("naïve Ωmega 東京 x_1"))
print(Regex('\d+').find_all("12 ٣٤ 56"))

# Options: ignore_case compares by Unicode case folding, and multiline makes
# ^ and $ match at every line.
print(Regex('hello', ignore_case: true).find_all("Hello HELLO hello"))
print(Regex('ÉTÉ', ignore_case: true).matches?("été"), Regex('[a-z]+', ignore_case: true).matches?("ABC"))
print(Regex('^\w+$', multiline: true).find_all("one\ntwo words\nthree"), Regex('^\w+$').find_all("one\ntwo"))
