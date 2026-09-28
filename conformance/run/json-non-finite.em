# JSON has no representation for NaN or either infinity. The builder rejects
# all three before an invalid Json value can exist.
for value in [Float.nan, Float.infinity, -Float.infinity] {
    try {
        Json.from_float(value)
    } catch error: JsonError {
        print(error.message)
    }
}
