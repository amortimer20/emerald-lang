print(double(4))
print(even_ish(10))

func double(n: Int): Int {
    return n * 2
}
func even_ish(n: Int): Bool {
    return if n == 0 then true else odd_ish(n - 1)
}
func odd_ish(n: Int): Bool {
    return if n == 0 then false else even_ish(n - 1)
}
