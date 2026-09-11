# Section 7.1: hoisting never permits reading an uninitialized captured
# variable. `area` can be called above its declaration, but not above the line
# that assigns what it reads.

print(area(2.0))

const pi = 3.14159

func area(radius: Float): Float {
    return pi * radius * radius
}
