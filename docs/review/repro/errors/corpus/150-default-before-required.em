# Mistake: defaulted parameter before a required one (line 2). Source: guide docs/language/core.md.
func greet(greeting: String = "Hello", name: String) {
    print(greeting + " " + name)
}
greet(name: "Ava")
