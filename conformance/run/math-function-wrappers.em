const sine: func(Float): Float = { value => Math.sin(value) }
const angle: func(Float, Float): Float = { y, x => Math.arc_tan2(y, x) }
assert(sine(0.0) == 0.0)
assert(angle(0.0, 1.0) == 0.0)
assert(Math.pi > 3.0)
assert(Emerald.Math.e > 2.0)
print("Math wrappers work")
