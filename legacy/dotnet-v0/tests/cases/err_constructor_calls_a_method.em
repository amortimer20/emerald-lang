## A constructor may not call a method on the object it is building.
##
## Definite assignment covers reading a field directly. It did not cover calling a method,
## and a method reads whatever it likes -- so this program used to compile and then fail
## at runtime with "Cannot call upper on nothing", on a non-nullable String, in the one
## feature whose whole purpose is that this cannot happen.
##
## The check is local. It never looks inside shout.

class Greeter {
    var name: String

    func shout(): String { return self.name.upper() }

    constructor() {
        print(self.shout())
        self.name = "ada"
    }
}

Greeter()
