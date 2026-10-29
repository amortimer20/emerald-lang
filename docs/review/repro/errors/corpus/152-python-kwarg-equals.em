# Mistake: Python keyword argument with = (line 5). Source: carry-over from Python.
func greet(name: String, times: Int = 1) {
    print(name.repeat(times))
}
greet("Ava", times=2)
