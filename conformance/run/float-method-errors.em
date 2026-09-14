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
