# `throw` is written `raise`.
func check(n: Int) {
    if n < 0 {
        throw RuntimeError("negative")
    }
}
