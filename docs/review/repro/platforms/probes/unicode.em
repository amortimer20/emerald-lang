# Probe: Unicode normalization, case mapping, widths, graphemes.
const samples = ["straße", "İstanbul", "ǅemal", "ΣΑΣ", "ﬁ", "é", "é", "👩‍👩‍👧", "🇬🇧🇫🇷", "क्षि", "한국어", "ᄀᄀᄀ각", "a\u{0301}\u{0327}", "\u{1F44D}\u{1F3FD}", "Ⅻ", "ŉ", "ΐ", "\u{0345}", "ꭰ", "𐐀"]
for s in samples {
    print(s, s.count, s.upper(), s.lower(), s.capitalize(), s.reverse(), s.code_points(), s.chars(), s == s.upper().lower())
}
print("é" == "é", "Å" == "Å", "é" < "f", ["e", "é", "f", "E", "Z", "z", "ä"].sort())
print(Console.table([["中文", "😀👍🏽", "e\u{0301}"], ["ａｂ", "🇬🇧", "x"], ["\u{200B}", "\u{00AD}", "🧑‍🚀"], ["\t", "ᄀ각", "⌚"]], header: ["wide", "emoji", "combining"]))
print("x".pad_start(5, "中"), "中".pad_end(4), "é".pad_center(5, "*"))
