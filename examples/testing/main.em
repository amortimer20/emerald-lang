# Tests: *_test.em files and @test functions (§3.5)
#
# Convention over configuration, in the box. There is nothing to register and nothing
# to configure — a test is a file named something_test.em with @test functions in it.
#
#   emerald test examples/testing
#
# Running the tests does not run this file's top-level code. Declarations are loaded so
# the tests can call them; the program's own work is left alone.

print("this line runs with `emerald run`, and not during `emerald test`")

func clamp(value: Int, low: Int, high: Int): Int {
    return if value < low then low else if value > high then high else value
}

func initials(name: String): String {
    var letters = ""
    for part in name.split(" ") {
        letters += part.chars()[0].upper()
    }
    return letters
}
