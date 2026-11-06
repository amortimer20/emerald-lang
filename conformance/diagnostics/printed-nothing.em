# A function with no result gives back `nothing`, so printing its call prints
# `nothing`.
func greet(name: String) {
    print("Hello, #{name}")
}
print(greet("Ava"))
print("Result:", greet("Bo"))

class Door {
    func open() {
        print("creak")
    }
}
const door = Door()
print(door.open())

# Near misses: a call that gives back a value, an optional that may be
# `nothing`, and the call on its own line.
func shout(name: String): String {
    return name.upper()
}
func find_name(names: List[String]): String? {
    return names.first
}
print(shout("Ava"))
print(find_name([]))
greet("Cy")
