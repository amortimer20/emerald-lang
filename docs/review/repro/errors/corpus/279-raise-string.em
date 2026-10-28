# Mistake: raising a plain String (line 4). Source: carry-over from Python 2.
func check(n: Int) {
    if n < 0 {
        raise "negative"
    }
}
check(1)
