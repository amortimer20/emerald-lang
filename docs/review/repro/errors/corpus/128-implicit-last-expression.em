# Mistake: last expression as the result (Ruby habit) (line 3). Source: carry-over from Ruby; Rust.
func double(n: Int): Int {
    n * 2
}
print(double(4))
