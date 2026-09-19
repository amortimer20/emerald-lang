# Section 11.1 and 11.2: traits declare requirements and defaults, types adopt
# them explicitly with `with`, and a value seen through a trait keeps its own
# type's behavior and its value or reference semantics.

trait Named {
    const name: String

    func introduction(): String {
        return "I am #{self.name}."
    }
}

trait Greeter with Named {
    func greet(other: String): String

    const shout: String {
        return self.introduction().upper()
    }
}

trait Counter {
    var count: Int

    func bump() {
        self.count += 1
    }
}

struct Person with Greeter, Counter {
    const name: String
    var count: Int = 0

    @override
    func greet(other: String): String {
        return "Hi #{other}, " + Named.introduction(self)
    }
}

class Robot with Greeter {
    var serial: Int

    const name: String {
        return "RX-#{self.serial}"
    }

    @override
    func introduction(): String {
        return "BEEP. " + Named.introduction(self)
    }

    @override
    func greet(other: String): String {
        return "GREETINGS #{other}"
    }
}

func welcome(guest: Greeter) {
    print(guest.greet("Ann"), "/", guest.introduction(), "/", guest.shout, "/", guest.type_name)
}

var ada = Person("Ada")
welcome(ada)
welcome(Robot(7))
ada.bump()
ada.bump()
print(ada.count)

var counter: Counter = ada
counter.bump()
print(counter.count, ada.count)

const things: List[Named] = [ada, Robot(1)]
for thing in things {
    print(thing.name, thing is Greeter, thing is Robot, thing is Counter)
    if thing is Robot {
        print(thing.serial)
    }
}

# A trait's default property, replaced in one type by a stored field.
trait Labelled {
    const label: String {
        return "unlabelled"
    }
}

struct Box with Labelled {
    const size: Int = 1
}

struct Jar with Labelled {
    const label: String = "jam"
}

const labels: List[Labelled] = [Box(), Jar()]
for item in labels {
    print(item.label)
}

# A `var` requirement met by a property with a setter, set through the trait.
trait Scaled {
    var scale: Float
}

class Dial with Scaled {
    var raw: Float = 0

    var scale: Float {
        get {
            return self.raw / 10
        }
        set {
            self.raw = value * 10
        }
    }
}

const dial = Dial()
var scaled: Scaled = dial
scaled.scale = 2.5
print(dial.raw, scaled.scale)

# A class shares itself through a trait, while a struct is copied.
class Tally with Counter {
    var count: Int = 0
}

const tally = Tally()
var shared: Counter = tally
shared.bump()
print(tally.count)

# Traits may each keep a private helper of the same name.
trait Left {
    func left(): String {
        return self._tag()
    }

    func _tag(): String {
        return "L"
    }
}

trait Right {
    func right(): String {
        return self._tag()
    }

    func _tag(): String {
        return "R"
    }
}

struct Pair with Left, Right {
    func own(): String {
        return self._tag()
    }

    func _tag(): String {
        return "P"
    }
}
print(Pair().left(), Pair().right(), Pair().own())

# Trait membership is inherited, and an abstract class may leave a
# requirement to its subclasses.
@abstract
class Machine with Greeter {
    const name: String = "machine"
}

class Toaster extends Machine {
    @override
    func greet(other: String): String {
        return "*pop* #{other}"
    }
}

const toaster: Greeter = Toaster()
print(toaster.greet("Bo"), toaster is Machine)

# A captured method through a trait is the value's own version.
const hello = toaster.greet
print(hello("Cy"))

# `is` narrows to a trait too.
func maybe_count(value: Named): Int {
    if value is Counter {
        return value.count
    }
    return -1
}
print(maybe_count(ada), maybe_count(Robot(2)))

# A requirement a struct supplies with a method that changes it, called
# through the trait, changes the value the trait's variable holds.
trait Resettable {
    func reset()
}

struct Stopwatch with Resettable {
    var seconds: Int = 9

    @override
    func reset() {
        self.seconds = 0
    }
}

var timer: Resettable = Stopwatch()
timer.reset()
if timer is Stopwatch {
    print(timer.seconds)
}

# A requirement's parameter defaults belong to the trait, so an implementation
# called through its own type uses them too, and so does a subclass's override.
trait Repeater {
    func echo(word: String, times: Int = 2): String
}

struct Parrot with Repeater {
    @override
    func echo(word: String, times: Int): String {
        return word.repeat(times)
    }
}

class Canyon with Repeater {
    @override
    func echo(word: String, times: Int): String {
        return word.repeat(times)
    }
}

class DeepCanyon extends Canyon {
    @override
    func echo(word: String, times: Int): String {
        return super.echo(word.upper(), times: times)
    }
}

print(Parrot().echo("hi"), Canyon().echo("ho"), DeepCanyon().echo("ha"))
