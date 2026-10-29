# Section 9.3: both signed zeros answer false to `positive?()` and `negative?()`,
# `Math.natural_log(0)` gives `-Infinity`, and `List.random()` and `Random.choose`
# give `nothing` for an empty List.
print(0.0.positive?(), 0.0.negative?(), (-0.0).positive?(), (-0.0).negative?())
print((-0.0).zero?(), 0.positive?(), 0.negative?())
print(Math.natural_log(0), Math.natural_log(0.0))
const empty: List[Int] = []
print(empty.random() == nothing)
const generator = Random(seed: 42)
print(generator.choose(empty) == nothing)
