# Mistake: try with no catch or finally (line 2). Source: carry-over from Java/C.
try {
    var n = "x".to_int()
    print(n)
}
print("done")
