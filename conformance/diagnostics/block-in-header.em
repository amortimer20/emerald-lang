const numbers = [1, 2, 3]
if numbers.map { number => number } {
    print("never")
}
