# Section 9.2: `capitalize()` returns an empty string unchanged, a successful
# `remove_prefix`/`remove_suffix` keeps the receiver's remaining original bytes, and
# `to_float` accepts `Infinity`, `-Infinity`, and `NaN`.
print("[#{"".capitalize()}]", "".capitalize().empty?())
const decomposed = "cafe\u{301}!"
const trimmed = decomposed.remove_suffix("!")
print(trimmed.code_points())
print("<cafe\u{301}>".remove_prefix("<").remove_suffix(">").code_points())
print("caf\u{e9}s".remove_prefix("cafe\u{301}"))
print("Infinity".to_float(), "-Infinity".to_float(), "NaN".to_float().nan?())
print("Infinity".to_float() > 1e308, "-Infinity".to_float() < -1e308)
