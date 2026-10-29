# Mistake: except instead of catch (line 6). Source: carry-over from Python.
try {
    var n = "x".to_int()
    print(n)
}
except error: RuntimeError {
    print("bad number")
}
