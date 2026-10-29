# 16.3: "Ordering should be deterministic" and tests "run independently
# enough", but which order, and whether module state carries between tests,
# are unstated. Run with `emerald test`.
var counter = 0

@test
func zeta_declared_first() {
    counter += 1
    print("zeta sees", counter)
}

@test
func alpha_declared_second() {
    counter += 1
    print("alpha sees", counter)
}
