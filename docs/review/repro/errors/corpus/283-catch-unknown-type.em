# Mistake: catching a type that does not exist (line 6). Source: carry-over from Python (ValueError).
try {
    var n = "x".to_int()
    print(n)
}
catch error: ValueError {
    print("bad number")
}
