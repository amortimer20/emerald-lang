# Section 9.2's text tools: joining, words, character tests, and code points
# back to characters.

print(["Ada", "Grace", "Alan"].join(", "))
print(["a", "b", "c"].join(), "|" + ["x"].join("-") + "|")
const nobody: List[String] = []
print("[" + nobody.join(", ") + "]")
print("olleh".chars().reverse().join())

print("  the  quick\tbrown\nfox ".words())
print("".words(), "   ".words(), "one".words())
# A combining accent after a space belongs to the space, not to the next word.
print("a \u{301}b".words().count, "a \u{301}b".words()[1] == "b")

# Every character passes, and an empty string never does.
print("abc".letter?(), "é".letter?(), "日本".letter?(), "e\u{301}".letter?())
print("a1".letter?(), "".letter?(), "".digit?(), "".whitespace?())
print("2026".digit?(), "٣".digit?(), "-1".digit?())
print(" \t\n".whitespace?(), "a b".whitespace?())
print("ABC".upper?(), "A1".upper?(), "1".upper?(), "Ab".upper?())
print("abc".lower?(), "ß".lower?(), "a!".lower?(), "".lower?())
# A titlecase letter such as ǅ is neither all capitals nor all small.
print("ǅ".upper?(), "ǅ".lower?())

const password = "hunter2"
print(password.chars().any? { character => character.digit?() })

print(97.to_character(), 65.to_character(), 128512.to_character(), 0.to_character().count)
print("Hi".code_points().map { code => code.to_character() }.join())

func shift(letter: String, by: Int): String {
    const start = "a".code_points()[0]
    const position = (letter.code_points()[0] - start + by) % 26
    return (start + position).to_character()
}
print("yza".chars().map { letter => shift(letter, 3) }.join())
