# Section 9.2's vocabulary. No method changes the string it is called on.

var line = "  apples, pears,,plums  "
var trimmed = line.trim()
print("[" + trimmed + "]", trimmed.split(","), line)
print("[" + line.trim_start() + "]", "[" + line.trim_end() + "]")
print(trimmed.starts_with?("apples"), trimmed.ends_with?("plums"), trimmed.contains?("pear"))
print("one\ntwo\r\nthree\n".lines(), "abc".chars(), "ab".repeat(3), "stressed".reverse())
print("a-b-c".replace("-", " + "), "hello".substring(1, 3), "hello".substring(2))
print("   ".blank?(), "".empty?(), "x".empty?())
print("42".to_int() + 1, " 2.5 ".to_float(), "oops".to_int_or(0), 7.to_string() + "!")

var joined = ""
for word in ["a", "b", "c"] {
    joined += word
}
print(joined, joined.count)
