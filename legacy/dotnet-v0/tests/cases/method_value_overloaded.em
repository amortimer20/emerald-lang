## Which version a bare name means cannot be read off the site, so the type it is being
## given to decides. The runtime keeps the whole set and dispatches on the arguments,
## which reaches the same version the checker chose.
class Greeter {
    func hi(): String { return "hi there" }
    func hi(name: String): String { return "hi #{name}" }
}

var g = Greeter()

var greet_one: func(String): String = g.hi
var greet_none: func(): String = g.hi

print(greet_one("ada"))
print(greet_none())
