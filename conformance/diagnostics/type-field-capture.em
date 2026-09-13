# Section 7.1, for section 10.4's lazy setup: reading a type-level field can be
# what sets the type up, so whatever its value reads must be assigned by then.
var greeting: String

struct Banner {
    var text: String
    const Banner.default = greeting
}

print(Banner.default)
const banner = Banner("hi")
greeting = "hello"
print(Banner.default, banner)
