func key_with_nan(number: Int): Float {
    if number == 1 {
        return Float.nan
    }
    return 1.0
}

print([1, 2].sort_by { number => key_with_nan(number) })
