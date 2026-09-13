# Section 10.4: members that belong to a type rather than to each value,
# declared with the type's name in front and always reached through it.

struct Vector2 {
    var x: Float
    var y: Float

    # A type-level field needs its value where it is declared. Fields are set
    # up together, in order, the first time the type is reached.
    var Vector2.made = 0
    const Vector2.zero = Vector2.origin()

    # Factory functions name what `Vector2(Float)` would only imply (7.3).
    func Vector2.origin(): Vector2 {
        Vector2.made += 1
        return Vector2(0, 0)
    }

    # Defaults and named arguments work as for any function called by name.
    # With no return type, the type is inferred like any other function's.
    func Vector2.along(length: Float, turned: Bool = false) {
        if turned {
            return Vector2(0, length)
        }
        return Vector2(length, 0)
    }

    # An instance method reaches type-level members through the type too.
    func numbered(): String {
        return "#{self.x},#{self.y} (#{Vector2.made} made)"
    }
}

print(Vector2.zero, Vector2.made)
print(Vector2.origin().numbered())
print(Vector2.along(2), Vector2.along(3, turned: true))

# A type-level function is a function value like any other (7.5).
const make = Vector2.origin
print(make(), Vector2.made)

# A `var` type-level field changes in place like any `var`.
struct Registry {
    var Registry.names: [String] = []
    var Registry.scores: [String: Int] = []
    var Registry.last: Vector2 = Vector2(1, 1)
    var Registry.label: String? = nothing
}

func register(name: String) {
    Registry.names.append(name)
    Registry.scores[name] = Registry.names.count
}

register("ada")
register("grace")
Registry.names[0] = "Ada"
Registry.scores["grace"] += 10
Registry.last.x = 5
Registry.last.y *= 3
print(Registry.names, Registry.scores, Registry.last)
Registry.label = "done"
print(Registry.label.or("none"))

# Setting up happens once, on first use, and not before.
struct Loud {
    var Loud.first = Loud.say("first")
    var Loud.second = Loud.say("second")

    func Loud.say(text: String): String {
        print("setting up #{text}")
        return text
    }
}

print("before")
print(Loud.second)
print(Loud.first)
