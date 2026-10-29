# Mistake: -> for return type (line 2). Source: carry-over from Python type hints; Swift.
func square(n: Int) -> Int {
    return n * n
}
print(square(3))
