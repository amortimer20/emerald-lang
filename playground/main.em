# Scratch space — edit freely, this file is not part of the test suite.
#
# Run it:  Ctrl+Shift+P -> "Tasks: Run Test Task"
# or from a WSL terminal:  emerald playground/main.em

print("Emerald v0")
print("")

# Sprinkles
5.times { print("hi") }
print(7.even?())
print(42.clamp(1, 10))

# Arrays — the block parameter's type is inferred from the element type
var numbers = [5, 3, 8, 1]
print(numbers.sort().join(", "))
print(numbers.filter { n => n > 3 }.map { n => n * 10 }.join(" "))

# if/then is an expression, so there is no ternary to learn
var grade = if numbers.sum() > 10 then "big" else "small"
print("the numbers are #{grade}")

# Classes, traits, and a struct
trait Greeter {
    abstract func name(): String

    func greet(): String {
        return "Hello, #{self.name()}!"
    }
}

class Person with Greeter {
    var given: String

    constructor(given: String) {
        self.given = given
    }

    func name(): String {
        return self.given
    }
}

class Teacher {
    var first_name: String
    var last_name: String

    constructor(first_name: String, last_name: String) {
        self.first_name = first_name
        self.last_name = last_name
    }

    func to_string(): String {
        return "#{self.first_name} #{self.last_name}"
    }
}

print(Person("Ada").greet())

# Things that might not be there come back as T?, and the checker insists you handle it
var maybe = "not a number".to_int_maybe()
print("parsed: #{maybe.or(0)}")

var t = Teacher("Anthony", "Mortimer")
print(t)