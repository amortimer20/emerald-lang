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

# The same through an operator, which runs a method of the left operand.
var offset: Int

struct Step with Addable, Ordered {
    const n: Int

    @override
    func add(other: Self): Self {
        return Step(self.n + other.n + offset)
    }

    @override
    func compare(other: Self): Int {
        return self.n - other.n + offset
    }
}

func total(): Step {
    return Step(1) + Step(2)
}

func ordered(): Bool {
    return Step(1) < Step(2)
}

func grow(): Step {
    var step = Step(1)
    step += Step(1)
    return step
}

print(total())
print(ordered())
print(grow())
print(Step(1) + Step(2))
offset = 10
