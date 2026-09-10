## ?. reads through a ? and puts it back on the answer. Without it, walking a nullable
## path costs a local and a nested if per link — verbose enough that the tempting fix is
## to declare the field non-nullable and store a fake, which is the sentinel habit
## non-nullable types exist to break.
class City {
    var name: String

    constructor(name: String) { self.name = name }

    func shout(): String { return self.name.upper() }
}

class Address {
    var city: City?
    constructor(city: City?) { self.city = city }
}

class User {
    var address: Address?
    constructor(address: Address?) { self.address = address }
}

var full = User(Address(City("Leeds")))
var partial = User(Address(nothing))
var empty = User(nothing)

## Each link checks itself, and the chain stops at the first one that is missing.
print(full.address?.city?.name.or("unknown"))
print(partial.address?.city?.name.or("unknown"))
print(empty.address?.city?.name.or("unknown"))

## A call is skipped whole when there is no receiver — including its arguments.
func loud(): String {
    print("the argument was evaluated")
    return "!"
}

print(full.address?.city?.shout().or("-"))
print(empty.address?.city?.shout().or("-"))

class Logger {
    func write(message: String) { print(message) }
}

var absent: Logger? = nothing
absent?.write(loud())

var present: Logger? = Logger()
present?.write(loud())

## Built-in types read the same way.
var some: List<Int>? = [1, 2, 3]
var none: List<Int>? = nothing
print(some?.count().or(0))
print(none?.count().or(0))

var text: String? = "hi"
print(text?.upper().or("-"))
