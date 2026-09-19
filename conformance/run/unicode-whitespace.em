# Section 9.2's `trim`/`trim_start`/`trim_end`/`blank?` use Unicode's
# White_Space property, not just ASCII space and tab: a no-break space
# (U+00A0), an em space (U+2003), and an ideographic space (U+3000) are all
# whitespace here.

var padded = "\u{00A0}\u{3000}hello\u{2003}"
print(padded.trim())
print(padded.trim_start(), "|", padded.trim_end())
print("\u{00A0}\u{2028}\u{3000}".blank?(), " ".blank?(), "\u{00A0}x".blank?())
print(padded.count)
