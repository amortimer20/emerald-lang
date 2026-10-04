struct Greeter {
    func greet(name: String, punctuation: String = "!"): String {
        return name + punctuation
    }
}
const greeter = Greeter()
greeter.greet("Ada", /*cursor*/"!")
