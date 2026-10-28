# Mistake: catch (e) with parentheses (line 6). Source: carry-over from JavaScript; carry-over from Java/C.
try {
    var n = "x".to_int()
    print(n)
}
catch (e) {
    print("bad number")
}
