# Mistake: printing the result of a Nothing function (line 5). Source: McCall & Kolling 2019 (meaningful categories of novice errors).
func greet(name: String) {
    print("Hello " + name)
}
print(greet("Ava"))
