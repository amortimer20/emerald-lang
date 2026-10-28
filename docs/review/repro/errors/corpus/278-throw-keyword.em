# Mistake: throw instead of raise (line 4). Source: carry-over from Java/C; carry-over from JavaScript.
func check(n: Int) {
    if n < 0 {
        throw RuntimeError("negative")
    }
}
check(1)
