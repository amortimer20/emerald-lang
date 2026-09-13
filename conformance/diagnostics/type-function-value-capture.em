# Reaching a type-level function as a value sets up its type, even though the
# function body does not run until the value is called (7.1, 10.4, 14.1).
var greeting: String

struct Banner {
    const Banner.default = greeting

    func Banner.make() {
    }
}

const make = Banner.make
greeting = "hello"
make()
