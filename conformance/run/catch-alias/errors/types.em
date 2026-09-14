class SmallError extends Error {
}

func fail() {
    raise SmallError("caught through an alias")
}
