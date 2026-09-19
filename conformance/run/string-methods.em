# Section 9.2's vocabulary. No method changes the string it is called on.

var line = "  apples, pears,,plums  "
var trimmed = line.trim()
print("[" + trimmed + "]", trimmed.split(","), line)
print("[" + line.trim_start() + "]", "[" + line.trim_end() + "]")
print(trimmed.starts_with?("apples"), trimmed.ends_with?("plums"), trimmed.contains?("pear"))
print("one\ntwo\r\nthree\n".lines(), "abc".chars(), "ab".repeat(3), "stressed".reverse())
print("e\u{301}\u{1F44B}".code_points(), "\u{E9}".bytes())
print("a-b-c".replace("-", " + "), "hello".substring(1, 3), "hello".substring(2))
print("caf\u{E9}".insert_at(3, "!"), "cafe\u{301}".remove_suffix("\u{E9}"))
# `substring` and `insert_at` count graphemes: a combining accent and a
# three-person ZWJ family emoji each stay whole rather than splitting.
print("cafe\u{301}s".substring(3, 2), "cafe\u{301}s".substring(4))
print("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}!".insert_at(1, "-"))
print("unhappy".remove_prefix("un"), "happy".remove_prefix("un"), "playing".remove_suffix("ing"), "play".remove_suffix("ing"))
print("baallooon".collapse_repeats())
var (before, separator, after) = "left::right".partition("::")
var (whole, missing, tail) = "whole".partition(":")
print(before, separator, after, whole, "[#{missing}]", "[#{tail}]")
print("hi".pad_start(5, "-"), "hi".pad_end(5, "-"), "hi".pad_center(5, "-"))
print("hi".pad_start(4), "\u{1F44B}".pad_center(4, "\u{1F642}"))
print("   ".blank?(), "".empty?(), "x".empty?())
print("42".to_int() + 1, " 2.5 ".to_float(), "oops".to_int_or(0), 7.to_string() + "!")

var joined = ""
for word in ["a", "b", "c"] {
    joined += word
}
print(joined, joined.count)
