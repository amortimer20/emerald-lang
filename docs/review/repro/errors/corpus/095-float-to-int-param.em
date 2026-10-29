# Mistake: passing a / result to an Int parameter (line 5). Source: review brief list.
func stars(count: Int) {
    print("*".repeat(count))
}
stars(9 / 3)
