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

# `case` names a choice's data, in its own arm only.
func describe(download: Download): String {
    return case download {
        when Download.waiting then "Waiting"
        when Download.finished(path) then "Saved to #{path}"
        when Download.failed(message) then "Failed: #{message}"
    }
}

print(describe(Download.waiting))
print(describe(Download.finished("report.pdf")))
print(describe(Download.failed("disk full")))

func area(shape: Shape): Float {
    return case shape {
        when Shape.circle(radius) then Math.pi * radius * radius
        when Shape.rectangle(width, height) then width * height
    }
}

print(area(Shape.rectangle(width: 4.0, height: 3.0)))

for action in [Action.move(2, 3), Action.say("Hello!"), Action.wait] {
    case action {
        when Action.move(x, y) {
            print("Move to #{x}, #{y}")
        }
        when Action.say(text) {
            print(text)
        }
        when Action.wait {
            print("Wait here")
        }
    }
}

# `_` ignores a position; names need not be the labels.
case Action.move(1, 2) {
    when Action.move(_, down) {
        print("down #{down}")
    }
    else {
        print("other")
    }
}

# A working copy changes; the enum's own data does not.
case guests {
    when Guests.named(names) {
        var updated = names
        updated.append("Grace")
        print(updated)
    }
}
print(guests)

# Recursion, returns, and definite assignment through matches.
func total(chain: Chain): Int {
    case chain {
        when Chain.end {
            return 0
        }
        when Chain.link(number, rest) {
            return number + total(rest)
        }
    }
}

print(total(Chain.link(1, Chain.link(2, Chain.link(3, Chain.end)))))

func first(chain: Chain): String {
    var result: String
    case chain {
        when Chain.end {
            result = "empty"
        }
        when Chain.link(number, _) {
            result = "starts with #{number}"
        }
    }
    return result
}

print(first(Chain.link(7, Chain.end)))

# A block made in an arm keeps the data it names.
var later: List[func(): String] = []
for action in [Action.say("kept"), Action.wait] {
    case action {
        when Action.say(text) {
            later.append({ => "#{text}!" })
        }
        else {
        }
    }
}
print(later[0]())

# An optional subject: a match never matches `nothing`.
const missing: Download? = nothing
case missing {
    when Download.finished(path) {
        print(path)
    }
    when nothing {
        print("no download")
    }
    else {
        print("not finished")
    }
}

# Optional data stays optional when named.
case Note.text(nothing) {
    when Note.text(body) {
        print(body.or("(empty)"))
    }
}

# A match selects by choice, whatever custom equality says; `==` does not.
enum Tag with Equatable {
    named(text: String)
    blank

    @override
    func equals(other: Tag): Bool {
        return true
    }
}

case Tag.named("x") {
    when Tag.blank {
        print("equal to blank")
    }
    else {
        print("not blank")
    }
}
case Tag.blank {
    when Tag.named(text) {
        print("named #{text}")
    }
    when Tag.blank {
        print("the blank choice")
    }
}

# An error raised inside an arm leaves through it.
try {
    case Download.failed("disk full") {
        when Download.failed(message) {
            raise RuntimeError(message)
        }
        else {
        }
    }
}
catch error: RuntimeError {
    print("caught #{error.message}")
}

# A type-level field can be built from one of its enum's own choices.
enum Report {
    empty
    saved(path: String)

    const Report.fallback = Report.saved("default.txt")
}

print(Report.fallback)

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
