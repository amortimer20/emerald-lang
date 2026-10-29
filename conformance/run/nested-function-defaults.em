# Section 7.1: a nested function takes defaults and named arguments like any named
# function (7.3).
func outer() {
    func greet(name: String, punctuation: String = "!", greeting: String = "Hello") {
        print("#{greeting}, #{name}#{punctuation}")
    }
    greet("Ava")
    greet("Bo", greeting: "Hi")
    greet("Cy", punctuation: "?", greeting: "Hey")
}

outer()
