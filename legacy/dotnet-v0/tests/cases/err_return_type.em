# A declared return type was never compared with what the function actually returned,
# which meant the one annotation a caller relies on was the one nothing checked.
func name(): String {
    return 42
}
