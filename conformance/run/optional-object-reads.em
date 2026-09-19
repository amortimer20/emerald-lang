# Optional chaining slice 2: stored fields and computed properties short-circuit.
struct Person {
    const name: String

    const greeting: String {
        return "Hello, #{self.name}!"
    }

    func greet(prefix: String): String {
        return "#{prefix}, #{self.name}!"
    }
}

const present: Person? = Person("Ava")
const absent: Person? = nothing
print(present?.name, absent?.name)
print(present?.greeting, absent?.greeting)
print(absent?.name.or("unknown"), absent?.greeting.or("none"))
var calls = 0
func counted(): String {
    calls += 1
    return "Hi"
}
print(present?.greet(counted()), absent?.greet(counted()), calls)
