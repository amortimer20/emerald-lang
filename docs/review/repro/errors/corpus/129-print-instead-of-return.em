# Mistake: printing instead of returning, then using the result (line 5). Source: McCall & Kolling 2019 (meaningful categories of novice errors).
func add(a: Int, b: Int) {
    print(a + b)
}
var total = add(2, 3) + 1
print(total)
