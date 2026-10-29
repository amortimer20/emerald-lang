# Mistake: ?? or ?: for a fallback (line 3). Source: carry-over from C#/Kotlin/JS.
var n = "5".to_int_maybe()
print(n ?? 0)
