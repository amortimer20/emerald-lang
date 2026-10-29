# Section 3.2: a trait's private helper, and its documentation, does not become part of
# an adopter's public API, so completion on the adopter does not offer it.
trait Greeter {
    ## Builds the greeting text.
    func _greeting(): String {
        return "Hello"
    }

    ## Says hello.
    func greet() {
        print(self._greeting())
    }
}

struct Robot with Greeter {
}

var robot = Robot()
robot./*cursor*/
