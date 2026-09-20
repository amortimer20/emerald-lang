# Each value-dependent mistake is catchable, and a later expression still runs.

try {
    print((-9223372036854775808).abs())
}
catch error: RuntimeError {
    print(error.message)
}

try {
    print(5.clamp(9, 2))
}
catch error: RuntimeError {
    print(error.message)
}

try {
    print(5.between?(9, 2))
}
catch error: RuntimeError {
    print(error.message)
}

try {
    print(6.multiple_of?(0))
}
catch error: RuntimeError {
    print(error.message)
}

try {
    print((-1).factorial())
}
catch error: RuntimeError {
    print(error.message)
}

try {
    print(21.factorial())
}
catch error: RuntimeError {
    print(error.message)
}

try {
    print((-9223372036854775808).gcd(0))
}
catch error: RuntimeError {
    print(error.message)
}

try {
    print(9223372036854775807.lcm(2))
}
catch error: RuntimeError {
    print(error.message)
}

try {
    print(255.to_string(base: 1))
}
catch error: RuntimeError {
    print(error.message)
}

try {
    print(255.to_string(base: 37))
}
catch error: RuntimeError {
    print(error.message)
}
