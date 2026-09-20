# Value-dependent Float failures remain catchable RuntimeErrors.

const nan = Float.nan
const infinity = Float.infinity

try {
    print(1.0.clamp(9, 2))
}
catch error: RuntimeError {
    print(error.message)
}

try {
    print(1.0.between?(nan, 2))
}
catch error: RuntimeError {
    print(error.message)
}

try {
    print(nan.floor())
}
catch error: RuntimeError {
    print(error.message)
}

try {
    print(infinity.to_int())
}
catch error: RuntimeError {
    print(error.message)
}

try {
    print(9223372036854775808.0.truncate())
}
catch error: RuntimeError {
    print(error.message)
}

print((-9223372036854775808.0).to_int())

try {
    print(12.5.format(decimal_places: -1))
}
catch error: RuntimeError {
    print(error.message)
}

try {
    print(12.5.format(decimal_places: 101))
}
catch error: RuntimeError {
    print(error.message)
}
