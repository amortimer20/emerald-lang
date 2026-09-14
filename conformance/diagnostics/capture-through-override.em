# Section 7.1 with section 10.7: calling a method may run any subclass's
# override of it, so what an override reads has to be assigned by then too.
var title: String

class Greeter {
    func greet(): String {
        return "hi"
    }
}

class Formal extends Greeter {
    @override
    func greet(): String {
        return title + " hello"
    }
}

func pick(): Greeter {
    return Formal()
}

const greeter = pick()
print(greeter.greet())
title = "Dr."

# The same through a trait: the call may run what a type adopting it supplies.
var suffix: String

trait Titled {
    func title(): String
}

struct Book with Titled {
    @override
    func title(): String {
        return "Book" + suffix
    }
}

func shelf(): Titled {
    return Book()
}

const titled = shelf()
print(titled.title())
suffix = "!"
