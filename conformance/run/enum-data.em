# Section 12: enum choices that carry data.

enum Download {
    waiting
    finished(path: String)
    failed(message: String)
}

enum Action {
    move(x: Int, y: Int)
    say(text: String)
    wait
}

enum Shape {
    circle(radius: Float)
    rectangle(width: Float, height: Float)
}

# Construction and display.
var download = Download.waiting
print(download)
download = Download.finished("report.pdf")
print(download)
print(Action.move(y: 3, x: 2))
print(Shape.circle(2))
print([Action.move(2, 3), Action.say("Hello!"), Action.wait])

# Equality compares the choice, then its data.
print(Download.finished("a.pdf") == Download.finished("a.pdf"))
print(Download.finished("a.pdf") == Download.finished("b.pdf"))
print(Download.finished("a.pdf") == Download.failed("a.pdf"))
print(Download.waiting == Download.waiting)

# A choice is passed along by wrapping its call in a block.
const say: func(String): Action = { text => Action.say(text) }
print(say("Hello!"))
print(["one", "two"].map { text => Action.say(text) })

# Data is a value: changing the list it was built from changes nothing.
enum Guests {
    named(names: List[String])
}

var source = ["Ada"]
const guests = Guests.named(source)
source.append("Grace")
print(guests)
print(source)

# Arguments run once, in the order written, whatever order they fill.
var order: List[String] = []
func note(label: String, value: Int): Int {
    order.append(label)
    return value
}
print(Action.move(y: note("y", 4), x: note("x", 5)))
print(order)

# Recursive data.
enum Chain {
    end
    link(number: Int, next: Chain)
}

print(Chain.link(1, Chain.link(2, Chain.end)))

# A key when every choice's data is a key type.
enum Seat {
    numbered(row: Int, seat: Int)
    standing
}

var holders: Dict[Seat, String] = []
holders[Seat.numbered(1, 4)] = "Ada"
holders[Seat.standing] = "Grace"
print(holders[Seat.numbered(1, 4)])
print(holders.count)
const taken: Set[Seat] = [Seat.numbered(1, 4), Seat.numbered(row: 1, seat: 4), Seat.standing]
print(taken.count)

# Built in the enum's own functions, through an alias, and nested.
enum Outcome {
    ok(value: Int)
    failed(message: String)

    func Outcome.checked(number: Int): Outcome {
        return if number >= 0 then Outcome.ok(number) else Outcome.failed("negative")
    }
}

using Result = Outcome
print(Outcome.checked(3))
print(Outcome.checked(-1))
print(Result.ok(5))

struct Game {
    enum Move {
        step(by: Int)
        rest
    }
}

struct Turn {
    const move: Game.Move
}

print(Turn(Game.Move.step(by: 2)))

# Optional data, sent through a channel.
enum Note {
    text(body: String?)
}

const notes: Channel[Note] = Channel(capacity: 2)
notes.send(Note.text("hi"))
notes.send(Note.text(nothing))
print(notes.receive())
print(notes.receive())

# `case` compares with a value built beforehand by `==`.
const wanted = Download.finished("report.pdf")
case download {
    when wanted {
        print("the wanted file")
    }
    else {
        print("something else")
    }
}
