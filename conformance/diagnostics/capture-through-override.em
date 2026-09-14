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
