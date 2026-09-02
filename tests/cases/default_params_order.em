func greet(greeting: String = "Hello", name: String): String {
    return "#{greeting}, #{name}"
}

print(greet("a", "b"))
